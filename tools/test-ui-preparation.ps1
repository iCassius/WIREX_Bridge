[CmdletBinding()]
param(
    [switch]$RunPrepareOnly,
    [string]$PackageDirectory,
    [string]$ConnectionProfilePath,
    [string]$AudioSettingsPath,
    [string]$PasswordFile,
    [string]$BodyFile
)

$ErrorActionPreference = 'Stop'
function Assert-UiPreparation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Assert-UiPreparation ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-UiPreparationRecord' }, $true)
Assert-UiPreparation ($null -ne $functionAst) '没有找到 UI 启动参数验证函数。'
Invoke-Expression $functionAst.Extent.Text

$testRoot = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $repoRoot 'build\_work'))) ('ui-preparation-test-' + [guid]::NewGuid().ToString('N'))
$runRoot = Join-Path $testRoot 'ui-runs'
$runDirectory = Join-Path $runRoot ([guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$expectedExe = Join-Path $testRoot 'wirex_bridge.exe'
[System.IO.File]::WriteAllBytes($expectedExe, [byte[]]@(0x4D, 0x5A))
$statusPath = Join-Path $runDirectory 'bm-bridge-20261026-123456-789-0123abcd.jsonl'
$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.AddRange([string[]]@('--run', '--port', 'COM5', '--body-file', 'fixture.bin', '--input', '1', '--output', '3',
    '--status-file', $statusPath, '--expected-wavein-endpoint', 'input-endpoint', '--expected-waveout-endpoint', 'output-endpoint',
    '--radio-playback-gain', '1', '--mic-transmit-gain', '16', '--profile-callsign', 'TEST', '--profile-gateway-id', '1',
    '--password-file', 'local-password-fixture.txt',
    '--profile-source-id', '1', '--profile-master', 'localhost', '--profile-master-port', '62031',
    '--profile-destination-id', '460997', '--profile-slot', '2', '--profile-color-code', '1', '--profile-call-kind', 'P',
    '--profile-receive-destination-id', '1', '--profile-receive-slot', '2', '--profile-receive-call-kind', 'P', '--ui-pipe'))
$record = [pscustomobject][ordered]@{
    schema_version = [int64]1
    executable = [System.IO.Path]::GetFullPath($expectedExe)
    arguments = [string[]]$arguments.ToArray()
    status_path = $statusPath
}

try {
    $validated = Test-UiPreparationRecord -Record $record -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe
    Assert-UiPreparation ([string]::Equals($validated.StatusPath, [System.IO.Path]::GetFullPath($statusPath), [System.StringComparison]::OrdinalIgnoreCase)) '有效预检记录未返回实际状态路径。'
    Assert-UiPreparation ($validated.Arguments.Count -eq $record.arguments.Count -and
        [string]::Join([char]0, $validated.Arguments) -ceq [string]::Join([char]0, $record.arguments)) '有效预检记录的完整启动参数没有保留。'

    $listenOnlyRecord = $record.PSObject.Copy()
    $listenOnlyRecord.arguments = [string[]]@($record.arguments) + [string[]]@('--listen-only')
    [void](Test-UiPreparationRecord -Record $listenOnlyRecord -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe)
    $withoutReceive = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $record.arguments.Count; $index++) {
        if ($record.arguments[$index] -ceq '--profile-receive-destination-id') { $index++; continue }
        if ($record.arguments[$index] -ceq '--profile-receive-slot') { $index++; continue }
        if ($record.arguments[$index] -ceq '--profile-receive-call-kind') { $index++; continue }
        $withoutReceive.Add([string]$record.arguments[$index])
    }
    $invalid = $record.PSObject.Copy()
    $invalid.arguments = [string[]]$withoutReceive.ToArray()
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '缺少接收目标三元组时没有拒绝启动参数。'

    $invalid = $record.PSObject.Copy()
    $badReceive = [System.Collections.Generic.List[string]]::new()
    $badReceive.AddRange([string[]]$record.arguments)
    $badIndex = $badReceive.IndexOf('--profile-receive-slot')
    $badReceive[$badIndex + 1] = '3'
    $invalid.arguments = [string[]]$badReceive.ToArray()
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '无效接收时隙没有拒绝启动参数。'

    $invalid = $record.PSObject.Copy()
    $invalid.arguments = [string[]]@($record.arguments) + [string[]]@('--unrecognized-option', '1')
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '不受支持的启动参数没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.status_path = Join-Path $testRoot ([System.IO.Path]::GetFileName($statusPath))
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '运行目录之外的状态路径没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.status_path = Join-Path $runDirectory 'wrong.jsonl'
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '与 --status-file 不一致的状态路径没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.arguments = [string[]]@($record.arguments) + [string[]]@('--ui-pipe')
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '重复的 --ui-pipe 没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.arguments = [string[]]@($record.arguments | Where-Object { $_ -cne '--status-file' })
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '缺失的 --status-file 参数没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.arguments = [string[]]@($record.arguments) + [string[]]@('--status-file', $statusPath)
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '重复的 --status-file 参数没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.status_path = Join-Path $runDirectory 'bm-bridge-20261026-123456-789-0123abcd.txt'
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '非 JSONL 状态文件扩展名没有被拒绝。'

    $invalid = $record.PSObject.Copy()
    $invalid.executable = Join-Path $testRoot 'other.exe'
    [System.IO.File]::WriteAllBytes($invalid.executable, [byte[]]@(0x4D, 0x5A))
    $rejected = $false
    try { [void](Test-UiPreparationRecord -Record $invalid -RunDirectory $runDirectory -RunRoot $runRoot -ExpectedExecutable $expectedExe) }
    catch { $rejected = $true }
    Assert-UiPreparation $rejected '另一个便携目录的 native 核心没有被拒绝。'

    if ($RunPrepareOnly) {
        if ([string]::IsNullOrWhiteSpace($PackageDirectory) -or -not [System.IO.Directory]::Exists($PackageDirectory)) {
            throw 'PrepareOnly 集成测试需要现有的便携目录。'
        }
        foreach ($required in @($ConnectionProfilePath, $AudioSettingsPath, $PasswordFile, $BodyFile)) {
            if ([string]::IsNullOrWhiteSpace($required) -or -not [System.IO.File]::Exists($required)) {
                throw 'PrepareOnly 集成测试需要现有的 native、连接设置、密码文件路径和批准的 Y 模板文件。'
            }
        }
        $packageRoot = [System.IO.Path]::GetFullPath($PackageDirectory)
        $integrationExe = Join-Path $packageRoot 'wirex_bridge.exe'
        if (-not [System.IO.File]::Exists($integrationExe)) { throw '指定便携目录缺少 native 核心。' }
        $integrationRun = Join-Path $runRoot ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($integrationRun) | Out-Null
        $preparationPath = Join-Path $integrationRun 'preparation.json'
        $launcherPath = Join-Path $PSScriptRoot 'start-bm-radio-bridge.ps1'
        $harnessPath = Join-Path $testRoot 'invoke-prepare-only.ps1'
        $harness = @'
param([string]$LauncherPath,[string]$BridgePath,[string]$BodyFile,[string]$ConnectionProfilePath,[string]$AudioSettingsPath,[string]$PasswordFile,[string]$StatusDirectory,[string]$PreparationOutputPath)
$ErrorActionPreference = 'Stop'
try {
    & $LauncherPath -BridgePath $BridgePath -BodyFile $BodyFile -Preset manual `
        -ConnectionProfilePath $ConnectionProfilePath -AudioSettingsPath $AudioSettingsPath `
        -PasswordFile $PasswordFile -StatusDirectory $StatusDirectory `
        -PreparationOutputPath $PreparationOutputPath -PrepareOnly -NoInteractive -RequirePasswordFile *> $null
    exit 0
} catch {
    [Console]::Error.WriteLine('PrepareOnly failed: ' + $_.Exception.GetType().FullName)
    exit 3
}
'@
        [System.IO.File]::WriteAllText($harnessPath, $harness, (New-Object System.Text.UTF8Encoding($true)))
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not [System.IO.File]::Exists($windowsPowerShell)) { throw '找不到 Windows PowerShell 5.1。' }
        $childArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $harnessPath,
            '-LauncherPath', $launcherPath, '-BridgePath', $integrationExe, '-BodyFile', $BodyFile,
            '-ConnectionProfilePath', $ConnectionProfilePath, '-AudioSettingsPath', $AudioSettingsPath,
            '-PasswordFile', $PasswordFile, '-StatusDirectory', $integrationRun, '-PreparationOutputPath', $preparationPath)
        $quoted = foreach ($value in $childArguments) { '"' + ([string]$value).Replace('"', '\"') + '"' }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $windowsPowerShell
        $startInfo.Arguments = $quoted -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $child = New-Object System.Diagnostics.Process
        $child.StartInfo = $startInfo
        try {
            if (-not $child.Start()) { throw '未能启动隔离的 PrepareOnly 预检进程。' }
            $stdoutTask = $child.StandardOutput.ReadToEndAsync()
            $stderrTask = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(60000)) {
                try { $child.Kill() } catch { }
                [void]$child.WaitForExit(2000)
                throw 'PrepareOnly 设备枚举超过 60 秒。'
            }
            if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) { throw 'PrepareOnly 预检输出管道未关闭。' }
            if ($child.ExitCode -ne 0) { throw ('PrepareOnly 预检进程退出，代码 {0}。' -f $child.ExitCode) }
        } finally { $child.Dispose() }

        if (-not [System.IO.File]::Exists($preparationPath)) { throw 'PrepareOnly 没有生成预检文件。' }
        $actualRecord = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($preparationPath, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
        $actualRunId = [System.IO.Path]::GetFileName($integrationRun)
        $actualValidated = Test-UiPreparationRecord -Record $actualRecord -RunDirectory $integrationRun `
            -RunRoot $runRoot -ExpectedExecutable $integrationExe
        Assert-UiPreparation ([string]::Equals([System.IO.Path]::GetDirectoryName($actualValidated.StatusPath),
            [System.IO.Path]::GetFullPath($integrationRun), [System.StringComparison]::OrdinalIgnoreCase)) '真实预检状态路径不在本次运行目录内。'
        Assert-UiPreparation ($actualValidated.Arguments.Count -ge 20) '真实预检没有保留完整启动参数。'
        Assert-UiPreparation ([System.IO.Path]::GetFileName($integrationRun) -ceq $actualRunId) '运行目录 nonce 未保留。'
    }

    if ($RunPrepareOnly) {
        Write-Output '通过：真实 PowerShell 5.1 PrepareOnly 预检产物通过 UI 启动参数确认；未启动 core 或打开串口/音频流。'
    } else {
        Write-Output '通过：UI 预检参数校验接受正确的动态状态文件路径，并拒绝越界、错配、重复参数和错误 native。'
    }
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        try { [System.IO.Directory]::Delete($testRoot, $true) }
        catch { throw ('测试临时目录清理失败，残留路径：' + $testRoot) }
    }
}
