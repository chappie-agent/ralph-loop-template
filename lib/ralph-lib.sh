#!/usr/bin/env bash
# ralph-lib.sh — shared helpers for the supervised Ralph loop.
# Sourced by afk-ralph-supervised.sh, ralph-dashboard.sh and the tests.
# Sourcing has no side effects beyond defining functions + default config,
# so it is safe to source from tests.

# --- Config (all env-overridable) ------------------------------------------
: "${RALPH_DIR:=.ralph}"
: "${RALF_TIMEZONE:=Europe/Amsterdam}"
: "${RALF_RESUME_MARGIN_SECONDS:=90}"
: "${RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES:=300}"
: "${RALF_RATE_LIMIT_MAX_RETRIES:=10}"
: "${RALF_REVIEW_EVERY:=5}"
: "${RALF_FULL_REVIEW_EVERY:=20}"

STATE_FILE="$RALPH_DIR/state.json"
STATUS_FILE="$RALPH_DIR/status.json"
LIVE_LOG="$RALPH_DIR/live.log"
RATE_LIMIT_LOG="$RALPH_DIR/rate-limit.log"
LOCK_FILE="$RALPH_DIR/lock"

# Usage-limit patterns (case-insensitive, extended regex). The first is the real
# Claude Code message ("You've hit your session limit · resets 8:40pm (UTC)");
# the rest are defensive for variant / older / future wording.
RALF_LIMIT_PATTERNS='hit your session limit|session limit|usage limit|5-hour limit|limit reached|rate limit|quota exceeded|resets at|will reset at|reset your usage'

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
ralph_detect_limit() {
  printf '%s' "$1" | grep -iqE "$RALF_LIMIT_PATTERNS"
}

# --- Reset-time parsing -----------------------------------------------------
# Echoes the epoch (seconds) the limit resets at, or nothing on failure.
# Handles "resets 8:40pm (UTC)", "resets at 15:00", "will reset at 7pm",
# bare "3pm", and an ISO 8601 timestamp if present. Claude reports UTC.
ralph_parse_reset_epoch() {
  local text="$1" epoch now iso t

  # 1) ISO 8601 (e.g. 2026-06-23T15:00:00Z) — most precise if present.
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

  # Claude reports the reset in UTC; parse in UTC.
  epoch="$(TZ=UTC date -d "$t" '+%s' 2>/dev/null)" || return 1
  [ -z "$epoch" ] && return 1

  # The reset is always in the (near) future when emitted. If the parsed clock
  # time already passed today (e.g. "1:40am" seen at 23:00), it means tomorrow.
  now="$(date '+%s')"
  if [ "$epoch" -lt "$now" ]; then
    local later; later="$(TZ=UTC date -d "$t tomorrow" '+%s' 2>/dev/null)"
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
