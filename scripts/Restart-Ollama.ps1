#Requires -Version 7.0
<#
.SYNOPSIS
    Restarts the Ollama service. On macOS, also re-applies the saved performance knobs.

.DESCRIPTION
    On Fedora 42+, restarts the packaged systemd service, preserving native settings
    and boot policy. On Windows, quit/reopen the native Ollama app instead. The tuning
    and -AtLogin options below apply only to macOS.

    Implemented as stop + `brew services run`, deliberately NOT `brew services restart` -
    restart registers a launchd login item as a side effect, which is a surprising thing
    for a restart to do. Pass -AtLogin if you actually want that.

    Settings are stored in a persistent service plist. Omitted settings reuse saved
    values, so a restart does not silently reset a previously selected context length.

    Defaults live in scripts/_common.ps1.

.PARAMETER AtLogin
    Use stop + `brew services start`, registering Ollama to launch at every login.

.PARAMETER KeepAlive
    How long weights stay resident after the last request. Default '-1' (until the server
    stops or the model is unloaded explicitly). Pass a duration like '1h' for time-based
    unloading.

.PARAMETER MaxLoadedModels
    Sets OLLAMA_MAX_LOADED_MODELS. Default 1, which stops models accumulating under an
    infinite keep-alive. Pass 0 to leave it unset.

.PARAMETER KvCacheType
    KV cache quantization. Default 'q8_0'.

.PARAMETER FlashAttention
    Faster attention kernel. Default $true.

.PARAMETER ContextLength
    Sets OLLAMA_CONTEXT_LENGTH. Reuses the saved value when omitted; 0 resets to Ollama's
    default. Start with 65536 for coding agents if the model and memory budget permit it.

.PARAMETER NoEnvironment
    Restart using the existing configuration without rewriting it; not a factory reset.

.EXAMPLE
    ./scripts/Restart-Ollama.ps1 -ContextLength 65536

    Raise the context window on a running server. This is the common case.

.EXAMPLE
    ./scripts/Restart-Ollama.ps1 -KeepAlive 1h

    Switch a running server to time-based unloading after an hour of inactivity.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$AtLogin,
    [string]$KeepAlive,
    [ValidateSet('f16', 'q8_0', 'q4_0')]
    [string]$KvCacheType,
    [bool]$FlashAttention,
    [ValidateRange(0, 2147483647)]
    [int]$ContextLength,
    [ValidateRange(0, 2147483647)]
    [int]$MaxLoadedModels,
    [switch]$NoEnvironment,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60,
    [string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& "$PSScriptRoot/Start-Ollama.ps1" @PSBoundParameters -Restart
