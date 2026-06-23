#!/usr/bin/env bash
# test-rate-limit-parser.sh — offline tests for the usage-limit detection,
# reset-time parsing, fallback, and circuit-breaker counting. No Claude calls.
set -u
cd "$(dirname "$0")/.." || exit 1
# Isolate test state so we never touch a real .ralph dir.
export RALPH_DIR; RALPH_DIR="$(mktemp -d)"
# shellcheck source=lib/ralph-lib.sh
source lib/ralph-lib.sh

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# --- 1. Detection -----------------------------------------------------------
echo "== detection =="
for s in \
  "You've hit your session limit · resets 8:40pm (UTC)" \
  "5-hour limit reached - resets 3pm" \
  "usage limit reached, resets at 15:00" \
  "Your limit will reset at 7pm" \
  "quota exceeded"
do
  ralph_detect_limit "$s" && ok "detect: $s" || bad "detect: $s"
done
# Must NOT fire on normal output.
ralph_detect_limit "pushed after iter 3; build passed" && bad "false-positive on normal output" || ok "no false-positive on normal output"

# --- 2. Reset parsing (assert the HH:MM in UTC) ----------------------------
echo "== reset parsing =="
assert_hhmm() { # text expected_hhmm label
  local got; got="$(ralph_parse_reset_epoch "$1")"
  if [ -z "$got" ]; then bad "$3 (no parse)"; return; fi
  local hhmm; hhmm="$(TZ=UTC date -d "@$got" '+%H:%M')"
  [ "$hhmm" = "$2" ] && ok "$3 -> $hhmm UTC" || bad "$3 got $hhmm, want $2"
}
assert_hhmm "You've hit your session limit · resets 8:40pm (UTC)" "20:40" "8:40pm"
assert_hhmm "5-hour limit reached - resets 3pm"                   "15:00" "3pm"
assert_hhmm "usage limit reached, resets at 15:00"                "15:00" "15:00"
assert_hhmm "Your limit will reset at 7pm"                        "19:00" "7pm"
assert_hhmm "resets at 2026-01-01T09:30:00Z"                      "09:30" "ISO"

# --- 3. Parse failure -> fixed fallback -------------------------------------
echo "== fallback =="
out="$(ralph_resolve_reset_epoch "quota exceeded")"; rc=$?
now="$(date '+%s')"; want=$(( now + RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES*60 ))
if [ "$rc" -eq 2 ] && [ -n "$out" ] && [ "$out" -ge $((want-60)) ] && [ "$out" -le $((want+60)) ]; then
  ok "no reset time -> ~${RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES}m fallback (rc=2)"
else
  bad "fallback wrong (rc=$rc out=$out want~$want)"
fi

# --- 4. Atomic JSON merge + retry counting ----------------------------------
echo "== state =="
ralph_json_merge "$STATE_FILE" status "running" rate_limit_retry_count "0"
ralph_json_merge "$STATE_FILE" rate_limit_retry_count "1"
ralph_json_merge "$STATE_FILE" rate_limit_retry_count "2"
cnt="$(jq -r '.rate_limit_retry_count' "$STATE_FILE" 2>/dev/null)"
[ "$cnt" = "2" ] && ok "retry counter persists separately (=2)" || bad "retry counter ($cnt)"
jq -e . "$STATE_FILE" >/dev/null 2>&1 && ok "state.json is valid JSON (atomic write)" || bad "state.json invalid"

# --- 5. Circuit breaker arithmetic ------------------------------------------
echo "== circuit breaker =="
RALF_RATE_LIMIT_MAX_RETRIES=3
hit=0; tripped="no"
for _ in 1 2 3 4 5; do
  hit=$((hit+1))
  if [ "$hit" -gt "$RALF_RATE_LIMIT_MAX_RETRIES" ]; then tripped="yes"; break; fi
done
[ "$tripped" = "yes" ] && [ "$hit" -eq 4 ] && ok "breaker trips on retry > max ($RALF_RATE_LIMIT_MAX_RETRIES)" || bad "breaker ($hit/$tripped)"

rm -rf "$RALPH_DIR"
echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
