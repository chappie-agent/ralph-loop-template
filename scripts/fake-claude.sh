#!/usr/bin/env bash
# fake-claude.sh — a stand-in for `claude` so the supervised loop can be tested
# end-to-end offline (no tokens, no real usage limit). It ignores all flags and
# emits the same JSON result envelope as `claude -p --output-format json`:
#   - a usage-limit ERROR on call number $FAKE_LIMIT_ON_CALL (default 1; 0 =
#     never), with a reset a few seconds in the future in the legacy
#     "…|<epoch>" format — portable, and it exercises the epoch parser;
#   - garbage (no envelope at all) on call $FAKE_GARBAGE_ON_CALL (default 0 =
#     never), to test the consecutive-failure breaker;
#   - a normal success envelope on every other call. Set FAKE_COMMIT=1 to also
#     make an empty git commit, so stall detection sees progress.
# Call count is kept in $RALPH_DIR/.fake-claude-calls.
set -u
: "${RALPH_DIR:=.ralph}"
: "${FAKE_LIMIT_ON_CALL:=1}"
: "${FAKE_GARBAGE_ON_CALL:=0}"
: "${FAKE_RESET_SECONDS:=3}"   # how far in the future the fake reset is
mkdir -p "$RALPH_DIR"
counter="$RALPH_DIR/.fake-claude-calls"
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$counter"

if [ "${FAKE_ALWAYS_LIMIT:-0}" = "1" ] || [ "$n" = "$FAKE_LIMIT_ON_CALL" ]; then
  reset_epoch=$(( $(date '+%s') + FAKE_RESET_SECONDS ))
  jq -cn --arg msg "Claude AI usage limit reached|${reset_epoch}" \
    '{type: "result", subtype: "error_during_execution", is_error: true, result: $msg}'
  exit 1
fi

if [ "$n" = "$FAKE_GARBAGE_ON_CALL" ]; then
  echo "claude: unexpected crash (fake, call #$n)"
  exit 1
fi

if [ "${FAKE_COMMIT:-0}" = "1" ]; then
  git commit --allow-empty -qm "chore(fake): iteration work (call #$n)" 2>/dev/null
fi

jq -cn --arg r "FAKE: implemented task on call #$n; build passed; committed." \
  '{type: "result", subtype: "success", is_error: false, result: $r}'
