#!/usr/bin/env bash
# ralph-dashboard.sh — observability for the supervised Ralph loop.
#
#   With tmux:    a 4-pane control panel (runner | live log | status | git/progress).
#   Without tmux: a single-pane live status view (read-only; run the loop in
#                 another terminal). Mirrors frankbria/ralph-claude-code's monitor,
#                 kept lean.
#
# Usage:
#   ./ralph-dashboard.sh            # monitor only (works with or without tmux)
#   ./ralph-dashboard.sh --run [N]  # tmux only: also launch the runner for N iters
set -u
cd "$(dirname "$0")" || exit 1
source lib/ralph-lib.sh

RUN_LOOP=0; ITERS=""
[ "${1:-}" = "--run" ] && { RUN_LOOP=1; ITERS="${2:-}"; }

# ---------------------------------------------------------------- tmux mode --
if command -v tmux >/dev/null 2>&1; then
  S="ralph"
  # Never kill an existing session here — it may contain a RUNNING loop
  # (started with --run earlier). Attach instead; kill explicitly if needed.
  if tmux has-session -t "$S" 2>/dev/null; then
    echo "tmux session '$S' already exists — attaching. (Kill it first with: tmux kill-session -t $S)"
    exec tmux attach -t "$S"
  fi
  if [ "$RUN_LOOP" = "1" ]; then
    tmux new-session -d -s "$S" -n loop "./afk-ralph-supervised.sh $ITERS; echo; echo '[runner stopped — press a key]'; read -r _"
  else
    tmux new-session -d -s "$S" -n loop "echo 'Monitor only. Start the loop with ./afk-ralph-supervised.sh in another pane/terminal.'; exec bash"
  fi
  tmux split-window -h -t "$S" "touch '$LIVE_LOG'; tail -f '$LIVE_LOG'"
  tmux split-window -v -t "$S".0 "watch -n2 -t 'jq . \"$STATUS_FILE\" 2>/dev/null || echo no status yet'"
  tmux split-window -v -t "$S".1 "watch -n3 -t 'git -C \"$PWD\" status -s; echo; tail -n 6 progress.txt 2>/dev/null; echo; echo review:; head -c 300 review.md 2>/dev/null'"
  tmux select-layout -t "$S" tiled
  tmux attach -t "$S"
  exit 0
fi

# ---------------------------------------------------- single-pane fallback --
echo "tmux not found — single-pane monitor (Ctrl-C to quit)."
trap 'printf "\033[?25h"; echo; exit 0' INT TERM
printf '\033[?25l'  # hide cursor
while true; do
  clear
  echo "================ RALPH SUPERVISED MONITOR  $(date '+%H:%M:%S') ================"
  if [ -f "$STATUS_FILE" ]; then
    jq -r '"status      : \(.status // "?")
loop        : \(.loop // "?")
task        : \(.task // "?")
retries     : \(.retries // "0")
failures    : \(.failures // "0")
no_progress : \(.no_progress // "0")
reset_at    : \(.reset_at // "-")
commit      : \(.commit // "-")
updated     : \(.updated // "-")"' "$STATUS_FILE" 2>/dev/null || echo "(unreadable status.json)"
  else
    echo "No .ralph/status.json yet — is the loop running?"
  fi
  echo "------------------------------ recent activity ------------------------------"
  if [ -f "$LIVE_LOG" ]; then tail -n 12 "$LIVE_LOG"; else echo "(no live.log yet)"; fi
  echo "------------------------------ git -----------------------------------------"
  git -C "$PWD" status -s 2>/dev/null | head -6
  sleep 2
done
