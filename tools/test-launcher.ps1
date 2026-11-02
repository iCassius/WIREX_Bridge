[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$LauncherPath)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Launcher lifecycle checks must run in Windows PowerShell 5.1.'
}
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
$launcherSource = [System.IO.Path]::GetFullPath($LauncherPath)
if (-not [System.IO.File]::Exists($launcherSource)) { throw 'The compiled launcher does not exist.' }
if (-not [System.IO.Directory]::Exists($workRoot)) { throw 'app/build/_work does not exist.' }
. (Join-Path $PSScriptRoot 'package-release.ps1')
$releaseProfile = Get-ReleaseProfile -Version 'v0.1.0'
$runtimeStartUiRecord = @($releaseProfile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'runtime/start-ui.ps1' })
if ($runtimeStartUiRecord.Count -ne 1) { throw 'The stable profile must provide exactly one runtime/start-ui.ps1 entry.' }

$testRoot = Join-Path $workRoot ('launcher-test-' + [guid]::NewGuid().ToString('N'))
$exeRoot = Join-Path $testRoot 'portable package 中文 path'
$runtimeRoot = Join-Path $exeRoot 'runtime'
$runtimeStartUi = Join-Path $runtimeRoot 'start-ui.ps1'
$runtimeWindows = Join-Path $runtimeRoot 'ui\windows'
$marker = Join-Path $testRoot 'ui-called.txt'
$startUiProbePath = Join-Path $testRoot 'start-ui-parameters.txt'
$uiModePath = Join-Path $testRoot 'ui-mode.txt'
$childPidPath = Join-Path $testRoot 'fake-child.pid'
$childScript = Join-Path $testRoot 'fake-child.ps1'
$callerDirectory = Join-Path $testRoot 'different working directory 中文'
$copied = $false
$ownedChildId = 0
$assertions = 0

function Assert-LauncherTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Invoke-LauncherFixture {
    param([switch]$NoConnect, [switch]$ValidateConfig, [switch]$FailRoutingDiagnostic,
        [AllowNull()][AllowEmptyString()][string]$RawArguments = $null, [string]$Label)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $exeRoot 'WirexBridge.exe'
    $startInfo.Arguments = if ($PSBoundParameters.ContainsKey('RawArguments')) { $RawArguments } elseif ($ValidateConfig) { '--validate-config' } elseif ($NoConnect) { '--no-connect' } else { '' }
    $startInfo.WorkingDirectory = $callerDirectory
    $startInfo.UseShellExecute = $false
    [void]$startInfo.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_MARKER'] = $marker
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_MODE'] = $uiModePath
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_CHILD_PID'] = $childPidPath
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_CHILD_SCRIPT'] = $childScript
    $startInfo.EnvironmentVariables['WIREX_TEST_START_UI_PROBE'] = $startUiProbePath
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_START_CHILD'] = if ($NoConnect -or $ValidateConfig) { '0' } else { '1' }
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_FAIL_DIAGNOSTIC'] = if ($FailRoutingDiagnostic) { '1' } else { '0' }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw ($Label + ': could not start the launcher fixture.') }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw ($Label + ': launcher did not stop after timeout.') }
        throw ($Label + ': launcher timed out.')
    }
    $script:lastLauncherStandardOutput = [string]$stdoutTask.Result
    $script:lastLauncherStandardError = [string]$stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    return $exitCode
}

function Invoke-DirectRoutingDiagnostic {
    param([string]$UserConfigDirectory, [switch]$PassPortableDirectory)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',
        $runtimeStartUi,'-PackageDirectory',$runtimeRoot,
        '-UserConfigDirectory',$UserConfigDirectory,'-RoutingDiagnostic','-RoutingDiagnosticAutoTest')
    if ($PassPortableDirectory) { $arguments += @('-PortableDirectory',$exeRoot) }
    $startInfo.Arguments = ($arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' '
    $startInfo.WorkingDirectory = $callerDirectory
    $startInfo.UseShellExecute = $false
    [void]$startInfo.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_MARKER'] = $marker
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_MODE'] = $uiModePath
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_CHILD_PID'] = $childPidPath
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_CHILD_SCRIPT'] = $childScript
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_START_CHILD'] = '0'
    $startInfo.EnvironmentVariables['WIREX_FAKE_UI_FAIL_DIAGNOSTIC'] = '0'
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start direct start-ui diagnostic fixture.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        throw 'Direct start-ui diagnostic did not exit after refusing a package-local config path.'
    }
    $result = [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=[string]$stdoutTask.Result; Stderr=[string]$stderrTask.Result }
    $process.Dispose()
    return $result
}

