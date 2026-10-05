#Requires -Version 7.0
<#
.SYNOPSIS
    Prints this machine's rough model-weight budget and what comfortably fits.

.DESCRIPTION
    Apple Silicon shares one memory pool between CPU and GPU, so model weights compete
    directly with macOS, your apps, and the KV cache - which grows with context length,
    and agent loops have long context.

    This reserves the larger of 8GB or 29% of unified memory for all of that, matching the
    table in docs/models.md (a 48GB machine -> 34GB of weights).

    Treat the result as a ceiling, not a target. A model slightly over budget does not
    fail cleanly: macOS swaps and throughput collapses to single digits.

.EXAMPLE
    ./scripts/Get-LocalAgentBudget.ps1
#>
[CmdletBinding()]
param([string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'models.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsMacOS) { throw 'This budget is for Apple unified memory, not PC system RAM or dedicated VRAM.' }
$totalGb = [math]::Round([int64](& sysctl -n hw.memsize) / 1GB, 0)
if ($LASTEXITCODE -ne 0 -or $totalGb -le 0) { throw 'Could not read unified memory from sysctl.' }
$reservedGb = [math]::Round([math]::Max(8, $totalGb * 0.29), 0)
$budgetGb = [math]::Max(0, $totalGb - $reservedGb)
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$fits = @($manifest.models | Where-Object {
    $null -ne $_.size_gb -and ([double]$_.size_gb * 1e9) -le ($budgetGb * 1GB)
} | ForEach-Object { $_.tag })

[pscustomobject]@{
    UnifiedMemoryGb   = $totalGb
    ReservedGb        = $reservedGb
    WeightBudgetGb    = $budgetGb
    ComfortableModels = if ($fits.Count) { $fits -join ', ' } else { 'no manifest models fit the estimated budget' }
    Note              = 'Memory fields are GiB; model sizes are estimates, not a load test. Context and backend overhead still matter.'
}
