#!/bin/bash
# afk-ralph.sh — Unattended implementation loop with independent review every N iterations.
# Usage: ./afk-ralph.sh [iterations] [review_interval]
# Defaults: 20 iterations, review every 5.
# Stops early when the reviewer outputs COMPLETE.
#
# Headless runs can't answer permission prompts — the permissions.allow rules
# in .claude/settings.json (git commit, pnpm build/lint/test) are what make
# this loop able to commit at all. To sandbox the runs, point RALF_CLAUDE_BIN
# at a wrapper script (e.g. one that execs `docker sandbox run claude "$@"`).

set -e

ITERATIONS=${1:-20}
REVIEW_INTERVAL=${2:-5}
CLAUDE_BIN="${RALF_CLAUDE_BIN:-claude}"
PERMISSION_MODE="${RALF_PERMISSION_MODE:-acceptEdits}"

echo ""
echo "Ralph AFK loop starting"
echo "  Iterations:      $ITERATIONS"
echo "  Review interval: every $REVIEW_INTERVAL loops"
echo ""

for ((i=1; i<=ITERATIONS; i++)); do
  echo "========================================"
  echo "Loop $i / $ITERATIONS"
  echo "========================================"

  # ── 1. Implement (Stop hook enforces build + lint + tests) ──────────────
  "$CLAUDE_BIN" --permission-mode "$PERMISSION_MODE" -p \
    "@PRD.md @learnings.txt @review.md

    1. Read learnings.txt first — apply any relevant patterns.
    2. Fix any open gaps listed in review.md before picking a new task.
    3. Find the highest-priority incomplete task in PRD.md and implement it fully (no stubs, no TODOs).
    4. Mark that task done in PRD.md by changing its checkbox from '- [ ]' to '- [x]'.
    5. Append a one-line summary to progress.txt.
    6. If you learned a reusable pattern, append it briefly to learnings.txt.
    7. Commit ALL your changes (code, PRD.md, progress.txt, learnings.txt) in one conventional commit.

    ONLY WORK ON A SINGLE TASK."

  # ── 2. Independent review every REVIEW_INTERVAL iterations ─────────────
  if (( i % REVIEW_INTERVAL == 0 )); then
    echo ""
    echo "--- Independent review (after loop $i) ---"

    result=$("$CLAUDE_BIN" --permission-mode "$PERMISSION_MODE" -p \
      "Use the reviewer subagent to review the latest commit against PRD.md.
      Write any gaps to review.md. If the PRD is fully implemented and there are NO GAPS, end your reply with exactly this on its own final line: <promise>COMPLETE</promise>")

    echo "$result"

    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      echo ""
      echo "PRD complete and independently verified after $i iterations."
      exit 0
    fi

    echo ""
  fi
done

# ── Final review after max iterations ──────────────────────────────────────
echo ""
echo "Max iterations ($ITERATIONS) reached. Running final review..."
"$CLAUDE_BIN" --permission-mode "$PERMISSION_MODE" -p \
  "Use the reviewer subagent to review all work against PRD.md and write findings to review.md.
  End your reply with <promise>COMPLETE</promise> on its own final line only if everything is done and review.md says NO GAPS."
