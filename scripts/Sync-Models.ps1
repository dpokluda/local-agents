#Requires -Version 7.0
<#
.SYNOPSIS
    Pulls and verifies the model set declared in models.json.

.DESCRIPTION
    models.json is the single source of truth for which models this machine should have.
    This script reconciles the local Ollama model store against a tier from that manifest.

    Idempotent: models that are already present are skipped, so re-running costs nothing.

    Tiers:
      minimal      - the small always-works model (fits any Apple Silicon Mac)
      recommended  - the daily-driver set for a 48GB machine
      full         - everything in the manifest

.PARAMETER Tier
    Which tier from models.json to sync. Defaults to 'recommended'.

.PARAMETER Tag
    Sync one or more explicit tags instead of a tier. Tags do not have to appear in
    the manifest; unknown tags are pulled with a warning.

.PARAMETER ManifestPath
    Path to models.json. Defaults to the manifest at the repo root.

.PARAMETER UseMlx
    Prefer the Apple-Silicon-native MLX variant of a model when the manifest declares one.
    MLX builds are meaningfully faster on M-series hardware.

.PARAMETER ListOnly
    Show the plan (what is present, what would be pulled, disk totals) and exit.

.PARAMETER Prune
    Remove installed models that are not part of the selected tier. Destructive;
    honours -WhatIf and prompts by default.

.EXAMPLE
    ./scripts/Sync-Models.ps1 -Tier recommended -ListOnly

    Shows the plan without downloading anything.

.EXAMPLE
    ./scripts/Sync-Models.ps1 -Tier minimal

    Pulls just the small offline-safe model.

.EXAMPLE
    ./scripts/Sync-Models.ps1 -Tier full -UseMlx

    Pulls everything, preferring MLX builds where available.

.EXAMPLE
    ./scripts/Sync-Models.ps1 -Tag 'gpt-oss:20b'

    Pulls a single model.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Tier')]
param(
    [Parameter(ParameterSetName = 'Tier')]
    [ValidateSet('minimal', 'recommended', 'full')]
    [string]$Tier = 'recommended',

    [Parameter(ParameterSetName = 'Tag', Mandatory)]
    [string[]]$Tag,

    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'models.json'),

    [string]$BaseUrl = 'http://localhost:11434',

    [switch]$UseMlx,

    [switch]$ListOnly,

    [Parameter(ParameterSetName = 'Tier')]
    [switch]$Prune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers: Get-HttpErrorDetail. Dot-sourced before the local helpers below, so
# the script-specific versions win on name overlap.
. "$PSScriptRoot/_common.ps1"

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-InstalledModel {
    <#
        .SYNOPSIS
            Returns the tags currently present in the local Ollama store.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    try {
        $tags = Invoke-RestMethod -Uri "$Uri/api/tags" -TimeoutSec 10 -ErrorAction Stop
    }
    catch {
        throw "Could not reach the Ollama API at $Uri. Is the service running? Try: ./scripts/Start-Ollama.ps1`n  Underlying error: $(Get-HttpErrorDetail -ErrorRecord $_)"
    }

    if (-not $tags.PSObject.Properties.Name.Contains('models') -or $null -eq $tags.models) {
        return @()
    }
    return @($tags.models)
}

function Invoke-OllamaPull {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModelTag)

    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw "The 'ollama' CLI was not found on PATH. Run ./scripts/Install-LocalAgents.ps1 first."
    }

    # The CLI is used rather than the HTTP API so the user sees native download progress.
    & ollama pull $ModelTag
    if ($LASTEXITCODE -ne 0) {
        throw "ollama pull $ModelTag failed with exit code $LASTEXITCODE."
    }
}

# --- Load manifest ------------------------------------------------------------

$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
Write-Step "Reading manifest: $ManifestPath"

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
Write-Host "    Manifest verified $($manifest.verified_date) against $($manifest.verified_against)." -ForegroundColor DarkGray
Write-Host '    Model tags churn quickly - re-verify if this date is stale.' -ForegroundColor DarkGray

$memoryBudgetGb = $manifest.ram_budget.usable_for_weights_gb

# --- Resolve the desired set --------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Tag') {
    $desired = foreach ($t in $Tag) {
        $known = $manifest.models | Where-Object { $_.tag -eq $t -or $_.mlx_tag -eq $t }
        if ($known) {
            [pscustomobject]@{ Tag = $t; SizeGb = $known.size_gb; Purpose = $known.purpose }
        }
        else {
            Write-Warning "Tag '$t' is not in the manifest. Pulling anyway; size is unknown."
            [pscustomobject]@{ Tag = $t; SizeGb = $null; Purpose = 'unknown' }
        }
    }
    $selectionLabel = "explicit tags ($($Tag -join ', '))"
}
else {
    $selected = $manifest.models | Where-Object { $_.tiers -contains $Tier }
    if (-not $selected) {
        throw "No models in the manifest are tagged with tier '$Tier'."
    }

    $desired = foreach ($m in $selected) {
        $useTag = $m.tag
        if ($UseMlx -and $m.mlx_tag) {
            $useTag = $m.mlx_tag
            Write-Host "    Using MLX build for $($m.tag) -> $useTag" -ForegroundColor DarkGray
        }
        [pscustomobject]@{ Tag = $useTag; SizeGb = $m.size_gb; Purpose = $m.purpose }
    }
    $selectionLabel = "tier '$Tier'"
}

