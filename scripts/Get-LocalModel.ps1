#Requires -Version 7.0
<#
.SYNOPSIS
    Lists installed models with their on-disk size.

.DESCRIPTION
    Prints the exact tags Ollama knows about. Copy model names from here rather than
    typing them - 'qwen3-coder:30b' and 'qwen3-coder:30B' are different strings, and a
    typo shows up as a confusing harness error rather than "no such model".

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.EXAMPLE
    ./scripts/Get-LocalModel.ps1
#>
[CmdletBinding()]
param([string]$BaseUrl)

Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

if (-not (Test-OllamaReachable -BaseUrl $BaseUrl)) { return }

try {
    $tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 10 -ErrorAction Stop
}
catch {
    Write-Warning "Could not read $BaseUrl/api/tags : $(Get-HttpErrorDetail -ErrorRecord $_)"
    return
}

$models = @($tags.models)
if ($models.Count -eq 0) {
    Write-Host 'No models installed. Pull some with: ./scripts/Sync-Models.ps1 -Tier recommended' -ForegroundColor Yellow
    return
}

$models | Sort-Object name | Select-Object `
@{ L = 'Model'; E = { $_.name } },
@{ L = 'Size(GB)'; E = { [math]::Round($_.size / 1e9, 1) } },
@{ L = 'Modified'; E = { $_.modified_at } }
