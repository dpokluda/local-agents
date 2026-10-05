#Requires -Version 7.0
<#
.SYNOPSIS
    Shows whether the Ollama server is up and which models are currently resident in RAM.

.DESCRIPTION
    The first thing to run when something feels wrong. Resident models are where your
    unified memory goes - if throughput has collapsed, compare the total here against
    ./scripts/Get-LocalAgentBudget.ps1.

    Free memory without stopping the server: ./scripts/Dismount-LocalModel.ps1

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.EXAMPLE
    ./scripts/Get-OllamaStatus.ps1
#>
[CmdletBinding()]
param([string]$BaseUrl)

Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

$version = Get-OllamaVersion -BaseUrl $BaseUrl
if (-not $version) {
    Write-Host "Ollama is not reachable at $BaseUrl" -ForegroundColor Red
    Write-Host '  Start it with: ./scripts/Start-Ollama.ps1' -ForegroundColor Yellow
    return
}

Write-Host "Ollama $version at $BaseUrl" -ForegroundColor Green

# What the server process actually sees, not what this shell has.
$serverEnv = Get-OllamaServerEnvironment
if ($serverEnv.Values.Count -gt 0) {
    Write-Host "  Server environment, via $($serverEnv.Source):" -ForegroundColor DarkGray
    foreach ($entry in $serverEnv.Values.GetEnumerator()) {
        Write-Host "    $($entry.Key)=$($entry.Value)" -ForegroundColor DarkGray
    }
}
else {
    Write-Host '  No OLLAMA_* knobs set on the server process.' -ForegroundColor DarkGray
    Write-Host '  Apply them with: ./scripts/Restart-Ollama.ps1' -ForegroundColor DarkGray
}

try {
    $running = Invoke-RestMethod -Uri "$BaseUrl/api/ps" -TimeoutSec 5 -ErrorAction Stop
}
catch {
    Write-Warning "Could not read $BaseUrl/api/ps : $(Get-HttpErrorDetail -ErrorRecord $_)"
    return
}

$loaded = @($running.models)
if ($loaded.Count -eq 0) {
    Write-Host '  No models currently resident (server idle, well under 100MB).' -ForegroundColor DarkGray
    return
}

$loaded | Select-Object `
@{ L = 'Model'; E = { $_.name } },
@{ L = 'RAM(GB)'; E = { '{0:0.#}' -f ($_.size / 1GB) } },
@{ L = 'ExpiresAt'; E = { $_.expires_at } }
