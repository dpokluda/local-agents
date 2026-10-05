# local-agents

A reproducible setup for running **local LLM agents on Apple Silicon Macs**, driven from
PowerShell.

It answers three questions:

1. **Should you run an agent locally at all?** (Often no. See below.)
2. **If yes, which model fits your machine?** ([docs/models.md](docs/models.md))
3. **How do you know it actually works before you rely on it?**
   ([`scripts/Test-LocalStack.ps1`](scripts/Test-LocalStack.ps1))

Everything is PowerShell 7 (`pwsh`) on macOS. Model list verified **2026-10-04**.

---

## Quick start

```powershell
./scripts/Install-LocalAgents.ps1           # brew install ollama + start it on demand
./scripts/Sync-Models.ps1 -Tier recommended # pull ~40 GB of models
./scripts/Test-LocalStack.ps1               # health, tokens/sec, tool-calling
```

Everything is a **standalone script** — there is no profile to load and nothing to add to
your `$PROFILE`.

The service starts **on demand**, not at login — `./scripts/Start-Ollama.ps1` and
`./scripts/Stop-Ollama.ps1` control it, and `./scripts/Install-LocalAgents.ps1 -AtLogin`
opts into always-on if you prefer. `Start-Ollama.ps1` also applies the tuning knobs
(flash attention, q8_0 KV cache, keep-alive until you stop it, one model resident at a
time) to the service, which is the only way they
actually take effect — see [docs/setup.md](docs/setup.md#3-environment-knobs).

### Then point an agent at it

**GitHub Copilot app** (easiest — Ollama is a built-in provider, public preview):

> App settings → **Model providers** → **Add provider** → **Ollama** → base URL
> `http://localhost:11434/v1` → **Add provider**

Your local models then show up in the model picker next to the GitHub-hosted ones. You need
a GitHub account, but **not** a Copilot plan when using your own provider.

**GitHub Copilot CLI** (the documented path for working offline):

```powershell
$env:COPILOT_PROVIDER_BASE_URL = 'http://localhost:11434/v1'
$env:COPILOT_MODEL             = 'qwen3-coder:30b'
copilot
```

Anything else that takes a custom base URL — Aider, OpenCode, Continue, any OpenAI SDK —
uses the same `http://localhost:11434/v1`. See [docs/harnesses.md](docs/harnesses.md), or
[docs/chat-apps.md](docs/chat-apps.md) for plain chat rather than coding.

Every script supports `-WhatIf`. Start there if you want to see what will happen first.

---

## When local actually beats cloud

Local inference is not cheaper or better by default. It wins in specific situations, and
it is worth being precise about which.

**Strong fits:**

- **Code that cannot leave the machine.** Proprietary, regulated, client-confidential,
  export-controlled. This is the one case where local wins regardless of quality, because
  the alternative is not "a worse model" — it is "no model."
- **Bulk, low-stakes batch work.** Generating tests across 400 files, writing docstrings,
  mechanical migration sweeps, bulk commit-message drafting. Here token cost dominates
  quality, and the marginal cost of a local token is electricity.
- **Always-on background agents.** A watcher that triages every commit or lints every diff
  runs constantly and is unaffordable per-token but free locally.
- **Offline work.** Flights, trains, airgapped environments. Copilot CLI's `COPILOT_OFFLINE`
  mode plus a local provider gives you a real agent with no network at all. See
  [docs/offline.md](docs/offline.md).
- **Building and debugging your own agent framework.** Iterating on a tool loop means
  thousands of throwaway calls. Doing that against a metered API is slow and expensive.
- **PII-heavy data wrangling.** Cleaning, classifying, or reshaping data that should not be
  sent anywhere.

**Poor fits — be honest about these:**

- **Hard reasoning.** Subtle debugging, tricky algorithms, anything that needs to hold a
  lot of interacting constraints at once. Frontier cloud models win decisively.
- **Large multi-file refactors.** Needs long-range coherence that a 19 GB model does not
  sustain.
- **Novel architecture and design work.** Taste and breadth are exactly what frontier scale
  buys, and exactly what quantized local weights give up.
- **Anything needing current information.** Local models cannot browse. Their knowledge is
  frozen at training time.

**The pragmatic pattern:**

> **Local for high-volume / low-stakes. Cloud for low-volume / high-stakes.**

These are complementary, not competing. A good setup routes the mechanical 80% locally and
escalates the hard 20% to a frontier model. The failure mode is treating local as a drop-in
replacement, deciding it is disappointing, and giving up — instead of giving it the work it
is genuinely good at.

---

## Will it run on your Mac?

Apple Silicon shares one memory pool between CPU and GPU, so model weights compete directly
with macOS, your apps, and the KV cache — which grows with context length, and agent loops
have long context.

| Unified memory | Budget for weights | Realistically |
|---:|---:|---|
| 16 GB | 8 GB | `gemma4:e4b` only. Fine for Q&A, painful for agent loops. |
| 24 GB | 16 GB | One mid-size model at a time, nothing else open. |
| 36 GB | 26 GB | Comfortable single-model agent work. |
| 48 GB | 34 GB | Everything in this repo's model set, with headroom. |
| 64 GB | 45 GB | Same, plus long-context room. |
| 128 GB | 91 GB | Opens up the 65–75 GB tier. |

```powershell
./scripts/Get-LocalAgentBudget.ps1   # check your own machine
```

A model slightly over budget does not fail cleanly — macOS swaps, and throughput collapses
to single digits. Full math and derivation in [docs/models.md](docs/models.md).

---

## Model picks (48 GB machine, verified 2026-10-04)

| Model | Size | Use it for |
|---|---:|---|
| `qwen3-coder:30b` | 19 GB | **Default daily driver.** MoE with ~3B active params — far faster than 30B suggests. |
| `gpt-oss:20b` | 14 GB | Most reliable tool-calling in the set. The control model when debugging a harness. |
| `gemma4:e4b` | 7.5 GB | **The airplane model.** Tiny, loads instantly, genuinely usable. |
| `devstral-small-2:24b` | 15 GB | Purpose-built for agentic loops. |
| `qwen3.8:27b` | 18 GB | Strongest general reasoning here. MLX build available. |
| `qwen3.6:27b-coding` | 17 GB | Coding-tuned alternative. MLX build available. |
| `gemma4:26b` | 16 GB | Multimodal — accepts images. |

**Does not fit on 48 GB:** `qwen3-coder-next` (52 GB), `gpt-oss:120b` (65 GB),
`devstral-2` (75 GB), `qwen3-coder:480b` (290 GB).
**`glm-5.3-flash` is cloud-only — no local weights exist at any size.**

Two things worth knowing that are not obvious:

- **`q4_K_M` is the right quantization.** `q8_0` doubles RAM for marginal gain; `bf16`
  triples it. A bigger model at q4 beats a smaller model at q8 at equal memory.
- **Ollama ships Apple-native MLX builds** (`qwen3.8:27b-mlx`, `qwen3.6:27b-mlx`) that are
  meaningfully faster on M-series than the default llama.cpp path. Pull them with
  `./scripts/Sync-Models.ps1 -Tier full -UseMlx`.

Model tags churn quickly. Re-verify sizes before trusting this table.

---

## Verify before you trust it

```powershell
./scripts/Test-LocalStack.ps1
```

The most important script here. Per model it reports throughput (from Ollama's eval
counters, not wall clock), cold-load time, and whether **tool-calling actually works** — on
both the native API and the OpenAI-compatible `/v1` endpoint that harnesses use.

That last check earns its place because its failure mode is silent. A model that ignores
tool definitions does not throw an error; it writes a pleasant paragraph *about* calling the
tool, the harness receives no `tool_calls`, and your agent loop quietly stalls. Catch it in
a health check, not twenty minutes into a task.

The script exits non-zero if any model fails, so it drops straight into a pre-flight script.

---

## Layout

```
local-agents/
├── README.md                      # this file - the decision guide
├── models.json                    # single source of truth for the model set
├── docs/
│   ├── setup.md                   # install, env knobs, idle cost, troubleshooting
│   ├── models.md                  # sizes, RAM math, quantization, MLX
│   ├── offline.md                 # pre-flight checklist before losing connectivity
│   ├── harnesses.md               # Copilot app + CLI (BYOK), Aider, OpenCode, Continue, SDKs
│   └── chat-apps.md               # LM Studio, Ollama desktop app, general chat use
└── scripts/
    ├── Install-LocalAgents.ps1    # idempotent install + service start
    ├── Sync-Models.ps1            # reconcile local models against a models.json tier
    ├── Test-LocalStack.ps1        # health, tokens/sec, tool-calling verification
    ├── Uninstall-LocalAgents.ps1  # clean revert incl. ~/.ollama
    │
    ├── Start-Ollama.ps1           # start on demand + apply env knobs (-AtLogin to register)
    ├── Stop-Ollama.ps1            # stop and unregister
    ├── Restart-Ollama.ps1         # restart, re-applying knobs - how you change a setting
    ├── Get-OllamaStatus.ps1       # server version + models resident in RAM
    ├── Get-LocalModel.ps1         # installed models with on-disk sizes
    ├── Get-LocalAgentBudget.ps1   # this machine's weight budget
    ├── Dismount-LocalModel.ps1    # free resident model memory, server stays up
    ├── Remove-LocalModel.ps1      # delete weights from disk, reports space reclaimed
    ├── Invoke-LocalChat.ps1       # one-shot prompt from the terminal
    ├── Start-LocalCopilot.ps1     # Copilot CLI against local Ollama (BYOK)
    └── _common.ps1                # internal: shared defaults + helpers, not run directly
```

All scripts are idempotent and support `-WhatIf` where they change anything; destructive
ones prompt by default. Run them from anywhere — they resolve their own dependencies via
`$PSScriptRoot`. Shared defaults (keep-alive, max loaded models, KV cache type, flash
attention) live in one
place: `scripts/_common.ps1`.

---

## Requirements

- macOS on Apple Silicon (M-series). Intel Macs have no useful GPU path here.
- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`brew install powershell`).
- Homebrew at `/opt/homebrew`.
- Disk: 7.5 GB (minimal tier) to ~107 GB (full tier).

---

## Uninstall

```powershell
./scripts/Uninstall-LocalAgents.ps1 -WhatIf   # see what would go
./scripts/Uninstall-LocalAgents.ps1           # stop service, uninstall, remove ~/.ollama
```

---

## License

[MIT](LICENSE)
