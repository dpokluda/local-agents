# Models

**Model list verified 2026-10-04** against the public Ollama library.
Tags churn fast — a model that exists today may be renamed, re-quantized, or superseded
within weeks. Re-check before trusting any size below. The authoritative machine-readable
copy of this list is [`../models.json`](../models.json); this page is the prose version.

Sizes below are historical decimal-GB planning estimates, not pinned artifacts. A tag can
resolve to different formats or sizes as the library/runtime changes; inspect installed
bytes with `Get-LocalModel.ps1`. Memory-budget fields use GiB (PowerShell's `1GB`), and the
budget script converts model estimates before comparing them.

---

## The RAM budget, honestly

Apple Silicon uses unified memory: the GPU and CPU share one pool. A model's weights must
fit in that pool alongside macOS, your apps, and the KV cache.

The KV cache is the part people forget. It grows linearly with context length, and agent
loops have *long* context — a coding agent 30 tool-calls deep can be sitting on 60k+ tokens.
At that length the KV cache is not a rounding error; it is gigabytes.

So the rule used throughout this repo:

> **Weight budget ≈ total unified memory − max(8GB, 29% of total)**

| Unified memory | Reserved (OS + apps + KV) | Budget for weights | What that actually buys you |
|---:|---:|---:|---|
| 16 GB | 8 GB | **8 GB** | `gemma4:e4b` only. Workable for autocomplete and short Q&A, painful for agent loops. |
| 24 GB | 8 GB | **16 GB** | `gpt-oss:20b` (14 GB), `devstral-small-2:24b` (15 GB), `gemma4:26b` (16 GB) — one at a time, nothing else open. |
| 36 GB | 10 GB | **26 GB** | Everything in `models.json`. Comfortable single-model agent work. |
| 48 GB | 14 GB | **34 GB** | Everything in `models.json`, with room to keep a small model resident alongside a large one — though the scripts cap you at one by default, see below. **This machine.** |
| 64 GB | 19 GB | **45 GB** | Same set, plus long-context headroom. The 52 GB+ tier is still out of reach. |
| 128 GB | 37 GB | **91 GB** | Opens up `gpt-oss:120b` (65 GB) and `devstral-2` (75 GB). |

Check your own machine:

```powershell
./scripts/Get-LocalAgentBudget.ps1
```

Two things this table does *not* mean:

- **It is not a disk budget.** The `full` tier is ~107 GB on disk but you never hold all
  seven resident. Disk is cheap; RAM is the constraint.
- **It is not a "will it load" test.** An oversized allocation may fail outright, trigger
  CPU offload, or create memory pressure and severe slowdown. GPU-wired allocations are
  not ordinary pageable RAM. Inspect the actual loaded model and memory pressure.

**One model at a time, by default.** The budget column is what you can hold *in total*, and
two models will happily sit inside it: `qwen3-coder:30b` (19 GB) plus `gpt-oss:20b` (14 GB)
is 33 GB, under the 34 GB budget — so Ollama has no reason to evict either, and the rest of
macOS gets about 15 GB. Because the scripts set an infinite keep-alive, nothing would clear
them on a timer, so they also set `OLLAMA_MAX_LOADED_MODELS=1`: loading a different model
swaps out the current one. Raise it with `./scripts/Start-Ollama.ps1 -MaxLoadedModels 2` if
you want both resident and the table above says you can afford it. See
[setup.md](setup.md#3-environment-knobs).

---

## Recommended picks for a 48 GB machine

### Coding

| Tag | Size | Why |
|---|---:|---|
| `qwen3-coder:30b` | 19 GB | **The default daily driver.** Mixture-of-experts with only ~3B active parameters per token, so it generates far faster than the 30B label suggests while keeping the breadth of a large model. If you pull one coding model, pull this. |
| `qwen3.6:27b-coding` | 17 GB | Coding-tuned variant of the 3.6 generation. Slightly smaller; worth benchmarking head-to-head against the above on your own code. Has an MLX build. |
| `devstral-small-2:24b` | 15 GB | Purpose-built for *agentic* loops — plan, call tool, read result, repeat — rather than single-shot completion. Reach for this when a harness keeps losing the thread. |

### General purpose and reasoning

| Tag | Size | Why |
|---|---:|---|
| `gpt-oss:20b` | 14 GB | OpenAI's open-weight model. Notably solid, predictable tool-calling. When an agent harness misbehaves, switch to this first to isolate whether the problem is the model or the harness. |
| `qwen3.8:27b` | 18 GB | Newest Qwen generation; the strongest general reasoning in this set. Has an MLX build. |
| `gemma4:26b` | 16 GB | Google's multimodal model — accepts images as well as text. Useful for screenshot-driven work. |
| `gemma4:e4b` | 7.5 GB | Tiny but genuinely usable, not a toy. **The airplane model**: loads in seconds, leaves headroom for everything else, and still follows instructions well enough to be worth having. Always keep this one pulled. |

---

## What does *not* fit on 48 GB

Listed explicitly because these come up constantly and the answer is a flat no:

| Tag | Size | Verdict |
|---|---:|---|
| `qwen3-coder-next` | 52 GB | Over budget. Needs 80 GB+ of real headroom. |
| `gpt-oss:120b` | 65 GB | Over budget. 96 GB machine minimum. |
| `devstral-2` | 75 GB | Over budget. 128 GB machine realistically. |
| `qwen3-coder:480b` | 290 GB | Beyond any Apple Silicon configuration currently sold. |
| `glm-5.3-flash` | — | **Cloud-only. No local weights exist.** It cannot be run with Ollama at any memory size. If you see it recommended for local use, the recommendation is wrong. |

---

## Quantization

Quantization shrinks weights by storing them at lower precision. Q4_K_M is a useful
starting point for GGUF models, not an Ollama-wide default. `gpt-oss:20b` uses MXFP4;
the MLX alternatives listed here are safetensors/NVFP4. Check the exact artifact rather
than assuming that every tag uses the same format.

| Scheme | Relative size | Verdict |
|---|---|---|
| `q4_K_M` | 1.0× (baseline) | Useful GGUF size/quality starting point. |
| `q8_0` | roughly 2× | More weight memory, potentially better precision; measure on your task. |
| `bf16` | roughly 3–4× | Much larger weights; exact ratios depend on tensor mix and metadata. |

At a fixed memory budget, compare both model size and quantization. A larger Q4 model
can beat a smaller Q8 one, but this is not a universal quality guarantee.

Note that this is separate from `OLLAMA_KV_CACHE_TYPE=q8_0` (see [setup.md](setup.md)) —
that quantizes the *KV cache*, not the weights, and there `q8_0` is exactly right.

---

## MLX builds — Apple-Silicon-specific, and underpublicized

This is the single most Apple-Silicon-specific thing in this repo, and it is not widely
known: **Ollama now ships MLX variants of some models.**

MLX is Apple's own array framework, built for the M-series unified-memory architecture.
The default Ollama execution path is llama.cpp with a Metal backend; MLX is a native
alternative whose performance depends on the model, quantization, and runtime.

Currently available in this repo's model set:

- `qwen3.8:27b-mlx`
- `qwen3.6:27b-mlx`

Pull them with:

```powershell
./scripts/Sync-Models.ps1 -Tier full -UseMlx
```

`-UseMlx` substitutes the MLX tag wherever `models.json` declares one and falls back to the
standard tag otherwise. MLX download estimates are tracked separately; substitution is
not a guarantee of identical weights or tuning. The inspected Qwen 3.6 and 3.8 MLX
artifacts declared minimum Ollama versions 0.22.0 and 0.32.12 respectively; verify current
requirements before pulling them. Existing models are not changed merely by updating
these scripts.

Do measure rather than assume. `Test-LocalStack.ps1` reports tokens/sec per model, so pull
both variants and compare on your own hardware:

```powershell
./scripts/Sync-Models.ps1 -Tag 'qwen3.8:27b','qwen3.8:27b-mlx'
./scripts/Test-LocalStack.ps1 -Model 'qwen3.8:27b*' -UnloadAfterEach
```

LM Studio (`brew install --cask lm-studio`) has an MLX backend too. Sharing a backend family
does not guarantee identical throughput: compare matching weights, settings, and context.
See [chat-apps.md](chat-apps.md).

---

## Tiers in `models.json`

`Sync-Models.ps1 -Tier <name>` pulls one of these sets.

| Tier | Models | Disk |
|---|---|---:|
| `minimal` | `gemma4:e4b` | 7.5 GB |
| `recommended` | `gemma4:e4b`, `qwen3-coder:30b`, `gpt-oss:20b` | 40.5 GB |
| `full` | all seven | 106.5 GB |

`recommended` is deliberately a *spread*, not three variations on a theme: one tiny
always-works model, one fast coding model, one strong tool-caller. That covers the three
things you actually need from a local stack.

---

## Disk usage and removing models

Weights live in `~/.ollama/models`, in two parts:

| Path | What it holds |
|---|---|
| `manifests/` | Small JSON files, one per tag. These are the "names". |
| `blobs/` | The actual weights, content-addressed by SHA-256 digest. |

Set **`OLLAMA_MODELS`** to store them elsewhere — an external SSD, say. It has to be set on
the *server*, not in your shell; see [the launchd gotcha](setup.md#the-gotcha-that-will-waste-your-afternoon).
The repo's scripts read it back from the server process, so they follow the override
automatically.

### Why deleting a 17 GB tag may not free 17 GB

Blobs are shared by digest. Two tags built on the same base layers — a model and its MLX
variant, or two quantizations of one base — store the common layers **once**. Deleting one
tag removes its manifest and only the blobs nothing else references.

So the size in `models.json` and in `Get-LocalModel.ps1` is an **upper bound on what you
get back**, not a promise. This is why `Remove-LocalModel.ps1` measures the directory
before and after rather than reporting the tag's listed size:

```powershell
# See what would go, and what it is currently using
./scripts/Remove-LocalModel.ps1 qwen3-coder:30b -WhatIf

# Remove it (prompts, because this is destructive)
./scripts/Remove-LocalModel.ps1 qwen3-coder:30b

# Several at once, no prompting; wildcards match the installed list
./scripts/Remove-LocalModel.ps1 'gemma4:*' -Force
```

It unloads the model from memory first if it is resident, deletes through the API so it
works without the `ollama` CLI on PATH, and prints the measured space reclaimed per model
plus a total.

If you remove something declared in `models.json`, the script says so — a later
`Sync-Models.ps1` run for a tier containing that tag will simply download it again.

### Bulk removal

```powershell
# Remove everything outside a tier, in one pass
./scripts/Sync-Models.ps1 -Tier minimal -Prune -WhatIf

# Remove the software but keep the weights for a later reinstall
./scripts/Uninstall-LocalAgents.ps1 -KeepModels

# Remove everything, weights included
./scripts/Uninstall-LocalAgents.ps1
```

### If you also use LM Studio

LM Studio keeps its **own** copy of every model under `~/.lmstudio/models`. It does not
share Ollama's blob store, so a model you run in both places is downloaded and stored
**twice**. On a machine where the recommended tier is already 40 GB, that is worth knowing
before you duplicate the set. Check both when you are hunting for disk:

```powershell
du -sh ~/.ollama/models ~/.lmstudio/models
```

---

## Picking a model in practice

1. Start with `qwen3-coder:30b` for anything code-shaped.
2. If tool-calling misbehaves, switch to `gpt-oss:20b` to find out whether the model or the
   harness is at fault.
3. If the agent loop itself keeps derailing, try `devstral-small-2:24b` — it is tuned for
   exactly that shape of work.
4. On battery, or when you need headroom for other apps, drop to `gemma4:e4b`.
5. Whatever you pick, run `Test-LocalStack.ps1` against it before wiring it into a harness.
   A model that cannot emit a tool call is not an agent model, no matter how well it writes.
