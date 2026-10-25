param(
    [string]$LauncherPath = (Join-Path $PSScriptRoot 'start-bm-radio-bridge.ps1')
)

$ErrorActionPreference = 'Stop'
$selectedFunctions = @(
    'ConvertTo-GainMilli',
    'Format-GainDecimal',
    'Read-AudioSettings',
    'Write-AudioSettings',
    'Get-AudioSettings'
)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    [System.IO.Path]::GetFullPath($LauncherPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "启动器 PowerShell 语法错误：$messages"
}
$launcherText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($LauncherPath))
foreach ($requiredText in @('--radio-playback-gain', '--mic-transmit-gain', "Join-Path `$script:packageRoot 'audio-settings.json'")) {
    if (-not $launcherText.Contains($requiredText)) { throw "启动器缺少音量配置接线：$requiredText" }
}
$listenLauncherPath = Join-Path (Split-Path -Parent $LauncherPath) 'start-listen-91.cmd'
if (Test-Path -LiteralPath $listenLauncherPath -PathType Leaf) {
    $listenLauncherText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($listenLauncherPath))
    if ($listenLauncherText -notmatch '-Preset listen-91\s+%\*') { throw 'TG91 启动器没有透传增益命令行参数。' }
}
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $selectedFunctions -ccontains $node.Name
}, $true))
if ($functionAsts.Count -ne $selectedFunctions.Count) { throw '没有找到全部音量设置函数。' }
foreach ($functionAst in $functionAsts) { Invoke-Expression $functionAst.Extent.Text }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "预期拒绝但操作成功：$Message" }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-audio-settings-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$settingsPath = Join-Path $temporaryRoot 'audio-settings.json'
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    $defaults = Get-AudioSettings -Path $settingsPath
    Assert-True ($defaults.RadioPlaybackGainMilli -eq 1000) '缺少配置时回放默认值应为 1x'
    Assert-True ($defaults.MicTransmitGainMilli -eq 16000) '缺少配置时发送默认值应为 16x'
    Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) '缺少配置时应保存默认文件'
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryRoot | Where-Object { $_.Name -match '\.(tmp|bak)-' }).Count -eq 0) '首次保存后不应残留临时文件'

    $playbackOverride = Get-AudioSettings -Path $settingsPath `
        -RadioPlaybackGainWasBound $true -RadioPlaybackGainValue '0.75'
    Assert-True ($playbackOverride.RadioPlaybackGainMilli -eq 750) '播放增益覆盖应精确换算到千分位'
    Assert-True ($playbackOverride.MicTransmitGainMilli -eq 16000) '单项覆盖应保留另一项设置'

    $bothOverrides = Get-AudioSettings -Path $settingsPath `
        -RadioPlaybackGainWasBound $true -RadioPlaybackGainValue '1.25' `
        -MicTransmitGainWasBound $true -MicTransmitGainValue '12.125'
    Assert-True ($bothOverrides.RadioPlaybackGainMilli -eq 1250) '播放参数应支持 1.25x'
    Assert-True ($bothOverrides.MicTransmitGainMilli -eq 12125) '发送参数应支持三位小数'
    $reloaded = Get-AudioSettings -Path $settingsPath
    Assert-True ($reloaded.RadioPlaybackGainMilli -eq 1250 -and $reloaded.MicTransmitGainMilli -eq 12125) '保存值应在下次启动恢复'

    [System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    Write-AudioSettings -Path $settingsPath -RadioPlaybackGainMilli 1250 -MicTransmitGainMilli 12125
    $serialized = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    Assert-True ($serialized.Contains('"radio_playback_gain": 1.25')) 'JSON 小数点应固定使用 invariant 格式'
    Assert-True (-not $serialized.Contains('1,25')) 'JSON 不应因系统区域设置写出逗号小数'
    $cultureReload = Get-AudioSettings -Path $settingsPath
    Assert-True ($cultureReload.RadioPlaybackGainMilli -eq 1250 -and $cultureReload.MicTransmitGainMilli -eq 12125) '区域设置变化不应影响读取'
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture

    foreach ($invalid in @('0.249', '16.001', '1.0000', '1,5', '1e0', '-1', '.5', '1.')) {
        Assert-Throws { ConvertTo-GainMilli -Text $invalid -Label 'test' | Out-Null } "增益 $invalid"
    }

    $invalidDocuments = @(
        '{"schema_version":1,"radio_playback_gain":1,"mic_transmit_gain":16,"new_field":2}',
        '{"schema_version":2,"radio_playback_gain":1,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1,"radio_playback_gain":2,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1e0,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":"1","mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":{"radio_playback_gain":1},"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1}',
        '{broken json'
    )
    foreach ($invalidDocument in $invalidDocuments) {
        [System.IO.File]::WriteAllText($settingsPath, $invalidDocument, (New-Object System.Text.UTF8Encoding($false)))
        Assert-Throws { Get-AudioSettings -Path $settingsPath -RadioPlaybackGainWasBound $true `
            -RadioPlaybackGainValue '2' | Out-Null } '无效配置必须拒绝且不能被覆盖'
        Assert-True ([System.IO.File]::ReadAllText($settingsPath) -ceq $invalidDocument) '拒绝配置时应保留原文件内容'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryRoot | Where-Object { $_.Name -match '\.(tmp|bak)-' }).Count -eq 0) '拒绝配置后不应残留临时文件'
    Write-Output '启动器 AST、音量设置、区域格式和拒绝路径检查通过。'
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        } else {
            throw '拒绝清理超出系统临时目录的测试路径。'
        }
    }
}
