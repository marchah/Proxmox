# MTP / NextN patches for `qwen4exp` on b11018

> 🔴 **NOT APPLIED, AND NOT WORKING. This is a staged artifact for a future retry.**
> The rebase builds and the server starts, but a request **aborts in the MTP graph**:
> `GGML_ASSERT(ggml_can_repeat(b, a))` in `build_hc_mix`, reached via `graph_mtp`. b11018
> reshaped the hyper-connection gammas from `{hc_dim}` to `{n_embd, hc}`, and no resolution of
> the conflict below satisfies both the main graph and the MTP graph. **The blocker is in the
> GRAPH, not the loader** — so a clean build and a registered `--spec-type draft-mtp` are not
> evidence that it works. Retry when #28097 rebases onto a build whose gamma shape it expects.
> Patch correctness beyond that conflict was never reviewed.

llama.cpp PR **#28097** adds `--spec-type draft-mtp` for Qwen3.8-Flash-Next and teaches
the loader the draft-head-only GGUF layout unsloth ships. It already contains #27836's
three commits, rebased, so it is the only PR needed.

## 🔴 Why these patches exist instead of a plain checkout

**#28097's base is 307 commits behind b11018, and what it lacks includes
`35822afe5 vulkan: support qwen4exp hc ops` (#28988)** — the commit that makes this
architecture's hyper-connection ops work on Vulkan at all. A binary built from the PR as
published cannot offload qwen4exp to a V620, so any speculation measured on it would be
meaningless. It also predates #25483 (skip unneeded MoE work in the `mul_mm` coopmat1
path) and #28996, both directly relevant to a Vulkan MoE.

So the four commits are rebased onto b11018 instead.

## Applying

```sh
git checkout -B mtp-b11018 b11018
git am /path/to/mtp-patches/*.patch
```

## What conflicted, and the resolution rule

Two commits touched `src/models/qwen4exp.cpp`, which b11018 had moved on underneath:

| what changed in b11018 | resolution |
| --- | --- |
| `n_ff_exp` became a per-layer array (`n_ff_exp_arr` + an `n_ff_exp(il)` accessor) | keep the accessor, drop the PR's scalar read |
| `LLM_KV_NEXTN_PREDICT_LAYERS` is now read by the **generic** loader (`llama-model.cpp`) before the arch hook | drop the PR's re-read, keep only its stricter arch assert (`n_layer_nextn < n_layer_all`) |
| every `hc_*_norm`, `ple_norm_*` and `hc_head_norm` gamma was reshaped `{hc_dim}` → `{n_embd, hc}` with `TENSOR_ALLOW_RESHAPE`, so the grouped norm needs no graph reshape | keep b11018's shape, `OR` in the PR's flag: `TENSOR_ALLOW_RESHAPE \| flags` |
| the PLE row-count block became a strict superset of the PR's — it validates the head ranges against the tensor, reads back the padded row count, **and** tolerates a model synthesised from metadata with no tensor to ask | keep b11018's block entirely; take only the PR's `!mtp_only &&` guard |

**The rule throughout: keep b11018's shapes and logic, OR in the PR's flags.** Every
`create_tensor` call outside the conflicted hunks already used `flags` (those lines merged
cleanly), which is what makes the resolution unambiguous rather than a judgement call.

⚠️ The PR's `require_weight()` rewrite of the PLE block was **deliberately not taken**: it
would have regressed b11018's no-tensor case, and its `const int64_t ple_rows` cannot
compile against b11018's assigning loop.

## Verification done

* `git rev-list --count b11018..mtp-b11018` = 4, and b11018 is an ancestor
* `g++ -fsyntax-only` on `src/models/qwen4exp.cpp` with the build's real flags — clean
* the build asserts `--spec-type draft-mtp` in `llama-server --help` **and** that
  `ggml-vulkan` is in the output, since the Vulkan backend is the entire point

⚠️ **Re-check all of this on any llama.cpp bump.** These are patches against one tag; the
next tag may move the same tensors again. If #28097 merges upstream, delete this directory.
