[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [int]$PrepareTimeoutSeconds = 60,
    [int]$DiagnosticTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw '此包级检查必须由 Windows PowerShell 5.1 运行。'
}

$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $buildRoot '_work'))
$sourcePackage = [System.IO.Path]::GetFullPath($PackageDirectory)
$packagePrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $sourcePackage.StartsWith($packagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '包级启动检查只接受 app/build 下的候选包目录。'
}
if (-not [System.IO.Directory]::Exists($sourcePackage)) { throw '候选包目录不存在。' }

. (Join-Path $PSScriptRoot 'package-release.ps1')
$manifestPath = Join-Path $sourcePackage 'manifest.json'
if (-not [System.IO.File]::Exists($manifestPath)) { throw '候选包缺少 manifest.json。' }
try {
    $packageManifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) |
        ConvertFrom-Json -ErrorAction Stop
} catch {
    throw ('候选包 manifest.json 无法读取：{0}' -f $_.Exception.Message)
}
$packageVersion = [string]$packageManifest.version
if (@('v0.1.0-alpha.9', 'v0.1.0-alpha.10') -cnotcontains $packageVersion) {
    throw ('包级启动检查只支持 alpha.9 或 alpha.10；manifest.version 为：{0}' -f $packageVersion)
}
$releaseProfile = Set-ReleaseVersion -Version $packageVersion
Assert-ReleasePackageInventory -PackageRoot $sourcePackage -Version $releaseProfile.Version | Out-Null
$releaseNumber = $releaseProfile.Version.Substring($releaseProfile.Version.LastIndexOf('.') + 1)
$packageLabel = 'alpha.' + $releaseNumber
$testDirectoryPrefix = 'alpha' + $releaseNumber + '-launcher-test-'

