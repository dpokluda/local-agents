#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . "$repo/scripts/_common.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$repo/scripts/Test-LocalStack.ps1", [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function ollama { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function brew { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function launchctl { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function plutil { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function sysctl { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }

    function New-ToolStream {
        @'
data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_current_","arguments":"{\"loc"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"weather","arguments":"ation\":\"Prague\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

'@
    }
    function New-ReplyStream {
        @'
data: {"choices":[{"index":0,"delta":{"content":"It is 17 C in Prague."},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]

'@
    }
}

Describe 'Shared connection helpers' {
    It 'normalizes host:port and the OpenAI suffix' {
        Resolve-LocalAgentBaseUrl ' localhost:11434/v1/ ' | Should -Be 'http://localhost:11434'
        Resolve-LocalAgentBaseUrl 'http://[::1]:11434/v1' | Should -Be 'http://[::1]:11434'
    }
    It 'rejects unsupported URLs' {
        foreach ($url in 'file:///tmp/test', 'http://localhost:11434/v2', 'http://user:pass@localhost:11434') {
            { Resolve-LocalAgentBaseUrl $url } | Should -Throw
        }
    }
    It 'normalizes tagless model names without confusing registry ports' {
        Resolve-OllamaModelTag 'qwen3' | Should -Be 'qwen3:latest'
        Resolve-OllamaModelTag 'registry:5000/team/model' | Should -Be 'registry:5000/team/model:latest'
        Resolve-OllamaModelTag 'qwen3:4b' | Should -Be 'qwen3:4b'
    }
    It 'routes CLI calls to the selected server and restores the environment on failure' {
        $saved = $env:OLLAMA_HOST
        try {
            $env:OLLAMA_HOST = 'http://old-server:11434'
            Mock ollama {
                $env:OLLAMA_HOST | Should -Be 'http://selected-server:21434'
                $global:LASTEXITCODE = 9
            }
            { Invoke-OllamaCli -BaseUrl 'selected-server:21434' -ArgumentList @('pull', 'test:latest') } | Should -Throw '*exit code 9*'
            $env:OLLAMA_HOST | Should -Be 'http://old-server:11434'
        }
        finally { $env:OLLAMA_HOST = $saved }
    }
}

Describe 'Model synchronization' {
    BeforeEach {
        $state = @{ Tags = @('gemma4:e4b') }
        Mock Invoke-RestMethod {
            [pscustomobject]@{ models = @($state.Tags | ForEach-Object { [pscustomobject]@{ name = $_; size = 100 } }) }
        }
        Mock ollama {
            if ($Arguments[0] -eq 'pull') { $state.Tags += $Arguments[1] }
            elseif ($Arguments[0] -eq 'rm') { $state.Tags = @($state.Tags | Where-Object { $_ -cne $Arguments[1] }) }
            $global:LASTEXITCODE = 0
        }
    }
    It 'allows a no-op sync and does not download existing models' {
        { & "$repo/scripts/Sync-Models.ps1" -Tier minimal } | Should -Not -Throw
        Should -Invoke ollama -Times 0
    }
    It 'allows an unknown-size custom tag' {
        & "$repo/scripts/Sync-Models.ps1" -Tag 'custom:4b'
        $state.Tags | Should -Contain 'custom:4b'
    }
    It 'pulls a first model into an empty store' {
        $state.Tags = @()
        & "$repo/scripts/Sync-Models.ps1" -Tier minimal
        $state.Tags | Should -Contain 'gemma4:e4b'
    }
    It 'does not mutate in WhatIf or ListOnly mode, including prune' {
        $state.Tags = @('unrelated:latest')
        & "$repo/scripts/Sync-Models.ps1" -Tier minimal -Prune -WhatIf
        & "$repo/scripts/Sync-Models.ps1" -Tier minimal -Prune -ListOnly
        Should -Invoke ollama -Times 0
    }
    It 'prunes through the selected endpoint only after the requested models exist' {
        $state.Tags += 'unrelated:latest'
        Mock ollama {
            $env:OLLAMA_HOST | Should -Be 'http://selected-server:21434'
            $Arguments | Should -Be @('rm', 'unrelated:latest')
            $state.Tags = @('gemma4:e4b')
            $global:LASTEXITCODE = 0
        }
        & "$repo/scripts/Sync-Models.ps1" -Tier minimal -Prune -BaseUrl 'selected-server:21434' -Confirm:$false
        Should -Invoke ollama -Times 1
    }
    It 'fails verification and refuses to prune if a pull did not install the model' {
        $state.Tags = @('unrelated:latest')
        Mock ollama { $global:LASTEXITCODE = 0 }
        { & "$repo/scripts/Sync-Models.ps1" -Tier minimal -Prune -Confirm:$false } | Should -Throw '*Pruning was not attempted*'
        Should -Invoke ollama -Times 0 -ParameterFilter { $Arguments[0] -eq 'rm' }
    }
    It 'uses high confirmation impact for the destructive operation only' {
        $syncAst = [System.Management.Automation.Language.Parser]::ParseFile(
            "$repo/scripts/Sync-Models.ps1", [ref]$null, [ref]$null)
        $remove = $syncAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-SyncModel'
        }, $false)
        . ([scriptblock]::Create($remove.Extent.Text))
        (Get-Command Remove-SyncModel).ScriptBlock.Attributes.ConfirmImpact | Should -Be 'High'
    }
}

