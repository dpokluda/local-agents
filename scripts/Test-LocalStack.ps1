#Requires -Version 7.0
<#
.SYNOPSIS
    Health-checks the local LLM agent stack: server, models, throughput, and tool-calling.

.DESCRIPTION
    Run this after installing or after pulling new models, and again before you go offline.

    For each installed model it:
      1. Runs a short completion and measures generation throughput (tokens/sec) using
         Ollama's own eval counters rather than wall-clock time.
      2. Records cold-load time (how long the weights took to map into memory).
      3. Sends a request carrying a tool definition and verifies the model emits a
         well-formed tool call - correct function name, parseable arguments, expected key.
      4. Repeats the tool check against the OpenAI-compatible /v1 endpoint, which is the
         path real agent harnesses actually use.

    Step 3/4 is the point of this script. A model that generates beautiful prose but
    silently ignores tool definitions is useless in an agent loop, and the failure mode
    is quiet: the agent just "talks about" calling the tool and the loop stalls. Check it
    explicitly, per model, before you trust it.

.PARAMETER Model
    Only test models whose tag matches one of these values (exact match or wildcard).
    Default: every installed model.

.PARAMETER BaseUrl
    Ollama server root. Default http://localhost:11434.

.PARAMETER TimeoutSeconds
    Per-request timeout. Cold-loading a 19GB model can take a while on first touch.

.PARAMETER KeepAlive
    Value passed as Ollama's keep_alive for test requests.

.PARAMETER UnloadAfterEach
    Unload each model from memory after testing it. Use this when testing a large tier
    so the run does not hold several models resident at once.

.PARAMETER SkipBenchmark
    Skip the throughput measurement and only check reachability and tool-calling.

.PARAMETER SkipToolCheck
    Skip tool-calling verification. Rarely what you want.

.PARAMETER JsonPath
    Also write the full results to this path as JSON, for tracking regressions over time.

.EXAMPLE
    ./scripts/Test-LocalStack.ps1

    Full check of every installed model.

.EXAMPLE
    ./scripts/Test-LocalStack.ps1 -Model 'qwen3-coder:30b','gpt-oss:20b'

    Check just two models.

.EXAMPLE
    ./scripts/Test-LocalStack.ps1 -UnloadAfterEach -JsonPath ./out/stack-check.json

    Memory-friendly full sweep, with results saved.
#>
[CmdletBinding()]
param(
    [string[]]$Model,

    [string]$BaseUrl = 'http://localhost:11434',

    [ValidateRange(10, 1800)]
    [int]$TimeoutSeconds = 300,

    [string]$KeepAlive = '5m',

    [switch]$UnloadAfterEach,

    [switch]$SkipBenchmark,

    [switch]$SkipToolCheck,

    [string]$JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers: Get-OllamaServerEnvironment and Get-HttpErrorDetail. Dot-sourced
# before the local helpers below, so the script-specific versions win on name overlap.
. "$PSScriptRoot/_common.ps1"

$BenchmarkPrompt = 'Write a PowerShell one-liner that lists files larger than 10 MB under the current directory. Answer with the command and one sentence of explanation.'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-Prop {
    <#
        .SYNOPSIS
            Strict-mode-safe property read. Returns $Default when the property is absent.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -isnot [psobject]) { return $Default }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function New-WeatherTool {
    <#
        .SYNOPSIS
            A minimal, unambiguous tool definition. Deliberately boring so that a failure
            means "this model cannot do tool-calling", not "the schema was tricky".

        .NOTES
            Returns with a leading comma (`return ,@(...)`) on purpose. PowerShell unrolls
            a single-element array on return, so a plain `return @($tool)` hands back the
            bare hashtable; `tools = New-WeatherTool` then serializes as a JSON *object*
            and Ollama rejects the request with:

                json: cannot unmarshal object into Go struct field .tools of type api.Tools

            Call sites pipe through ForEach-Object before collecting with @(...), which
            is the only wrapping that stays flat for every possible return shape. A bare
            @(New-WeatherTool) around the comma idiom nests one level too deep and gets
            rejected just as loudly:

                json: cannot unmarshal array into .tools.0 of type api.Tool
    #>
    [CmdletBinding()]
    param()

    return , @(
        @{
            type     = 'function'
            function = @{
                name        = 'get_current_weather'
                description = 'Get the current weather for a city. Call this whenever the user asks about weather.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        location = @{
                            type        = 'string'
                            description = 'The city name, for example "Prague".'
                        }
                        unit     = @{
                            type        = 'string'
                            enum        = @('celsius', 'fahrenheit')
                            description = 'Temperature unit.'
                        }
                    }
                    required   = @('location')
                }
            }
        }
    )
}

