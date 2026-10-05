# Going offline

The point of this repo: a laptop that still has a working coding agent at 35,000 feet, or
inside an airgapped network. That mostly works — but it only works if you prepared, and the
failure modes are all "the thing you forgot to download."

Run through this **before** you lose connectivity. It takes about five minutes if the models
are already pulled, and the whole checklist is scriptable.

---

## Pre-flight checklist

### 1. Models are pulled *and* verified

Pulling is not enough. A tag can download fine and still fail to emit tool calls, and you
will not discover that offline.

```powershell
./scripts/Sync-Models.ps1 -Tier recommended
./scripts/Test-LocalStack.ps1 -JsonPath ./out/preflight.json
```

`Test-LocalStack.ps1` exits non-zero if any requested check fails, so this is a
single gate:

```powershell
./scripts/Test-LocalStack.ps1
if ($LASTEXITCODE -eq 0) { 'Ready to fly' } else { 'Fix this before you board' }
```

### 2. You have a small fallback model

Keep `gemma4:e4b` (7.5 GB) pulled even if you plan to use a bigger model. On battery, with
a browser and an IDE open, a 19 GB model plus KV cache can push you into swap. Having a
model that loads in seconds and leaves 25 GB free is the difference between degraded and
dead.

```powershell
./scripts/Sync-Models.ps1 -Tier minimal
```

### 3. The service will be running when you need it

This repo deliberately starts Ollama **on demand** (`brew services run`), which does *not*
register a launchd login item — so it does **not** come back automatically after a reboot.
That is the right default day to day, and the wrong one at 35,000 feet if you reboot and
forget.

Two ways to handle it. Either register it for the trip:

```powershell
./scripts/Start-Ollama.ps1 -AtLogin          # brew services start - survives reboot
brew services list | Select-String ollama    # expect: started
```

Or just remember the one command you need after a restart:

```powershell
./scripts/Start-Ollama.ps1
./scripts/Get-OllamaStatus.ps1     # confirm it answered
```

`./scripts/Stop-Ollama.ps1` unregisters the login item again when you land.

### 4. Weights are warm, or you accept the cold-start

First request after a cold boot pays the full load. For a 19 GB model that is meaningful
time. Warm it deliberately:

```powershell
./scripts/Invoke-LocalChat.ps1 'ready?' -Model qwen3-coder:30b
./scripts/Get-OllamaStatus.ps1     # confirm it is resident
```

Nothing to tune here: the default keep-alive is `-1`, so once a model is loaded it **stays
loaded** until you stop the server. That is exactly what you want on a flight — no cold
reload on battery because you spent twenty minutes reading.

If memory gets tight mid-flight, `./scripts/Dismount-LocalModel.ps1` frees it immediately
without stopping the server.

### 5. Your harness is configured and tested *against local*

Do not discover your agent tool's config schema offline. Wire it up and run one real task
while you still have a network to debug against. See [harnesses.md](harnesses.md).

If you are using **Copilot CLI**, this is the configuration — it supports BYOK providers,
including a local Ollama instance, and has a dedicated offline mode:

```powershell
$env:COPILOT_PROVIDER_BASE_URL = 'http://localhost:11434/v1'
$env:COPILOT_MODEL             = 'qwen3-coder:30b'
$env:COPILOT_OFFLINE           = 'true'
copilot
```

Or via the script, which scopes the variables to the child process:

```powershell
./scripts/Start-LocalCopilot.ps1 -Model qwen3-coder:30b -Offline
```

`COPILOT_OFFLINE=true` stops the CLI from contacting GitHub's servers. It only delivers
genuine network isolation because the provider is local — if `COPILOT_PROVIDER_BASE_URL`
pointed at a remote endpoint, prompts and code context would still leave the machine.

