[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'reconfigure', 'status', 'doctor', 'test', 'official', 'third-party', 'rotate-key', 'restart-app', 'rollback', 'uninstall', 'update', 'version', '-V', '--version', 'help')]
    [string] $Command = 'menu',

    [string] $BaseUrl = '',
    [string] $Model = 'gpt-5.6-sol',
    [string] $ProviderId = 'third_party',
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh')]
    [string] $Reasoning = 'high',
    [string] $CodexBin = '',
    [switch] $RotateKey,
    [switch] $Json,
    [switch] $DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CommandArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:ProvidedParameters = @{}
foreach ($parameterName in $PSBoundParameters.Keys) {
    $script:ProvidedParameters[$parameterName] = $true
}

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoDir = (Resolve-Path (Join-Path $script:ScriptDir '..\..')).Path
$script:VersionFile = Join-Path $script:RepoDir 'VERSION'
if (-not (Test-Path -LiteralPath $script:VersionFile -PathType Leaf)) { throw 'VERSION 文件缺失。' }
$script:KitVersion = [System.IO.File]::ReadAllText($script:VersionFile).Trim()
if ($script:KitVersion -notmatch '^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$') { throw 'VERSION 文件格式无效。' }
$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:DataDir = if ($env:CODEX_RP_DATA_DIR) { $env:CODEX_RP_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'CodexRemoteProviderKit' }
$script:ActiveDir = Join-Path $script:DataDir 'active'
$script:AuditDir = Join-Path $script:DataDir 'audit'
$script:ConfigFile = Join-Path $script:CodexHome 'config.toml'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Fail([string] $Message) {
    throw $Message
}

function Read-Confirmation([string] $Prompt) {
    if ($env:CODEX_RP_CONFIRMATION) { return $env:CODEX_RP_CONFIRMATION }
    return Read-Host $Prompt
}

function Show-Usage {
    Write-Host "Codex Remote Provider Kit（Windows）v$($script:KitVersion)"
    Write-Host ''
    @'
用法：
  codex-rp <命令> [PowerShell 参数]

命令：
  menu          打开中文管理面板（默认）
  install       安装/配置第三方 provider
  reconfigure   更新已安装第三方配置；增加 -RotateKey 可同时轮换密钥
  status        检查配置、DPAPI 凭据、Codex 与 ChatGPT 应用
  doctor        与 status 相同，外部配置时继续输出诊断
  test          执行一次最小化第三方 Codex 真实调用
  official      恢复安装前的官方默认模型配置
  third-party   重新启用第三方模型配置
  rotate-key    更新当前 Windows 用户的 DPAPI 加密密钥
  restart-app   明确重启 ChatGPT 桌面应用
  rollback      选择性移除本工具配置并删除加密密钥（支持 --dry-run）
  uninstall     rollback 的兼容别名
  version       显示套件版本
  update        Windows 不自动更新；显示安全更新指引

示例：
  codex-rp install -BaseUrl https://provider.example/v1 -Model gpt-5.6-sol
  codex-rp reconfigure -Model gpt-5.6-sol -Reasoning medium
  codex-rp status -Json
  codex-rp rollback --dry-run

脚本只修改 %USERPROFILE%\.codex 和当前用户的 DPAPI 凭据，不修改 ChatGPT
登录、workspace、Remote 配对或会话历史。切换后请重启桌面应用并新建会话。
'@ | Write-Host
}

$platformOk = ($env:OS -eq 'Windows_NT') -or ($env:CODEX_RP_TEST_PLATFORM -eq 'Windows')
if (-not $platformOk) {
    Fail '此入口仅支持 Windows。'
}

function Test-ProviderId([string] $Value) {
    return $Value -match '^[A-Za-z0-9_-]+$'
}

function Test-ModelName([string] $Value) {
    return $Value -match '^[A-Za-z0-9._-]+$'
}

function Test-ApiKey([string] $Value) {
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[A-Za-z0-9._~+/=-]+$')
}

function Test-BaseUrl([string] $Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.Query)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.Fragment)) { return $false }
    if ($uri.Host -match '(^|\.)example\.(com|org|net)$' -or $uri.Host -match '\.(example|invalid)$') { return $false }
    return $true
}

function ConvertTo-TomlString([string] $Value) {
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Read-ConfigLines([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path))
}

