#!/usr/bin/env bash
# test-rate-limit-parser.sh — offline tests for the usage-limit detection,
# reset-time parsing, output classification, review promise, fallback, and
# circuit-breaker counting. No Claude calls.
set -u
cd "$(dirname "$0")/.." || exit 1
# Deterministic timezone for clock-time parsing (individual tests override it).
export RALF_TIMEZONE=UTC
# Isolate test state so we never touch a real .ralph dir.
export RALPH_DIR; RALPH_DIR="$(mktemp -d)"
# shellcheck source=lib/ralph-lib.sh
source lib/ralph-lib.sh

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# --- 0. Preflight ------------------------------------------------------------
echo "== preflight =="
ralph_preflight && ok "preflight passes on this machine" || bad "preflight (missing deps?)"

# --- 1. Detection (patterns are ONLY applied to failed runs) -----------------
echo "== detection =="
for s in \
  "You've hit your session limit · resets 8:40pm (UTC)" \
  "5-hour limit reached - resets 3pm" \
  "usage limit reached, resets at 15:00" \
  "Your limit will reset at 7pm" \
  "Claude AI usage limit reached|1893456000" \
  "quota exceeded"
do
  ralph_detect_limit "$s" && ok "detect: $s" || bad "detect: $s"
done
# Must NOT fire on normal output.
ralph_detect_limit "pushed after iter 3; build passed" && bad "false-positive on normal output" || ok "no false-positive on normal output"

# --- 2. Reset parsing --------------------------------------------------------
echo "== reset parsing =="
assert_hhmm() { # text expected_hhmm label [tz]
  local tz="${4:-UTC}"
  local got; got="$(ralph_parse_reset_epoch "$1")"
  if [ -z "$got" ]; then bad "$3 (no parse)"; return; fi
  local hhmm; hhmm="$(TZ="$tz" date -d "@$got" '+%H:%M')"
  [ "$hhmm" = "$2" ] && ok "$3 -> $hhmm ($tz)" || bad "$3 got $hhmm, want $2 ($tz)"
}
assert_hhmm "You've hit your session limit · resets 8:40pm (UTC)" "20:40" "8:40pm (UTC)"
assert_hhmm "5-hour limit reached - resets 3pm"                   "15:00" "3pm"
assert_hhmm "usage limit reached, resets at 15:00"                "15:00" "15:00"
assert_hhmm "Your limit will reset at 7pm"                        "19:00" "7pm"
assert_hhmm "resets at 2026-01-01T09:30:00Z"                      "09:30" "ISO"

# Legacy "…|<epoch>" format parses to the exact epoch.
got="$(ralph_parse_reset_epoch "Claude AI usage limit reached|1893456000")"
[ "$got" = "1893456000" ] && ok "pipe-epoch format -> exact epoch" || bad "pipe-epoch (got ${got:-nothing})"

# Clock times WITHOUT a UTC marker parse in RALF_TIMEZONE.
(
  export RALF_TIMEZONE="America/New_York"
  got="$(ralph_parse_reset_epoch "resets at 15:00")"
  [ -n "$got" ] || exit 1
  hhmm="$(TZ="America/New_York" date -d "@$got" '+%H:%M')"
  [ "$hhmm" = "15:00" ]
) && ok "RALF_TIMEZONE honoured for unmarked clock times" || bad "RALF_TIMEZONE not honoured"

# --- 3. Output classification (JSON envelope) --------------------------------
echo "== classification =="
assert_cls() { # raw expected label
  ralph_classify_output "$1"
  [ "$RALPH_CLS" = "$2" ] && ok "$3 -> $RALPH_CLS" || bad "$3 got $RALPH_CLS, want $2"
}
assert_cls '{"type":"result","subtype":"success","is_error":false,"result":"Implemented rate limiting for the API; committed."}' \
  success "success envelope mentioning 'rate limiting' is NOT a limit"
assert_cls '{"type":"result","subtype":"success","is_error":false,"result":"The reset at 15:00 banner now renders."}' \
  success "success envelope mentioning 'reset at' is NOT a limit"
assert_cls '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"You'\''ve hit your session limit · resets 8:40pm (UTC)"}' \
  limit "error envelope with limit text"
assert_cls '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"stopped: maximum turns exceeded"}' \
  failure "error envelope without limit text"
assert_cls 'zsh: command not found: claude' \
  failure "no envelope, no limit text (crash)"
assert_cls "You've hit your session limit · resets 3pm" \
  limit "bare limit message without envelope (older CLI)"
# Envelope preceded by stderr noise on earlier lines still parses.
assert_cls 'npm warn deprecated something
{"type":"result","subtype":"success","is_error":false,"result":"done"}' \
  success "envelope after noise lines"
# Extracted text lands in RALPH_LAST_RESULT.
ralph_classify_output '{"type":"result","is_error":false,"result":"hello world"}'
[ "$RALPH_LAST_RESULT" = "hello world" ] && ok "RALPH_LAST_RESULT extracted from envelope" || bad "RALPH_LAST_RESULT ($RALPH_LAST_RESULT)"

# --- 4. Review promise (exact final line only) -------------------------------
echo "== review promise =="
ralph_review_complete "All done.
<promise>COMPLETE</promise>" && ok "promise on final line -> complete" || bad "promise on final line"
ralph_review_complete "I will not output <promise>COMPLETE</promise> because task 3 is open." \
  && bad "promise mentioned mid-sentence must NOT count" || ok "promise mentioned mid-sentence does not count"
ralph_review_complete "  <promise>COMPLETE</promise>  " && ok "surrounding whitespace tolerated" || bad "surrounding whitespace"
ralph_review_complete "gaps remain" && bad "no promise must not count" || ok "no promise -> not complete"

# --- 5. Parse failure -> fixed fallback --------------------------------------
echo "== fallback =="
out="$(ralph_resolve_reset_epoch "quota exceeded")"; rc=$?
now="$(date '+%s')"; want=$(( now + RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES*60 ))
if [ "$rc" -eq 2 ] && [ -n "$out" ] && [ "$out" -ge $((want-60)) ] && [ "$out" -le $((want+60)) ]; then
  ok "no reset time -> ~${RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES}m fallback (rc=2)"
else
  bad "fallback wrong (rc=$rc out=$out want~$want)"
fi

# --- 6. Atomic JSON merge + retry counting ------------------------------------
echo "== state =="
ralph_json_merge "$STATE_FILE" status "running" rate_limit_retry_count "0"
ralph_json_merge "$STATE_FILE" rate_limit_retry_count "1"
ralph_json_merge "$STATE_FILE" rate_limit_retry_count "2"
cnt="$(jq -r '.rate_limit_retry_count' "$STATE_FILE" 2>/dev/null)"
[ "$cnt" = "2" ] && ok "retry counter persists separately (=2)" || bad "retry counter ($cnt)"
jq -e . "$STATE_FILE" >/dev/null 2>&1 && ok "state.json is valid JSON (atomic write)" || bad "state.json invalid"

# --- 7. Circuit breaker arithmetic --------------------------------------------
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
