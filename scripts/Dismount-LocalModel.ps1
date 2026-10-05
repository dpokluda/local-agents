#Requires -Version 7.0
<#
.SYNOPSIS
    Unloads models from memory without stopping the server.

.DESCRIPTION
    Sets keep_alive to 0 for a model, which tells Ollama to evict it immediately. The
    server keeps running - it costs well under 100MB idle - and only the weights are
    freed. That is usually what you want: a loaded model holds its full size in unified
    memory (~19GB for qwen3-coder:30b) until OLLAMA_KEEP_ALIVE expires.

    With no -Model, every model currently listed by /api/ps is unloaded.

    To stop the server as well, use ./scripts/Stop-Ollama.ps1.

.PARAMETER Model
    Tag to unload. Omit to unload everything currently resident.

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.EXAMPLE
    ./scripts/Dismount-LocalModel.ps1

    Frees all resident model memory.

.EXAMPLE
    ./scripts/Dismount-LocalModel.ps1 qwen3-coder:30b

.EXAMPLE
    ./scripts/Dismount-LocalModel.ps1 -WhatIf

    Shows what would be unloaded without doing it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$Model,

    [string]$BaseUrl
)

Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

if ($Model) {
    $targets = @($Model)
}
else {
    if (-not (Get-OllamaVersion -BaseUrl $BaseUrl)) {
        Write-Host "Ollama is not reachable at $BaseUrl - nothing to unload." -ForegroundColor Yellow
        return
    }
    $targets = @(Get-ResidentOllamaModel -BaseUrl $BaseUrl)
}

if ($targets.Count -eq 0) {
    Write-Host 'No models are currently resident.' -ForegroundColor DarkGray
    return
}

foreach ($target in $targets) {
    if (-not $PSCmdlet.ShouldProcess($target, 'unload from memory')) { continue }

    if (Invoke-OllamaUnload -BaseUrl $BaseUrl -ModelTag $target) {
        Write-Host "  unloaded $target" -ForegroundColor Green
    }
}
