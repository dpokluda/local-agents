#Requires -Version 7.0
<#
.SYNOPSIS
    Health-checks the local LLM agent stack: server, models, throughput, and tool-calling.

.DESCRIPTION
    Run this after installing or after pulling new models, and again before you go offline.

    For each installed model it:
      1. Runs a short completion and measures generation throughput (tokens/sec) using
         Ollama's own eval counters rather than wall-clock time.
      2. Records load_duration (a warm model does not measure cold-start latency).
      3. Sends a request carrying a tool definition and verifies the model emits a
         well-formed tool call - correct function name, parseable arguments, expected key.
      4. Reassembles streamed tool calls from /v1/chat/completions, sends a synthetic
         weather tool result back, and checks that the final reply uses it.

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
    Value passed as Ollama's keep_alive for native test requests. On a local Mac it defaults
    to the saved/shared setting; elsewhere it is omitted to retain the server's policy.
    OpenAI requests use the server's setting.

.PARAMETER UnloadAfterEach
    Unload each model from memory after testing it. Use this when testing a large tier
    so the run does not hold several models resident at once.

.PARAMETER SkipBenchmark
    Skip the throughput measurement and only check reachability and tool-calling.

.PARAMETER SkipToolCheck
    Skip tool-calling verification. Rarely what you want.

.PARAMETER JsonPath
    Also write the full results to this path as JSON, for tracking regressions over time.

.PARAMETER MinimumContextLength
    Require at least this many allocated tokens in /api/ps after testing each model.
    This checks configuration, not long-context quality. The model must remain loaded.

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

    [string]$BaseUrl,

    [ValidateRange(10, 1800)]
    [int]$TimeoutSeconds = 300,

    [string]$KeepAlive,

    [switch]$UnloadAfterEach,

    [switch]$SkipBenchmark,

    [switch]$SkipToolCheck,

    [ValidateRange(1, 2147483647)]
    [int]$MinimumContextLength,

    [string]$JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers: Get-OllamaServerEnvironment and Get-HttpErrorDetail. Dot-sourced
