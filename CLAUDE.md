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
  Load-tested 2026-08-22 with both cards saturated at once: GPU 1 62 °C / GPU 2 73 °C at 51 % fan,
  ~29 °C of margin to the watchdog trip — thermals are not a constraint on this box. CT 120 is **pinned to GPU 1 alone** (`0000:2d:00.0`): its
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
      into the provisioning script (so a rebuild keeps it) and applied live on 2026-08-11.
      Because Hermes' default provider `custom` points here, **this is also the Hermes default** —
      there is no separate Hermes setting. Measured on the same prompt, before → after: 76.4 s / 6,000 tokens (hit the cap) /
      12,262 chars of reasoning / **470-char answer** → 26.0 s / 2,045 tokens / **0** reasoning /
      **4,930-char answer**. Thinking was consuming the whole budget and returning a truncated
      reply — that is the `Thinking Budget Exhausted` failure, on demand.
      - Rationale: on KB ingestion (the only real Hermes consumer now; the daily reports moved to
        an OpenAI subscription) reasoning was ~80 % of the token spend and produced a *shorter*
        entry — 5× faster at the same 6/6 template sections. It removes the thinking-budget failure
        structurally instead of sizing slots around it.
      - ⚠️ **`--reasoning off` ≠ `--reasoning-format none`** (both now present). The latter only
        decides *where* thought tags go; it does not stop them being generated.
      - ⚠️ **Do not try to do this from Hermes.** `hermes --reasoning none` does **not** reach a
        bare `custom` OpenAI endpoint — measured 2,845 → 2,656 output tokens (~7 %), versus ~3.5×
        when thinking is genuinely off — and it does not even reject an invalid level. Hermes'
        reasoning-effort abstraction targets providers with a native parameter. Server-side or
        nothing.
        ⚠️ **This was measured on b10361 and is now BUILD-DEPENDENT.** b10587 (deployed 2026-08-22)
        *does* accept a native per-request `reasoning_effort`, verified against b10361 which ignored
        it byte-identically. So the premise of this rule no longer holds — see the reasoning matrix
        under CT 123. Whether `hermes --reasoning` now reaches through has NOT been retested.
      - ⚠️ The flag lives in the **serve script**, not `/etc/llamacpp.env`, so it survives
        `llamacpp-reload` (which rewrites only ctx/parallel).
      - **Two knobs are now over-provisioned** (deliberately left alone): `MODEL_PARALLEL=2`
        (131k/slot) was chosen *because* reasoning filled slots, so `4` (65k/slot) is viable again
        for 2× concurrency; and Hermes `context_length: 65536` was set to deliberately half a slot
        so the prompt could not crowd out reasoning output, which no longer applies.
  - `pro-v620/create-lxc-llama-swap-gpu2.sh` — **CT 123 `gpu2`** on GPU 2: a `llama-swap` proxy for the
    autonomous coding loop that hot-swaps between a coder model (Qwen3.8-27B, alias
    `qwen3.8-27b-mtp`) and a reviewer model (ThinkingCap-Qwen3.6-27B, alias `thinkingcap-27b`),
    one resident at a time (OpenAI API `0.0.0.0:8080`, pick model by name).
    Same single-GPU pin idiom (`GPU_PCI_ADDRESS=0000:06:00.0`, by-path, REAL node name) + the loud-guard.
    The loop's dispatcher is serialized (`kanban.max_in_progress: 1`) so swaps fire only at role handoffs.
    - 🔴 **The coder is a THINKING model whose default effort NEVER ANSWERS, and no entry sets a
      `--reasoning` flag.** `llama-server`'s `--reasoning` defaults to `auto` (detect from template),
      so Qwen3.8-27B reasons without bound: measured 2026-08-22 at 8000 tokens / **32,901 chars of
      reasoning with `content` still empty**, `finish_reason: length`. `--n-predict 32768` is the
      only bound, so a request can burn 32k tokens and return nothing — the same "Thinking Budget
      Exhausted" failure CT 120 fixed with `--reasoning off`. Reproduced identically on b10361, and
      the chat template is byte-identical across the 2026-08-20 requant (`12827f24b742ea4e`), so this
      is long-standing behaviour, not a regression from either bump.
    - ✅ **Reasoning is controllable BY THE CLIENT, per request — which is better than a global
      server flag, because the loop can pick per task.** Measured against `qwen3.8-27b-mtp`:

      | client-side parameter | effect |
      | --- | --- |
      | `chat_template_kwargs: {"enable_thinking": false}` | **works** — 746 tok, `stop`, 2,659-char answer, reasoning 0 |
      | `reasoning_effort: "low"` | **works** — 1770 tok, 3,945 ch reasoning, 3,158 ch answer |
      | `reasoning_effort: "medium"` | **works** — 2240 tok, 4,664 ch reasoning, 4,219 ch answer |
      | `reasoning_effort: "high"` / unset | runs away — 18,112 / 17,306 ch reasoning, **no answer** |
      | `reasoning_effort: "none"` | ✅ **works, and is BYTE-IDENTICAL to `enable_thinking:false`** — 746 tok, same 2,659-char content, same sha `7eea1bc7ec28`. **Prefer this**: same code path, but the canonical OpenAI spelling and portable to other servers, whereas `chat_template_kwargs` is llama.cpp-specific. Available since PR #26045 (2026-07-24), so it worked on b10361 too — unlike `low`/`medium`, which needed PR #26941 (2026-08-14). |
      | `reasoning_budget: N` | ⚠️ **silently ignored** (byte-identical to control) — server-only |
      | `chat_template_kwargs: {"thinking_budget": N}` | ⚠️ silently ignored, same |
      | `/no_think` prompt suffix | ⚠️ ignored |
      | `reasoning_effort: "minimal"` | ⚠️ **HTTP 500** — an invalid level crashes the request rather than being rejected |

      - **Unset behaves like `high`**, which is why the default never answers. `low`/`medium` both
        complete cleanly *and* run slightly faster (32.2 / 31.3 vs 28.5 tok/s).
      - **On/off and effort are client-side; BUDGET is server-side only.** The robust shape is both:
        clients send `reasoning_effort` per task, and the server sets `--reasoning-budget N` as a
        floor so a client that sends nothing cannot run away. Hard-coding `--reasoning off` would
        work but takes the choice away from the loop.
      - ✅ **`reasoning_effort` support is NEW in b10587 — b10361 silently ignored it.** Verified by
        running the identical request set against b10361 with the same model/drafter/flags: `unset`,
        `low` and `medium` all returned **byte-identical** output (17,333 reasoning chars each, zero
        content). At temperature 0 identical output proves the parameter had literally no effect. On
        b10587 the same three give 17,306 / 3,945 / 4,664 chars. So the bump did not just ship fixes
        — **it unlocked per-request reasoning control that did not exist before.**
      - ⚠️ **Therefore the "Server-side or nothing" rule under CT 120 above is now BUILD-DEPENDENT
        and probably obsolete.** It was correct on b10361 (llama.cpp had no native reasoning-effort
        parameter, so Hermes' abstraction had nothing to target); b10587 has one. Retesting
        `hermes --reasoning <level>` against CT 120 is now worthwhile — if it reaches through, CT 120
        could move from the global `--reasoning off` to per-task control. Not yet retested.
    - ⚠️ **It serves more than the coder/reviewer pair** — plus general and evaluation models, all
      **live-only in `/etc/llama-swap/config.yaml`, deliberately not baked into the script** (they
      change as models are trialled). **As of 2026-08-22 there are FOUR:**
      `qwen3.8-27b-mtp` (coder), `thinkingcap-27b` (reviewer) · `qwen3.6-35b-a3b` (general) ·
      `muse-glimmer-30b` (speculative/eval).
      A rebuild from the script yields only the bootstrap pair — re-add the rest by hand.
      That list is the served set; treat anything absent from it as not available.
      ⚠️ **`qwen3.8-27b`, `qwen3.6-27b` and `ornith` were RETIRED 2026-08-22**, freeing 43.4 GB
      (`/models` 77 % → 51 % used). `qwen3.8-27b` was the unaccelerated A/B control and thermal
      fallback for the coder; **the thermal case for it is gone** — with a blower per card a full
      solo load lands at 73-88 °C, ~14-28 °C under the trip, so no non-speculative fallback is
      needed. Its GGUF is **retained** because `qwen3.8-27b-mtp` shares it; only the alias went.
      The other two had their weights deleted and are restorable:
      `unsloth/Qwen3.6-27B-GGUF` → `Qwen3.6-27B-UD-Q5_K_XL.gguf` (etag `ac310abf2895aa39…`) and
      `ornith-ai/Ornith-1.0-35B-GGUF` → `ornith-1.0-35b-Q5_K_M.gguf` (etag `325b351fc30a4114…`),
      both verified live before deletion. ⚠️ Also deleted: `Qwen3.6-27B-DFlash-Q8_0.gguf`, which is
      **NOT re-downloadable** — its provenance was never established (it matched no published
      repo). Recorded sha256 `c37b84724fa58cc5c6b545d8b96f8617a8c3bd7f018bf608feef4d3460e0575e` in
      case it ever surfaces. Losing it costs the DFlash arm of
      `pro-v620/gpu-ab-bench/spec-sweep.sh` (now loudly skipped); `dflash-kquant.gguf` remains, so
      DFlash coverage survives via `muse-glimmer-30b`.
      - ⚠️ **A MATCHED drafter beats a borrowed one — search HF for `MTP` too, not just `DFlash`.**
        Qwen ships no DFlash drafter for Qwen3.8, so the coder borrowed Qwen3.6-27B's head. Qwen3.8
        has its own native **MTP** head (`a4lg/Qwen3.8-27B-MTP-ONLY-GGUF`, Q8_0, 4.19 GB) and the
        pinned b10361 already lists `draft-mtp` under `--spec-type` — no build bump needed. Measured
        2026-08-15, all at ctx 65536: no speculation **17.55** tok/s · borrowed DFlash **23.68**
        (28.8 % acceptance) · own MTP **27.73** (61.7 %). The coder moved to `qwen3.8-27b-mtp`
        2026-08-15. The unaccelerated `qwen3.8-27b` entry *was* the A/B control for any speculation
        claim here (and the thermal fallback) — the DFlash-drafted entries were dropped, since a
        borrowed head had no capability case left once the matched one existed.
        ⚠️ **That control alias was itself retired 2026-08-22** (thermals no longer justify a
        non-speculative fallback). Its GGUF is still on disk, shared with the MTP entry, so an
        unaccelerated baseline is still measurable — via `spec-sweep.sh`, which starts its own
        server with no `--spec-*` flags, rather than via a standing llama-swap alias.
        ⚠️ **n-max 2 is the optimum and the sweep is NOT flat** — 2 → 27.77, 3 → 26.36, 4 → 26.87,
        6 → 20.49, **8 → 8.80**. Acceptance falls as n-max rises, so drafting *more* is strictly
        worse. Same cliff shape as DFlash's n≥8, i.e. the backend threshold, not an MTP property.
        Never copy an n-max between drafters.
        🔄 **Re-swept on b10587 (2026-08-22) with the new requant: `n-max 3` is now the best CLEAN
        setting** — 2 → 30.50 (73.7 %), **3 → 31.56 (64.2 %)**, 4 → 28.71 (52.0 %). Only 3.5 %
        separates 2 from 3, so either is defensible; both are ~12 % faster than the b10361 figures
        above. ⚠️ **n-max 6 and 8 are DEGENERATE, not fast** — 6 "reached" 41.97 and 8 22.39, but
        their unique-8-gram ratios are 0.065 and 0.030, i.e. the output collapsed into repetition
        (which drafts almost perfectly and inflates acceptance *and* tok/s). Discard both. ⚠️ The
        MTP *baseline* also degenerated (ratio 0.141) because greedy decoding at temp 0 repeats on
        its own, so treat the "vs base" ratios for MTP as soft; DFlash's baseline stayed clean.
      ⚠️ **`qwen3-instruct-2507` and `qwen3-coder-30b-a3b` were RETIRED 2026-08-14** and their
      GGUFs deleted, freeing 43.47 GB. Neither had a capability case left — the latter scores
      14 on the AA index against 32/35/38 for its peers, with no vendor benchmarks at its size.
    - **`muse-glimmer-30b`** — Meta Superintelligence Lab, dense 28B + 2B perception encoder,
      Apache-2.0. Deployed quant is Meta's own **`muse-glimmer-30B-kquant-dynamic.gguf`**
      (19.65 GB, ~5.64 bpw effective despite the "4-bit" label — it is mixed-precision), plus
      Meta's **`dflash-kquant.gguf`** drafter (1.63 GB). Chosen over Unsloth's ladder because it
      is the **only** Muse Glimmer quant with a published degradation figure (Meta: 0.2 % average
      over 15 benchmarks; their 17 GB build is 1.0 %). Unsloth publishes no accuracy numbers for
      any of its Muse quants, so a switch would trade a measured build for an unmeasured one.
      Three settings are **required**, each found the hard way:
      - `--reasoning-format auto`. With `none` (the wrapper default) the model's channel format
        (`to=<recipient>`, `<|message|>`) leaks raw into `content` and the reply is unusable.
      - `--spec-draft-n-max 3`. Measured optimum **for this drafter**: 2 → 37.4, **3 → 41.8**,
        4 → 41.0, 6 → 39.4 tok/s. `qwen3.6-27b-dflash`'s optimum is **4** — the value does not
        transfer between models, so sweep any new drafter.
        ⚠️ Those absolutes are **prompt-specific** (as is every speculative tok/s figure here); a
        re-sweep on a prose prompt gave 2 → 31.7, **3 → 35.8**, 4 → 34.1, 6 → 29.3. Compare the
        *shape*, not the numbers, across sweeps — the shape reproduced and **3 is still optimal**.
      - A generous client `max_tokens`. It reasons before answering: at 300 the reply comes back
        with `content` **completely empty** and everything in `reasoning_content`. At 2500 it used
        465 and finished cleanly. A low cap yields empty responses, not errors.
      - Without DFlash it runs **18.8 tok/s**; with it, **33–44 tok/s depending on the prompt** —
        a range, not a number (see the prompt-dependence rule below). Re-verified 2026-08-15 at
        n-max 3, fan pinned, from a cold card:
        | prompt class | tok/s | draft acceptance |
        |---|---:|---:|
        | free-form prose (a TCP explainer) | 32.9 | 44.8 % |
        | structured list (the OSI layers) | 39.6 | 59.2 % |
        | verbatim repetition | 43.0 | 67.1 % |
        | **code** (a small Python function) | **44.3** | **71.0 %** |
        The earlier headline **41.8** sits inside that range, so it is confirmed rather than
        contradicted — it just describes drafter-friendly content, not prose. Code is the workload
        this model would actually serve, and there it is the fastest of the four. Meta's 2.21×
        claim reproduces at the top of the range (44.3/18.8 = 2.36×) and not at the bottom
        (32.9/18.8 = 1.75×). n-max re-swept the same day: 2 → 31.7, **3 → 35.8**, 4 → 34.1,
        6 → 29.3 — same shape as the original sweep, so **3 is still the optimum**.
        For scale, the 3B-active MoE `qwen3.6-35b-a3b` does 63.1 tok/s unaccelerated
        — dense-vs-sparse dominates, and speculation narrows that gap without closing it.
      - ⚠️ DFlash and **vision are mutually exclusive** upstream (llama.cpp #26108, still open), so
        the `mmproj` projector is not deployed.
    - **DFlash speculative decoding on a dense 27B — the finding that made speculation viable here.**
      Measured 2026-08-10 on GPU 2 on the (since-removed) `qwen3.6-27b-dflash` entry:
      **17.6 → 43.8 tok/s, a 2.49× speedup**, output unchanged. That entry is gone — Qwen3.6 is a
      generation behind and `qwen3.8-27b-mtp` supersedes it — but every mechanism note below still
      applies to any speculative entry, `muse-glimmer-30b` included.
      `llamaswap-guarded-serve` gained two backward-compatible env hooks for this: `LLAMACPP_DIR`
      (pin ONE entry to a different llama.cpp build without moving the shared
      `/opt/llamacpp/current` symlink) and `EXTRA_ARGS` (extra `llama-server` flags).
      Flags: `--spec-type draft-dflash --spec-draft-model /models/hf/Qwen3.6-27B-DFlash-Q8_0.gguf
      --spec-draft-n-max 4 --spec-draft-ngl 99`.
      - ⚠️ **A SPECULATIVE MODEL HAS NO SINGLE tok/s — throughput is PROMPT-DEPENDENT.** Speculation
        only pays when the drafter guesses right, so decode speed tracks **draft acceptance**, and
        acceptance depends on how predictable the output text is. Measured on `muse-glimmer-30b`
        (2026-08-15, identical model/flags/load, only the prompt changed): free-form prose 32.9 tok/s
        at 44.8 % acceptance → code **44.3 tok/s at 71.0 %**. That is a **35 % spread from prompt
        choice alone**, wider than most of the differences these notes are used to argue about.
        Consequences, all learned by nearly mis-reporting a regression:
        - **Quote a range and name the prompt class**, never a bare number. A single figure invites
          a false alarm: re-running muse's documented 41.8 on a prose prompt returns 33 and looks
          like a 20 % regression, when nothing has changed.
        - **Never A/B two models or two settings on different prompts.** The prompt difference can
          exceed the effect being measured. The `qwen3.8-27b` / DFlash / MTP comparison above is
          valid *because* all three ran the same prompt at the same ctx on the same day — that is
          the bar for any speculation claim here.
        - **Judge a regression by acceptance, not tok/s.** `draft_n` / `draft_n_accepted` come back
          in every response's `timings` block. If acceptance is unchanged, the model is unchanged
          and only the workload moved.
        - Non-speculative entries are immune: `qwen3.8-27b` at 17.55 tok/s reproduced its documented
          17.6 exactly, on a different prompt. The whole effect is a speculation artifact.
      - ⚠️ **Pin the shroud fan to 100 % before benchmarking GPU 2**, or a sweep will trip the
        102 °C watchdog and leave llama-swap down (see `gpu-thermal-watchdog/`). `systemctl stop
        gpu-fan-control@shroud`, write `255` to the `nct6687` hwmon's `pwm3`, and restore the
        service in a `trap ... EXIT`. A missed restore leaves the fan loud, which is the safe
        direction. Peaks measured: **92 °C on the curve vs 65-74 °C pinned** for the same work.
      - ⚠️ **`--spec-draft-n-max` is tuned to 4 and must stay ≤ 6.** Sweep on this hardware:
        n=2 → 2.06×, n=3 → 2.40×, **n=4 → 2.49×**, n=6 → 2.54×, **n=8 → 0.97×**, n=16 → 1.07×.
        There is a **cliff** between 6 and 8, not a gradual falloff — and it is not an acceptance
        problem (accepted-tokens-per-target-pass keeps *rising* at n=8/16), so each forward pass is
        getting ~4.5× more expensive past n=6. Looks like a backend threshold, not a hardware limit.
        **Do NOT set this from the drafter GGUF's `dflash.block_size` (16)** — that is the worst
        value tested.
      - ⚠️ **TODO at the next llama.cpp bump on CT 123: re-run the n-max sweep.** The n≥8 cliff may
        well be a fixable Vulkan/backend bug; if it lifts, the optimum moves and 6+ becomes worth
        using. Sweep script idiom: rewrite the `--spec-draft-n-max` value in
        `/etc/llama-swap/config.yaml`, `systemctl restart llama-swap`, re-run the 3-prompt A/B and
        compare `predicted_per_second` plus `draft_n`/`draft_n_accepted`. (Pairs with the existing
        bump TODO to re-check `--cache-ram 0` on CT 120.) **Re-checked at the b10308 → b10361
        bump on 2026-08-11: the cliff did NOT lift** — n=6 45.1 tok/s → n=8 17.6, essentially
        unchanged. So it is not a transient upstream bug; keep n-max ≤ 6 and re-check again only
        if a release notes Vulkan batching work.
      - ✅ **DONE for b10587 (2026-08-22) — and it paid off, though not by lifting the cliff.**
        Re-swept with `pro-v620/gpu-ab-bench/spec-sweep.sh` on GPU 2. **The DFlash pair is the
        controlled comparison: its target and drafter GGUFs are byte-identical to the b10361 run,
        so only the build changed.**

        | n-max | b10361 | b10587 | Δ |
        | --- | ---: | ---: | ---: |
        | unaccelerated | 17.57 | 17.54 | **−0.2 % (flat)** |
        | 2 | 27.75 | 34.03 | **+22.6 %** |
        | 3 | 29.68 | **37.73** | **+27.1 %** |
        | 4 | 28.97 | 36.22 | **+25.0 %** |
        | 8 | 21.18 | 22.63 | still collapsed |

        **b10587 improved the speculative path by ~22–27 % while unaccelerated decode stayed flat**
        — same files, same card, same flags. So a build bump can be worth far more to a speculative
        entry than to a plain one; re-sweep speculation after every bump, not just when a release
        notes Vulkan work.
        - ⚠️ **The n≥8 cliff STILL did not lift** (n=4 2.06× → n=8 1.29×), so it survives three
          builds now (b10308, b10361, b10587). Treat it as a fixed backend property.
        - ⚠️ **n-max 6 is no longer merely slow, it is DEGENERATE** on both drafters — 56.17 tok/s
          for DFlash at a unique-8-gram ratio of 0.058. A tok/s-only sweep would have recorded that
          as a 3.20× win. **The optimum among clean results is 3 for BOTH drafters**, so the earlier
          "≤ 6 is safe" guidance should now read **≤ 4**.
        - The sweep's degeneracy gate is built into `spec-probe.py` (`uniq_8gram_min`,
          `any_degenerate`), so this cannot silently recur.
      - ⚠️ **The drafter GGUF must declare `general.architecture = dflash`, not `dflash-draft`.**
        Upstream registers `dflash`; several community repos ship the fork's name and fail to load
        with `unknown model architecture` (llama.cpp #25116). Known good: `williamliao/…`,
        `Anbeeld/…`. Known bad: `spiritbuun/…`, `Lucebox/…`, `Ardenzard/…`. Check before downloading
        gigabytes: `curl -fsSL -r 0-1023 <url> | tr -c '[:print:]' '\n' | grep -aoE 'dflash[a-z-]*' | head -1`.
      - **Speculation is a dense-model lever, not a universal one.** Same GPU, same build, same
        prompts: dense 27B 17.6 → 43.8 with DFlash, but the **3B-active MoE `qwen3.6-35b-a3b` runs
        63.1 tok/s with no speculation at all**. A 3B-active MoE's decode is already cheap, so
        draft/verify overhead dominates and there is nothing to win — an earlier separate-draft-model
        test on the MoE was completely inert. Reach for DFlash on dense targets only.
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
  agents are the consumers. Live since 2026-07-04 (PR #14); ~3.6k chunks / ~456 docs as of
  2026-08-07. `kb-rag/create-lxc-kb-rag.sh`; full design rationale in `kb-rag/SPEC.md`.
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
    the host copies removed (the hermes idiom). **No nft port-forward by default** — reachable only
    inside the `10.10.10.0/24` NAT LAN, by hostname.
  - ⚠️ Changing `EMBED_MODEL`/`EMBED_DIM` later requires `kb-reindex --full` — the stored
    `sqlite-vec` vector dimension must match.
  - ⚠️ **Nothing consumes it yet.** Verified 2026-08-07: CT 121's `/root/.hermes/config.yaml` has
    no `mcp:` block and no `kb-rag`/`8770` reference, so this is a live-but-*unwired* service.
    Registering `http://kb-rag:8770/mcp/` (header `Authorization: Bearer <key>`) on Hermes is the
    step that makes it useful.
  - ⚠️ Its `rootfs` `backup=0` is one of the **silent no-ops** described under Conventions —
    verified 2026-08-07, CT 140's line is a bare `local-lvm:vm-140-disk-0,size=12G` with no
    `backup=`, so this entirely rebuildable container **is** in the weekly vzdump, contrary to what
    `kb-rag/README.md` and `SPEC.md` claim. Low stakes in practice (1.8 GB used: 278 MB venv,
    154 MB index+checkout, 78 MB ONNX cache), but don't believe the "not backed up" comments. To
    actually skip the bulk: `vzdump 140 --exclude-path /opt/kb-rag`.
  - ⚠️ Its `kb-reindex`/`kb-stats` wrappers live in `/usr/local/bin`, so they hit the **`pct exec`
    PATH gotcha**: `pct exec 140 -- kb-stats` fails with `Failed to exec "kb-stats"` (verified
    2026-08-07). Wrap in `bash -lc '…'` — `kb-rag/README.md`'s bare examples do not work.
- **CT 200 `bench-runner`** (`bench-runner/`): an *unprivileged* Debian LXC that benchmarks
  that endpoint. It auto-discovers CT 120's IP at provisioning time. It lives in the
  `200+` test/temporary range because it is disposable — destroy it when done. The suite is
  engine-neutral (it speaks OpenAI `/v1`), so it benchmarks either engine unchanged.
- **VM 300 `docker-host`** (`docker-host/`): a Debian **VM** (the *only* VM here, deliberately)
  running **Docker + Compose + Portainer CE**, which hosts the homelab's small self-contained web
  apps as Compose stacks — currently **MealDeal**
  ([github.com/marchah/mealdeal](https://github.com/marchah/mealdeal), the grocery-deal tracker
  the local AI codes features for), live on `:4000`. Apps here **do not consume a VMID each** —
  they are containers inside this VM, so a new project costs a compose file
  (`docker-host/stacks/<project>/compose.yaml`) plus a Portainer git stack, not a bespoke
  provisioning script. Stack secrets (e.g. `IMAP_PASSWORD`) are **Portainer stack env vars**,
  never in this public repo. ⚠️ **Why a VM when everything else is an LXC:** Proxmox recommends
  Docker in a VM; Docker-in-LXC needs `nesting=1`+`keyctl=1` (often privileged), puts `overlay2`
  on a container filesystem, tends to break after Proxmox kernel bumps, and shares a kernel with
  this host's hand-rolled nftables NAT that Docker also writes rules into. The GPU/LLM containers
  stay native LXCs — they need device passthrough and gain nothing here. MealDeal now **pulls a
  prebuilt image** — `marchah/mealdeal#36` merged 2026-07-27 and its `Publish image` workflow
  publishes `ghcr.io/marchah/mealdeal` on every push to `main` (tags `main` + `sha-<short>`, plus
  semver from `v*`). The package came out **public**, so anonymous pull works and Portainer needs
  no registry credentials — don't trust the old warning that GHCR always defaults to private.
  Redeploys are a ~10 s pull; rollback is pinning a `sha-` tag. ⚠️ The stack sets
  **`pull_policy: always`** deliberately — without it a redeploy can reuse a stale local layer
  cache and silently keep serving the old build even though `main` moved. (Historical note: this stack built
  from git for a while, blamed on an "Actions billing-locked" state that **never existed** —
  verified 2026-07-26, plan `free` with every Actions line item at **$0.00 net**, because
  public-repo minutes are 100% free. The image had simply never been published.) ⚠️ Unlike
  the retired per-app LXC, **Portainer has no health-gated auto-rollback** — a broken deploy stays
  broken until acted on (the compose healthcheck makes it *visible*, not self-healing). See
  `docker-host/README.md`.
  - **Superseded:** `mealdeal/create-lxc-mealdeal.sh` (a native per-app LXC, CT 110) was built
    and verified first, then removed — one bespoke 870-line script per app doesn't scale to a
    fleet of small projects, which was the whole point of the pivot. Its genuinely reusable
    findings are retained below (the `pct exec` PATH gotcha, the `rootfs` `backup=` no-op).

VMIDs `120`/`121`/`122`/`123`/`140`/`200` and hostnames are defaults overridable via env vars (`VMID=`, `LXC_HOSTNAME=`, etc.).

## Common commands

All run on the Proxmox host as root.

```bash
# Provision the ops LLM-runtime container (CT 120) — GPU 1 of two Radeon Pro V620
./pro-v620/create-lxc-llamacpp-qwen3.6-35b-a3b.sh # llama.cpp (llama-server), Qwen3.6-35B-A3B MoE
# Autonomous coding loop's GPU-2 model server (CT 123 gpu2) — llama-swap on GPU 2
./pro-v620/create-lxc-llama-swap-gpu2.sh          # qwen3.8-27b-mtp coder + thinkingcap-27b reviewer, swapped by name (:8080)
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
# Operate the app stacks — prefer the Portainer UI (https://192.168.1.93:9443); by CLI:
ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100'   # into the VM (host holds the key)
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
  - **Current pins, all bumped 2026-08-22:** llama.cpp **`b10587`** (from `b10361`; llama.cpp now
    also self-reports a semver, `0.2.0-dev (build 10587, commit 3f545becc)`), llama-swap **`v250`**
    (from `v247`), and the coder GGUF moved to revision `4ca72078` after unsloth requantised it
    (20.2 → 20.9 GB; chat template byte-identical, so tensors only). Prior builds are left in
    `/opt/llamacpp/` and the previous llama-swap binary as `llama-swap.v247.bak`, so rollback is a
    symlink flip / file copy. Verified after the bump: both cards' RADV init (the loud-guard passes),
    CT 120 serving at 68.7 tok/s, all 7 llama-swap models registered, and MTP speculation still
    active on the coder (65.5 % acceptance, 27.7 tok/s).
    ⚠️ **The standing "re-run the n-max sweep at the next llama.cpp bump" TODO below is now DUE
    again** — the sweep recorded here was measured on b10361, i.e. pre-bump. Harness: `pro-v620/gpu-ab-bench/spec-sweep.sh`.
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
    a `llama-swap` server on GPU 2 for the loop (`qwen3.8-27b-mtp` coder + `thinkingcap-27b` reviewer,
    swapped one at a time))
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
  ⚠️ **The ledger is deliberately NOT in the git config backup** (excluded 2026-08-10, commit `48b8eee`
  in `marchah/hermes-agent-backup`): `daily.jsonl` gains a row and `state.json` is rewritten on *every*
  5-minute scrape, so they churned the diff on every single run, and that backup is meant to show what
  Hermes *changed*, not operational counters. Its only off-box copy is therefore the **weekly Sunday
  vzdump of CT 121** — a ledger loss between vzdumps is unrecoverable, on top of the floor caveat above.
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
  traps here, both hit for real on 2026-07-26 after a four-week silent outage:
  - ⚠️ **The Synology allow-lists NFS clients by IP.** The WiFi-NAT cutover moved the host
    `192.168.1.50` → `.93`, so every backup from 2026-07-05 on failed with
    `mount.nfs: access denied by server`. Fixed in DSM (Control Panel → Shared Folder → NFS
    Permissions). It is allow-listed by the **exact IP**, so *another host IP change breaks
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
  - `Synology-Backup` is now the **only** NFS storage. A second one (`Synology`, export
    `/volume1/Plex`) was **removed 2026-07-26**: it declared `content rootdir`, i.e. the Plex
    *media* share registered as a place to put container root disks — unused, and a trap (LXC
    rootfs over NFS is slow and hits the uid-mapping problem above, and it carried no `backup`
    content type). To give a future Plex container its media, **bind-mount the path instead of
    adding a storage**: `pct set <vmid> --mp0 /mnt/pve/<mount>,mp=/media`. That share also held
    **13 GB of vzdump archives from June 2023** (CT 100/101/103, all long gone) in a `dump/` dir
    left over from when it carried `backup` content — **deleted 2026-07-26**, reclaiming 13 GB.
    Both exports live on the same Synology volume, so that space benefits `Synology-Backup` too
    (601 GB → 614 GB free), which matters as keep-last=3 across seven guests accumulates.
  - The Docker host's precious state is its **volumes** (`portainer_data`,
    `mealdeal_mealdeal-data`) — see `docker-host/README.md` for pulling those out separately.
- **Notifications go to Slack, not just root's mailbox.** The four-week backup outage was silent
  because Proxmox's builtin `mail-to-root` target delivers to a local mailbox nobody reads. A
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
  Measured 2026-08-22 with `llama-bench` run inside each card's own container, 3 interleaved rounds
  in alternating order, every other variable verified rather than assumed: same GGUF (`25233af7…`,
  hash-matched across both containers *and* upstream HF), same build `b10361 (14e78ddef)`, same
  flags (`-ngl 99 -fa 1 -b 4096 -ub 1024`), both cards −100 mV (read live from
  `pp_od_clk_voltage`), both `power1_cap` 250 W. Variance under **0.1 %** across rounds.
  Model: `Qwen3.6-35B-A3B-UD-Q5_K_XL`.

  | test | GPU 1 — `2d:00.0` Gen4 x16 | GPU 2 — `06:00.0` Gen3 x4 | Δ |
  | --- | ---: | ---: | ---: |
  | pp512 | 969.4 | 976.8 | +0.8 % |
  | pp4096 | 1573.6 | **1614.0** | **+2.6 %** |
  | pp512 @d8192 | 863.0 | **890.3** | +3.2 % |
  | pp512 @d32768 | 349.1 | **362.9** | +3.9 % |
  | pp32768 | 621.8 | **642.9** | +3.4 % |
  | tg128 | **83.9** | 65.1 | **−22.4 %** |
  | tg128 @d8192 | **77.8** | 61.3 | −21.2 % |
  | tg128 @d32768 | **70.3** | 56.4 | −19.7 % |

  - **GPU 2 is the *stronger* card.** It wins every prefill test, sustains ~130 MHz higher clocks
    (2462 vs 2333) and draws more power under the same offset and cap — yet loses ~20 % of decode.
    A physical slot swap is therefore unnecessary to rank the two cards; prefill already answers it.
  - **The penalty is a FIXED ~3.45 ms/token, not a percentage.** 11.92 → 15.36 ms/tok at depth 0,
    12.86 → 16.31 at 8k, 14.24 → 17.73 at 32k — constant while per-token compute grows ~20 %. That
    is the signature of an interconnect round-trip, not weaker silicon. Prefill batches 4096 tokens
    per submission and amortises it away; decode issues one token at a time and pays it every token.
  - **So the tax hurts FAST models most**, which is what decides placement: ~4 ms on this MoE's
    12 ms token is −22 %, but on a dense 27B's 53 ms token only −7 %. **Never move
    `qwen3.6-35b-a3b` to GPU 2** — it would surrender ~22 % of decode. The dense loop models on
    CT 123 are correctly placed and barely notice.
  - **The fixed-tax model was then confirmed on a second architecture.** `Qwen3.8-27B` (dense) run
    through the same 3-interleaved-round harness, both cards driven from one container via
    `--device`:

    | test | GPU 1 | GPU 2 | Δ |
    | --- | ---: | ---: | ---: |
    | pp512 | 322.3 | **330.8** | +2.6 % |
    | pp4096 | 358.2 | **370.1** | +3.3 % |
    | pp512 @d8192 | 261.3 | **271.7** | +4.0 % |
    | pp512 @d32768 | 125.5 | **130.5** | +4.0 % |
    | tg128 | **19.15** | 17.76 | **−7.2 %** |
    | tg128 @d8192 | **18.40** | 17.14 | −6.8 % |
    | tg128 @d32768 | **17.09** | 16.00 | −6.3 % |

    Same prefill-favours-GPU-2 / decode-favours-GPU-1 split, and the per-token penalty is again
    **constant**: 52.22 → 56.31 ms at depth 0 (4.09 ms), 54.35 → 58.34 at 8k (3.99 ms), 58.51 →
    62.50 at 32k (3.99 ms). ~4 ms on both architectures, but −7 % here versus −22 % on the MoE
    purely because a dense token is 4× slower to produce. Independently corroborated by the
    speculation sweep's unaccelerated baselines (19.00 → 17.65 tok/s, −7.1 %; `Qwen3.6-27B`
    18.82 → 17.57, −6.6 %).
  - ⚠️ **`current_link_speed` / `current_link_width` LIE** — both report `16.0 GT/s PCIe x16` for
    *both* cards. Ground truth is the starred line of `pp_dpm_pcie`: `16.0GT/s, x16` on GPU 1 vs
    `8.0GT/s, x4` on GPU 2. Closing the gap needs slot bifurcation in BIOS, still blocked by the
    host having no video output — so that headless-BIOS problem now gates ~22 % of MoE decode on
    GPU 2, not merely C-states.
  - Harness: **`pro-v620/gpu-ab-bench/`** (host-side, NOT a service — no `install.sh`/unit). Read
    its README before re-running: it carries the interleaving method, the "verify every control"
    checklist, the ⚠️ **revert `ct123-dual-gpu.sh` before production returns** rule, the fact that
    `gpu-thermal-watchdog` cannot protect a hand-driven `llama-bench`, and the output-sanity gate
    that stops a speculative sweep reporting a degenerate-repetition artifact as a speedup.
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
  tach watchdog. Retired env files (`@shroud`→pwm3 NF-F12, `@blower`→pwm2, `@arctic`→pwm4) and
  staged per-card ones (`@gpu1`/`@gpu2`) are kept in-repo for reference.
  Each instance pins its GPU(s) by PCI address and is driven off the card temp(s);
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
  ⚠️ **It has not tripped since the per-card blowers went in** (2026-08-22). Its three firings on
  2026-08-14/15 were all under the earlier shared-shroud cooling, which ran a full load with its
  fan maxed. With a blower per card, both saturated simultaneously settle at 62/73 °C — so treat a
  trip now as a real fault (a seized blower, a detached hub lead), not as normal saturation.
  Independently re-validated 2026-08-22 across a benchmark session on the **production fan curve
  untouched**, with **zero trips** and clocks flat throughout (no throttling) in every case.
  ⚠️ **A DENSE model, not big-context MoE prefill, is the thermal worst case** — because a dense
  27B pins the firmware-locked 250 W cap while the 3B-active MoE is memory-bound and never reaches
  it:

  | workload | peak junction G1 / G2 | power under load | fan |
  | --- | --- | ---: | ---: |
  | `qwen3.6-35b-a3b` MoE, 3× 32768-tok prefill | 73 / 74 °C | ~220 W | ≤ 50 % |
  | **`Qwen3.8-27B` dense, prefill + decode** | **84 / 88 °C** | **250 W (at the cap)** | 61 % |

  So margin to the 102 °C trip is ~28 °C on the MoE but only **~14 °C on a dense model** — still
  safe, and with fan headroom left, but do not quote the MoE figure as the worst case. This also
  explains the pre-blower trip history: every firing was a *dense* model (the qwen3.6-27b coding
  harness, dense-28B muse-glimmer), never the MoE.
  ⚠️ **It CANNOT protect a hand-driven load.** It stops the CT's model *service*
  (`systemctl stop llamacpp` / `llama-swap`), which is a no-op against a `llama-bench` or
  `llama-server` you launched yourself — the 105 °C hardware MODE1 reset then becomes the only
  backstop. Run an independent guard alongside any manual benchmark: poll `temp2_input` on both
  cards every 2 s and `pkill -f llama-bench` at ~100 °C.
- **Non-GPU host networking lives under `host-net/`** (also host-side, NOT in an LXC).
  `host-net/wifi-nat/` lets the host run with **no ethernet**: onboard WiFi (`wlo1`) becomes the
  routed WAN and `vmbr0` becomes an internal NAT'd LAN (`10.10.10.0/24`) the LXCs sit behind
  (dnsmasq DHCP/DNS + nftables masquerade/port-forwards, reservations `.120`→CT120 / `.121`→CT121).
  Same idempotent-`install.sh` + `.env` idiom, but **staged/transactional** because it re-points
  the host's own uplink: `stage → --test-wifi → --cutover → --confirm`, with an armed auto-rollback
  (a full, verified teardown) as the safety net and `--revert` to undo. Containers keep `ip=dhcp`
  (no per-CT change) — they just get `10.10.10.x` and are reached from the LAN via the host's WiFi
  IP + the DNAT port-forwards. Consumers that hard-code a container's IP (e.g. Hermes's
  `model.base_url`, the bench-runner's `MODEL_API_URL`) must use the dnsmasq name / be re-pointed
  after the cutover changes CT 120's address.