Describe 'Streaming and tool schemas' {
    It 'keeps a flat tools array' {
        $body = @{ tools = @(New-WeatherTool | ForEach-Object { $_ }) } | ConvertTo-Json -Depth 15
        ($body | ConvertFrom-Json).tools.Count | Should -Be 1
        ($body | ConvertFrom-Json).tools[0].function.name | Should -Be 'get_current_weather'
    }
    It 'rejects malformed argument values' {
        foreach ($arguments in '{"location":[123]}', '{"location":17}', '{"location":""}', '{"location":"London"}',
            '{"location":"Prague","unit":null}', '{"location":"Prague","unit":"kelvin"}', '[]', 'null', 'broken') {
            (Test-ToolCallShape -FunctionName 'get_current_weather' -Arguments $arguments).Ok | Should -BeFalse
        }
        (Test-ToolCallShape -FunctionName 'get_current_weather' -Arguments '{"location":"Prague","unit":"celsius"}').Ok | Should -BeTrue
    }
    It 'reassembles fragmented tool-call names and JSON arguments' {
        $result = ConvertFrom-OpenAiEventStream (New-ToolStream)
        $result.Message.tool_calls[0].id | Should -Be 'call_1'
        $result.Message.tool_calls[0].function.name | Should -Be 'get_current_weather'
        $result.Message.tool_calls[0].function.arguments | Should -Be '{"location":"Prague"}'
    }
    It 'rejects truncated and error streams' {
        { ConvertFrom-OpenAiEventStream ((New-ToolStream) -replace 'data: \[DONE\]', '') } | Should -Throw '*Incomplete*'
        { ConvertFrom-OpenAiEventStream 'data: {"error":"model failed"}' } | Should -Throw '*Stream error*'
    }
    It 'rejects a non-streaming response to a streaming request' {
        Mock Invoke-WebRequest { @{ Headers = @{ 'Content-Type' = 'application/json' }; Content = '{}' } }
        { Invoke-OpenAiStream -Uri 'http://localhost:11434' -Body @{ stream = $true } -TimeoutSec 10 } | Should -Throw '*text/event-stream*'
    }
    It 'sends the reconstructed call ID and synthetic tool result back in a second streamed request' {
        Mock Invoke-WebRequest {
            $request = $Body | ConvertFrom-Json
            $request.stream | Should -BeTrue
            if ($request.messages.Count -eq 1) {
                return @{ Headers = @{ 'Content-Type' = 'text/event-stream' }; Content = New-ToolStream }
            }
            $request.messages[2].role | Should -Be 'tool'
            $request.messages[2].tool_call_id | Should -Be 'call_1'
            ($request.messages[2].content | ConvertFrom-Json).temperature | Should -Be 17
            return @{ Headers = @{ 'Content-Type' = 'text/event-stream' }; Content = New-ReplyStream }
        }
        (Invoke-OpenAiToolCheck -Uri 'http://localhost:11434' -ModelTag 'test:latest' -TimeoutSec 10).Ok | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 2
    }
}

