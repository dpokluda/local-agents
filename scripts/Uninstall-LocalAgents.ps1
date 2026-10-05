#Requires -Version 7.0
<#
.SYNOPSIS
    Cleanly reverts the local LLM agent stack installed by Install-LocalAgents.ps1.

.DESCRIPTION
    Destructive by nature, so every step supports -WhatIf and prompts by default.

    On Windows, quit the tray app first; removes Ollama with WinGet. On Fedora 42+,
    stops the packaged service and removes the RPM with DNF. These paths do not request
    model deletion. Windows uses silent uninstall to avoid the vendor's preselected
    model-removal checkbox. Use Remove-LocalModel.ps1 while the server is running to delete
    unwanted models before uninstalling. -RemoveLmStudio is macOS-only.

    macOS steps:
      1. Stop the ollama background service.
      2. Uninstall the ollama formula.
      3. Optionally uninstall the LM Studio cask.
      4. Remove ~/.ollama, which holds all downloaded model weights. This is where the
         disk space actually is - skipping it leaves tens of GB behind.

    Use -KeepModels to uninstall the software but keep the weights, so a later reinstall
    does not have to re-download everything.

.PARAMETER KeepModels
    On macOS, leave ~/.ollama in place. Windows/Fedora do not request model deletion.

.PARAMETER RemoveLmStudio
    Also uninstall the LM Studio cask if present.

.PARAMETER Force
    Suppress confirmation prompts. -WhatIf still wins over -Force.

.EXAMPLE
    ./scripts/Uninstall-LocalAgents.ps1 -WhatIf

    Shows exactly what would be removed, including how much disk ~/.ollama is using.

.EXAMPLE
    ./scripts/Uninstall-LocalAgents.ps1

    Full revert with prompts.

.EXAMPLE
    ./scripts/Uninstall-LocalAgents.ps1 -KeepModels -Force

    Remove the software, keep the weights, no prompts.

.NOTES
    Nothing here touches your $PROFILE - this repo does not ask you to edit it.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$KeepModels,
    [switch]$RemoveLmStudio,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_common.ps1"

if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
}

if (-not $IsMacOS) {
    if ($RemoveLmStudio) { throw '-RemoveLmStudio is macOS-only; manage the native GUI separately.' }
    Write-Detail 'No model deletion is requested on Windows/Fedora, regardless of -KeepModels. Native app settings/logs may be removed.'
    if ($IsWindows) {
        $null = Get-Command winget -ErrorAction Stop
        if ($PSCmdlet.ShouldProcess('Ollama.Ollama', 'winget uninstall --id Ollama.Ollama --exact --silent (no model deletion requested)')) {
            if (Get-OllamaVersion -BaseUrl (Resolve-LocalAgentBaseUrl)) {
                throw 'Quit the Ollama tray app/server before uninstalling. No processes were killed.'
            }
            & winget uninstall --id Ollama.Ollama --exact --silent
            if ($LASTEXITCODE -ne 0) { throw "WinGet uninstall failed with exit code $LASTEXITCODE." }
            Write-Ok 'Ollama uninstalled; no model deletion was requested'
        }
    }
    else {
        . "$PSScriptRoot/_fedora.ps1"
        Assert-FedoraHost
        if (-not (Test-FedoraOllamaPackage)) {
            Write-Detail 'Fedora ollama package is not installed; no changes made.'
            return
        }
        if ($PSCmdlet.ShouldProcess('ollama', 'Stop ollama.service and dnf remove ollama (keep model data)')) {
            Invoke-FedoraOllamaService -Action stop -BaseUrl (Resolve-LocalAgentBaseUrl) -Confirm:$false
            Invoke-FedoraCommand -Command dnf -ArgumentList @('remove', 'ollama')
            if (Test-FedoraOllamaPackage) { throw 'DNF completed, but the ollama package is still installed.' }
            Write-Ok 'Ollama uninstalled; model data was not deleted by this script'
        }
    }
    return
}

$savedEnvironment = Get-SavedOllamaEnvironment
$baseUrl = $LocalAgentDefaults.BaseUrl
if ($savedEnvironment.Contains('OLLAMA_HOST')) { $baseUrl = $savedEnvironment['OLLAMA_HOST'] }

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    --  $Message" -ForegroundColor DarkGray
}

function Test-BrewPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('formula', 'cask')][string]$Kind = 'formula'
    )

    $null = & brew list "--$Kind" --versions $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
    Write-Warning 'Homebrew is not on PATH; the brew steps will be skipped. The ~/.ollama cleanup can still run.'
    $hasBrew = $false
}
else {
    $hasBrew = $true
}

