[CmdletBinding()]
param([string]$ControlPackageDirectory)

$ErrorActionPreference = 'Stop'
$script:assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'package-release.ps1')

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    $script:assertions++
    if ($Actual -cne $Expected) { throw "断言失败：$Message；实际='$Actual'，预期='$Expected'" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "断言失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "断言失败：应拒绝 $Message" }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$assetPairs = @(
    @{ Path='wirex_bridge.exe'; Name='wirex_bridge.exe' },
    @{ Path='docs/连接配置.md'; Name='docs__connection-profile.md' },
    @{ Path='docs/音量调节.md'; Name='docs__audio-gain.md' },
    @{ Path='licenses/dmr_signal/NOTICE.md'; Name='licenses__dmr-signal__NOTICE.md' },
    @{ Path='licenses/droidstar_mbe/ISC-NOTICE.txt'; Name='licenses__droidstar-mbe__ISC-NOTICE.txt' },
    @{ Path='private/device-y.bin'; Name='private__device-y.bin' }
)
foreach ($pair in $assetPairs) {
    Assert-Equal (Get-ReleaseAssetName -RelativePath $pair.Path) $pair.Name "ASCII asset 映射 $($pair.Path)"
    Assert-True ($pair.Name -cmatch '^[A-Za-z0-9._-]+$') "asset_name 仅含 ASCII 字符：$($pair.Name)"
}
$mappedPaths = @(Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' })
$mappedAssetNames = @($mappedPaths | ForEach-Object { Get-ReleaseAssetName -RelativePath $_ })
Assert-True (@($mappedAssetNames | Sort-Object -Unique).Count -eq $mappedAssetNames.Count) `
    '所有固定文件的 GitHub asset 名称均唯一'
Assert-True (@($mappedAssetNames | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' }).Count -eq 0) `
    '所有固定文件的 GitHub asset 名称均为 ASCII'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.1') '候选版本格式可用'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.2') 'alpha.2 明确版本允许'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.3') 'alpha.3 明确版本允许'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.4') 'alpha.4 明确版本允许'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.5') 'alpha.5 明确版本允许'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.9') 'alpha.9 明确版本允许'
Assert-True (-not (Test-ReleaseVersion -Value 'v0.1.0')) '正式版本格式不能混入 alpha 标签'
Assert-True (-not (Test-ReleaseVersion -Value 'v0.2.0-alpha.1')) '未登记的 alpha 版本必须拒绝'
Assert-True (-not (Test-ReleaseVersion -Value 'V0.1.0-ALPHA.1')) '版本匹配区分大小写'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'docs/未知文件.md' } '未列入白名单的文件路径'
Assert-Throws { Get-ReleaseAssetName -RelativePath '../private/secret.txt' } '越界路径'

$expectedTests = @(Get-ExpectedReleaseTests)
Assert-Equal $expectedTests.Count 27 '正式 builder 测试清单数'
Assert-True (@($expectedTests | Select-Object -Unique).Count -eq $expectedTests.Count) 'builder 测试名称不重复'
$alpha1Files = @(Get-ExpectedReleasePackageFiles)
Assert-Equal $alpha1Files.Count 17 'alpha.1 固定本地文件数含 manifest'
Assert-True ($alpha1Files -cnotcontains 'start-ui.cmd') 'alpha.1 清单不接收 alpha.2 UI 文件'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.2')
$alpha2Files = @(Get-ExpectedReleasePackageFiles)
$alpha2Tests = @(Get-ExpectedReleaseTests)
$alpha2Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.2'
Assert-Equal $alpha2Files.Count 27 'alpha.2 固定本地文件数含 manifest'
Assert-Equal $alpha2Tests.Count 28 'alpha.2 builder 测试数含 ui_pipe_test'
Assert-True ($alpha2Tests[14] -ceq 'bounded_pipe_writer_test' -and
    $alpha2Tests[15] -ceq 'ui_pipe_test' -and $alpha2Tests[16] -ceq 'console_lifecycle_test') `
    'alpha.2 ui_pipe_test 顺序与 builder 清单一致'
$builderTestLines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-bm-bridge.ps1') -Encoding UTF8 |
    Where-Object { $_ -match "^\s*@\{\s*Name='[^']+';\s*Source='tests\\" })
$builderTestNames = @($builderTestLines | ForEach-Object { [regex]::Match($_, "Name='([^']+)'").Groups[1].Value })
$builderAlpha3Prefix = @($builderTestNames | Select-Object -First 35)
Assert-True ($alpha2Tests.Count -eq 28 -and $alpha2Tests[15] -ceq 'ui_pipe_test') `
    'alpha.2 retains its historical 28-test manifest independently of the current builder'
Assert-True ($alpha2Files -ccontains 'start-ui.cmd' -and $alpha2Files -ccontains 'start-ui.ps1' -and
    $alpha2Files -ccontains 'ui/windows/SettingsWindow.xaml') 'alpha.2 允许清单中的桌面入口和设置窗口'
foreach ($entry in @(
    @{ Source='tools\start-ui.cmd'; Destination='start-ui.cmd' },
    @{ Source='tools\start-ui.ps1'; Destination='start-ui.ps1' },
    @{ Source='tools\bridge-user-config.psm1'; Destination='bridge-user-config.psm1' },
    @{ Source='tools\start-bm-radio-bridge.ps1'; Destination='start-bm-radio-bridge.ps1' }
)) {
    Assert-True (@($alpha2Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $entry.Source -and [string]$_.Destination -ceq $entry.Destination
    }).Count -eq 1) "alpha.2 package source mapping is fixed: $($entry.Source)"
}
Assert-True ((Get-ReleaseAssetName -RelativePath 'start-ui.cmd') -ceq 'start-ui.cmd') `
    '选择 alpha.2 profile 后 UI asset 映射启用'
$alpha3Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.3'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.3')
$alpha3Files = @(Get-ExpectedReleasePackageFiles)
$alpha3Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha3Files.Count 28 'alpha.3 固定本地文件数含 manifest 和身份说明'
Assert-Equal $alpha3Tests.Count 35 'alpha.3 builder 测试数为精确 35 项'
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md') -ceq 'docs__bm-call-identity.md') `
    'alpha.3 identity guide has a fixed ASCII asset mapping'
