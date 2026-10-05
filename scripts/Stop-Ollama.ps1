#Requires -Version 7.0
<#
.SYNOPSIS
    Stops the Ollama service, freeing all resident model memory.

.DESCRIPTION
    `brew services stop` stops the server AND unregisters any launchd login item, so this
    is the full off switch - it undoes './scripts/Start-Ollama.ps1 -AtLogin' as well.

    If you only want to free model memory and leave the server running, use
    ./scripts/Dismount-LocalModel.ps1 instead. An idle server costs well under 100MB.

.EXAMPLE
    ./scripts/Stop-Ollama.ps1

.EXAMPLE
    ./scripts/Stop-Ollama.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$BaseUrl)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

Write-Step 'Stopping Ollama service'
if (-not $BaseUrl -and -not $env:OLLAMA_HOST) {
    $saved = Get-SavedOllamaEnvironment
    if ($saved.Contains('OLLAMA_HOST')) { $BaseUrl = $saved['OLLAMA_HOST'] }
}
Stop-OllamaService -BaseUrl (Resolve-LocalAgentBaseUrl $BaseUrl)
