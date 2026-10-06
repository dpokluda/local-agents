#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . "$repo/scripts/_common.ps1"
    . "$repo/scripts/_fedora.ps1"
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
    function winget { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function dnf { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function rpm { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function sudo { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function id { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function systemctl { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function copilot { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function du { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }

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

Describe 'Keep-alive request encoding' {
    It 'returns an integer for <Value>' -ForEach @(
        @{ Value = '-1'; Expected = -1 }
        @{ Value = '0'; Expected = 0 }
        @{ Value = '300'; Expected = 300 }
    ) {
        $result = ConvertTo-OllamaKeepAlive -KeepAlive $Value
        $result | Should -BeOfType ([int])
        $result | Should -Be $Expected
    }
    It 'keeps <Value> as a duration string' -ForEach @(
        @{ Value = '1h' }
        @{ Value = '10m' }
        @{ Value = '-1s' }
        @{ Value = '1.5' }
    ) {
        $result = ConvertTo-OllamaKeepAlive -KeepAlive $Value
        $result | Should -BeOfType ([string])
        $result | Should -Be $Value
    }
    It 'treats empty input as unset' {
        ConvertTo-OllamaKeepAlive -KeepAlive '' | Should -BeNullOrEmpty
        ConvertTo-OllamaKeepAlive -KeepAlive $null | Should -BeNullOrEmpty
    }
    It 'serializes -1 as an unquoted JSON number' {
        # Ollama parses a quoted integer as a Go duration and returns
        # 400 time: missing unit in duration "-1". The number form is what works.
        $body = @{ keep_alive = (ConvertTo-OllamaKeepAlive -KeepAlive '-1') } | ConvertTo-Json -Compress
        $body | Should -BeLike '*"keep_alive":-1*'
        $body | Should -Not -BeLike '*"keep_alive":"-1"*'
    }
    It 'serializes a duration as a quoted JSON string' {
        $body = @{ keep_alive = (ConvertTo-OllamaKeepAlive -KeepAlive '1h') } | ConvertTo-Json -Compress
        $body | Should -BeLike '*"keep_alive":"1h"*'
    }
    It 'sends the saved -1 setting as a number in a real request body' {
        Set-Variable IsMacOS -Value $true -Force
        Set-Variable IsWindows -Value $false -Force
        Set-Variable IsLinux -Value $false -Force
        Mock Get-SavedOllamaEnvironment { [ordered]@{ OLLAMA_KEEP_ALIVE = '-1' } }
        Mock Get-OllamaServerEnvironment { @{ Source = 'none'; Values = [ordered]@{} } }
        $state = @{ Raw = $null }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100 }) } }
            $state.Raw = $Body
            [pscustomobject]@{ eval_count = 50; eval_duration = 1000000000 }
        }
        & "$repo/scripts/Test-LocalStack.ps1" -SkipToolCheck -BaseUrl 'http://localhost:11434'
        $LASTEXITCODE | Should -Be 0
        $state.Raw | Should -Not -BeNullOrEmpty
        # Assert on the raw JSON text: ConvertFrom-Json would erase the quoting
        # distinction that caused the 400.
        ($state.Raw -replace '\s', '') | Should -BeLike '*"keep_alive":-1*'
        ($state.Raw | ConvertFrom-Json).keep_alive | Should -Be -1
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

Describe 'Windows native installation' {
    BeforeEach {
        Set-Variable IsMacOS -Value $false -Force
        Set-Variable IsWindows -Value $true -Force
        Set-Variable IsLinux -Value $false -Force
        $state = @{ Installed = $false }
        Mock Resolve-OllamaCommand { if ($state.Installed) { 'ollama' } }
        Mock winget {
            $state.Installed = $Arguments[0] -eq 'install'
            $global:LASTEXITCODE = 0
        }
        Mock Invoke-RestMethod { throw 'Server not running' }
        Mock Get-SavedOllamaEnvironment { throw 'Must not read the Mac plist' }
        Mock brew { throw 'Must not call Homebrew' }
    }
    It 'installs the exact WinGet package without changing Mac configuration' {
        & "$repo/scripts/Install-LocalAgents.ps1"
        Should -Invoke winget -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'install --id Ollama.Ollama --exact --source winget' }
        Should -Invoke Get-SavedOllamaEnvironment -Times 0
        Should -Invoke brew -Times 0
    }
    It 'leaves an existing CLI alone' {
        $state.Installed = $true
        & "$repo/scripts/Install-LocalAgents.ps1" -SkipService
        Should -Invoke winget -Times 0
    }
    It 'does not install or uninstall in WhatIf mode' {
        & "$repo/scripts/Install-LocalAgents.ps1" -WhatIf
        & "$repo/scripts/Uninstall-LocalAgents.ps1" -WhatIf
        Should -Invoke winget -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'rejects Mac-only options before installation' {
        { & "$repo/scripts/Install-LocalAgents.ps1" -AtLogin } | Should -Throw '*macOS-only*'
        { & "$repo/scripts/Install-LocalAgents.ps1" -InstallLmStudio } | Should -Throw '*macOS-only*'
        Should -Invoke winget -Times 0
    }
    It 'propagates package-manager failures' {
        Mock winget { $global:LASTEXITCODE = 9 }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*exit code 9*'
        { & "$repo/scripts/Uninstall-LocalAgents.ps1" -Confirm:$false } | Should -Throw '*exit code 9*'
    }
    It 'does not claim the CLI is usable when WinGet returns success without it' {
        Mock winget { $global:LASTEXITCODE = 0 }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*CLI was not found*'
    }
    It 'refuses an uninstall while the server is answering' {
        Mock Invoke-RestMethod { [pscustomobject]@{ version = 'test' } }
        { & "$repo/scripts/Uninstall-LocalAgents.ps1" -Confirm:$false } | Should -Throw '*Quit the Ollama tray*'
        Should -Invoke winget -Times 0
    }
    It 'requests silent uninstall without the vendor model-deletion checkbox' {
        Mock Remove-Item { throw 'Must not delete directories' }
        & "$repo/scripts/Uninstall-LocalAgents.ps1" -Confirm:$false
        Should -Invoke winget -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'uninstall --id Ollama.Ollama --exact --silent' }
        Should -Invoke Remove-Item -Times 0
    }
    It 'gives native app guidance instead of pretending to manage a Windows service' {
        { & "$repo/scripts/Start-Ollama.ps1" } | Should -Throw '*Start menu*'
        { & "$repo/scripts/Restart-Ollama.ps1" } | Should -Throw '*tray app*'
        { & "$repo/scripts/Stop-Ollama.ps1" } | Should -Throw '*tray menu*'
        Should -Invoke Get-SavedOllamaEnvironment -Times 0
    }
}

Describe 'Windows CLI lookup and explicit model choice' {
    BeforeEach {
        Set-Variable IsMacOS -Value $false -Force
        Set-Variable IsWindows -Value $true -Force
        Set-Variable IsLinux -Value $false -Force
    }
    It 'finds the standard installed executable before PATH is refreshed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'ollama' }
        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $TestDrive
            $directory = Join-Path $TestDrive 'Programs' 'Ollama'
            $null = New-Item -ItemType Directory $directory -Force
            $path = Join-Path $directory 'ollama.exe'
            Set-Content $path ''
            Resolve-OllamaCommand | Should -Be $path
        }
        finally { $env:LOCALAPPDATA = $saved }
    }
    It 'launches the explicitly selected minimal model and restores provider settings' {
        $state = @{ Model = $null; WireApi = $null }
        $saved = $env:COPILOT_PROVIDER_MODEL_ID
        Mock Get-Command { [pscustomobject]@{ Source = 'copilot' } } -ParameterFilter { $Name -eq 'copilot' }
        Mock copilot {
            $state.Model = $env:COPILOT_PROVIDER_MODEL_ID
            $state.WireApi = $env:COPILOT_PROVIDER_WIRE_API
        }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            [pscustomobject]@{ models = @([pscustomobject]@{ name = 'gemma4:e4b' }) }
        }
        & "$repo/scripts/Start-LocalCopilot.ps1" -Model 'gemma4:e4b'
        $state.Model | Should -Be 'gemma4:e4b'
        $state.WireApi | Should -Be 'completions'
        $env:COPILOT_PROVIDER_MODEL_ID | Should -Be $saved
        $LocalAgentDefaults.Model | Should -Be 'qwen3-coder:30b'
    }
}