function Get-LauncherPeFacts {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or [System.BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) {
        throw 'Launcher does not have a valid DOS/PE header.'
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 64 -or $peOffset + 92 -gt $bytes.Length -or
        [System.BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
        throw 'Launcher PE header is incomplete.'
    }
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $optionalSize = [System.BitConverter]::ToUInt16($bytes, $peOffset + 20)
    $optionalOffset = $peOffset + 24
    if ($optionalSize -lt 70 -or $optionalOffset + $optionalSize -gt $bytes.Length) {
        throw 'Launcher optional header is incomplete.'
    }
    $magic = [System.BitConverter]::ToUInt16($bytes, $optionalOffset)
    $subsystem = [System.BitConverter]::ToUInt16($bytes, $optionalOffset + 68)
    return [pscustomobject]@{ Machine=$machine; OptionalMagic=$magic; Subsystem=$subsystem }
}

function Test-ByteSequence {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return $false }
    for ($start = 0; $start -le ($Haystack.Length - $Needle.Length); $start++) {
        $matched = $true
        for ($offset = 0; $offset -lt $Needle.Length; $offset++) {
            if ($Haystack[$start + $offset] -ne $Needle[$offset]) { $matched = $false; break }
        }
        if ($matched) { return $true }
    }
    return $false
}

function Stop-OwnedFakeChildIfNeeded {
    if ($script:ownedChildId -le 0) { return }
    $process = @(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $script:ownedChildId) -ErrorAction Stop)
    if ($process.Count -eq 0) { return }
    $commandLine = [string]$process[0].CommandLine
    $expectedScript = [System.IO.Path]::GetFullPath($childScript)
    if ([string]$process[0].Name -ine 'powershell.exe' -or
        $commandLine.IndexOf($expectedScript, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Refusing cleanup because the remaining process is not the synthetic child created by this test.'
    }
    Stop-Process -Id $script:ownedChildId -Force -ErrorAction Stop
    $script:ownedChildId = 0
}

try {
    foreach ($relativeDirectory in $releaseProfile.Directories) {
        New-Item -ItemType Directory -Path (Join-Path $exeRoot ([string]$relativeDirectory).Replace('/',[System.IO.Path]::DirectorySeparatorChar)) -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $runtimeWindows -Force | Out-Null
    New-Item -ItemType Directory -Path $callerDirectory -Force | Out-Null
    Copy-Item -LiteralPath $launcherSource -Destination (Join-Path $exeRoot 'WirexBridge.exe') -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $appRoot ([string]$runtimeStartUiRecord[0].Source)) -Destination $runtimeStartUi -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $appRoot 'ui\windows\PortableConfig.psm1') -Destination (Join-Path $runtimeWindows 'PortableConfig.psm1') -ErrorAction Stop
    [System.IO.File]::WriteAllBytes((Join-Path $runtimeRoot 'wirex_bridge.exe'), [byte[]]@())
    [System.IO.File]::WriteAllText($childScript, 'Start-Sleep -Seconds 60' + "`n", (New-Object System.Text.UTF8Encoding($true)))
    $fakeUi = @'
