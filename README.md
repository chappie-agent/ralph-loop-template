# Ralph Loop Template

A self-improving autonomous coding loop for Claude Code. Clone this for any new project.

## What's in here

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Persistent project memory — stack, conventions, guardrails, quality gates. Re-read every loop. |
| `PRD.md` | What to build. Filled by the kick-off interview. The loop picks the top open task. |
| `progress.txt` | Append-only log of what each iteration did. |
| `learnings.txt` | Reusable patterns and gotchas. Read first each loop. |
| `review.md` | Open gaps from the independent reviewer. `NO GAPS` = clear. |
| `kick-off.sh` | Start a new project: asks what you want, runs a deep interview, writes `PRD.md`. |
| `ralph-once.sh` | Run one implementation loop (human in the loop). |
| `afk-ralph.sh` | Simple unattended loop with independent review. `./afk-ralph.sh [iterations] [interval]`. |
| `afk-ralph-supervised.sh` | **Production AFK loop** — usage-limit aware, auto-resume, checkpointed, circuit-broken, logged. `./afk-ralph-supervised.sh [iterations]`. |
| `ralph-dashboard.sh` | Live control panel (tmux panes, or a single-pane fallback without tmux). |
| `lib/ralph-lib.sh` | Shared helpers (result classification, limit detection, reset parsing, atomic state, locking, waiting). |
| `scripts/test-rate-limit-parser.sh` | Offline tests for detection / parsing / classification / fallback / breaker. |
| `scripts/fake-claude.sh` | A `claude` stand-in to test the whole resume loop offline (no tokens). |
| `.claude/agents/interviewer.md` | Subagent that interviews you and writes the PRD. |
| `.claude/agents/reviewer.md` | Fresh, independent reviewer subagent. |
| `.claude/hooks/verify.sh` | Stop hook — blocks finishing while build/lint/tests are red (max 3 blocks per stop, then fails open). |
| `.claude/skills/kickoff/SKILL.md` | `/kickoff` skill inside a Claude session. |

## Quick start

```bash
# 1. Define what to build (deep interview → PRD.md)
./kick-off.sh

# 2. Try one loop by hand to get a feel for it
./ralph-once.sh

# 3. Let it run unattended (20 loops, review every 5)
./afk-ralph.sh 20 5
```

## Requirements

- **No Docker.** Nothing in the template shells out to Docker — every run is a plain
  `claude -p` on your machine. Sandboxing is opt-in: point `RALF_CLAUDE_BIN` at a wrapper
  script if you want one.
- **bash, git, jq.** The loop refuses to start without them (clear preflight error).
- **GNU date.** Linux has it; on macOS: `brew install coreutils` (the lib picks up `gdate`
  automatically). `flock` is optional — without it a portable mkdir-lock is used.
- **Headless permissions.** `claude -p` can't show permission prompts, and `acceptEdits`
  only covers file edits — NOT `git commit` or `pnpm`. The `permissions.allow` rules in
  `.claude/settings.json` are what make the loop able to commit at all. If you strip that
  file, the loop edits files but never commits (the stall breaker will catch it and stop).

## How the loop works

Each iteration: read `learnings.txt` → fix open gaps in `review.md` → implement the
highest-priority PRD task → commit → log to `progress.txt`. The **Stop hook** blocks the
agent from finishing while the build, lint, or tests are red — up to 3 times per stop,
then it fails open so a hard-stuck gate can never wedge a session. Every Nth loop a **fresh
reviewer** with no memory of the implementation checks the diff against the PRD and writes
gaps to `review.md`. The loop stops when the reviewer reports `COMPLETE`.

## Defaults

- **Loops:** 20 max
- **Review:** every 5 loops
- **Stack:** TypeScript / Next.js / Supabase / Tailwind + shadcn / pnpm / Vercel (see `CLAUDE.md`)

Tune `CLAUDE.md` per project. When the agent makes a recurring mistake, add a one-line
guardrail there instead of growing prose elsewhere.

## Supervised mode (long unattended runs)

`afk-ralph.sh` is fine for short runs, but a multi-hour run will hit Claude's usage limit
and die. `afk-ralph-supervised.sh` survives that and more:

```bash
./afk-ralph-supervised.sh 50          # 50 iterations, resilient
./ralph-dashboard.sh                  # watch it live (separate terminal)
```

**What it adds over the simple loop**

- **JSON-based run classification.** Every run uses `--output-format json`; the result
  envelope decides success / usage-limit / failure. Limit patterns are only matched against
  *failed* runs — a task summary like "implemented rate limiting" can never fake a usage
  limit (with prose matching it triggered a phantom multi-hour sleep).
- **Auto-resume without burning tokens.** On a usage limit it parses the reset time
  (`…|<epoch>`, ISO 8601, or a clock time — UTC when marked, else `RALF_TIMEZONE`), sleeps
  locally past it (plus a margin), then re-issues the **same** `claude -p` call. If the
  reset time can't be parsed it waits a fixed fallback window.
