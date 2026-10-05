#Requires -Version 7.0
<#
.SYNOPSIS
    Saves the performance knobs in a persistent service plist and starts Ollama.

.DESCRIPTION
    Starts the brew-managed Ollama service on demand, after registering the environment
    knobs that the server actually reads. Omitted settings reuse saved values, falling
    back to _common.ps1 on the first run.

    Two things this gets right that are easy to get wrong by hand:

      * `brew services run` starts the server now WITHOUT registering a launchd login
        item, so your Mac does not boot a model server you did not ask for. Use -AtLogin
        for the always-on behaviour.

      * The server runs under launchd, which does NOT inherit your shell environment.
        This script supplies a custom plist through Homebrew's --file option, so the
        saved values override formula defaults and survive reboot with -AtLogin.

    The file lives in ~/Library/Application Support/local-agents/ollama.plist.
    No model files are changed. A running server is restarted when -AtLogin is supplied.

    Defaults live in scripts/_common.ps1 - change them there, not here.

.PARAMETER AtLogin
    Use `brew services start`, which also registers Ollama to launch at every login.
    The default is on-demand.

.PARAMETER KeepAlive
    How long weights stay resident after the last request. Default '-1', meaning they
    stay loaded until the server stops or the model is unloaded explicitly. The lifecycle
    is deliberate here: starting the service means you intend to use it, so an idle gap
    should not cost a cold reload. The cost is that a loaded model holds its full size in
    GPU-wired memory (~19GB for qwen3-coder:30b) until you act. Free it with
    './scripts/Stop-Ollama.ps1' or './scripts/Dismount-LocalModel.ps1', or pass a duration
    like '1h' or '10m' for time-based unloading.

.PARAMETER MaxLoadedModels
    Sets OLLAMA_MAX_LOADED_MODELS. Default 1. With an infinite keep-alive nothing evicts
    a model on a timer, so without a cap they accumulate - qwen3-coder:30b plus
    gpt-oss:20b is ~33GB resident. A cap of 1 makes loading a model swap out the previous
    one. Pass 0 to leave it unset and use Ollama's own default.

.PARAMETER KvCacheType
    KV cache quantization. Default 'q8_0', which roughly halves KV RAM at long context.

.PARAMETER FlashAttention
    Faster attention kernel. Default $true.

.PARAMETER ContextLength
    Sets OLLAMA_CONTEXT_LENGTH. Omitted values reuse the saved setting; initially unset.
    Pass 0 to return to Ollama's default. A larger window requires more memory.

.PARAMETER NoEnvironment
    Do not rewrite configuration. Reuse the saved plist if present, otherwise use
    Homebrew's service definition. This does not reset settings to factory defaults.

.PARAMETER Restart
    Restart even when the API already answers. Restart-Ollama.ps1 forwards to this mode.

.PARAMETER TimeoutSeconds
    How long to wait for the API to answer after starting.

.EXAMPLE
    ./scripts/Start-Ollama.ps1

    Applies the default knobs and starts the service for this session only.

.EXAMPLE
    ./scripts/Start-Ollama.ps1 -ContextLength 65536

    Same, with a 64k context window - what you want before an agent session.

.EXAMPLE
    ./scripts/Start-Ollama.ps1 -KeepAlive 1h

    Go back to time-based unloading: weights are released an hour after the last request.

.NOTES
    Stop it again with ./scripts/Stop-Ollama.ps1, which also removes any login item.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$AtLogin,
    [string]$KeepAlive,
    [ValidateSet('f16', 'q8_0', 'q4_0')]
    [string]$KvCacheType,
    [bool]$FlashAttention,
    [ValidateRange(0, 2147483647)]
    [int]$ContextLength,
    [ValidateRange(0, 2147483647)]
    [int]$MaxLoadedModels,
    [switch]$NoEnvironment,
    [switch]$Restart,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 60,
    [string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$settings = Get-OllamaServiceSettings
if (-not $PSBoundParameters.ContainsKey('KeepAlive')) { $KeepAlive = $settings.KeepAlive }
if (-not $PSBoundParameters.ContainsKey('KvCacheType')) { $KvCacheType = $settings.KvCacheType }
if (-not $PSBoundParameters.ContainsKey('FlashAttention')) { $FlashAttention = $settings.FlashAttention }
if (-not $PSBoundParameters.ContainsKey('ContextLength')) { $ContextLength = $settings.ContextLength }
if (-not $PSBoundParameters.ContainsKey('MaxLoadedModels')) { $MaxLoadedModels = $settings.MaxLoadedModels }

if (-not $BaseUrl -and -not $env:OLLAMA_HOST) {
    $savedEnvironment = Get-SavedOllamaEnvironment
    if ($savedEnvironment.Contains('OLLAMA_HOST')) { $BaseUrl = $savedEnvironment['OLLAMA_HOST'] }
}
$BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl
Assert-OllamaServiceHost -BaseUrl $BaseUrl

$existing = Get-OllamaVersion -BaseUrl $BaseUrl
if ($existing -and -not $Restart -and -not $AtLogin) {
    Write-Host "Ollama is already running at $BaseUrl (v$existing)." -ForegroundColor Green
    Write-Detail 'To apply different knobs to a running server, use ./scripts/Restart-Ollama.ps1'
    return
}

$action = if ($Restart -or $existing) { 'Restart Ollama and apply service configuration' } else { 'Configure and start Ollama' }
if (-not $PSCmdlet.ShouldProcess("$BaseUrl (start at login: $AtLogin)", $action)) { return }

if ($NoEnvironment) {
    Write-Step 'Keeping existing service configuration (-NoEnvironment)'
}
else {
    Write-Step 'Saving persistent service configuration'
    Set-OllamaServiceKnob -KeepAlive $KeepAlive -KvCacheType $KvCacheType `
        -FlashAttention $FlashAttention -ContextLength $ContextLength `
        -MaxLoadedModels $MaxLoadedModels -BaseUrl $BaseUrl -Confirm:$false
}

# brew services start itself skips an already running on-demand service.
Stop-OllamaService -BaseUrl $BaseUrl -Confirm:$false
Write-Step "Starting Ollama ($(if ($AtLogin) { 'brew services start - registers at login' } else { 'brew services run - this session only' }))"
Start-OllamaService -AtLogin:$AtLogin -Confirm:$false

Write-Detail "Waiting up to ${TimeoutSeconds}s for the API..."
$version = Wait-OllamaApi -BaseUrl $BaseUrl -TimeoutSeconds $TimeoutSeconds
if (-not $version) {
    throw "Ollama did not answer on $BaseUrl within ${TimeoutSeconds}s. Check 'brew services list' and ~/Library/Logs/local-agents/ollama.log."
}
$service = Get-BrewOllamaServiceInfo
if (-not $service.running -or [bool]$service.registered -ne [bool]$AtLogin) {
    throw 'Ollama answered, but Homebrew did not reach the requested running/login-registration state.'
}
Write-Ok "server up (v$version)"
