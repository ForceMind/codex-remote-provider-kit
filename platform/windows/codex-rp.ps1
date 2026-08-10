[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'status', 'test', 'official', 'third-party', 'rotate-key', 'restart-app', 'rollback', 'help')]
    [string] $Command = 'menu',

    [string] $BaseUrl = '',
    [string] $Model = 'gpt-5.6-sol',
    [string] $ProviderId = 'third_party',
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh')]
    [string] $Reasoning = 'high',
    [string] $CodexBin = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoDir = (Resolve-Path (Join-Path $script:ScriptDir '..\..')).Path
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
    @'
Codex Remote Provider Kit（Windows）

用法：
  codex-rp <命令> [PowerShell 参数]

命令：
  menu          打开中文管理面板（默认）
  install       安装/配置第三方 provider
  status        检查配置、DPAPI 凭据、Codex 与 ChatGPT 应用
  test          执行一次最小化第三方 Codex 真实调用
  official      恢复安装前的官方默认模型配置
  third-party   重新启用第三方模型配置
  rotate-key    更新当前 Windows 用户的 DPAPI 加密密钥
  restart-app   明确重启 ChatGPT 桌面应用
  rollback      恢复安装前配置并删除加密密钥

示例：
  codex-rp install -BaseUrl https://provider.example/v1 -Model gpt-5.6-sol
  codex-rp status

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
    $installer = Invoke-RestMethod 'https://chatgpt.com/codex/install.ps1'
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

        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $managed = @(
            '',
            '# BEGIN codex-remote-provider-kit:' + $ProviderId,
            '[model_providers.' + $ProviderId + ']',
            'name = "' + (ConvertTo-TomlString $ProviderId) + '"',
            'base_url = "' + (ConvertTo-TomlString $effectiveBaseUrl) + '"',
            'wire_api = "responses"',
            '',
            '[model_providers.' + $ProviderId + '.auth]',
            'command = "' + (ConvertTo-TomlString $powershellExe) + '"',
            'args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "' + (ConvertTo-TomlString $helperFile) + '", "' + (ConvertTo-TomlString $secretFile) + '"]',
            '# END codex-remote-provider-kit:' + $ProviderId
        )
        Write-AtomicLines $temporaryConfig (@(Read-ConfigLines $temporaryConfig) + $managed)

        $temporaryProfile = Join-Path $staging 'profile.config.toml'
        Write-AtomicLines $temporaryProfile @(
            'model = "' + (ConvertTo-TomlString $Model) + '"',
            'model_provider = "' + (ConvertTo-TomlString $ProviderId) + '"',
            'model_reasoning_effort = "' + (ConvertTo-TomlString $Reasoning) + '"'
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
    $confirmation = Read-Confirmation '只恢复安装前官方默认配置，可能使用官方额度。输入 USE_OFFICIAL 继续'
    if ($confirmation -ne 'USE_OFFICIAL') { Fail '操作已取消。' }
    Restore-OfficialDefaults $state
    Write-Host '已恢复安装前官方默认配置。DPAPI 凭据、账号和 Remote 配对均未删除。'
    Write-Host '请明确运行 codex-rp restart-app，再新建会话。'
}

function Show-Status {
    $state = Load-State
    $provider = Get-TopLevelString $script:ConfigFile 'model_provider'
    $modelValue = Get-TopLevelString $script:ConfigFile 'model'
    $reasoningValue = Get-TopLevelString $script:ConfigFile 'model_reasoning_effort'
    Write-Host '[平台]'
    Write-Host 'Windows'
    Write-Host '[配置]'
    if ($provider -eq $state.provider_id) {
        Write-Host '当前模式：third-party'
        if ($modelValue -ne $state.model) { Fail "模型不匹配：$modelValue" }
        if ($reasoningValue -ne $state.reasoning) { Fail "推理强度不匹配：$reasoningValue" }
    }
    elseif (Test-OfficialDefaults) { Write-Host '当前模式：official' }
    else {
        Write-Host '当前模式：unmanaged'
        Fail '三项顶层默认配置既不匹配第三方模式，也不匹配安装前官方模式。'
    }
    Write-Host "用户配置：$($script:ConfigFile)"

    $secretFile = Join-Path $script:ActiveDir 'provider.key'
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) { Fail 'DPAPI 凭据文件缺失。' }
    $helperFile = Join-Path $script:ActiveDir 'get-provider-token.ps1'
    if (-not (Test-Path -LiteralPath $helperFile -PathType Leaf)) { Fail 'DPAPI 解密助手缺失。' }
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
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

function Rotate-Key {
    $null = Load-State
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
    Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force
    $appTarget = 'shell:AppsFolder\' + $package.PackageFamilyName + '!' + $applicationId
    Start-Process -FilePath explorer.exe -ArgumentList $appTarget
    Write-Host 'ChatGPT 已重新打开；请等待 Remote 恢复后新建会话。'
}

function Rollback-All {
    $state = Load-State
    $confirmation = Read-Confirmation '恢复安装前配置并删除 DPAPI 密钥。输入 ROLLBACK 继续'
    if ($confirmation -ne 'ROLLBACK') { Fail '操作已取消。' }
    $profileFile = Join-Path $script:CodexHome ($state.provider_id + '.config.toml')
    $backupConfig = Join-Path $script:ActiveDir 'backup\config.toml'
    $backupProfile = Join-Path $script:ActiveDir 'backup\profile.config.toml'
    if ($state.config_existed) { Copy-Item -LiteralPath $backupConfig -Destination $script:ConfigFile -Force }
    elseif (Test-Path -LiteralPath $script:ConfigFile) { Remove-Item -LiteralPath $script:ConfigFile -Force }
    if ($state.profile_existed) { Copy-Item -LiteralPath $backupProfile -Destination $profileFile -Force }
    elseif (Test-Path -LiteralPath $profileFile) { Remove-Item -LiteralPath $profileFile -Force }
    $secretFile = Join-Path $script:ActiveDir 'provider.key'
    if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
    [System.IO.Directory]::CreateDirectory($script:AuditDir) | Out-Null
    $target = Join-Path $script:AuditDir ('state-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
    Move-Item -LiteralPath $script:ActiveDir -Destination $target
    Write-Host "回滚完成。账号、Remote 配对和会话未修改；审计备份：$target"
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host 'Codex Remote Provider Kit（Windows）'
        Write-Host '1) 安装第三方 provider    2) 查看状态    3) 完整测试'
        Write-Host '4) 切换第三方              5) 切换官方    6) 轮换密钥'
        Write-Host '7) 重启 ChatGPT 应用       8) 完整回滚    0) 退出'
        switch (Read-Host '请选择') {
            '1' { Install-Provider }
            '2' { Show-Status }
            '3' { Invoke-ProviderTest }
            '4' { Use-ThirdParty }
            '5' { Use-Official }
            '6' { Rotate-Key }
            '7' { Restart-ChatGptApp }
            '8' { Rollback-All }
            '0' { return }
            default { Write-Warning '无效选项。' }
        }
    }
}

try {
    switch ($Command) {
        'menu' { Show-Menu }
        'install' { Install-Provider }
        'status' { Show-Status }
        'test' { Invoke-ProviderTest }
        'official' { Use-Official }
        'third-party' { Use-ThirdParty }
        'rotate-key' { Rotate-Key }
        'restart-app' { Restart-ChatGptApp }
        'rollback' { Rollback-All }
        'help' { Show-Usage }
    }
}
catch {
    [Console]::Error.WriteLine('错误：' + $_.Exception.Message)
    exit 1
}