> **Why the CLI and not the Copilot app.** The app also supports local providers (Ollama is
> in its provider list — see [harnesses.md](harnesses.md#github-copilot-app)), and it is the
> nicer interface day to day. But it **requires signing in with a GitHub account**, and its
> offline behaviour is **not documented** — this repo has not verified it. Treat the app as
> unproven offline. **Copilot CLI with `COPILOT_OFFLINE=true` is the documented path**, so
> that is what this checklist configures. If you intend to rely on the app offline, test it
> on the ground with Wi-Fi off before you count on it.

Two prerequisites that are easy to miss, and both fail *after* you are offline:

- **The model must support tool calling and streaming**, or the CLI errors out rather than
  degrading. `./scripts/Test-LocalStack.ps1 -Model '<tag>'` is the pre-flight check for
  exactly this — confirm `Tools/v1` reads `pass`.
- **Raise the context window.** Ollama's integration page recommends ≥64k tokens and
  GitHub's recommends ≥128k; on 48 GB, **64k is the practical floor** because KV cache
  costs real RAM. Ollama defaults vary by runtime and available memory. Set it and restart
  the service *before* you leave:

  ```powershell
  ./scripts/Restart-Ollama.ps1 -ContextLength 65536     # or 131072 if your budget allows
  ```

  Then run `Test-LocalStack.ps1 -Model 'qwen3-coder:30b' -MinimumContextLength 65536`
  and sanity-check RAM with
  `./scripts/Get-LocalAgentBudget.ps1` — a
  large KV cache is additional memory on top of the weights. Because a local tag is not in Copilot
  CLI's model catalog, also pin the prompt budget so it does not fall back to a
  conservative default:

  ```powershell
  ./scripts/Start-LocalCopilot.ps1 -Offline -MaxPromptTokens 60000 -MaxOutputTokens 4096
  ```

### 6. Everything else your workflow needs is local

This is the step people miss. The model is not the only network dependency:

- **Dependencies installed.** `npm install`, `pip install`, `dotnet restore`, `cargo fetch` —
  run them now. An agent that can write code but cannot install a package is half useless.
- **Container images pulled**, if your tests need them.
- **Git state fetched.** `git fetch --all --tags` — you cannot pull a branch mid-flight.
- **Documentation cached.** The agent cannot browse. Vendor the docs you need, or clone the
  relevant repos.
- **Disk space.** Models, caches, and build artifacts add up. Check before, not during.

```powershell
git fetch --all --tags
Get-PSDrive -Name / | Select-Object Used, Free
```

### 7. Power

Sustained local inference is a real load on the SoC. Expect meaningfully reduced battery
life and some thermal throttling on a long session — throughput will drift down over a
multi-hour flight. A smaller model is not just a RAM decision; it is a battery decision.

---

## One-shot pre-flight script

Paste this into a shell before you leave:

```powershell
# Pre-flight for offline agent work
$ErrorActionPreference = 'Stop'

Write-Host 'Syncing models...'       ; ./scripts/Sync-Models.ps1 -Tier recommended
Write-Host 'Fetching git state...'   ; git fetch --all --tags
Write-Host 'Warming model...'        ; ./scripts/Invoke-LocalChat.ps1 'ready?' | Out-Null
Write-Host 'Verifying stack...'      ; ./scripts/Test-LocalStack.ps1 -JsonPath ./out/preflight.json

if ($LASTEXITCODE -ne 0) { Write-Host 'NOT READY - a requested check failed' -ForegroundColor Red }
else { Write-Host 'Ready for offline work' -ForegroundColor Green }
```

---

## What still works offline

- Code completion, explanation, and review on files you already have.
- Writing tests, docstrings, and boilerplate.
- Refactors scoped to a handful of files.
- Shell, git, and filesystem tool use — all local.
- Running your test suite and iterating on failures.
- Rubber-ducking a design, as long as you are the one holding the context.

## What stops working offline

Be clear-eyed about these so you plan around them rather than being surprised:

- **Anything that browses.** Web search, docs lookup, fetching a URL. If the model does not
  already know an API, you are reading source.
- **Package installation.** Pre-install everything.
- **Remote git operations.** Commit locally; push later.
- **The quality ceiling drops.** This is the real cost. A 19 GB local model is not a
  frontier cloud model, and hard reasoning or a large multi-file refactor will go worse.
  Plan the offline block around work that suits a local model — volume, boilerplate,
  mechanical edits — and save the hard architectural thinking for when you land.

---

## Degraded-mode tips

- **Drop model size before accepting slowness.** If throughput tanks, you are swapping.
  Switch to `gemma4:e4b` rather than waiting it out.
- **Keep context short.** KV cache is your RAM constraint. Start a fresh session between
  unrelated tasks instead of carrying a 60k-token history forward.
- **Prefer narrow, well-specified tasks.** Local models hold a plan less well than frontier
  models; "add a test for this function" lands far more reliably than "refactor this module."
- **Check what is resident when things feel wrong.** `./scripts/Get-OllamaStatus.ps1`
  first, always.