function Test-ToolCallShape {
    <#
        .SYNOPSIS
            Validates a normalized tool call: right function name, parseable arguments,
            and the required 'location' argument actually populated.
        .OUTPUTS
            PSCustomObject with Ok (bool) and Detail (string).
    #>
    [CmdletBinding()]
    param(
        [string]$FunctionName,
        $Arguments
    )

    if ([string]::IsNullOrWhiteSpace($FunctionName)) {
        return [pscustomobject]@{ Ok = $false; Detail = 'tool call had no function name' }
    }
    if ($FunctionName -ne 'get_current_weather') {
        return [pscustomobject]@{ Ok = $false; Detail = "called '$FunctionName' instead of 'get_current_weather'" }
    }

    # Native API returns an object; the OpenAI-compatible shim returns a JSON string.
    $parsed = $Arguments
    if ($Arguments -is [string]) {
        try { $parsed = $Arguments | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ Ok = $false; Detail = 'arguments were not valid JSON' } }
    }

    $location = Get-Prop -InputObject $parsed -Name 'location'
    if ([string]::IsNullOrWhiteSpace([string]$location)) {
        return [pscustomobject]@{ Ok = $false; Detail = "required argument 'location' was missing" }
    }

    return [pscustomobject]@{ Ok = $true; Detail = "get_current_weather(location='$location')" }
}

function Invoke-Benchmark {
    <#
        .SYNOPSIS
            One short non-streaming completion; returns tokens/sec from Ollama's counters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ModelTag,
        [Parameter(Mandatory)][string]$KeepAliveValue,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model      = $ModelTag
        stream     = $false
        keep_alive = $KeepAliveValue
        messages   = @(@{ role = 'user'; content = $BenchmarkPrompt })
        options    = @{ temperature = 0; num_predict = 128 }
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Uri "$Uri/api/chat" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop

    $evalCount = [double](Get-Prop -InputObject $response -Name 'eval_count' -Default 0)
    $evalNs = [double](Get-Prop -InputObject $response -Name 'eval_duration' -Default 0)
    $loadNs = [double](Get-Prop -InputObject $response -Name 'load_duration' -Default 0)
    $promptCount = [double](Get-Prop -InputObject $response -Name 'prompt_eval_count' -Default 0)

    $tokensPerSecond = $null
    if ($evalNs -gt 0) {
        $tokensPerSecond = [math]::Round($evalCount / ($evalNs / 1e9), 1)
    }

    return [pscustomobject]@{
        TokensPerSecond = $tokensPerSecond
        OutputTokens    = [int]$evalCount
        PromptTokens    = [int]$promptCount
        LoadSeconds     = [math]::Round($loadNs / 1e9, 1)
    }
}

