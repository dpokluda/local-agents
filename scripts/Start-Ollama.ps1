#Requires -Version 7.0
<#
.SYNOPSIS
    Applies the performance knobs to the launchd service and starts Ollama.

.DESCRIPTION
    Starts the brew-managed Ollama service on demand, after registering the environment
    knobs that the server actually reads.

    Two things this gets right that are easy to get wrong by hand:

      * `brew services run` starts the server now WITHOUT registering a launchd login
        item, so your Mac does not boot a model server you did not ask for. Use -AtLogin
        for the always-on behaviour.

      * The server runs under launchd, which does NOT inherit your shell environment.
        Setting $env:OLLAMA_* in a terminal has no effect on it. This script uses
        `launchctl setenv` instead, which does work.

    launchctl setenv values last until reboot, not forever. That is fine here, because
    this script re-applies them every time it starts the service.

    Defaults live in scripts/_common.ps1 - change them there, not here.

.PARAMETER AtLogin
    Use `brew services start`, which also registers Ollama to launch at every login.
    The default is on-demand.

.PARAMETER KeepAlive
    How long weights stay resident after the last request. Default '-1', meaning they
    stay loaded until the server stops or the model is unloaded explicitly. The lifecycle
    is deliberate here: starting the service means you intend to use it, so an idle gap
    should not cost a cold reload. The cost is that a loaded model holds its full size in
    GPU-wired memory (~19GB for qwen3-coder:30b) until you act. Free it with
    './scripts/Stop-Ollama.ps1' or './scripts/Dismount-LocalModel.ps1', or pass a duration
    like '1h' or '10m' for time-based unloading.

.PARAMETER MaxLoadedModels
    Sets OLLAMA_MAX_LOADED_MODELS. Default 1. With an infinite keep-alive nothing evicts
    a model on a timer, so without a cap they accumulate - qwen3-coder:30b plus
    gpt-oss:20b is ~33GB resident. A cap of 1 makes loading a model swap out the previous
    one. Pass 0 to leave it unset and use Ollama's own default.

.PARAMETER KvCacheType
    KV cache quantization. Default 'q8_0', which roughly halves KV RAM at long context.

.PARAMETER FlashAttention
    Faster attention kernel. Default $true.

.PARAMETER ContextLength
    Sets OLLAMA_CONTEXT_LENGTH. Unset by default, because a bigger window costs KV cache
    RAM. Agent harnesses need it: 65536 is the practical floor on a 48GB machine.

.PARAMETER NoEnvironment
    Skip the knob registration entirely and just start the service.

.PARAMETER TimeoutSeconds
    How long to wait for the API to answer after starting.

.EXAMPLE
    ./scripts/Start-Ollama.ps1

    Applies the default knobs and starts the service for this session only.

.EXAMPLE
    ./scripts/Start-Ollama.ps1 -ContextLength 65536

    Same, with a 64k context window - what you want before an agent session.

.EXAMPLE
    ./scripts/Start-Ollama.ps1 -KeepAlive 1h

    Go back to time-based unloading: weights are released an hour after the last request.

.NOTES
    Stop it again with ./scripts/Stop-Ollama.ps1, which also removes any login item.
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

# Defaults are resolved here rather than in param() so they live in exactly one place.
if (-not $PSBoundParameters.ContainsKey('KeepAlive')) { $KeepAlive = $LocalAgentDefaults.KeepAlive }
if (-not $PSBoundParameters.ContainsKey('KvCacheType')) { $KvCacheType = $LocalAgentDefaults.KvCacheType }
if (-not $PSBoundParameters.ContainsKey('FlashAttention')) { $FlashAttention = $LocalAgentDefaults.FlashAttention }
if (-not $PSBoundParameters.ContainsKey('ContextLength')) { $ContextLength = $LocalAgentDefaults.ContextLength }
if (-not $PSBoundParameters.ContainsKey('MaxLoadedModels')) { $MaxLoadedModels = $LocalAgentDefaults.MaxLoadedModels }

$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

$existing = Get-OllamaVersion -BaseUrl $BaseUrl
if ($existing) {
    Write-Host "Ollama is already running at $BaseUrl (v$existing)." -ForegroundColor Green
    Write-Detail 'To apply different knobs to a running server, use ./scripts/Restart-Ollama.ps1'
    return
}

if ($NoEnvironment) {
    Write-Step 'Skipping environment knobs (-NoEnvironment)'
}
else {
    Write-Step 'Registering environment knobs with launchd'
    Set-OllamaServiceKnob -KeepAlive $KeepAlive -KvCacheType $KvCacheType `
        -FlashAttention $FlashAttention -ContextLength $ContextLength `
        -MaxLoadedModels $MaxLoadedModels
}

Write-Step "Starting Ollama ($(if ($AtLogin) { 'brew services start - registers at login' } else { 'brew services run - this session only' }))"
Start-OllamaService -AtLogin:$AtLogin

if ($WhatIfPreference) { return }

Write-Detail "Waiting up to ${TimeoutSeconds}s for the API..."
$version = Wait-OllamaApi -BaseUrl $BaseUrl -TimeoutSeconds $TimeoutSeconds
if (-not $version) {
    throw "Ollama did not answer on $BaseUrl within ${TimeoutSeconds}s. Check 'brew services list' and ~/Library/Logs/Homebrew/ollama/."
}
Write-Ok "server up (v$version)"