$rootCommand = Join-Path $sourcePackage 'start-wirex-bridge.cmd'
if (-not [System.IO.File]::Exists($rootCommand)) { throw '候选包缺少唯一启动命令 start-wirex-bridge.cmd。' }
$allCommands = @(Get-ChildItem -LiteralPath $sourcePackage -Recurse -File -Filter '*.cmd')
if ($allCommands.Count -ne 1 -or -not [string]::Equals($allCommands[0].FullName, $rootCommand,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ($packageLabel + ' 包必须只包含根目录 start-wirex-bridge.cmd。')
}
$identityModule = Join-Path $sourcePackage 'ui\windows\RadioIdentity.psm1'
if (-not [System.IO.File]::Exists($identityModule)) { throw ($packageLabel + ' 包缺少 RadioIdentity.psm1。') }
$identityModuleBytes = [System.IO.File]::ReadAllBytes($identityModule)
if ($identityModuleBytes.Length -lt 3 -or $identityModuleBytes[0] -ne 0xEF -or
    $identityModuleBytes[1] -ne 0xBB -or $identityModuleBytes[2] -ne 0xBF) {
    throw ($packageLabel + ' RadioIdentity.psm1 缺少 Windows PowerShell 5.1 需要的 UTF-8 BOM。')
}

$testRoot = Join-Path $workRoot ($testDirectoryPrefix + [guid]::NewGuid().ToString('N'))
$packageCopy = Join-Path $testRoot ($packageLabel + ' package 中文 path')
$fixtureRoot = Join-Path $testRoot 'fixture files 中文 path'
$isolatedConfig = Join-Path $fixtureRoot 'isolated user config'
$canonicalConfig = Join-Path $packageCopy 'private\user-config'
$driverPath = Join-Path $testRoot 'invoke-package-entry.cmd'
$copied = $false

function Get-TestCommandDescendants {
    param(
        [int]$RootProcessId,
        [DateTime]$RootStartedUtc,
        [string]$TestRoot,
        [string]$PackageCopy,
        [string]$Mode,
        [string]$FakeSleepScriptPath
    )

    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $depthById = @{$RootProcessId = 0}
    $descendants = New-Object 'System.Collections.Generic.List[object]'
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($candidate in $processes) {
            $id = [int]$candidate.ProcessId
            $parentId = [int]$candidate.ParentProcessId
            if (-not $depthById.ContainsKey($parentId) -or $depthById.ContainsKey($id)) { continue }
            try {
                $createdUtc = [System.Management.ManagementDateTimeConverter]::ToDateTime(
                    [string]$candidate.CreationDate).ToUniversalTime()
            } catch { throw ('无法验证测试子进程创建时间 PID {0}。' -f $id) }
            if ($createdUtc -lt $RootStartedUtc.AddSeconds(-2)) { continue }

            $commandLine = [string]$candidate.CommandLine
            $executablePath = [string]$candidate.ExecutablePath
            $allowed = $false
            if ([string]::Equals([string]$candidate.Name, 'powershell.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not [string]::IsNullOrWhiteSpace($FakeSleepScriptPath)) {
                    $allowed = $commandLine.IndexOf($FakeSleepScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                } elseif ($Mode -ceq 'StartNoArguments') {
                    $entryScript = Join-Path $PackageCopy 'tools\start-wirex-bridge.ps1'
                    $allowed = $commandLine.IndexOf($entryScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                        $commandLine.IndexOf($PackageCopy, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                } else {
                    $entryScript = Join-Path $PackageCopy 'tools\start-wirex-bridge.ps1'
                    $allowed = $commandLine.IndexOf($entryScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                        $commandLine.IndexOf(('-Mode ' + $Mode), [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                        $commandLine.IndexOf($PackageCopy, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
            } elseif ([string]::Equals([string]$candidate.Name, 'wirex_bridge.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                $expectedNative = Join-Path $PackageCopy 'wirex_bridge.exe'
                $allowed = [string]::Equals($executablePath, $expectedNative, [System.StringComparison]::OrdinalIgnoreCase) -and
                    (($Mode -ceq 'RoutingDiagnosticAutoTest' -and $commandLine.Contains('--routing-diagnostic')) -or
                     ($Mode -ceq 'PrepareOnly' -and $commandLine.Contains('--list-audio-json')))
            } elseif ([string]::Equals([string]$candidate.Name, 'cmd.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $commandLine.IndexOf($TestRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            if (-not $allowed) {
                throw ('测试进程树中发现未获准的子进程，拒绝终止：PID {0} {1} {2}' -f $id, $candidate.Name, $executablePath)
            }
            $depth = [int]$depthById[$parentId] + 1
            $depthById[$id] = $depth
            $descendants.Add([pscustomobject]@{
                ProcessId = $id
                ParentProcessId = $parentId
                Name = [string]$candidate.Name
                ExecutablePath = $executablePath
                CommandLine = $commandLine
                CreationDate = [string]$candidate.CreationDate
                CreatedUtc = $createdUtc
                Depth = $depth
            })
            $changed = $true
        }
    }
    return @($descendants)
}

function Assert-NoTestPathProcesses {
    param([string]$TestRoot)
    $rootPath = [System.IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $hits = @($all | Where-Object {
        ($_.CommandLine -and $_.CommandLine.IndexOf($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase))
    })
    if ($hits.Count) {
        throw ('测试临时路径仍被进程引用：{0}' -f (($hits | ForEach-Object { '{0}:{1}' -f $_.ProcessId,$_.Name }) -join ', '))
    }
}

function Stop-TestCommandTree {
    param(
        [Parameter(Mandatory=$true)][System.Diagnostics.Process]$RootProcess,
        [string]$TestRoot,
        [string]$PackageCopy,
        [string]$Mode,
        [string]$FakeSleepScriptPath
    )

    $rootStartedUtc = $RootProcess.StartTime.ToUniversalTime()
    $descendants = @(Get-TestCommandDescendants -RootProcessId $RootProcess.Id -RootStartedUtc $rootStartedUtc `
        -TestRoot $TestRoot -PackageCopy $PackageCopy -Mode $Mode -FakeSleepScriptPath $FakeSleepScriptPath)
    foreach ($child in @($descendants | Sort-Object -Property Depth -Descending)) {
        $current = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $child.ProcessId)
        if (-not $current) { continue }
        if ([string]$current.CreationDate -cne $child.CreationDate -or
            [int]$current.ParentProcessId -ne $child.ParentProcessId -or
            [string]$current.Name -cne $child.Name -or
            [string]$current.ExecutablePath -cne $child.ExecutablePath) {
            throw ('测试子进程身份变化，拒绝终止 PID {0}。' -f $child.ProcessId)
        }
        Stop-Process -Id $child.ProcessId -Force -ErrorAction Stop
    }
    $currentRoot = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $RootProcess.Id)
    if ($currentRoot) {
        try {
            $currentRootCreatedUtc = [System.Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$currentRoot.CreationDate).ToUniversalTime()
        } catch { throw '无法验证测试根进程创建时间。' }
        $rootExecutable = [System.IO.Path]::GetFullPath($RootProcess.StartInfo.FileName)
        $rootPathMarker = if (-not [string]::IsNullOrWhiteSpace($FakeSleepScriptPath)) {
            $FakeSleepScriptPath
        } else {
            Join-Path $TestRoot 'invoke-package-entry.cmd'
        }
        $creationDelta = [Math]::Abs(($currentRootCreatedUtc - $rootStartedUtc).TotalSeconds)
        if ($creationDelta -gt 2 -or
            -not [string]::Equals([string]$currentRoot.ExecutablePath, $rootExecutable,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]$currentRoot.CommandLine.IndexOf($rootPathMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw ('测试根进程身份无法确认，拒绝终止 PID {0}。' -f $RootProcess.Id)
        }
        Stop-Process -Id $RootProcess.Id -Force -ErrorAction Stop
    }
    [void]$RootProcess.WaitForExit(5000)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @(Get-TestCommandDescendants -RootProcessId $RootProcess.Id `
            -RootStartedUtc $rootStartedUtc -TestRoot $TestRoot -PackageCopy $PackageCopy -Mode $Mode `
            -FakeSleepScriptPath $FakeSleepScriptPath)
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert-NoTestPathProcesses -TestRoot $TestRoot
    if (-not $RootProcess.HasExited -or $remaining.Count -gt 0) { throw '测试进程树未能在限定时间内退出。' }
}

function Test-FakeTimeoutCleanup {
    $fakeSleepScript = Join-Path $testRoot 'fake-sleep.ps1'
    [System.IO.File]::WriteAllText($fakeSleepScript, "Start-Sleep -Seconds 60`r`n", [System.Text.Encoding]::ASCII)
    $powerShell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell51
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fakeSleepScript + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动可控 fake sleep 子进程。' }
        if ($process.WaitForExit(1000)) { throw 'fake sleep 子进程没有按预期保持运行。' }
        $fakeProcess = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $process.Id)
        if (-not $fakeProcess -or
            -not [string]::Equals([string]$fakeProcess.Name, 'powershell.exe', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$fakeProcess.ExecutablePath,
                [System.IO.Path]::GetFullPath($powerShell51), [System.StringComparison]::OrdinalIgnoreCase) -or
            $fakeProcess.CommandLine.IndexOf($fakeSleepScript, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'fake sleep 进程身份验证失败，未执行终止。'
        }
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        if (-not $process.WaitForExit(5000)) { throw 'fake sleep 子进程在限定时间内没有退出。' }
        if (-not $process.HasExited) { throw 'fake sleep 子进程在超时处理后仍运行。' }
        Assert-NoTestPathProcesses -TestRoot $testRoot
        Write-Output '通过：fake sleep 子进程超时后已退出，临时路径没有被进程引用。'
    } finally { $process.Dispose() }
}

function Invoke-PackageEntryFromCmd {
    param([string]$Mode, [string]$UserConfigDirectory, [int]$TimeoutSeconds)

    $callArguments = @(
        'call', '"%WIREX_PACKAGE_ROOT%\start-wirex-bridge.cmd"',
        '-Mode', $Mode,
        '-PackageDirectory', '"%WIREX_PACKAGE_ROOT%"',
        '-ConnectionProfilePath', '"%WIREX_PROFILE_PATH%"',
        '-AudioSettingsPath', '"%WIREX_AUDIO_PATH%"',
        '-PasswordFile', '"%WIREX_PASSWORD_PATH%"',
        '-BodyFile', '"%WIREX_BODY_PATH%"',
        '-StatusDirectory', '"%WIREX_STATUS_PATH%"',
        '-PreparationOutputPath', '"%WIREX_PREPARATION_PATH%"'
    )
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
        $callArguments += @('-UserConfigDirectory', '"%WIREX_USER_CONFIG_PATH%"')
    }
    $driverLines = @('@echo off', 'setlocal', ($callArguments -join ' '), 'exit /b %ERRORLEVEL%')
    [System.IO.File]::WriteAllText($driverPath, ([string]::Join("`r`n", $driverLines) + "`r`n"), [System.Text.Encoding]::ASCII)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /s /c "' + $driverPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['WIREX_PACKAGE_ROOT'] = $packageCopy
    $startInfo.EnvironmentVariables['WIREX_PROFILE_PATH'] = Join-Path $fixtureRoot 'connection profile.json'
    $startInfo.EnvironmentVariables['WIREX_AUDIO_PATH'] = Join-Path $fixtureRoot 'audio settings.json'
    $startInfo.EnvironmentVariables['WIREX_PASSWORD_PATH'] = Join-Path $fixtureRoot 'empty password placeholder.bin'
    $startInfo.EnvironmentVariables['WIREX_BODY_PATH'] = Join-Path $packageCopy 'private\device-y.bin'
    $startInfo.EnvironmentVariables['WIREX_STATUS_PATH'] = Join-Path $fixtureRoot 'status output'
    $startInfo.EnvironmentVariables['WIREX_PREPARATION_PATH'] = Join-Path $fixtureRoot 'preparation output.json'
    $startInfo.EnvironmentVariables['WIREX_USER_CONFIG_PATH'] = $UserConfigDirectory

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动 cmd.exe 测试进程。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $progressText = ''
            if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
                $progressPath = Join-Path $UserConfigDirectory 'routing-diagnostic-progress.txt'
                if ([System.IO.File]::Exists($progressPath)) {
                    $progressText = [System.IO.File]::ReadAllText($progressPath, [System.Text.Encoding]::UTF8)
                }
            }
            Stop-TestCommandTree -RootProcess $process -TestRoot $testRoot -PackageCopy $packageCopy -Mode $Mode `
                -FakeSleepScriptPath ''
            if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
                throw ($Mode + ' 超时后输出管道未关闭。')
            }
            $partialOutput = $stdoutTask.Result + $stderrTask.Result
            throw ('{0} 入口检查超过 {1} 秒；routing progress={2}；输出={3}' -f `
                $Mode, $TimeoutSeconds, $progressText, $partialOutput)
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) {
            throw ($Mode + ' 入口检查的输出管道未关闭。')
        }
        Assert-NoTestPathProcesses -TestRoot $testRoot
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output = $stdoutTask.Result + $stderrTask.Result
        }
    } finally { $process.Dispose() }
}

function Test-NoArgumentStartupFailurePrompt {
    $pointerPath = Join-Path $packageCopy 'private\user-config-directory.txt'
    $commandPath = Join-Path $packageCopy 'start-wirex-bridge.cmd'
    $commandText = [System.IO.File]::ReadAllText($commandPath, [System.Text.Encoding]::ASCII)
    $interactiveGuard = 'if "%~1"=="" set "_wirex_interactive=1"'
    $failureGuard = 'if "%_wirex_interactive%"=="1" if not "%_wirex_exit%"=="0" ('
    $failureMessage = 'echo WIREX Bridge failed to start. Review the error above.'
    $pauseCommand = 'pause >nul'
    $exitCommand = 'exit /b %_wirex_exit%'
    $guardAt = $commandText.IndexOf($failureGuard, [System.StringComparison]::Ordinal)
    $messageAt = $commandText.IndexOf($failureMessage, [System.StringComparison]::Ordinal)
    $pauseAt = $commandText.IndexOf($pauseCommand, [System.StringComparison]::Ordinal)
    $exitAt = $commandText.IndexOf($exitCommand, [System.StringComparison]::Ordinal)
    if ($commandText.IndexOf($interactiveGuard, [System.StringComparison]::Ordinal) -lt 0 -or
        $guardAt -lt 0 -or $messageAt -le $guardAt -or $pauseAt -le $messageAt -or $exitAt -le $pauseAt) {
        throw '唯一 CMD 未把 ASCII 错误提示和 pause 放在无参数启动失败分支中，或未保留原退出码。'
    }
    [System.IO.File]::WriteAllText($pointerPath, "C:\\R110-invalid-one`r`nC:\\R110-invalid-two`r`n",
        [System.Text.Encoding]::ASCII)
    $driverLines = @(
        '@echo off',
        'setlocal',
        'call "%WIREX_PACKAGE_ROOT%\start-wirex-bridge.cmd"',
        'exit /b %ERRORLEVEL%'
    )
    [System.IO.File]::WriteAllText($driverPath, ([string]::Join("`r`n", $driverLines) + "`r`n"), [System.Text.Encoding]::ASCII)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /s /c "' + $driverPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['WIREX_PACKAGE_ROOT'] = $packageCopy
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动无参数 CMD 启动失败测试。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write('x')
        $process.StandardInput.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            Stop-TestCommandTree -RootProcess $process -TestRoot $testRoot -PackageCopy $packageCopy `
                -Mode 'StartNoArguments' -FakeSleepScriptPath ''
            throw '无参数启动失败提示子进程没有正常退出。'
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) {
            throw '无参数启动失败提示的输出管道未关闭。'
        }
        $output = $stdoutTask.Result + $stderrTask.Result
        if ($process.ExitCode -ne 2 -or -not $output.Contains('WIREX Bridge failed to start. Review the error above.')) {
            throw ('无参数启动失败没有显示ASCII错误提示或没有保留退出码2；exit={0}; output={1}' -f `
                $process.ExitCode, $output)
        }
        Assert-NoTestPathProcesses -TestRoot $testRoot
        Write-Output '通过：真实无参数 CMD 启动失败显示 ASCII 提示并保留退出码2；静态检查确认 pause 仅位于交互式失败分支。'
    } finally {
        if ([System.IO.File]::Exists($pointerPath)) { [System.IO.File]::Delete($pointerPath) }
        $process.Dispose()
    }
}

try {
    $sourceItems = @(Get-ChildItem -LiteralPath $sourcePackage -Recurse -Force)
    if (@($sourceItems | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw '候选包含 reparse point，测试副本拒绝递归复制。'
    }
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    Test-FakeTimeoutCleanup
    Copy-Item -LiteralPath $sourcePackage -Destination $packageCopy -Recurse
    $copied = $true
    Test-NoArgumentStartupFailurePrompt

    $scriptFiles = @(Get-ChildItem -LiteralPath $packageCopy -Recurse -File | Where-Object {
        $_.Extension -in @('.ps1', '.psm1')
    })
    if ($scriptFiles.Count -eq 0) { throw '候选包中没有 PowerShell 脚本。' }
    foreach ($scriptFile in $scriptFiles) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            $details = @($parseErrors | ForEach-Object {
                '{0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
            }) -join ' | '
            throw ('Windows PowerShell 5.1 无法解析包内文件 {0}：{1}' -f $scriptFile.FullName, $details)
        }
    }

    $modulePath = Join-Path $packageCopy 'bridge-user-config.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $connection = [pscustomobject][ordered]@{
        callsign='R110T'; gateway_id=[uint64]123456789; source_id=[uint64]1234567
        master='127.0.0.1'; master_port=[uint64]62031; color_code=[uint64]1
    }
    $devices = [pscustomobject][ordered]@{
        serial_port='auto'; wave_in_endpoint_id='auto'; wave_out_endpoint_id='auto'
    }
    $txTarget = [pscustomobject][ordered]@{ destination_id=[uint64]91; kind='group'; slot=[uint64]2 }
    $policy = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='disabled'; allow_groups=@(); allow_private_peers=@()
        local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
    }
    $profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices `
        -TxTarget $txTarget -RxPolicy $policy -TransmitEnabled $false
    Write-BridgeUserConnectionProfile -Path (Join-Path $fixtureRoot 'connection profile.json') -Profile $profile
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'audio settings.json'),
        '{"schema_version":1,"radio_playback_gain":1,"mic_transmit_gain":1}',
        (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'empty password placeholder.bin'), [byte[]]@())

    $prepare = Invoke-PackageEntryFromCmd -Mode 'PrepareOnly' -UserConfigDirectory '' `
        -TimeoutSeconds $PrepareTimeoutSeconds
    if ($prepare.ExitCode -ne 0) {
        $failedDriver = [System.IO.File]::ReadAllText($driverPath, [System.Text.Encoding]::ASCII)
        throw ('ASCII CMD → Windows PowerShell 5.1 → PrepareOnly 失败，退出码 {0}；driver={1}；输出={2}' -f `
            $prepare.ExitCode, $failedDriver, $prepare.Output)
    }
    $preparationPath = Join-Path $fixtureRoot 'preparation output.json'
    if (-not [System.IO.File]::Exists($preparationPath)) { throw 'PrepareOnly 未生成隔离的启动预检文件。' }
    $preparationText = [System.IO.File]::ReadAllText($preparationPath, [System.Text.Encoding]::UTF8)
    $preparation = ConvertFrom-Json -InputObject $preparationText -ErrorAction Stop
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($preparation.executable),
        [System.IO.Path]::GetFullPath((Join-Path $packageCopy 'wirex_bridge.exe')),
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PrepareOnly 结果没有指向带空格和中文路径的本次测试包。'
    }

    $canonicalProbe = Invoke-PackageEntryFromCmd -Mode 'RoutingDiagnosticAutoTest' `
        -UserConfigDirectory $canonicalConfig -TimeoutSeconds 15
    if ($canonicalProbe.ExitCode -ne 2 -or [System.IO.Directory]::Exists($canonicalConfig)) {
        throw ('唯一 CMD 入口没有保留预期的失败退出码 2，或错误创建了 canonical 配置目录；实际退出码 {0}。' -f $canonicalProbe.ExitCode)
    }

    [System.IO.Directory]::CreateDirectory($isolatedConfig) | Out-Null
    $diagnosticConnection = [pscustomobject][ordered]@{
        callsign='R110T'; gateway_id=[uint64]123456789; source_id=[uint64]1
        master='127.0.0.1'; master_port=[uint64]62031; color_code=[uint64]1
    }
    $diagnosticProfile = ConvertTo-BridgeUserConnectionProfile -Connection $diagnosticConnection -Devices $devices `
        -TxTarget $txTarget -RxPolicy $policy -TransmitEnabled $false
    Write-BridgeUserConnectionProfile -Path (Join-Path $isolatedConfig 'connection-profile.json') `
        -Profile $diagnosticProfile
    $fixture = [pscustomobject][ordered]@{
        schema_version=1; purpose='wirex-routing-diagnostic-test'
        fixture_id=[guid]::NewGuid().ToString('N'); source_id=1
    }
    [System.IO.File]::WriteAllText((Join-Path $isolatedConfig 'routing-diagnostic-fixture.json'),
        (ConvertTo-Json -InputObject $fixture -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $diagnostic = Invoke-PackageEntryFromCmd -Mode 'RoutingDiagnosticAutoTest' `
        -UserConfigDirectory $isolatedConfig -TimeoutSeconds $DiagnosticTimeoutSeconds
    if ($diagnostic.ExitCode -ne 0) {
        throw ('ASCII CMD → Windows PowerShell 5.1 → isolated RoutingDiagnosticAutoTest 失败，退出码 {0}：{1}' -f $diagnostic.ExitCode, $diagnostic.Output)
    }
    $resultPath = Join-Path $isolatedConfig 'routing-diagnostic-result.json'
    if (-not [System.IO.File]::Exists($resultPath)) { throw '隔离路由诊断没有生成结果文件。' }
    $result = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $dynamicGroupTest = $result.dynamic_group_action_test
    if (-not [bool]$result.passed -or -not [bool]$result.offline_cancel_verified -or
        -not [bool]$result.timeout_fence_verified -or -not [bool]$dynamicGroupTest.passed -or
        [string]$dynamicGroupTest.local_listen_command -cne 'rx_policy.replace' -or
        [string]$dynamicGroupTest.activation_command -cne 'network_subscription.quick_call_join' -or
        [uint64]$dynamicGroupTest.frames_sent -ne 2 -or [bool]$dynamicGroupTest.bm_connected -or
        [string]$dynamicGroupTest.bm_state -cne 'not_started' -or -not [bool]$dynamicGroupTest.used_memory_sink) {
        throw ('隔离路由诊断结果不符合 offline RX/TX contract：{0}' -f $result.message)
    }
    $diagnosticProgressPath = Join-Path $isolatedConfig 'routing-diagnostic-progress.txt'
    if ([System.IO.File]::Exists($diagnosticProgressPath)) {
        $diagnosticProgress = [System.IO.File]::ReadAllText($diagnosticProgressPath, [System.Text.Encoding]::UTF8)
        if ($diagnosticProgress.Contains('auto-test-initialization-failed:')) {
            throw '自动诊断初始化记录了失败，但结果文件仍报告 passed。'
        }
    }
    if ([System.IO.File]::Exists((Join-Path $isolatedConfig 'password-file-path.txt')) -or
        [System.IO.Directory]::Exists((Join-Path $isolatedConfig 'ui-runs'))) {
        throw '隔离路由诊断触碰了密码指针或常规运行目录。'
    }

    Write-Output ('{0} 包级检查通过：{1} 个 PowerShell 文件均由 Windows PowerShell 5.1 解析；唯一 ASCII CMD 经包含空格和中文的包路径进入 PrepareOnly 与隔离 RoutingDiagnosticAutoTest。' -f $packageLabel, $scriptFiles.Count)
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $workPrefix = $workRoot.TrimEnd('\') + '\'
        if (-not $resolvedTestRoot.StartsWith($workPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [System.IO.Path]::GetFileName($resolvedTestRoot).StartsWith($testDirectoryPrefix, [System.StringComparison]::Ordinal)) {
            throw '测试临时目录路径校验失败，未执行清理。'
        }
        $rootInfo = New-Object System.IO.DirectoryInfo($resolvedTestRoot)
        if ($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw '测试临时目录是 reparse point，未执行清理。'
        }
        Assert-NoTestPathProcesses -TestRoot $resolvedTestRoot
        $remainingItems = @(Get-ChildItem -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue)
        if (@($remainingItems | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
            throw '测试临时目录包含 reparse point，未执行递归清理。'
        }
        [System.IO.Directory]::Delete($resolvedTestRoot, $true)
    }
}