Describe 'Fedora package and service paths' {
    BeforeEach {
        Set-Variable IsMacOS -Value $false -Force
        Set-Variable IsWindows -Value $false -Force
        Set-Variable IsLinux -Value $true -Force
        $state = @{ Installed = $false; Active = $false; Answering = $false }
        Mock Get-Content { "ID=fedora`nVERSION_ID=43`n" } -ParameterFilter { $LiteralPath -eq '/etc/os-release' }
        Mock Resolve-OllamaCommand { $null }
        Mock rpm { $global:LASTEXITCODE = if ($state.Installed) { 0 } else { 1 } }
        Mock id { $global:LASTEXITCODE = 0; '1000' }
        Mock dnf { $state.Installed = $Arguments[0] -eq 'install'; $global:LASTEXITCODE = 0 }
        Mock sudo {
            $command = $Arguments[0]
            $forward = @($Arguments | Select-Object -Skip 1)
            & $command @forward
        }
        Mock systemctl {
            if ($Arguments[0] -eq 'is-active') {
                $global:LASTEXITCODE = if ($state.Active) { 0 } else { 3 }
            }
            else {
                $state.Active = $Arguments[0] -in @('start', 'restart')
                $state.Answering = $state.Active
                $global:LASTEXITCODE = 0
            }
        }
        Mock Invoke-RestMethod {
            if ($state.Answering) { return [pscustomobject]@{ version = 'test' } }
            throw 'Server not running'
        }
        Mock Wait-OllamaApi { if ($state.Answering) { 'test' } }
        Mock Get-SavedOllamaEnvironment { throw 'Must not read the Mac plist' }
    }
    It 'uses DNF and starts the packaged service without changing boot policy' {
        & "$repo/scripts/Install-LocalAgents.ps1"
        $state.Installed | Should -BeTrue
        $state.Active | Should -BeTrue
        Should -Invoke sudo -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'dnf install ollama' }
        Should -Invoke systemctl -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'start ollama.service' }
        Should -Invoke systemctl -Times 0 -ParameterFilter { $Arguments[0] -in @('enable', 'disable') }
        Should -Invoke Get-SavedOllamaEnvironment -Times 0
    }
    It 'can skip starting the service' {
        & "$repo/scripts/Install-LocalAgents.ps1" -SkipService
        $state.Installed | Should -BeTrue
        Should -Invoke systemctl -Times 0
    }
    It 'is non-mutating in WhatIf mode, even before the RPM is installed' {
        & "$repo/scripts/Install-LocalAgents.ps1" -WhatIf
        & "$repo/scripts/Restart-Ollama.ps1" -WhatIf
        $state.Installed = $true
        & "$repo/scripts/Uninstall-LocalAgents.ps1" -WhatIf
        Should -Invoke sudo -Times 0
        Should -Invoke dnf -Times 0
        Should -Invoke systemctl -Times 0 -ParameterFilter { $Arguments[0] -ne 'is-active' }
    }
    It 'does not use sudo when already root' {
        Mock id { $global:LASTEXITCODE = 0; '0' }
        & "$repo/scripts/Install-LocalAgents.ps1" -SkipService
        Should -Invoke dnf -Times 1
        Should -Invoke sudo -Times 0
    }
    It 'rejects unsupported distributions and old Fedora versions before mutations' {
        Mock Get-Content { "ID=ubuntu`nVERSION_ID=44`n" } -ParameterFilter { $LiteralPath -eq '/etc/os-release' }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*Fedora 42*'
        Mock Get-Content { "ID=fedora`nVERSION_ID=41`n" } -ParameterFilter { $LiteralPath -eq '/etc/os-release' }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*Fedora 42*'
        Should -Invoke sudo -Times 0
    }
    It 'accepts quoted Fedora release fields' {
        Mock Get-Content { "ID=`"fedora`"`nVERSION_ID=`"42`"`n" } -ParameterFilter { $LiteralPath -eq '/etc/os-release' }
        { Assert-FedoraHost } | Should -Not -Throw
    }
    It 'distinguishes a failed RPM query from a missing package' {
        Mock rpm { $global:LASTEXITCODE = 2 }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*rpm could not query*'
        Should -Invoke sudo -Times 0
    }
    It 'does not overwrite a non-RPM installation' {
        Mock Resolve-OllamaCommand { '/opt/ollama/bin/ollama' }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*outside the Fedora*'
        Should -Invoke sudo -Times 0
    }
    It 'stops on DNF failure rather than starting the service' {
        Mock dnf { $global:LASTEXITCODE = 9 }
        { & "$repo/scripts/Install-LocalAgents.ps1" } | Should -Throw '*exit code 9*'
        Should -Invoke systemctl -Times 0
    }
    It 'restarts and stops without enabling or disabling boot startup' {
        $state.Installed = $true
        $state.Active = $true
        $state.Answering = $true
        & "$repo/scripts/Restart-Ollama.ps1"
        & "$repo/scripts/Stop-Ollama.ps1"
        Should -Invoke systemctl -Times 1 -ParameterFilter { $Arguments[0] -eq 'restart' }
        Should -Invoke systemctl -Times 1 -ParameterFilter { $Arguments[0] -eq 'stop' }
        Should -Invoke systemctl -Times 0 -ParameterFilter { $Arguments[0] -in @('enable', 'disable') }
    }
    It 'rejects remote service control, Mac tuning, and foreign servers' {
        $state.Installed = $true
        { & "$repo/scripts/Start-Ollama.ps1" -BaseUrl 'http://remote-test:11434' } | Should -Throw '*loopback*'
        { & "$repo/scripts/Restart-Ollama.ps1" -ContextLength 65536 } | Should -Throw '*macOS-only*'
        { & "$repo/scripts/Start-Ollama.ps1" -AtLogin } | Should -Throw '*macOS-only*'
        $state.Answering = $true
        { & "$repo/scripts/Start-Ollama.ps1" } | Should -Throw '*externally managed*'
        Should -Invoke sudo -Times 0
    }
    It 'stops on service failure and does not claim readiness' {
        $state.Installed = $true
        Mock sudo { $global:LASTEXITCODE = 9 }
        { & "$repo/scripts/Start-Ollama.ps1" } | Should -Throw '*exit code 9*'
        Should -Invoke Wait-OllamaApi -Times 0
    }
    It 'removes the RPM after stopping but never deletes model directories' {
        $state.Installed = $true
        $state.Active = $true
        $state.Answering = $true
        Mock Remove-Item { throw 'Must not delete directories' }
        & "$repo/scripts/Uninstall-LocalAgents.ps1" -Confirm:$false
        $state.Installed | Should -BeFalse
        $state.Active | Should -BeFalse
        Should -Invoke dnf -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'remove ollama' }
        Should -Invoke Remove-Item -Times 0
    }
    It 'does not uninstall if the API still answers after stopping the service' {
        $state.Installed = $true
        $state.Active = $true
        $state.Answering = $true
        Mock systemctl { $global:LASTEXITCODE = 0 }
        { & "$repo/scripts/Uninstall-LocalAgents.ps1" -Confirm:$false } | Should -Throw '*still answers*'
        Should -Invoke dnf -Times 0
    }
}