Assert-True (@($alpha3Profile.SourceFiles | Where-Object {
    [string]$_.Source -ceq 'docs\BM来话身份显示.md' -and [string]$_.Destination -ceq 'docs\BM来话身份显示.md'
}).Count -eq 1) 'alpha.3 package includes the BM call-identity guide'
$alpha3ReadmeMap = @($alpha3Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha3ReadmeMap.Count 1 'alpha.3 has exactly one README source mapping'
Assert-True ([string]$alpha3ReadmeMap[0].Source -ceq 'docs\releases\v0.1.0-alpha.3-package-README.md') `
    'alpha.3 package copies its own versioned README'
Assert-True ($alpha3Profile.ReleaseScope -match 'per-accepted-call DMR Source ID label' -and
    @($alpha3Profile.NotIncluded | Where-Object { $_ -match 'RF node operation is not implemented' }).Count -eq 1) `
    'alpha.3 package scope states identity behavior and RF omission explicitly'
Assert-True ($builderTestNames.Count -ge $alpha3Tests.Count) '当前 builder 保留 alpha.3 的固定历史测试前缀'
Assert-Equal $builderAlpha3Prefix.Count $alpha3Tests.Count 'alpha.3 固定测试列表与当前 builder 的首 35 项分开比较'
for ($testIndex = 0; $testIndex -lt $alpha3Tests.Count; $testIndex++) {
    Assert-True ($builderAlpha3Prefix[$testIndex] -ceq $alpha3Tests[$testIndex]) `
        "alpha.3 fixed test list matches builder source order at index $testIndex"
}
$alpha4Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.4'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.4')
$alpha4Files = @(Get-ExpectedReleasePackageFiles)
$alpha4Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha4Files.Count $alpha3Files.Count 'alpha.4 保留 alpha.3 全部便携运行文件'
Assert-Equal $alpha4Tests.Count 35 'alpha.4 固定保留历史 35 项测试清单'
Assert-True ($alpha4Tests.Count -eq $alpha3Tests.Count) 'alpha.4 沿用 alpha.3 的历史测试清单'
for ($testIndex = 0; $testIndex -lt $alpha4Tests.Count; $testIndex++) {
    Assert-True ($alpha4Tests[$testIndex] -ceq $alpha3Tests[$testIndex]) `
        "alpha.4 preserves alpha.3 historical test order at index $testIndex"
}
Assert-True ($alpha4Profile.ReleaseScope -match 'independent receive and transmit targets' -and
    $alpha4Profile.ReleaseScope -match 'listen-only TG91' -and
    $alpha4Profile.ReleaseScope -match 'BM China 4602') `
    'alpha.4 包配置说明独立收发目标、TG91只收和4602预设'
Assert-True (@($alpha4Profile.NotIncluded | Where-Object { $_ -match 'RF node operation is not implemented' }).Count -eq 1 -and
    @($alpha4Profile.NotIncluded | Where-Object { $_ -match 'PTT behavior during Echo playback still requires alpha.4 device verification' }).Count -eq 1) `
    'alpha.4 明确列出RF范围和鹦鹉回音PTT实机待验'
$alpha4ReadmeMap = @($alpha4Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha4ReadmeMap.Count 1 'alpha.4 有且只有一个随包 README'
Assert-True ([string]$alpha4ReadmeMap[0].Source -ceq 'docs\releases\v0.1.0-alpha.4-package-README.md') `
    'alpha.4 package copies its own versioned README'
$alpha4ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha4ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha4ReadmeText.Contains('43.129.83.124:62031') -and
    $alpha4ReadmeText.Contains('接收 `91/G/TS2`') -and
    $alpha4ReadmeText.Contains('发射 `460997/P/TS2`') -and
    $alpha4ReadmeText.Contains('默认保存在便携目录的 `private/user-config`') -and
    $alpha4ReadmeText.Contains('-UserConfigDirectory') -and
    $alpha4ReadmeText.Contains('请在本版实机验收中')) `
    'alpha.4 README 写明4602、独立收发目标、配置目录和PTT实机待验'
Assert-Equal (Get-ReleaseAssetName -RelativePath 'start-ui.cmd') 'start-ui.cmd' `
    'alpha.4 保留 alpha.3 的绿色启动入口'

$alpha5Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.5'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.5')
$alpha5Files = @(Get-ExpectedReleasePackageFiles)
$alpha5Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha5Files.Count ($alpha4Files.Count + 6) 'alpha.5 在 alpha.4 运行文件上增加两份迁移/协议文档和四个测试入口文件'
Assert-Equal $alpha5Tests.Count 36 'alpha.5 包记录原35项测试和IPC v2新测试'
Assert-True ($builderTestNames.Count -ge $alpha5Tests.Count) '当前 builder 保留 alpha.5 的固定测试前缀'
$expectedAlpha5Tests = @($alpha4Tests + 'ui_control_protocol_v2_test')
for ($testIndex = 0; $testIndex -lt $alpha5Tests.Count; $testIndex++) {
    Assert-True ($alpha5Tests[$testIndex] -ceq $expectedAlpha5Tests[$testIndex]) `
        "alpha.5 profile inserts the IPC v2 test without reordering historical tests at index $testIndex"
    Assert-True ($builderTestNames[$testIndex] -ceq $expectedAlpha5Tests[$testIndex]) `
        "alpha.5 fixed test list matches builder source order at index $testIndex"
}
Assert-Equal $alpha5Tests[35] 'ui_control_protocol_v2_test' 'alpha.5 appends the IPC v2 protocol test as item 36'
Assert-Equal $alpha5Files.Count 34 'alpha.5 fixed package file count includes manifest'
foreach ($mapping in @(
    @{ Source='docs\releases\v0.1.0-alpha.5-package-README.md'; Destination='README.md' },
    @{ Source='docs\R106_IPC第二版.md'; Destination='docs\R106_IPC第二版.md' },
    @{ Source='docs\R106_配置迁移与测试.md'; Destination='docs\R106_配置迁移与测试.md' },
    @{ Source='tools\start-step1-test.cmd'; Destination='start-step1-test.cmd' },
    @{ Source='tools\start-step1-test.ps1'; Destination='start-step1-test.ps1' },
    @{ Source='tools\test-control.cmd'; Destination='test-control.cmd' },
    @{ Source='tools\test-control.ps1'; Destination='test-control.ps1' }
)) {
    Assert-True (@($alpha5Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.5 source mapping is fixed: $($mapping.Source)"
}
Assert-Equal (Get-ReleaseAssetName -RelativePath 'docs/R106_配置迁移与测试.md') 'docs__r106-profile-migration-test.md' `
    'alpha.5 Unicode migration document has an ASCII asset name'
Assert-Equal (Get-ReleaseAssetName -RelativePath 'docs/R106_IPC第二版.md') 'docs__r106-ipc-v2.md' `
    'alpha.5 IPC v2 guide has an ASCII asset name'
Assert-True ($alpha5Profile.ReleaseScope -match 'Step 1' -and
    $alpha5Profile.ReleaseScope -match 'schema-2 configuration migration' -and
    $alpha5Profile.ReleaseScope -match 'multi-group runtime is not implemented') `
    'alpha.5 scope labels the first step and excludes multi-group runtime'
Assert-True (@($alpha5Profile.NotIncluded | Where-Object { $_ -match 'multi-group runtime' }).Count -eq 1 -and
    @($alpha5Profile.NotIncluded | Where-Object { $_ -match 'hardware validation' }).Count -eq 1) `
    'alpha.5 names the unsupported multi-group runtime and missing hardware validation'
$alpha5ReadmeMap = @($alpha5Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha5ReadmeMap.Count 1 'alpha.5 has exactly one package README'
Assert-True ([string]$alpha5ReadmeMap[0].Source -ceq 'docs\releases\v0.1.0-alpha.5-package-README.md') `
    'alpha.5 package copies its own versioned README'
$alpha5ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha5ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha5ReadmeText.Contains('test-control.cmd') -and
    $alpha5ReadmeText.Contains('start-step1-test.cmd') -and
    $alpha5ReadmeText.Contains('R106_IPC第二版.md') -and
    $alpha5ReadmeText.Contains('schema_version') -and
    $alpha5ReadmeText.Contains('多组运行') -and
    $alpha5ReadmeText.Contains('不支持') -and
    $alpha5ReadmeText.Contains('音频') -and
    $alpha5ReadmeText.Contains('BrandMeister')) `
    'alpha.5 README documents the protocol diagnostic, schema migration, and the runtime limitation'
Assert-True ($alpha5ReadmeText.Contains('connection-profile.json') -and
    $alpha5ReadmeText.Contains('audio-settings.json') -and
    $alpha5ReadmeText.Contains('password-file-path.txt') -and
    $alpha5ReadmeText.Contains('通用 manifest') -and
    $alpha5ReadmeText.Contains('无需手工编辑 JSON') -and
    $alpha5ReadmeText.Contains('不会复制或读取密码文件内容')) `
    'alpha.5 README separates local approved config copies from the generic package and excludes password contents'
$alpha5HandoffText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'docs\releases\v0.1.0-alpha.5-step1-handoff.md'), [System.Text.Encoding]::UTF8)
Assert-True ($alpha5HandoffText.Contains('在测试配置副本放入前') -and
    $alpha5HandoffText.Contains('通用 manifest 完成审计后') -and
    $alpha5HandoffText.Contains('不需要手动编辑或输入配置 JSON')) `
    'alpha.5 handoff orders the generic manifest audit before local config preparation and avoids manual JSON steps'
foreach ($commandPath in @('tools\test-control.cmd','tools\start-step1-test.cmd')) {
    $commandBytes = [System.IO.File]::ReadAllBytes((Join-Path $repositoryRoot $commandPath))
    Assert-True (@($commandBytes | Where-Object { $_ -gt 127 }).Count -eq 0) "$commandPath is ASCII-only"
    $commandText = [System.Text.Encoding]::ASCII.GetString($commandBytes)
    Assert-True ($commandText.Contains("`r`n") -and -not $commandText.Replace("`r`n", '').Contains("`n")) `
        "$commandPath uses Windows CRLF line endings"
    if ($commandPath -ceq 'tools\test-control.cmd') {
        $successMessageAt = $commandText.IndexOf('Protocol diagnostic passed. Press any key to close.', [System.StringComparison]::Ordinal)
        $successPauseAt = if ($successMessageAt -ge 0) {
            $commandText.IndexOf('pause', $successMessageAt, [System.StringComparison]::OrdinalIgnoreCase)
        } else { -1 }
        Assert-True ($successMessageAt -ge 0 -and $successPauseAt -gt $successMessageAt) `
            'test-control keeps the successful diagnostic result visible until a keypress'
    } else {
        Assert-True (-not $commandText.Contains('passed. Press any key') -and
            $commandText.Contains('Step 1 test UI failed.') -and $commandText.Contains('pause')) `
            'start-step1-test retains failure-only pause behavior without waiting after a successful UI launch'
    }
}
foreach ($scriptPath in @('tools\test-control.ps1','tools\start-step1-test.ps1')) {
    $fullScriptPath = Join-Path $repositoryRoot $scriptPath
    $scriptBytes = [System.IO.File]::ReadAllBytes($fullScriptPath)
    Assert-True ($scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and
        $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF) "$scriptPath has a UTF-8 BOM for Windows PowerShell"
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($fullScriptPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$scriptPath parses in Windows PowerShell"
}
$controlScriptPath = Join-Path $repositoryRoot 'tools\test-control.ps1'
$controlTokens = $null
$controlParseErrors = $null
$controlScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $controlScriptPath, [ref]$controlTokens, [ref]$controlParseErrors)
$controlExecutableParameter = @($controlScriptAst.ParamBlock.Parameters | Where-Object {
    [string]$_.Name.VariablePath.UserPath -ceq 'ExecutablePath'
})
Assert-True ($controlParseErrors.Count -eq 0 -and $controlExecutableParameter.Count -eq 1 -and
    $null -eq $controlExecutableParameter[0].DefaultValue) `
    'test-control defers its package-relative path until after parameter binding'
$controlScriptText = [System.IO.File]::ReadAllText($controlScriptPath, [System.Text.Encoding]::UTF8)
Assert-True ($controlScriptText.Contains('$ExecutablePath = Join-Path $PSScriptRoot ''wirex_bridge.exe''')) `
    'test-control resolves an omitted executable argument from its own package directory'
