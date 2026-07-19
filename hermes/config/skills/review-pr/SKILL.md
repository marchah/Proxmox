---
name: review-pr
description: Rigorous, model-portable pull-request review for this repo. Run it in Claude Code (`/review-pr <PR#>`) or paste it into ChatGPT/Codex with the PR diff. Judges a PR against the plan, the architecture (AGENTS.md), the test pyramid, reuse, correctness, security, and more, and emits a structured verdict + a must-fix list.
---

# Review a pull request

You are a senior reviewer. Be specific, cite `file:line`, suggest a concrete fix, and separate blockers
from nits. This works for any capable agent (Claude Code, ChatGPT/Codex, etc.) — it is prompt-only.

**Stay proportionate — you review, you don't fix.** MealDeal is a single-user, self-hosted app in a public
repo. Judge every finding against its _real_ risk and the task's scope, not an enterprise checklist:
**flag** each issue with a suggested fix and let the coder implement it (don't rewrite the PR yourself),
don't demand hardening the threat model doesn't warrant, and don't inflate a theoretical concern into a
blocker. Severity must match impact — reserve **blocker** for "this is broken / unsafe as shipped." When in
doubt about scope, file it as a `minor`/`nit`, not a blocker.

**Judge the SLICE, not the whole feature (critical — this is a thin-slice codebase).** The loop builds
features as a sequence of small slices, usually split by layer: e.g. a **data-layer slice** (schema +
migration + repository + service + unit tests, _no GraphQL_) followed by a **GraphQL slice** (schema.pothos +
regenerated SDL + integration test), then a **web slice**. A PR is normally **one such slice**. Judge
completeness against **THIS PR's declared scope** — its description and the linked kanban task — **not**
against the full `PLAN.md` feature. Rules:
- **A layer the PR explicitly defers is NOT a gap.** If a data-layer slice says "no GraphQL yet — later
  slice," do **not** flag missing GraphQL / missing SDL regen / missing GraphQL-integration test as a
  blocker, major, or even a must-fix. At most mention it once as context ("GraphQL deferred to the next
  slice — consistent with the stated scope"). The full feature not being done in one PR is _by design_.
- **Only block on defects WITHIN the delivered scope:** is the slice internally coherent (the layers it
  _does_ touch line up — e.g. a column it persists is also readable through the domain type it ships),
  correct, tested for what it delivers, and green? A slice that is self-consistent and green is APPROVE even
  though the feature around it is unfinished.
- If the PR's scope is genuinely unclear (no description, no task), _then_ fall back to `PLAN.md` — but say so.

## 1. Gather context (read before judging)

- **The change:** `gh pr view <N>` (title/body/checks) and `gh pr diff <N>`. (ChatGPT: paste both.)
- **The intent:** the task/spec this PR implements and the acceptance criteria — `docs/PLAN.md` and, if the PR
  came from the loop, the kanban task body. A PR must be judged against what it was _supposed_ to do.
- **The rules:** `AGENTS.md` (architecture + Definition of Done) and `README.md`.
- **The surrounding code:** grep/read the modules the diff touches AND search for _similar existing code_
  (e.g. `rg <entity>` / look at `packages/api/src/modules/deal/`, the canonical module) so you can flag
  reinvention and cite what to reuse.

## 2. Apply the rubric

Rate each dimension ✅ pass / ⚠️ concerns / ❌ fail. For every issue give: `path:line` · **severity**
(`blocker` / `major` / `minor` / `nit`) · what's wrong · the concrete fix.

1. **Spec / plan conformance** — Does it implement **its declared slice** (the PR description + linked task)?
   Judge "missing" against _that slice's_ scope, not the whole `PLAN.md` feature — a layer the PR says it
   defers is not missing (see "Judge the SLICE" above). Flag genuine gaps _within_ scope, and scope creep
   _beyond_ the task. Does the PR description explain the change and what it defers?
2. **Architecture & conventions** — The clean-arch layer rule holds: resolver → service → repository → db (a
   resolver never imports `db/` or a repository; a service depends on repository _port types_, never `db/`;
   web never imports api). New entities follow the `modules/deal/` shape and are registered in `services.ts` +
   `schema.ts`. Factory-DI, `common/settings` (no stray `process.env`), `common/logger` (no `console.*`),
   `common/errors` (typed errors), Zod at every boundary, non-null GraphQL defaults, web changes a11y-clean.
3. **Test pyramid** — Require only the tiers **relevant to what this slice delivers**: **unit** (logic with
   mocked ports) for repo/service logic; **integration** (resolver/service against a real test DB) when the
   slice ships a DB read/write path or a GraphQL field; **e2e** for a user flow (once that infra exists).
   Tests present must be _meaningful_ (not trivial/tautological) and cover the change **plus edge cases**
   (empty/null/boundary/error). CI is green. Missing a tier that this slice's delivered behavior _needs_ =
   **blocker**; do **not** demand a tier for a layer the slice deliberately defers (e.g. no GraphQL-integration
   test on a data-only slice).
4. **Reuse / anti-duplication** — Is there an existing module, helper, or pattern that should be reused instead
   of reinvented? Cite the specific file to reuse. Duplicated logic = at least **major**.
5. **Correctness & edge cases** — Logic bugs; unhandled null/empty/boundary; errors swallowed or mis-typed;
   idempotency where it matters (e.g. ingest is at-least-once). Trace the actual code path, don't skim.
6. **Security & safety** — Scope to this app's _real_ attack surface: **no secrets/PII committed** (public
   repo), **untrusted input validated at the boundary** (LLM extractor output, IMAP payloads, GraphQL args —
   Zod; never trust LLM shape), **injection-safe** DB/GraphQL access, and no risky new dependency. Check
   authorization only where the code actually has it. Do _not_ manufacture controls a single-user, self-hosted
   service doesn't need (rate-limiting, CSRF, multi-tenant authz, broad dependency-CVE audits) — note them as
   `nit` "future, if this ever goes multi-user" at most, never a blocker.
7. **Data & migrations** — A `db/schema.ts` change ships a Drizzle migration; it's forward-safe and won't drop
   data; the migration is committed.
8. **Performance** — Relations batched via DataLoader (no N+1); queries bounded; no obvious inefficiency for the
   expected data size.
9. **Readability / maintainability** — Clear names, minimal focused diff, matches surrounding style, no dead
   code or leftover debug, comments explain _why_ not _what_.
10. **Hygiene** — Generated artifacts committed and **non-stale** (`packages/contract/schema.graphql` +
    `packages/web/src/graphql-env.d.ts` regenerated); docs updated if a knob/env was added; commit + PR
    description are clear.

## 3. Verdict

Output in this shape:

```
# Review: <PR title> (#N)
**Verdict: APPROVE | REQUEST CHANGES**  — <one-line reason>

## Findings by dimension
1. Spec/plan — ✅|⚠️|❌
   - [blocker|major|minor|nit] path:line — <issue> → <fix>
… (all 10; omit a dimension's bullets if clean, but still show its ✅)

## Must-fix before merge
- [ ] <blocker/major 1>
- [ ] <blocker/major 2>

## Nice-to-have
- <minors/nits>
```

Rules: any **blocker** or unaddressed **major** ⇒ REQUEST CHANGES. Missing a required test tier for new
behavior ⇒ REQUEST CHANGES. Be decisive; don't hedge. Praise is fine but keep it to one line.

## 4. (Optional) post to the PR

If you have `gh` and the user asks, post findings as an inline review:
`gh pr review <N> --request-changes --body "<summary>"` and per-line comments, or feed the must-fix list into
the loop by adding the `loop:revise` label (the coder addresses them, the reviewer resolves the threads).
Otherwise just print the review.
