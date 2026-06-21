#!/bin/bash
# Stop hook — Claude cannot stop until the configured gates pass.
# Exit 2 = block stop and ask Claude to fix. Exit 0 = allow stop.
# Gates are bootstrap-tolerant: each runs only once it is actually configured,
# so the project can build itself up task-by-task without the hook dead-locking.

input=$(cat)

# Prevent infinite loops: allow stop if hook is already active
if [ "$(echo "$input" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0
fi

# Nothing to gate before there is a package.json
if [ ! -f "package.json" ]; then
  exit 0
fi

# Build — the hard gate (only if a build script exists)
if grep -q '"build"' package.json; then
  if ! pnpm build 2>&1; then
    echo "Build/typecheck fails. Fix all errors before stopping." >&2
    exit 2
  fi
fi

# Lint — only once an ESLint config is present
if grep -q '"lint"' package.json && ls .eslintrc* eslint.config.* >/dev/null 2>&1; then
  if ! pnpm lint 2>&1; then
    echo "Lint fails. Fix all lint errors before stopping." >&2
    exit 2
  fi
fi

# Tests — only once a test script exists
if grep -q '"test"' package.json; then
  if ! pnpm test 2>&1; then
    echo "Tests fail. Make all tests green before stopping." >&2
    exit 2
  fi
fi

exit 0
