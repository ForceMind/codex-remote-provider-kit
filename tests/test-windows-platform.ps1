$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-rp-test-' + [Guid]::NewGuid().ToString('N'))
$homeDir = Join-Path $testDir 'home'
$codexHome = Join-Path $homeDir '.codex'
$dataDir = Join-Path $testDir 'data'
$mockScript = Join-Path $testDir 'mock-codex.ps1'
    $isNativeWindows = ($env:OS -eq 'Windows_NT')
$mockCommand = if ($isNativeWindows) { Join-Path $testDir 'codex.cmd' } else { $mockScript }

$entry = Join-Path $repoDir 'platform\windows\codex-rp.ps1'

try {
    [System.IO.Directory]::CreateDirectory($codexHome) | Out-Null
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Remaining)
$ErrorActionPreference = 'Stop'
switch ($Remaining[0]) {
    '--version' { Write-Output 'codex-cli test'; exit 0 }
    'login' { Write-Output 'Logged in using ChatGPT'; exit 0 }
    'exec' {
        $index = [Array]::IndexOf($Remaining, '--output-last-message')
        if ($index -lt 0) { exit 2 }
        [System.IO.File]::WriteAllText($Remaining[$index + 1], "OK`n")
        exit 0
    }
    default { exit 2 }
}
'@ | Set-Content -LiteralPath $mockScript -Encoding UTF8
    if ($isNativeWindows) {
        '@echo off' + "`r`n" + 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mockScript + '" %*' + "`r`n" | Set-Content -LiteralPath $mockCommand -Encoding ASCII
    }

    $configFile = Join-Path $codexHome 'config.toml'
    $profileFile = Join-Path $codexHome 'third_party.config.toml'
    $originalConfig = @'
model_provider = 'openai'
model = "official-model"
model_reasoning_effort = "medium"