# before the local helpers below, so the script-specific versions win on name overlap.
. "$PSScriptRoot/_common.ps1"
$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl
$localMac = Test-LocalMacEndpoint $BaseUrl
if (-not $KeepAlive -and $localMac) { $KeepAlive = (Get-OllamaServiceSettings).KeepAlive }

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
    if ($FunctionName -cne 'get_current_weather') {
        return [pscustomobject]@{ Ok = $false; Detail = "called '$FunctionName' instead of 'get_current_weather'" }
    }

    # Native API returns an object; the OpenAI-compatible shim returns a JSON string.
    $parsed = $Arguments
    if ($Arguments -is [string]) {
        try { $parsed = $Arguments | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ Ok = $false; Detail = 'arguments were not valid JSON' } }
    }

    if ($parsed -isnot [pscustomobject]) {
        return [pscustomobject]@{ Ok = $false; Detail = 'arguments must be a JSON object' }
    }
    $location = Get-Prop -InputObject $parsed -Name 'location'
    if ($location -isnot [string] -or [string]::IsNullOrWhiteSpace($location)) {
        return [pscustomobject]@{ Ok = $false; Detail = "required argument 'location' must be a nonempty string" }
    }
    if ($location -notmatch '(?i)\bPrague\b|\bPraha\b') {
        return [pscustomobject]@{ Ok = $false; Detail = "tool call requested '$location', not Prague" }
    }
    $unit = $parsed.PSObject.Properties['unit']
    if ($null -ne $unit -and ($unit.Value -isnot [string] -or $unit.Value -cnotin @('celsius', 'fahrenheit'))) {
        return [pscustomobject]@{ Ok = $false; Detail = "argument 'unit' did not match the schema" }
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
        [string]$KeepAliveValue,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model      = $ModelTag
        stream     = $false
        messages   = @(@{ role = 'user'; content = $BenchmarkPrompt })
        options    = @{ temperature = 0; num_predict = 128 }
    }
    if ($KeepAliveValue) { $body.keep_alive = $KeepAliveValue }
    $body = $body | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Uri "$Uri/api/chat" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop

    $evalCount = [double](Get-Prop -InputObject $response -Name 'eval_count' -Default 0)
    $evalNs = [double](Get-Prop -InputObject $response -Name 'eval_duration' -Default 0)
    $loadNs = [double](Get-Prop -InputObject $response -Name 'load_duration' -Default 0)
    $promptCount = [double](Get-Prop -InputObject $response -Name 'prompt_eval_count' -Default 0)

    if ($evalNs -le 0 -or $evalCount -le 0) { throw 'Benchmark returned no valid generation counters.' }
    $tokensPerSecond = [math]::Round($evalCount / ($evalNs / 1e9), 1)

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
        [string]$KeepAliveValue,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model      = $ModelTag
        stream     = $false
        # Flatten-and-collect. This is the one wrapping idiom that yields a flat JSON
        # array whether New-WeatherTool returns ,@(x), @(x) or a bare x - a plain @(...)
        # around the comma idiom nests instead, and Ollama rejects both shapes.
        tools      = @(New-WeatherTool | ForEach-Object { $_ })
        messages   = @(
            @{ role = 'user'; content = 'What is the weather in Prague right now?' }
        )
        options    = @{ temperature = 0 }
    }
    if ($KeepAliveValue) { $body.keep_alive = $KeepAliveValue }
    $body = $body | ConvertTo-Json -Depth 20

    $response = Invoke-RestMethod -Uri "$Uri/api/chat" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop

    $message = Get-Prop -InputObject $response -Name 'message'
    $toolCalls = @(Get-Prop -InputObject $message -Name 'tool_calls' -Default @())

    if ($toolCalls.Count -ne 1) {
        return [pscustomobject]@{ Ok = $false; Detail = "expected one weather tool call, received $($toolCalls.Count)" }
    }

    $fn = Get-Prop -InputObject $toolCalls[0] -Name 'function'
    return Test-ToolCallShape -FunctionName ([string](Get-Prop -InputObject $fn -Name 'name')) `
        -Arguments (Get-Prop -InputObject $fn -Name 'arguments')
}

function ConvertFrom-OpenAiEventStream {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $calls = @{}
    $text = ''
    $reasoning = ''
    $finish = $null
    $done = $false
    foreach ($event in ($Content -split '\r?\n\r?\n')) {
        $data = @(foreach ($line in ($event -split '\r?\n')) {
            if ($line.StartsWith('data:')) { $line.Substring(5).TrimStart() }
        }) -join "`n"
        if (-not $data) { continue }
        if ($done) { throw 'Received data after the stream terminator.' }
        if ($data.Trim() -eq '[DONE]') { $done = $true; continue }
        $chunk = $data | ConvertFrom-Json -ErrorAction Stop
        if (Get-Prop $chunk 'error') { throw "Stream error: $data" }
        foreach ($choice in @(Get-Prop $chunk 'choices' @())) {
            if ((Get-Prop $choice 'index' -1) -ne 0) { throw 'Unexpected choice index in stream.' }
            $delta = Get-Prop $choice 'delta'
            $text += [string](Get-Prop $delta 'content' '')
            $reasoning += [string](Get-Prop $delta 'reasoning' '')
            foreach ($part in @(Get-Prop $delta 'tool_calls' @())) {
                $index = Get-Prop $part 'index' -1
                if ($index -isnot [long] -and $index -isnot [int]) { throw 'Invalid tool-call index in stream.' }
                if ($index -lt 0) { throw 'Missing tool-call index in stream.' }
                if (-not $calls.ContainsKey($index)) {
                    $calls[$index] = @{ id = ''; type = 'function'; function = @{ name = ''; arguments = '' } }
                }
                $call = $calls[$index]
                $call.id += [string](Get-Prop $part 'id' '')
                $type = Get-Prop $part 'type'
                if ($type -and $type -cne 'function') { throw "Unsupported streamed tool type '$type'." }
                $fn = Get-Prop $part 'function'
                $call.function.name += [string](Get-Prop $fn 'name' '')
                $call.function.arguments += [string](Get-Prop $fn 'arguments' '')
            }
            $reason = Get-Prop $choice 'finish_reason'
            if ($reason) { $finish = $reason }
        }
    }
    if (-not $done -or -not $finish) { throw 'Incomplete OpenAI stream: missing finish_reason or [DONE].' }
    $message = @{ role = 'assistant'; content = $text }
    if ($reasoning) { $message.reasoning = $reasoning }
    if ($calls.Count) { $message.tool_calls = @($calls.Keys | Sort-Object | ForEach-Object { $calls[$_] }) }
    return [pscustomobject]@{ Message = $message; FinishReason = $finish }
}