$modelDir = Join-Path $HOME '.ollama'

# --- Show what is at stake ----------------------------------------------------

Write-Step 'Inventory'

if (Test-Path -LiteralPath $modelDir) {
    $sizeOutput = (& du -sh $modelDir 2>$null)
    $sizeText = if ($sizeOutput) { ($sizeOutput -split '\s+')[0] } else { 'unknown size' }
    Write-Host "    $modelDir  ($sizeText)" -ForegroundColor White
}
else {
    Write-Skip "$modelDir does not exist"
}

if ($hasBrew) {
    foreach ($pkg in @(@{ n = 'ollama'; k = 'formula' }, @{ n = 'lm-studio'; k = 'cask' })) {
        if (Test-BrewPackage -Name $pkg.n -Kind $pkg.k) {
            Write-Host "    brew $($pkg.k): $($pkg.n)" -ForegroundColor White
        }
    }
}

# --- 1. Stop the service ------------------------------------------------------

Write-Step 'Stopping the Ollama service'

if (-not $hasBrew) {
    if (Get-OllamaVersion -BaseUrl $baseUrl) { throw 'Ollama is still running. Stop it before uninstalling or deleting its configuration.' }
    Write-Skip 'no brew; skipping'
}
elseif ($PSCmdlet.ShouldProcess('ollama', 'brew services stop')) {
    Stop-OllamaService -BaseUrl $baseUrl -Confirm:$false
}
elseif (-not $WhatIfPreference) {
    Write-Warning 'Service stop was declined; uninstall was cancelled.'
    return
}

# --- 2. Uninstall the formula -------------------------------------------------

Write-Step 'Uninstalling the ollama formula'

if (-not $hasBrew) {
    Write-Skip 'no brew; skipping'
}
elseif (-not (Test-BrewPackage -Name 'ollama' -Kind 'formula')) {
    Write-Skip 'ollama formula is not installed'
}
elseif ($PSCmdlet.ShouldProcess('ollama', 'brew uninstall')) {
    & brew uninstall ollama
    if ($LASTEXITCODE -ne 0) { throw "brew uninstall ollama returned exit code $LASTEXITCODE." }
    else { Write-Host '    OK  formula removed' -ForegroundColor Green }
}

# --- 3. Optional GUI ----------------------------------------------------------

if ($RemoveLmStudio) {
    Write-Step 'Uninstalling LM Studio'

    if (-not $hasBrew) {
        Write-Skip 'no brew; skipping'
    }
    elseif (-not (Test-BrewPackage -Name 'lm-studio' -Kind 'cask')) {
        Write-Skip 'lm-studio is not installed'
    }
    elseif ($PSCmdlet.ShouldProcess('lm-studio', 'brew uninstall --cask')) {
        & brew uninstall --cask lm-studio
        if ($LASTEXITCODE -ne 0) { throw "brew uninstall --cask lm-studio returned exit code $LASTEXITCODE." }
        else { Write-Host '    OK  cask removed' -ForegroundColor Green }
    }
}

# --- 4. Model weights ---------------------------------------------------------

Write-Step 'Removing downloaded model weights'

if ($KeepModels) {
    Write-Skip "-KeepModels specified; leaving $modelDir in place"
}
elseif (-not (Test-Path -LiteralPath $modelDir)) {
    Write-Skip "$modelDir does not exist"
}
elseif ($PSCmdlet.ShouldProcess($modelDir, 'Remove directory and all downloaded model weights')) {
    Remove-Item -LiteralPath $modelDir -Recurse -Force
    Write-Host "    OK  $modelDir removed" -ForegroundColor Green
}

# --- Done ---------------------------------------------------------------------

$serviceFile = Get-OllamaServiceFile
if ((Test-Path -LiteralPath $serviceFile) -and $PSCmdlet.ShouldProcess($serviceFile, 'Remove saved service configuration')) {
    Remove-Item -LiteralPath $serviceFile -Force
}
if ($savedEnvironment.Contains('OLLAMA_MODELS')) {
    Write-Host "Custom model storage was not deleted: $($savedEnvironment['OLLAMA_MODELS'])" -ForegroundColor Yellow
}

Write-Host ''
Write-Step 'Revert complete.'
Write-Host '  Nothing was added to your $PROFILE, so there is nothing to clean up there.' -ForegroundColor DarkGray
Write-Host '  Delete the repo directory itself if you are done with it.' -ForegroundColor DarkGray
Write-Host ''
