#Requires -Version 7.0
<#
    _common.ps1 - internal helper, not meant to be run directly.

    Every user-facing script in this folder dot-sources this via $PSScriptRoot, so the
    scripts work from any working directory:

        . "$PSScriptRoot/_common.ps1"

    It holds the single source of truth for default settings plus the small amount of
    logic that would otherwise be copy-pasted across scripts (output formatting, base-URL
    resolution, the reachability check, launchd knob registration, service control).

    If you change a default, change it HERE. Nowhere else should hard-code these values.
#>

Set-StrictMode -Version Latest

# --- Defaults -----------------------------------------------------------------

$LocalAgentDefaults = [ordered]@{
    # Ollama's native API root. The OpenAI-compatible shim is this plus /v1.
    BaseUrl        = 'http://localhost:11434'

    # Model used by Invoke-LocalChat.ps1 and Start-LocalCopilot.ps1 when none is given.
    Model          = 'qwen3-coder:30b'

    # How long weights stay resident after the last request. '-1' means "until the server
    # stops or the model is unloaded explicitly". The lifecycle here is deliberate -
    # Start-Ollama.ps1 means "I am using this" - so a coffee break should not cost a
    # cold reload. Use a duration ('1h', '10m') to get time-based unloading back.
    KeepAlive      = '-1'

    # Cap on models resident at once. With an infinite keep-alive, nothing evicts a model
    # on a timer, so without this cap they accumulate: qwen3-coder:30b (19GB) plus
    # gpt-oss:20b (14GB) is ~33GB, which fits under Metal's working-set limit, so Ollama
    # keeps both and leaves macOS ~15GB. With a cap of 1, loading a model swaps out the
    # previous one.
    MaxLoadedModels = 1

    # Quantized KV cache. Roughly halves KV RAM at long context for negligible quality
    # cost - this is what lets a 19GB model survive a 60k-token agent loop on 48GB.
    KvCacheType    = 'q8_0'

    # Faster attention kernel. The win grows with context length.
    FlashAttention = $true

    # Ollama's default num_ctx is far below what models support, but a bigger window
    # costs KV cache RAM, so this is opt-in rather than defaulted. 65536 is the practical
    # floor for agent harnesses on a 48GB machine.
    ContextLength  = 0
}

# --- Output -------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    OK  $Message" -ForegroundColor Green
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

# --- Connection ---------------------------------------------------------------

function Resolve-LocalAgentBaseUrl {
    <#
        .SYNOPSIS
            Returns the Ollama base URL to use, with no trailing slash and no /v1 suffix.

        .DESCRIPTION
            Precedence: explicit -BaseUrl argument, then $env:OLLAMA_HOST, then the
            default above. The /v1 suffix is stripped because callers here want the
            native API; Start-LocalCopilot.ps1 re-adds it for the OpenAI shim.
    #>
    param([string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $env:OLLAMA_HOST }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $LocalAgentDefaults.BaseUrl }

    return ($BaseUrl.TrimEnd('/') -replace '/v1$', '')
}

function Get-OllamaVersion {
    <#
        .SYNOPSIS
            Returns the server version string, or $null if the API does not answer.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSec = 3
    )

    try {
        return (Invoke-RestMethod -Uri "$BaseUrl/api/version" -TimeoutSec $TimeoutSec -ErrorAction Stop).version
    }
    catch {
        return $null
    }
}

function Test-OllamaReachable {
    <#
        .SYNOPSIS
            Returns $true if the server answers; otherwise prints how to fix it and
            returns $false.

        .DESCRIPTION
            Used by the read-only scripts so an unreachable server produces one clear
            line instead of a wall of exception text.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSec = 3
    )

    if (Get-OllamaVersion -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec) { return $true }

    Write-Host "Ollama is not reachable at $BaseUrl" -ForegroundColor Red
    Write-Host '  Start it with: ./scripts/Start-Ollama.ps1' -ForegroundColor Yellow
    return $false
}

# --- Service environment ------------------------------------------------------

