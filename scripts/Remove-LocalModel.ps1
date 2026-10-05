#Requires -Version 7.0
<#
.SYNOPSIS
    Deletes downloaded model weights from disk and reports the space actually reclaimed.

.DESCRIPTION
    Unloads the model if it is resident, then deletes it through the API
    (DELETE /api/delete), so this works whether or not the `ollama` CLI is on PATH.

    Disk space is measured, not estimated: the models directory is sized with `du`
    before and after each delete. That matters because Ollama stores weights as
    content-addressed blobs shared between tags. A tag listed at 17GB may free far less
    if another installed tag shares its base layers - and occasionally frees nothing at
    all. The listed size is an upper bound, never a promise.

    This is destructive and prompts by default. Re-downloading means pulling the weights
    again, which is the slow part.

.PARAMETER Model
    One or more tags to remove. Accepts wildcards, which are matched against the
    installed list, and accepts pipeline input.

.PARAMETER Force
    Skip the confirmation prompt. Equivalent to -Confirm:$false.

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.EXAMPLE
    ./scripts/Remove-LocalModel.ps1 gemma4:e4b -WhatIf

    Shows what would be removed, and how much disk it is currently using, without
    deleting anything.

.EXAMPLE
    ./scripts/Remove-LocalModel.ps1 qwen3-coder:30b, gpt-oss:20b

    Prompts for each, then removes both and reports the total reclaimed.

.EXAMPLE
    ./scripts/Get-LocalModel.ps1 | Where-Object { $_.Model -like 'gemma*' } |
        ./scripts/Remove-LocalModel.ps1 -Force

    Pipeline input, no prompting.

.EXAMPLE
    ./scripts/Remove-LocalModel.ps1 'llama*' -Force

    Wildcard match against installed tags.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('Name', 'Tag')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Model,

    [switch]$Force,

    [string]$BaseUrl
)

begin {
    Set-StrictMode -Version Latest

    . "$PSScriptRoot/_common.ps1"

    $BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

    # -Force means "don't ask". An explicit -Confirm still wins, so that
    # -Force -Confirm behaves the way a reader would expect.
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    $script:Ready = Test-OllamaReachable -BaseUrl $BaseUrl
    if ($script:Ready) {
        $script:ModelsPath = Get-OllamaModelsPath
        $script:StartBytes = Get-DirectorySizeBytes -Path $script:ModelsPath
        Write-Host "Models directory: $script:ModelsPath  ($(Format-ByteSize -Bytes $script:StartBytes))" -ForegroundColor DarkGray
        Write-Host ''
    }

    # Tags declared in models.json, so we can warn when a later sync would undo this.
    $script:ManifestTags = @()
    $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'models.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $script:ManifestTags = @($manifest.models | ForEach-Object { $_.tag })
        }
        catch {
            Write-Verbose "Could not read $manifestPath : $($_.Exception.Message)"
        }
    }

    $script:Removed = @()
    $script:ReclaimedTotal = 0L
    $script:SyncWarn = @()
}