function Invoke-OpenAiStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $response = Invoke-WebRequest -Uri "$Uri/v1/chat/completions" -Method Post `
        -Body ($Body | ConvertTo-Json -Depth 20) -ContentType 'application/json' `
        -Headers @{ Authorization = 'Bearer ollama' } -TimeoutSec $TimeoutSec -ErrorAction Stop
    if ([string]$response.Headers['Content-Type'] -notlike 'text/event-stream*') {
        throw 'The server did not return text/event-stream for a streaming request.'
    }
    # Buffer a bounded smoke-test response, then reconstruct the actual SSE deltas.
    $content = $response.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return ConvertFrom-OpenAiEventStream -Content $content
}

function Invoke-OpenAiToolCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$ModelTag,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $body = @{
        model       = $ModelTag
        stream      = $true
        max_tokens  = 1024
        temperature = 0
        tools       = @(New-WeatherTool | ForEach-Object { $_ })
        tool_choice = 'auto'
        messages    = @(
            @{ role = 'user'; content = 'What is the weather in Prague right now?' }
        )
    }

    $response = Invoke-OpenAiStream -Uri $Uri -Body $body -TimeoutSec $TimeoutSec
    $message = $response.Message
    $toolCalls = @()
    if ($message.ContainsKey('tool_calls')) { $toolCalls = @($message.tool_calls) }
    if ($toolCalls.Count -ne 1 -or $response.FinishReason -cne 'tool_calls') {
        return [pscustomobject]@{ Ok = $false; Detail = 'stream did not finish with one weather tool call' }
    }
    $call = $toolCalls[0]
    $shape = Test-ToolCallShape -FunctionName $call.function.name -Arguments $call.function.arguments
    if (-not $shape.Ok) { return $shape }
    if ([string]::IsNullOrWhiteSpace($call.id)) {
        return [pscustomobject]@{ Ok = $false; Detail = 'streamed tool call has no id for the tool reply' }
    }
    $body.messages += $message
    $body.messages += @{
        role = 'tool'; tool_call_id = $call.id
        content = '{"location":"Prague","temperature":17,"unit":"celsius","condition":"sunny","synthetic_test_data":true}'
    }
    $body.messages += @{ role = 'user'; content = 'Report the temperature in Celsius from the tool result in one short sentence. Do not call another tool.' }
    $body.tool_choice = 'none'
    $reply = Invoke-OpenAiStream -Uri $Uri -Body $body -TimeoutSec $TimeoutSec
    if ($reply.FinishReason -cne 'stop' -or $reply.Message.ContainsKey('tool_calls') -or
        $reply.Message.content -notmatch '\b17\b') {
        return [pscustomobject]@{ Ok = $false; Detail = 'tool-result continuation did not finish with the supplied temperature (17 C)' }
    }
    return [pscustomobject]@{ Ok = $true; Detail = "$($shape.Detail); streaming and synthetic tool-result round trip passed" }
}

function Get-ModelContextLength {
    param([string]$Uri, [string]$ModelTag)

    $running = Invoke-RestMethod -Uri "$Uri/api/ps" -TimeoutSec 10 -ErrorAction Stop
    $models = @(Get-Prop $running 'models' @() | Where-Object { $_.name -ceq $ModelTag })
    if ($models.Count -ne 1) { throw "Cannot inspect allocated context: '$ModelTag' is not resident." }
    $context = Get-Prop $models[0] 'context_length'
    if ($null -eq $context) { throw 'This Ollama version does not report context_length in /api/ps. Upgrade Ollama to check it.' }
    return [int]$context
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
        throw "Unload request for $ModelTag failed: $(Get-HttpErrorDetail -ErrorRecord $_)"
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
    Write-Host "  $(Get-OllamaStartHint -BaseUrl $BaseUrl)" -ForegroundColor Yellow
    exit 1
}
Write-Host "    OK  server up, version $version" -ForegroundColor Green

# --- 2. Environment knobs -----------------------------------------------------

Write-Step 'Environment knobs'

$knobs = [ordered]@{}
if ($localMac) { $knobs = Get-SavedOllamaEnvironment }
if ($localMac -and $knobs.Count -eq 0) {
    $knobs = [ordered]@{
        OLLAMA_FLASH_ATTENTION = $(if ($LocalAgentDefaults.FlashAttention) { '1' } else { '0' })
        OLLAMA_KV_CACHE_TYPE = $LocalAgentDefaults.KvCacheType
        OLLAMA_KEEP_ALIVE = $LocalAgentDefaults.KeepAlive
        OLLAMA_MAX_LOADED_MODELS = [string]$LocalAgentDefaults.MaxLoadedModels
    }
}