function Invoke-NativeToolCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ModelTag,
        [Parameter(Mandatory)][string]$KeepAliveValue,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model      = $ModelTag
        stream     = $false
        keep_alive = $KeepAliveValue
        # Flatten-and-collect. This is the one wrapping idiom that yields a flat JSON
        # array whether New-WeatherTool returns ,@(x), @(x) or a bare x - a plain @(...)
        # around the comma idiom nests instead, and Ollama rejects both shapes.
        tools      = @(New-WeatherTool | ForEach-Object { $_ })
        messages   = @(
            @{ role = 'user'; content = 'What is the weather in Prague right now?' }
        )
        options    = @{ temperature = 0 }
    } | ConvertTo-Json -Depth 20

    $response = Invoke-RestMethod -Uri "$Uri/api/chat" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop

    $message = Get-Prop -InputObject $response -Name 'message'
    $toolCalls = @(Get-Prop -InputObject $message -Name 'tool_calls' -Default @())

    if ($toolCalls.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Detail = 'model replied with text instead of a tool call' }
    }

    $fn = Get-Prop -InputObject $toolCalls[0] -Name 'function'
    return Test-ToolCallShape -FunctionName ([string](Get-Prop -InputObject $fn -Name 'name')) `
        -Arguments (Get-Prop -InputObject $fn -Name 'arguments')
}

function Invoke-OpenAiToolCheck {
    <#
        .SYNOPSIS
            Same check against /v1/chat/completions - the endpoint agent harnesses use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ModelTag,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model       = $ModelTag
        stream      = $false
        temperature = 0
        tools       = @(New-WeatherTool | ForEach-Object { $_ })
        tool_choice = 'auto'
        messages    = @(
            @{ role = 'user'; content = 'What is the weather in Prague right now?' }
        )
    } | ConvertTo-Json -Depth 20

    $headers = @{ Authorization = 'Bearer ollama' }  # shim ignores the value but some clients require the header

    $response = Invoke-RestMethod -Uri "$Uri/v1/chat/completions" -Method Post -Body $body `
        -ContentType 'application/json' -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop

    $choices = @(Get-Prop -InputObject $response -Name 'choices' -Default @())
    if ($choices.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Detail = '/v1 returned no choices' }
    }

    $message = Get-Prop -InputObject $choices[0] -Name 'message'
    $toolCalls = @(Get-Prop -InputObject $message -Name 'tool_calls' -Default @())
    if ($toolCalls.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Detail = 'model replied with text instead of a tool call' }
    }

    $fn = Get-Prop -InputObject $toolCalls[0] -Name 'function'
    return Test-ToolCallShape -FunctionName ([string](Get-Prop -InputObject $fn -Name 'name')) `
        -Arguments (Get-Prop -InputObject $fn -Name 'arguments')
}

function Clear-LoadedModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ModelTag
    )

    $body = @{ model = $ModelTag; keep_alive = 0; messages = @() } | ConvertTo-Json -Depth 5
    try {
        $null = Invoke-RestMethod -Uri "$Uri/api/chat" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        Write-Verbose "Unload request for $ModelTag failed: $(Get-HttpErrorDetail -ErrorRecord $_)"
    }
}

# --- 1. Server ----------------------------------------------------------------

Write-Step "Checking Ollama at $BaseUrl"

try {
    $version = (Invoke-RestMethod -Uri "$BaseUrl/api/version" -TimeoutSec 5 -ErrorAction Stop).version
}
catch {
    Write-Host ''
    Write-Host 'FAIL: the Ollama server is not reachable.' -ForegroundColor Red
    Write-Host "  Tried: $BaseUrl/api/version" -ForegroundColor Red
    Write-Host "  Error: $(Get-HttpErrorDetail -ErrorRecord $_)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  Try:  ./scripts/Start-Ollama.ps1' -ForegroundColor Yellow
    Write-Host '  Or:   ollama serve' -ForegroundColor Yellow
    exit 1
}
Write-Host "    OK  server up, version $version" -ForegroundColor Green

# --- 2. Environment knobs -----------------------------------------------------

Write-Step 'Environment knobs'

$knobs = [ordered]@{
    OLLAMA_FLASH_ATTENTION   = '1'
    OLLAMA_KV_CACHE_TYPE     = 'q8_0'
    OLLAMA_KEEP_ALIVE        = '-1'
    OLLAMA_MAX_LOADED_MODELS = '1'
}

# Read the server process itself. Checking this shell's environment would only tell
# you about this shell - the server runs under launchd and never saw it.
$serverEnv = Get-OllamaServerEnvironment
if ($serverEnv.Source -eq 'none') {
    Write-Host '    --  could not read the server environment (no server process found)' -ForegroundColor DarkYellow
}
else {
    Write-Host "    source: $($serverEnv.Source)" -ForegroundColor DarkGray
}

$missing = @()
foreach ($knob in $knobs.GetEnumerator()) {
    $actual = if ($serverEnv.Values.Contains($knob.Key)) { $serverEnv.Values[$knob.Key] } else { $null }
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Write-Host "    --  $($knob.Key) not set (suggested: $($knob.Value))" -ForegroundColor DarkYellow
        $missing += $knob.Key
    }
    elseif ($actual -ne $knob.Value) {
        Write-Host "    ~~  $($knob.Key)=$actual (suggested: $($knob.Value))" -ForegroundColor DarkYellow
        $missing += $knob.Key
    }
    else {
        Write-Host "    OK  $($knob.Key)=$actual" -ForegroundColor Green
    }
}

# Anything the server has that we did not ask about is still worth seeing.
foreach ($extra in $serverEnv.Values.GetEnumerator()) {
    if (-not $knobs.Contains($extra.Key)) {
        Write-Host "    ..  $($extra.Key)=$($extra.Value)" -ForegroundColor DarkGray
    }
}

if ($missing.Count -gt 0) {
    Write-Host '    The values above are what the *server* sees, which is the only reading' -ForegroundColor DarkGray
    Write-Host '    that matters. Setting OLLAMA_* in a terminal does nothing. Apply them with:' -ForegroundColor DarkGray
    Write-Host '        ./scripts/Restart-Ollama.ps1' -ForegroundColor DarkGray
    Write-Host "    Missing or different: $($missing -join ', ')" -ForegroundColor DarkGray
}

# --- 3. Installed models ------------------------------------------------------

Write-Step 'Enumerating installed models'

$tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 15 -ErrorAction Stop
$installed = @(Get-Prop -InputObject $tags -Name 'models' -Default @())

if ($installed.Count -eq 0) {
    Write-Warning 'No models are installed. Run: ./scripts/Sync-Models.ps1 -Tier recommended'
    exit 1
}

if ($Model) {
    $installed = @($installed | Where-Object {
            $name = $_.name
            # @(...) matters: a single match unwraps to a bare string, and .Count on
            # that throws under Set-StrictMode -Version Latest.
            @($Model | Where-Object { $name -like $_ -or $name -eq $_ }).Count -gt 0
        })
    if ($installed.Count -eq 0) {
        Write-Warning "No installed model matched: $($Model -join ', ')"
        exit 1
    }
}

foreach ($m in $installed) {
    $sizeGb = [math]::Round([double](Get-Prop -InputObject $m -Name 'size' -Default 0) / 1GB, 1)
    Write-Host "    $($m.name)  (${sizeGb}GB)" -ForegroundColor White
}

# --- 4. Per-model checks ------------------------------------------------------

Write-Step "Testing $($installed.Count) model(s)"
Write-Host '    Cold loads are slow the first time; later runs reuse resident weights.' -ForegroundColor DarkGray

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($m in $installed) {
    $index++
    $tag = $m.name
    $sizeGb = [math]::Round([double](Get-Prop -InputObject $m -Name 'size' -Default 0) / 1GB, 1)

    Write-Host ''
    Write-Host "[$index/$($installed.Count)] $tag" -ForegroundColor Yellow

    $row = [ordered]@{
        Model           = $tag
        SizeGb          = $sizeGb
        Reachable       = $false
        TokensPerSecond = $null
        OutputTokens    = $null
        LoadSeconds     = $null
        ToolsNative     = 'skipped'
        ToolsOpenAi     = 'skipped'
        Notes           = @()
    }

    if (-not $SkipBenchmark) {
        Write-Host '      benchmarking...' -NoNewline
        try {
            $bench = Invoke-Benchmark -Uri $BaseUrl -ModelTag $tag -KeepAliveValue $KeepAlive -TimeoutSec $TimeoutSeconds
            $row.Reachable = $true
            $row.TokensPerSecond = $bench.TokensPerSecond
            $row.OutputTokens = $bench.OutputTokens
            $row.LoadSeconds = $bench.LoadSeconds
            Write-Host " $($bench.TokensPerSecond) tok/s (load $($bench.LoadSeconds)s)" -ForegroundColor Green
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            Write-Host " FAILED  $detail" -ForegroundColor Red
            $row.Notes += "benchmark: $detail"
        }
    }
    else {
        $row.Reachable = $true
    }

    if (-not $SkipToolCheck) {
        Write-Host '      tool-calling (native /api/chat)...' -NoNewline
        try {
            $native = Invoke-NativeToolCheck -Uri $BaseUrl -ModelTag $tag -KeepAliveValue $KeepAlive -TimeoutSec $TimeoutSeconds
            $row.Reachable = $true
            $row.ToolsNative = if ($native.Ok) { 'pass' } else { 'FAIL' }
            if ($native.Ok) {
                Write-Host " pass  $($native.Detail)" -ForegroundColor Green
            }
            else {
                Write-Host " FAIL  $($native.Detail)" -ForegroundColor Red
                $row.Notes += "tools(native): $($native.Detail)"
            }
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            Write-Host " ERROR  $detail" -ForegroundColor Red
            $row.ToolsNative = 'error'
            $row.Notes += "tools(native): $detail"
        }

        Write-Host '      tool-calling (OpenAI /v1)...' -NoNewline
        try {
            $openai = Invoke-OpenAiToolCheck -Uri $BaseUrl -ModelTag $tag -TimeoutSec $TimeoutSeconds
            $row.ToolsOpenAi = if ($openai.Ok) { 'pass' } else { 'FAIL' }
            if ($openai.Ok) {
                Write-Host " pass  $($openai.Detail)" -ForegroundColor Green
            }
            else {
                Write-Host " FAIL  $($openai.Detail)" -ForegroundColor Red
                $row.Notes += "tools(v1): $($openai.Detail)"
            }
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            Write-Host " ERROR  $detail" -ForegroundColor Red
            $row.ToolsOpenAi = 'error'
            $row.Notes += "tools(v1): $detail"
        }
    }

    if ($UnloadAfterEach) {
        Clear-LoadedModel -Uri $BaseUrl -ModelTag $tag
    }

    $results.Add([pscustomobject]$row)
}

# --- 5. Summary ---------------------------------------------------------------

Write-Host ''
Write-Step 'Summary'

$results | Format-Table -AutoSize `
    @{ L = 'Model'; E = { $_.Model } },