Describe 'Readiness exit status' {
    BeforeEach {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100 }) } }
            throw 'Simulated load failure'
        }
    }
    It 'fails when a benchmark fails even with tools skipped' {
        & "$repo/scripts/Test-LocalStack.ps1" -SkipToolCheck -BaseUrl 'http://remote-test:11434'
        $LASTEXITCODE | Should -Be 1
    }
    It 'does not mark skipped inference as reachable' {
        $json = Join-Path $TestDrive 'results.json'
        & "$repo/scripts/Test-LocalStack.ps1" -SkipBenchmark -SkipToolCheck -JsonPath $json -BaseUrl 'http://remote-test:11434'
        $LASTEXITCODE | Should -Be 0
        (Get-Content $json -Raw | ConvertFrom-Json).results[0].Reachable | Should -BeFalse
    }
    It 'rejects partially unmatched model selectors' {
        { & "$repo/scripts/Test-LocalStack.ps1" -Model 'test:latest', 'missing:*' -BaseUrl 'http://remote-test:11434' } | Should -Throw '*missing:*'
    }
    It 'fails an explicitly requested context check when context is too small' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100; context_length = 4096 }) }
        }
        & "$repo/scripts/Test-LocalStack.ps1" -SkipBenchmark -SkipToolCheck -MinimumContextLength 65536 -BaseUrl 'http://remote-test:11434'
        $LASTEXITCODE | Should -Be 1
    }
    It 'passes the complete native, streamed-round-trip, benchmark, and context path' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/tags' -or $Uri -like '*/api/ps') {
                return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100; context_length = 65536 }) }
            }
            $request = $Body | ConvertFrom-Json
            if ($request.PSObject.Properties['tools']) {
                return '{"message":{"role":"assistant","tool_calls":[{"function":{"name":"get_current_weather","arguments":{"location":"Prague"}}}]}}' | ConvertFrom-Json
            }
            return [pscustomobject]@{ eval_count = 50; eval_duration = 1000000000; load_duration = 1000000; prompt_eval_count = 20 }
        }
        Mock Invoke-WebRequest {
            $request = $Body | ConvertFrom-Json
            $content = if ($request.messages.Count -eq 1) { New-ToolStream } else { New-ReplyStream }
            return @{ Headers = @{ 'Content-Type' = 'text/event-stream' }; Content = $content }
        }
        $json = Join-Path $TestDrive 'complete.json'
        & "$repo/scripts/Test-LocalStack.ps1" -MinimumContextLength 65536 -JsonPath $json -BaseUrl 'http://remote-test:11434'
        $LASTEXITCODE | Should -Be 0
        $row = (Get-Content $json -Raw | ConvertFrom-Json).results[0]
        $row.ToolsNative | Should -Be 'pass'
        $row.ToolsOpenAi | Should -Be 'pass'
        $row.TokensPerSecond | Should -Be 50
        $row.ContextLength | Should -Be 65536
    }
}

Describe 'Persistent service settings' {
    BeforeEach {
        $script:serviceFile = Join-Path $TestDrive ([guid]::NewGuid().ToString()) 'ollama.plist'
        Mock Get-OllamaServiceFile { $script:serviceFile }
        Mock Assert-OllamaServiceHost {}
        Mock Get-BrewOllamaServiceInfo { [pscustomobject]@{ service_name = 'homebrew.mxcl.ollama'; running = $false; registered = $false } }
        Mock Get-OllamaServerEnvironment { @{ Source = 'server process'; Values = [ordered]@{ OLLAMA_MODELS = 'disk with spaces/models' } } }
        $script:prefix = Join-Path $TestDrive 'opt' 'ollama'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:prefix 'bin') -Force
        Set-Content (Join-Path $script:prefix 'bin' 'ollama') ''
        Mock brew { $global:LASTEXITCODE = 0; $script:prefix }
        Mock plutil { $global:LASTEXITCODE = 0 }
        Mock launchctl { $global:LASTEXITCODE = 0 }
        # Keep generated logs inside Pester's isolated test directory.
        Set-Variable HOME -Value $TestDrive -Force
    }

    It 'writes actual plist overrides, preserves storage paths, and restores saved defaults' {
        Set-OllamaServiceKnob -KeepAlive '-1' -KvCacheType 'f16' -FlashAttention:$false -ContextLength 65536 -MaxLoadedModels 1
        $xml = [xml](Get-Content $script:serviceFile -Raw)
        $xml.SelectSingleNode('/plist/dict/array/string[1]').InnerText | Should -Be (Join-Path $script:prefix 'bin' 'ollama')
        $saved = Get-SavedOllamaEnvironment
        $saved['OLLAMA_FLASH_ATTENTION'] | Should -Be '0'
        $saved['OLLAMA_KV_CACHE_TYPE'] | Should -Be 'f16'
        $saved['OLLAMA_MODELS'] | Should -Be 'disk with spaces/models'
        (Get-OllamaServiceSettings).ContextLength | Should -Be 65536
        (Get-OllamaServiceSettings).FlashAttention | Should -BeFalse
        Should -Invoke launchctl -Times 5
    }
    It 'clears opt-in settings without reviving stale defaults' {
        Set-OllamaServiceKnob -KeepAlive '-1' -KvCacheType q8_0 -ContextLength 0 -MaxLoadedModels 0
        (Get-SavedOllamaEnvironment).Contains('OLLAMA_CONTEXT_LENGTH') | Should -BeFalse
        (Get-OllamaServiceSettings).MaxLoadedModels | Should -Be 0
    }
    It 'does not write files or change launchd in WhatIf mode' {
        Set-OllamaServiceKnob -KeepAlive '-1' -KvCacheType q8_0 -WhatIf
        Test-Path $script:serviceFile | Should -BeFalse
        Should -Invoke launchctl -Times 0
        Should -Invoke brew -Times 0
    }
    It 'passes the saved service file to both Homebrew startup modes' {
        $null = New-Item -ItemType Directory -Path (Split-Path $script:serviceFile) -Force
        Set-Content $script:serviceFile '<plist/>'
        Start-OllamaService
        Start-OllamaService -AtLogin
        Should -Invoke brew -Times 1 -ParameterFilter { $Arguments[1] -eq 'run' -and $Arguments[3] -eq "--file=$script:serviceFile" }
        Should -Invoke brew -Times 1 -ParameterFilter { $Arguments[1] -eq 'start' -and $Arguments[3] -eq "--file=$script:serviceFile" }
    }
    It 'does not continue after a failed stop or a foreign server remaining on the port' {
        Mock brew { $global:LASTEXITCODE = 3 }
        { Stop-OllamaService } | Should -Throw '*exit code 3*'
        Mock brew { $global:LASTEXITCODE = 0 }
        Mock Get-OllamaVersion { 'test' }
        { Stop-OllamaService } | Should -Throw '*still answers*'
    }
}