process {
    if (-not $script:Ready) { return }

    foreach ($pattern in $Model) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

        $installed = Get-InstalledOllamaModel -BaseUrl $BaseUrl
        if ($null -eq $installed) {
            Write-Warning "Could not list installed models from $BaseUrl; skipping '$pattern'."
            continue
        }

        $installedTags = @($installed | ForEach-Object { $_.name })

        # Treat the argument as a wildcard only if it looks like one. An exact tag such
        # as 'gemma4:e4b' contains no wildcard characters and is matched literally.
        if ($pattern -match '[*?\[]') {
            $matched = @($installedTags | Where-Object { $_ -like $pattern })
            if ($matched.Count -eq 0) {
                Write-Host "  no installed model matches '$pattern'" -ForegroundColor Yellow
                continue
            }
        }
        else {
            $matched = @($installedTags | Where-Object { $_ -eq $pattern })
            if ($matched.Count -eq 0) {
                # A bare name like 'gemma4' is a common slip; point at the real tag.
                $near = @($installedTags | Where-Object { $_ -like "$pattern*" -or $_ -like "*$pattern*" })
                if ($near.Count -gt 0) {
                    Write-Host "  '$pattern' is not installed. Did you mean: $($near -join ', ')?" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  '$pattern' is not installed - nothing to remove." -ForegroundColor Yellow
                }
                continue
            }
        }

        foreach ($tag in $matched) {
            if ($script:Removed -contains $tag) { continue }

            $listed = @($installed | Where-Object { $_.name -eq $tag })
            $listedBytes = if ($listed.Count -gt 0 -and $listed[0].PSObject.Properties['size']) {
                [long]$listed[0].size
            }
            else { $null }

            $describe = "delete model weights (listed size $(Format-ByteSize -Bytes $listedBytes))"
            if (-not $PSCmdlet.ShouldProcess($tag, $describe)) { continue }

            if ((Get-ResidentOllamaModel -BaseUrl $BaseUrl) -contains $tag) {
                Write-Host "  unloading $tag from memory first..." -ForegroundColor DarkGray
                $null = Invoke-OllamaUnload -BaseUrl $BaseUrl -ModelTag $tag
            }

            $before = Get-DirectorySizeBytes -Path $script:ModelsPath

            $body = @{ model = $tag } | ConvertTo-Json
            try {
                $null = Invoke-RestMethod -Uri "$BaseUrl/api/delete" -Method Delete -Body $body `
                    -ContentType 'application/json' -TimeoutSec 60 -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove '$tag': $(Get-HttpErrorDetail -ErrorRecord $_)"
                continue
            }

            $after = Get-DirectorySizeBytes -Path $script:ModelsPath
            $freed = if ($null -ne $before -and $null -ne $after) { [long]($before - $after) } else { $null }

            if ($null -eq $freed) {
                Write-Host "  removed $tag  (could not measure $script:ModelsPath)" -ForegroundColor Green
            }
            else {
                $script:ReclaimedTotal += $freed
                $note = ''
                # Shared blobs are the usual reason measured < listed.
                if ($freed -le 0) {
                    $note = '  (no disk freed - every layer is shared with other installed tags)'
                }
                elseif ($null -ne $listedBytes -and $freed -lt ($listedBytes * 0.9)) {
                    $note = "  (listed $(Format-ByteSize -Bytes $listedBytes); the rest is blobs shared with other tags)"
                }
                Write-Host "  removed $tag  freed $(Format-ByteSize -Bytes $freed)$note" -ForegroundColor Green
            }

            $script:Removed += $tag
            if ($script:ManifestTags -contains $tag) { $script:SyncWarn += $tag }
        }
    }
}

end {
    if (-not $script:Ready) { return }

    Write-Host ''

    if ($script:Removed.Count -eq 0) {
        Write-Host 'Nothing was removed.' -ForegroundColor DarkGray
        return
    }

    $endBytes = Get-DirectorySizeBytes -Path $script:ModelsPath
    Write-Host "Removed $($script:Removed.Count) model(s): $($script:Removed -join ', ')" -ForegroundColor White
    Write-Host "Reclaimed: $(Format-ByteSize -Bytes $script:ReclaimedTotal)" -ForegroundColor Green
    if ($null -ne $script:StartBytes -and $null -ne $endBytes) {
        Write-Host "Models directory: $(Format-ByteSize -Bytes $script:StartBytes) -> $(Format-ByteSize -Bytes $endBytes)" -ForegroundColor DarkGray
    }

    if ($script:SyncWarn.Count -gt 0) {
        Write-Host ''
        Write-Host "  Note: $($script:SyncWarn -join ', ') $(if ($script:SyncWarn.Count -eq 1) { 'is' } else { 'are' }) declared in models.json." -ForegroundColor Yellow
        Write-Host '  A later ./scripts/Sync-Models.ps1 run for a tier containing it will download it again.' -ForegroundColor Yellow
    }
}
