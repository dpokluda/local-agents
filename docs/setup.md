# Setup

Target: macOS on Apple Silicon, with [PowerShell 7](https://github.com/PowerShell/PowerShell)
(`pwsh`) as the shell. Every command on this page is pwsh syntax.

Prerequisite: Homebrew at `/opt/homebrew`. These scripts will not install Homebrew for you.

This page describes the unchanged Mac lifecycle and tuning. For native WinGet/DNF
installation and the shared minimal-model workflow, see [Windows and Fedora](windows-fedora.md).

---

## 1. Install

```powershell
# See exactly what would happen, without touching the system
./scripts/Install-LocalAgents.ps1 -WhatIf

# Do it
./scripts/Install-LocalAgents.ps1
```

Already installed? Follow the [no-redownload update steps](../README.md#already-installed-apply-the-script-fixes-without-downloading-models).
The installer checks existing state before installing packages. It:

1. Verifies the host is macOS on Apple Silicon and reports your memory budget.
2. Verifies Homebrew is present.
3. `brew install ollama` (skipped if already installed).
4. `brew services run ollama` — starts the server **now, without** registering it to
   launch at every login (skipped if the API already answers unless `-AtLogin` is requested).
5. Polls `http://localhost:11434/api/version` until the server responds.

On-demand is the default on purpose. If you want Ollama always available after a reboot:

```powershell
./scripts/Install-LocalAgents.ps1 -AtLogin     # uses `brew services start` instead
```

Otherwise start and stop it per session with `./scripts/Start-Ollama.ps1` /
`./scripts/Stop-Ollama.ps1` — see [When it's not in use](#when-its-not-in-use) below.

Optional GUI with an MLX backend (comparable speed to Ollama's MLX tags, better UI — see
[chat-apps.md](chat-apps.md)):

```powershell
./scripts/Install-LocalAgents.ps1 -InstallLmStudio
```

Manual verification at any point:

```powershell
Invoke-RestMethod http://localhost:11434/api/version
```

### The two endpoints

| Endpoint | Use |
|---|---|
| `http://localhost:11434` | Ollama's native API (`/api/chat`, `/api/tags`, `/api/ps`). |
| `http://localhost:11434/v1` | **OpenAI-compatible shim.** This is what you point agent harnesses at. |

---

## 2. The scripts

There is **no profile to load and nothing to add to `$PROFILE`.** Every helper is a
standalone script you run directly from the repo root:

| Script | Does |
|---|---|
| `./scripts/Get-OllamaStatus.ps1` | Server version + which models are currently resident in RAM. |
| `./scripts/Get-LocalModel.ps1` | Installed models with on-disk sizes. |
| `./scripts/Get-LocalAgentBudget.ps1` | This machine's weight budget and what fits. |
| `./scripts/Invoke-LocalChat.ps1` | One-shot prompt. `./scripts/Invoke-LocalChat.ps1 'explain git rebase'` |
| `./scripts/Start-LocalCopilot.ps1` | Launches Copilot CLI against local Ollama (BYOK), child-process env only. |
| `./scripts/Start-Ollama.ps1` / `Stop-Ollama.ps1` | Service control. Start is on-demand; add `-AtLogin` to register a login item. |
| `./scripts/Restart-Ollama.ps1` | Restart **and re-apply the env knobs** — how you change a setting on a running server. |
| `./scripts/Dismount-LocalModel.ps1` | Frees resident model memory without stopping the server. |

Plus the three lifecycle scripts: `Install-LocalAgents.ps1`, `Sync-Models.ps1`,
`Test-LocalStack.ps1`, and `Uninstall-LocalAgents.ps1`.

Run them from anywhere — they locate their own dependencies via `$PSScriptRoot`, so
`/Users/you/Repos/local-agents/scripts/Get-OllamaStatus.ps1` works just as well as the
relative form.

`scripts/_common.ps1` is an internal helper holding the shared defaults and utilities. It
is not meant to be run directly, but it **is** the one place to edit if you want to change
a default.

> **Optional convenience, not a requirement:** if you get tired of typing the path, add
> `scripts/` to your `PATH` and call them by name (`Start-Ollama.ps1`). Nothing in this
> repo depends on that — every example below uses the explicit path.
>
> ```powershell
> $env:PATH = "$PWD/scripts" + [IO.Path]::PathSeparator + $env:PATH
> ```

---

## 3. Environment knobs

Three settings materially change how a local stack behaves under long agent loops. You do
**not** set these yourself — `Start-Ollama.ps1` and `Restart-Ollama.ps1` apply them to the
service every time they run. The table is here so you know what they are and can override
them.

| Variable | Default | Parameter | Why it matters |
|---|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | `-FlashAttention` | Faster attention kernel. The win grows with context length, so agent loops benefit most. |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | `-KvCacheType` | Roughly **halves KV cache RAM** at long context. This is what lets a 19 GB model survive a 60k-token agent session on a 48 GB machine instead of swapping. |
| `OLLAMA_KEEP_ALIVE` | `-1` | `-KeepAlive` | Keeps weights resident **until the server stops or you unload them**. Without it, an agent that pauses between tool round-trips pays a full cold reload — tens of seconds for a 19 GB model, repeatedly. |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | `-MaxLoadedModels` | Only one model resident at a time. Loading a second one evicts the first instead of stacking. |

Initial defaults live in **`scripts/_common.ps1`**. Start/restart saves the chosen settings
in a service plist. Later omitted parameters reuse those saved values; pass explicit
parameters to change them. Use `-ContextLength 0` or `-MaxLoadedModels 0` to clear those
overrides.

**Why keep-alive is `-1`.** The lifecycle here is **explicit**, not timed. You start the
server when you intend to use it and stop it when you are done, so a coffee break or a long
think should not silently cost you a 19 GB reload. `-1` means weights stay loaded until the
server stops or you unload them.

The tradeoff is real and worth stating plainly: **if you forget to stop the server, the
model stays resident indefinitely** — about **19 GB for `qwen3-coder:30b`**. That memory is
GPU-wired, so macOS *cannot* page it out the way it would an ordinary process. It is simply
gone until you act. Two ways to get it back:

```powershell
./scripts/Stop-Ollama.ps1             # server and weights, everything
./scripts/Dismount-LocalModel.ps1     # weights only, server stays up
```

**If you would rather have a timer back**, pass a duration — the scripts take anything
Ollama accepts:

```powershell
./scripts/Start-Ollama.ps1 -KeepAlive 1h      # or '10m', '30m', '8h'
```

**Why `OLLAMA_MAX_LOADED_MODELS=1` comes with it.** An infinite keep-alive means nothing
evicts a model on a timer, so without a cap they *accumulate*. Concretely:
`qwen3-coder:30b` (19 GB) plus `gpt-oss:20b` (14 GB) is about **33 GB** — which still fits
under Metal's working-set limit, so Ollama has no reason to evict either, and macOS is left
with roughly 15 GB for everything else. With the cap at 1, loading a different model swaps
out the current one. Raise it with `-MaxLoadedModels 2` if you deliberately want two
resident and have checked the budget.

**Ollama's own keep-alive default is 5 minutes** when no override is supplied.
`-NoEnvironment` means **reuse configuration without rewriting it**, not reset to
Ollama's defaults. If a saved plist exists, it is still used.

A fourth knob is **not** set by default because it costs real memory, but you will likely
need it for agent harnesses:

| Variable | Value | Parameter | Why |
|---|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | e.g. `65536` | `-ContextLength` | Defaults vary with runtime/backend and available memory. Choose a window explicitly for agents; Ollama recommends at least 64k and GitHub recommends 128k. More context costs memory. Start at 65536 on a 48 GB Mac and verify the allocation with `Test-LocalStack.ps1 -MinimumContextLength 65536`. |

```powershell
# At startup
./scripts/Start-Ollama.ps1 -ContextLength 65536

# Or on a server that is already running
./scripts/Restart-Ollama.ps1 -ContextLength 65536
```

Use `-NoEnvironment` to start or restart without touching the knobs at all.

### The gotcha that will waste your afternoon

The Ollama server started by `brew services` runs under **launchd**, which does *not*
inherit your shell environment. Setting `$env:OLLAMA_KEEP_ALIVE` in a terminal — or in a
profile — changes **nothing** about the server's behaviour. This is the single most common
way people conclude the knobs "don't work."

The scripts now write **`~/Library/Application Support/local-agents/ollama.plist`** and
pass it to `brew services run/start ollama --file=...`. This file contains the actual
`EnvironmentVariables` used by the process, so it overrides Homebrew's formula defaults.
It references Homebrew's stable `opt` executable path, not the repository or a particular
Cellar version.

With **`-AtLogin`**, Homebrew registers a copy in your LaunchAgents directory. The saved
values therefore survive reboot without PowerShell or this checkout running at login.
Without `-AtLogin`, the configuration persists but startup remains on demand.
Registering an already-running on-demand service requires a brief stop/start; the scripts
do this deliberately because `brew services start` otherwise skips a running service.

The old scripts used `launchctl setenv`. Those values were transient, and conflicting
plist values took precedence. A normal start/restart clears only the five old tuning keys
after saving the replacement configuration. Existing `OLLAMA_MODELS` values observed in
the server environment (or its launchctl fallback) are preserved in the plist, including
paths with spaces. Keep using these scripts after Homebrew upgrades so startup continues
to use the custom file; a manual `brew services restart ollama` can restore formula defaults.

Confirm what the server actually picked up:

```powershell
./scripts/Test-LocalStack.ps1 -SkipBenchmark -SkipToolCheck
```

The check prefers the **server process's environment** (`ps eww`) and labels its source.
A `launchctl getenv` fallback is only a hint, not proof of what a running process inherited.
Environment inspection is advisory; it is unavailable for remote/non-Mac endpoints.
To check a model's actual allocated window, use `-MinimumContextLength` after inference.

The alternative, if you prefer not to touch launchd: stop the service and run the server in
the foreground, where it does inherit your shell environment.

```powershell
./scripts/Stop-Ollama.ps1
$env:OLLAMA_KEEP_ALIVE = '-1'
$env:OLLAMA_MAX_LOADED_MODELS = '1'
ollama serve     # inherits your shell environment, including the knobs
```

---

## 4. Pull models

```powershell
# Preview the plan: sizes, what is already present, disk totals
./scripts/Sync-Models.ps1 -Tier recommended -ListOnly

# Pull it
./scripts/Sync-Models.ps1 -Tier recommended
```

Tiers are defined in [`models.json`](../models.json) and explained in [models.md](models.md).

```powershell
./scripts/Sync-Models.ps1 -Tier minimal          # gemma4:e4b only, 7.5 GB
./scripts/Sync-Models.ps1 -Tier full             # all seven, ~107 GB
./scripts/Sync-Models.ps1 -Tier full -UseMlx     # prefer Apple MLX builds
./scripts/Sync-Models.ps1 -Tag 'gpt-oss:20b'     # one specific model
```

Already-present tags are skipped; rerunning does not refresh their weights. Explicit tags
with unknown sizes are supported, but excluded from size totals. All reads, downloads,
and deletions use the same `-BaseUrl` (or `OLLAMA_HOST`).
To also remove models that are no longer in the tier:

```powershell
./scripts/Sync-Models.ps1 -Tier recommended -Prune -WhatIf
```

Without `-WhatIf`, pruning asks for confirmation for each extra model. Use
`-Confirm:$false` only when deliberately approving all deletions. Pruning will not run if
the desired replacement models are missing after downloads.

---

## 5. Verify

```powershell
./scripts/Test-LocalStack.ps1
```

This is the script that earns its keep. Per installed model it reports throughput
(tokens/sec, taken from Ollama's own eval counters rather than wall clock), load duration,
and native tool-call shape. It also reassembles streamed tool calls from
`/v1/chat/completions`, submits a synthetic tool result, and checks the final reply.
This is a bounded smoke test, not a long-context evaluation or a Responses API test.

Tool-calling is checked separately because its failure mode is silent. A model that ignores
tool definitions does not error; it writes a friendly paragraph *about* calling the tool,
the harness gets no `tool_calls` array, and the agent loop quietly stalls. You want to find
that out from a health check, not from an agent that has been spinning for ten minutes.

The script exits non-zero if any requested benchmark, tool, context, or unload check fails,
including benchmark-only runs. Skips are not counted as successful inference.

```powershell
# Memory-friendly sweep of a large tier, with results saved for comparison over time
./scripts/Test-LocalStack.ps1 -UnloadAfterEach -JsonPath ./out/stack-check.json

# Just one model
./scripts/Test-LocalStack.ps1 -Model 'qwen3-coder:30b' -MinimumContextLength 65536
```

---

## 6. Wire up a harness

See [harnesses.md](harnesses.md) for the GitHub Copilot app, Copilot CLI, Aider, OpenCode,
and raw SDK clients. For general (non-coding) chat, see [chat-apps.md](chat-apps.md).

---

## When it's not in use

Worth knowing, because "am I leaving a 19 GB process running?" is the obvious worry and the
answer is reassuring.

**An idle server is cheap.** With no model loaded, `ollama serve` sits under **100 MB** of
RAM and uses essentially no CPU. It is a socket waiting for a request.

**A loaded model is not.** That is where the memory goes — the full weight size, resident,
for as long as `OLLAMA_KEEP_ALIVE` says. This repo sets `-1`, so **it stays until you stop
the server or unload it**; that is deliberate, because starting the server is how you say
"I am using this." Ollama's own default is 5 minutes, which is what applies if you start
the server without any keep-alive override. `-NoEnvironment` preserves existing settings.

So there are three reasonable postures:

```powershell
# 1. On-demand: start it when you sit down, stop it when you're done.
./scripts/Start-Ollama.ps1        # brew services run - no login item
# ...work...
./scripts/Stop-Ollama.ps1         # frees everything, server included

# 2. Leave the server up, free the weights early.
./scripts/Dismount-LocalModel.ps1                    # unload everything resident now
./scripts/Dismount-LocalModel.ps1 qwen3-coder:30b    # or just one

# 3. Put the timer back, and let it expire on its own.
./scripts/Start-Ollama.ps1 -KeepAlive 10m
```

Check what is actually resident at any time:

```powershell
./scripts/Get-OllamaStatus.ps1    # server version + loaded models with their RAM
```

If you installed with `-AtLogin`, the server comes back on every boot.
`./scripts/Stop-Ollama.ps1` undoes that registration as well as stopping the process, so it
is the full off switch.

---

## Uninstall

```powershell
# See what would go, including how much disk ~/.ollama is using
./scripts/Uninstall-LocalAgents.ps1 -WhatIf

# Full revert: stop service, uninstall formula, delete ~/.ollama
./scripts/Uninstall-LocalAgents.ps1

# Remove the software but keep the downloaded weights
./scripts/Uninstall-LocalAgents.ps1 -KeepModels
```

The equivalent by hand:

```powershell
brew services stop ollama
brew uninstall ollama
Remove-Item -Recurse -Force ~/.ollama
```

`~/.ollama` is where the disk space actually lives. Uninstalling the formula without
removing it leaves tens of gigabytes behind.

Nothing in this repo was ever added to your `$PROFILE`, so there is nothing to unwind
there. Delete the repo directory when you are done with it.

The uninstaller also offers to remove the saved service plist. It leaves diagnostic logs
and any custom `OLLAMA_MODELS` directory alone, reporting the latter for manual handling.

---

## Troubleshooting

**`Test-LocalStack.ps1` says the server is unreachable.**
`brew services list` to check state; custom-service logs are at `~/Library/Logs/local-agents/ollama.log`.
Try `./scripts/Stop-Ollama.ps1` then `ollama serve` in the foreground to see errors directly.

**Generation is inexplicably slow (single-digit tokens/sec on a big machine).**
Possible causes include memory pressure, CPU offload, prompt processing, or throttling. Check resident models with
`./scripts/Get-OllamaStatus.ps1` and compare the total against
`./scripts/Get-LocalAgentBudget.ps1`. Free memory with `./scripts/Dismount-LocalModel.ps1`,
or sweep a whole tier with `./scripts/Test-LocalStack.ps1 -UnloadAfterEach`.

**Tool-calling fails for one specific model.**
Usually the tag is a base (non-instruct) build, or its bundled template lacks tool support.
Try the `-instruct`-style variant if one exists, or fall back to `gpt-oss:20b`, which is
the most reliable tool-caller in this set.

**Tool-calling fails for _every_ model, with HTTP 400.**
That pattern — all models, both endpoints — is not a model problem. It means the request
itself is malformed, and the server's response body says so precisely. `Test-LocalStack.ps1`
prints that body rather than just the status code, so look for the text after
`HTTP BadRequest -`. For example:

```
json: cannot unmarshal object into Go struct field .tools of type api.Tools
```

means `tools` was sent as a JSON object instead of an array.

**The knobs do not seem to apply.**
The service runs under launchd, not your shell. Run
`./scripts/Restart-Ollama.ps1`, then confirm with `./scripts/Test-LocalStack.ps1
-SkipBenchmark -SkipToolCheck`, which reads the server process rather than your shell.
See section 3.

**Installed, but the server is on a 5-minute keep-alive.**
An already-running server does not read a changed plist. `./scripts/Restart-Ollama.ps1`
applies the saved values. Native API requests with their own `keep_alive` override the
server default for that model.
