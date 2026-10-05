#Requires -Version 7.0
<#
.SYNOPSIS
    Stops the Ollama service, freeing all resident model memory.

.DESCRIPTION
    On Fedora 42+, stops ollama.service without changing its boot policy. On Windows,
    quit the native Ollama tray app instead.

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

if (-not $IsMacOS) {
    if ($IsWindows) { throw 'On Windows, quit Ollama from its tray menu. This script does not kill the app or unrelated server processes.' }
    . "$PSScriptRoot/_fedora.ps1"
    Invoke-FedoraOllamaService -Action stop -BaseUrl (Resolve-LocalAgentBaseUrl $BaseUrl)
    return
}

Write-Step 'Stopping Ollama service'
if (-not $BaseUrl -and -not $env:OLLAMA_HOST) {
    $saved = Get-SavedOllamaEnvironment
    if ($saved.Contains('OLLAMA_HOST')) { $BaseUrl = $saved['OLLAMA_HOST'] }
}
Stop-OllamaService -BaseUrl (Resolve-LocalAgentBaseUrl $BaseUrl)
