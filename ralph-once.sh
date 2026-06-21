#!/bin/bash
# ralph-once.sh — Run one implementation loop iteration (with human in the loop).
# Usage: ./ralph-once.sh
# The Stop hook enforces: pnpm build + lint + tests must pass before stopping.

claude --permission-mode acceptEdits -p \
  "@PRD.md @progress.txt @learnings.txt @review.md

  1. Read learnings.txt first — apply any relevant patterns.
  2. Fix any open gaps listed in review.md before picking a new task.
  3. Find the highest-priority incomplete task in PRD.md and implement it fully (no stubs, no TODOs).
  4. Mark that task done in PRD.md by changing its checkbox from '- [ ]' to '- [x]'.
  5. Commit your changes with a conventional commit message (feat:, fix:, chore:, refactor:).
  6. Append a one-line summary of what you did to progress.txt.
  7. If you learned a reusable pattern or hit a gotcha, append it briefly to learnings.txt.

  ONLY WORK ON A SINGLE TASK PER RUN."
