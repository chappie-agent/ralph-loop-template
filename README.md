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
| `afk-ralph.sh` | Unattended loop with independent review. `./afk-ralph.sh [iterations] [interval]`. |
| `.claude/agents/interviewer.md` | Subagent that interviews you and writes the PRD. |
| `.claude/agents/reviewer.md` | Fresh, independent reviewer subagent. |
| `.claude/hooks/verify.sh` | Stop hook — blocks finishing until build + lint + tests pass. |
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

## How the loop works

Each iteration: read `learnings.txt` → fix open gaps in `review.md` → implement the
highest-priority PRD task → commit → log to `progress.txt`. The **Stop hook** refuses to
let the agent finish while the build, lint, or tests are red. Every Nth loop a **fresh
reviewer** with no memory of the implementation checks the diff against the PRD and writes
gaps to `review.md`. The loop stops when the reviewer reports `COMPLETE`.

## Defaults

- **Loops:** 20 max
- **Review:** every 5 loops
- **Stack:** TypeScript / Next.js / Supabase / Tailwind + shadcn / pnpm / Vercel (see `CLAUDE.md`)

Tune `CLAUDE.md` per project. When the agent makes a recurring mistake, add a one-line
guardrail there instead of growing prose elsewhere.
