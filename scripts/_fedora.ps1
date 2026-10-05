#Requires -Version 7.0
# Internal helpers for Fedora's packaged Ollama; no custom service or configuration.

function Assert-FedoraHost {
    if (-not $IsLinux) { throw 'This operation requires Fedora Linux.' }
    $release = Get-Content -LiteralPath '/etc/os-release' -Raw -ErrorAction Stop
    if ($release -notmatch '(?m)^ID="?fedora"?\r?$' -or
        $release -notmatch '(?m)^VERSION_ID="?(\d+)"?\r?$' -or [int]$Matches[1] -lt 42) {
        throw 'Package/service management supports Fedora 42 or newer. Other Linux hosts can use an externally managed Ollama server.'
    }
}

function Test-FedoraOllamaPackage {
    $PSNativeCommandUseErrorActionPreference = $false
    $null = Get-Command rpm -ErrorAction Stop
    & rpm -q --quiet ollama
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq 1) { return $false }
    throw "rpm could not query ollama (exit code $LASTEXITCODE)."
}

function Invoke-FedoraCommand {
    param([Parameter(Mandatory)][string]$Command, [string[]]$ArgumentList)

    $null = Get-Command $Command -ErrorAction Stop
    $uid = & id -u
    if ($LASTEXITCODE -ne 0 -or "$uid" -notmatch '^\d+$') { throw 'Could not determine the current user ID.' }
    if ("$uid" -eq '0') {
        & $Command @ArgumentList
    }
    else {
        $null = Get-Command sudo -ErrorAction Stop
        & sudo $Command @ArgumentList
    }
    if ($LASTEXITCODE -ne 0) { throw "$Command $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE." }
}

function Invoke-FedoraOllamaService {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'stop', 'restart')][string]$Action,
        [string]$BaseUrl = 'http://localhost:11434',
        [int]$TimeoutSeconds = 60
    )

    Assert-FedoraHost
    $BaseUrl = Resolve-LocalAgentBaseUrl $BaseUrl
    $uri = [uri]$BaseUrl
    if (-not $uri.IsLoopback -or $uri.Scheme -ne 'http') {
        throw 'Service management requires a local HTTP loopback endpoint.'
    }
    if (-not (Test-FedoraOllamaPackage) -and -not $WhatIfPreference) {
        throw 'The Fedora ollama package is not installed. Run Install-LocalAgents.ps1 first.'
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $null = Get-Command systemctl -ErrorAction Stop
    & systemctl is-active --quiet ollama.service
    $active = $LASTEXITCODE -eq 0
    if ($LASTEXITCODE -notin 0, 3, 4) { throw "Cannot read ollama.service state (exit code $LASTEXITCODE)." }
    $version = Get-OllamaVersion -BaseUrl $BaseUrl
    if ($version -and -not $active) {
        throw 'Ollama is answering, but ollama.service is not active. Stop the externally managed server before controlling the Fedora service.'
    }
    if ($Action -eq 'start' -and $active -and $version) {
        Write-Ok "server already up (v$version); existing configuration and boot policy unchanged"
        return
    }
    if (-not $PSCmdlet.ShouldProcess('ollama.service', "systemctl $Action (boot policy unchanged)")) { return }
    Invoke-FedoraCommand -Command systemctl -ArgumentList @($Action, 'ollama.service')
    if ($Action -eq 'stop') {
        if (Get-OllamaVersion -BaseUrl $BaseUrl) { throw "Ollama still answers at $BaseUrl after stopping ollama.service." }
        Write-Ok 'service stopped; boot policy unchanged'
        return
    }
    $version = Wait-OllamaApi -BaseUrl $BaseUrl -TimeoutSeconds $TimeoutSeconds
    if (-not $version) { throw "Ollama did not answer at $BaseUrl. Inspect: sudo journalctl -u ollama.service" }
    & systemctl is-active --quiet ollama.service
    if ($LASTEXITCODE -ne 0) { throw 'The API answered, but ollama.service is not active.' }
    Write-Ok "server up (v$version); existing configuration and boot policy unchanged"
}