Assert-True (([System.IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools\start-step1-test.ps1'), [System.Text.Encoding]::UTF8)).Contains('private\r106-step1-test-config') -and
    ([System.IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools\start-step1-test.ps1'), [System.Text.Encoding]::UTF8)).Contains('-UserConfigDirectory $resolvedUserConfigDirectory')) `
    'step-one UI entry uses the dedicated test configuration directory explicitly'

$alpha6Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.6'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.6')
$alpha6Files = @(Get-ExpectedReleasePackageFiles)
$alpha6Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha6Files.Count ($alpha5Files.Count + 3) 'alpha.6 在 alpha.5 固定清单上只增加 R108 文档和两个合并入口文件'
Assert-Equal $alpha6Tests.Count 39 'alpha.6 固定记录 39 项 C++ 离线测试'
Assert-Equal $builderTestNames.Count $alpha6Tests.Count 'alpha.6 profile 与 builder 固定测试数量一致'
$alpha6AddedTests = @('talkgroup_routing_test', 'bm_routing_lifecycle_test', 'routing_state_test')
for ($testIndex = 0; $testIndex -lt $alpha5Tests.Count; $testIndex++) {
    Assert-True ($alpha6Tests[$testIndex] -ceq $alpha5Tests[$testIndex]) `
        "alpha.6 keeps alpha.5's fixed test prefix at index $testIndex"
}
for ($testIndex = 0; $testIndex -lt $alpha6AddedTests.Count; $testIndex++) {
    $index = $alpha5Tests.Count + $testIndex
    Assert-True ($alpha6Tests[$index] -ceq $alpha6AddedTests[$testIndex] -and
        $builderTestNames[$index] -ceq $alpha6AddedTests[$testIndex]) `
        "alpha.6 appends the fixed R108 test $($alpha6AddedTests[$testIndex])"
}
Assert-True ((Get-ReleaseProfile -Version 'v0.1.0-alpha.5').TestNames.Count -eq 36 -and
    (Get-ReleaseProfile -Version 'v0.1.0-alpha.5').PackageFiles.Count -eq 34) `
    'alpha.6 additions do not change alpha.5 test or package inventories'
foreach ($mapping in @(
    @{ Source='docs\releases\v0.1.0-alpha.6-package-README.md'; Destination='README.md' },
    @{ Source='docs\R108_收发路由状态与alpha6验收.md'; Destination='docs\R108_收发路由状态与alpha6验收.md' },
    @{ Source='tools\start-merged-test.cmd'; Destination='start-merged-test.cmd' },
    @{ Source='tools\start-merged-test.ps1'; Destination='start-merged-test.ps1' }
)) {
    Assert-True (@($alpha6Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.6 source mapping is fixed: $($mapping.Source)"
}
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/R108_收发路由状态与alpha6验收.md') -ceq 'docs__r108-routing-state-alpha6.md') `
    'alpha.6 R108 guide has a stable ASCII asset name'
Assert-True ($alpha6Profile.ReleaseScope -match 'full schema-2 receive-policy runtime routing' -and
    @($alpha6Profile.NotIncluded | Where-Object { $_ -match 'hardware acceptance record' }).Count -eq 1) `
    'alpha.6 profile describes full runtime policy scope and its hardware evidence boundary'
$alpha6ReadmeMap = @($alpha6Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha6ReadmeMap.Count 1 'alpha.6 has exactly one package README'
Assert-True ([string]$alpha6ReadmeMap[0].Source -ceq 'docs\releases\v0.1.0-alpha.6-package-README.md') `
    'alpha.6 package copies its own versioned README'
$alpha6ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha6ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha6ReadmeText.Contains('private/r108-merged-test-config') -and
    $alpha6ReadmeText.Contains('test-control.cmd')) `
    'alpha.6 README documents its isolated local test entry and standalone control diagnostic'
$alpha6R108Text = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'docs\R108_收发路由状态与alpha6验收.md'), [System.Text.Encoding]::UTF8)
Assert-True ($alpha6R108Text.Contains('routing-state.json') -and
    $alpha6R108Text.Contains('password-file-path.txt')) `
    'alpha.6 R108 guide documents the per-run routing file and local password-file path pointer'
$alpha6LauncherText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'tools\start-merged-test.ps1'), [System.Text.Encoding]::UTF8)
Assert-True ($alpha6LauncherText.Contains('private\r108-merged-test-config') -and
    $alpha6LauncherText.Contains('UserConfigDirectory = $userConfigDirectory') -and
    -not $alpha6LauncherText.Contains('NoAutoConnect')) `
    'alpha.6 merged entry uses its dedicated config directory and standard UI startup behavior'
$alpha6CommandPath = Join-Path $repositoryRoot 'tools\start-merged-test.cmd'
$alpha6CommandBytes = [System.IO.File]::ReadAllBytes($alpha6CommandPath)
Assert-True (@($alpha6CommandBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'start-merged-test.cmd is ASCII-only'
$alpha6CommandText = [System.Text.Encoding]::ASCII.GetString($alpha6CommandBytes)
Assert-True ($alpha6CommandText.Contains("`r`n") -and -not $alpha6CommandText.Replace("`r`n", '').Contains("`n")) `
    'start-merged-test.cmd uses Windows CRLF line endings'
$alpha6LauncherPath = Join-Path $repositoryRoot 'tools\start-merged-test.ps1'
$alpha6Tokens = $null
$alpha6ParseErrors = $null
$alpha6Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $alpha6LauncherPath, [ref]$alpha6Tokens, [ref]$alpha6ParseErrors)
$alpha6EntryDirectory = @($alpha6Ast.ParamBlock.Parameters | Where-Object {
    [string]$_.Name.VariablePath.UserPath -ceq 'UserConfigDirectory'
})
Assert-True ($alpha6ParseErrors.Count -eq 0 -and $alpha6EntryDirectory.Count -eq 0) `
    ('alpha.6 launcher parses on Windows PowerShell and fixes its isolated config path; parse errors={0}, mutable config parameters={1}' -f
        $alpha6ParseErrors.Count, $alpha6EntryDirectory.Count)

$alpha7Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.7'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.7')
$alpha7Files = @(Get-ExpectedReleasePackageFiles)
$alpha7Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha7Files.Count ($alpha6Files.Count + 2) 'alpha.7 在 alpha.6 清单上只增加两份 R109 文档'
Assert-Equal $alpha7Tests.Count 39 'alpha.7 沿用 39 项 C++ 离线测试'
Assert-True ([string]::Join('|', $alpha7Tests) -ceq [string]::Join('|', $alpha6Tests) -and
    $builderTestNames.Count -eq $alpha7Tests.Count) 'alpha.7 keeps the full alpha.6 test order and count'
foreach ($mapping in @(
    @{ Source='docs\releases\v0.1.0-alpha.7-package-README.md'; Destination='README.md' },
    @{ Source='docs\R109_下行状态与动态组修复.md'; Destination='docs\R109_下行状态与动态组修复.md' },
    @{ Source='docs\R109_动态组激活实现.md'; Destination='docs\R109_动态组激活实现.md' },
    @{ Source='tools\start-merged-test-alpha7.cmd'; Destination='start-merged-test.cmd' },
    @{ Source='tools\start-merged-test-alpha7.ps1'; Destination='start-merged-test.ps1' }
)) {
    Assert-True (@($alpha7Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.7 source mapping is fixed: $($mapping.Source)"
}
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/R109_下行状态与动态组修复.md') -ceq 'docs__r109-downlink-dynamic-groups.md') `
    'alpha.7 R109 guide has a stable ASCII asset name'
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/R109_动态组激活实现.md') -ceq 'docs__r109-dynamic-group-activation.md') `
    'alpha.7 dynamic-group guide has a stable ASCII asset name'
Assert-True (-not ($alpha7Files -contains 'include/wirex/quick_call.hpp')) `
    'quick_call.hpp remains a source build input and is not a runtime package asset'
$alpha7ReadmeMap = @($alpha7Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha7ReadmeMap.Count 1 'alpha.7 has exactly one package README'
$alpha7ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha7ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha7ReadmeText.Contains('private/r109-merged-test-config') -and
    $alpha7ReadmeText.Contains('加入本机收听') -and $alpha7ReadmeText.Contains('激活动态组') -and
    $alpha7ReadmeText.Contains('一个 header 和一个 EOT') -and
    $alpha7ReadmeText.Contains('rx_call_accepted_voice_bursts')) `
    'alpha.7 README documents the isolated entry, separate dynamic-group actions, and empty-call diagnostics'
