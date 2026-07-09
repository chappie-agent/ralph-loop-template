# CLAUDE.md

Persistent project memory. Auto-loaded every session and **every Ralph loop**, so keep it lean — each line is re-read on every iteration and eats context. The per-iteration instructions live in the loop scripts (`ralph-once.sh` / `afk-ralph.sh` / `afk-ralph-supervised.sh`), not here. This file is the *what we build with and how*; `PRD.md` is the *what to build*.

> Tune this file like a guitar. When you watch the agent make a mistake, add a one-line "sign" to **Guardrails** instead of growing prose elsewhere.

## Default stack

- **Language:** TypeScript, `strict: true`. No `any` (use `unknown` + type guards).
- **Framework:** Next.js, App Router only. Never the Pages Router.
- **Backend / DB / Auth:** Supabase (Postgres). Schema changes are **migrations**, never hand-edited. RLS on by default for new tables.
- **UI:** Tailwind CSS + shadcn/ui. No inline style objects, no ad-hoc CSS files.
- **Package manager:** pnpm.
- **Deploy:** Vercel.
- **Avoid:** class components, Redux, raw SQL in app code, fetching secrets into the client.

## Commands

Keep this list current per project.

- `pnpm dev` — local dev server (http://localhost:3000)
- `pnpm build` — production build **and** typecheck (the primary gate)
- `pnpm lint` — ESLint + Prettier
- `pnpm test` — unit / integration tests
- Migrations via the **Supabase MCP** — never edit committed migrations

## Connectors (MCP tools — prefer these over guessing or shelling out)

> **Accounts (why this note exists):** the GitHub and Vercel MCP connectors act *on behalf of a specific account*, so the loop must know which one to use — for this repo that is the **`chappie-agent`** GitHub account (and its matching Vercel account). Authorize those connectors with that account in your own MCP settings. The account **handle** lives here on purpose so the agent picks the right identity; **no e-mail address, token, or credential ever belongs in this file or any commit** — git history is public and permanent. Fill in your own handle per project.

- **Supabase MCP** — all database work. `list_tables` before any schema change; `apply_migration` for DDL (never raw `execute_sql` for schema); `execute_sql` for reads/data; `get_advisors` after every schema change to catch RLS/security gaps; `get_logs` when debugging; `generate_typescript_types` after schema changes.
- **Vercel MCP** — deploy, and read **build + runtime logs** when a deploy or production error needs debugging.
- **GitHub MCP** — branches, PRs, commit/CI status. The loop commits locally (set `RALF_GIT_PUSH=1` to also push each green iteration); use this to open PRs or check CI. All GitHub access goes through this MCP — don't shell out to `gh` or embed tokens. It is configured at **user scope** (`claude mcp add`, lives in `~/.claude.json`), so the token stays **outside the repo** — never commit a GitHub token.
- **Context7 MCP** — before using an unfamiliar or version-sensitive library API, pull current docs instead of guessing.
- **shadcn/ui MCP** — pull components and apply themes via the MCP rather than hand-writing component markup.
- **Browser MCP** — verify UI changes: navigate to the page, interact, confirm, screenshot.

**Rule:** if a dedicated MCP exists for the job, use it. Don't invent APIs or guess library syntax — check Context7 first.

## Committing & pushing (make the right call every loop)

The loop's git history is public and permanent, so each commit/push is a deliberate choice:

- **Never leak a personal e-mail.** Commit author metadata is published forever. Before the first commit, confirm git is set to a GitHub **noreply** address — `git config user.email "<handle>@users.noreply.github.com"` — and enable "Keep my email address private" on GitHub. Never author commits with a personal `@gmail.com`-style address. (Use a handle, never an e-mail, when a file must reference an account.)
- **Commit after each completed task**, all related changes in one **conventional commit** (`feat:` / `fix:` / `chore:` / `refactor:`), and only once the quality gates are green — the Stop hook enforces build + lint + tests.
- **Never commit secrets or personal data.** No `.env*`, no tokens/keys, no real people's e-mails or names in tracked files. When in doubt, leave it out and use an env var.
- **Pushing is opt-in and additive.** Push only when the run is configured for it (`RALF_GIT_PUSH=1`) or you're explicitly asked, and push the current branch (`git push origin HEAD`). **Never `--force` a shared branch** — rewriting published history is a human decision, not the loop's.
- **Prefer the GitHub MCP** for branches, PRs and CI status instead of shelling out with an embedded token; the connector already holds credentials at user scope, outside the repo.

## Code conventions

- Functional components, arrow functions, named exports for shared modules.
- Imports: external libs → internal modules → types.
- Server work in Server Components / server actions; keep client components thin.
- Data access goes through a typed Supabase client — never raw SQL strings in components.
- Co-locate component, styles (Tailwind), and tests.
- Conventional commits: `feat:`, `fix:`, `chore:`, `refactor:`.

## Guardrails (signs for the loop — grow this list over time)

- **One task per loop.** Don't widen scope mid-iteration.
- **Fix open review gaps first.** Read `review.md` at the start of each loop and resolve any listed gaps before picking a new task.
- **Search before assuming.** Never conclude something isn't implemented from a single grep. Use subagents to search first. Think hard.
- **No placeholders.** Full implementations only — never ship stubs or "TODO: implement".
- **Migrations, always.** Every schema change is a Supabase migration; enable RLS on new tables.
- **Secrets stay out of git.** Use Vercel/Supabase env vars; never commit `.env*`.
- **Don't fight unrelated failures silently.** If a check unrelated to your change is red, fix it as part of this increment or add it as a task in `PRD.md`.

## Quality gates (must be green before any commit — enforced by the Stop hook)

1. **`pnpm build` passes** (compiles + typechecks). The hard gate.
2. **`pnpm lint` passes.**
3. **Tests for the changed unit pass.**
4. **UI changes verified in the browser** via the browser MCP: navigate to the page, interact, confirm the change, screenshot if useful.

Never commit broken code. A red build compounds across loops. *(The Stop hook in `.claude/hooks/verify.sh` enforces gates 1–3; make sure it runs these same `pnpm` commands.)*

> **The gate only proves compile + lint + *unit* tests.** It does **not** exercise runtime/integration behaviour — API routes hitting the real DB, RLS, ORM/PostgREST queries, external API calls. Unit tests that mock those stay green while the live path is broken (a mocked test will never catch an ambiguous DB embed, a wrong env var, or an auth failure). For any task that touches the DB, an external API, or a real request path, **verify it live** before trusting "done": run the real call (build + start + `curl`, or the relevant MCP) and confirm the effect. The reviewer subagent reviews the diff, not the running system — runtime is yours to check.

## Files (source of truth — context is fresh each loop)

- `PRD.md` — what to build. The agreed task list and source of truth. The loop picks the top open item.
- `review.md` — open gaps from the independent reviewer. Resolve these first each loop. `NO GAPS` means clear.
- `progress.txt` — append-only log of what each iteration did.
- `learnings.txt` — reusable patterns and gotchas. **Read this first each loop.**
- `git` history — what already happened.

## Self-improvement

When you learn a **reusable** pattern or gotcha, append it briefly to `learnings.txt` (and to a module-level `CLAUDE.md` if it's module-specific). Keep additions general and short. Do not dump task-specific detail or status reports here — status goes to `progress.txt`, review findings go to `review.md`.
