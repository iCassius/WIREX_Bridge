#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PackageDirectory,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Full launcher routing diagnostics require Windows PowerShell 5.1.'
}
if ($TimeoutSeconds -lt 20 -or $TimeoutSeconds -gt 600) { throw 'TimeoutSeconds must be between 20 and 600.' }

$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
$packageRoot = [System.IO.Path]::GetFullPath($PackageDirectory)
$launcher = Join-Path $packageRoot 'WirexBridge.exe'
$runtimeRoot = Join-Path $packageRoot 'runtime'
$configModule = Join-Path $runtimeRoot 'ui\windows\PortableConfig.psm1'
foreach ($path in @($launcher, (Join-Path $runtimeRoot 'start-ui.ps1'),
        (Join-Path $runtimeRoot 'ui\windows\bridge-ui.ps1'),
        (Join-Path $runtimeRoot 'wirex_bridge.exe'), $configModule)) {
    if (-not [System.IO.File]::Exists($path)) { throw "Release candidate is incomplete: $path" }
}
if (-not [System.IO.Directory]::Exists($workRoot)) { throw 'app/build/_work does not exist.' }
$isolatedPrefix = $workRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$diagnosticId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$testRoot = Join-Path $workRoot ('rd-' + $diagnosticId)
$isolated = Join-Path $testRoot 'cfg'
$created = $false
$launcherProcess = $null

try {
    if ([System.IO.Directory]::Exists($testRoot) -or [System.IO.File]::Exists($testRoot)) { throw 'Unique diagnostic test directory already exists.' }
    [System.IO.Directory]::CreateDirectory($isolated) | Out-Null
    $created = $true
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($isolatedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolvedTestRoot) -notlike 'rd-????????') {
        throw 'Diagnostic test directory escaped build/_work.'
    }

    Import-Module -Name $configModule -Force -ErrorAction Stop
    $configPath = [System.IO.Path]::GetFullPath((Join-Path $isolated 'config.json'))
    $maximumBackupPathLength = $configPath.Length + '.backup-'.Length + 19 + 1 + 32
    if ($maximumBackupPathLength -ge 260) {
        throw ('Diagnostic config backup path must stay below MAX_PATH; calculated=' + $maximumBackupPathLength)
    }
    $config = Get-WirexPortableConfig -Path $configPath
    $config.connection.callsign = 'TEST'
    $config.connection.gateway_id = [uint64]100
    $config.connection.source_id = [uint64]1
    $config.connection.master = '127.0.0.1'
    $config.connection.master_port = [uint64]62031
    $config.connection.color_code = [uint64]1
    $config.connection.password = ''
    $config.connection.api_key = ''
    [void](Save-WirexPortableConfig -Path $configPath -Config $config)
    $marker = [pscustomobject][ordered]@{
        schema_version = 1
        purpose = 'wirex-routing-diagnostic-test'
        fixture_id = [guid]::NewGuid().ToString('N')
        source_id = 1
    }
    [System.IO.File]::WriteAllText((Join-Path $isolated 'routing-diagnostic-fixture.json'),
        (ConvertTo-Json -InputObject $marker -Compress), (New-Object System.Text.UTF8Encoding($false)))

    $rootConfigPath = Join-Path $packageRoot 'config.json'
    if ([System.IO.File]::Exists($rootConfigPath)) { throw 'Generic release candidate unexpectedly contains config.json.' }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launcher
    $startInfo.Arguments = '--routing-diagnostic "' + $isolated.Replace('"','') + '"'
    $startInfo.WorkingDirectory = $workRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $launcherProcess = New-Object System.Diagnostics.Process
    $launcherProcess.StartInfo = $startInfo
    if (-not $launcherProcess.Start()) { throw 'Could not start the candidate WirexBridge.exe.' }
    if (-not $launcherProcess.WaitForExit($TimeoutSeconds * 1000)) {
        throw "The real launcher → PowerShell → WPF → Native routing diagnostic did not exit within $TimeoutSeconds seconds."
    }
    $launcherProcess.Refresh()
    if ($launcherProcess.ExitCode -ne 0) { throw "Candidate routing diagnostic exited with code $($launcherProcess.ExitCode)." }

    $resultPath = Join-Path $isolated 'routing-diagnostic-result.json'
    if (-not [System.IO.File]::Exists($resultPath)) { throw 'The candidate UI did not write routing-diagnostic-result.json.' }
    $result = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resultPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $flow = $result.channel_flow_test
    if ([int]$result.schema_version -ne 2 -or -not [bool]$result.passed -or
        -not [bool]$flow.passed -or [string]$flow.channel_key -cne 'group:12345:1' -or
        [string]$flow.rx_command -cne 'rx_policy.replace' -or
        [string]$flow.quick_call_command -cne 'network_subscription.quick_call_join' -or
        -not [bool]$flow.ptt_unchanged_after_add -or -not [bool]$flow.root_config_saved -or
        [uint64]$flow.frames_sent -ne 2 -or [bool]$flow.bm_connected -or
        -not [bool]$flow.used_memory_sink -or -not [bool]$flow.routing_unchanged_after_activation -or
        -not [bool]$flow.normal_shutdown_requested) {
        throw ('Candidate WPF/Native diagnostic reported a failed offline routing contract: ' + [string]$result.message)
    }
    $progressPath = Join-Path $isolated 'routing-diagnostic-progress.txt'
    if (-not [System.IO.File]::Exists($progressPath)) { throw 'The candidate UI did not write diagnostic progress.' }
    $progress = [System.IO.File]::ReadAllText($progressPath,[System.Text.Encoding]::UTF8)
    foreach ($step in @('native-start-requested','channel-flow-test-passed')) {
        if (-not $progress.Contains($step)) { throw "Candidate diagnostic progress is missing $step." }
    }
    if ([System.IO.File]::Exists($rootConfigPath)) { throw 'Routing diagnostic wrote config.json beside WirexBridge.exe.' }
    Write-Output ('Full candidate launcher routing diagnostic passed: exit=0; WPF/Native flow=' + [string]$flow.quick_call_command +
        '; BM=false; two memory-sink frames; normal shutdown requested. No hardware, audio, PTT, or RF was used.')
} finally {
    if ($null -ne $launcherProcess) { $launcherProcess.Dispose() }
    if ($created) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($isolatedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTestRoot) -notlike 'rd-????????') {
            throw 'Refusing cleanup because the temporary diagnostic directory failed path validation.'
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
        if ([System.IO.Directory]::Exists($resolvedTestRoot)) { throw 'The temporary diagnostic directory remains after cleanup.' }
    }
}