Describe 'Portable client diagnostics' {
    BeforeEach {
        Mock Get-SavedOllamaEnvironment { throw 'Must not read local saved settings' }
        Mock du { throw 'Must not measure client disk' }
    }
    It 'continues to use saved keep-alive for a local Mac' {
        Set-Variable IsMacOS -Value $true -Force
        Mock Get-SavedOllamaEnvironment { [ordered]@{ OLLAMA_KEEP_ALIVE = '20m' } }
        Mock Get-OllamaServerEnvironment { @{ Source = 'none'; Values = [ordered]@{} } }
        $state = @{ Body = $null }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100 }) } }
            $state.Body = $Body | ConvertFrom-Json
            [pscustomobject]@{ eval_count = 50; eval_duration = 1000000000 }
        }
        & "$repo/scripts/Test-LocalStack.ps1" -SkipToolCheck -BaseUrl 'http://localhost:11434'
        $LASTEXITCODE | Should -Be 0
        $state.Body.keep_alive | Should -Be '20m'
    }
    It 'leaves native keep-alive alone and skips Mac diagnostics on <Platform>' -ForEach @(
        @{ Platform = 'Windows'; Mac = $false; Windows = $true; Linux = $false; Endpoint = 'http://localhost:11434' }
        @{ Platform = 'Fedora'; Mac = $false; Windows = $false; Linux = $true; Endpoint = 'http://localhost:11434' }
        @{ Platform = 'remote from Mac'; Mac = $true; Windows = $false; Linux = $false; Endpoint = 'http://remote-test:11434' }
    ) {
        Set-Variable IsMacOS -Value $Mac -Force
        Set-Variable IsWindows -Value $Windows -Force
        Set-Variable IsLinux -Value $Linux -Force
        $state = @{ Body = $null }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100 }) } }
            $state.Body = $Body | ConvertFrom-Json
            [pscustomobject]@{ eval_count = 50; eval_duration = 1000000000 }
        }
        & "$repo/scripts/Test-LocalStack.ps1" -SkipToolCheck -BaseUrl $Endpoint
        $LASTEXITCODE | Should -Be 0
        $state.Body.PSObject.Properties.Name | Should -Not -Contain 'keep_alive'
        & "$repo/scripts/Test-LocalStack.ps1" -SkipToolCheck -KeepAlive '0' -BaseUrl $Endpoint
        $state.Body.keep_alive | Should -Be '0'
        Should -Invoke Get-SavedOllamaEnvironment -Times 0
    }
    It 'deletes through the selected API and reports unknown disk savings on <Platform>' -ForEach @(
        @{ Platform = 'Windows'; Mac = $false; Endpoint = 'http://localhost:11434' }
        @{ Platform = 'remote Mac'; Mac = $true; Endpoint = 'http://remote-test:11434' }
    ) {
        Set-Variable IsMacOS -Value $Mac -Force
        $state = @{ DeletedAt = $null }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = 'test' } }
            if ($Uri -like '*/api/ps') { return [pscustomobject]@{ models = @() } }
            if ($Method -eq 'Delete') { $state.DeletedAt = $Uri; return }
            [pscustomobject]@{ models = @([pscustomobject]@{ name = 'test:latest'; size = 100 }) }
        }
        $output = & "$repo/scripts/Remove-LocalModel.ps1" -Model 'test:latest' -BaseUrl $Endpoint -Confirm:$false 6>&1 | Out-String
        $state.DeletedAt | Should -Be "$Endpoint/api/delete"
        $output | Should -Match 'Reclaimed: unknown'
        Should -Invoke du -Times 0
        Should -Invoke Get-SavedOllamaEnvironment -Times 0
    }
}
