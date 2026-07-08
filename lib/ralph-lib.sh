#!/usr/bin/env bash
# ralph-lib.sh — shared helpers for the supervised Ralph loop.
# Sourced by afk-ralph-supervised.sh, ralph-dashboard.sh and the tests.
# Sourcing has no side effects beyond defining functions + default config
# (and a gdate shim when GNU date is missing), so it is safe to source
# from tests.

# --- Config (all env-overridable) ------------------------------------------
: "${RALPH_DIR:=.ralph}"
: "${RALF_TIMEZONE:=Europe/Amsterdam}"
: "${RALF_RESUME_MARGIN_SECONDS:=90}"
: "${RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES:=300}"
: "${RALF_RATE_LIMIT_MAX_RETRIES:=10}"
: "${RALF_REVIEW_EVERY:=5}"
: "${RALF_FULL_REVIEW_EVERY:=20}"
: "${RALF_MAX_CONSECUTIVE_FAILURES:=3}"
: "${RALF_FAILURE_BACKOFF_SECONDS:=60}"
: "${RALF_MAX_NO_PROGRESS:=3}"

STATE_FILE="$RALPH_DIR/state.json"
STATUS_FILE="$RALPH_DIR/status.json"
LIVE_LOG="$RALPH_DIR/live.log"
RAW_LOG="$RALPH_DIR/raw.log"
RATE_LIMIT_LOG="$RALPH_DIR/rate-limit.log"
LOCK_FILE="$RALPH_DIR/lock"

# Usage-limit patterns (case-insensitive, extended regex). Deliberately broad —
# but they are ONLY ever applied to FAILED runs (error envelope, or no envelope
# at all). Never match these against a successful result text: a normal task
# summary like "implemented rate limiting" would read as a usage limit and
# trigger a phantom multi-hour sleep.
RALF_LIMIT_PATTERNS='hit your session limit|session limit|usage limit|5-hour limit|limit reached|rate limit|quota exceeded|resets at|will reset at|reset your usage'

# --- GNU date ---------------------------------------------------------------
# The reset/wait logic needs GNU `date -d`. On macOS/BSD, fall back to
# coreutils' gdate when installed (brew install coreutils).
if ! date -u -d '@0' '+%s' >/dev/null 2>&1; then
  if command -v gdate >/dev/null 2>&1 && gdate -u -d '@0' '+%s' >/dev/null 2>&1; then
    date() { command gdate "$@"; }
  fi
fi

# --- Preflight ----------------------------------------------------------------
# Verify runtime dependencies up front with actionable messages, instead of
# failing halfway through a run with something cryptic. Returns 1 (after
# listing every problem) when the loop cannot run here.
ralph_preflight() {
  local bad=0
  command -v jq >/dev/null 2>&1 || { echo "ralph: jq is required (brew install jq / apt install jq)." >&2; bad=1; }
  command -v git >/dev/null 2>&1 || { echo "ralph: git is required." >&2; bad=1; }
  if ! date -u -d '@0' '+%s' >/dev/null 2>&1; then
    echo "ralph: GNU date is required — on macOS: brew install coreutils (provides gdate)." >&2
    bad=1
  fi
  return "$bad"
}

# --- Single-runner lock -------------------------------------------------------
# flock when available; otherwise a portable mkdir lock with stale-PID takeover
# (macOS ships without flock). Call ralph_release_lock from your EXIT trap —
# it is a no-op for the flock variant (the fd releases itself on exit).
ralph_acquire_lock() {
  mkdir -p "$RALPH_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || return 1
    RALPH_LOCK_MODE="flock"
    return 0
  fi
  local dir="$LOCK_FILE.d" oldpid
  if ! mkdir "$dir" 2>/dev/null; then
    oldpid="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
      return 1  # live runner holds it
    fi
    rm -rf "$dir"  # stale lock (crashed runner) — take over
    mkdir "$dir" 2>/dev/null || return 1
  fi
  echo "$$" > "$dir/pid"
  RALPH_LOCK_MODE="dir"
  return 0
}

