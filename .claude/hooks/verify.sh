#!/bin/bash
# Stop hook — blocks the agent from stopping while the quality gates are red.
# Exit 2 = block the stop and feed stderr back to Claude. Exit 0 = allow.
#
# Blocking is BOUNDED: a counter in .ralph/stop-blocks allows at most
# STOP_HOOK_MAX_BLOCKS consecutive blocks, then the hook fails open so a
# hard-stuck gate can never wedge the session. (The naive `stop_hook_active`
# guard blocks only ONCE — the second stop attempt always passes, red or
# green.) The supervised loop clears the counter before every fresh attempt.
#
# Gates are bootstrap-tolerant: each runs only once it is actually configured,
# so the project can build itself up task-by-task without the hook dead-locking.

# shellcheck disable=SC2034  # stdin must be consumed; the payload itself is unused
input=$(cat)

STOP_HOOK_MAX_BLOCKS="${STOP_HOOK_MAX_BLOCKS:-3}"
COUNT_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
COUNT_FILE="$COUNT_DIR/stop-blocks"

blocks="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac

allow() { rm -f "$COUNT_FILE"; exit 0; }

block() { # $1 = gate name, $2 = gate output
  if [ "$blocks" -ge "$STOP_HOOK_MAX_BLOCKS" ]; then
    echo "Stop hook: $1 still red after $STOP_HOOK_MAX_BLOCKS blocks — failing open so the session can end." >&2
    allow
  fi
  mkdir -p "$COUNT_DIR"
  echo $((blocks + 1)) > "$COUNT_FILE"
  {
    echo "$1 fails. Fix all errors before stopping. Output (last 50 lines):"
    printf '%s\n' "$2" | tail -n 50
  } >&2
  exit 2
}

# Nothing to gate before there is a package.json
[ -f "package.json" ] || allow

# Build — the hard gate (only if a build script exists)
if grep -q '"build"' package.json; then
  out="$(pnpm build 2>&1)" || block "Build/typecheck" "$out"
fi

# Lint — only once an ESLint config is present
if grep -q '"lint"' package.json && ls .eslintrc* eslint.config.* >/dev/null 2>&1; then
  out="$(pnpm lint 2>&1)" || block "Lint" "$out"
fi

# Tests — only once a test script exists
if grep -q '"test"' package.json; then
  out="$(pnpm test 2>&1)" || block "Tests" "$out"
fi

allow