# Read the server process itself. Checking this shell's environment would only tell
# you about this shell - the server runs under launchd and never saw it.
$serverEnv = Get-OllamaServerEnvironment -BaseUrl $BaseUrl
if ($serverEnv.Source -eq 'none') {
    Write-Host '    --  server environment unavailable (remote/non-Mac endpoint or no readable process); not verified' -ForegroundColor DarkYellow
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
    Write-Host '    Environment diagnostics are advisory; a launchctl fallback is not proof of process settings.' -ForegroundColor DarkGray
    Write-Host '    Apply the saved service configuration with:' -ForegroundColor DarkGray
    Write-Host '        ./scripts/Restart-Ollama.ps1' -ForegroundColor DarkGray
    Write-Host "    Missing or different: $($missing -join ', ')" -ForegroundColor DarkGray
}

# --- 3. Installed models ------------------------------------------------------

Write-Step 'Enumerating installed models'

$tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 15 -ErrorAction Stop
$installed = @(Get-Prop -InputObject $tags -Name 'models' -Default @())

if ($installed.Count -eq 0) {
    $suggestedTier = if ($localMac) { 'recommended' } else { 'minimal' }
    Write-Warning "No models are installed. Run: ./scripts/Sync-Models.ps1 -Tier $suggestedTier"
    exit 1
}

if ($Model) {
    foreach ($pattern in $Model) {
        if (@($installed | Where-Object { $_.name -clike $pattern }).Count -eq 0) {
            throw "No installed model matched requested selector '$pattern'."
        }
    }
    $installed = @($installed | Where-Object {
            $name = $_.name
            # @(...) matters: a single match unwraps to a bare string, and .Count on
            # that throws under Set-StrictMode -Version Latest.
            @($Model | Where-Object { $name -clike $_ }).Count -gt 0
        })
    if ($installed.Count -eq 0) {
        Write-Warning "No installed model matched: $($Model -join ', ')"
        exit 1
    }
}

foreach ($m in $installed) {
    $sizeGb = [math]::Round([double](Get-Prop -InputObject $m -Name 'size' -Default 0) / 1e9, 1)
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
    $sizeGb = [math]::Round([double](Get-Prop -InputObject $m -Name 'size' -Default 0) / 1e9, 1)

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
        ContextLength   = $null
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

        Write-Host '      streamed tool call + result round trip (OpenAI /v1)...' -NoNewline
        try {
            $openai = Invoke-OpenAiToolCheck -Uri $BaseUrl -ModelTag $tag -TimeoutSec $TimeoutSeconds
            $row.Reachable = $true
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

    if ($MinimumContextLength) {
        try {
            $row.ContextLength = Get-ModelContextLength -Uri $BaseUrl -ModelTag $tag
            if ($row.ContextLength -lt $MinimumContextLength) {
                throw "Allocated context $($row.ContextLength) is below required $MinimumContextLength tokens."
            }
        }
        catch {
            $row.Notes += "context: $(Get-HttpErrorDetail $_)"
            Write-Warning $row.Notes[-1]
        }
    }
    if ($UnloadAfterEach) {
        try { Clear-LoadedModel -Uri $BaseUrl -ModelTag $tag }
        catch {
            $row.Notes += "unload: $(Get-HttpErrorDetail $_)"
            Write-Warning $row.Notes[-1]
        }
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
@{ L = 'Context'; E = { if ($null -ne $_.ContextLength) { $_.ContextLength } else { '-' } } },
@{ L = 'Tools/native'; E = { $_.ToolsNative } },
@{ L = 'Tools/v1'; E = { $_.ToolsOpenAi } } | Out-Host

$agentReady = @($results | Where-Object { $_.ToolsNative -eq 'pass' -and $_.ToolsOpenAi -eq 'pass' -and $_.Notes.Count -eq 0 })
$failed = @($results | Where-Object { $_.Notes.Count -gt 0 })

Write-Host "  Tool smoke checks passed (native + streamed OpenAI round trip): $($agentReady.Count)/$($results.Count)" -ForegroundColor White
Write-Host '  This does not certify long-context quality, real-task reliability, or the Responses API.' -ForegroundColor DarkGray
if ($agentReady.Count -gt 0) {
    $fastest = $agentReady | Where-Object { $null -ne $_.TokensPerSecond } | Sort-Object TokensPerSecond -Descending | Select-Object -First 1
    if ($fastest) {
        Write-Host "  Fastest passing model: $($fastest.Model) at $($fastest.TokensPerSecond) tok/s" -ForegroundColor Green
    }
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Requested checks failed:' -ForegroundColor Red
    foreach ($b in $failed) {
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
if ($failed.Count -gt 0) { exit 1 }
exit 0