$desired = @($desired)

# --- Compare against what is installed ----------------------------------------

Write-Step "Planning sync for $selectionLabel"

$installed = Get-InstalledModel -Uri $BaseUrl
$installedTags = @($installed | ForEach-Object { $_.name })

$plan = foreach ($d in $desired) {
    $present = $installedTags -contains $d.Tag
    [pscustomobject]@{
        Tag     = $d.Tag
        SizeGb  = $d.SizeGb
        Purpose = $d.Purpose
        Status  = if ($present) { 'present' } else { 'pull' }
    }
}
$plan = @($plan)

$plan | Format-Table -AutoSize @{ L = 'Model'; E = { $_.Tag } },
                               @{ L = 'Size(GB)'; E = { if ($null -ne $_.SizeGb) { $_.SizeGb } else { '?' } }; A = 'right' },
                               @{ L = 'Purpose'; E = { $_.Purpose } },
                               @{ L = 'Action'; E = { $_.Status } } | Out-Host

$toPull = @($plan | Where-Object { $_.Status -eq 'pull' })
$pullGb = ($toPull | Where-Object { $null -ne $_.SizeGb } | Measure-Object -Property SizeGb -Sum).Sum
if (-not $pullGb) { $pullGb = 0 }
$totalGb = ($plan | Where-Object { $null -ne $_.SizeGb } | Measure-Object -Property SizeGb -Sum).Sum
if (-not $totalGb) { $totalGb = 0 }

Write-Host "    To download: $($toPull.Count) model(s), roughly ${pullGb}GB." -ForegroundColor White
Write-Host "    Set total on disk when complete: roughly ${totalGb}GB." -ForegroundColor White

$oversized = @($plan | Where-Object { $null -ne $_.SizeGb -and $_.SizeGb -gt $memoryBudgetGb })
foreach ($o in $oversized) {
    Write-Warning "$($o.Tag) is $($o.SizeGb)GB, above the ${memoryBudgetGb}GB weight budget in the manifest. It will swap or fail to load."
}

if ($totalGb -gt $memoryBudgetGb) {
    Write-Host "    Note: the set totals more than the ${memoryBudgetGb}GB RAM budget. That is fine on disk - just do not expect to hold them all resident at once." -ForegroundColor DarkGray
}

if ($ListOnly) {
    Write-Step 'List-only mode; nothing was changed.'
    return
}

# --- Pull ---------------------------------------------------------------------

if ($toPull.Count -eq 0) {
    Write-Step 'Nothing to pull; all requested models are already present.'
}
else {
    Write-Step "Pulling $($toPull.Count) model(s)"
    $index = 0
    foreach ($item in $toPull) {
        $index++
        Write-Host ''
        Write-Host "[$index/$($toPull.Count)] $($item.Tag)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($item.Tag, 'ollama pull')) {
            Invoke-OllamaPull -ModelTag $item.Tag
        }
    }
}

# --- Prune --------------------------------------------------------------------

if ($Prune) {
    Write-Step 'Pruning models outside the selected tier'

    $keep = @($desired | ForEach-Object { $_.Tag })
    $refreshed = Get-InstalledModel -Uri $BaseUrl
    $extra = @($refreshed | Where-Object { $keep -notcontains $_.name })

    if ($extra.Count -eq 0) {
        Write-Host '    Nothing to prune.' -ForegroundColor DarkGray
    }
    foreach ($e in $extra) {
        if ($PSCmdlet.ShouldProcess($e.name, 'ollama rm')) {
            & ollama rm $e.name
            if ($LASTEXITCODE -ne 0) { Write-Warning "ollama rm $($e.name) failed with exit code $LASTEXITCODE." }
        }
    }
}

# --- Verify -------------------------------------------------------------------

Write-Step 'Verifying'

$final = Get-InstalledModel -Uri $BaseUrl
$finalTags = @($final | ForEach-Object { $_.name })
$missing = @($desired | Where-Object { $finalTags -notcontains $_.Tag })

if ($missing.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Warning "Still missing after sync: $(($missing | ForEach-Object { $_.Tag }) -join ', ')"
}
else {
    Write-Host "    All $($desired.Count) model(s) for $selectionLabel are present." -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next: ./scripts/Test-LocalStack.ps1   (health, tokens/sec, tool-calling)' -ForegroundColor White