Describe 'Service startup entry points' {
    BeforeEach {
        Set-Variable IsMacOS -Value $true -Force
        Set-Variable HOME -Value $TestDrive -Force
        $state = @{ Running = $true; Registered = $false; Commands = [Collections.Generic.List[string]]::new() }
        Mock Invoke-RestMethod {
            if ($state.Running) { return [pscustomobject]@{ version = 'test' } }
            throw 'Connection refused'
        }
        Mock brew {
            $global:LASTEXITCODE = 0
            $state.Commands.Add(($Arguments -join ' '))
            switch ($Arguments[1]) {
                'stop' { $state.Running = $false; $state.Registered = $false }
                'start' { $state.Running = $true; $state.Registered = $true }
                'run' { $state.Running = $true }
                'info' { @{ service_name = 'homebrew.mxcl.ollama'; running = $state.Running; registered = $state.Registered } | ConvertTo-Json -Compress }
            }
        }
    }
    It 'restarts an on-demand server to enable login registration' {
        & "$repo/scripts/Start-Ollama.ps1" -AtLogin -NoEnvironment -BaseUrl 'http://localhost:11434'
        $state.Registered | Should -BeTrue
        $state.Commands[0] | Should -Be 'services stop ollama'
        $state.Commands[1] | Should -Be 'services start ollama'
    }
    It 'keeps an ordinary start idempotent when the server already answers' {
        & "$repo/scripts/Start-Ollama.ps1" -NoEnvironment -BaseUrl 'http://localhost:11434'
        $state.Commands.Count | Should -Be 0
    }
    It 'does not stop or reconfigure a service in WhatIf mode' {
        & "$repo/scripts/Restart-Ollama.ps1" -AtLogin -WhatIf -BaseUrl 'http://localhost:11434'
        $state.Commands.Count | Should -Be 0
        $state.Running | Should -BeTrue
    }
    It 'does not accidentally retain login registration on an on-demand restart' {
        $state.Registered = $true
        & "$repo/scripts/Restart-Ollama.ps1" -NoEnvironment -BaseUrl 'http://localhost:11434'
        $state.Registered | Should -BeFalse
        $state.Commands[1] | Should -Be 'services run ollama'
    }
}

Describe 'Budget and model pipeline' {
    It 'includes the default coder on a 36 GiB Mac using manifest sizes' {
        Set-Variable IsMacOS -Value $true -Force
        Mock sysctl { $global:LASTEXITCODE = 0; 36GB }
        $budget = & "$repo/scripts/Get-LocalAgentBudget.ps1"
        $budget.WeightBudgetGb | Should -Be 26
        $budget.ComfortableModels | Should -Match 'qwen3-coder:30b'
    }
    It 'returns a Model property usable by removal through property binding' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 1000000000; modified_at = '2026-10-05' }) }
        }
        $model = & "$repo/scripts/Get-LocalModel.ps1"
        $model.Model | Should -Be 'test:latest'
        $model.'Size(GB)' | Should -Be 1
        $binding = (Get-Command "$repo/scripts/Remove-LocalModel.ps1").Parameters['Model'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $binding.ValueFromPipelineByPropertyName | Should -BeTrue
    }
}