ralph_release_lock() {
  [ "${RALPH_LOCK_MODE:-}" = "dir" ] && rm -rf "$LOCK_FILE.d"
  return 0
}

# --- Logging ----------------------------------------------------------------
ralph_log() {
  mkdir -p "$RALPH_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LIVE_LOG"
}

# --- Atomic JSON merge ------------------------------------------------------
# Usage: ralph_json_merge FILE key val [key val ...]
# Sets each key to its (string) value and writes atomically (tmp + mv), so a
# reader never sees a half-written file.
ralph_json_merge() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || echo '{}' > "$file"
  local tmp; tmp="$(mktemp "${file}.XXXXXX")" || return 1
  local jq_args=() filter='.'
  while [ "$#" -ge 2 ]; do
    local k="$1" v="$2"; shift 2
    jq_args+=(--arg "v_${k}" "$v")
    filter="${filter} | .[\"${k}\"] = \$v_${k}"
  done
  if jq "${jq_args[@]}" "$filter" "$file" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"; return 1
  fi
}

# --- Usage-limit detection --------------------------------------------------
# Returns 0 (true) when the given text contains a usage/rate-limit signal.
# Only call this on FAILED output (see RALF_LIMIT_PATTERNS above).
ralph_detect_limit() {
  printf '%s' "$1" | grep -iqE "$RALF_LIMIT_PATTERNS"
}

# --- Output classification ---------------------------------------------------
# The loop runs `claude -p --output-format json`, which ends in a result
# envelope: {"type":"result","is_error":false,"result":"…",…}. Classify raw
# run output into RALPH_CLS:
#   success — envelope present, is_error false
#   limit   — a failed (or envelope-less) run whose text matches the limit
#             patterns
#   failure — anything else: CLI crash/missing, denied tools, max-turns, …
# The assistant's text (or the raw output when no envelope was found) is left
# in RALPH_LAST_RESULT for logging and promise-checking.
#
# NOTE: this sets globals instead of echoing so callers don't need a command
# substitution (a subshell would lose RALPH_LAST_RESULT).
RALPH_CLS=""
RALPH_LAST_RESULT=""

# Echo the result envelope found in $1, if any: the whole output when it is a
# single JSON document, else the last line that parses as an envelope.
ralph_extract_result_json() {
  local raw="$1" line found=""
  if printf '%s' "$raw" | jq -e 'type == "object" and has("is_error")' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c .
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      *'"is_error"'*)
        printf '%s' "$line" | jq -e 'type == "object" and has("is_error")' >/dev/null 2>&1 && found="$line" ;;
    esac
  done <<< "$raw"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

ralph_classify_output() {
  local raw="$1" envelope is_error text
  RALPH_CLS="failure"
  RALPH_LAST_RESULT="$raw"
  if ! envelope="$(ralph_extract_result_json "$raw")"; then
    # No envelope: the CLI crashed, is missing, or printed a bare limit
    # message outside the envelope (older CLI versions).
    if ralph_detect_limit "$raw"; then RALPH_CLS="limit"; fi
    return 0
  fi
  is_error="$(printf '%s' "$envelope" | jq -r '.is_error // false')"
  text="$(printf '%s' "$envelope" | jq -r '.result // .error // empty')"
  [ -n "$text" ] && RALPH_LAST_RESULT="$text"
  if [ "$is_error" = "true" ]; then
    if ralph_detect_limit "$raw"; then RALPH_CLS="limit"; fi
  else
    RALPH_CLS="success"
  fi
  return 0
}

# --- Review promise -----------------------------------------------------------
# True when the reviewer put the promise tag ALONE on the final non-empty line.
# Grepping the whole reply would also match prose that merely mentions the tag
# ("…so I will not output <promise>COMPLETE</promise>").
ralph_review_complete() {
  printf '%s\n' "$1" | awk 'NF { last = $0 } END {
    gsub(/^[ \t]+|[ \t\r]+$/, "", last)
    exit (last == "<promise>COMPLETE</promise>") ? 0 : 1
  }'
}

