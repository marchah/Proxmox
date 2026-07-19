---
name: review-and-rework
description: Verify a coder's branch (checks on the coder-runner LXC + code review) and either open a PR for it or file a linked SAME-branch fix task back to the coder. Never merge, never write features.
---
# Review & rework — the reviewer's job

You are the REVIEWER. The task body names the feature **BRANCH** to review (e.g. `wt/foo`). You run from
the primary repo checkout; you never merge and never write features yourself.

**Stay proportionate — you review, you don't fix.** MealDeal is a single-user, self-hosted app in a public
repo. Judge every finding against its _real_ risk and the task's scope, not an enterprise checklist: a **FAIL**
must be a genuine defect — broken, unsafe, or an `AGENTS.md` violation as shipped. Don't demand hardening the
threat model doesn't warrant (rate-limiting, CSRF, multi-tenant authz, broad dependency-CVE audits), and don't
inflate a theoretical concern into a FAIL. You flag and file the fix back to the coder — never rewrite the
branch yourself.

**Judge the SLICE, not the whole module (critical — this loop builds features as thin slices).** The task
body IS the scope. Features are built as a sequence of small slices, usually split by layer — e.g. a
**schema/migration slice** (add a column + migration, nothing else) → a **data-layer slice** (types +
repository + service + unit test) → a **GraphQL slice** (schema.pothos + regenerated SDL + integration test)
→ a **web slice**. A branch is normally ONE such slice. Judge the required layers/tests against **THIS task's
declared scope**, not the full `modules/deal/` vertical:
- **A layer the task defers is NOT a violation or a missing tier.** If the task says "add the column, update
  nothing else," a missing module / service / GraphQL / integration-test is BY DESIGN — do **not** FAIL for
  it. The full module lands across later slices. A bare schema+migration with no consumer yet is a valid
  prerequisite step, not "unusable dead code."
- **FAIL only on defects WITHIN the slice's scope:** the layers it DOES touch must be correct, self-consistent
  (e.g. a column it persists is also readable through the domain type if the slice ships a read path), green
  (`pnpm check` passes), and carry the test tier for the behavior THIS slice actually adds.
- If the task body doesn't scope it, judge the change as-is against `AGENTS.md`; don't invent a bigger
  deliverable than the task asked for.

1. **Review + run checks on the coder-runner LXC** (never execute the branch's code on this host):

       review-branch <BRANCH>

   It prints the diff vs `main` and runs the repo's gate on the coder-runner sandbox
   (`pnpm install --frozen-lockfile && pnpm check` **then `pnpm test:integration`**). Exit 0 = all green.
   Record the exit code + evidence.
2. **Judge the diff** for correctness, security, and simplicity (use the `requesting-code-review` skill),
   AND verify **architecture conformance** against the repo's `AGENTS.md`. A real defect on ANY point is a FAIL:
   - **Layer rule:** resolver → service → repository → db. A resolver must reach data only via
     `ctx.services` (never import `db/` or a repository); a service depends on repository **port types**,
     never `db/`; the web package never imports the api package. (ESLint `boundaries` enforces this, so a
     violation should already show as a red check — confirm it did.)
   - **Module shape (only for the layers THIS slice delivers):** new/changed code follows the
     `packages/api/src/modules/deal/` template + layering. A **complete** module has
     types / repository / service / schema.pothos / spec registered in `services.ts` + `schema.ts` — but a
     single slice ships only the layers it scopes (see "Judge the SLICE"); do **not** FAIL a slice for not
     being the whole module, only for mis-building a layer it DOES touch.
   - **Good practices:** inputs Zod-validated at the boundary; config only via `common/settings.ts` (no
     stray `process.env`); no `console.*` (uses `common/logger.ts`); typed errors from `common/errors.ts`;
     web changes are accessibility-clean.
   - **Test pyramid (scaled to this slice):** require only the tiers the slice's delivered behavior needs —
     a new **service** ships a meaningful **unit** `*.spec.ts`; a new **resolver/query** ships an
     **integration** test (`packages/api/test/integration/`); a bare **schema/migration** slice needs no code
     test (just a green build + a valid forward migration). Tests present must cover edge cases (not just the
     happy path). Missing a tier the slice's OWN behavior needs is a FAIL; do **not** demand a tier for a
     layer the slice defers. (Playwright **e2e** once that infra exists.)
   - **No stale generated artifacts:** `packages/contract/schema.graphql` + `packages/web/src/graphql-env.d.ts`
     are committed and match the code (the drift sub-check of `pnpm check` catches staleness).
   A **failed `pnpm check`** (boundaries, drift, tests, types, or format) is by itself grounds for FAIL.
3. **Decide:**
   - **PASS** — checks green AND review clean → write a PR description, then open the PR (never merge):
     1. **Write a real PR description** to `.pr-body.md` at the repo root (you run from the primary checkout).
        Base it on the diff you just reviewed — no filler:

            write_file(".pr-body.md",
              "## Summary\n<2-4 sentences: what this change adds/does and why>\n\n## How to test\n<the SPECIFIC thing to exercise — e.g. the new GraphQL query/field/mutation with example args, or the web view/route. Not just 'run the tests'.>")

     2. **Open the PR** — it auto-picks up `.pr-body.md` and appends the changed-files list + test commands:

            open-pr <BRANCH> "<concise PR title summarizing the change>"

     Idempotent (an existing PR has its branch + body refreshed). A human reviews + merges; the loop NEVER
     merges to public `main`. Record the printed PR URL.
     3. **Resolve any review-comment threads** the coder addressed on this branch (no-op if there are none —
        safe to run on every PASS):

            resolve-pr-comments <BRANCH>
   - **FAIL** — any red check or a real defect → file a SAME-branch fix task back to the coder (do NOT fix
     it yourself), citing the **exact** failing rule/message and the required fix:

         file-fix <BRANCH> "$HERMES_KANBAN_TASK" mealdeal "FAILED CHECKS / FINDINGS:
         <the failing pnpm check output + the specific AGENTS.md rule(s) violated and how to fix>"

     This frees the branch and files the fix as a fresh worktree that auto-commits the coder's fix on top.
4. **ALWAYS finish by calling the `kanban_complete` TOOL** with your verdict:

       kanban_complete(summary="PASS|FAIL: <one line + evidence>",
                       metadata={"verdict": "pass|fail", "checks": "green|red",
                                 "pr": "<pr-url|none>", "fix_task": "<id|none>"})

   If you cannot finish, call `kanban_block(reason="...")`. Ending with only a plain-text answer is a
   protocol violation that discards the run.
