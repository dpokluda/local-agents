#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot prompt against a local model. Handy for quick sanity checks and for warming
    a model before a session.

.DESCRIPTION
    Sends a single non-streaming request to Ollama's native /api/chat and prints the
    reply. No conversation history, no tools - if you want a real chat UI see
    docs/chat-apps.md, and for an agent see docs/harnesses.md.

.PARAMETER Prompt
    The prompt. Accepts pipeline input.

.PARAMETER Model
    Ollama tag. Defaults to $env:LOCAL_AGENT_MODEL, then the default in _common.ps1.

.PARAMETER System
    Optional system message.

.PARAMETER Temperature
    Sampling temperature. Default 0.2 - low, because this is mostly used for checks.

.PARAMETER BaseUrl
    Ollama base URL. Defaults to $env:OLLAMA_HOST, then http://localhost:11434.

.PARAMETER TimeoutSeconds
    Request timeout. The first call after idle pays the full model load, so this is
    generous by default.

.EXAMPLE
    ./scripts/Invoke-LocalChat.ps1 'Explain the difference between a worktree and a clone.'

.EXAMPLE
    ./scripts/Invoke-LocalChat.ps1 'Write a regex for an ISO-8601 date.' -Model gemma4:e4b

.EXAMPLE
    ./scripts/Invoke-LocalChat.ps1 'ready?' | Out-Null

    Warms the default model before an offline session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
    [string]$Prompt,

    [string]$Model,

    [string]$System,

    [double]$Temperature = 0.2,

    [string]$BaseUrl,

    [int]$TimeoutSeconds = 300
)

begin {
    Set-StrictMode -Version Latest

    . "$PSScriptRoot/_common.ps1"

    $BaseUrl = Resolve-LocalAgentBaseUrl -BaseUrl $BaseUrl

    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $env:LOCAL_AGENT_MODEL }
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $LocalAgentDefaults.Model }

    $reachable = Test-OllamaReachable -BaseUrl $BaseUrl
}

process {
    if (-not $reachable) { return }

    $messages = @()
    if ($System) { $messages += @{ role = 'system'; content = $System } }
    $messages += @{ role = 'user'; content = $Prompt }

    $body = @{
        model    = $Model
        stream   = $false
        messages = $messages
        options  = @{ temperature = $Temperature }
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/api/chat" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    }
    catch {
        Write-Error "Request to $BaseUrl/api/chat failed for model '$Model': $(Get-HttpErrorDetail -ErrorRecord $_)"
        return
    }

    $response.message.content
}
