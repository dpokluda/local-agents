#Requires -Version 7.0
<#
.SYNOPSIS
    Launches GitHub Copilot CLI wired to the local Ollama instance (BYOK).

.DESCRIPTION
    Copilot CLI supports bring-your-own-key providers, including a local Ollama instance.
    This sets the required variables for the *child process only*, so your shell
    environment is left untouched and a normal `copilot` invocation elsewhere still uses
    GitHub-hosted models.

    Setting COPILOT_PROVIDER_BASE_URL is what activates BYOK mode; GitHub authentication
    is not required once it is set. The URL is the same OpenAI-compatible endpoint every
    other harness uses, including the /v1 suffix, which is appended here if missing. No
    API key is needed for local Ollama.

    The authoritative reference is `copilot help providers` - the published docs disagree
    with each other on the base URL.

    The model must support tool calling and streaming or Copilot CLI errors out. Verify
    first with:  ./scripts/Test-LocalStack.ps1 -Model <tag>

.PARAMETER Model
    Ollama tag to use. Defaults to $env:LOCAL_AGENT_MODEL, then the default in _common.ps1.

.PARAMETER Offline
    Also set COPILOT_OFFLINE=true, which stops the CLI contacting GitHub's servers. Full
    network isolation only holds because the provider here is local.

.PARAMETER WireApi
    'completions' (the CLI default) or 'responses'. Ollama's own integration docs use
    'responses'; the CLI help says it is intended for GPT-5-series models. Leave unset to
    take the CLI default, and try 'responses' if tool calls misbehave.

.PARAMETER MaxPromptTokens
    Passed as COPILOT_PROVIDER_MAX_PROMPT_TOKENS. Worth setting for local models: an
    unrecognized model ID makes the agent fall back to conservative defaults, so match
    this to your configured context length (minus room for the response).

.PARAMETER MaxOutputTokens
    Passed as COPILOT_PROVIDER_MAX_OUTPUT_TOKENS. Set this along with the prompt budget
    so their sum fits the server's allocated context window.

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.PARAMETER ArgumentList
    Extra arguments forwarded to the copilot executable.

.EXAMPLE
    ./scripts/Start-LocalCopilot.ps1

.EXAMPLE
    ./scripts/Start-LocalCopilot.ps1 -Model gpt-oss:20b -Offline

.EXAMPLE
    ./scripts/Start-LocalCopilot.ps1 -WireApi responses -MaxPromptTokens 60000

.EXAMPLE
    # Forward extra flags to copilot itself. Use -ArgumentList explicitly; PowerShell
    # consumes a bare "--" before the child process ever sees it.
    ./scripts/Start-LocalCopilot.ps1 -ArgumentList '--banner'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Model,

    [switch]$Offline,

    [ValidateSet('completions', 'responses')]
    [string]$WireApi,

    [ValidateRange(1, 2147483647)]
    [int]$MaxPromptTokens,

    [ValidateRange(1, 2147483647)]
    [int]$MaxOutputTokens,

    [string]$BaseUrl,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ArgumentList
)

Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$copilot = Get-Command copilot -ErrorAction SilentlyContinue
if (-not $copilot) {
    Write-Host 'Copilot CLI is not on PATH.' -ForegroundColor Red
    Write-Host '  Install it first: https://docs.github.com/copilot/how-tos/copilot-cli' -ForegroundColor Yellow
    return
}

if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $env:LOCAL_AGENT_MODEL }
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $LocalAgentDefaults.Model }
$Model = Resolve-OllamaModelTag $Model

# Resolve-LocalAgentBaseUrl strips any /v1 for the native API checks below.
$nativeUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

# Copilot CLI wants the OpenAI-compatible path.
$providerUrl = "$nativeUrl/v1"

if (-not (Test-OllamaReachable -BaseUrl $nativeUrl)) { return }

try {
    $installed = @((Invoke-RestMethod -Uri "$nativeUrl/api/tags" -TimeoutSec 10 -ErrorAction Stop).models |
        ForEach-Object { $_.name })
}
catch {
    Write-Warning "Could not list installed models: $(Get-HttpErrorDetail -ErrorRecord $_)"
    return
}

if ($installed -cnotcontains $Model) {
    Write-Warning "Model '$Model' is not installed. Available: $($installed -join ', ')"
    Write-Warning "Pull it with: ./scripts/Sync-Models.ps1 -Tag '$Model'"
    return
}

# Scope the configuration to the child process so the current shell stays clean.
$childEnv = @{
    COPILOT_PROVIDER_BASE_URL = $providerUrl
    COPILOT_PROVIDER_TYPE     = 'openai'
    COPILOT_PROVIDER_MODEL_ID = $Model
    COPILOT_PROVIDER_WIRE_MODEL = $Model
    COPILOT_PROVIDER_WIRE_API = $(if ($WireApi) { $WireApi } else { 'completions' })
    COPILOT_MODEL             = $Model
}
if ($Offline) { $childEnv['COPILOT_OFFLINE'] = 'true' }
if ($WireApi) { $childEnv['COPILOT_PROVIDER_WIRE_API'] = $WireApi }
if ($PSBoundParameters.ContainsKey('MaxPromptTokens')) {
    $childEnv['COPILOT_PROVIDER_MAX_PROMPT_TOKENS'] = "$MaxPromptTokens"
}
if ($PSBoundParameters.ContainsKey('MaxOutputTokens')) {
    $childEnv['COPILOT_PROVIDER_MAX_OUTPUT_TOKENS'] = "$MaxOutputTokens"
}

Write-Host "Copilot CLI -> $providerUrl  model: $Model$(if ($WireApi) { "  wire: $WireApi" })$(if ($Offline) { '  [offline]' })" -ForegroundColor Green

$saved = @{}
foreach ($k in $childEnv.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    Set-Item -Path "Env:$k" -Value $childEnv[$k]
}

try {
    if ($ArgumentList) { & $copilot.Source @ArgumentList }
    else { & $copilot.Source }
}
finally {
    # Restore, so the calling shell is exactly as it was.
    foreach ($k in $childEnv.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "Env:$k" -Value $saved[$k] }
    }
}