@{ L = 'Size(GB)'; E = { '{0:0.#}' -f $_.SizeGb }; A = 'right' },
@{ L = 'Tok/s'; E = { if ($null -ne $_.TokensPerSecond) { '{0:0.#}' -f $_.TokensPerSecond } else { '-' } }; A = 'right' },
@{ L = 'Load(s)'; E = { if ($null -ne $_.LoadSeconds) { '{0:0.#}' -f $_.LoadSeconds } else { '-' } }; A = 'right' },
@{ L = 'Tools/native'; E = { $_.ToolsNative } },
@{ L = 'Tools/v1'; E = { $_.ToolsOpenAi } } | Out-Host

$agentReady = @($results | Where-Object { $_.ToolsNative -eq 'pass' -and $_.ToolsOpenAi -eq 'pass' })
$toolBroken = @($results | Where-Object { $_.ToolsNative -notin @('pass', 'skipped') -or $_.ToolsOpenAi -notin @('pass', 'skipped') })

Write-Host "  Agent-ready models (tool-calling verified on both endpoints): $($agentReady.Count)/$($results.Count)" -ForegroundColor White
if ($agentReady.Count -gt 0) {
    $fastest = $agentReady | Where-Object { $null -ne $_.TokensPerSecond } | Sort-Object TokensPerSecond -Descending | Select-Object -First 1
    if ($fastest) {
        Write-Host "  Fastest agent-ready model: $($fastest.Model) at $($fastest.TokensPerSecond) tok/s" -ForegroundColor Green
    }
}

if ($toolBroken.Count -gt 0) {
    Write-Host ''
    Write-Host '  Models with tool-calling problems - do not point an agent harness at these:' -ForegroundColor Red
    foreach ($b in $toolBroken) {
        Write-Host "    $($b.Model)" -ForegroundColor Red
        foreach ($n in $b.Notes) { Write-Host "      - $n" -ForegroundColor DarkRed }
    }
    Write-Host ''
    Write-Host '  Common causes: the tag is a base/non-instruct build, the template shipped with' -ForegroundColor DarkGray
    Write-Host '  the tag lacks tool support, or the model is simply too small to follow the schema.' -ForegroundColor DarkGray
}

if ($JsonPath) {
    $dir = Split-Path -Parent $JsonPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    [pscustomobject]@{
        timestamp      = (Get-Date).ToString('o')
        ollama_version = $version
        base_url       = $BaseUrl
        results        = $results
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JsonPath -Encoding utf8
    Write-Host ''
    Write-Host "  Results written to $JsonPath" -ForegroundColor White
}

Write-Host ''
if ($toolBroken.Count -gt 0) { exit 1 }
exit 0