param([switch]$NoAutoConnect, [switch]$RoutingDiagnostic, [switch]$RoutingDiagnosticAutoTest, [string]$UserConfigDirectory, [string]$PortableDirectory)
$marker = $env:WIREX_FAKE_UI_MARKER
if ($env:WIREX_FAKE_UI_START_CHILD -ceq '1') {
    $child = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList ('-NoLogo -NoProfile -WindowStyle Hidden -File "' + $env:WIREX_FAKE_UI_CHILD_SCRIPT + '"') `
        -PassThru -WindowStyle Hidden
    [System.IO.File]::WriteAllText($env:WIREX_FAKE_UI_CHILD_PID, [string]$child.Id)
}
[System.IO.File]::WriteAllText($marker, 'fake UI entry reached')
[System.IO.File]::WriteAllText($env:WIREX_FAKE_UI_MODE, ([string][bool]$NoAutoConnect) + '|' + ([string][bool]$RoutingDiagnostic) + '|' + ([string][bool]$RoutingDiagnosticAutoTest) + '|' + $env:WIREX_FAKE_UI_FAIL_DIAGNOSTIC)
if ($RoutingDiagnostic -and $env:WIREX_FAKE_UI_FAIL_DIAGNOSTIC -ceq '1') { throw 'synthetic diagnostic failure' }
'@
    [System.IO.File]::WriteAllText((Join-Path $runtimeWindows 'bridge-ui.ps1'), $fakeUi + "`n", (New-Object System.Text.UTF8Encoding($true)))
    $zoneMarker = "[ZoneTransfer]`r`nZoneId=3`r`n"
    foreach ($motedPath in @($runtimeStartUi,
            (Join-Path $runtimeWindows 'PortableConfig.psm1'), (Join-Path $runtimeWindows 'bridge-ui.ps1'))) {
        Set-Content -LiteralPath $motedPath -Stream Zone.Identifier -Value $zoneMarker -Encoding ASCII -NoNewline
        Assert-LauncherTest ((Get-Content -LiteralPath $motedPath -Stream Zone.Identifier -Raw) -match 'ZoneId=3') `
            ('Zone.Identifier should mark the synthetic downloaded file: ' + [System.IO.Path]::GetFileName($motedPath))
    }
    $copied = $true

    $startUiText = [System.IO.File]::ReadAllText($runtimeStartUi, [System.Text.Encoding]::UTF8)
    $probeSnippet = @'
if (-not [string]::IsNullOrWhiteSpace($env:WIREX_TEST_START_UI_PROBE)) {
    [System.IO.File]::WriteAllText($env:WIREX_TEST_START_UI_PROBE, ([string][bool]$PortableDirectory + '|' + [string][bool]$ValidateConfigOnly + '|' + [string]$PackageDirectory))
}
'@
    $startUiText = $startUiText.Replace("`$ErrorActionPreference = 'Stop'", $probeSnippet + "`r`n`$ErrorActionPreference = 'Stop'")
    [System.IO.File]::WriteAllText($runtimeStartUi, $startUiText, (New-Object System.Text.UTF8Encoding($true)))
    Set-Content -LiteralPath $runtimeStartUi -Stream Zone.Identifier -Value $zoneMarker -Encoding ASCII -NoNewline
    Assert-LauncherTest ((Get-Content -LiteralPath $runtimeStartUi -Stream Zone.Identifier -Raw) -match 'ZoneId=3') `
        'the instrumented synthetic launcher script should retain the downloaded-file Zone.Identifier'

    $peFacts = Get-LauncherPeFacts -Path (Join-Path $exeRoot 'WirexBridge.exe')
    Assert-LauncherTest ($peFacts.Machine -eq 0x8664 -and $peFacts.OptionalMagic -eq 0x20b) `
        'launcher output should be a 64-bit PE32+ image'
    Assert-LauncherTest ($peFacts.Subsystem -eq 2) 'launcher output should use the Windows GUI subsystem and show no console window'
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $exeRoot 'WirexBridge.exe'))
    Assert-LauncherTest ($versionInfo.ProductName -ceq 'WIREX Bridge' -and $versionInfo.FileVersion -ceq '0.1.0.0' -and
        $versionInfo.ProductVersion -ceq '0.1.0' -and $versionInfo.CompanyName -ceq 'iCassius') `
        'launcher PE metadata should identify WIREX Bridge v0.1.0 and iCassius'
    $launcherBytes = [System.IO.File]::ReadAllBytes((Join-Path $exeRoot 'WirexBridge.exe'))
    $unicodeLiteral = [System.Text.Encoding]::Unicode.GetBytes('WIREX Bridge 启动失败')
    Assert-LauncherTest (Test-ByteSequence -Haystack $launcherBytes -Needle $unicodeLiteral) `
        'compiled launcher should preserve the Chinese startup message as a Unicode string'

    $validateExit = Invoke-LauncherFixture -ValidateConfig -Label 'validate-config initial bootstrap'
    $configPath = Join-Path $exeRoot 'config.json'
    Assert-LauncherTest ($validateExit -eq 0) 'validate-config should initialize a config and exit successfully'
    Assert-LauncherTest ([System.IO.File]::Exists($configPath)) 'missing config should be created beside WirexBridge.exe'
    Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) `
        ('validate-config must exit before bridge-ui; marker=' + [System.IO.File]::Exists($marker) +
            '; ui-mode=' + $(if ([System.IO.File]::Exists($uiModePath)) { [System.IO.File]::ReadAllText($uiModePath) } else { '<none>' }) +
            '; start-ui=' + $(if ([System.IO.File]::Exists($startUiProbePath)) { [System.IO.File]::ReadAllText($startUiProbePath) } else { '<none>' }) +
            '; launcher stdout=' + $script:lastLauncherStandardOutput + '; launcher stderr=' + $script:lastLauncherStandardError)
    $configModule = Join-Path $runtimeWindows 'PortableConfig.psm1'
    Import-Module $configModule -Force -ErrorAction Stop
    $config = Get-WirexPortableConfig -Path $configPath
    Assert-LauncherTest ($config.connection.callsign -ceq '' -and $config.connection.password -ceq '' -and $config.connection.api_key -ceq '') `
        'first-start config must contain empty callsign, password, and API key values'
    Assert-LauncherTest (@(Get-ChildItem -LiteralPath $exeRoot -Filter 'config.json.init-*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) `
        'atomic config creation should leave no temporary file'

    Add-Member -InputObject $config -NotePropertyName synthetic_unknown_field -NotePropertyValue 'preserve-this'
    $existingBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Depth 24) + "`n")
    [System.IO.File]::WriteAllBytes($configPath, $existingBytes)
    $existingHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $existingExit = Invoke-LauncherFixture -ValidateConfig -Label 'existing config read-only validation'
    Assert-LauncherTest ($existingExit -eq 0) 'an existing valid config should pass validate-config'
    Assert-LauncherTest ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $existingHash) `
        'config initialization must not rewrite existing bytes or unknown fields'

    $badBytes = [System.Text.Encoding]::UTF8.GetBytes('{ broken-json')
    [System.IO.File]::WriteAllBytes($configPath, $badBytes)
    $badExit = Invoke-LauncherFixture -ValidateConfig -Label 'malformed config refusal'
    Assert-LauncherTest ($badExit -ne 0) 'malformed config must stop validate-config with a nonzero exit code'
    Assert-LauncherTest ([System.Linq.Enumerable]::SequenceEqual([byte[]]$badBytes, [byte[]][System.IO.File]::ReadAllBytes($configPath))) `
        'malformed config bytes must remain unchanged'
    Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) 'config failure must exit before bridge-ui is loaded'

    [System.IO.File]::Delete($configPath)
    $noConnectUiExit = Invoke-LauncherFixture -NoConnect -Label 'no-connect UI lifecycle'
    Assert-LauncherTest ($noConnectUiExit -eq 0) '--no-connect should open the actual UI entry and exit normally'
    Assert-LauncherTest ([System.IO.File]::Exists($marker)) '--no-connect should launch bridge-ui'
    Assert-LauncherTest ([System.IO.File]::ReadAllText($uiModePath) -ceq 'True|False|False|0') '--no-connect should pass NoAutoConnect and no diagnostic flags to bridge-ui'
    [System.IO.File]::Delete($marker)
    [System.IO.File]::Delete($uiModePath)

    $configHashBeforeRejectedDiagnostics = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $directRootDiagnostic = Invoke-DirectRoutingDiagnostic -UserConfigDirectory $exeRoot
    Assert-LauncherTest ($directRootDiagnostic.ExitCode -ne 0) 'direct start-ui should reject the executable root as UserConfigDirectory'
    Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) 'direct start-ui should reject the root before bridge-ui is loaded'
    Assert-LauncherTest ($directRootDiagnostic.Stderr.Length -gt 0) 'direct start-ui should explain the isolated-root refusal'
    $directRuntimeDiagnostic = Invoke-DirectRoutingDiagnostic -UserConfigDirectory $runtimeRoot -PassPortableDirectory
    Assert-LauncherTest ($directRuntimeDiagnostic.ExitCode -ne 0) 'direct start-ui should reject runtime as UserConfigDirectory'
    Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) 'direct start-ui should reject runtime before bridge-ui is loaded'

    foreach ($forbiddenDiagnosticDirectory in @($exeRoot,$runtimeRoot)) {
        $forbiddenArguments = '--routing-diagnostic "' + $forbiddenDiagnosticDirectory + '"'
        $forbiddenExit = Invoke-LauncherFixture -RawArguments $forbiddenArguments `
            -Label 'launcher rejects package-local routing config'
        Assert-LauncherTest ($forbiddenExit -ne 0) ('launcher should reject diagnostic config under package: ' + $forbiddenDiagnosticDirectory)
        Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) 'launcher should refuse package-local diagnostic paths before UI startup'
    }
    Assert-LauncherTest ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $configHashBeforeRejectedDiagnostics) `
        'direct-script and EXE diagnostic guard failures must preserve the executable-root config bytes'

    $normalExit = Invoke-LauncherFixture -Label 'normal fake UI lifecycle'
    Assert-LauncherTest ($normalExit -eq 0) 'normal startup should return the fake UI process exit code'
    Assert-LauncherTest ([System.IO.File]::Exists($marker)) 'normal startup should load the fake bridge-ui entry'
    Assert-LauncherTest ([System.IO.File]::Exists($childPidPath)) 'fake bridge-ui should create one synthetic descendant process'
    $script:ownedChildId = [int][System.IO.File]::ReadAllText($childPidPath).Trim()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $child = @(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $script:ownedChildId) -ErrorAction Stop)
        if ($child.Count -eq 0) { $script:ownedChildId = 0; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-LauncherTest ($script:ownedChildId -eq 0) 'closing the launcher job should reap the fake descendant after PowerShell exits'

    $isolatedDiagnosticDirectory = Join-Path $testRoot 'isolated routing config'
    New-Item -ItemType Directory -Path $isolatedDiagnosticDirectory -Force | Out-Null
    $configHashBeforeDiagnostic = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $routingArguments = '--routing-diagnostic "' + $isolatedDiagnosticDirectory + '"'
    $diagnosticExit = Invoke-LauncherFixture -FailRoutingDiagnostic -RawArguments $routingArguments `
        -Label 'noninteractive routing diagnostic failure'
    Assert-LauncherTest ($diagnosticExit -eq 2) `
        ('routing diagnostic should return the UI exit code without a modal dialog; exit=' + $diagnosticExit +
            '; ui-mode=' + $(if ([System.IO.File]::Exists($uiModePath)) { [System.IO.File]::ReadAllText($uiModePath) } else { '<none>' }) +
            '; stderr=' + $script:lastLauncherStandardError)
    Assert-LauncherTest ([System.IO.File]::Exists($marker)) 'routing diagnostic should reach the isolated UI entry'
    Assert-LauncherTest ([System.IO.File]::ReadAllText($uiModePath) -ceq 'True|True|True|1') `
        'routing diagnostic should disable auto-connect and pass both diagnostic flags'
    Assert-LauncherTest ([System.IO.File]::Exists($childPidPath)) 'routing diagnostic failure fixture should create one synthetic child'
    $script:ownedChildId = [int][System.IO.File]::ReadAllText($childPidPath).Trim()
    $diagnosticChildDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $diagnosticChildDeadline) {
        $diagnosticChild = @(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $script:ownedChildId) -ErrorAction Stop)
        if ($diagnosticChild.Count -eq 0) { $script:ownedChildId = 0; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-LauncherTest ($script:ownedChildId -eq 0) 'routing diagnostic failure should not leave its synthetic child process running'
    Assert-LauncherTest ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $configHashBeforeDiagnostic) `
        'routing diagnostic should leave the executable-root user config unchanged'
    Assert-LauncherTest ($script:lastLauncherStandardError -match 'Isolated routing diagnostic failed \(exit code 2\)') `
        ('routing diagnostic should write a bounded non-secret error to redirected stderr; stderr=' + $script:lastLauncherStandardError)

    [System.IO.File]::Delete($marker)
    [System.IO.File]::Delete($uiModePath)
    $unknownExit = Invoke-LauncherFixture -RawArguments '--not-a-supported-mode' -Label 'unknown CLI refusal'
    Assert-LauncherTest ($unknownExit -eq 64) 'unknown CLI should return a strict nonzero usage code'
    Assert-LauncherTest (-not [System.IO.File]::Exists($marker)) 'unknown CLI should stop before launching PowerShell UI'
    Assert-LauncherTest ($script:lastLauncherStandardError -match 'Usage: WirexBridge.exe') `
        'unknown CLI should return usage on stderr without opening a modal dialog'

    Write-Output ('Launcher synthetic startup assertions passed: ' + $script:assertions + '; no real UI, Native, device, BrandMeister, audio, PTT, or RF path was started.')
} finally {
    Stop-OwnedFakeChildIfNeeded
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $resolvedWorkRoot = [System.IO.Path]::GetFullPath($workRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($copied -and $resolvedTestRoot.StartsWith($resolvedWorkRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedTestRoot).StartsWith('launcher-test-', [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedTestRoot) { throw 'Launcher test temporary directory remains after cleanup.' }
    }
}
