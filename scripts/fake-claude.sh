#!/usr/bin/env bash
# fake-claude.sh — a stand-in for `claude` so the supervised loop can be tested
# end-to-end offline (no tokens, no real usage limit). It ignores all flags and:
#   - emits a usage-limit message on call number $FAKE_LIMIT_ON_CALL (default 1),
#     with a reset time a few seconds in the future (so the wait is short);
#   - on every other call, prints a normal success line.
# Call count is kept in $RALPH_DIR/.fake-claude-calls.
set -u
: "${RALPH_DIR:=.ralph}"
: "${FAKE_LIMIT_ON_CALL:=1}"
: "${FAKE_RESET_SECONDS:=3}"   # how far in the future the fake reset is
mkdir -p "$RALPH_DIR"
counter="$RALPH_DIR/.fake-claude-calls"
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$counter"

if [ "${FAKE_ALWAYS_LIMIT:-0}" = "1" ] || [ "$n" = "$FAKE_LIMIT_ON_CALL" ]; then
  reset_iso="$(date -u -d "+${FAKE_RESET_SECONDS} seconds" '+%Y-%m-%dT%H:%M:%SZ')"
  echo "You've hit your session limit · resets at ${reset_iso}"
  exit 0
fi
echo "FAKE: implemented task on call #$n; build passed; committed."
