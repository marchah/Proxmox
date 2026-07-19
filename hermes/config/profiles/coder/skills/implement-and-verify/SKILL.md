---
name: implement-and-verify
description: Implement ONE coding task on the current git branch, then verify-and-commit it (checks run on the coder-runner LXC; the commit is made for you). Never merge; never run the project's build on this host.
---
# The coder's job

Implement ONE task on the current git branch in this worktree, verify it, and finish. Never merge.

## 0. Read `AGENTS.md` first — this is a pnpm-monorepo clean-architecture GraphQL stack
The repo's architecture is **machine-enforced** by `pnpm check`; code that breaks a rule cannot be
committed. Read `AGENTS.md` at the repo root before editing. The rules you must follow:

- **To add or extend an entity, COPY the canonical module `packages/api/src/modules/deal/`** (its files
  `types.ts` / `repository.ts` / `service.ts` / `schema.pothos.ts` / `service.spec.ts` are the template),
  rename it, then **register it**: build the repo + service in `packages/api/src/services.ts` and import
  its `schema.pothos` in `packages/api/src/schema.ts`.
- **Layer rule (enforced by ESLint boundaries):** resolver → service → repository → db. A resolver reaches
  data ONLY via `ctx.services` — never import `db/` or a repository from a resolver. A service depends on
  repository **port types**, never on `db/`. The web package never imports the api package.
- Validate all inputs with **Zod**; read config only from `common/settings.ts` (never `process.env`
  elsewhere); never `console.*` (use `common/logger.ts`); throw the typed errors from `common/errors.ts`.
- **Test pyramid for new behavior:** add a **unit** `*.spec.ts` for any new service (factory-DI mock style —
  see `modules/deal/service.spec.ts`) **and** an **integration** test exercising the new resolver/query against
  a real test DB (in `packages/api/test/integration/` — see `deal.integration.spec.ts`; run by
  `pnpm test:integration`). Make them meaningful and cover edge cases (empty/null/boundary/error), not just the
  happy path. (Playwright **e2e** is required too once that infra exists — not yet built.)

## 1. Make the change
Edit the files in the worktree directly (read_file / patch / write_file). Keep the change focused and
idiomatic. Do NOT hand-edit the generated files `packages/contract/schema.graphql`,
`packages/web/src/graphql-env.d.ts`, or **Drizzle migrations under `packages/api/drizzle/`** — they are all
regenerated for you in step 2. For a **DB change**, just edit `packages/api/src/db/schema.ts`;
`verify-and-commit` runs `pnpm db:generate` on the runner, which writes the migration `.sql` + updates
`meta/_journal.json` + the snapshot together and commits them. **NEVER hand-write migration SQL** — a `.sql`
without its `_journal.json` entry is inert (Drizzle's migrator skips it → the column never exists → CI
integration tests fail even though checks looked green). If the task body is a set of **PR review comments**
to address, make
exactly those changes on this branch — do NOT resolve the comment threads yourself (the reviewer resolves
them after verifying).

## 2. Verify + commit — everything runs on the coder-runner LXC (CT 122), NOT on this host
NEVER run `pnpm`/`npm`, install scripts, builds, or the project's tests on this host. Run:

    verify-and-commit .

This (a) **regenerates** the committed GraphQL SDL + gql.tada types AND the Drizzle migration, **and
auto-formats the tree with prettier**, all on the coder-runner, syncing it back so nothing is ever stale or
mis-formatted, (b) runs the gate on the coder-runner — `pnpm check` (typecheck + ESLint layer boundaries +
prettier check + unit vitest + schema/codegen drift) **then `pnpm test:integration`** (your integration tests
against a real test DB) — and (c) — only if it all passes — commits your changes (including the regenerated
artifacts) on the branch for you. Exit 0 = green + committed. If it exits non-zero, read the output, fix the
**code**, and run `verify-and-commit .` again until it is green. You do NOT run `git` yourself. Once green it
also files the reviewer task for this branch automatically — do NOT create a review task yourself.

**A red gate is ALWAYS a real code defect** — a type error, an ESLint layer-boundary violation, a failing
unit/integration test, or codegen drift. Because regeneration AND formatting are done for you on the runner,
it is **NEVER** a formatting or generated-artifact problem. So do **NOT** try to run `prettier`, `pnpm`,
`npm`, or `npx` yourself to "fix formatting" — there is no toolchain on this host, it cannot help, and it
just burns a ~3-minute gate cycle. Read the actual error, fix the source file, and re-run `verify-and-commit .`.

## 3. Finish — ONLY after `verify-and-commit` actually committed
**The task is NOT done until `verify-and-commit .` prints a line like
`[verify-and-commit] committed <sha> on <branch>`.** Writing the files is not enough — an uncommitted task
produces nothing. You MUST see that commit line before finishing.

- **If `verify-and-commit .` committed** (you saw the commit line) → call the **`kanban_complete`** tool
  (the tool, NOT a shell command):

      kanban_complete(summary="<what changed>; checks green + committed <sha>",
                      metadata={"files": ["<changed files>"], "checks": "green", "committed": true})

- **If you canNOT get `verify-and-commit .` green** after genuinely trying to fix the errors it reports →
  call **`kanban_block(reason="verify-and-commit still red: <the failing output>")`**.
  **NEVER call `kanban_complete` for a task whose `verify-and-commit` did not commit.** Do not claim a
  success you have not seen — a false "done" with no commit is treated as a failure and re-queued, wasting
  a full cycle.

NEVER end with only a plain-text answer — a worker that exits without `kanban_complete`/`kanban_block` is a
protocol violation and the whole run is discarded.
