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
    MLX builds require a compatible Ollama runtime; benchmark rather than assuming speed.

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

    [string]$BaseUrl,

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
$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

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

    # The CLI is used rather than the HTTP API so the user sees native download progress.
    Invoke-OllamaCli -BaseUrl $BaseUrl -ArgumentList @('pull', $ModelTag)
}

function Remove-SyncModel {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$ModelTag)

    if ($PSCmdlet.ShouldProcess("$ModelTag at $BaseUrl", 'Delete model outside selected tier')) {
        Invoke-OllamaCli -BaseUrl $BaseUrl -ArgumentList @('rm', $ModelTag)
        if (@(Get-InstalledModel -Uri $BaseUrl | Where-Object { $_.name -ceq $ModelTag }).Count -gt 0) {
            throw "Ollama reported deletion success but '$ModelTag' is still installed at $BaseUrl."
        }
    }
}

# --- Load manifest ------------------------------------------------------------

$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
Write-Step "Reading manifest: $ManifestPath"

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
Write-Host "    Manifest reference date: $($manifest.verified_date) ($($manifest.verified_against))." -ForegroundColor DarkGray
Write-Host '    Sizes are planning estimates, not pinned artifacts. Installed bytes may differ.' -ForegroundColor DarkGray

$memoryBudgetGb = if (Test-LocalMacEndpoint $BaseUrl) { $manifest.ram_budget.usable_for_weights_gb } else { $null }

# --- Resolve the desired set --------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Tag') {
    $desired = foreach ($inputTag in $Tag) {
        $t = Resolve-OllamaModelTag -Tag $inputTag
        $known = $manifest.models | Where-Object { $_.tag -ceq $t -or $_.mlx_tag -ceq $t }
        if ($known) {
            $size = $known.size_gb
            if ($known.mlx_tag -ceq $t) {
                $size = if ($known.PSObject.Properties['mlx_size_gb']) { $known.mlx_size_gb } else { $null }
            }
            [pscustomobject]@{ Tag = $t; SizeGb = $size; Purpose = $known.purpose }
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
        $size = $m.size_gb
        if ($UseMlx -and $m.mlx_tag) {
            $useTag = $m.mlx_tag
            $size = if ($m.PSObject.Properties['mlx_size_gb']) { $m.mlx_size_gb } else { $null }
            Write-Host "    Using MLX build for $($m.tag) -> $useTag" -ForegroundColor DarkGray
        }
        [pscustomobject]@{ Tag = $useTag; SizeGb = $size; Purpose = $m.purpose }
    }
    $selectionLabel = "tier '$Tier'"
}

$desired = @($desired | Sort-Object Tag -Unique -CaseSensitive)

# --- Compare against what is installed ----------------------------------------

Write-Step "Planning sync for $selectionLabel"

$installed = @(Get-InstalledModel -Uri $BaseUrl)
$installedTags = @($installed | ForEach-Object { $_.name })

$plan = foreach ($d in $desired) {
    $present = $installedTags -ccontains $d.Tag
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
$pullGb = 0.0
$totalGb = 0.0
foreach ($item in $plan) {
    if ($null -ne $item.SizeGb) {
        $totalGb += $item.SizeGb
        if ($item.Status -eq 'pull') { $pullGb += $item.SizeGb }
    }
}
if (@($plan | Where-Object { $null -eq $_.SizeGb }).Count -gt 0) {
    Write-Warning 'Totals exclude models whose download size is unknown.'
}

Write-Host "    To download: $($toPull.Count) model(s), roughly ${pullGb}GB." -ForegroundColor White
Write-Host "    Set total on disk when complete: roughly ${totalGb}GB." -ForegroundColor White

$oversized = @($plan | Where-Object { $null -ne $memoryBudgetGb -and $null -ne $_.SizeGb -and ($_.SizeGb * 1e9) -gt ($memoryBudgetGb * 1GB) })
foreach ($o in $oversized) {
    Write-Warning "$($o.Tag) is estimated at $($o.SizeGb)GB, above the manifest's ${memoryBudgetGb}GiB planning budget. It may fail to load or run slowly."
}

if ($null -eq $memoryBudgetGb) {
    Write-Host '    The manifest memory budget is Mac-specific; memory fit on this target is not evaluated.' -ForegroundColor DarkGray
}
elseif (($totalGb * 1e9) -gt ($memoryBudgetGb * 1GB)) {
    Write-Host "    Note: the set totals more than the ${memoryBudgetGb}GiB RAM budget. That is fine on disk - just do not expect to hold them all resident at once." -ForegroundColor DarkGray
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
        if ($PSCmdlet.ShouldProcess("$($item.Tag) at $BaseUrl", 'ollama pull')) {
            Invoke-OllamaPull -ModelTag $item.Tag
        }
    }
}

if ($WhatIfPreference) {
    Write-Step 'Preview complete; no models were downloaded or deleted.'
    if ($Prune) {
        $keep = @($desired.Tag)
        foreach ($extraModel in @($installed | Where-Object { $keep -cnotcontains $_.name })) {
            Remove-SyncModel -ModelTag $extraModel.name -WhatIf
        }
    }
    return
}

# Do not prune a working fallback set if the requested replacement is incomplete.
$final = @(Get-InstalledModel -Uri $BaseUrl)
$finalTags = @($final | ForEach-Object { $_.name })
$missing = @($desired | Where-Object { $finalTags -cnotcontains $_.Tag })
if ($missing.Count -gt 0) {
    throw "Still missing after sync: $(($missing | ForEach-Object { $_.Tag }) -join ', '). Pruning was not attempted."
}

# --- Prune --------------------------------------------------------------------

if ($Prune) {
    Write-Step 'Pruning models outside the selected tier'

    $keep = @($desired | ForEach-Object { $_.Tag })
    $extra = @($final | Where-Object { $keep -cnotcontains $_.name })

    if ($extra.Count -eq 0) {
        Write-Host '    Nothing to prune.' -ForegroundColor DarkGray
    }
    foreach ($e in $extra) {
        $confirmation = @{}
        if ($PSBoundParameters.ContainsKey('Confirm')) { $confirmation.Confirm = $PSBoundParameters['Confirm'] }
        Remove-SyncModel -ModelTag $e.name @confirmation
    }
}

# --- Verify -------------------------------------------------------------------

Write-Step 'Verifying'

$final = @(Get-InstalledModel -Uri $BaseUrl)
$finalTags = @($final | ForEach-Object { $_.name })
$missing = @($desired | Where-Object { $finalTags -cnotcontains $_.Tag })

if ($missing.Count -gt 0) {
    throw "Still missing after sync: $(($missing | ForEach-Object { $_.Tag }) -join ', ')"
}
else {
    Write-Host "    All $($desired.Count) model(s) for $selectionLabel are present." -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next: ./scripts/Test-LocalStack.ps1   (health, tokens/sec, tool-calling)' -ForegroundColor White
