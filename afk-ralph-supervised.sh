#!/usr/bin/env bash
# afk-ralph-supervised.sh — supervised, long-running AFK Ralph loop.
#
# Same job as afk-ralph.sh (implement → review → repeat against PRD.md), but
# production-ready for unattended multi-hour runs:
#   - runs Claude with --output-format json and classifies every run as
#     success / usage-limit / failure from the result envelope — no regex over
#     prose, so a task about "rate limiting" can't fake a usage limit,
#   - on a usage limit: parses the reset time, waits LOCALLY past it (no
#     tokens), then retries the SAME iteration; circuit breaker after
#     RALF_RATE_LIMIT_MAX_RETRIES,
#   - on any other failure (CLI crash, denied tools, max-turns…): short
#     backoff and retry; circuit breaker after RALF_MAX_CONSECUTIVE_FAILURES,
#   - stall detection: an implement iteration that produces NO new commit
#     counts toward RALF_MAX_NO_PROGRESS — the loop stops instead of burning
#     tokens on a wedged task (a denied `git commit` looks exactly like this),
#   - checkpoint/state in .ralph/ (atomic JSON), live + raw + rate-limit logs,
#   - single-runner lock (flock, or a portable mkdir fallback on macOS),
#   - token-efficient tiered review (mini self-check every loop, diff review
#     every N, full PRD review every M).
#
# Resume model: Claude is invoked non-interactively (`claude -p`), so "resume"
# means simply re-issuing the SAME `claude -p` call after the wait — no
# `continue` needed. Override the binary with RALF_CLAUDE_BIN (e.g.
# scripts/fake-claude.sh for offline tests); it must support
# `--output-format json`.
#
# Usage: ./afk-ralph-supervised.sh [iterations]
set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/ralph-lib.sh
source lib/ralph-lib.sh

ITERATIONS="${1:-${RALF_ITERATIONS:-20}}"
RALF_CLAUDE_BIN="${RALF_CLAUDE_BIN:-claude}"
RALF_PERMISSION_MODE="${RALF_PERMISSION_MODE:-acceptEdits}"
RALF_MAX_TURNS="${RALF_MAX_TURNS:-}"   # empty = no --max-turns flag
RALF_GIT_PUSH="${RALF_GIT_PUSH:-0}"    # 1 = push after every committing iteration

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
git_q() { git "$@" 2>/dev/null; }

ralph_preflight || exit 1
mkdir -p "$RALPH_DIR"

# --- single-runner lock (no double runners) --------------------------------
if ! ralph_acquire_lock; then
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
    failures    "$(jq -r '.consecutive_failures // "0"'   "$STATE_FILE" 2>/dev/null)/$RALF_MAX_CONSECUTIVE_FAILURES" \
    no_progress "$(jq -r '.no_progress_count // "0"'      "$STATE_FILE" 2>/dev/null)/$RALF_MAX_NO_PROGRESS" \
    commit      "$(jq -r '.git_commit // ""'              "$STATE_FILE" 2>/dev/null)" \
    updated     "$(date '+%H:%M:%S')"
}

ralph_state_init() {
  ralph_json_merge "$STATE_FILE" \
    status "running" current_iteration "0" current_task "startup" \
    last_completed_step "" next_step "implement" pause_reason "" \
    detected_limit_message "" reset_at "" resume_after "" \
    rate_limit_retry_count "0" max_rate_limit_retries "$RALF_RATE_LIMIT_MAX_RETRIES" \
    consecutive_failures "0" no_progress_count "0" \
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
  ralph_release_lock
}
trap finish EXIT

# Run Claude once. Raw output (JSON envelope + any noise) is appended to the
# raw log for post-mortems; the caller logs the extracted text to the live log.
run_claude() {
  local args=(--permission-mode "$RALF_PERMISSION_MODE" --output-format json)
  [ -n "$RALF_MAX_TURNS" ] && args+=(--max-turns "$RALF_MAX_TURNS")
  "$RALF_CLAUDE_BIN" "${args[@]}" -p "$1" 2>&1 | tee -a "$RAW_LOG"
}

# Map a supervised_claude breaker code to a final status and stop the runner.
breaker_exit() { # $1 = return code, $2 = context
  case "$1" in
    3) RUN_STATUS="failed_rate_limit_max_retries" ;;
    4) RUN_STATUS="failed_consecutive_failures" ;;
    *) RUN_STATUS="failed_unknown" ;;
  esac
  ralph_log "Circuit breaker ($RUN_STATUS) during $2. Stopping cleanly."
  exit 1
}

