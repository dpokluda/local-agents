# Windows and Fedora

Mac remains the main platform. These paths reuse the same PowerShell scripts and
`models.json`; there are no machine profiles or separate model lists. Install
[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
first and run the scripts from `pwsh`, not Windows PowerShell 5.1.

## Install

```powershell
./scripts/Install-LocalAgents.ps1 -WhatIf
./scripts/Install-LocalAgents.ps1
```

### Windows

Requires WinGet (App Installer). The script uses:

```powershell
winget install --id Ollama.Ollama --exact --source winget
```

It skips installation when an Ollama CLI is already available. It also recognizes the
standard per-user install location before the current terminal's PATH has refreshed.
For a custom install location, reopen PowerShell or add the binary directory to PATH.
Package-manager errors stop the script; source/package agreement prompts remain native.

**Open Ollama from the Start menu.** This is the standard native application, not a
custom service or scheduled task. The installer reports whether the API answers, but
does not launch, kill, configure, or claim ownership of the app. `-SkipService` skips
that status check; it cannot prevent the vendor installer from launching its own app.

To stop or restart, **quit through the tray menu**, then reopen from Start if needed.
The service-control scripts deliberately return this guidance as an error on Windows
rather than killing processes or reporting a restart that did not happen.

For optional tuning, set user environment variables such as `OLLAMA_CONTEXT_LENGTH`
or `OLLAMA_MODELS`, then quit/reopen the app. Startup behavior is managed using the
native app/Windows startup settings. The scripts do not apply the Mac's tuning here.

### Fedora 42 or newer

Uses the official Fedora package, with elevation only where needed:

```bash
sudo dnf install ollama
```

The script checks the RPM first, and refuses to replace an existing non-RPM Ollama
installation. It does not add repositories, install GPU drivers, or fall back to a
downloaded upstream shell script.

Unless `-SkipService` is given, it starts the packaged `ollama.service` and waits for
the API. The normal wrappers are available:

```powershell
./scripts/Start-Ollama.ps1
./scripts/Restart-Ollama.ps1
./scripts/Stop-Ollama.ps1
```

These preserve native tuning and **do not enable or disable startup at boot**.
Package presets/existing configuration determine that policy; change it explicitly if
wanted with `sudo systemctl enable ollama.service` or `sudo systemctl disable ollama.service`.
Boot is not login, so `-AtLogin` is not supported on Fedora.

Configure tuning through `sudo systemctl edit ollama.service`, adding environment
entries under `[Service]`, then run `sudo systemctl daemon-reload` and restart the service.
View logs with `sudo journalctl -u ollama.service`.
The service runs as its own user: use its configuration and permissions when moving
model storage, not the client's `$HOME`. Fedora packaging may differ from upstream,
including storage defaults and acceleration backends.

Mac tuning flags (`-ContextLength`, `-KeepAlive`, `-KvCacheType`, `-FlashAttention`,
`-MaxLoadedModels`, `-NoEnvironment`) and the optional LM Studio installation/removal
are not implemented for these platforms. They fail explicitly rather than being ignored.
Other Linux distributions can use the API scripts against an externally managed Ollama.

## One minimal-model workflow

Once the server is running:

```powershell
./scripts/Sync-Models.ps1 -Tier minimal
./scripts/Test-LocalStack.ps1 -Model 'gemma4:e4b'
if ($LASTEXITCODE -ne 0) { throw 'Resolve the reported failure before launching an agent.' }
./scripts/Invoke-LocalChat.ps1 'Explain git rebase briefly.' -Model 'gemma4:e4b'
./scripts/Start-LocalCopilot.ps1 -Model 'gemma4:e4b'
```

Syncing a tier only selects downloads. It does not change the default model used by
chat/Copilot; that remains `qwen3-coder:30b` for the Mac workflow. Use `-Model` explicitly.
Do not automatically copy the Mac's long-context configuration to the PC.

`gemma4:e4b` is a reasonable first trial, not a guarantee of agent quality or speed.
DPOKLUDA's system RAM can accommodate it, but the P600 cannot hold it entirely in VRAM:
expect CPU-heavy inference. Larger models are not forbidden by Windows; their latency
may be impractical. A failed model load/tool check can also mean the packaged runtime
needs an update (`winget upgrade --id Ollama.Ollama --exact` or `sudo dnf upgrade ollama`).

## Diagnostics and model data

Listing, chat, sync, unloading, status, deletion, and readiness share the same API path
on all platforms. Non-Mac/remote readiness requests leave native keep-alive unchanged
unless `-KeepAlive` is explicitly supplied. They do not read the Mac plist or recommend
Mac settings as if they had inspected the target server.

`Get-LocalAgentBudget.ps1` remains Mac-only. The manifest's Mac memory budget is not
used for Windows, Fedora, or remote sync; these scripts do not infer a GPU memory budget.
Model deletion still works through the API, but reclaimed disk space is reported as
unknown outside local Mac accounting. It never measures the client's disk for a remote
server. An API on localhost must belong to the local installation for Mac diagnostics
to be meaningful; a localhost tunnel is not a remotely managed service.

## Uninstall

Delete any unwanted models **while Ollama is still running**, using
`Remove-LocalModel.ps1` (with its normal confirmation). Then quit the Windows tray app,
or let the Fedora uninstaller stop its service:

```powershell
./scripts/Uninstall-LocalAgents.ps1 -WhatIf
./scripts/Uninstall-LocalAgents.ps1
```

Uses `winget uninstall --id Ollama.Ollama --exact --silent` or `dnf remove ollama`.
These script paths do **not** recursively delete model/configuration directories,
regardless of `-KeepModels`. Windows silent mode avoids the native uninstaller's
preselected "Remove models" checkbox; no model deletion is requested. The native
uninstaller can still remove app settings, history, and logs. Back up important data
before uninstalling. Data cleanup beyond the model API is manual. Mac uninstall retains
its existing behavior, including `-KeepModels`.

## References

- [Ollama on Windows](https://docs.ollama.com/windows)
- [WinGet package](https://github.com/microsoft/winget-pkgs/tree/master/manifests/o/Ollama/Ollama)
- [Fedora Ollama guide](https://docs.fedoraproject.org/en-US/quick-docs/ollama/)
- [Fedora package](https://packages.fedoraproject.org/pkgs/ollama/ollama/)
- [Ollama environment and storage settings](https://docs.ollama.com/faq)