function Get-OllamaServerPid {
    <#
        .SYNOPSIS
            PID of the running Ollama server, or $null.

        .DESCRIPTION
            Prefers `brew services info`, which knows about the service it manages, and
            falls back to pgrep for a server started some other way (ollama serve, the
            desktop app).
    #>
    [CmdletBinding()]
    param()

    if (Get-Command brew -CommandType Application -ErrorAction SilentlyContinue) {
        try {
            $json = & brew services info ollama --json 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) {
                $info = $json | ConvertFrom-Json
                if ($info -is [array]) { $info = $info[0] }
                $servicePid = $info.PSObject.Properties['pid']
                if ($servicePid -and $servicePid.Value) { return [int]$servicePid.Value }
            }
        }
        catch {
            # brew is noisy in odd states; pgrep below is the fallback.
        }
    }

    $found = & pgrep -f 'ollama serve' 2>$null
    if ($LASTEXITCODE -eq 0 -and $found) {
        return [int](@($found)[0])
    }
    return $null
}

function Get-OllamaServerEnvironment {
    <#
        .SYNOPSIS
            The OLLAMA_* environment the *server process* actually sees.

        .DESCRIPTION
            This is the only reading that means anything. The server runs under launchd,
            so $env:OLLAMA_* in your shell describes your shell and nothing else, and
            even `launchctl getenv` only describes what was injected into the launchd
            session - a plist's own EnvironmentVariables block does not appear there.

            `ps eww` prints the process's real environment, so that is the primary
            source. launchctl getenv is the fallback when the process cannot be read.

            Returns a hashtable of OLLAMA_* values plus a Source label.
    #>
    [CmdletBinding()]
    param()

    $result = @{ Source = 'none'; Values = [ordered]@{}; ProcessId = $null }

    $serverPid = Get-OllamaServerPid
    if ($serverPid) {
        $result.ProcessId = $serverPid
        $raw = & ps eww -p $serverPid 2>$null | Out-String
        if ($raw) {
            # ps prints "KEY=VALUE KEY=VALUE ..." after the command. Values here never
            # contain spaces, so stop each match at the next KEY= or end of line.
            $matched = [regex]::Matches($raw, '(?m)\b(OLLAMA_[A-Z0-9_]+)=(\S*)')
            foreach ($m in $matched) {
                $result.Values[$m.Groups[1].Value] = $m.Groups[2].Value
            }
            if ($result.Values.Count -gt 0) {
                $result.Source = "server process (pid $serverPid)"
                return $result
            }
            # A running server with no OLLAMA_* set is a real answer, not a failure.
            $result.Source = "server process (pid $serverPid)"
            return $result
        }
    }

    if (Get-Command launchctl -CommandType Application -ErrorAction SilentlyContinue) {
        foreach ($name in 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_KEEP_ALIVE',
            'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_CONTEXT_LENGTH', 'OLLAMA_MODELS') {
            $value = & launchctl getenv $name 2>$null
            if (-not [string]::IsNullOrWhiteSpace($value)) { $result.Values[$name] = $value.Trim() }
        }
        if ($result.Values.Count -gt 0) {
            $result.Source = 'launchctl getenv (server process not readable)'
        }
    }

    return $result
}

function Get-HttpErrorDetail {
    <#
        .SYNOPSIS
            The useful part of a failed Invoke-RestMethod, not just the status code.

        .DESCRIPTION
            PowerShell surfaces "400 (Bad Request)" and hides the response body, which is
            where every server actually explains itself. Ollama puts a JSON {"error":...}
            there - e.g. "json: cannot unmarshal object into Go struct field .tools of
            type api.Tools", which is the difference between a five-minute fix and an
            afternoon.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $status = $null
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $code = $response.Value.PSObject.Properties['StatusCode']
        if ($code -and $code.Value) { $status = [string]$code.Value }
    }

    $body = $null
    $details = $ErrorRecord.PSObject.Properties['ErrorDetails']
    if ($details -and $details.Value -and $details.Value.Message) {
        $body = [string]$details.Value.Message
    }

    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            $errField = $parsed.PSObject.Properties['error']
            if ($errField -and $errField.Value) {
                # Some servers nest it as {"error":{"message":...}}
                $inner = $errField.Value
                if ($inner -isnot [string]) {
                    $msg = $inner.PSObject.Properties['message']
                    $inner = if ($msg -and $msg.Value) { $msg.Value } else { $inner | ConvertTo-Json -Compress -Depth 5 }
                }
                $body = [string]$inner
            }
        }
        catch {
            # Not JSON - use the raw body as-is.
        }
        $body = ($body -replace '\s+', ' ').Trim()
        if ($body.Length -gt 300) { $body = $body.Substring(0, 300) + '...' }
    }

    if ($status -and $body) { return "HTTP $status - $body" }
    if ($body) { return $body }
    if ($status) { return "HTTP $status" }
    return ($ErrorRecord.Exception.Message -replace '\s+', ' ').Trim()
}