[features]
shell_tool = true
'@
    $originalProfile = $null
    [System.IO.File]::WriteAllText($configFile, $originalConfig)

    $env:CODEX_HOME = $codexHome
    $env:CODEX_RP_DATA_DIR = $dataDir
    $env:CODEX_RP_TEST_PLATFORM = 'Windows'
    $env:CODEX_RP_SKIP_CODEX_INSTALL = '1'
    $env:CODEX_RP_TEST_MODE = '1'
    $env:TEMP = $testDir
    $env:THIRD_PARTY_API_KEY = 'test_token'

    $expectedVersion = [System.IO.File]::ReadAllText((Join-Path $repoDir 'VERSION')).Trim()
    $versionOutput = (& $entry version | Out-String).Trim()
    if ($versionOutput -ne "codex-remote-provider-kit $expectedVersion") { throw "Unexpected kit version: $versionOutput" }
    $versionFlagOutput = (& $entry --version | Out-String).Trim()
    if ($versionFlagOutput -ne "codex-remote-provider-kit $expectedVersion") { throw "Unexpected --version output: $versionFlagOutput" }

    & $entry install -BaseUrl 'https://gateway.test/v1' -Model 'gpt-5.6-sol' -ProviderId 'third_party' -Reasoning 'high' -CodexBin $mockCommand
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'active\provider.key'))) { throw 'DPAPI credential was not created.' }
    $config = [System.IO.File]::ReadAllText($configFile)
    foreach ($expected in @(
        'model_provider = "third_party"',
        'model = "gpt-5.6-sol"',
        '[model_providers.third_party.auth]',
        'command = "',
        'get-provider-token.ps1'
    )) {
        if (-not $config.Contains($expected)) { throw "Missing config fragment: $expected" }
    }
    if ($config.Contains('env_key')) { throw 'Windows config unexpectedly uses env_key.' }
    if ($config.Contains('test_token')) { throw 'Plaintext API key leaked into Windows config.' }

    $statusOutput = (& $entry status *>&1 | Out-String)
    if ($statusOutput -notmatch '当前模式：third-party') { throw 'Third-party status was not detected.' }
    if ($statusOutput -notmatch '当前用户可解密') { throw 'DPAPI decryption was not verified.' }
    $statusJson = (& $entry status -Json | ConvertFrom-Json)
    if ($statusJson.mode -ne 'third-party') { throw 'JSON status did not report third-party mode.' }

    & $entry reconfigure -Model 'gpt-5.6-updated' -Reasoning 'medium'
    $config = [System.IO.File]::ReadAllText($configFile)
    if (-not $config.Contains('model = "gpt-5.6-updated"')) { throw 'Reconfigure did not update third-party model.' }
    if (-not $config.Contains('model_reasoning_effort = "medium"')) { throw 'Reconfigure did not update third-party reasoning.' }

    $env:CODEX_RP_CONFIRMATION = 'y'
    & $entry official
    $config = [System.IO.File]::ReadAllText($configFile)
    if ($config.Contains('model_provider = "third_party"')) { throw 'Official mode did not restore provider.' }
    if (-not $config.Contains("model_provider = 'openai'")) { throw 'Literal-string official provider was not restored.' }
    if (-not $config.Contains('model = "official-model"')) { throw 'Official model was not restored.' }
    if (-not $config.Contains('[model_providers.third_party.auth]')) { throw 'Managed provider block was unexpectedly removed.' }
    $officialStatus = (& $entry status *>&1 | Out-String)
    if ($officialStatus -notmatch '当前模式：official') { throw 'Official status was not detected.' }

    Remove-Item Env:CODEX_RP_CONFIRMATION
    & $entry third-party
    $thirdPartyConfig = [System.IO.File]::ReadAllText($configFile)
    & $entry test
    & $entry rotate-key

    [System.IO.File]::WriteAllText($configFile, $thirdPartyConfig.Replace('model_provider = "third_party"', 'model_provider = "external_provider"'))
    $externalStatus = (& $entry doctor *>&1 | Out-String)
    if ($externalStatus -notmatch '当前模式：external') { throw 'Doctor did not continue diagnostics for external configuration.' }
    & $entry third-party
    if ($LASTEXITCODE -eq 0) { throw 'External configuration was unexpectedly overwritten.' }
    & $entry reconfigure -Model 'gpt-5.6-updated'
    if ($LASTEXITCODE -eq 0) { throw 'External reconfigure unexpectedly succeeded.' }
    [System.IO.File]::WriteAllText($configFile, $thirdPartyConfig)

    $dryRunOutput = (& $entry uninstall -DryRun *>&1 | Out-String)
    if ($dryRunOutput -notmatch '回滚预演通过') { throw 'Rollback dry-run did not report success.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'active\provider.key'))) { throw 'Rollback dry-run modified the credential.' }

    $env:CODEX_RP_CONFIRMATION = 'RESTART_APP'
    $restartOutput = (& $entry restart-app *>&1 | Out-String)
    if ($restartOutput -notmatch '已模拟重启 ChatGPT') { throw 'Restart test mode did not run.' }

    $env:CODEX_RP_CONFIRMATION = 'ROLLBACK'
    & $entry rollback
    $rolledBackConfig = [System.IO.File]::ReadAllText($configFile)
    if (-not $rolledBackConfig.Contains("model_provider = 'openai'")) { throw 'Rollback did not restore the official provider.' }
    if (-not $rolledBackConfig.Contains('model = "official-model"')) { throw 'Rollback did not restore the official model.' }
    if (-not $rolledBackConfig.Contains('[features]')) { throw 'Rollback removed unrelated configuration.' }
    if ($rolledBackConfig.Contains('[model_providers.third_party]')) { throw 'Rollback retained the managed provider block.' }
    if (Test-Path -LiteralPath $profileFile) { throw 'Rollback did not remove the managed profile.' }
    if (Test-Path -LiteralPath (Join-Path $dataDir 'active')) { throw 'Active state still exists after rollback.' }
    if (-not (Get-ChildItem -LiteralPath (Join-Path $dataDir 'audit') -Directory -Filter 'state-*')) { throw 'Audit state was not retained.' }

    Write-Host 'Windows platform lifecycle: ok'
}
finally {
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_TEST_PLATFORM -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_SKIP_CODEX_INSTALL -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:TEMP -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_CONFIRMATION -ErrorAction SilentlyContinue
    Remove-Item Env:THIRD_PARTY_API_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force }
}
