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
param()

Set-StrictMode -Version Latest

$totalGb = [math]::Round([int64](& sysctl -n hw.memsize) / 1GB, 0)
$reservedGb = [math]::Round([math]::Max(8, $totalGb * 0.29), 0)
$budgetGb = [math]::Max(0, $totalGb - $reservedGb)

[pscustomobject]@{
    UnifiedMemoryGb   = $totalGb
    ReservedGb        = $reservedGb
    WeightBudgetGb    = $budgetGb
    ComfortableModels = switch ($budgetGb) {
        { $_ -ge 80 } { 'everything in models.json, plus the 65-75GB tier (gpt-oss:120b, devstral-2)'; break }
        { $_ -ge 45 } { 'everything in models.json with room to spare; the 52GB+ tier is still out of reach'; break }
        { $_ -ge 30 } { 'everything in models.json (largest is qwen3-coder:30b at 19GB)'; break }
        { $_ -ge 14 } { 'gpt-oss:20b, devstral-small-2:24b, gemma4:26b, gemma4:e4b'; break }
        { $_ -ge 8 } { 'gemma4:e4b only'; break }
        default { 'too little headroom for comfortable agent work'; break }
    }
}