# --- Model storage ------------------------------------------------------------

function Get-OllamaModelsPath {
    <#
        .SYNOPSIS
            Directory holding the downloaded weights.

        .DESCRIPTION
            Defaults to ~/.ollama/models, which contains manifests/ (small JSON pointers)
            and blobs/ (the actual weights, content-addressed). Because blobs are shared
            by digest, two tags built on the same base layers cost less than the sum of
            their listed sizes.

            OLLAMA_MODELS overrides the location. It has to be read from the *server*
            process, not this shell - the server is what decides where files land.
    #>
    [CmdletBinding()]
    param()

    $serverEnv = Get-OllamaServerEnvironment
    if ($serverEnv.Values.Contains('OLLAMA_MODELS')) {
        $override = $serverEnv.Values['OLLAMA_MODELS']
        if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    }

    return (Join-Path (Join-Path $HOME '.ollama') 'models')
}

function Get-DirectorySizeBytes {
    <#
        .SYNOPSIS
            Size on disk of a directory, in bytes, or $null if it cannot be read.

        .DESCRIPTION
            Uses `du -sk`, which reports blocks actually allocated. That is the number
            that changes when weights are deleted, and it is what makes a before/after
            difference trustworthy.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $output = & du -sk $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }

    $first = @($output)[0]
    $kb = 0L
    if ([long]::TryParse((($first -split '\s+')[0]), [ref]$kb)) { return $kb * 1024 }
    return $null
}

function Format-ByteSize {
    <#
        .SYNOPSIS
            Human-readable byte count, e.g. "18.6 GB".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][System.Nullable[long]]$Bytes)

    if ($null -eq $Bytes) { return 'unknown' }
    if ($Bytes -lt 0) { return "-$(Format-ByteSize -Bytes ([long](-$Bytes)))" }
    if ($Bytes -ge 1GB) { return ('{0:0.#} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0.#} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0.#} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-InstalledOllamaModel {
    <#
        .SYNOPSIS
            Models reported by /api/tags, or $null if the server cannot be reached.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 15)

    try {
        $tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $tags.PSObject.Properties['models']) { return @() }
    return @($tags.models)
}

function Invoke-OllamaUnload {
    <#
        .SYNOPSIS
            Evicts one model from memory by setting keep_alive to 0.

        .DESCRIPTION
            Shared by Dismount-LocalModel.ps1 and Remove-LocalModel.ps1. Deleting a model
            that is still resident works, but unloading first keeps the server's view and
            the memory accounting honest.

            Returns $true on success. ShouldProcess is handled by the calling script, so
            that its prompts describe the user-facing action rather than this step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$ModelTag,
        [int]$TimeoutSec = 30
    )

    $body = @{ model = $ModelTag; keep_alive = 0 } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "$BaseUrl/api/generate" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Could not unload '$ModelTag': $(Get-HttpErrorDetail -ErrorRecord $_)"
        return $false
    }
}

function Get-ResidentOllamaModel {
    <#
        .SYNOPSIS
            Tags currently resident in memory according to /api/ps.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 5)

    try {
        $running = Invoke-RestMethod -Uri "$BaseUrl/api/ps" -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    catch {
        return @()
    }

    if (-not $running.PSObject.Properties['models']) { return @() }
    return @(@($running.models) | ForEach-Object { $_.name })
}