# Run Claude with supervision. Classifies every run:
#   limit   → record it, wait past the reset (locally, no tokens), retry the
#             SAME call; returns 3 when the rate-limit breaker trips.
#   failure → short backoff, retry the SAME call; returns 4 when the failure
#             breaker trips.
#   success → echoes the assistant text and returns 0.
supervised_claude() {
  local prompt="$1" output retries fails target msg
  while true; do
    # A fresh attempt gets a fresh stop-gate budget (see .claude/hooks/verify.sh).
    rm -f "$RALPH_DIR/stop-blocks"
    output="$(run_claude "$prompt")"
    ralph_classify_output "$output"

    if [ "$RALPH_CLS" = "limit" ]; then
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

    if [ "$RALPH_CLS" = "failure" ]; then
      fails=$(( $(jq -r '.consecutive_failures // 0' "$STATE_FILE" 2>/dev/null) + 1 ))
      msg="$(printf '%s' "$RALPH_LAST_RESULT" | tr '\n' ' ' | cut -c1-200)"
      ralph_log "Run failed ($fails/$RALF_MAX_CONSECUTIVE_FAILURES): $msg"
      ralph_json_merge "$STATE_FILE" status "retrying_failure" consecutive_failures "$fails"
      ralph_status_update
      if [ "$fails" -ge "$RALF_MAX_CONSECUTIVE_FAILURES" ]; then
        return 4
      fi
      sleep "$RALF_FAILURE_BACKOFF_SECONDS"
      ralph_json_merge "$STATE_FILE" status "running"
      ralph_status_update
      continue
    fi

    # Success — this limit/failure episode is over, reset both counters.
    ralph_json_merge "$STATE_FILE" rate_limit_retry_count "0" consecutive_failures "0"
    ralph_log "$RALPH_LAST_RESULT"
    printf '%s' "$RALPH_LAST_RESULT"
    return 0
  done
}

IMPLEMENT_PROMPT="$(cat <<'PROMPT'
@PRD.md @learnings.txt @review.md

1. Read learnings.txt first — apply any relevant patterns.
2. Fix any open gaps listed in review.md before picking a new task. Mark the gaps you fixed as resolved in review.md; write NO GAPS when none remain.
3. Find the highest-priority incomplete task in PRD.md and implement it fully (no stubs, no TODOs).
4. Mark that task done in PRD.md by changing its checkbox from '- [ ]' to '- [x]'.
5. Append a one-line summary to progress.txt.
6. If you learned a reusable pattern, append it briefly to learnings.txt. If learnings.txt has grown past ~40 lines, compact it (merge duplicates, drop stale entries) as part of this commit.
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
    prompt="Use the reviewer subagent for a FULL pass: review all work against PRD.md, write gaps to review.md. If the PRD is fully implemented and there are NO GAPS, end your reply with exactly this on its own final line: <promise>COMPLETE</promise>"
  else
    prompt="Use the reviewer subagent for a CHEAP diff review: review ONLY the latest commit (git diff HEAD~1 HEAD) against the PRD task it claims to implement. Write gaps to review.md, else write NO GAPS. End your reply with <promise>COMPLETE</promise> on its own final line ONLY if the entire PRD is done."
  fi
  out="$(supervised_claude "$prompt")" || breaker_exit "$?" "review:$mode"
  ralph_review_complete "$out"
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

  head_before="$(git_q rev-parse HEAD || echo none)"
  supervised_claude "$IMPLEMENT_PROMPT" >/dev/null || breaker_exit "$?" "implement#$i"

  # Stall detection: an implement run that commits nothing made no progress —
  # a wedged task, or `git commit` being denied (check permissions.allow).
  head_after="$(git_q rev-parse HEAD || echo none)"
  if [ "$head_after" = "$head_before" ]; then
    stalls=$(( $(jq -r '.no_progress_count // 0' "$STATE_FILE" 2>/dev/null) + 1 ))
    ralph_json_merge "$STATE_FILE" no_progress_count "$stalls"
    ralph_status_update
    ralph_log "No new commit after implement #$i ($stalls/$RALF_MAX_NO_PROGRESS)."
    if [ "$stalls" -ge "$RALF_MAX_NO_PROGRESS" ]; then
      RUN_STATUS="stalled_no_progress"
      ralph_log "Stall breaker: $stalls consecutive iterations without a commit. Stopping cleanly."
      exit 1
    fi
  else
    ralph_json_merge "$STATE_FILE" no_progress_count "0"
    if [ "$RALF_GIT_PUSH" = "1" ]; then
      git_q push origin HEAD || ralph_log "git push failed (non-fatal)."
    fi
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
