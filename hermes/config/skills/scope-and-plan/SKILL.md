---
name: scope-and-plan
description: Scope a NEW project or epic from a rough idea + feature ideas — ask clarifying questions, then write a plan (docs/PLAN.md) and a machine-readable feature backlog, and finalize it (opens a plan PR + files blocked coder tasks the autonomous loop will build). Use when the user asks to plan/scope a project or a batch of features in the #planning channel.
---
# Scope & plan a project → seed the coder↔reviewer loop

You are the PROJECT PLANNER. The user gives you a project idea + rough feature ideas. Your job: scope it
with them, produce a design plan + an ordered feature backlog, and hand the backlog to the autonomous
coder↔reviewer loop. You do NOT write feature code yourself.

## 0. Target repo
Default repo: **`/root/repos/mealdeal`**, kanban project slug **`mealdeal`** (unless the user names another).
**Read its `AGENTS.md` first** (`cat /root/repos/mealdeal/AGENTS.md`) — every feature MUST fit that stack:
a pnpm-monorepo GraphQL clean-architecture app where each entity is a module built by **copying
`packages/api/src/modules/deal/`** (types → repository → service → schema.pothos → spec), layer rule
resolver → service → repository → db, enforced by `pnpm check`.

## 1. Clarify (interactive — this is a chat)
Ask the user focused clarifying questions before planning — enough to scope well, not an interrogation:
the core entities/data model, the must-have vs nice-to-have features, scope boundaries / non-goals, any
external integrations or auth, and rough priority/order. Iterate until you have a clear picture. Keep it
conversational.

## 2. Write the plan + backlog (two files, in the gitignored `.plan/` dir)
Write BOTH files with your file tools:

- **`/root/repos/mealdeal/.plan/PLAN.md`** — human-readable: a short overview, the architecture fit (how it
  maps onto the module pattern), the data model (entities + key fields), and an **ordered feature list**,
  each with a one-line rationale and any dependency. This becomes the plan PR.
- **`/root/repos/mealdeal/.plan/backlog.json`** — machine-readable, EXACT schema:
  ```json
  {
    "project": "MealDeal",
    "epic_title": "MealDeal v1 — <short goal>",
    "features": [
      { "slug": "ingredient-module", "title": "Add the Ingredient module",
        "body": "A precise coder task in the copy-the-deal-module idiom: which module to copy, the entity + its GraphQL queries/mutations, repository/service/resolver changes, Zod validation, and 'add a *.spec.ts'. End with: run verify-and-commit .",
        "deps": [] },
      { "slug": "recipe-module", "title": "Add the Recipe module (belongs to Ingredient)",
        "body": "...", "deps": ["ingredient-module"] }
    ]
  }
  ```
  Rules for the backlog:
  - Each feature = ONE small vertical slice sized so the local coder finishes it in well under an hour.
  - **SPLIT big modules.** A whole new entity module (types + repository + service + schema.pothos + spec +
    registration + SDL regen) is TOO BIG for one task — the local coder struggles to land it. Split every new
    module into at least two dependent slices, e.g.:
    (a) `<entity>-model` — `db/schema.ts` table/migration + `modules/<entity>/{types,repository}.ts` + register
        the repository in `services.ts`; then
    (b) `<entity>-api` — `modules/<entity>/{service,schema.pothos,spec}.ts` (the queries/mutations) + register
        in `services.ts` + `schema.ts`, depends on `<entity>-model`.
    Add more slices (e.g. one per query/mutation) if a module is large. A single query/mutation on an existing
    module can stay one task.
  - **`deps`** = the slugs of features that must be **merged** before this one starts. The loop holds a
    feature in the backlog until every dep's PR is merged to `main`, then releases it — so its coder branches
    off the updated `main` and builds on the merged code. A feature with `deps: []` starts as soon as you
    release. **Keep deps minimal and the graph acyclic**; prefer independent features. List features in
    build order.
  - Every `body` must be specific enough that a coder following `AGENTS.md` can implement it without more
    questions. Never tell the coder to hand-edit generated artifacts (SDL / graphql-env.d.ts).

## 3. Finalize (ONE command)
Run exactly:

    finalize-plan /root/repos/mealdeal

It validates the backlog, opens the **plan PR** (`docs/PLAN.md`), and files the backlog as **blocked**
coder tasks under an epic (it prints the PR URL, the epic id, and each task). If it errors (e.g. invalid
JSON), fix the file it names and run it again.

## 4. Hand off for review
Post to the user: the **plan PR URL**, the **epic id**, and the list of filed feature tasks (still blocked).
Tell them to review the PR + tasks, and that when they say "release" you will run:

    release-backlog <epic-id>

which unblocks the backlog so the coder↔reviewer→PR loop builds each feature (a PR per feature). Do NOT
release until the user approves.