$alpha7NotesText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'docs\releases\v0.1.0-alpha.7.md'), [System.Text.Encoding]::UTF8)
Assert-True ($alpha7NotesText.Contains('local-hri-downlink-0304eff') -and
    $alpha7NotesText.Contains('TG91 的所有中断原因仍未查明') -and
    $alpha7NotesText.Contains('红色 LED 没有在 R109 中修复或解释')) `
    'alpha.7 notes state that the LED and all TG91 interruption causes remain unresolved'
$alpha7LauncherPath = Join-Path $repositoryRoot 'tools\start-merged-test-alpha7.ps1'
$alpha7LauncherText = [System.IO.File]::ReadAllText($alpha7LauncherPath, [System.Text.Encoding]::UTF8)
Assert-True ($alpha7LauncherText.Contains('private\r109-merged-test-config') -and
    $alpha7LauncherText.Contains('UserConfigDirectory = $userConfigDirectory') -and
    -not $alpha7LauncherText.Contains('NoAutoConnect')) `
    'alpha.7 merged entry uses its dedicated config directory and normal UI startup behavior'
$alpha7CmdPath = Join-Path $repositoryRoot 'tools\start-merged-test-alpha7.cmd'
$alpha7CmdBytes = [System.IO.File]::ReadAllBytes($alpha7CmdPath)
Assert-True (@($alpha7CmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'alpha.7 cmd entry is ASCII-only'
$alpha7CmdText = [System.Text.Encoding]::ASCII.GetString($alpha7CmdBytes)
Assert-True ($alpha7CmdText.Contains('alpha7 local test') -and $alpha7CmdText.Contains("`r`n") -and
    -not $alpha7CmdText.Replace("`r`n", '').Contains("`n")) 'alpha.7 cmd entry has its own title and Windows CRLF line endings'
$alpha7LauncherBytes = [System.IO.File]::ReadAllBytes($alpha7LauncherPath)
Assert-True ($alpha7LauncherBytes.Length -ge 3 -and $alpha7LauncherBytes[0] -eq 0xEF -and
    $alpha7LauncherBytes[1] -eq 0xBB -and $alpha7LauncherBytes[2] -eq 0xBF) `
    'alpha.7 launcher has a UTF-8 BOM so Windows PowerShell 5.1 reads its Chinese strings correctly'
$alpha7Tokens = $null
$alpha7ParseErrors = $null
$alpha7Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $alpha7LauncherPath, [ref]$alpha7Tokens, [ref]$alpha7ParseErrors)
$alpha7EntryDirectory = @($alpha7Ast.ParamBlock.Parameters | Where-Object {
    [string]$_.Name.VariablePath.UserPath -ceq 'UserConfigDirectory'
})
Assert-True ($alpha7ParseErrors.Count -eq 0 -and $alpha7EntryDirectory.Count -eq 0) `
    ('alpha.7 launcher parses and fixes its isolated config path; parse errors={0}, mutable config parameters={1}' -f
        $alpha7ParseErrors.Count, $alpha7EntryDirectory.Count)

$alpha8Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.8'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.8')
$alpha8Files = @(Get-ExpectedReleasePackageFiles)
$alpha8Tests = @(Get-ExpectedReleaseTests)
$alpha8ExcludedPaths = @(
    'start-bm-radio-bridge.cmd', 'start-listen-91.cmd', 'start-profile.cmd',
    'start-ui.cmd', 'start-user-config.cmd', 'start-user-config.ps1',
    'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1',
    'start-merged-test.cmd', 'start-merged-test.ps1'
)
Assert-Equal $alpha8Files.Count ($alpha7Files.Count - $alpha8ExcludedPaths.Count + 2) `
    'alpha.8 只保留一个用户 CMD 入口和一个子目录 PowerShell 入口'
Assert-Equal $alpha8Tests.Count $alpha7Tests.Count 'alpha.8 沿用 alpha.7 的 39 项 C++ 离线测试清单'
Assert-True (@($alpha8Files | Where-Object { [string]$_ -match '\.cmd$' }).Count -eq 1 -and
    $alpha8Files -ccontains 'start-wirex-bridge.cmd' -and
    $alpha8Files -ccontains 'tools/start-wirex-bridge.ps1') `
    'alpha.8 包清单只含根目录的 start-wirex-bridge.cmd 入口'
foreach ($path in $alpha8ExcludedPaths) {
    Assert-True (-not ($alpha8Files -ccontains $path)) "alpha.8 package excludes obsolete entry $path"
}
foreach ($requiredPath in @('start-ui.ps1','start-bm-radio-bridge.ps1','bridge-user-config.psm1',
    'ui/windows/bridge-ui.ps1','ui/windows/BridgeSupervisor.cs','ui/windows/MainWindow.xaml',
    'ui/windows/SettingsWindow.xaml','private/device-y.bin')) {
    Assert-True ($alpha8Files -ccontains $requiredPath) "alpha.8 preserves runtime dependency $requiredPath"
}
foreach ($mapping in @(
    @{ Source='docs\releases\v0.1.0-alpha.8-package-README.md'; Destination='README.md' },
    @{ Source='tools\start-wirex-bridge-alpha8.cmd'; Destination='start-wirex-bridge.cmd' },
    @{ Source='tools\start-wirex-bridge-alpha8.ps1'; Destination='tools\start-wirex-bridge.ps1' }
)) {
    Assert-True (@($alpha8Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.8 source mapping is fixed: $($mapping.Source)"
}
$alpha8CmdPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha8.cmd'
$alpha8CmdBytes = [System.IO.File]::ReadAllBytes($alpha8CmdPath)
Assert-True (@($alpha8CmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'alpha.8 CMD source contains ASCII only'
$alpha8CmdText = [System.Text.Encoding]::ASCII.GetString($alpha8CmdBytes)
Assert-True ($alpha8CmdText.Contains('powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass') -and
    $alpha8CmdText.Contains('"%~dp0tools\start-wirex-bridge.ps1" %*') -and
    $alpha8CmdText.Contains('exit /b %_wirex_exit%') -and $alpha8CmdText.Contains("`r`n") -and
    -not $alpha8CmdText.Replace("`r`n", '').Contains("`n")) `
    'alpha.8 CMD forwards quoted paths and arguments through PowerShell while preserving the exit code'
$alpha8LauncherPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha8.ps1'
$alpha8LauncherBytes = [System.IO.File]::ReadAllBytes($alpha8LauncherPath)
Assert-True ($alpha8LauncherBytes.Length -ge 3 -and $alpha8LauncherBytes[0] -eq 0xEF -and
    $alpha8LauncherBytes[1] -eq 0xBB -and $alpha8LauncherBytes[2] -eq 0xBF) `
    'alpha.8 technical entry uses UTF-8 BOM for Windows PowerShell 5.1'
$alpha8Tokens = $null
$alpha8ParseErrors = $null
$alpha8Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $alpha8LauncherPath, [ref]$alpha8Tokens, [ref]$alpha8ParseErrors)
Assert-True ($alpha8ParseErrors.Count -eq 0) `
    ('alpha.8 technical entry parses in Windows PowerShell; parse errors={0}' -f $alpha8ParseErrors.Count)
$alpha8ReadmeMap = @($alpha8Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha8ReadmeMap.Count 1 'alpha.8 has exactly one package README'
$alpha8ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha8ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha8ReadmeText.Contains('start-wirex-bridge.cmd') -and
    $alpha8ReadmeText.Contains('private/user-config-directory.txt') -and
    $alpha8ReadmeText.Contains('config-backups/R110') -and
    $alpha8ReadmeText.Contains('密码文件内容') -and
    -not $alpha8ReadmeText.Contains('test-control.cmd')) `
    'alpha.8 README points users to one command and documents the local-only configuration boundary'

$alpha9Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.9'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.9')
$alpha9NotIncluded = @($alpha9Profile.NotIncluded)
Assert-True (@($alpha9NotIncluded | Where-Object { $_ -match 'slot_flags defaults to 4 \(simplex\)' }).Count -eq 1 -and
    @($alpha9NotIncluded | Where-Object { $_ -match 'dual-slot DMR RF or simultaneous two-slot playback' }).Count -eq 1 -and
    @($alpha9NotIncluded | Where-Object { $_ -match 'not C4FM DG-ID' }).Count -eq 1) `
    'alpha.9 release scope separates software timeslot fields and DMR CC from unverified FTX-1 dual-slot RF and C4FM DG-ID'
$alpha9Files = @(Get-ExpectedReleasePackageFiles)
$alpha9Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha9Files.Count ($alpha8Files.Count + 4) 'alpha.9 只增加 RadioIdentity runtime 模块和三份 R111 文档'
Assert-Equal $alpha9Tests.Count 39 'alpha.9 沿用 alpha.8 的 39 项 C++ 离线测试'
Assert-True ([string]::Join('|', $alpha9Tests) -ceq [string]::Join('|', $alpha8Tests)) `
    'alpha.9 keeps the complete alpha.8 C++ test order'
Assert-True (@($alpha9Files | Where-Object { [string]$_ -match '\.cmd$' }).Count -eq 1 -and
    $alpha9Files -ccontains 'start-wirex-bridge.cmd' -and
    $alpha9Files -ccontains 'tools/start-wirex-bridge.ps1') `
    'alpha.9 keeps one root CMD and one technical PowerShell launcher'
foreach ($requiredPath in @(
    'ui/windows/RadioIdentity.psm1',
    'docs/R111_UI与音量.md',
    'docs/R111_BM订阅与收听优先级.md',
    'docs/R111_用户资料与电台显示.md'
)) {
    Assert-True ($alpha9Files -ccontains $requiredPath) "alpha.9 package includes $requiredPath"
}
foreach ($forbiddenPath in @('tools/test-radio-identity.ps1','tools/test-radio-identity-http-server.ps1',
    'radio-identity-cache.json','channel-favorites.json',
    'private/user-config-directory.txt','connection-profile.json','audio-settings.json','bm-device-password.txt')) {
    Assert-True (-not ($alpha9Files -contains $forbiddenPath)) "alpha.9 package excludes private/developer file $forbiddenPath"
}
foreach ($mapping in @(
    @{ Source='docs\releases\v0.1.0-alpha.9-package-README.md'; Destination='README.md' },
    @{ Source='tools\start-wirex-bridge-alpha9.cmd'; Destination='start-wirex-bridge.cmd' },
    @{ Source='tools\start-wirex-bridge-alpha9.ps1'; Destination='tools\start-wirex-bridge.ps1' },
    @{ Source='ui\windows\RadioIdentity.psm1'; Destination='ui\windows\RadioIdentity.psm1' },
    @{ Source='docs\R111_UI与音量.md'; Destination='docs\R111_UI与音量.md' },
    @{ Source='docs\R111_BM订阅与收听优先级.md'; Destination='docs\R111_BM订阅与收听优先级.md' },
    @{ Source='docs\R111_用户资料与电台显示.md'; Destination='docs\R111_用户资料与电台显示.md' }
)) {
    Assert-True (@($alpha9Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.9 source mapping is fixed: $($mapping.Source)"
}
foreach ($pair in @(
    @{ Path='ui/windows/RadioIdentity.psm1'; Name='ui__windows__radio-identity.psm1' },
    @{ Path='docs/R111_UI与音量.md'; Name='docs__r111-ui-audio.md' },
    @{ Path='docs/R111_BM订阅与收听优先级.md'; Name='docs__r111-bm-listening-policy.md' },
    @{ Path='docs/R111_用户资料与电台显示.md'; Name='docs__r111-radio-identity-display.md' }
)) {
    Assert-True ((Get-ReleaseAssetName -RelativePath $pair.Path) -ceq $pair.Name) `
        "alpha.9 fixed ASCII asset mapping $($pair.Path)"
}
$alpha9CmdPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha9.cmd'
$alpha9CmdBytes = [System.IO.File]::ReadAllBytes($alpha9CmdPath)
Assert-True (@($alpha9CmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'alpha.9 CMD source contains ASCII only'
$alpha9CmdText = [System.Text.Encoding]::ASCII.GetString($alpha9CmdBytes)
Assert-True ($alpha9CmdText.Contains('powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass') -and
    $alpha9CmdText.Contains('"%~dp0tools\start-wirex-bridge.ps1" %*') -and
    $alpha9CmdText.Contains('exit /b %_wirex_exit%') -and $alpha9CmdText.Contains("`r`n") -and
    -not $alpha9CmdText.Replace("`r`n", '').Contains("`n")) `
    'alpha.9 CMD preserves the alpha.8 argument, path, and exit-code forwarding contract'
$alpha9LauncherPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha9.ps1'
$alpha9LauncherBytes = [System.IO.File]::ReadAllBytes($alpha9LauncherPath)
Assert-True ($alpha9LauncherBytes.Length -ge 3 -and $alpha9LauncherBytes[0] -eq 0xEF -and
    $alpha9LauncherBytes[1] -eq 0xBB -and $alpha9LauncherBytes[2] -eq 0xBF) `
    'alpha.9 technical entry has a UTF-8 BOM for Windows PowerShell 5.1'
$alpha9Tokens = $null
$alpha9ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $alpha9LauncherPath, [ref]$alpha9Tokens, [ref]$alpha9ParseErrors) | Out-Null
Assert-True ($alpha9ParseErrors.Count -eq 0) `
    ('alpha.9 technical entry parses; parse errors={0}' -f $alpha9ParseErrors.Count)
$alpha9LauncherText = [System.IO.File]::ReadAllText($alpha9LauncherPath, [System.Text.Encoding]::UTF8)
Assert-True ($alpha9LauncherText.Contains('alpha.9') -and -not $alpha9LauncherText.Contains('alpha.8')) `
    'alpha.9 startup failure text uses the current package version'
$alpha9ReadmeMap = @($alpha9Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha9ReadmeMap.Count 1 'alpha.9 has exactly one package README'
$alpha9ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha9ReadmeMap[0].Source), [System.Text.Encoding]::UTF8)
Assert-True ($alpha9ReadmeText.Contains('RadioID 查询只在用户点击') -and
    $alpha9ReadmeText.Contains('radio-identity-cache.json') -and
    $alpha9ReadmeText.Contains('最近 50 条真实通话记录') -and
    $alpha9ReadmeText.Contains('不按 CC 过滤') -and
    $alpha9ReadmeText.Contains('FTX-1 屏幕上的实际内容仍未知')) `
    'alpha.9 README documents implemented boundaries and keeps identity cache local'
$alpha9IdentityText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'docs\R111_用户资料与电台显示.md'), [System.Text.Encoding]::UTF8)
Assert-True ($alpha9IdentityText.Contains('UserConfigDirectory') -and
    -not $alpha9IdentityText.Contains('%LOCALAPPDATA%') -and
    $alpha9IdentityText.Contains('呼号显示实现路径（待实机确认）')) `
    'alpha.9 identity guide uses the canonical cache path and keeps LCD confirmation pending'

$alpha10Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.10'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.10')
$alpha10NotIncluded = @($alpha10Profile.NotIncluded)
Assert-True (@($alpha10NotIncluded | Where-Object { $_ -ceq 'FTX-1 LCD source-identity display is not implemented' }).Count -eq 1 -and
    @($alpha10NotIncluded | Where-Object { $_ -ceq 'FM and C4FM RF transmit paths are not implemented' }).Count -eq 1) `
    'alpha.10 metadata clearly records that LCD display and FM/C4FM RF transmit are not implemented'
$alpha10Files = @(Get-ExpectedReleasePackageFiles)
$alpha10Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha10Files.Count $alpha9Files.Count 'alpha.10 用三份 R112 文档替换三份 R111 文档，文件数不变'
Assert-Equal $alpha10Tests.Count 39 'alpha.10 沿用39项离线原生测试'
Assert-True ([string]::Join('|', $alpha10Tests) -ceq [string]::Join('|', $alpha9Tests)) `
    'alpha.10 keeps the complete alpha.9 native test order'
Assert-True (@($alpha10Files | Where-Object { [string]$_ -match '\.cmd$' }).Count -eq 1 -and
    $alpha10Files -ccontains 'start-wirex-bridge.cmd') `
    'alpha.10 keeps exactly one root CMD entry point'
foreach ($requiredPath in @(
    'ui/windows/RadioIdentity.psm1',
    'docs/R112_A_身份查询实施.md',
    'docs/R112_A_网络音频指标.md',
    'docs/R112_A_UI精简.md'
)) {
    Assert-True ($alpha10Files -ccontains $requiredPath) "alpha.10 package includes $requiredPath"
}
foreach ($historicalPath in @(
    'docs/R111_UI与音量.md',
    'docs/R111_BM订阅与收听优先级.md',
    'docs/R111_用户资料与电台显示.md'
)) {
    Assert-True (-not ($alpha10Files -ccontains $historicalPath)) "alpha.10 package replaces historical guide $historicalPath"
}
foreach ($forbiddenPath in @(
    'tools/test-radio-identity.ps1', 'tools/test-radio-identity-http-server.ps1', 'tools/test-ui-identity.ps1',
    'radio-identity-cache.json', 'channel-favorites.json', 'password-file-path.txt',
    'private/user-config-directory.txt', 'connection-profile.json', 'audio-settings.json', 'bm-device-password.txt'
)) {
    Assert-True (-not ($alpha10Files -contains $forbiddenPath)) "alpha.10 package excludes private/developer file $forbiddenPath"
}
Assert-True (@($alpha10Files | Where-Object { $_ -match '(^|/)test[^/]*\.(?:cmd|ps1)$' }).Count -eq 0) `
    'alpha.10 package excludes every test entry script'
foreach ($mapping in @(
    @{ Source='tools\start-wirex-bridge-alpha10.cmd'; Destination='start-wirex-bridge.cmd' },
    @{ Source='tools\start-wirex-bridge-alpha10.ps1'; Destination='tools/start-wirex-bridge.ps1' },
    @{ Source='docs\R112_A_身份查询实施.md'; Destination='docs\R112_A_身份查询实施.md' },
    @{ Source='docs\R112_A_网络音频指标.md'; Destination='docs\R112_A_网络音频指标.md' },
    @{ Source='docs\R112_A_UI精简.md'; Destination='docs\R112_A_UI精简.md' }
)) {
    Assert-True (@($alpha10Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $mapping.Source -and [string]$_.Destination -ceq $mapping.Destination
    }).Count -eq 1) "alpha.10 source mapping is fixed: $($mapping.Source)"
}
Assert-True (@($alpha10Profile.SourceFiles | Where-Object {
    [string]$_.Source -ceq 'tools\start-wirex-bridge-alpha9.cmd' -or
    [string]$_.Source -ceq 'tools\start-wirex-bridge-alpha9.ps1' -or
    [string]$_.Source -ceq 'docs\releases\v0.1.0-alpha.9-package-README.md' -or
    [string]$_.Source -like 'docs\R111_*'
}).Count -eq 0) 'alpha.10 source profile removes alpha.9 entry and superseded R111 guides'
$alpha10CmdPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha10.cmd'
$alpha10CmdBytes = [System.IO.File]::ReadAllBytes($alpha10CmdPath)
Assert-True (@($alpha10CmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'alpha.10 CMD source contains ASCII only'
$alpha10CmdText = [System.Text.Encoding]::ASCII.GetString($alpha10CmdBytes)
Assert-True ($alpha10CmdText -ceq $alpha9CmdText) `
    'alpha.10 CMD preserves alpha.9 path, argument and exit-code forwarding byte-for-byte'
$alpha10LauncherPath = Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha10.ps1'
$alpha10LauncherBytes = [System.IO.File]::ReadAllBytes($alpha10LauncherPath)
Assert-True ($alpha10LauncherBytes.Length -ge 3 -and $alpha10LauncherBytes[0] -eq 0xEF -and
    $alpha10LauncherBytes[1] -eq 0xBB -and $alpha10LauncherBytes[2] -eq 0xBF) `
    'alpha.10 technical entry has a UTF-8 BOM for Windows PowerShell 5.1'
$alpha10Tokens = $null
$alpha10ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $alpha10LauncherPath, [ref]$alpha10Tokens, [ref]$alpha10ParseErrors) | Out-Null
Assert-True ($alpha10ParseErrors.Count -eq 0) `
    ('alpha.10 technical entry parses; parse errors={0}' -f $alpha10ParseErrors.Count)
$alpha10LauncherText = [System.IO.File]::ReadAllText($alpha10LauncherPath, [System.Text.Encoding]::UTF8)
Assert-True ($alpha10LauncherText -ceq $alpha9LauncherText.Replace('alpha.9', 'alpha.10')) `
    'alpha.10 technical entry changes only the version-specific startup failure text'
foreach ($pair in @(
    @{ Path='docs/R112_A_身份查询实施.md'; Name='docs__r112-a-identity-lookup.md' },
    @{ Path='docs/R112_A_网络音频指标.md'; Name='docs__r112-a-network-audio-metrics.md' },
    @{ Path='docs/R112_A_UI精简.md'; Name='docs__r112-a-ui-compact.md' }
)) {
    Assert-True ((Get-ReleaseAssetName -RelativePath $pair.Path) -ceq $pair.Name) `
        "alpha.10 fixed ASCII asset mapping $($pair.Path)"
}
Assert-True ([string]$alpha10Profile.PackageReadme -ceq 'docs\releases\v0.1.0-alpha.10-package-README.md') `
    'alpha.10 profile selects its versioned package README'
$alpha10ReadmeText = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot $alpha10Profile.PackageReadme), [System.Text.Encoding]::UTF8)
Assert-True ($alpha10ReadmeText.Contains('start-wirex-bridge.cmd') -and
    $alpha10ReadmeText.Contains('在后台查询单条 RadioID 资料') -and
    $alpha10ReadmeText.Contains('BM 往返、DMRD 丢包百分比') -and
    $alpha10ReadmeText.Contains('FTX-1 LCD 呼号显示和 FM/C4FM RF 发射路径尚未实现')) `
    'alpha.10 package README names the current entry, delivered data and unimplemented LCD/RF paths'
Assert-True (-not $alpha10ReadmeText.Contains('RadioID 查询只在用户点击')) `
    'alpha.10 package README does not repeat the alpha.9 manual-query behavior'

