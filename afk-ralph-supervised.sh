#!/usr/bin/env bash
# afk-ralph-supervised.sh — supervised, long-running AFK Ralph loop.
#
# Same job as afk-ralph.sh (implement → review → repeat against PRD.md), but
# production-ready for unattended multi-hour runs:
#   - detects Claude usage/rate limits in the output,
#   - parses the reset time, waits LOCALLY past it (no tokens), then retries the
#     SAME iteration (rate-limit retries are counted separately, not as failures),
#   - circuit breaker after RALF_RATE_LIMIT_MAX_RETRIES,
#   - checkpoint/state in .ralph/ (atomic JSON), live + rate-limit logs,
#   - single-runner lockfile,
#   - token-efficient tiered review (mini self-check every loop, diff review every
#     N, full PRD review every M).
#
# Resume model: Claude is invoked non-interactively (`claude -p`), so "resume"
# means simply re-issuing the SAME `claude -p` call after the wait — no `continue`
# needed. Override the binary with RALF_CLAUDE_BIN (e.g. the fake for tests).
#
# Usage: ./afk-ralph-supervised.sh [iterations]
set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/ralph-lib.sh
source lib/ralph-lib.sh

ITERATIONS="${1:-${RALF_ITERATIONS:-20}}"
RALF_CLAUDE_BIN="${RALF_CLAUDE_BIN:-claude}"
RALF_PERMISSION_MODE="${RALF_PERMISSION_MODE:-acceptEdits}"

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
git_q() { git "$@" 2>/dev/null; }

mkdir -p "$RALPH_DIR"

# --- single-runner lock (no double runners) --------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another supervised runner already holds $LOCK_FILE. Exiting." >&2
  exit 1
fi

RUN_STATUS="running"

# Compact status.json for the dashboard (derived from state.json).
ralph_status_update() {
  ralph_json_merge "$STATUS_FILE" \
    status      "$(jq -r '.status // "?"'                 "$STATE_FILE" 2>/dev/null)" \
    loop        "$(jq -r '.current_iteration // "0"'      "$STATE_FILE" 2>/dev/null)/$ITERATIONS" \
    task        "$(jq -r '.current_task // "?"'           "$STATE_FILE" 2>/dev/null)" \
    reset_at    "$(jq -r '.reset_at // ""'                "$STATE_FILE" 2>/dev/null)" \
    retries     "$(jq -r '.rate_limit_retry_count // "0"' "$STATE_FILE" 2>/dev/null)/$RALF_RATE_LIMIT_MAX_RETRIES" \
    commit      "$(jq -r '.git_commit // ""'              "$STATE_FILE" 2>/dev/null)" \
    updated     "$(date '+%H:%M:%S')"
}

ralph_state_init() {
  ralph_json_merge "$STATE_FILE" \
    status "running" current_iteration "0" current_task "startup" \
    last_completed_step "" next_step "implement" pause_reason "" \
    detected_limit_message "" reset_at "" resume_after "" \
    rate_limit_retry_count "0" max_rate_limit_retries "$RALF_RATE_LIMIT_MAX_RETRIES" \
    last_successful_timestamp "" \
    git_branch "$(git_q rev-parse --abbrev-ref HEAD || echo unknown)" \
    git_commit "$(git_q rev-parse --short HEAD || echo unknown)" \
    dirty_worktree "$([ -n "$(git_q status --porcelain)" ] && echo true || echo false)"
  ralph_status_update
}

finish() {
  ralph_json_merge "$STATE_FILE" status "$RUN_STATUS" \
    git_commit "$(git_q rev-parse --short HEAD || echo unknown)" \
    dirty_worktree "$([ -n "$(git_q status --porcelain)" ] && echo true || echo false)"
  ralph_status_update
  ralph_log "Runner exiting — status: $RUN_STATUS"
}
trap finish EXIT

# Run Claude once: tee output to the live log (so the dashboard streams it) and
# echo it back for parsing. Exit code is irrelevant; we parse the text.
run_claude() {
  "$RALF_CLAUDE_BIN" --permission-mode "$RALF_PERMISSION_MODE" -p "$1" 2>&1 | tee -a "$LIVE_LOG"
}

