$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Fail([string] $Message) { throw $Message }

function Get-SafeDirectory([string] $Path, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        Fail "$Label 必须是绝对路径。"
    }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\')
    $forbidden = @($root, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($forbidden | Where-Object { $_ -ieq $full }) {
        Fail "$Label 范围过大，已拒绝执行：$full"
    }
    return $full
}

function Test-ManagedFile([string] $Path, [string] $Marker) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return @([System.IO.File]::ReadAllLines($Path)) -contains $Marker
}

function Write-AtomicText([string] $Path, [string] $Content, [System.Text.Encoding] $Encoding) {
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.codex-rp-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, $Encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

if ($env:OS -ne 'Windows_NT' -and $env:CODEX_RP_TEST_PLATFORM -ne 'Windows') {
    Fail '此安装入口仅支持 Windows。'
}

$repoSlug = if ($env:CODEX_RP_REPO) { $env:CODEX_RP_REPO } else { 'ForceMind/codex-remote-provider-kit' }
$repoRef = if ($env:CODEX_RP_REF) { $env:CODEX_RP_REF } else { 'main' }
$requestedInstallDir = if ($env:CODEX_RP_INSTALL_DIR) { $env:CODEX_RP_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\CodexRemoteProviderKit' }
$requestedBinDir = if ($env:CODEX_RP_BIN_DIR) { $env:CODEX_RP_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'CodexRemoteProviderKit\bin' }
$installDir = Get-SafeDirectory $requestedInstallDir '安装目录'
$binDir = Get-SafeDirectory $requestedBinDir '命令目录'
$archiveUrl = if ($env:CODEX_RP_ARCHIVE_URL) { $env:CODEX_RP_ARCHIVE_URL } else { "https://github.com/$repoSlug/archive/refs/heads/$repoRef.zip" }
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-rp-' + [Guid]::NewGuid().ToString('N'))
$archiveFile = Join-Path $temporaryRoot 'source.zip'
$extractDir = Join-Path $temporaryRoot 'source'
$stagingDir = $installDir + '.new-' + [Guid]::NewGuid().ToString('N')
$backupDir = $installDir + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID
$launcher = Join-Path $binDir 'codex-rp.cmd'
$launcherScript = Join-Path $binDir 'codex-rp-launch.ps1'
$launcherMarker = 'rem Managed by codex-remote-provider-kit:windows'
$launcherScriptMarker = '# Managed by codex-remote-provider-kit:windows'
$launcherBackupDir = Join-Path $temporaryRoot 'launcher-backup'
$oldInstallMoved = $false
$newInstallActivated = $false
$launcherExisted = $false
$launcherScriptExisted = $false
$pathUpdated = $false
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalProcessPath = $env:Path

if ((Test-Path -LiteralPath $launcher) -and -not (Test-ManagedFile $launcher $launcherMarker)) {
    Fail "$launcher 已存在，且不由本套件管理。"
}
if ((Test-Path -LiteralPath $launcherScript) -and -not (Test-ManagedFile $launcherScript $launcherScriptMarker)) {
    Fail "$launcherScript 已存在，且不由本套件管理。"
}

try {
    [System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($launcherBackupDir) | Out-Null
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        $launcherExisted = $true
        Copy-Item -LiteralPath $launcher -Destination (Join-Path $launcherBackupDir 'codex-rp.cmd')
    }
    if (Test-Path -LiteralPath $launcherScript -PathType Leaf) {
        $launcherScriptExisted = $true
        Copy-Item -LiteralPath $launcherScript -Destination (Join-Path $launcherBackupDir 'codex-rp-launch.ps1')
    }

    Write-Host "正在下载 $repoSlug（$repoRef）……"
    if ($archiveUrl -match '^file://') {
        Copy-Item -LiteralPath ([Uri] $archiveUrl).LocalPath -Destination $archiveFile
    }
    elseif (Test-Path -LiteralPath $archiveUrl -PathType Leaf) {
        Copy-Item -LiteralPath $archiveUrl -Destination $archiveFile
    }
    else {
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archiveFile
    }
    Expand-Archive -LiteralPath $archiveFile -DestinationPath $extractDir -Force
    $sourceRoots = @(Get-ChildItem -LiteralPath $extractDir -Directory)
    if ($sourceRoots.Count -ne 1) { Fail '下载压缩包必须只包含一个顶层目录。' }
    $sourceRoot = $sourceRoots[0]
    $windowsEntry = Join-Path $sourceRoot.FullName 'platform\windows\codex-rp.ps1'
    $tokenHelper = Join-Path $sourceRoot.FullName 'platform\windows\get-provider-token.ps1'
    if (-not (Test-Path -LiteralPath $windowsEntry -PathType Leaf)) { Fail '下载内容缺少 Windows 管理入口。' }
    if (-not (Test-Path -LiteralPath $tokenHelper -PathType Leaf)) { Fail '下载内容缺少 Windows DPAPI 助手。' }

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $installDir)) | Out-Null
    [System.IO.Directory]::CreateDirectory($stagingDir) | Out-Null
    Get-ChildItem -LiteralPath $sourceRoot.FullName -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $stagingDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $installDir) {
        Move-Item -LiteralPath $installDir -Destination $backupDir
        $oldInstallMoved = $true
        Write-Host "旧版本已备份到：$backupDir"
    }
    Move-Item -LiteralPath $stagingDir -Destination $installDir
    $newInstallActivated = $true

    [System.IO.Directory]::CreateDirectory($binDir) | Out-Null
    $entryPath = Join-Path $installDir 'platform\windows\codex-rp.ps1'
    $escapedEntryPath = $entryPath.Replace("'", "''")
    $launcherScriptText = @(
        $launcherScriptMarker,
        "`$ErrorActionPreference = 'Stop'",
        "& '$escapedEntryPath' @args"
    ) -join "`r`n"
    $launcherText = @(
        '@echo off',
        $launcherMarker,
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-rp-launch.ps1" %*',
        'exit /b %ERRORLEVEL%'
    ) -join "`r`n"
    Write-AtomicText $launcherScript ($launcherScriptText + "`r`n") (New-Object System.Text.UTF8Encoding($true))
    Write-AtomicText $launcher ($launcherText + "`r`n") (New-Object System.Text.ASCIIEncoding)

    $pathEntries = @($originalUserPath -split ';' | Where-Object { $_ })
    if (-not ($pathEntries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('Path', (($pathEntries + $binDir) -join ';'), 'User')
        $pathUpdated = $true
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') })) {
        $env:Path = (@($env:Path, $binDir) | Where-Object { $_ }) -join ';'
    }
}
catch {
    $originalError = $_.Exception.Message
    $recoveryErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($pathUpdated) {
        try {
            [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
            $env:Path = $originalProcessPath
        }
        catch { $recoveryErrors.Add('恢复用户 PATH 失败：' + $_.Exception.Message) }
    }
    try {
        if ($launcherExisted) {
            Copy-Item -LiteralPath (Join-Path $launcherBackupDir 'codex-rp.cmd') -Destination $launcher -Force
        }
        elseif (Test-ManagedFile $launcher $launcherMarker) {
            Remove-Item -LiteralPath $launcher -Force
        }
        if ($launcherScriptExisted) {
            Copy-Item -LiteralPath (Join-Path $launcherBackupDir 'codex-rp-launch.ps1') -Destination $launcherScript -Force
        }
        elseif (Test-ManagedFile $launcherScript $launcherScriptMarker) {
            Remove-Item -LiteralPath $launcherScript -Force
        }
    }
    catch { $recoveryErrors.Add('恢复全局命令失败：' + $_.Exception.Message) }
    try {
        if ($newInstallActivated -and (Test-Path -LiteralPath $installDir)) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        if ($oldInstallMoved -and (Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $installDir)) {
            Move-Item -LiteralPath $backupDir -Destination $installDir
        }
    }
    catch { $recoveryErrors.Add('恢复旧安装目录失败：' + $_.Exception.Message) }
    if ($recoveryErrors.Count -gt 0) {
        $originalError += '；恢复时另有错误：' + ($recoveryErrors -join '；')
    }
    throw "Windows 安装失败，已尝试恢复原状态：$originalError"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
}

Write-Host "工具已安装到：$installDir"
Write-Host '重新打开终端后，可以在任意目录运行：codex-rp'
if ($env:CODEX_RP_NO_LAUNCH -ne '1') {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installDir 'platform\windows\codex-rp.ps1') menu
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '管理面板异常退出，但工具安装和旧版本备份均已保留；请重新运行 codex-rp。'
    }
}