[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.1')
Assert-Throws { Get-ReleaseAssetName -RelativePath 'start-ui.cmd' } 'alpha.1 不接受 alpha.2 UI asset'
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/连接配置.md') -ceq 'docs__connection-profile.md') `
    '切回 alpha.1 后仍保留原 asset 映射'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md' } 'alpha.1 不接受 alpha.3 identity guide'

$testRoot = Join-Path $repositoryRoot ('build\_work\package-release-test-' + [guid]::NewGuid().ToString('N'))
$buildDirectory = Join-Path $testRoot 'wirex-bridge-0123456-20261025-000000'
$buildLogPath = Join-Path $testRoot 'synthetic-build.log'
$packageRoot = Join-Path $testRoot 'synthetic-package'
$approvedFixturePath = Join-Path $repositoryRoot 'private\fixtures\device-y.bin'
$approvedFixtureHash = Test-ApprovedYFixture -Path $approvedFixturePath
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
try {
    $alpha3ReadmeOutput = Join-Path $testRoot 'synthetic-alpha3-readme\README.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $alpha3ReadmeOutput) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot $alpha3ReadmeMap[0].Source) -Destination $alpha3ReadmeOutput
    $copiedAlpha3Readme = [System.IO.File]::ReadAllText($alpha3ReadmeOutput, [System.Text.Encoding]::UTF8)
    Assert-True ($copiedAlpha3Readme -match '(?m)^# WIREX Bridge v0\.1\.0-alpha\.3\s*$' -and
        $copiedAlpha3Readme -notmatch 'v0\.1\.0-alpha\.2') `
        'alpha.3 README copy contains alpha.3 instructions and no alpha.2 version text'

    $fakeExePath = Join-Path $buildDirectory 'wirex_bridge.exe'
    Write-Utf8NoBom -Path $fakeExePath -Text 'synthetic-only; not an executable'
    $fakeExe = Get-Item -LiteralPath $fakeExePath
    $fakeExeHash = (Get-FileHash -LiteralPath $fakeExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildRelative = (Get-RepoRelativePath -RepositoryRoot $repositoryRoot -Path $buildDirectory)
    $testRecords = @($expectedTests | ForEach-Object {
        [ordered]@{ name=$_; result='passed'; exit_code=0 }
    })
    $provenance = [ordered]@{
        schema_version = 1
        source_commit = '0123456789abcdef0123456789abcdef01234567'
        source_tree_clean = $true
        compile_only = $false
        build_completed = $true
        result = 'passed'
        output_directory = $buildRelative
        started_utc = '2026-10-25T00:00:00.0000000Z'
        completed_utc = '2026-10-25T00:01:00.0000000Z'
        executable = [ordered]@{
            path='wirex_bridge.exe'
            length_bytes=[long]$fakeExe.Length
            sha256=$fakeExeHash
        }
        tests = $testRecords
    }
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    $logLines = @('DroidStar 固定 commit 的 57 个本地源文件 SHA-256 全部通过。')
    foreach ($testName in $expectedTests) { $logLines += '运行离线测试：' + $testName }
    $logLines += '构建产物：' + $buildDirectory
    $logLines += '可执行文件：' + $fakeExePath
    $validLogText = ($logLines -join "`n") + "`n"
    Write-Utf8NoBom -Path $buildLogPath -Text $validLogText

    $syntheticEvidence = Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
        -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
        -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    Assert-Equal $syntheticEvidence.passed_test_count 27 'alpha.1 合成 provenance 的结构和测试数验证'
    Assert-Equal $syntheticEvidence.executable_sha256 $fakeExeHash '合成 EXE 文件 hash 一致性验证'

    $provenance.output_directory = 'C:/Users/example/build-output'
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '含绝对本机路径的 provenance'
    $provenance.output_directory = $buildRelative
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")

    $provenance.source_tree_clean = $false
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'dirty source provenance'
    $provenance.source_tree_clean = $true
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")

    $provenance.compile_only = $true
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'CompileOnly provenance'
    $provenance.compile_only = $false
    $provenance.tests = @($testRecords | Select-Object -First 26)
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '缺少一项测试的 provenance'
    $provenance.tests = $testRecords
    $provenance.executable.sha256 = ('0' * 64)
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'EXE hash 与 provenance 不符'
    $provenance.executable.sha256 = $fakeExeHash
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Write-Utf8NoBom -Path $buildLogPath -Text ($validLogText + 'warning C4996: synthetic warning')
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '包含编译警告的构建日志'
    Write-Utf8NoBom -Path $buildLogPath -Text $validLogText

    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($relativePath in (Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' })) {
        $fullPath = Join-Path $packageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($relativePath -ceq 'private/device-y.bin') {
            Copy-Item -LiteralPath $approvedFixturePath -Destination $fullPath
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic inventory fixture: ' + $relativePath)
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $packageRoot 'logs') -Force | Out-Null
    $fileRecords = @()
    foreach ($relativePath in (Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' } | Sort-Object)) {
        $fullPath = Join-Path $packageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $fileRecords += ,([ordered]@{
            path=$relativePath
            asset_name=(Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes=[long]$item.Length
            sha256=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source='synthetic test fixture'
        })
    }
    $packageManifest = [ordered]@{
        schema_version=1
        package_status='awaiting_root_audit'
        version='v0.1.0-alpha.1'
        tag_candidate='v0.1.0-alpha.1'
        manifest_asset_name='manifest.json'
        approved_y_fixture=[ordered]@{
            path='private/device-y.bin'
            length_bytes=100
            sha256=$approvedFixtureHash
        }
        files=$fileRecords
    }
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'manifest.json') `
        -Text ((ConvertTo-Json -InputObject $packageManifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $packageRoot) -eq $null) `
        '合成固定目录清单结构通过；没有创建发布包'

    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.9')
    $alpha9InventoryProfile = Get-ReleaseProfile -Version 'v0.1.0-alpha.9'
    $alpha9InventoryRoot = Join-Path $testRoot 'synthetic-alpha9-package'
    New-Item -ItemType Directory -Path $alpha9InventoryRoot -Force | Out-Null
    foreach ($relativeDirectory in $alpha9InventoryProfile.Directories) {
        New-Item -ItemType Directory -Path (Join-Path $alpha9InventoryRoot $relativeDirectory.Replace('/', '\')) -Force | Out-Null
    }
    foreach ($relativePath in ($alpha9InventoryProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' })) {
        $fullPath = Join-Path $alpha9InventoryRoot $relativePath.Replace('/', '\')
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($relativePath -ceq 'private/device-y.bin') {
            Copy-Item -LiteralPath $approvedFixturePath -Destination $fullPath
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.9 inventory fixture: ' + $relativePath)
        }
    }
    $alpha9InventoryRecords = @()
    foreach ($relativePath in ($alpha9InventoryProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' } | Sort-Object)) {
        $fullPath = Join-Path $alpha9InventoryRoot $relativePath.Replace('/', '\')
        $item = Get-Item -LiteralPath $fullPath
        $alpha9InventoryRecords += ,([ordered]@{
            path = $relativePath
            asset_name = [string]$alpha9InventoryProfile.AssetMap[$relativePath]
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.9 inventory fixture'
        })
    }
    $alpha9InventoryManifest = [ordered]@{
        schema_version = 1
        package_status = 'awaiting_root_audit'
        version = 'v0.1.0-alpha.9'
        tag_candidate = 'v0.1.0-alpha.9'
        manifest_asset_name = 'manifest.json'
        approved_y_fixture = [ordered]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $approvedFixtureHash
        }
        files = $alpha9InventoryRecords
    }
    Write-Utf8NoBom -Path (Join-Path $alpha9InventoryRoot 'manifest.json') `
        -Text ((ConvertTo-Json -InputObject $alpha9InventoryManifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha9InventoryRoot -Version 'v0.1.0-alpha.9') -eq $null) `
        'alpha.9 synthetic package inventory includes the runtime identity module and R111 docs'
    $cacheDirectory = Join-Path $alpha9InventoryRoot 'private\user-config'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $cacheDirectory 'radio-identity-cache.json') -Text '{}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $alpha9InventoryRoot -Version 'v0.1.0-alpha.9' } `
        'alpha.9 package inventory rejects a local RadioID cache'
    Remove-Item -LiteralPath $cacheDirectory -Recurse -Force -ErrorAction Stop
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $cacheDirectory 'channel-favorites.json') -Text '{}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $alpha9InventoryRoot -Version 'v0.1.0-alpha.9' } `
        'alpha.9 package inventory rejects user-maintained channel favorites'

    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.10')
    $alpha10InventoryProfile = Get-ReleaseProfile -Version 'v0.1.0-alpha.10'
    $alpha10InventoryRoot = Join-Path $testRoot 'synthetic-alpha10-package'
    New-Item -ItemType Directory -Path $alpha10InventoryRoot -Force | Out-Null
    foreach ($relativeDirectory in $alpha10InventoryProfile.Directories) {
        New-Item -ItemType Directory -Path (Join-Path $alpha10InventoryRoot $relativeDirectory.Replace('/', '\')) -Force | Out-Null
    }
    foreach ($relativePath in ($alpha10InventoryProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' })) {
        $fullPath = Join-Path $alpha10InventoryRoot $relativePath.Replace('/', '\')
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($relativePath -ceq 'private/device-y.bin') {
            Copy-Item -LiteralPath $approvedFixturePath -Destination $fullPath
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.10 inventory fixture: ' + $relativePath)
        }
    }
    $alpha10InventoryRecords = @()
    foreach ($relativePath in ($alpha10InventoryProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' } | Sort-Object)) {
        $fullPath = Join-Path $alpha10InventoryRoot $relativePath.Replace('/', '\')
        $item = Get-Item -LiteralPath $fullPath
        $alpha10InventoryRecords += ,([ordered]@{
            path = $relativePath
            asset_name = [string]$alpha10InventoryProfile.AssetMap[$relativePath]
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.10 inventory fixture'
        })
    }
    $alpha10InventoryManifest = [ordered]@{
        schema_version = 1
        package_status = 'awaiting_root_audit'
        version = 'v0.1.0-alpha.10'
        tag_candidate = 'v0.1.0-alpha.10'
        manifest_asset_name = 'manifest.json'
        approved_y_fixture = [ordered]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $approvedFixtureHash
        }
        excluded_private_files = @(
            'private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json',
            'private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt'
        )
        files = $alpha10InventoryRecords
    }
    Write-Utf8NoBom -Path (Join-Path $alpha10InventoryRoot 'manifest.json') `
        -Text ((ConvertTo-Json -InputObject $alpha10InventoryManifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha10InventoryRoot -Version 'v0.1.0-alpha.10') -eq $null) `
        'alpha.10 synthetic package inventory accepts the R112 docs and declares personal-file exclusions'
    $privateConfigDirectory = Join-Path $alpha10InventoryRoot 'private\user-config'
    New-Item -ItemType Directory -Path $privateConfigDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $privateConfigDirectory 'password-file-path.txt') -Text 'synthetic test path only'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $alpha10InventoryRoot -Version 'v0.1.0-alpha.10' } `
        'alpha.10 package inventory rejects a local password-path file'

    $alpha2PackageRoot = Join-Path $testRoot 'package-alpha2'
    Copy-Item -LiteralPath $packageRoot -Destination $alpha2PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.2')
    $alpha2ManifestPath = Join-Path $alpha2PackageRoot 'manifest.json'
    $alpha2Manifest = [System.IO.File]::ReadAllText($alpha2ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @(
        'start-user-config.cmd', 'start-user-config.ps1', 'bridge-user-config.psm1', 'start-ui.cmd', 'start-ui.ps1',
        'docs/配置与桌面操作.md', 'ui/windows/bridge-ui.ps1', 'ui/windows/BridgeSupervisor.cs',
        'ui/windows/MainWindow.xaml', 'ui/windows/SettingsWindow.xaml'
    )) {
        $fullPath = Join-Path $alpha2PackageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.2 inventory fixture: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha2Manifest.files += ,([pscustomobject]@{
            path = $relativePath
            asset_name = (Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.2 test fixture'
        })
    }
    $alpha2Manifest.version = 'v0.1.0-alpha.2'
    $alpha2Manifest.tag_candidate = 'v0.1.0-alpha.2'
    Write-Utf8NoBom -Path $alpha2ManifestPath -Text ((ConvertTo-Json -InputObject $alpha2Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha2PackageRoot -Version 'v0.1.0-alpha.2') -eq $null) `
        'alpha.2 合成目录和 asset 清单与显式包配置一致'

    $alpha3PackageRoot = Join-Path $testRoot 'package-alpha3'
    Copy-Item -LiteralPath $alpha2PackageRoot -Destination $alpha3PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.3')
    $alpha3ManifestPath = Join-Path $alpha3PackageRoot 'manifest.json'
    $alpha3Manifest = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $identityGuide = Join-Path $alpha3PackageRoot 'docs\BM来话身份显示.md'
    Write-Utf8NoBom -Path $identityGuide -Text 'synthetic alpha.3 identity guide'
    $identityItem = Get-Item -LiteralPath $identityGuide
    $alpha3Manifest.files += ,([pscustomobject]@{
        path = 'docs/BM来话身份显示.md'
        asset_name = (Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md')
        length_bytes = [long]$identityItem.Length
        sha256 = (Get-FileHash -LiteralPath $identityGuide -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic alpha.3 test fixture'
    })
    $alpha3Manifest.version = 'v0.1.0-alpha.3'
    $alpha3Manifest.tag_candidate = 'v0.1.0-alpha.3'
    Write-Utf8NoBom -Path $alpha3ManifestPath -Text ((ConvertTo-Json -InputObject $alpha3Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha3PackageRoot -Version 'v0.1.0-alpha.3') -eq $null) `
        'alpha.3 合成目录和 identity asset 清单与显式包配置一致'

    $alpha5PackageRoot = Join-Path $testRoot 'package-alpha5'
    Copy-Item -LiteralPath $alpha3PackageRoot -Destination $alpha5PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.5')
    $alpha5ManifestPath = Join-Path $alpha5PackageRoot 'manifest.json'
    $alpha5Manifest = [System.IO.File]::ReadAllText($alpha5ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha5ReadmePath = Join-Path $alpha5PackageRoot 'README.md'
    Write-Utf8NoBom -Path $alpha5ReadmePath -Text '# WIREX Bridge v0.1.0-alpha.5 synthetic test package'
    foreach ($relativePath in @('docs/R106_IPC第二版.md', 'docs/R106_配置迁移与测试.md', 'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1')) {
        $fullPath = Join-Path $alpha5PackageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.5 inventory fixture: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha5Manifest.files += ,([pscustomobject]@{
            path = $relativePath
            asset_name = (Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.5 test fixture'
        })
    }
    $alpha5ReadmeItem = Get-Item -LiteralPath $alpha5ReadmePath
    $alpha5ReadmeRecord = @($alpha5Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha5ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.5 manifest must contain one README record.' }
    $alpha5ReadmeRecord[0].length_bytes = [long]$alpha5ReadmeItem.Length
    $alpha5ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha5ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha5Manifest.version = 'v0.1.0-alpha.5'
    $alpha5Manifest.tag_candidate = 'v0.1.0-alpha.5'
    Write-Utf8NoBom -Path $alpha5ManifestPath -Text ((ConvertTo-Json -InputObject $alpha5Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha5PackageRoot -Version 'v0.1.0-alpha.5') -eq $null) `
        'alpha.5 synthetic folder and the six new package records match the alpha.5 profile'

    $alpha6PackageRoot = Join-Path $testRoot 'package-alpha6'
    Copy-Item -LiteralPath $alpha5PackageRoot -Destination $alpha6PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.6')
    $alpha6ManifestPath = Join-Path $alpha6PackageRoot 'manifest.json'
    $alpha6Manifest = [System.IO.File]::ReadAllText($alpha6ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha6ReadmePath = Join-Path $alpha6PackageRoot 'README.md'
    Write-Utf8NoBom -Path $alpha6ReadmePath -Text '# WIREX Bridge v0.1.0-alpha.6 synthetic test package'
    foreach ($relativePath in @('docs/R108_收发路由状态与alpha6验收.md', 'start-merged-test.cmd', 'start-merged-test.ps1')) {
        $fullPath = Join-Path $alpha6PackageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.6 inventory fixture: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha6Manifest.files += ,([pscustomobject]@{
            path = $relativePath
            asset_name = (Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.6 test fixture'
        })
    }
    $alpha6ReadmeItem = Get-Item -LiteralPath $alpha6ReadmePath
    $alpha6ReadmeRecord = @($alpha6Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha6ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.6 manifest must contain one README record.' }
    $alpha6ReadmeRecord[0].length_bytes = [long]$alpha6ReadmeItem.Length
    $alpha6ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha6ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha6Manifest.version = 'v0.1.0-alpha.6'
    $alpha6Manifest.tag_candidate = 'v0.1.0-alpha.6'
    Write-Utf8NoBom -Path $alpha6ManifestPath -Text ((ConvertTo-Json -InputObject $alpha6Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha6PackageRoot -Version 'v0.1.0-alpha.6') -eq $null) `
        'alpha.6 synthetic folder and three additive package records match the alpha.6 profile'

    $alpha7PackageRoot = Join-Path $testRoot 'package-alpha7'
    Copy-Item -LiteralPath $alpha6PackageRoot -Destination $alpha7PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.7')
    $alpha7ManifestPath = Join-Path $alpha7PackageRoot 'manifest.json'
    $alpha7Manifest = [System.IO.File]::ReadAllText($alpha7ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha7ReadmePath = Join-Path $alpha7PackageRoot 'README.md'
    Write-Utf8NoBom -Path $alpha7ReadmePath -Text '# WIREX Bridge v0.1.0-alpha.7 synthetic test package'
    $alpha7ReadmeItem = Get-Item -LiteralPath $alpha7ReadmePath
    $alpha7ReadmeRecord = @($alpha7Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha7ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.6 manifest must contain one README record.' }
    $alpha7ReadmeRecord[0].length_bytes = [long]$alpha7ReadmeItem.Length
    $alpha7ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha7ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha7DocPath = Join-Path $alpha7PackageRoot 'docs\R109_下行状态与动态组修复.md'
    Write-Utf8NoBom -Path $alpha7DocPath -Text 'synthetic alpha.7 R109 guide'
    $alpha7DocItem = Get-Item -LiteralPath $alpha7DocPath
    $alpha7Manifest.files += ,([pscustomobject]@{
        path = 'docs/R109_下行状态与动态组修复.md'
        asset_name = (Get-ReleaseAssetName -RelativePath 'docs/R109_下行状态与动态组修复.md')
        length_bytes = [long]$alpha7DocItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha7DocPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic alpha.7 test fixture'
    })
    $alpha7DynamicDocPath = Join-Path $alpha7PackageRoot 'docs\R109_动态组激活实现.md'
    Write-Utf8NoBom -Path $alpha7DynamicDocPath -Text 'synthetic alpha.7 dynamic-group guide'
    $alpha7DynamicDocItem = Get-Item -LiteralPath $alpha7DynamicDocPath
    $alpha7Manifest.files += ,([pscustomobject]@{
        path = 'docs/R109_动态组激活实现.md'
        asset_name = (Get-ReleaseAssetName -RelativePath 'docs/R109_动态组激活实现.md')
        length_bytes = [long]$alpha7DynamicDocItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha7DynamicDocPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic alpha.7 test fixture'
    })
    $alpha7Manifest.version = 'v0.1.0-alpha.7'
    $alpha7Manifest.tag_candidate = 'v0.1.0-alpha.7'
    Write-Utf8NoBom -Path $alpha7ManifestPath -Text ((ConvertTo-Json -InputObject $alpha7Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha7PackageRoot -Version 'v0.1.0-alpha.7') -eq $null) `
        'alpha.7 synthetic folder and two additive R109 guide records match the alpha.7 profile'
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.1')

    $readmeFixture = Join-Path $packageRoot 'README.md'
    Write-Utf8NoBom -Path $readmeFixture -Text 'tampered content'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '文件内容与manifest SHA不符'
    Write-Utf8NoBom -Path $readmeFixture -Text 'synthetic inventory fixture: README.md'
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $manifestObject = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $exeRecord = @($manifestObject.files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    $exeRecord.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 8) + "`n")
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '占用manifest asset名的普通文件'
    $exeRecord.asset_name = 'wirex_bridge.exe'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 8) + "`n")
    $forbiddenPath = Join-Path $packageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $forbiddenPath -Text '{"gateway_id":1}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '额外连接配置文件'

    $badFixture = Join-Path $testRoot 'wrong-y.bin'
    [System.IO.File]::WriteAllBytes($badFixture, (New-Object byte[] 100))
    Assert-Throws { Test-ApprovedYFixture -Path $badFixture } '内容不同的 100 字节 Y 素材'
    Copy-Item -LiteralPath $badFixture -Destination (Join-Path $packageRoot 'private\device-y.bin') -Force
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '被替换的 Y 素材'

    if ([string]::IsNullOrWhiteSpace($ControlPackageDirectory)) {
        Write-Host ("Release packager 离线合成断言通过：{0}；未生成发布包，未运行 EXE。" -f $script:assertions)
    } else {
        Write-Host ("Release packager 离线合成断言通过：{0}；将检查指定 alpha.5 包的默认诊断入口。" -f $script:assertions)
    }
}
finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PathWithinDirectory -Path $testRoot -Directory (Join-Path $repositoryRoot 'build\_work')) -and
        ([System.IO.Path]::GetFileName($testRoot).StartsWith('package-release-test-', [System.StringComparison]::Ordinal))) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not [string]::IsNullOrWhiteSpace($ControlPackageDirectory)) {
    $controlPackageRoot = [System.IO.Path]::GetFullPath($ControlPackageDirectory)
    $alpha5PackageRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'build\releases\v0.1.0-alpha.5'))
    $alpha6PackageRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'build\releases\v0.1.0-alpha.6'))
    $controlPackageVersion = if ($controlPackageRoot.Equals($alpha5PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        'alpha.5'
    } elseif ($controlPackageRoot.Equals($alpha6PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        'alpha.6'
    } else { '' }
    if (-not $controlPackageVersion) {
        throw "默认入口集成测试只接受本地 alpha.5 或 alpha.6 包目录：$alpha6PackageRoot"
    }
    $packagedControlScript = Join-Path $controlPackageRoot 'test-control.ps1'
    if (-not [System.IO.File]::Exists((Join-Path $controlPackageRoot 'wirex_bridge.exe')) -or
        -not [System.IO.File]::Exists($packagedControlScript)) {
        throw '默认入口集成测试需要同目录中的 test-control.ps1 与 wirex_bridge.exe。'
    }
    $powershellExe = Get-Command powershell.exe -ErrorAction Stop
    $controlOutput = @(& $powershellExe.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $packagedControlScript 2>&1)
    $controlExitCode = $LASTEXITCODE
    Assert-True ($controlExitCode -eq 0) `
        ("$controlPackageVersion test-control.ps1 must use its same-directory executable without -ExecutablePath; output: " + ($controlOutput -join ' | '))
    Write-Output ("Packaged test-control default-path integration passed for ${controlPackageVersion}: same-directory wirex_bridge.exe completed ready/hello/status/shutdown/exit0 without an executable argument.")
}