function Write-AtomicLines([string] $Path, [string[]] $Lines) {
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.codex-rp-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllLines($temporary, $Lines, $script:Utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Set-TopLevelString([string] $Path, [string] $Key, [string] $Value) {
    $lines = @(Read-ConfigLines $Path)
    $output = New-Object 'System.Collections.Generic.List[string]'
    $inTop = $true
    $wrote = $false
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*='
    foreach ($line in $lines) {
        if ($inTop -and $line -match '^\s*\[') {
            if (-not $wrote) {
                $output.Add($Key + ' = "' + (ConvertTo-TomlString $Value) + '"')
                $wrote = $true
            }
            $inTop = $false
        }
        if ($inTop -and $line -match $keyPattern) {
            if (-not $wrote) {
                $output.Add($Key + ' = "' + (ConvertTo-TomlString $Value) + '"')
                $wrote = $true
            }
            continue
        }
        $output.Add($line)
    }
    if ($inTop -and -not $wrote) {
        $output.Add($Key + ' = "' + (ConvertTo-TomlString $Value) + '"')
    }
    Write-AtomicLines $Path $output.ToArray()
}

function Remove-TopLevelKey([string] $Path, [string] $Key) {
    $lines = @(Read-ConfigLines $Path)
    $output = New-Object 'System.Collections.Generic.List[string]'
    $inTop = $true
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*='
    foreach ($line in $lines) {
        if ($inTop -and $line -match '^\s*\[') { $inTop = $false }
        if ($inTop -and $line -match $keyPattern) { continue }
        $output.Add($line)
    }
    Write-AtomicLines $Path $output.ToArray()
}

function Get-TopLevelString([string] $Path, [string] $Key) {
    $inTop = $true
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
    foreach ($line in @(Read-ConfigLines $Path)) {
        if ($inTop -and $line -match '^\s*\[') { break }
        if ($inTop -and $line -match $keyPattern) { return $Matches[1] }
    }
    return $null
}

function Get-TopLevelAssignment([string] $Path, [string] $Key) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $inTop = $true
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*='
    foreach ($line in @(Read-ConfigLines $Path)) {
        if ($inTop -and $line -match '^\s*\[') { break }
        if ($inTop -and $line -match $keyPattern) { return $line }
    }
    return $null
}

function Set-TopLevelAssignment([string] $Path, [string] $Key, $Assignment) {
    $lines = @(Read-ConfigLines $Path)
    $output = New-Object 'System.Collections.Generic.List[string]'
    $inTop = $true
    $wrote = $false
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*='
    foreach ($line in $lines) {
        if ($inTop -and $line -match '^\s*\[') {
            if (-not $wrote -and $null -ne $Assignment) {
                $output.Add([string] $Assignment)
                $wrote = $true
            }
            $inTop = $false
        }
        if ($inTop -and $line -match $keyPattern) {
            if (-not $wrote -and $null -ne $Assignment) {
                $output.Add([string] $Assignment)
                $wrote = $true
            }
            continue
        }
        $output.Add($line)
    }
    if ($inTop -and -not $wrote -and $null -ne $Assignment) {
        $output.Add([string] $Assignment)
    }
    Write-AtomicLines $Path $output.ToArray()
}

function Update-DefaultConfig([hashtable] $Assignments) {
    [System.IO.Directory]::CreateDirectory($script:CodexHome) | Out-Null
    $temporary = Join-Path $script:CodexHome ('.codex-rp-defaults-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
            Copy-Item -LiteralPath $script:ConfigFile -Destination $temporary
        }
        else {
            [System.IO.File]::WriteAllText($temporary, '', $script:Utf8NoBom)
        }
        foreach ($key in @('model_provider', 'model', 'model_reasoning_effort')) {
            Set-TopLevelAssignment $temporary $key $Assignments[$key]
        }
        Move-Item -LiteralPath $temporary -Destination $script:ConfigFile -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Remove-ManagedBlock([string[]] $Lines, [string] $Id) {
    $begin = '# BEGIN codex-remote-provider-kit:' + $Id
    $end = '# END codex-remote-provider-kit:' + $Id
    $output = New-Object 'System.Collections.Generic.List[string]'
    $skip = $false
    foreach ($line in $Lines) {
        if ($line -eq $begin) { $skip = $true; continue }
        if ($line -eq $end) { $skip = $false; continue }
        if (-not $skip) { $output.Add($line) }
    }
    return $output.ToArray()
}

function Save-State([string] $Directory, [hashtable] $State) {
    $path = Join-Path $Directory 'state.json'
    $json = $State | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($path, $json, $script:Utf8NoBom)
}

function Load-State {
    $path = Join-Path $script:ActiveDir 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail '尚未安装 Windows provider 配置。' }
    return [System.IO.File]::ReadAllText($path, $script:Utf8NoBom) | ConvertFrom-Json
}

function Resolve-Codex([string] $Override) {
    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return (Resolve-Path $Override).Path }
        Fail "指定的 Codex 不存在：$Override"
    }
    $commandInfo = Get-Command codex -ErrorAction SilentlyContinue
    if ($commandInfo) { return $commandInfo.Source }
    return $null
}

function Ensure-Codex([string] $Override) {
    $resolved = Resolve-Codex $Override
    if ($resolved) { return $resolved }
    if ($env:CODEX_RP_SKIP_CODEX_INSTALL -eq '1') { Fail '测试模式下未找到 Codex CLI。' }
    Write-Host '未检测到 Codex CLI，正在运行 OpenAI 官方 Windows 安装器……'
    $downloadTimeoutSec = if ($env:CODEX_RP_DOWNLOAD_TIMEOUT_SEC) { [int] $env:CODEX_RP_DOWNLOAD_TIMEOUT_SEC } else { 60 }
    $installer = Invoke-RestMethod -UseBasicParsing -Uri 'https://chatgpt.com/codex/install.ps1' -TimeoutSec $downloadTimeoutSec
    Invoke-Expression $installer
    $resolved = Resolve-Codex ''
    if (-not $resolved) { Fail 'Codex 安装完成，但仍未找到 codex 命令。' }
    return $resolved
}