# Run Claude with usage-limit handling. On a limit: record it, wait past the
# reset (locally, no tokens), and retry the SAME call. Returns 3 if the circuit
# breaker trips; otherwise echoes the successful output and returns 0.
supervised_claude() {
  local prompt="$1" output retries target msg
  while true; do
    output="$(run_claude "$prompt")"
    if ralph_detect_limit "$output"; then
      retries=$(( $(jq -r '.rate_limit_retry_count // 0' "$STATE_FILE" 2>/dev/null) + 1 ))
      msg="$(printf '%s' "$output" | grep -iE "$RALF_LIMIT_PATTERNS" | head -1 | tr -d '\r' | cut -c1-200)"
      printf '[%s] retry %s/%s — %s\n' "$(date '+%F %T')" "$retries" "$RALF_RATE_LIMIT_MAX_RETRIES" "$msg" >> "$RATE_LIMIT_LOG"
      ralph_log "Usage limit (retry $retries/$RALF_RATE_LIMIT_MAX_RETRIES): $msg"
      ralph_json_merge "$STATE_FILE" status "paused_rate_limit" pause_reason "usage_limit" \
        detected_limit_message "$msg" rate_limit_retry_count "$retries"
      ralph_status_update
      if [ "$retries" -gt "$RALF_RATE_LIMIT_MAX_RETRIES" ]; then
        return 3
      fi
      target="$(ralph_resolve_reset_epoch "$output")"
      ralph_json_merge "$STATE_FILE" \
        reset_at "$(date -d "@$target" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" \
        resume_after "$(date -d "@$((target + RALF_RESUME_MARGIN_SECONDS))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
      ralph_status_update
      ralph_wait_until_epoch "$target"
      ralph_json_merge "$STATE_FILE" status "running" pause_reason ""
      ralph_status_update
      continue
    fi
    # Success — this limit episode is over, reset the retry counter.
    ralph_json_merge "$STATE_FILE" rate_limit_retry_count "0"
    printf '%s' "$output"
    return 0
  done
}

IMPLEMENT_PROMPT="$(cat <<'PROMPT'
@PRD.md @progress.txt @learnings.txt @review.md

1. Read learnings.txt first — apply any relevant patterns.
2. Fix any open gaps listed in review.md before picking a new task.
3. Find the highest-priority incomplete task in PRD.md and implement it fully (no stubs, no TODOs).
4. Mark that task done in PRD.md by changing its checkbox from '- [ ]' to '- [x]'.
5. Append a one-line summary to progress.txt.
6. If you learned a reusable pattern, append it briefly to learnings.txt.
7. Self-check before finishing: re-read your own diff — no stubs, scope matches the task, gates green.
8. Commit ALL your changes in one conventional commit.

ONLY WORK ON A SINGLE TASK.
PROMPT
)"

# Returns 0 when the reviewer declares the whole PRD COMPLETE.
do_review() {
  local mode="$1" prompt out
  ralph_json_merge "$STATE_FILE" current_task "review:$mode"; ralph_status_update
  ralph_log "--- Independent review ($mode) ---"
  if [ "$mode" = "full" ]; then
    prompt="Use the reviewer subagent for a FULL pass: review all work against PRD.md, write gaps to review.md. If the PRD is fully implemented and there are NO GAPS, output exactly: <promise>COMPLETE</promise>"
  else
    prompt="Use the reviewer subagent for a CHEAP diff review: review ONLY the latest commit (git diff HEAD~1 HEAD) against the PRD task it claims to implement. Write gaps to review.md, else write NO GAPS. Output <promise>COMPLETE</promise> ONLY if the entire PRD is done."
  fi
  out="$(supervised_claude "$prompt")" || { RUN_STATUS="failed_rate_limit_max_retries"; ralph_log "Circuit breaker tripped during review."; exit 1; }
  printf '%s\n' "$out" | grep -q "<promise>COMPLETE</promise>"
}

# ---------------------------------------------------------------------------
echo "Ralph supervised loop — $ITERATIONS iterations, diff review every $RALF_REVIEW_EVERY, full review every $RALF_FULL_REVIEW_EVERY"
ralph_state_init
ralph_log "Supervised loop starting: $ITERATIONS iterations"

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  ralph_json_merge "$STATE_FILE" status "running" current_iteration "$i" current_task "implement" next_step "implement"
  ralph_status_update
  ralph_log "=== Loop $i/$ITERATIONS ==="

  if ! output="$(supervised_claude "$IMPLEMENT_PROMPT")"; then
    RUN_STATUS="failed_rate_limit_max_retries"
    ralph_log "Circuit breaker: exceeded $RALF_RATE_LIMIT_MAX_RETRIES rate-limit retries. Stopping cleanly."
    exit 1
  fi

  ralph_json_merge "$STATE_FILE" \
    last_completed_step "implement#$i" last_successful_timestamp "$(now_iso)" \
    git_commit "$(git_q rev-parse --short HEAD || echo unknown)" \
    dirty_worktree "$([ -n "$(git_q status --porcelain)" ] && echo true || echo false)"
  ralph_status_update

  # Tiered review: full every M, else diff every N.
  if (( i % RALF_FULL_REVIEW_EVERY == 0 )); then
    if do_review full; then RUN_STATUS="complete"; ralph_log "PRD COMPLETE (full review) after loop $i."; exit 0; fi
  elif (( i % RALF_REVIEW_EVERY == 0 )); then
    if do_review diff; then RUN_STATUS="complete"; ralph_log "PRD COMPLETE (diff review) after loop $i."; exit 0; fi
  fi

  i=$(( i + 1 ))
done

ralph_log "Max iterations ($ITERATIONS) reached — final full review."
if do_review full; then RUN_STATUS="complete"; else RUN_STATUS="max_iterations_reached"; fi
