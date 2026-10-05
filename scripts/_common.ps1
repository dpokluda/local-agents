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

    # Choose context explicitly: runtime defaults vary by version and available memory.
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

    $BaseUrl = $BaseUrl.Trim().TrimEnd('/') -replace '/v1$', ''
    if ($BaseUrl -notmatch '^[a-z][a-z0-9+.-]*://') { $BaseUrl = "http://$BaseUrl" }
    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw "Invalid Ollama base URL '$BaseUrl'. Use an HTTP(S) host and port, optionally ending in /v1."
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Resolve-OllamaModelTag {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Tag)

    $Tag = $Tag.Trim()
    if (-not $Tag -or $Tag -match '\s') { throw "Invalid model tag '$Tag'." }
    if (($Tag -split '/')[-1] -notmatch ':') {
        return "${Tag}:latest"
    }
    return $Tag
}

function Invoke-OllamaCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw "The 'ollama' CLI was not found on PATH."
    }
    $savedHost = $env:OLLAMA_HOST
    try {
        $env:OLLAMA_HOST = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl
        & ollama @ArgumentList
        if ($LASTEXITCODE -ne 0) { throw "ollama $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE." }
    }
    finally {
        if ($null -eq $savedHost) { Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue }
        else { $env:OLLAMA_HOST = $savedHost }
    }
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

    if (-not $IsMacOS) { return $null }

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

            `ps eww` prints the process's real environment. launchctl getenv is only a
            fallback hint, not proof of the running process's configuration.

            Returns a hashtable of OLLAMA_* values plus a Source label.
    #>
    [CmdletBinding()]
    param([string]$BaseUrl = 'http://localhost:11434')

    $result = @{ Source = 'none'; Values = [ordered]@{}; ProcessId = $null }
    if (-not $IsMacOS -or -not ([uri](Resolve-LocalAgentBaseUrl $BaseUrl)).IsLoopback) {
        return $result
    }

    $serverPid = Get-OllamaServerPid
    if ($serverPid) {
        $result.ProcessId = $serverPid
        $raw = & ps eww -p $serverPid 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $raw) {
            # Preserve spaces in values such as OLLAMA_MODELS.
            $matched = [regex]::Matches($raw, '(?m)\b(OLLAMA_[A-Z0-9_]+)=(.*?)(?=\s+[A-Za-z_][A-Za-z0-9_]*=|[\r\n]|$)')
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
    if ($Bytes -ge 1GB) { return ('{0:0.#} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0.#} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0.#} KiB' -f ($Bytes / 1KB)) }
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

function Assert-OllamaServiceHost {
    param([string]$BaseUrl = 'http://localhost:11434')

    if (-not $IsMacOS) { throw 'Service management requires macOS. On Windows, manage the native Ollama application instead.' }
    $uri = [uri](Resolve-LocalAgentBaseUrl $BaseUrl)
    if (-not $uri.IsLoopback -or $uri.Scheme -ne 'http') {
        throw 'Service management requires a local HTTP loopback endpoint; it cannot manage a remote server or terminate TLS.'
    }
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) { throw 'Homebrew is not on PATH.' }
}

function Get-OllamaServiceFile {
    return (Join-Path $HOME 'Library' 'Application Support' 'local-agents' 'ollama.plist')
}

