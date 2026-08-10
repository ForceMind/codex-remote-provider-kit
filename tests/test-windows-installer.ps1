$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-rp-installer-' + [Guid]::NewGuid().ToString('N'))
$sourceParent = Join-Path $testDir 'archive-source'
$sourceRoot = Join-Path $sourceParent 'codex-remote-provider-kit-main'
$archive = Join-Path $testDir 'source.zip'
$installDir = Join-Path $testDir '安装目录'
$binDir = Join-Path $testDir '命令目录'
$installer = Join-Path $repoDir 'install-windows.ps1'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalProcessPath = $env:Path

function Invoke-InstallerChild {
    $process = Start-Process -FilePath powershell.exe -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installer + '"')
    ) -Wait -PassThru
    return $process.ExitCode
}

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'platform\windows')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoDir 'platform\windows\codex-rp.ps1') -Destination (Join-Path $sourceRoot 'platform\windows\codex-rp.ps1')
    Copy-Item -LiteralPath (Join-Path $repoDir 'platform\windows\get-provider-token.ps1') -Destination (Join-Path $sourceRoot 'platform\windows\get-provider-token.ps1')
    Compress-Archive -LiteralPath $sourceRoot -DestinationPath $archive

    $env:CODEX_RP_TEST_PLATFORM = 'Windows'
    $env:CODEX_RP_ARCHIVE_URL = $archive
    $env:CODEX_RP_INSTALL_DIR = $installDir
    $env:CODEX_RP_BIN_DIR = $binDir
    $env:CODEX_RP_NO_LAUNCH = '1'

    & $installer
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'platform\windows\codex-rp.ps1'))) { throw 'Windows source was not installed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $binDir 'codex-rp.cmd'))) { throw 'Windows launcher was not installed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $binDir 'codex-rp-launch.ps1'))) { throw 'Unicode-safe Windows launcher helper was not installed.' }
    $launcherText = [System.IO.File]::ReadAllText((Join-Path $binDir 'codex-rp.cmd'))
    if ($launcherText.Contains($installDir)) { throw 'ASCII launcher unexpectedly embeds an absolute user path.' }
    if (-not $launcherText.Contains('%~dp0codex-rp-launch.ps1')) { throw 'ASCII launcher does not use its relative helper.' }

    [System.IO.File]::WriteAllText((Join-Path $installDir 'old-marker'), 'old')
    & $installer
    $backupFilter = (Split-Path -Leaf $installDir) + '.backup-*'
    $backup = Get-ChildItem -LiteralPath $testDir -Directory -Filter $backupFilter | Select-Object -First 1
    if (-not $backup) { throw 'Previous Windows install was not backed up.' }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.FullName 'old-marker'))) { throw 'Windows backup is incomplete.' }

    [System.IO.File]::WriteAllText((Join-Path $installDir 'restore-marker'), 'restore-me')
    $blockedBin = Join-Path $testDir 'blocked-bin'
    [System.IO.File]::WriteAllText($blockedBin, 'not a directory')
    $env:CODEX_RP_BIN_DIR = $blockedBin
    $failureExit = Invoke-InstallerChild
    if ($failureExit -eq 0) { throw 'Post-activation installer failure unexpectedly succeeded.' }
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'restore-marker'))) { throw 'Failed upgrade did not restore the previous install.' }

    $conflictInstall = Join-Path $testDir 'conflict-install'
    $conflictBin = Join-Path $testDir 'conflict-bin'
    [System.IO.Directory]::CreateDirectory($conflictBin) | Out-Null
    $conflictLauncher = Join-Path $conflictBin 'codex-rp.cmd'
    [System.IO.File]::WriteAllText($conflictLauncher, '@echo unrelated')
    $env:CODEX_RP_INSTALL_DIR = $conflictInstall
    $env:CODEX_RP_BIN_DIR = $conflictBin
    $conflictExit = Invoke-InstallerChild
    if ($conflictExit -eq 0) { throw 'Unmanaged launcher conflict unexpectedly succeeded.' }
    if ([System.IO.File]::ReadAllText($conflictLauncher) -ne '@echo unrelated') { throw 'Unmanaged launcher was modified.' }
    if (Test-Path -LiteralPath $conflictInstall) { throw 'Install directory was created despite launcher conflict.' }

    Write-Host 'Windows online installer: ok'
}
finally {
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    $env:Path = $originalProcessPath
    Remove-Item Env:CODEX_RP_TEST_PLATFORM -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_ARCHIVE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_INSTALL_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_BIN_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_RP_NO_LAUNCH -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force }
}