function ConvertFrom-SecureStringPlain([Security.SecureString] $Secure) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Read-ProviderSecret {
    if ($env:THIRD_PARTY_API_KEY) {
        if (-not (Test-ApiKey $env:THIRD_PARTY_API_KEY)) { Fail '环境中的 API 密钥格式无效。' }
        return ConvertTo-SecureString $env:THIRD_PARTY_API_KEY -AsPlainText -Force
    }
    if (-not [Environment]::UserInteractive) { Fail '非交互安装需要通过受控环境注入 THIRD_PARTY_API_KEY。' }
    return Read-Host '请输入第三方 API 密钥（不会回显）' -AsSecureString
}

function Write-DpapiSecret([Security.SecureString] $Secret, [string] $Path) {
    $plain = ConvertFrom-SecureStringPlain $Secret
    try {
        if (-not (Test-ApiKey $plain)) { Fail 'API 密钥为空或包含不支持的字符。' }
    }
    finally { $plain = $null }
    $encrypted = ConvertFrom-SecureString $Secret
    [System.IO.File]::WriteAllText($Path, $encrypted, $script:Utf8NoBom)
}

function Restore-OfficialDefaults($State) {
    $backup = Join-Path $script:ActiveDir 'backup\config.toml'
    $assignments = @{}
    foreach ($key in @('model_provider', 'model', 'model_reasoning_effort')) {
        $assignments[$key] = Get-TopLevelAssignment $backup $key
    }
    Update-DefaultConfig $assignments
}

function Test-OfficialDefaults {
    $backup = Join-Path $script:ActiveDir 'backup\config.toml'
    foreach ($key in @('model_provider', 'model', 'model_reasoning_effort')) {
        if ((Get-TopLevelAssignment $script:ConfigFile $key) -cne (Get-TopLevelAssignment $backup $key)) {
            return $false
        }
    }
    return $true
}

function Test-ManagedProviderBlock($State) {
    $begin = '# BEGIN codex-remote-provider-kit:' + $State.provider_id
    $end = '# END codex-remote-provider-kit:' + $State.provider_id
    $lines = @(Read-ConfigLines $script:ConfigFile)
    $beginIndex = [Array]::IndexOf($lines, $begin)
    $endIndex = [Array]::IndexOf($lines, $end)
    if ($beginIndex -lt 0 -or $endIndex -le $beginIndex) { return $false }
    $block = $lines[$beginIndex..$endIndex] -join "`n"
    return $block.Contains('[model_providers.' + $State.provider_id + ']') -and
        $block.Contains('base_url = "' + (ConvertTo-TomlString $State.base_url) + '"') -and
        $block.Contains('wire_api = "responses"') -and
        $block.Contains('[model_providers.' + $State.provider_id + '.auth]')
}

function Test-ManagedProfile($State) {
    $profileFile = Join-Path $script:CodexHome ($State.provider_id + '.config.toml')
    if (-not (Test-Path -LiteralPath $profileFile -PathType Leaf)) { return $false }
    $expected = @(
        ('model = "' + (ConvertTo-TomlString $State.model) + '"'),
        ('model_provider = "' + (ConvertTo-TomlString $State.provider_id) + '"'),
        ('model_reasoning_effort = "' + (ConvertTo-TomlString $State.reasoning) + '"')
    ) -join "`n"
    return ([System.IO.File]::ReadAllText($profileFile).Trim() -eq $expected)
}

function Get-ConfigurationMode($State) {
    $provider = Get-TopLevelString $script:ConfigFile 'model_provider'
    $modelValue = Get-TopLevelString $script:ConfigFile 'model'
    $reasoningValue = Get-TopLevelString $script:ConfigFile 'model_reasoning_effort'
    if ($provider -eq $State.provider_id -and $modelValue -eq $State.model -and $reasoningValue -eq $State.reasoning) {
        return 'third-party'
    }
    if (Test-OfficialDefaults) { return 'official' }
    return 'external'
}

function Assert-ManagedWriteAllowed($State) {
    if ((Get-ConfigurationMode $State) -eq 'external') {
        Fail '检测到外部 provider 或未受管默认配置；已拒绝覆盖。请先在外部工具中切换到 OpenAI 官方配置。'
    }
    if (-not (Test-ManagedProviderBlock $State)) {
        Fail "Provider $($State.provider_id) 的配置所有权不明确；已拒绝覆盖。"
    }
    if (-not (Test-ManagedProfile $State)) {
        Fail "$($State.provider_id).config.toml 已被外部修改；已拒绝覆盖。"
    }
}