# --- Reset-time parsing -----------------------------------------------------
# Echoes the epoch (seconds) the limit resets at, or nothing on failure.
# Handles, in order of precision:
#   0) the legacy headless format "…usage limit reached|1735689600" (epoch),
#   1) an ISO 8601 timestamp (e.g. 2026-06-23T15:00:00Z),
#   2) a clock time: "resets 8:40pm (UTC)", "resets at 15:00", bare "3pm".
# Clock times are parsed in UTC when the text mentions UTC, otherwise in
# RALF_TIMEZONE (CLI versions differ in whether they report local or UTC).
ralph_parse_reset_epoch() {
  local text="$1" epoch now iso t tz

  # 0) "…|<epoch>" — exact, if present.
  epoch="$(printf '%s' "$text" | grep -oE '\|[0-9]{10}' | head -1 | tr -d '|')"
  if [ -n "$epoch" ]; then printf '%s' "$epoch"; return 0; fi

  # 1) ISO 8601 — most precise textual form.
  iso="$(printf '%s' "$text" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?' | head -1)"
  if [ -n "$iso" ]; then
    epoch="$(date -d "$iso" '+%s' 2>/dev/null)" && [ -n "$epoch" ] && { printf '%s' "$epoch"; return 0; }
  fi

  # 2) A clock time, preferably the one following a "reset" word.
  t="$(printf '%s' "$text" \
        | grep -ioE '(reset[s]?|will reset)([[:space:]]+at)?[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' \
        | head -1 \
        | grep -ioE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | tail -1)"
  # Fallback: any am/pm or HH:MM token in the text.
  [ -z "$t" ] && t="$(printf '%s' "$text" | grep -ioE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)|[0-2]?[0-9]:[0-9]{2}' | head -1)"
  t="$(printf '%s' "$t" | tr -d '[:space:]')"
  [ -z "$t" ] && return 1

  tz="$RALF_TIMEZONE"
  printf '%s' "$text" | grep -qi 'utc' && tz="UTC"

  epoch="$(TZ="$tz" date -d "$t" '+%s' 2>/dev/null)" || return 1
  [ -z "$epoch" ] && return 1

  # The reset is always in the (near) future when emitted. If the parsed clock
  # time already passed today (e.g. "1:40am" seen at 23:00), it means tomorrow.
  now="$(date '+%s')"
  if [ "$epoch" -lt "$now" ]; then
    local later; later="$(TZ="$tz" date -d "$t tomorrow" '+%s' 2>/dev/null)"
    [ -n "$later" ] && epoch="$later" || epoch=$((epoch + 86400))
  fi
  printf '%s' "$epoch"
}

# --- Wait helpers -----------------------------------------------------------
# Sleep (no model calls) until the given epoch + margin, in short chunks so the
# status file / dashboard stay responsive and Ctrl-C is honoured promptly.
ralph_wait_until_epoch() {
  local target=$(( $1 + RALF_RESUME_MARGIN_SECONDS ))
  local now secs chunk
  now="$(date '+%s')"; secs=$(( target - now ))
  [ "$secs" -lt 0 ] && secs=0
  ralph_log "Sleeping ${secs}s (until $(date -d "@$target" '+%H:%M:%S'), incl ${RALF_RESUME_MARGIN_SECONDS}s margin) — no tokens spent."
  while [ "$secs" -gt 0 ]; do
    chunk=$(( secs > 20 ? 20 : secs ))
    sleep "$chunk"; secs=$(( secs - chunk ))
  done
}

# Resolve how long to wait after a limit: parse the reset, else fall back to a
# fixed window. Echoes the target epoch (already including nothing extra — the
# margin is added by ralph_wait_until_epoch).
ralph_resolve_reset_epoch() {
  local text="$1" epoch
  epoch="$(ralph_parse_reset_epoch "$text")"
  if [ -n "$epoch" ]; then
    printf '%s' "$epoch"; return 0
  fi
  # Parsing failed → conservative fixed fallback.
  printf '%s' "$(( $(date '+%s') + RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES * 60 ))"
  return 2
}