- **Three circuit breakers, never an infinite loop.**
  `failed_rate_limit_max_retries` after `RALF_RATE_LIMIT_MAX_RETRIES` limit retries;
  `failed_consecutive_failures` after `RALF_MAX_CONSECUTIVE_FAILURES` non-limit failures
  (CLI crash, denied tools, max-turns) with a short backoff between attempts; and
  `stalled_no_progress` after `RALF_MAX_NO_PROGRESS` implement iterations that produced
  **no new commit** (a wedged task — or `git commit` being denied — looks exactly like this).
- **Checkpoint / state** in `.ralph/` (git-ignored): `state.json` (full resume state,
  atomic writes), `status.json` (compact, for the dashboard), `live.log` (extracted
  assistant text), `raw.log` (raw envelopes, for post-mortems), `rate-limit.log`, and a
  lock so two runners can't clash (flock, or a portable mkdir fallback).
- **Token-efficient tiered review.** A mini self-check rides in every implement prompt; a
  cheap **diff** review runs every `RALF_REVIEW_EVERY` loops; a **full** PRD review every
  `RALF_FULL_REVIEW_EVERY`; plus a final review. The reviewer never reads the whole context
  unless it's a full pass.

**Environment variables**

| Var | Default | Meaning |
|-----|---------|---------|
| `RALF_TIMEZONE` | `Europe/Amsterdam` | Timezone for reset clock-times without an explicit UTC marker. |
| `RALF_RESUME_MARGIN_SECONDS` | `90` | Extra wait after the parsed reset, to be safe. |
| `RALF_RATE_LIMIT_FALLBACK_WAIT_MINUTES` | `300` | Wait when the reset time can't be parsed. |
| `RALF_RATE_LIMIT_MAX_RETRIES` | `10` | Usage-limit circuit-breaker threshold. |
| `RALF_MAX_CONSECUTIVE_FAILURES` | `3` | Non-limit failure breaker (crash, denied tools, …). |
| `RALF_FAILURE_BACKOFF_SECONDS` | `60` | Wait between failure retries. |
| `RALF_MAX_NO_PROGRESS` | `3` | Stall breaker: implement loops without a new commit. |
| `RALF_REVIEW_EVERY` | `5` | Diff review cadence. |
| `RALF_FULL_REVIEW_EVERY` | `20` | Full PRD review cadence. |
| `RALF_MAX_TURNS` | *(unset)* | If set, passed as `--max-turns` (caps a runaway iteration). |
| `RALF_GIT_PUSH` | `0` | `1` = `git push origin HEAD` after every committing iteration. |
| `RALF_CLAUDE_BIN` | `claude` | The Claude binary — must support `--output-format json` (`scripts/fake-claude.sh` does). |
| `RALF_PERMISSION_MODE` | `acceptEdits` | Passed to `claude --permission-mode`. |

**Resume model.** Because this template drives Claude non-interactively (`claude -p`), a
"resume" is just the same call again after the wait — there is no interactive session to
`continue`. If you wire this into an interactive setup, override the implement step yourself.

**Dashboard.** `./ralph-dashboard.sh` opens a tmux control panel (runner · live log ·
`status.json` · git/progress) when tmux is installed, and falls back to a single refreshing
status pane otherwise. `--run [N]` (tmux only) also launches the runner in a pane.

**Testing.** `bash scripts/test-rate-limit-parser.sh` checks detection, every reset format,
JSON classification, the review promise, the fallback, atomic state, and the breaker — all
offline. To exercise the **full** resume loop without a real limit (the fake emits the same
JSON envelopes as the real CLI; `FAKE_COMMIT=1` makes empty commits so the stall breaker
sees progress):

```bash
RALF_CLAUDE_BIN=./scripts/fake-claude.sh RALF_RESUME_MARGIN_SECONDS=1 \
FAKE_RESET_SECONDS=2 FAKE_COMMIT=1 ./afk-ralph-supervised.sh 2
```

The only thing that still needs a one-off **manual** check is a real usage-reset (the
message format can drift between Claude Code versions; the patterns in `lib/ralph-lib.sh`
are easy to extend, and an unparseable message safely falls back to the fixed wait).

**Troubleshooting.** `Another supervised runner already holds .ralph/lock` → a previous run
is still active; remove `.ralph/lock` (and `.ralph/lock.d` on machines without flock) if
you're sure none is running. Status `stalled_no_progress` → iterations stopped committing:
usually a wedged task, or `git commit` being denied (check `permissions.allow` in
`.claude/settings.json`). Status `failed_consecutive_failures` → the CLI itself is failing;
inspect `.ralph/raw.log` for the raw envelopes. Watch `.ralph/rate-limit.log` to see every
wait/retry. `jq . .ralph/state.json` shows the exact resume state.