function Install-Provider {
    $staging = $null
    $preserveStaging = $false
    try {
        if (Test-Path -LiteralPath $script:ActiveDir) { Fail '已经安装；请使用 third-party、official、rotate-key 或 rollback。' }
        if (-not (Test-ProviderId $ProviderId)) { Fail 'Provider ID 无效。' }
        if (-not (Test-ModelName $Model)) { Fail '模型名称无效。' }
        if (-not $BaseUrl) { $script:BaseUrl = Read-Host '请输入真实第三方 Base URL（示例：https://api.example.com/v1）' }
        $effectiveBaseUrl = $BaseUrl
        if (-not $effectiveBaseUrl) { $effectiveBaseUrl = $script:BaseUrl }
        $effectiveBaseUrl = $effectiveBaseUrl.TrimEnd('/')
        if (-not (Test-BaseUrl $effectiveBaseUrl)) { Fail 'Base URL 必须是非示例 HTTPS 地址，且不能包含凭据、查询或片段。' }

        $resolvedCodex = Ensure-Codex $CodexBin
        $profileFile = Join-Path $script:CodexHome ($ProviderId + '.config.toml')
        $staging = Join-Path $script:DataDir ('active.new.' + [Guid]::NewGuid().ToString('N'))
        $backupDir = Join-Path $staging 'backup'
        [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($script:CodexHome) | Out-Null
        [System.IO.Directory]::CreateDirectory($script:AuditDir) | Out-Null
        $configExisted = Test-Path -LiteralPath $script:ConfigFile -PathType Leaf
        $profileExisted = Test-Path -LiteralPath $profileFile -PathType Leaf
        $selectedProvider = Get-TopLevelString $script:ConfigFile 'model_provider'
        if ($selectedProvider -and $selectedProvider -ne 'openai') {
            Fail '检测到外部 provider；首次安装不会覆盖现有选择。请先在外部工具中切换到 OpenAI 官方配置。'
        }
        if ($profileExisted) {
            Fail "$ProviderId.config.toml 已存在且不属于本套件；首次安装拒绝覆盖。"
        }
        if ($configExisted) { Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $backupDir 'config.toml') }
        if ($profileExisted) { Copy-Item -LiteralPath $profileFile -Destination (Join-Path $backupDir 'profile.config.toml') }

        $secretFile = Join-Path $script:ActiveDir 'provider.key'
        $stagingSecret = Join-Path $staging 'provider.key'
        $helperFile = Join-Path $script:ActiveDir 'get-provider-token.ps1'
        Copy-Item -LiteralPath (Join-Path $script:ScriptDir 'get-provider-token.ps1') -Destination (Join-Path $staging 'get-provider-token.ps1')
        $secureSecret = Read-ProviderSecret
        try { Write-DpapiSecret $secureSecret $stagingSecret }
        finally { if ($secureSecret) { $secureSecret.Dispose() } }

        $baseLines = @(Remove-ManagedBlock @(Read-ConfigLines $script:ConfigFile) $ProviderId)
        $providerPattern = '^\s*\[model_providers\.' + [Regex]::Escape($ProviderId) + '\]\s*$'
        if ($baseLines | Where-Object { $_ -match $providerPattern }) { Fail "配置已在套件管理区块之外定义 model_providers.$ProviderId。" }
        $temporaryConfig = Join-Path $staging 'config.toml'
        Write-AtomicLines $temporaryConfig $baseLines
        Set-TopLevelString $temporaryConfig 'model_provider' $ProviderId
        Set-TopLevelString $temporaryConfig 'model' $Model
        Set-TopLevelString $temporaryConfig 'model_reasoning_effort' $Reasoning

        $powershellExe = if ($env:CODEX_RP_TEST_MODE -eq '1' -and (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        (Get-Command pwsh).Source
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
        $managed = @(
            '',
            ('# BEGIN codex-remote-provider-kit:' + $ProviderId),
            ('[model_providers.' + $ProviderId + ']'),
            ('name = "' + (ConvertTo-TomlString $ProviderId) + '"'),
            ('base_url = "' + (ConvertTo-TomlString $effectiveBaseUrl) + '"'),
            'wire_api = "responses"',
            '',
            ('[model_providers.' + $ProviderId + '.auth]'),
            ('command = "' + (ConvertTo-TomlString $powershellExe) + '"'),
            ('args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "' + (ConvertTo-TomlString $helperFile) + '", "' + (ConvertTo-TomlString $secretFile) + '"]'),
            ('# END codex-remote-provider-kit:' + $ProviderId)
        )
        Write-AtomicLines $temporaryConfig (@(Read-ConfigLines $temporaryConfig) + $managed)

        $temporaryProfile = Join-Path $staging 'profile.config.toml'
        Write-AtomicLines $temporaryProfile @(
            ('model = "' + (ConvertTo-TomlString $Model) + '"'),
            ('model_provider = "' + (ConvertTo-TomlString $ProviderId) + '"'),
            ('model_reasoning_effort = "' + (ConvertTo-TomlString $Reasoning) + '"')
        )
        Save-State $staging @{
            provider_id = $ProviderId
            model = $Model
            reasoning = $Reasoning
            base_url = $effectiveBaseUrl
            codex_bin = $resolvedCodex
            config_existed = [bool] $configExisted
            profile_existed = [bool] $profileExisted
        }

        $installedConfig = $false
        try {
            Write-AtomicLines $script:ConfigFile @(Read-ConfigLines $temporaryConfig)
            $installedConfig = $true
            Write-AtomicLines $profileFile @(Read-ConfigLines $temporaryProfile)
            Move-Item -LiteralPath $staging -Destination $script:ActiveDir
        }
        catch {
            $installError = $_.Exception.Message
            $recoveryErrors = New-Object 'System.Collections.Generic.List[string]'
            try {
                if ($configExisted) {
                    Write-AtomicLines $script:ConfigFile @(Read-ConfigLines (Join-Path $backupDir 'config.toml'))
                }
                elseif ($installedConfig -and (Test-Path -LiteralPath $script:ConfigFile)) {
                    Remove-Item -LiteralPath $script:ConfigFile -Force
                }
            }
            catch { $recoveryErrors.Add('恢复 config.toml 失败：' + $_.Exception.Message) }
            try {
                if ($profileExisted) {
                    Write-AtomicLines $profileFile @(Read-ConfigLines (Join-Path $backupDir 'profile.config.toml'))
                }
                elseif (Test-Path -LiteralPath $profileFile) {
                    Remove-Item -LiteralPath $profileFile -Force
                }
            }
            catch { $recoveryErrors.Add('恢复 profile 失败：' + $_.Exception.Message) }
            if ($recoveryErrors.Count -gt 0) {
                $preserveStaging = $true
                throw ($installError + '；自动恢复不完整，备份暂存目录已保留：' + $staging + '；' + ($recoveryErrors -join '；'))
            }
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            throw $installError
        }

        Write-Host "Windows 第三方 provider 已安装：$ProviderId / $Model"
        Write-Host '密钥已使用当前 Windows 用户的 DPAPI 加密，未写入 config.toml。'
        Write-Host '账号、workspace、Remote 配对和会话均未修改。'
        Write-Host '请运行 codex-rp restart-app，再从手机新建会话验证。'
    }
    catch {
        if (-not $preserveStaging -and $staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
        throw
    }
}

function Use-ThirdParty {
    $state = Load-State
    $mode = Get-ConfigurationMode $state
    if ($mode -eq 'external') { Assert-ManagedWriteAllowed $state }
    if ($mode -eq 'third-party') {
        Write-Host '当前已经是本工具管理的第三方 provider。'
        return
    }
    Assert-ManagedWriteAllowed $state
    Update-DefaultConfig @{
        model_provider = 'model_provider = "' + (ConvertTo-TomlString $state.provider_id) + '"'
        model = 'model = "' + (ConvertTo-TomlString $state.model) + '"'
        model_reasoning_effort = 'model_reasoning_effort = "' + (ConvertTo-TomlString $state.reasoning) + '"'
    }
    Write-Host "已切换配置到第三方 provider：$($state.provider_id) / $($state.model)。"
    Write-Host '未重启 ChatGPT，也未修改账号或 Remote 配对；请明确运行 codex-rp restart-app。'
}

function Use-Official {
    $state = Load-State
    $mode = Get-ConfigurationMode $state
    if ($mode -eq 'external') { Assert-ManagedWriteAllowed $state }
    if ($mode -eq 'official') {
        Write-Host '当前已经是 OpenAI 官方配置；未修改外部配置。'
        return
    }
    Assert-ManagedWriteAllowed $state
    $confirmation = Read-Confirmation '只恢复安装前官方默认配置，可能使用官方额度。是否继续？[y/N]'
    if ($confirmation -notmatch '^[yY]$') {
        Write-Host '操作已取消。'
        return
    }
    Restore-OfficialDefaults $state
    Write-Host '已恢复安装前官方默认配置。DPAPI 凭据、账号和 Remote 配对均未删除。'
    Write-Host '请明确运行 codex-rp restart-app，再新建会话。'
}

function Show-Status {
    $state = Load-State
    $mode = Get-ConfigurationMode $state
    $provider = Get-TopLevelString $script:ConfigFile 'model_provider'
    $modelValue = Get-TopLevelString $script:ConfigFile 'model'
    $reasoningValue = Get-TopLevelString $script:ConfigFile 'model_reasoning_effort'
    $providerConfigStatus = if (Test-ManagedProviderBlock $state) { '完整' } else { '缺失或已被外部修改' }
    $profileStatus = if (Test-ManagedProfile $state) { '完整' } else { '缺失或已被外部修改' }
    if ($Json) {
        [pscustomobject]@{
            schema_version = 1
            kit_version = $script:KitVersion
            platform = 'windows'
            mode = $mode
            ok = ($mode -ne 'external' -and $providerConfigStatus -eq '完整' -and $profileStatus -eq '完整')
            checks = @(
                [pscustomobject]@{ id = 'config.mode'; status = $(if ($mode -eq 'external') { 'BLOCKED' } else { 'PASS' }) }
                [pscustomobject]@{ id = 'config.provider'; status = $(if ($providerConfigStatus -eq '完整') { 'PASS' } else { 'BLOCKED' }) }
                [pscustomobject]@{ id = 'config.profile'; status = $(if ($profileStatus -eq '完整') { 'PASS' } else { 'BLOCKED' }) }
                [pscustomobject]@{ id = 'credential.presence'; status = $(if (Test-Path -LiteralPath (Join-Path $script:ActiveDir 'provider.key') -PathType Leaf) { 'PASS' } else { 'FAIL' }) }
                [pscustomobject]@{ id = 'remote.host_readiness'; status = 'UNKNOWN' }
            )
        } | ConvertTo-Json -Compress -Depth 4
        return
    }
    Write-Host '[套件]'
    Write-Host "版本：$($script:KitVersion)"
    Write-Host '[平台]'
    Write-Host 'Windows'
    Write-Host '[配置]'
    Write-Host "当前模式：$mode"
    if ($mode -eq 'third-party') {
        Write-Host "第三方配置：$($state.provider_id) / $modelValue / $reasoningValue"
    }
    elseif ($mode -eq 'external') {
        Write-Warning '诊断：检测到 external/unmanaged；所有写操作将拒绝覆盖。'
    }
    Write-Host "Provider 配置：$providerConfigStatus"
    Write-Host "Profile 配置：$profileStatus"
    Write-Host "用户配置：$($script:ConfigFile)"

    $secretFile = Join-Path $script:ActiveDir 'provider.key'
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) { Fail 'DPAPI 凭据文件缺失。' }
    $helperFile = Join-Path $script:ActiveDir 'get-provider-token.ps1'
    if (-not (Test-Path -LiteralPath $helperFile -PathType Leaf)) { Fail 'DPAPI 解密助手缺失。' }
    $powershellExe = if ($env:CODEX_RP_TEST_MODE -eq '1' -and (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        (Get-Command pwsh).Source
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $decrypted = (& $powershellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helperFile $secretFile 2>$null | Out-String).Trim()
    $decryptExit = $LASTEXITCODE
    if ($decryptExit -ne 0 -or -not (Test-ApiKey $decrypted)) {
        $decrypted = $null
        Fail 'DPAPI 凭据无法由当前 Windows 用户解密。'
    }
    $decrypted = $null
    Write-Host '[凭据]'
    Write-Host 'DPAPI 加密文件：存在，当前用户可解密'

    Write-Host '[Codex]'
    & $state.codex_bin --version
    if ($LASTEXITCODE -ne 0) { Fail '无法执行 Codex CLI。' }
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $login = (& $state.codex_bin login status 2>&1 | Out-String)
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
    if ($login -match 'Logged in using ChatGPT') { Write-Host 'CLI 登录：已使用 ChatGPT 登录' }
    else { Write-Host 'CLI 登录：未确认；请检查 ChatGPT 桌面应用的账号/workspace' }

    Write-Host '[Remote 宿主]'
    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) { Write-Host 'ChatGPT 桌面应用：运行中' }
    else { Write-Host 'ChatGPT 桌面应用：未运行' }
    Write-Host 'Remote 就绪状态：UNKNOWN（进程存在不能证明手机 Remote 端到端可用）'
}

function Invoke-ProviderTest {
    $state = Load-State
    if ((Get-TopLevelString $script:ConfigFile 'model_provider') -ne $state.provider_id) { Fail '真实测试只在 third-party 模式运行。' }
    Show-Status
    $lastMessage = Join-Path $env:TEMP ('codex-rp-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        Write-Host '正在执行最小化第三方 Codex 回合，可能产生少量用量……'
        & $state.codex_bin exec --strict-config --profile $state.provider_id --ephemeral --skip-git-repo-check --sandbox read-only -C $env:TEMP --output-last-message $lastMessage 'Do not use tools. Reply exactly OK.' | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'Codex 真实调用失败。' }
        if (([System.IO.File]::ReadAllText($lastMessage).Trim()) -ne 'OK') { Fail 'Codex 回复不是预期的 OK。' }
        Write-Host 'Codex 回复：OK'
    }
    finally { if (Test-Path -LiteralPath $lastMessage) { Remove-Item -LiteralPath $lastMessage -Force } }
}

function Reconfigure-Provider {
    $state = Load-State
    if ($script:ProvidedParameters.ContainsKey('ProviderId') -and $ProviderId -ne $state.provider_id) {
        Fail 'reconfigure 不支持修改 Provider ID；为避免所有权冲突，请保留既有 ID。'
    }
    $newBaseUrl = if ($script:ProvidedParameters.ContainsKey('BaseUrl')) { $BaseUrl.TrimEnd('/') } else { [string] $state.base_url }
    $newModel = if ($script:ProvidedParameters.ContainsKey('Model')) { $Model } else { [string] $state.model }
    $newReasoning = if ($script:ProvidedParameters.ContainsKey('Reasoning')) { $Reasoning } else { [string] $state.reasoning }
    if (-not (Test-BaseUrl $newBaseUrl)) { Fail 'Base URL 必须是非示例 HTTPS 地址，且不能包含凭据、查询或片段。' }
    if (-not (Test-ModelName $newModel)) { Fail '模型名称无效。' }
    $mode = Get-ConfigurationMode $state
    Assert-ManagedWriteAllowed $state

    $profileFile = Join-Path $script:CodexHome ($state.provider_id + '.config.toml')
    $oldConfig = @(Read-ConfigLines $script:ConfigFile)
    $oldProfile = @(Read-ConfigLines $profileFile)
    $oldState = [System.IO.File]::ReadAllText((Join-Path $script:ActiveDir 'state.json'), $script:Utf8NoBom)
    $newState = @{
        provider_id = $state.provider_id
        model = $newModel
        reasoning = $newReasoning
        base_url = $newBaseUrl
        codex_bin = $state.codex_bin
        config_existed = [bool] $state.config_existed
        profile_existed = [bool] $state.profile_existed
    }
    $temporaryConfig = Join-Path $script:ActiveDir ('.config-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $temporaryProfile = Join-Path $script:ActiveDir ('.profile-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $temporarySecret = Join-Path $script:ActiveDir ('.provider-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $newSecret = $null
    try {
        $newConfig = @(Remove-ManagedBlock $oldConfig $state.provider_id)
        Write-AtomicLines $temporaryConfig $newConfig
        $powershellExe = if ($env:CODEX_RP_TEST_MODE -eq '1' -and (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        (Get-Command pwsh).Source
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
        $secretFile = Join-Path $script:ActiveDir 'provider.key'
        $helperFile = Join-Path $script:ActiveDir 'get-provider-token.ps1'
        $managed = @(
            '',
            ('# BEGIN codex-remote-provider-kit:' + $state.provider_id),
            ('[model_providers.' + $state.provider_id + ']'),
            ('name = "' + (ConvertTo-TomlString $state.provider_id) + '"'),
            ('base_url = "' + (ConvertTo-TomlString $newBaseUrl) + '"'),
            'wire_api = "responses"',
            '',
            ('[model_providers.' + $state.provider_id + '.auth]'),
            ('command = "' + (ConvertTo-TomlString $powershellExe) + '"'),
            ('args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "' + (ConvertTo-TomlString $helperFile) + '", "' + (ConvertTo-TomlString $secretFile) + '"]'),
            ('# END codex-remote-provider-kit:' + $state.provider_id)
        )
        Write-AtomicLines $temporaryConfig (@(Read-ConfigLines $temporaryConfig) + $managed)
        if ($mode -eq 'third-party') {
            Set-TopLevelString $temporaryConfig 'model_provider' $state.provider_id
            Set-TopLevelString $temporaryConfig 'model' $newModel
            Set-TopLevelString $temporaryConfig 'model_reasoning_effort' $newReasoning
        }
        Write-AtomicLines $temporaryProfile @(
            ('model = "' + (ConvertTo-TomlString $newModel) + '"'),
            ('model_provider = "' + (ConvertTo-TomlString $state.provider_id) + '"'),
            ('model_reasoning_effort = "' + (ConvertTo-TomlString $newReasoning) + '"')
        )
        if ($RotateKey) {
            $newSecret = Read-ProviderSecret
            Write-DpapiSecret $newSecret $temporarySecret
        }
        Write-AtomicLines $script:ConfigFile @(Read-ConfigLines $temporaryConfig)
        Write-AtomicLines $profileFile @(Read-ConfigLines $temporaryProfile)
        Save-State $script:ActiveDir $newState
        if ($RotateKey) { Move-Item -LiteralPath $temporarySecret -Destination $secretFile -Force }
    }
    catch {
        $updateError = $_.Exception.Message
        try { Write-AtomicLines $script:ConfigFile $oldConfig } catch { }
        try { Write-AtomicLines $profileFile $oldProfile } catch { }
        try { [System.IO.File]::WriteAllText((Join-Path $script:ActiveDir 'state.json'), $oldState, $script:Utf8NoBom) } catch { }
        Fail "reconfigure 未完成；配置和活动状态已恢复：$updateError"
    }
    finally {
        if ($newSecret) { $newSecret.Dispose() }
        if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
        if (Test-Path -LiteralPath $temporaryProfile) { Remove-Item -LiteralPath $temporaryProfile -Force }
        if (Test-Path -LiteralPath $temporarySecret) { Remove-Item -LiteralPath $temporarySecret -Force }
    }
    Write-Host "已事务更新第三方配置：$($state.provider_id) / $newModel。当前模式保持 $mode；未重启 ChatGPT。"
    Write-Host '请明确运行 codex-rp restart-app，再执行 codex-rp test。'
}

function Rotate-Key {
    $state = Load-State
    Assert-ManagedWriteAllowed $state
    $secretFile = Join-Path $script:ActiveDir 'provider.key'
    $secret = Read-ProviderSecret
    $temporary = Join-Path $script:ActiveDir ('provider-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-DpapiSecret $secret $temporary
        Move-Item -LiteralPath $temporary -Destination $secretFile -Force
    }
    finally {
        if ($secret) { $secret.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-Host 'DPAPI 密钥已更新；请确认新密钥可用后立即吊销旧密钥。'
}

function Restart-ChatGptApp {
    $confirmation = Read-Confirmation '这会暂时断开当前 Remote，但不会注销或删除配对。输入 RESTART_APP 继续'
    if ($confirmation -ne 'RESTART_APP') { Fail '操作已取消。' }
    if ($env:CODEX_RP_TEST_MODE -eq '1') { Write-Host '测试模式：已模拟重启 ChatGPT。'; return }
    $package = Get-AppxPackage | Where-Object { $_.Name -match 'ChatGPT' } | Select-Object -First 1
    if (-not $package) {
        Write-Host '未能自动定位 ChatGPT 应用，因此没有关闭当前应用；请从开始菜单手动重启。'
        return
    }
    $manifest = Get-AppxPackageManifest $package
    $applicationId = $manifest.Package.Applications.Application.Id | Select-Object -First 1
    if (-not $applicationId) { Fail 'ChatGPT 包清单中缺少应用 ID；当前应用未被关闭。' }
    Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
    }
    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        $forceConfirmation = Read-Confirmation 'ChatGPT 在 15 秒内未退出。输入 FORCE_RESTART_APP 强制终止，或直接回车取消'
        if ($forceConfirmation -ne 'FORCE_RESTART_APP') {
            Fail 'ChatGPT 未被强制终止；请手动关闭后重试。'
        }
        Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    $appTarget = 'shell:AppsFolder\' + $package.PackageFamilyName + '!' + $applicationId
    Start-Process -FilePath explorer.exe -ArgumentList $appTarget
    $startDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $startDeadline -and -not (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
    }
    if (-not (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        Fail '已请求启动 ChatGPT，但 10 秒内未检测到进程；请手动打开应用。'
    }
    Write-Host 'ChatGPT 已重新打开并检测到进程；这不代表 Remote 端到端已恢复，请新建会话验证。'
}

function Rollback-All {
    $arguments = @($CommandArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $dryRunRequested = $DryRun -or ($arguments -contains '--dry-run')
    if (@($arguments | Where-Object { $_ -ne '--dry-run' }).Count -gt 0) {
        Fail 'rollback 只接受 --dry-run。'
    }
    $state = Load-State
    $mode = Get-ConfigurationMode $state
    Assert-ManagedWriteAllowed $state
    if ($dryRunRequested) {
        Write-Host '回滚预演通过：将移除受管 provider/profile，并尝试删除 DPAPI 密钥；不会修改任何内容。'
        return
    }
    $confirmation = Read-Confirmation '只移除本工具配置和 DPAPI 密钥，并保留其他 provider。输入 ROLLBACK 继续'
    if ($confirmation -ne 'ROLLBACK') { Fail '操作已取消。' }
    $secretFile = Join-Path $script:ActiveDir 'provider.key'
    try {
        if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
    }
    catch {
        Fail 'DPAPI 密钥删除失败；为避免误报，活动状态和其余配置均已保留。请解决文件权限后重试 rollback。'
    }
    $profileFile = Join-Path $script:CodexHome ($state.provider_id + '.config.toml')
    $configLines = @(Remove-ManagedBlock @(Read-ConfigLines $script:ConfigFile) $state.provider_id)
    Write-AtomicLines $script:ConfigFile $configLines
    if ($mode -eq 'third-party') {
        Restore-OfficialDefaults $state
    }
    if ($state.profile_existed) {
        Write-AtomicLines $profileFile @(Read-ConfigLines (Join-Path $script:ActiveDir 'backup\profile.config.toml'))
    }
    elseif (Test-Path -LiteralPath $profileFile) {
        Remove-Item -LiteralPath $profileFile -Force
    }
    [System.IO.Directory]::CreateDirectory($script:AuditDir) | Out-Null
    $target = Join-Path $script:AuditDir ('state-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
    Move-Item -LiteralPath $script:ActiveDir -Destination $target
    Write-Host "回滚完成。账号、Remote 配对和会话未修改；审计备份：$target"
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host "Codex Remote Provider Kit（Windows）v$($script:KitVersion)"
        Write-Host '1) 安装第三方 provider    2) 查看状态    3) 完整测试'
        Write-Host '4) 切换第三方              5) 切换官方    6) 重新配置'
        Write-Host '7) 轮换密钥                8) 重启应用    9) 完整回滚'
        Write-Host '10) 查看帮助               0) 退出'
        $choice = Read-Host '请选择'
        try {
            switch ($choice) {
                '1' { Install-Provider }
                '2' { Show-Status }
                '3' { Invoke-ProviderTest }
                '4' { Use-ThirdParty }
                '5' { Use-Official }
                '6' { Reconfigure-Provider }
                '7' { Rotate-Key }
                '8' { Restart-ChatGptApp }
                '9' { Rollback-All }
                '10' { Show-Usage }
                '0' { return }
                default { Write-Warning '无效选项。' }
            }
        }
        catch {
            Write-Warning ('操作失败：' + $_.Exception.Message)
            Write-Host '已返回主菜单；请修正问题后重试。'
        }
    }
}

try {
    switch ($Command) {
        'menu' { Show-Menu }
        'install' { Install-Provider }
        'reconfigure' { Reconfigure-Provider }
        'status' { Show-Status }
        'doctor' { Show-Status }
        'test' { Invoke-ProviderTest }
        'official' { Use-Official }
        'third-party' { Use-ThirdParty }
        'rotate-key' { Rotate-Key }
        'restart-app' { Restart-ChatGptApp }
        { $_ -in @('rollback', 'uninstall') } { Rollback-All }
        'update' { Write-Host 'Windows 不在启动器中自动下载更新。请重新运行 README 中受信任的 install-windows.ps1；安装器有下载超时和失败恢复。' }
        { $_ -in @('version', '-V', '--version') } { Write-Output "codex-remote-provider-kit $($script:KitVersion)" }
        'help' { Show-Usage }
    }
}
catch {
    [Console]::Error.WriteLine('错误：' + $_.Exception.Message)
    exit 1
}
