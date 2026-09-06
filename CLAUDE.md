# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash provisioning scripts (with embedded Python) that create and operate
Proxmox LXC containers for a local AI homelab. There is no application to build or test
suite to run — the "product" is the scripts themselves, executed **on the Proxmox host as
root**. macOS is only the authoring/editing environment; the scripts run remotely against
`pct`/`pveam`.

These containers form the system:

- **CT 120** (`pro-v620/`): a *privileged* Ubuntu LXC — the **LLM runtime** — serving
  `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MoE, 35B total / ~3B active) via Vulkan, exposing an
  OpenAI-compatible API at `0.0.0.0:1234` under the id `qwen3.6-35b-a3b`. The host now has
  **two Radeon Pro V620s** (Navi 21 / gfx1030, 32 GB each): one in the **PCIe-1** (CPU) slot
  `0000:2d:00.0`, one in the **PCIe-3** (chipset) slot `0000:06:00.0`, each cooled by its **own
  9733 radial blower**, both hanging off one SATA-powered PWM hub whose control lead sits on the
  **PUMP FAN** header (one `gpu-fan-control@hub` instance on pwm2, curve tracks the hotter card).
  With both cards saturated at once they settle around 62 / 73 °C at 51 % fan — thermals are not a
  constraint on this box. CT 120 is **pinned to GPU 1 alone** (`0000:2d:00.0`): its
  container bind-mounts only that card's `/dev/dri` render node (via the udev-stable `by-path`
  symlink — the reboot-stable way to pin one of two identical cards), so llama.cpp sees a single
  Vulkan device and runs the whole ~26.6 GB model on it. ⚠️ **This card assignment is not
  arbitrary** — GPU 2's chipset slot costs a fixed ~3.45 ms per decoded token, i.e. −22 % on this
  MoE, so the model belongs on GPU 1 (see the two-slot benchmark under Conventions).
  **GPU 2 (`0000:06:00.0`) runs CT 123 `gpu2`**
  (a `llama-swap` server for the autonomous coding loop — see below); it stays amdgpu-bound so the host
  fan/undervolt/watchdog services manage both. Both cards are undervolted −100 mV:
  - `pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh` — llama.cpp's `llama-server`
    (hostname `llamacpp`). This is the current runtime.
    - ⚠️ **Thinking is DISABLED — `--reasoning off`** in `/usr/local/bin/llamacpp-serve`, baked
      into the provisioning script. Hermes' default provider `custom` points here, so **this is
      also the Hermes default** — there is no separate Hermes setting. Without it, reasoning fills
      the whole per-slot context and returns `finish_reason: length` with no answer (the Hermes
      "Thinking Budget Exhausted" failure).
      - ⚠️ **`--reasoning off` ≠ `--reasoning-format`.** The latter only decides *where* thought
        tags go; it does not stop them being generated. With thinking off the template still emits
        an EMPTY `<think>\n\n</think>` pair, and `--reasoning-format none` leaves it in `content`
        — which silently corrupts every generated file (a KB-ingestion run produced a file starting
        `<think>\n\n</think>\n\n---` instead of `---`, i.e. invalid frontmatter). Must be
        **`auto`**, which siphons the empty block into `reasoning_content`.
      - ⚠️ The flag lives in the **serve script**, not `/etc/llamacpp.env`, so it survives
        `llamacpp-reload` (which rewrites only ctx/parallel).
      - `MODEL_PARALLEL=2` (131k/slot) is over-provisioned now that reasoning is off — `4`
        (65k/slot) is viable for 2× concurrency. Deliberately left alone.
  - `pro-v620/create-lxc-llama-swap-gpu2.sh` — **CT 123 `gpu2`** on GPU 2: a `llama-swap` proxy for the
    autonomous coding loop that hot-swaps between a coder model (Qwen3.8-27B, alias
    `qwen3.8-27b-dflash2`) and a reviewer model (ThinkingCap-Qwen3.6-27B, alias `thinkingcap-27b`),
    one resident at a time (OpenAI API `0.0.0.0:8080`, pick model by name).
    Same single-GPU pin idiom (`GPU_PCI_ADDRESS=0000:06:00.0`, by-path, REAL node name) + the loud-guard.
    The loop's dispatcher is serialized (`kanban.max_in_progress: 1`) so swaps fire only at role handoffs.
    - 📐 **KV-cache quantisation: q8_0 is free on speed, but BREAKS thinking termination.**
      q8_0 KV costs zero throughput (marginally faster, unchanged at 2× context) — the trade-off is
      not speed. With reasoning ON, quantised KV perturbs the logits enough that the model never
      emits its end-of-thinking token, so it reasons to the cap and returns **nothing**.
      With `reasoning_effort: "none"` it is provably lossless (byte-identical output at 2× context).
      ⚠️ **A COUPLED choice: `reasoning off + q8_0` XOR `reasoning low/medium + f16`.** Mixing gives
      silent empty replies. **Not applied**, because a later caller sending `low` would fail
      silently. Score any cache-type change by hashing the output — a speed-only comparison scores
      an empty reply as a free win.
    - 📐 **KV cache sizing — `n_layer` means FULL-ATTENTION layers only.** The formula
      `2 × n_layer × n_head_kv × head_dim × bytes` is right, but the Qwen3.5/3.6/3.8 families are
      hybrid: most layers are linear attention (Gated DeltaNet) whose state is fixed-size and
      context-independent, so only `layer_types == "full_attention"` layers hold a KV cache.
      Measured on this card: `qwen3.8-27b` 16 of 64 full-attn → 72 KiB/tok f16 (~42 at q8_0);
      `ornith-1.5-35b-a3b` 10 of 40 → 18.3 KiB/tok.
      - ⚠️ **A NON-hybrid model gets no such discount — the formula then applies literally.** Read
        `layer_types` / `full_attention_interval` in `config.json` before sizing anything new.
        Worked example: `ibm-granite/granite-4.2-30b` is plain GQA on **all 64** layers → 256
        KiB/token f16, which caps it near **24-28k context** at Q5_K_M on one V620.
      - Confirm with a VRAM **delta** between two context sizes, reading GTT alongside VRAM — flat
        VRAM can mean the KV moved to host memory, not that it got cheaper.
      - ⚠️ Below roughly **1 GiB of headroom** RADV starts spilling to GTT, which is a ~12× decode
        collapse the loud-guard does NOT catch. Watch `mem_info_gtt_used`, not just VRAM.
    - ✅ **Vision is enabled on the coder** via `--mmproj` in its `EXTRA_ARGS` (Qwen3.8-27B is
      multimodal). No script change was needed — `llamaswap-guarded-serve` word-splits `EXTRA_ARGS`
      and appends it to `llama-server` verbatim. Projector `/models/hf/Qwen3.8-27B-mmproj-F16.gguf`
      (`unsloth/Qwen3.8-27B-GGUF` → `mmproj-F16.gguf`, sha256 `cbb841a9ee0636b2…`). Costs 884 MiB
      of disk and **+1.11 GiB VRAM**; text throughput and output are unchanged. MTP/DFlash and
      vision coexist. Verified with `pro-v620/gpu-ab-bench/vision-test.py`.
      - **Why it earns its keep even unused:** without `--mmproj` the server answers `image input
        is not supported` and an agent **keeps working regardless** — one 3-hour run had a "visual
        critic" reasoning about screenshots it never received. This closes a silent failure mode.
      - **VRAM is the binding constraint, not compatibility.** If something else needs room the
        projector is the first thing to drop: `--no-mmproj-offload` keeps it on CPU for zero VRAM,
        which frees 1.10 GiB and costs **3–5× on image encoding only** (text throughput and
        post-image decode are unaffected). The penalty grows with resolution, so downscaling
        recovers most of it. That GiB buys roughly +16k of context.
      - ⚠️ **Set `cache_prompt: false` when timing image requests.** With caching on, repeated
        identical requests report `prompt_n` of ~4 and every config looks identical — you measure
        cache hits, not encoding.
    - 🔴 **The coder is a THINKING model whose default effort NEVER ANSWERS.**
      `llama-server`'s `--reasoning` defaults to `auto` and no entry overrides it, so Qwen3.8-27B
      reasons without bound — measured at 8000 tokens / 32,901 chars of reasoning with `content`
      still empty, `finish_reason: length`. `--n-predict 32768` is the only bound, so a request can
      burn 32k tokens and return nothing. **Callers must send `reasoning_effort`.**
    - ✅ **Reasoning is controllable BY THE CLIENT, per request** — better than a global server
      flag, because the loop can pick per task:

      | client-side parameter | effect |
      | --- | --- |
      | `reasoning_effort: "none"` | ✅ **prefer this** — canonical OpenAI spelling, portable; byte-identical to `enable_thinking:false` |
      | `reasoning_effort: "low"` / `"medium"` | works, and slightly faster than unset |
      | `reasoning_effort: "high"` / unset | runs away — no answer |
      | `chat_template_kwargs: {"enable_thinking": false}` | works, but llama.cpp-specific |
      | `reasoning_budget: N`, `chat_template_kwargs.thinking_budget`, `/no_think` | ⚠️ silently ignored |
      | `reasoning_effort: "minimal"` | ⚠️ **HTTP 500** — an invalid level crashes the request rather than being rejected |

      - **On/off and effort are client-side; BUDGET is server-side only.** The robust shape is
        both: clients send `reasoning_effort` per task, and the server sets `--reasoning-budget N`
        as a floor so a client that sends nothing cannot run away.
    - ⚠️ **It serves more than the coder/reviewer pair**, and the list is **live-only in
      `/etc/llama-swap/config.yaml`, deliberately not baked into the script** (models change as
      they are trialled). It has drifted from the docs twice — **read the config before trusting
      any doc**:
      `pct exec 123 -- bash -lc "grep -E '^  [a-z0-9.-]+:' /etc/llama-swap/config.yaml"`.
      Currently six: `qwen3.8-27b-dflash2` (coder — own DFlash2 head + vision on GPU, ctx 65536) ·
      `qwen3.8-27b-mtp` (previous coder, kept as a one-line rollback — ⚠️ it needs **n-max 2**, not
      DFlash2's 8, or it collapses) · `qwen3.8-27b-mtp-maxctx`
      (vision on **CPU** → ctx 98304) · `ornith-1.5-35b-a3b` (fastest + longest: 66.4 tok/s,
      ctx 196608, no drafter) · `thinkingcap-27b` (reviewer) · `muse-glimmer-30b` (eval).
      A rebuild from the script yields only the bootstrap pair — re-add the rest by hand.
      - **`ornith-1.5-35b-a3b`** — architecturally identical to `qwen3.6-35b-a3b` (same
        `qwen35moe`), so it needed no new llama.cpp support. 66.4 tok/s, KV 18.3 KiB/token, vision
        working. **No drafter, deliberately**: on a ~3B-active MoE draft/verify overhead dominates.
        - ⚠️ **Not a coder replacement.** It loses the two benchmarks closest to the loop's work
          (Terminal-Bench 2.1 67.8 vs 73.0, SWE-bench Pro 59.6 vs 61.7). The loop is PR-gated and
          serialised, so a task that fails review costs a whole cycle that tok/s cannot buy back.
          Use it for **long-context repo work and fast first-pass/triage**.
        - ⚠️ **Do not raise ctx to the native 262144.** It loads, but leaves only 0.49 GiB with GTT
          already at 0.54 — under the ~1 GiB floor where RADV spills silently. Decode is identical
          at 131072 and 196608, so 192k is free and 256k is not worth the risk.
      - ⚠️ **Keep a non-speculative entry, or be ready to re-add one before any speculation
        claim.** Comparing two speculative configs against each other measures agreement, not
        correctness. Retiring the unaccelerated alias cost a later comparison its baseline and one
        had to be recreated. `spec-sweep.sh` can start its own server with no `--spec-*` flags.
      - **Current coder: DFlash2 at n-max 8** (`z-lab/Qwen3.8-27B-DFlash2-GGUF` Q8_0, 1.92 GiB —
        smaller than the MTP head's 4.19 GiB, so it frees ~2.3 GiB of VRAM; auto-detected from the
        checkpoint, so `--spec-type` stays `draft-dflash`). Against a no-speculation control
        (17.03 tok/s): **+29% overall, +89% on code**, at a −4 to −9% cost on prose and list. Code
        is what the coder emits, so that trade is deliberate. DSpark was tested and is **not**
        better than MTP.
    - **`muse-glimmer-30b`** — Meta Superintelligence Lab, dense 28B + 2B perception encoder,
      Apache-2.0. Deployed quant is Meta's own `muse-glimmer-30B-kquant-dynamic.gguf` (19.65 GB,
      ~5.64 bpw effective despite the "4-bit" label) plus Meta's `dflash-kquant.gguf` drafter
      (1.63 GB) — chosen because it is the **only** Muse Glimmer quant with a published degradation
      figure (0.2% average over 15 benchmarks). Unsloth publishes no accuracy numbers, so a switch
      would trade a measured build for an unmeasured one. Three settings are **required**:
      - `--reasoning-format auto`. With `none` the model's channel format (`to=<recipient>`,
        `<|message|>`) leaks raw into `content` and the reply is unusable.
      - `--spec-draft-n-max 3` (3 and 4 are statistically tied; 2 is −12%, 6 is −5%).
        ⚠️ **muse has NO argmax-stable n-max range** — at temperature 0, changing n-max changes the
        answer even between 2 and 3. Treat an n-max change here as an output change, not a
        throughput knob.
      - A generous client `max_tokens`. It reasons before answering: at 300 the reply comes back
        with `content` **completely empty** and everything in `reasoning_content`. A low cap yields
        empty responses, not errors.
      - ⚠️ DFlash and **vision are mutually exclusive** upstream (llama.cpp #26108, still open), so
        the `mmproj` projector is not deployed for this model.
    - **Speculative decoding — the rules that generalise.** `llamaswap-guarded-serve` carries two
      backward-compatible env hooks for it: `LLAMACPP_DIR` (pin ONE entry to a different llama.cpp
      build without moving the shared `/opt/llamacpp/current` symlink) and `EXTRA_ARGS` (extra
      `llama-server` flags).
      - ⚠️ **A SPECULATIVE MODEL HAS NO SINGLE tok/s — throughput is PROMPT-DEPENDENT.** Decode
        speed tracks draft acceptance, which tracks how predictable the output is: on one model,
        prose 32.9 tok/s at 44.8% acceptance vs code 44.3 at 71.0%. That is a **35% spread from
        prompt choice alone**, wider than most differences these notes are used to argue about.
        - **Quote a range and name the prompt class**, never a bare number.
        - **Never A/B two models or settings on different prompts** — the prompt difference can
          exceed the effect being measured.
        - **Judge a regression by acceptance, not tok/s** (`draft_n` / `draft_n_accepted` come back
          in every response's `timings`). Unchanged acceptance means only the workload moved.
        - Non-speculative entries are immune; the whole effect is a speculation artifact.
      - ⚠️ **Interleave configs and take ≥3 reps before acting on a delta.** One rep per cell was
        actively misleading once — it understated a cost by half and flipped the recommendation.
      - ⚠️ **Gate every sweep on an output-sanity check.** Degenerate repetition drafts almost
        perfectly, inflating both acceptance and tok/s, so a tok/s-only sweep can record a
        corrupted run as a 3× win. The gate is built into `spec-probe.py` (`uniq_8gram_min`,
        `any_degenerate`).
      - ⚠️ **Speculation is NOT argmax-lossless here** — at temperature 0, output diverges as n-max
        rises, and where it diverges is prompt-dependent. Hash outputs against a no-speculation
        control, not against another speculative config.
      - ⚠️ **`--spec-draft-n-max` never transfers between drafters.** Sweep every new one. It is a
        drafter property, not a backend one: MTP falls off a cliff at n≥8 (acceptance drops
        monotonically), while DFlash2 and DSpark plateau instead — which is why the coder can
        safely run n-max 8 where MTP could not. **Do NOT set it from the drafter GGUF's
        `dflash.block_size`** — that is the worst value tested.
      - ⚠️ **A MATCHED drafter beats a borrowed one — search HF for `MTP` too, not just `DFlash`.**
        Same target, same ctx, same day: no speculation 17.55 tok/s · borrowed DFlash head 23.68
        (28.8% acceptance) · the model's own MTP head 27.73 (61.7%).
      - ⚠️ **The drafter GGUF must declare `general.architecture = dflash`, not `dflash-draft`.**
        Upstream registers `dflash`; several community repos ship the fork's name and fail to load
        with `unknown model architecture` (llama.cpp #25116). Check before downloading gigabytes:
        `curl -fsSL -r 0-1023 <url> | tr -c '[:print:]' '\n' | grep -aoE 'dflash[a-z-]*' | head -1`.
      - **Speculation is a dense-model lever, not a universal one.** Dense 27B goes 17.6 → 43.8
        with DFlash, but the 3B-active MoE `qwen3.6-35b-a3b` runs 63.1 tok/s with none at all — its
        decode is already cheap, so draft/verify overhead dominates. Reach for it on dense targets.
      - **Re-sweep speculation after every llama.cpp bump.** One build bump improved the
        speculative path by 22–27% while unaccelerated decode stayed flat, same files and card — a
        bump can be worth far more to a speculative entry than to a plain one.
  - **Prior GPU (`rx-6700-xt/`, kept for reference):** the V620 replaced a Radeon RX 6700 XT
    (12 GiB) that served `Qwen3.5-9B-Q4_K_M.gguf` (id `qwen3.5-9b`) via two interchangeable
    engine scripts — `create-lxc-lmstudio-qwen3.5-9b.sh` (LM Studio `lms`) and
    `create-lxc-llamacpp-qwen3.5-9b.sh` (llama.cpp). The README found llama.cpp better on
    that card, which is why the V620 ships only the llama.cpp script.
- **CT 121 `hermes`** (`hermes/`): an *unprivileged* Debian LXC running NousResearch's
  **Hermes Agent** — the homelab's agent (NOT a model server; it *consumes* CT 120's API,
  see the `ct120-vs-hermes` memory). It auto-discovers CT 120's IP, points Hermes at it via a
  `provider: custom` OpenAI endpoint (no Nous Portal login), and runs a single
  `hermes gateway run` service = messaging gateway + Hermes's own OpenAI-compatible API server
  on `0.0.0.0:8642`. Persistent (`120-139` AI range, starts on boot); full Playwright browser
  tools; installs + runs as root inside the unprivileged LXC. `hermes/create-lxc-hermes-agent.sh`.
- **CT 140 `kb-rag`** (`kb-rag/`): an *unprivileged* Debian LXC that indexes the private
  **CognitiveStack** Markdown knowledge base and serves **hybrid search** — FTS5 **BM25**
  (keyword/exact) ⊕ `sqlite-vec` **KNN** (semantic), merged by **Reciprocal Rank Fusion** (k=60)
  — to every agent on the box over one port: **REST *and* MCP-over-HTTP** on `0.0.0.0:8770`
  (`/v1/search`, `/v1/doc`, `/v1/stats`, plus an unauthenticated `/health`; MCP at `/mcp/` —
  trailing slash, `/mcp` 307-redirects — exposing `kb_search`/`kb_get`/`kb_stats`). It sits in the
  `140-159` **databases** range because the durable artifact is a vector+FTS database, even though
  agents are the consumers. `kb-rag/create-lxc-kb-rag.sh`; full design rationale in
  `kb-rag/SPEC.md`.
  - **Markdown-in-git stays the source of truth** — this CT holds only a *derived, rebuildable*
    index, so wiping `/opt/kb-rag/data` + `kb-reindex --full` reconstructs everything. Back up the
    CognitiveStack repo, not this container. If the vector store ever becomes where knowledge
    *lives*, that's a regression.
  - Embeddings are **CPU-only** (`fastembed`/ONNX, `BAAI/bge-small-en-v1.5`, 384-dim) —
    deliberately **no GPU passthrough and no load on CT 120**: embedding one short query is
    milliseconds on CPU and batch indexing is offline. A `kb-reindex.timer` pulls + reindexes every
    10 min, incrementally (only chunks whose `content_hash` changed are re-embedded) and stamps the
    source commit into the index. Corpus selection is glob-driven in `app/index.config.yaml`
    (include `**/*.md`, exclude `personal/**` + nav/meta), not hardcoded — a new topic folder is
    picked up automatically.
  - Security: a **read-only deploy key** for the KB repo is **mandatory** (`DEPLOY_KEY_FILE=`, the
    container can only pull), and every data endpoint is gated by a bearer key auto-generated at
    provision and stored mode-600 in `/etc/kb-rag.env`. Secrets are pushed as mode-600 files and
    the host copies removed (the hermes idiom). Reachable on its own LAN IP, by hostname.
  - ⚠️ Changing `EMBED_MODEL`/`EMBED_DIM` later requires `kb-reindex --full` — the stored
    `sqlite-vec` vector dimension must match.
  - **Wired into Hermes over MCP.** CT 121's `config.yaml` carries an `mcp_servers.kb-rag` entry
    pointing at `http://kb-rag:8770/mcp/`; verify with `hermes mcp test kb-rag`. Four things that
    are each load-bearing:
    - ⚠️ **The config key is `mcp_servers:`, not `mcp:`** — `mcp:` is silently ignored. Schema is
      in `tools/mcp_tool.py`'s module docstring.
    - ⚠️ **The trailing slash is required.** `/mcp` 307-redirects to `/mcp/`, and a redirected POST
      is not something every MCP client replays correctly.
    - ⚠️ **Keep the key OUT of `config.yaml`.** Hermes' `_load_mcp_config()` calls
      `load_hermes_dotenv()` and resolves `${VAR}` (also Cursor-style `${env:VAR}`) before
      connecting, so the entry reads `Authorization: "Bearer ${HERMES_KB_RAG_KEY}"` and the secret
      stays in `~/.hermes/.env`. This is not cosmetic: `config.yaml` **is** in the nightly backup,
      whose gitleaks gate is a hard `exit 1` on any finding — a literal token there would silently
      kill the only tracked copy of the config. No other literal secret lives in that file.
    - ⚠️ Hermes' MCP **client** is a major version behind what CT 140 serves; this works only
      because v2 still serves the legacy 2025-06-18 handshake. Verify that stays true on any
      future kb-rag SDK bump.
    Validation order is worth knowing: `_filter_suspicious_mcp_servers()` runs **before**
    interpolation, so the security check sees the placeholder, never the resolved secret.
  - ⚠️ Its `rootfs` `backup=0` is one of the **silent no-ops** described under Conventions, so
    this entirely rebuildable container **is** in the weekly vzdump — don't believe the "not backed
    up" comments in `kb-rag/README.md` and `SPEC.md`. To actually skip the bulk:
    `vzdump 140 --exclude-path /opt/kb-rag`.
  - ⚠️ Its `kb-reindex`/`kb-stats` wrappers live in `/usr/local/bin`, so they hit the **`pct exec`
    PATH gotcha**: `pct exec 140 -- kb-stats` fails with `Failed to exec "kb-stats"`. Wrap in
    `bash -lc '…'` — `kb-rag/README.md`'s bare examples do not work.
- **CT 200 `bench-runner`** (`bench-runner/`): an *unprivileged* Debian LXC that benchmarks
  that endpoint. It auto-discovers CT 120's IP at provisioning time. It lives in the
  `200+` test/temporary range because it is disposable — destroy it when done. The suite is
  engine-neutral (it speaks OpenAI `/v1`), so it benchmarks either engine unchanged.
- **VM 300 `docker-host`** (`docker-host/`): a Debian **VM** (the *only* VM here, deliberately)
  running **Docker + Compose + Portainer CE**, which hosts the homelab's small self-contained web
  apps as Compose stacks — currently **MealDeal**
  ([github.com/marchah/mealdeal](https://github.com/marchah/mealdeal), the grocery-deal tracker
  the local AI codes features for), live on `:4000`, and **work-board** on `:4100` (a Linear +
  GitHub "what should I work on next?" board). ⚠️ work-board is the exception to the pattern
  below: its compose file lives in its own **private** repo `marchah/work-board` rather than
  in `docker-host/stacks/`, so Portainer needs both git and registry credentials for it.
  Apps here **do not consume a VMID each** —
  they are containers inside this VM, so a new project costs a compose file
  (`docker-host/stacks/<project>/compose.yaml`) plus a Portainer git stack, not a bespoke
  provisioning script. Stack secrets (e.g. `IMAP_PASSWORD`) are **Portainer stack env vars**,
  never in this public repo. ⚠️ **Why a VM when everything else is an LXC:** Proxmox recommends
  Docker in a VM; Docker-in-LXC needs `nesting=1`+`keyctl=1` (often privileged), puts `overlay2`
  on a container filesystem, tends to break after Proxmox kernel bumps, and shares a kernel with
  the host's own firewall rules that Docker also writes into. The GPU/LLM containers
  stay native LXCs — they need device passthrough and gain nothing here. MealDeal **pulls a
  prebuilt image**: its `Publish image` workflow publishes `ghcr.io/marchah/mealdeal` on every push
  to `main` (tags `main` + `sha-<short>`, plus semver from `v*`). The package is **public**, so
  anonymous pull works and Portainer needs no registry credentials — GHCR does not always default
  to private. Redeploys are a ~10 s pull; rollback is pinning a `sha-` tag. ⚠️ The stack sets
  **`pull_policy: always`** deliberately — without it a redeploy can reuse a stale local layer
  cache and silently keep serving the old build even though `main` moved. ⚠️ **Portainer has no
  health-gated auto-rollback** — a broken deploy stays broken until acted on (the compose
  healthcheck makes it *visible*, not self-healing). See `docker-host/README.md`.
  - **A per-app native LXC was tried and rejected** — one bespoke ~870-line script per app doesn't
    scale to a fleet of small projects, which was the whole point of the pivot to compose stacks.

VMIDs `120`/`121`/`122`/`123`/`140`/`200` and hostnames are defaults overridable via env vars (`VMID=`, `LXC_HOSTNAME=`, etc.).

## Common commands

All run on the Proxmox host as root.

```bash
# Provision the ops LLM-runtime container (CT 120) — GPU 1 of two Radeon Pro V620
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh # llama.cpp (llama-server), Qwen3.6-35B-A3B MoE
# Autonomous coding loop's GPU-2 model server (CT 123 gpu2) — llama-swap on GPU 2
./pro-v620/create-lxc-llama-swap-gpu2.sh          # qwen3.8-27b-dflash2 coder + thinkingcap-27b reviewer, swapped by name (:8080)
# The loop's execution sandbox (CT 122 coder-runner; runs npm/build/tests, needs CT 121's ssh pubkey)
CODER_SSH_PUBKEY="$(pct exec 121 -- cat /root/.ssh/coder-runner.pub)" ./coder-runner/create-lxc-coder-runner.sh
# The loop/orchestrator config that runs INSIDE CT 121 (profiles/skills/plugins/timers) — run from within CT 121
pct exec 121 -- bash -lc 'cd /path/to/Proxmox/hermes/config && ./install.sh'  # see hermes/config/README.md
# The knowledge-base retrieval service (CT 140 kb-rag) — a read-only KB deploy key is REQUIRED
DEPLOY_KEY_FILE=./cognitivestack-deploy ./kb-rag/create-lxc-kb-rag.sh
# Prior GPU (RX 6700 XT) — kept for reference; pick ONE engine (mutually exclusive)
./rx-6700-xt/create-lxc-lmstudio-qwen3.5-9b.sh    # LM Studio (lms)
./rx-6700-xt/create-lxc-llamacpp-qwen3.5-9b.sh    # llama.cpp (llama-server)

# Provision the Docker app-stack host (VM 300): Docker + Compose + Portainer CE.
# Hosts MealDeal and future small projects as compose stacks. Portainer UI on :9443.
./docker-host/create-vm-docker-host.sh
./docker-host/create-vm-docker-host.sh --reinstall-docker   # re-run ONLY the in-guest install
# Operate the app stacks — prefer the Portainer UI (https://192.168.1.250:9443); by CLI:
ssh pve 'ssh -i /root/.ssh/docker-host debian@docker-host'    # into the VM (host holds the key)
#   docker ps
#   docker compose -f /opt/stacks/mealdeal/compose.yaml logs -f
#   docker compose -f /opt/stacks/mealdeal/compose.yaml up -d --build

# Operate the KB retrieval service (CT 140). Same `bash -lc` PATH rule as the bench wrappers.
pct exec 140 -- bash -lc 'kb-stats'            # index commit, embed model, chunk/doc counts
pct exec 140 -- bash -lc 'kb-reindex'          # git pull + incremental reindex now
pct exec 140 -- bash -lc 'kb-reindex --full'   # drop + rebuild (required after an embed-model change)
pct exec 140 -- systemctl status kb-rag        # and: journalctl -u kb-rag / list-timers kb-reindex.timer

# Provision the benchmark runner (CT 200); auto-targets CT 120's API
./bench-runner/create-lxc-bench-runner.sh

# Run benchmarks (wrapper commands installed into the bench-runner LXC)
# Wrap wrapper commands in `bash -lc '…'` — bare `pct exec` PATH omits /usr/local/bin
pct exec 200 -- bash -lc 'llm-bench-baseline'     # single-user repeatable baseline
pct exec 200 -- bash -lc 'llm-bench-concurrency'  # throughput / tail-latency
pct exec 200 -- bash -lc 'llm-bench-soak'         # longer, surfaces thermal/memory pressure
pct exec 200 -- bash -lc 'llm-bench-quality'      # enables lm-eval (GSM8K smoke test)
pct exec 200 -- bash -lc 'llm-bench-env'          # print resolved config
pct exec 200 -- bash -lc 'llm-bench-compare /results/<baseline> /results/<candidate>'

# Override any knob per-run via env
pct exec 200 -- bash -lc 'BENCHMARK_REQUESTS=5 BENCHMARK_CONCURRENCY=2 llm-bench-baseline'
```

Both creation scripts support `--help`/`-h` and a large set of `VAR=value` overrides
(documented in each script's `usage()` and the folder READMEs).

### Linting

Scripts use `set -Eeuo pipefail` and carry `# shellcheck disable=...` directives, so
**shellcheck is the expected linter** for `.sh` files. There is no CI, Makefile, or
automated test harness in the repo.

## Architecture

### Provisioning scripts share one shape

Both `create-lxc-*.sh` scripts follow the same structure: top-of-file `readonly`/env-default
config block → small helper funcs (`die`, `log`, `require_root`, `require_command`) →
a `main()` that runs an explicit ordered pipeline (resolve template → create container →
configure → install → summarize). Heredocs (`<<'CONTAINER_SCRIPT'`) push self-contained
sub-scripts into the container via `pct exec ... bash -s`. Match this idiom when extending.

**GPU/model/engine scripts are intentionally narrow, not generic.** Per the README, each GPU
folder owns its own model/runtime assumptions (GPU runtime flags, context size, VRAM sizing).
A different GPU, model, *or inference engine* should get a *new* script, not a parameterized
mega-launcher — the RX 6700 XT has two sibling scripts (`...-lmstudio-...` and
`...-llamacpp-...`) serving the same model on the same GPU via Vulkan, and the V620 got a
brand-new folder/script (`pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh`) for its larger
32 GB / MoE model rather than a flag on the 6700 XT script.
Both GPUs use Vulkan (mesa RADV) — Navi 22/gfx1031 on the 6700 XT, Navi 21/gfx1030 on the
V620 — the container installs `mesa-vulkan-drivers` and passes through the GPU render node. With
**two V620s** installed, CT 120 bind-mounts **only GPU 1's** render node (by PCI address, via the
`by-path` symlink), so llama.cpp sees one Vulkan device and runs the model on that card while GPU 2
stays idle; plus a pinned model repo/file/SHA-256 in a privileged container. (The V620
model is a single-file unsharded GGUF, so the download/verify path is unchanged; on 32 GB it
defaults to ctx 262144 / `--parallel 2` (the model's ~256k native max, 128k per slot; this
MoE's KV cache is cheap, ~20 KB/token, ~29.8 GiB total at Q5). It was `--parallel 4` (64k/slot),
but qwen3.6's uncapped reasoning could fill a whole 64k slot with `<think>` and return
`finish_reason='length'` with no answer (Hermes "Thinking Budget Exhausted"); 128k/slot leaves
room for reasoning + answer. A single agent needing the whole 256k window uses
`llamacpp-reload 262144 1`; tunable via `llamacpp-reload`.)

Engine differences that matter when extending the llama.cpp script:
- It installs a **pinned prebuilt Vulkan `llama-server` release** (tag + tarball SHA-256 in
  the config block; bump both from the ggml-org/llama.cpp releases page). It extracts to a
  flat `llama-<tag>/` dir and symlinks `/opt/llamacpp/current`. It also installs the
  **libglvnd/EGL stack** (`libglvnd0 libgl1 libglx0 libegl1`) on top of `mesa-vulkan-drivers`
  — without it the Mesa ICD loader can silently report **zero** Vulkan devices in the container.
  - **Both CT 120 and CT 123 run llama.cpp `b10678`; llama-swap is pinned at `v250`.** Prior
    llama.cpp builds are left in `/opt/llamacpp/` and the previous llama-swap binary kept as a
    `.bak`, so **rollback is a symlink flip / file copy**.
    ⚠️ **Bump the pins in the scripts, not just live** — they had drifted several builds behind
    because earlier bumps were applied on the box only. After any bump verify: both cards' RADV
    init (the loud-guard passes), CT 120 serving, every llama-swap model registered, and
    speculation still active on the coder.
  - ⚠️ **`llama-bench` cannot use the production `--batch-size 4096`** on this card: with 24.76 GiB
    of weights resident it dies with `radv/amdgpu: Not enough memory for command submission` at
    context creation. `-b 2048 -ub 1024` is the largest configuration that fits and is what the
    numbers above use. It also has **no `-c` flag** — context comes from the test params, and
    `--fit-target` is the auto-fit path this repo avoids on RADV (see the GTT-spill note).
- LM Studio hot-reloads context/parallel via `lms load`; **llama.cpp sets them as start-time
  flags**, so its container ships a `llamacpp-reload <ctx> <parallel>` helper (rewrites
  `/etc/llamacpp.env` + `systemctl restart`) and a `Type=simple` service running
  `/usr/local/bin/llamacpp-serve`.
- `llama-server --alias <id>` makes `/v1/models` report a stable id (else it reports the
  model file path); that id is what the bench-runner records as `MODEL_IDENTIFIER` (the V620
  serves `qwen3.6-35b-a3b`, the 6700 XT served `qwen3.5-9b`). The bench-runner auto-detects
  it from `/v1/models` at provision time; `ansible/benchmark.yml` and `host/run-context-sweep.sh`
  default `model_key`/`MODEL_KEY` to `qwen3.6-35b-a3b`, and the ansible run re-points an existing
  CT 200's `MODEL_IDENTIFIER` to it each run (so a model swap can't leave preflight stale).

### Dual-mode install (critical gotcha)

`bench-runner/create-lxc-bench-runner.sh` installs the suite into `/opt/bench-runner`
**two different ways** (`install_benchmark_suite`):

1. **Local checkout present** → `copy_local_benchmark_suite` tars up `scripts/`, `config/`,
   and the `*.md` docs and pushes them in.
2. **Run standalone via `wget | bash`** (no checkout) → `download_benchmark_suite` curls
   each file individually from GitHub raw using a **hardcoded file list**.

⚠️ When you add or rename a file under `bench-runner/scripts/` or `bench-runner/config/`,
you MUST also add it to the hardcoded `files=( ... )` array in `download_benchmark_suite`,
or the standalone install path will silently ship an incomplete suite.

`kb-rag/create-lxc-kb-rag.sh` mirrors this idiom for `kb-rag/app/` — same two paths, same trap,
different array name: **`APP_FILES=( ... )`** near the top of the script (alongside
`REPO_RAW_BASE`). Adding or renaming anything under `kb-rag/app/` without updating it ships a
broken service on the standalone path.

### Benchmark orchestration

`bench-runner/scripts/benchmarks/run-ai-benchmark-suite.sh` is the engine. Flow:

1. **Layered config** (process env wins, because every file default uses `: "${VAR:=...}"`
   — including `MODEL_API_URL`/`MODEL_IDENTIFIER`, so a per-run override actually takes
   effect): `config/local-model.env` (written at provisioning: the model's
   `MODEL_API_URL`, the discovered `MODEL_IDENTIFIER`, `RUN_*` toggles) → the profile file
   named by `BENCHMARK_PROFILE` (`config/benchmark-profiles/<name>.env`) → process env.
2. **Preflight** (unless `BENCHMARK_PREFLIGHT=false`): GETs `<MODEL_API_URL>/models` and
   aborts before any work if the endpoint is unreachable (exit-path "unreachable") or
   `MODEL_IDENTIFIER` is not in the served list. This is the loud-failure guard against a
   stale/wrong URL or model id from provisioning time.
3. For each enabled target, `run_with_telemetry` launches `system-sampler.py` in the
   background, runs the benchmark, then records `status.json`.
4. Writes `manifest.json`, `versions.json`, captures before/after `system-logs/`, evaluates
   SLOs (`evaluate-slos.py` against `config/benchmark-slos/default.json`), and renders
   `REPORT.md` + `SLO.md` (`write-benchmark-report.py`).

**Metric scope:** the bench-runner LXC is unprivileged with no GPU passthrough, but
`system-sampler.py` still reads the host's `/sys/class/drm` + hwmon, so it *does* capture
GPU utilization, VRAM, core clocks, and amdgpu/CPU temps (a baseline run recorded 99% GPU
util, 7.24 GiB VRAM, 103 °C junction) — and the GPU/temperature SLO checks in `default.json`
run from here. Caveat: `gpu_busy_percent` is only meaningful under active load and can return
`EBUSY`, so judge GPU-vs-CPU by throughput, not an idle sample. (llama.cpp holds the model in
VRAM, so `mem_info_vram_used` stays high even idle — the pre-allocated weights + KV — unlike
engines that free VRAM between requests.)
Trust the per-run telemetry peaks. `evaluate-slos.py` still skips any check whose data is
genuinely absent. **CPU/RAM/process metrics from the in-LXC sampler are lxcfs-virtualized to
CT 200 — they describe the benchmark *client*, not the model server (llama.cpp on CT 120).** To judge whether the model
server itself was CPU/RAM-bound, the Ansible batch wraps each run with
`host/run-with-target-telemetry.sh`, which samples CT 120 from the host and merges a
`target-telemetry.jsonl` into each `/results/<run-id>/`. Don't cite the in-LXC CPU/RAM numbers
as the server's. After merging, the wrapper re-runs `finalize-run.py` so `REPORT.md`/`SLO.md`
incorporate the server telemetry (a "Model Server Telemetry" report section + a
`model-server-target` SLO check) — the suite generated them in-container *before* the merge,
so regeneration is what makes the data count. The batch sets `REQUIRE_TARGET_TELEMETRY=true`,
so a run that captures no server samples fails (manual `run-with-target-telemetry.sh` runs
default to opt-out).

**`RUN_*` toggles gate each benchmark target**: `RUN_OPENAI_DIRECT`, `RUN_LLAMA_BENCHY`,
`RUN_LM_EVAL`. The runner targets only the LLM runtime's OpenAI endpoint, so it runs
`openai-direct` + `llama-benchy` by default; `lm-eval` runs only in the `quality` profile.
The Hermes, raw `llama-bench`, and vLLM benchmark paths were removed — they couldn't run in
this unprivileged, OpenAI-API-only LXC. The suite's built-in `SCENARIOS` (smoke/short/medium/
long) remain only as a manual `--scenario` fallback; every profile uses the promptset.

The `llm-bench-*` wrappers in `/usr/local/bin` are thin: they `source /etc/bench-runner.env`,
set `BENCHMARK_PROFILE`/`BENCHMARK_RUN_ID`, and exec the suite. They are generated inline by
`configure_benchmark_environment` in the creation script — edit them there, not by hand.

### Bottleneck tooling (the goal is hardware/infra limits, not model quality)

- **`run-sweep.py`** (wrapper `llm-bench-sweep <concurrency|input-length>`): drives
  `benchmark-openai-api.py` across a parameter and writes `curve.json`/`curve.md`. Relies on
  the `--synthetic-input-tokens`/`--synthetic-output-tokens` controlled-workload flags added
  to `benchmark-openai-api.py`. Client-side; finds the saturation knee / TTFT scaling.
- **`summarize-telemetry.py`**: reduces any `telemetry.jsonl` to peak GPU util, VRAM
  ratio, core-clock range (throttle hint), temps, and min free RAM. AMD-DRM and NVIDIA aware.
- **`host/` directory** — Proxmox-host orchestration, **not** shipped into the LXC (the
  local-copy tar and the download list both exclude it; these need `pct`). `run-with-host-
  telemetry.sh` samples a container's GPU during any bench command — largely **redundant**,
  since the in-LXC sampler already records GPU telemetry; keep it only for sampling around a
  non-benchmark command. `run-with-target-telemetry.sh` is the non-redundant counterpart: it
  pushes `system-sampler.py` into the *model* container (CT 120) and runs it there during a
  bench, so CPU/RAM/process metrics reflect the model server, llama.cpp (not the bench-runner
  client); the Ansible batch wraps every run with it and merges `target-telemetry.jsonl` into
  the result. `run-context-sweep.sh` reloads the model at each context length and correlates
  VRAM with TTFT/latency/throughput — still useful, because the per-context reload is the part
  the in-LXC suite can't do. The model-reload path is **llamacpp-only**: `ansible/benchmark.yml`'s
  `runtimes` map carries the `llamacpp` entry (`reload_cmd` + `target_process_patterns` + results
  `label`) and `host/run-context-sweep.sh` calls the container's `llamacpp-reload <ctx> <parallel>`
  (restart, blocks until `/health` is ready). Drive it with `make bench` / `make context-sweep`.
  (The prior RX 6700 XT also had an `lmstudio` runtime; it was removed with that card — the
  `rx-6700-xt/` scripts keep it for reference.)

### Results & data model

Every run writes a self-contained folder `/results/<run-id>/` (run-id defaults to a UTC
timestamp + profile). Output is plain JSON/JSONL/Markdown by design (no Prometheus/Grafana)
so runs diff and archive cleanly. Per-target subdirs hold `telemetry.jsonl`, `stdout.log`,
`stderr.log`, `status.json`, plus benchmark-specific request JSONL/summary JSON. See
`bench-runner/BENCHMARKS.md` for the full telemetry schema and experiment matrix.

### Remote vs in-container execution

- `sync-benchmark-run.sh <ssh-host> <remote-run-dir> [desc]` — copies a finished server-side
  run back to a local checkout and regenerates `REPORT.md` (run benchmarks on the server first).
- `run-remote-benchmark-suite.sh` — uploads suite, runs on a server over SSH, pulls results;
  reads creds from a `config/.env` (gitignored).

## Conventions

- **VMID allocation** (homelab-wide scheme — pick a new script's default `VMID` from the
  matching range):
  - `100-119` — infra / services (currently empty; CT 110 `mealdeal` lived here until the app
    moved into the Docker host — small web apps are now containers on VM 300, not LXCs)
  - `120-139` — AI/LLM containers (CT 120 LLM runtime, hostname `llamacpp`, pinned to GPU 1 of two V620s; the
    prior 6700 XT also offered an `lmstudio` variant. CT 121 `hermes` — the Hermes Agent that
    consumes CT 120's API. CT 122 `coder-runner` — the coding loop's execution sandbox; CT 123 `gpu2` —
    a `llama-swap` server on GPU 2 for the loop (`qwen3.8-27b-dflash2` coder + `thinkingcap-27b`
    reviewer, swapped one at a time))
  - `140-159` — databases (CT 140 `kb-rag` — the CognitiveStack hybrid-search API; it lives here
    rather than in the AI range because the durable artifact is a vector+FTS **database**, even
    though its consumers are agents)
  - `200+` — test / temporary (CT 200 `bench-runner` — disposable benchmark LXC)
  - `300+` — **VMs** (VM 300 `docker-host`). The ranges above allocate *containers*; VMs get their
    own range so `pct`/`qm` ids never collide. Apps running as Docker containers on VM 300 do not
    take a VMID at all.
- **Autonomous coding loop / execution isolation (`coder-runner/`, CT 122).** The homelab runs a
  self-driving coder↔reviewer loop on **Hermes kanban** (CT 121): coder/reviewer *profiles* work each task
  in an isolated git worktree/branch, PR-gated (no auto-merge to public `main`). The loop's design rule is
  that **untrusted project code executes only on a separate, generic, disposable LXC — CT 122
  `coder-runner`** (Node + pnpm + git + toolchain, holds no secrets), never inside the Hermes LXC. CT 121 drives
  it over **ssh+rsync** via `checks-on-runner`/`run-on-runner`/`verify-and-commit` helpers (committed under
  `hermes/config/bin/` and deployed into CT 121 by `hermes/config/install.sh`). Key facts learned the hard
  way: Hermes does **not**
  auto-commit managed worktrees and the local model won't reliably run `git`, so commits are made
  deterministically by `verify-and-commit` (checks on CT 122 → commit on the CT 121 host on green); a fix
  task must use `--workspace worktree:<absolute-repo-path>` (plain `worktree`+`--project` fails when created
  from inside a worker); keep worktrees out of the repo tree to avoid `git add -A` swallowing them as
  gitlinks. `coder-runner/create-lxc-coder-runner.sh` provisions CT 122 (once; repo-agnostic — add repos via
  `hermes project`, never a new LXC). See `coder-runner/README.md` and the `autonomous-coding-loop` memory.
  The loop's CT-121-side config (coder/reviewer profiles, the loop helper scripts under `hermes/config/bin/`,
  the `codex-review`/`completion-gate` plugins, the loop's `scope-and-plan`/`review-pr` skills, and the
  `loop-watchdog`/`backlog-tick`/`pr-revise-tick` systemd timers) is committed under **`hermes/config/`**
  (loop/orchestrator only — the box's unrelated KB/homelab automations are not tracked) with an idempotent
  `install.sh` — run it inside CT 121 to (re)deploy. Private Slack channel IDs are parameterized to env vars
  sourced from `/root/.hermes/.env` (see `hermes/config/hermes.env.example`); never commit the real `.env`.
- **Token accounting (`hermes/token-usage-collector/`, CT 121).** llama.cpp exposes
  `llamacpp:prompt_tokens_total`/`llamacpp:tokens_predicted_total` at `/metrics` (CT 120 runs
  `--metrics`; without it that route 501s), but they are **counters since process start** and reset on
  every restart — and restarting is the prompt-cache-corruption remedy, so it happens. A 5-minute
  systemd timer inside CT 121 folds each scrape's delta into a durable daily ledger at
  `/root/.hermes/token-usage/` (under the Hermes home so the weekly pricing job can read it).
  Query with `pct exec 121 -- bash -lc 'token-usage-report --month
  YYYY-MM'`. Same idempotent `install.sh` + systemd + `.env` idiom as the `pro-v620/` host services, but
  it runs **inside CT 121**, not on the host. ⚠️ Every total is a **floor** — tokens served between the
  last scrape and a restart are unrecoverable.
  ⚠️ **The ledger is deliberately NOT in the git config backup**: `daily.jsonl` gains a row and
  `state.json` is rewritten on *every* 5-minute scrape, so they churned the diff on every run, and
  that backup is meant to show what Hermes *changed*, not operational counters. Its only off-box
  copy is therefore the **weekly Sunday vzdump of CT 121** — a ledger loss between vzdumps is
  unrecoverable, on top of the floor caveat above.
  It collects **two sources with different semantics, which must never be summed**:
  - `endpoint` — the `/metrics` scrape above. Covers **every** client of CT 120 (including OpenCode on
    the Mac), no attribution, resets on llama-server restart.
  - `hermes_accounted` — Hermes' own `session_model_usage` table in `state.db`, keyed by
    `session_id|model|billing_provider|task` (unique). Covers only what **Hermes** spent, attributed per
    model, exact, never resets, and carries cache-read/reasoning/call counts. This is the **only** place
    cloud usage appears — a model reached over `openai-codex` (the weekly pricing cron runs on
    `gpt-5.6-terra`) never touches CT 120. Codex rows come back `cost_status: included`, i.e. free at
    the margin under the ChatGPT plan, so they are not "spend" the way metered API tokens are.
    ⚠️ `TOKEN_USAGE_DB_PROVIDERS` must **exclude** `custom`/`auto`/empty — those are CT 120 traffic the
    endpoint source already counts, so including them doubles every local token.
  ⚠️ **CT 123 (`gpu2`) is deliberately not covered** for non-Hermes traffic:
  llama-swap's `:8080/metrics` is host telemetry (CPU/memory/swap) with no token counters, and it
  unloads/reloads models on demand so per-model counters would reset on every swap. (Anything *Hermes*
  sends to a cloud provider is captured regardless of host, via the second source.)
- Keep downloaded model weights and generated results out of git (already covered by
  `.gitignore`: `models/`, `results/`, `artifacts/`, `bench-results*.tgz`, `.env*`).
- Container model storage (`/models`) uses `backup=0` — weights are large and
  re-downloadable; back up container config / service files / small state separately.
- ⚠️ **`backup=` works on MOUNT POINTS only, never on `rootfs`.** PVE rejects it outright
  (`rootfs.backup: property is not defined in schema`) — a container's root disk cannot be
  excluded from `vzdump`. Several scripts here append `backup=0` to the `rootfs` line behind a
  `>/dev/null 2>&1 || true`, so that step is a **silent no-op** (verified on pve-manager 9.2.3);
  don't trust the comment above such a line. Note the defaults are inverted: `rootfs` is always
  backed up, while a mount point defaults to `backup=0` and needs `backup=1` set explicitly. To
  keep a big rootfs out of backups, exclude paths in the backup job instead:
  `vzdump <vmid> --exclude-path /opt/<bulk>`.
- **Backups (`Synology-Backup` NFS, weekly job Sundays 01:00, all guests, keep-last=3).** Two
  traps here, both of which have caused a silent multi-week outage:
  - ⚠️ **The Synology allow-lists NFS clients by IP**, so a change to the host's address breaks
    every backup with `mount.nfs: access denied by server` — silently. Fix in DSM (Control Panel →
    Shared Folder → NFS Permissions). It is allow-listed by the **exact IP**, so *another host IP change breaks
    backups again* — prefer a `192.168.1.0/24` rule.
  - ⚠️ **`vzdump` needs `tmpdir: /var/tmp` in `/etc/vzdump.conf`** (set; comment in-file). Its
    temp dir defaults to the *target storage*, and for an **unprivileged** container `tar` runs
    under `lxc-usernsexec` as uid 100000+, which this NAS refuses even though the share reports
    mode 777 (root writes fine). Symptom is a mounted-and-active storage that still fails with
    `Cannot open: Permission denied`. Only small config files go to tmpdir; archives stream
    straight to the NAS. Verified across all four paths — stopped CT, running unprivileged CT
    (snapshot), privileged CT, and QEMU VM.
  - A container **rootfs cannot be excluded** from these backups (see the `backup=` note above),
    but a `backup=0` mount point can — which is why CT 120's `/models` is not in its 3 GB archive.
  - `Synology-Backup` is the **only** NFS storage, deliberately. To give a future container media
    from another share, **bind-mount the path instead of adding a storage**:
    `pct set <vmid> --mp0 /mnt/pve/<mount>,mp=/media` — an NFS storage declaring `content rootdir`
    is a trap (LXC rootfs over NFS is slow and hits the uid-mapping problem above).
  - The Docker host's precious state is its **volumes** (`portainer_data`,
    `mealdeal_mealdeal-data`) — see `docker-host/README.md` for pulling those out separately.
- **Notifications go to Slack, not just root's mailbox.** Proxmox's builtin `mail-to-root` target
  delivers to a local mailbox nobody reads, which is how a backup outage stayed silent for weeks. A
  `slack` webhook endpoint + `slack-all` matcher now forward **every** notification to Slack
  *alongside* mail-to-root. Provisioned by `host-notifications/setup-slack-notifications.sh`
  (re-run it to rotate the URL). The webhook URL path is stored as a Proxmox notification
  **secret** — the API returns only its name, never the value, so it stays out of
  `notifications.cfg` and out of `pvesh get` output.
- The GPUs are driven via **Vulkan** (mesa RADV). The host now runs **two Radeon Pro V620s**
  (Navi 21/gfx1030); the prior RX 6700 XT (Navi 22/gfx1031) is kept only for reference. The
  container installs the Vulkan userspace (`mesa-vulkan-drivers libvulkan1 vulkan-tools`) and
  passes through **only GPU 1's** render node (bind-mounted by PCI address via the `by-path`
  symlink), so llama.cpp offloads all layers (`-ngl 99`) onto that single card; verify with
  `vulkaninfo` / `llama-server --list-devices` (exactly one device) and a non-trivial
  `mem_info_vram_used` on GPU 1 (read by PCI address — `cardN` is not stable) with GPU 2
  near-idle. The bind's dest node name is resolved at provision, so a host DRM renumber (only
  on a GPU add/remove or kernel change) needs GPU 1's mount re-resolved in place (rewrite the
  two entries + restart the CT — see the README "Recovering after a DRM renumber" recipe; a
  plain re-run is rejected while the CT exists). The `llamacpp-serve` guard turns the
  otherwise-silent CPU fallback into a loud startup failure.
- ⚠️ **The two PCIe slots are NOT equivalent — GPU 2 pays a fixed per-token decode tax.**
  GPU 1 is Gen4 x16, GPU 2 is Gen3 x4 off the chipset. The penalty is a **fixed ~4 ms per decoded
  token**, not a percentage — constant across depths and confirmed on two architectures. So it
  hurts FAST models most: ~4 ms on this MoE's 12 ms token is **−22%**, but on a dense 27B's 53 ms
  token only −7%.
  - **Never move `qwen3.6-35b-a3b` to GPU 2** — it would surrender ~22% of decode. The dense loop
    models on CT 123 are correctly placed and barely notice.
  - **GPU 2 is the *stronger* card** — it wins every prefill test and sustains higher clocks, yet
    loses ~20% of decode. Prefill batches thousands of tokens per submission and amortises the
    interconnect round-trip away; decode issues one token at a time and pays it every token. So a
    physical slot swap is unnecessary to rank the two cards.
  - ⚠️ **`current_link_speed` / `current_link_width` LIE** — both report `16.0 GT/s PCIe x16` for
    *both* cards. Ground truth is the starred line of `pp_dpm_pcie`. Closing the gap needs slot
    bifurcation in BIOS, blocked by the host having no video output — so the headless-BIOS problem
    gates ~22% of MoE decode on GPU 2, not merely C-states.
  - Harness: **`pro-v620/gpu-ab-bench/`** (host-side, NOT a service). Read its README before
    re-running: it carries the interleaving method, the "verify every control" checklist, the
    ⚠️ **revert `ct123-dual-gpu.sh` before production returns** rule, and the output-sanity gate.
- **V620 host-side GPU services live under `pro-v620/` and run on the Proxmox host (NOT in the
  LXC)**, each with an idempotent `install.sh` + systemd unit + `.env`. `pro-v620/fan-control/`
  runs one `gpu-fan-control@<instance>` per **controllable fan channel** (out-of-tree `nct6687`) —
  currently a single **`@hub`→pwm2** driving BOTH cards' 9733 blowers through a SATA-powered PWM
  hub on the PUMP FAN header (curve tracks the hotter card; a required sensor missing on either
  forces 100%). Each card has its own blower, so only the *control signal* is shared.
  ⚠️ **Only `PUMP_FAN1` can control an externally-powered fan on this board** — the `SYS_FAN*`
  headers are in DC (voltage) mode, so their pin 4 carries no PWM signal and a SATA-powered fan
  free-runs at 100 % there forever. No software fix exists (no `pwm*_mode`, firmware-configured,
  Nuvoton publishes no NCT6687D register map, and this host has no video output to reach BIOS);
  CoolerControl/`fancontrol` cannot help — they write the same sysfs files. ⚠️ **A tach reading
  proves NOTHING about control**: a 4-pin fan with no PWM signal reports RPM perfectly while
  ignoring every duty change, which cost ~2 weeks of misdiagnosis (a fan and a hub were each
  wrongly declared dead). Confirm control by driving the channel to 0 and checking the fan STOPS.
  ⚠️ The hub returns a tach from its **RED port only**, so one blower's failure is invisible to the
  tach watchdog. Each instance pins its GPU(s) by PCI address and is driven off the card temp(s);
  `pro-v620/undervolt/` applies a persistent GFX **voltage offset** to **every** V620
  (both at −100 mV). The V620's board power
  is **firmware-locked at 250 W** (`power1_cap` write of any other value → `-EINVAL`) and
  OverDrive exposes no clock-ceiling knob, so an undervolt is the only power/thermal lever
  (−100 mV ≈ −18 % power / −8 °C peak junction at flat throughput). The undervolt installer also
  enables OverDrive via `/etc/modprobe.d/amdgpu-overdrive.conf` (needs a reboot to take effect).
- **A last-resort GPU over-temp watchdog lives under `pro-v620/gpu-thermal-watchdog/`** (also
  host-side, NOT in an LXC; same idempotent `install.sh` + systemd unit + `.env` idiom, but no
  kernel module — it only *reads* amdgpu hwmon). It watches junction/mem on both V620s and, if
  either crosses a trip temp (default **102 °C** junction / 101 °C mem — deliberately **above**
  the 100 °C hardware throttle, **below** the 105 °C emergency reset), gracefully stops the LLM
  server (`pct exec 120 -- systemctl stop llamacpp`) so the card cools before the hardware has to
  reset it (a MODE1 reset corrupts the running inference). Failure philosophy is the **opposite**
  of the fan controller's: stopping the model is disruptive, so a missing sensor is logged and
  skipped rather than treated as over-temp (the 105 °C hardware emergency is the final backstop).
  ⚠️ **Treat a trip as a real fault** (a seized blower, a detached hub lead), not as normal
  saturation — with a blower per card, both saturated at once settle around 62/73 °C on the
  production curve with fan headroom left.
  ⚠️ **A DENSE model, not big-context MoE prefill, is the thermal worst case** — a dense 27B pins
  the firmware-locked 250 W cap (peaks ~84/88 °C) while the 3B-active MoE is memory-bound and never
  reaches it (~73/74 °C at ~220 W). Margin to the 102 °C trip is ~28 °C on the MoE but only
  **~14 °C on a dense model**, so do not quote the MoE figure as the worst case.
  ⚠️ **It CANNOT protect a hand-driven load.** It stops the CT's model *service*
  (`systemctl stop llamacpp` / `llama-swap`), which is a no-op against a `llama-bench` or
  `llama-server` you launched yourself — the 105 °C hardware MODE1 reset then becomes the only
  backstop. Run an independent guard alongside any manual benchmark: poll `temp2_input` on both
  cards every 2 s and `pkill -f llama-bench` at ~100 °C.
- **Host networking.** The host is on the LAN at static **`192.168.1.93`**, with `vmbr0` bridging
  its NIC. Containers and VMs keep `ip=dhcp` and each takes **its own lease from the LAN router**,
  so every service is reached directly on its own IP and by hostname (the router serves DHCP
  hostnames under domain `lan`). ⚠️ Give each guest a **DHCP reservation on the router** — the
  leases are dynamic, and anything pinned to an address goes stale when one moves.
