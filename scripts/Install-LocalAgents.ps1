#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Ollama using Homebrew on macOS, WinGet on Windows, or DNF on Fedora.

.DESCRIPTION
    Idempotent installer. Safe to re-run: every step checks current state before acting.

    Steps:
      1. Validate the host is macOS on Apple Silicon.
      2. Validate Homebrew is present (this script does NOT install Homebrew itself).
      3. Install the 'ollama' formula if missing.
      4. Start the 'ollama' background service if not already running.
         By default this uses `brew services run`, which starts the server now without
         registering it to launch at every login. Pass -AtLogin for the always-on variant.
      5. Poll the API until it answers, then report the version.
      6. Optionally install the LM Studio GUI cask (useful for its MLX backend).

    This script deliberately does NOT pull any models. Run Sync-Models.ps1 for that.

    On Windows, use the standard Ollama app; this script does not create a service or
    manage the tray app. On Fedora 42+, start the packaged systemd service without
    changing its boot policy or tuning. Mac-specific options are rejected on other hosts.

.PARAMETER InstallLmStudio
    macOS only. Also install the LM Studio desktop app (cask). Optional GUI front end with an
    Apple-Silicon-native MLX backend. Not required for any script in this repo.

.PARAMETER SkipService
    Do not start the Mac/Fedora service. On Windows, skip the API status check; the
    vendor installer may still launch its own app. No server is launched by this script.

.PARAMETER AtLogin
    macOS only.
    Start the service with 'brew services start' instead of 'brew services run', which
    also registers a launchd login item so Ollama comes back after every reboot. The
    default is deliberately on-demand: an idle server costs little, but it is still a
    background process you did not ask for, and a model left resident is not.

.PARAMETER NoEnvironment
    macOS only.
    Do not rewrite the saved service configuration. Reuse it if present; otherwise use
    Homebrew's defaults. Mainly useful if you manage the environment yourself.

.PARAMETER TimeoutSeconds
    How long to wait for the API to become reachable after starting the service.

.EXAMPLE
    ./scripts/Install-LocalAgents.ps1 -WhatIf

    Shows what would be installed and started without touching the system.

.EXAMPLE
    ./scripts/Install-LocalAgents.ps1

    Installs Ollama, starts the service, waits for the API.

.EXAMPLE
    ./scripts/Install-LocalAgents.ps1 -InstallLmStudio

    Same, plus the LM Studio GUI.

.EXAMPLE
    ./scripts/Install-LocalAgents.ps1 -AtLogin

    Same, but also registers Ollama to start automatically at every login.

.NOTES
    Reverse with ./scripts/Uninstall-LocalAgents.ps1. See docs/windows-fedora.md for the
    native app/service workflow and preserved model data on Windows/Fedora.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$InstallLmStudio,
    [switch]$SkipService,
    [switch]$AtLogin,
    [switch]$NoEnvironment,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared defaults. Dot-sourced first so the install-specific
# helpers defined below take precedence where the names overlap.
. "$PSScriptRoot/_common.ps1"

$script:OllamaBaseUrl = 'http://localhost:11434'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    OK  $Message" -ForegroundColor Green
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    --  $Message (already done)" -ForegroundColor DarkGray
}