function Get-SavedOllamaEnvironment {
    $values = [ordered]@{}
    $path = Get-OllamaServiceFile
    if (Test-Path -LiteralPath $path) {
        $xml = [xml](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
        $dictionary = $xml.SelectSingleNode('/plist/dict/key[.="EnvironmentVariables"]/following-sibling::dict[1]')
        if ($null -eq $dictionary) { throw "Missing EnvironmentVariables in $path." }
        foreach ($key in $dictionary.SelectNodes('key')) {
            if ($key.NextSibling.LocalName -ne 'string') { throw "Invalid environment entry in $path." }
            $values[$key.InnerText] = $key.NextSibling.InnerText
        }
    }
    return $values
}

function Get-OllamaServiceSettings {
    $settings = @{}
    foreach ($entry in $LocalAgentDefaults.GetEnumerator()) { $settings[$entry.Key] = $entry.Value }
    $saved = Get-SavedOllamaEnvironment
    if ($saved.Count -gt 0 -and -not $saved.Contains('OLLAMA_MAX_LOADED_MODELS')) {
        $settings.MaxLoadedModels = 0
    }
    $names = @{
        KeepAlive = 'OLLAMA_KEEP_ALIVE'; KvCacheType = 'OLLAMA_KV_CACHE_TYPE'
        FlashAttention = 'OLLAMA_FLASH_ATTENTION'; ContextLength = 'OLLAMA_CONTEXT_LENGTH'
        MaxLoadedModels = 'OLLAMA_MAX_LOADED_MODELS'
    }
    foreach ($key in $names.Keys) {
        if ($saved.Contains($names[$key])) { $settings[$key] = $saved[$names[$key]] }
    }
    $settings.FlashAttention = "$($settings.FlashAttention)" -in @('1', 'true')
    $settings.ContextLength = [int]$settings.ContextLength
    $settings.MaxLoadedModels = [int]$settings.MaxLoadedModels
    return $settings
}

function Get-BrewOllamaServiceInfo {
    $json = & brew services info ollama --json
    if ($LASTEXITCODE -ne 0) { throw "brew services info failed with exit code $LASTEXITCODE." }
    $items = @(($json -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    if ($items.Count -ne 1 -or -not $items[0].PSObject.Properties['service_name']) {
        throw 'Homebrew did not return a single Ollama service with a service_name.'
    }
    return $items[0]
}

function Set-OllamaServiceKnob {
    # A custom plist overrides formula defaults and survives login without this repo.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$KeepAlive,
        [ValidateSet('f16', 'q8_0', 'q4_0')]
        [string]$KvCacheType,
        [bool]$FlashAttention = $true,
        [ValidateRange(0, 2147483647)]
        [int]$ContextLength = 0,
        [ValidateRange(0, 2147483647)]
        [int]$MaxLoadedModels = 0,
        [string]$BaseUrl = 'http://localhost:11434'
    )

    Assert-OllamaServiceHost -BaseUrl $BaseUrl
    $path = Get-OllamaServiceFile
    if (-not $PSCmdlet.ShouldProcess($path, 'Persist Ollama service environment')) { return }

    $service = Get-BrewOllamaServiceInfo
    $prefix = (& brew --prefix ollama | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $prefix) { throw 'Could not locate the installed Ollama formula.' }
    $executable = Join-Path $prefix 'bin' 'ollama'
    if (-not (Test-Path -LiteralPath $executable)) { throw "Ollama executable not found: $executable" }

    $environment = Get-SavedOllamaEnvironment
    $observed = Get-OllamaServerEnvironment -BaseUrl $BaseUrl
    foreach ($entry in $observed.Values.GetEnumerator()) {
        if (-not $environment.Contains($entry.Key)) { $environment[$entry.Key] = $entry.Value }
    }
    $knobs = [ordered]@{
        OLLAMA_FLASH_ATTENTION = $(if ($FlashAttention) { '1' } else { '0' })
        OLLAMA_KV_CACHE_TYPE   = $KvCacheType
        OLLAMA_KEEP_ALIVE      = $KeepAlive
        OLLAMA_HOST            = Resolve-LocalAgentBaseUrl $BaseUrl
    }
    foreach ($entry in $knobs.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    foreach ($entry in @{ OLLAMA_MAX_LOADED_MODELS = $MaxLoadedModels; OLLAMA_CONTEXT_LENGTH = $ContextLength }.GetEnumerator()) {
        $environment.Remove($entry.Key)
        if ($entry.Value -gt 0) { $environment[$entry.Key] = [string]$entry.Value }
    }

    $logDirectory = Join-Path $HOME 'Library' 'Logs' 'local-agents'
    $log = [System.Security.SecurityElement]::Escape((Join-Path $logDirectory 'ollama.log'))
    $program = [System.Security.SecurityElement]::Escape($executable)
    $label = [System.Security.SecurityElement]::Escape($service.service_name)
    $envXml = foreach ($entry in $environment.GetEnumerator()) {
        '<key>{0}</key><string>{1}</string>' -f
            [System.Security.SecurityElement]::Escape($entry.Key),
            [System.Security.SecurityElement]::Escape([string]$entry.Value)
    }
    $content = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$program</string><string>serve</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$log</string>
<key>StandardErrorPath</key><string>$log</string>
<key>EnvironmentVariables</key><dict>$($envXml -join "`n")</dict>
</dict></plist>
"@
    $null = New-Item -ItemType Directory -Path (Split-Path $path), $logDirectory -Force -ErrorAction Stop
    Set-Content -LiteralPath $path -Value $content -Encoding utf8 -ErrorAction Stop
    & plutil -lint $path
    if ($LASTEXITCODE -ne 0) { throw "Invalid service plist: $path" }

    # Remove only the tuning keys written by the old scripts; keep OLLAMA_MODELS intact.
    foreach ($name in 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_KEEP_ALIVE',
        'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_CONTEXT_LENGTH') {
        & launchctl unsetenv $name
        if ($LASTEXITCODE -ne 0) { throw "Could not clear legacy launchctl setting $name." }
    }
    Write-Ok "service configuration saved to $path"
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

    $arguments = @('services', $verb, 'ollama')
    $path = Get-OllamaServiceFile
    if (Test-Path -LiteralPath $path) { $arguments += "--file=$path" }
    & brew @arguments
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
    param([string]$BaseUrl = 'http://localhost:11434')

    Assert-OllamaServiceHost -BaseUrl $BaseUrl

    if (-not $PSCmdlet.ShouldProcess('ollama', 'brew services stop')) { return }

    & brew services stop ollama
    if ($LASTEXITCODE -ne 0) { throw "brew services stop ollama returned exit code $LASTEXITCODE." }
    if (Get-OllamaVersion -BaseUrl $BaseUrl) {
        throw "Ollama still answers at $BaseUrl. Quit the Ollama desktop app or manually started server before managing the Homebrew service."
    }
    Write-Ok 'service stopped'
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