function Set-OllamaServiceKnob {
    <#
        .SYNOPSIS
            Registers the performance knobs with launchd so the background server sees them.

        .DESCRIPTION
            `brew services` runs Ollama under launchd, which does NOT inherit your shell
            environment - setting $env:OLLAMA_* in a shell has no effect on the server.
            `launchctl setenv` is the mechanism that does work.

            Note: launchctl setenv values persist until reboot, not permanently. The
            scripts that start the service re-apply them every time, so in practice you
            do not have to think about it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$KeepAlive,
        [string]$KvCacheType,
        [bool]$FlashAttention = $true,
        [int]$ContextLength = 0,
        [int]$MaxLoadedModels = 0
    )

    $knobs = [ordered]@{
        OLLAMA_FLASH_ATTENTION = $(if ($FlashAttention) { '1' } else { '0' })
        OLLAMA_KV_CACHE_TYPE   = $KvCacheType
        OLLAMA_KEEP_ALIVE      = $KeepAlive
    }
    if ($MaxLoadedModels -gt 0) {
        $knobs['OLLAMA_MAX_LOADED_MODELS'] = "$MaxLoadedModels"
    }
    if ($ContextLength -gt 0) {
        $knobs['OLLAMA_CONTEXT_LENGTH'] = "$ContextLength"
    }

    foreach ($knob in $knobs.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($knob.Value)) { continue }
        if ($PSCmdlet.ShouldProcess($knob.Key, "launchctl setenv $($knob.Value)")) {
            & launchctl setenv $knob.Key $knob.Value
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "launchctl setenv $($knob.Key) returned exit code $LASTEXITCODE."
            }
            else {
                Write-Ok "$($knob.Key)=$($knob.Value)"
            }
        }
    }

    # launchctl setenv persists until reboot, so a value set by an earlier run would
    # otherwise linger. Clear the opt-in knobs explicitly when they are not requested,
    # so that what the scripts report is what the server actually sees.
    $clear = @()
    if ($MaxLoadedModels -le 0) { $clear += 'OLLAMA_MAX_LOADED_MODELS' }
    if ($ContextLength -le 0) { $clear += 'OLLAMA_CONTEXT_LENGTH' }

    foreach ($name in $clear) {
        if ($PSCmdlet.ShouldProcess($name, 'launchctl unsetenv')) {
            & launchctl unsetenv $name
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "launchctl unsetenv $name returned exit code $LASTEXITCODE."
            }
        }
    }

    if ($ContextLength -le 0) {
        Write-Detail 'OLLAMA_CONTEXT_LENGTH not set (Ollama default). Pass -ContextLength 65536 for agent work.'
    }
    if ($MaxLoadedModels -le 0) {
        Write-Detail 'OLLAMA_MAX_LOADED_MODELS not set (Ollama default). Models may accumulate in memory.'
    }
}

# --- Service control ----------------------------------------------------------

function Start-OllamaService {
    <#
        .SYNOPSIS
            Starts the brew-managed Ollama service.

        .DESCRIPTION
            `brew services run` starts it now WITHOUT registering a launchd login item.
            `brew services start` also registers it to launch at every login. On-demand
            is the default here; -AtLogin opts into always-on.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$AtLogin)

    $verb = if ($AtLogin) { 'start' } else { 'run' }

    if (-not $PSCmdlet.ShouldProcess('ollama', "brew services $verb")) { return }

    & brew services $verb ollama
    if ($LASTEXITCODE -ne 0) { throw "brew services $verb ollama failed with exit code $LASTEXITCODE." }

    if ($AtLogin) { Write-Ok 'service started and registered to launch at login' }
    else { Write-Ok 'service started (not registered at login)' }
}

function Stop-OllamaService {
    <#
        .SYNOPSIS
            Stops the brew-managed Ollama service and unregisters any login item.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('ollama', 'brew services stop')) { return }

    & brew services stop ollama
    if ($LASTEXITCODE -ne 0) { Write-Warning "brew services stop ollama returned exit code $LASTEXITCODE." }
    else { Write-Ok 'service stopped' }
}

function Wait-OllamaApi {
    <#
        .SYNOPSIS
            Polls the API until it answers. Returns the version string, or $null on timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $version = Get-OllamaVersion -BaseUrl $BaseUrl -TimeoutSec 2
        if ($version) { return $version }
        Start-Sleep -Seconds 1
    }
    return $null
}
