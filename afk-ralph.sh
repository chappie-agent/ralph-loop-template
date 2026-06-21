#!/bin/bash
# afk-ralph.sh — Unattended implementation loop with independent review every N iterations.
# Usage: ./afk-ralph.sh [iterations] [review_interval]
# Defaults: 20 iterations, review every 5.
# Stops early when the reviewer outputs COMPLETE.

set -e

ITERATIONS=${1:-20}
REVIEW_INTERVAL=${2:-5}

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
  docker sandbox run claude --permission-mode acceptEdits -p \
    "@PRD.md @progress.txt @learnings.txt @review.md

    1. Read learnings.txt first — apply any relevant patterns.
    2. Fix any open gaps listed in review.md before picking a new task.
    3. Find the highest-priority incomplete task in PRD.md and implement it fully (no stubs, no TODOs).
    4. Mark that task done in PRD.md by changing its checkbox from '- [ ]' to '- [x]'.
    5. Commit your changes with a conventional commit message.
    6. Append a one-line summary to progress.txt.
    7. If you learned a reusable pattern, append it briefly to learnings.txt.

    ONLY WORK ON A SINGLE TASK."

  # ── 2. Independent review every REVIEW_INTERVAL iterations ─────────────
  if (( i % REVIEW_INTERVAL == 0 )); then
    echo ""
    echo "--- Independent review (after loop $i) ---"

    result=$(docker sandbox run claude --permission-mode acceptEdits -p \
      "Use the reviewer subagent to review the latest commit against PRD.md.
      Write any gaps to review.md. If the PRD is fully implemented and there are NO GAPS, output exactly: <promise>COMPLETE</promise>")

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
docker sandbox run claude --permission-mode acceptEdits -p \
  "Use the reviewer subagent to review all work against PRD.md and write findings to review.md.
  Output <promise>COMPLETE</promise> only if everything is done and review.md says NO GAPS."
