#Requires -Version 7.0
<#
.SYNOPSIS
    Restarts the Ollama service, re-applying the performance knobs. This is how you change
    a setting on a server that is already running.

.DESCRIPTION
    Implemented as stop + `brew services run`, deliberately NOT `brew services restart` -
    restart registers a launchd login item as a side effect, which is a surprising thing
    for a restart to do. Pass -AtLogin if you actually want that.

    Because the knobs are re-registered with `launchctl setenv` on every restart, this is
    also the script to run after changing a value. There is no separate
    "set the environment" script: changing a knob means restarting the server anyway.

    Defaults live in scripts/_common.ps1.

.PARAMETER AtLogin
    Use `brew services restart`, which also registers Ollama to launch at every login.

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
    Sets OLLAMA_CONTEXT_LENGTH. Unset by default. 65536 is the practical floor for agent
    harnesses on a 48GB machine.

.PARAMETER NoEnvironment
    Restart without touching the knobs.

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
    [string]$KvCacheType,
    [bool]$FlashAttention,
    [int]$ContextLength,
    [int]$MaxLoadedModels,
    [switch]$NoEnvironment,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60,
    [string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

if (-not $PSBoundParameters.ContainsKey('KeepAlive')) { $KeepAlive = $LocalAgentDefaults.KeepAlive }
if (-not $PSBoundParameters.ContainsKey('KvCacheType')) { $KvCacheType = $LocalAgentDefaults.KvCacheType }
if (-not $PSBoundParameters.ContainsKey('FlashAttention')) { $FlashAttention = $LocalAgentDefaults.FlashAttention }
if (-not $PSBoundParameters.ContainsKey('ContextLength')) { $ContextLength = $LocalAgentDefaults.ContextLength }
if (-not $PSBoundParameters.ContainsKey('MaxLoadedModels')) { $MaxLoadedModels = $LocalAgentDefaults.MaxLoadedModels }

$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

if ($NoEnvironment) {
    Write-Step 'Skipping environment knobs (-NoEnvironment)'
}
else {
    Write-Step 'Registering environment knobs with launchd'
    Set-OllamaServiceKnob -KeepAlive $KeepAlive -KvCacheType $KvCacheType `
        -FlashAttention $FlashAttention -ContextLength $ContextLength `
        -MaxLoadedModels $MaxLoadedModels
}

Write-Step 'Stopping Ollama service'
Stop-OllamaService

if ($AtLogin) {
    Write-Step 'Starting Ollama (brew services start - registers at login)'
}
else {
    Write-Step 'Starting Ollama (brew services run - this session only)'
}
Start-OllamaService -AtLogin:$AtLogin

if ($WhatIfPreference) { return }

Write-Detail "Waiting up to ${TimeoutSeconds}s for the API..."
$version = Wait-OllamaApi -BaseUrl $BaseUrl -TimeoutSeconds $TimeoutSeconds
if (-not $version) {
    throw "Ollama did not answer on $BaseUrl within ${TimeoutSeconds}s. Check 'brew services list' and ~/Library/Logs/Homebrew/ollama/."
}
Write-Ok "server up (v$version)"
