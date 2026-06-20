#!/bin/bash
# Stop hook — Claude cannot stop until all gates pass.
# Exit 2 = block stop and ask Claude to fix. Exit 0 = allow stop.

input=$(cat)

# Prevent infinite loops: allow stop if hook is already active
if [ "$(echo "$input" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0
fi

# Skip if no package.json yet (project not yet initialised)
if [ ! -f "package.json" ]; then
  exit 0
fi

if ! pnpm build --silent 2>&1; then
  echo "Build/typecheck fails. Fix all errors before stopping." >&2
  exit 2
fi

if ! pnpm lint --silent 2>&1; then
  echo "Lint fails. Fix all lint errors before stopping." >&2
  exit 2
fi

if ! pnpm test --silent 2>&1; then
  echo "Tests fail. Make all tests green before stopping." >&2
  exit 2
fi

exit 0