function Test-BrewFormula {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $null = & brew list --formula --versions $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-BrewCask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $null = & brew list --cask --versions $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

# --- 1. Host validation -------------------------------------------------------

Write-Step 'Validating host'

if (-not $IsMacOS) {
    if ($InstallLmStudio -or $AtLogin -or $NoEnvironment) {
        throw '-InstallLmStudio, -AtLogin, and -NoEnvironment are macOS-only options. See docs/windows-fedora.md.'
    }
    if ($IsWindows) {
        if (Resolve-OllamaCommand) {
            Write-Skip 'Ollama CLI already available; leaving the existing installation alone'
        }
        else {
            $null = Get-Command winget -ErrorAction Stop
            if ($PSCmdlet.ShouldProcess('Ollama.Ollama', 'winget install --id Ollama.Ollama --exact --source winget')) {
                & winget install --id Ollama.Ollama --exact --source winget
                if ($LASTEXITCODE -ne 0) { throw "WinGet installation failed with exit code $LASTEXITCODE." }
                if (-not (Resolve-OllamaCommand)) {
                    throw 'WinGet completed, but the Ollama CLI was not found. Reopen PowerShell to refresh PATH, then rerun this script.'
                }
                Write-Ok 'Ollama installed'
            }
            elseif (-not $WhatIfPreference) { return }
        }
        if (-not $SkipService -and -not $WhatIfPreference) {
            $version = Get-OllamaVersion -BaseUrl $script:OllamaBaseUrl
            if ($version) { Write-Ok "server up (v$version)" }
            else { Write-Warning 'Server readiness is not verified. Open Ollama from the Start menu, then run Test-LocalStack.ps1 after syncing models.' }
        }
        Write-Detail 'Start/restart/quit using the native Ollama app. Its installer owns startup behavior; no repo-managed service or tuning was created.'
    }
    elseif ($IsLinux) {
        . "$PSScriptRoot/_fedora.ps1"
        Assert-FedoraHost
        if (Test-FedoraOllamaPackage) {
            Write-Skip 'Fedora ollama package installed'
        }
        elseif (Resolve-OllamaCommand) {
            throw 'An Ollama CLI exists outside the Fedora ollama package. Keep using that installation or remove it manually before installing the RPM.'
        }
        elseif ($PSCmdlet.ShouldProcess('ollama', 'dnf install ollama (sudo when needed)')) {
            Invoke-FedoraCommand -Command dnf -ArgumentList @('install', 'ollama')
            if (-not (Test-FedoraOllamaPackage)) { throw 'DNF completed, but the ollama package is not installed.' }
            Write-Ok 'Ollama installed'
        }
        elseif (-not $WhatIfPreference) { return }
        if (-not $SkipService) {
            & "$PSScriptRoot/Start-Ollama.ps1" -TimeoutSeconds $TimeoutSeconds -BaseUrl $script:OllamaBaseUrl
        }
    }
    else { throw 'Supported installation hosts are macOS, Windows, and Fedora 42+.' }

    Write-Host ''
    Write-Step 'Next steps (after the native server is running):'
    Write-Detail './scripts/Sync-Models.ps1 -Tier minimal'
    Write-Detail "./scripts/Test-LocalStack.ps1 -Model 'gemma4:e4b'"
    Write-Detail "After checks pass: ./scripts/Start-LocalCopilot.ps1 -Model 'gemma4:e4b'"
    Write-Detail 'The shared model catalog and Mac default are unchanged. See docs/windows-fedora.md.'
    return
}

$arch = (& uname -m).Trim()
if ($arch -ne 'arm64') {
    Write-Warning "Detected architecture '$arch'. These scripts are tuned for Apple Silicon (arm64); Intel Macs have no GPU acceleration path for Ollama and will be very slow."
}
else {
    Write-Ok "macOS on Apple Silicon ($arch)"
}

$totalMemoryBytes = [int64](& sysctl -n hw.memsize)
$totalMemoryGb = [math]::Round($totalMemoryBytes / 1GB, 0)
Write-Ok "Unified memory: ${totalMemoryGb}GB (budget roughly $([math]::Max(0, $totalMemoryGb - 14))GB for model weights)"

# --- 2. Homebrew --------------------------------------------------------------

Write-Step 'Checking Homebrew'

$brew = Get-Command brew -ErrorAction SilentlyContinue
if (-not $brew) {
    throw @'
Homebrew was not found on PATH.

Install it first (this script will not do it for you):
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

Then make sure /opt/homebrew/bin is on your PATH and re-run this script.
'@
}
Write-Ok "brew found at $($brew.Source)"

# --- 3. Ollama formula --------------------------------------------------------

Write-Step 'Installing Ollama'

if (Test-BrewFormula -Name 'ollama') {
    Write-Skip 'ollama formula installed'
}
elseif ($PSCmdlet.ShouldProcess('ollama', 'brew install')) {
    & brew install ollama
    if ($LASTEXITCODE -ne 0) { throw "brew install ollama failed with exit code $LASTEXITCODE." }
    Write-Ok 'ollama installed'
}

# --- 4. Background service ----------------------------------------------------

if ($SkipService) {
    Write-Step 'Skipping service start (-SkipService)'
    Write-Host '    Run the server manually when you need it:' -ForegroundColor DarkGray
    Write-Host '        ollama serve' -ForegroundColor DarkGray
}
else {
    & "$PSScriptRoot/Start-Ollama.ps1" -AtLogin:$AtLogin -NoEnvironment:$NoEnvironment `
        -TimeoutSeconds $TimeoutSeconds -BaseUrl $script:OllamaBaseUrl
}

# --- 5. Optional GUI ----------------------------------------------------------

if ($InstallLmStudio) {
    Write-Step 'Installing LM Studio (optional GUI)'

    if (Test-BrewCask -Name 'lm-studio') {
        Write-Skip 'lm-studio cask installed'
    }
    elseif ($PSCmdlet.ShouldProcess('lm-studio', 'brew install --cask')) {
        & brew install --cask lm-studio
        if ($LASTEXITCODE -ne 0) { throw "brew install --cask lm-studio failed with exit code $LASTEXITCODE." }
        Write-Ok 'lm-studio installed'
    }
}

# --- 6. Next steps ------------------------------------------------------------

Write-Host ''
Write-Step 'Done. Next steps:'
Write-Host ''
Write-Host '  1. Pull models:' -ForegroundColor White
Write-Host '       ./scripts/Sync-Models.ps1 -Tier recommended' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  2. Verify the stack (tool-calling, and the knobs the server really has):' -ForegroundColor White
Write-Host '       ./scripts/Test-LocalStack.ps1' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Service control (no profile or dot-sourcing needed):' -ForegroundColor White
Write-Host '       ./scripts/Start-Ollama.ps1    ./scripts/Stop-Ollama.ps1' -ForegroundColor DarkGray
Write-Host '       ./scripts/Get-OllamaStatus.ps1' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  OpenAI-compatible endpoint for agent tools: $script:OllamaBaseUrl/v1" -ForegroundColor White
Write-Host ''
