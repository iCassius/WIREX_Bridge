[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$NativeExecutable,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot '..'))
$uiScript = Join-Path $appRoot 'ui\windows\bridge-ui.ps1'
$modulePath = Join-Path $PSScriptRoot 'bridge-user-config.psm1'
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not [System.IO.File]::Exists($NativeExecutable)) { throw "Native executable not found: $NativeExecutable" }
if (-not [System.IO.File]::Exists($powershellExe)) { throw 'Windows PowerShell 5.1 was not found.' }

$workRoot = Join-Path $appRoot ('build\_work\ui-routing-diagnostic-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $workRoot 'package'
$isolated = Join-Path $workRoot 'isolated-user-config'
$canonical = Join-Path $package 'private\user-config'
[System.IO.Directory]::CreateDirectory($package) | Out-Null
[System.IO.Directory]::CreateDirectory($isolated) | Out-Null
[System.IO.Directory]::CreateDirectory($canonical) | Out-Null
Copy-Item -LiteralPath $modulePath -Destination (Join-Path $package 'bridge-user-config.psm1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-bm-radio-bridge.ps1') -Destination (Join-Path $package 'start-bm-radio-bridge.ps1')
Copy-Item -LiteralPath $NativeExecutable -Destination (Join-Path $package 'wirex_bridge.exe')

$sentinel = Join-Path $canonical 'do-not-touch.sentinel'
[System.IO.File]::WriteAllText($sentinel,'diagnostic-isolation-test',[System.Text.Encoding]::ASCII)
$canonicalHashBefore = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash

function Invoke-UiDiagnosticProbe {
    param([string[]]$Arguments,[string]$Name,[int]$WaitSeconds=12)
    $stdout = Join-Path $workRoot ($Name + '.stdout.txt')
    $stderr = Join-Path $workRoot ($Name + '.stderr.txt')
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
    $process = Start-Process -FilePath $powershellExe -ArgumentList $quoted -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit($WaitSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "$Name timed out."
    }
    $process.Refresh()
    $processExitCode = -1
    try { $processExitCode = [int]$process.ExitCode } catch { }
    return [pscustomobject]@{
        exit_code=$processExitCode
        stdout=if ([System.IO.File]::Exists($stdout)) { [System.IO.File]::ReadAllText($stdout,[System.Text.Encoding]::UTF8) } else { '' }
        stderr=if ([System.IO.File]::Exists($stderr)) { [System.IO.File]::ReadAllText($stderr,[System.Text.Encoding]::UTF8) } else { '' }
    }
}

$baseArguments = @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$uiScript,'-RoutingDiagnostic','-PackageDirectory',$package)
$missingConfig = Invoke-UiDiagnosticProbe -Arguments $baseArguments -Name 'missing-user-config' -WaitSeconds 10
if (($missingConfig.stderr + $missingConfig.stdout) -notmatch '-UserConfigDirectory') {
    throw ('RoutingDiagnostic missing-config probe did not reject correctly: exit={0}; output={1}{2}' -f $missingConfig.exit_code,$missingConfig.stdout,$missingConfig.stderr)
}

$canonicalArguments = $baseArguments + @('-RoutingDiagnosticAutoTest','-UserConfigDirectory',$canonical)
$canonicalProbe = Invoke-UiDiagnosticProbe -Arguments $canonicalArguments -Name 'canonical-config' -WaitSeconds 10
if (($canonicalProbe.stderr + $canonicalProbe.stdout) -notmatch '-UserConfigDirectory' -or
    ($canonicalProbe.stderr + $canonicalProbe.stdout) -match 'routing-diagnostic-fixture\.json') {
    throw 'RoutingDiagnostic accepted the package canonical user-config directory.'
}
$canonicalHashAfter = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
if ($canonicalHashBefore -cne $canonicalHashAfter) { throw 'Canonical user-config sentinel changed during rejection probes.' }

$missingFixtureArguments = $baseArguments + @('-RoutingDiagnosticAutoTest','-UserConfigDirectory',$isolated)
$fixtureProbe = Invoke-UiDiagnosticProbe -Arguments $missingFixtureArguments -Name 'missing-fixture' -WaitSeconds 10
if (($fixtureProbe.stderr + $fixtureProbe.stdout) -notmatch 'routing-diagnostic-fixture\.json') {
    throw 'RoutingDiagnosticAutoTest did not require its isolation marker.'
}

Import-Module -Name $modulePath -Force
$connection = [pscustomobject][ordered]@{
    callsign='TEST'; gateway_id=[uint64]1; source_id=[uint64]1
    master='192.0.2.1'; master_port=[uint64]62031; color_code=[uint64]1
}
$devices = [pscustomobject][ordered]@{
    serial_port='auto'; wave_in_endpoint_id='auto'; wave_out_endpoint_id='auto'
}
$txTarget = [pscustomobject][ordered]@{ destination_id=[uint64]91; kind='group'; slot=[uint64]2 }
$policy = [pscustomobject][ordered]@{
    group_mode='selected'; private_mode='disabled'; allow_groups=@(); allow_private_peers=@()
    local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
}
$profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices -TxTarget $txTarget `
    -RxPolicy $policy -TransmitEnabled $false
$profilePath = Join-Path $isolated 'connection-profile.json'
Write-BridgeUserConnectionProfile -Path $profilePath -Profile $profile
$fixture = [pscustomobject][ordered]@{
    schema_version=1; purpose='wirex-routing-diagnostic-test'; fixture_id=[guid]::NewGuid().ToString('N'); source_id=1
}
[System.IO.File]::WriteAllText((Join-Path $isolated 'routing-diagnostic-fixture.json'),
    (ConvertTo-Json -InputObject $fixture -Compress),(New-Object System.Text.UTF8Encoding($false)))

$runArguments = $baseArguments + @('-RoutingDiagnosticAutoTest','-UserConfigDirectory',$isolated)
$run = Invoke-UiDiagnosticProbe -Arguments $runArguments -Name 'real-wpf-routing-diagnostic' -WaitSeconds $TimeoutSeconds
$resultPath = Join-Path $isolated 'routing-diagnostic-result.json'
if (-not [System.IO.File]::Exists($resultPath)) { throw 'WPF routing diagnostic did not write its result file.' }
$result = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resultPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
if (-not [bool]$result.passed -or -not [bool]$result.offline_cancel_verified -or -not [bool]$result.timeout_fence_verified) {
    throw ('WPF routing diagnostic reported failure: {0}' -f $result.message)
}
$dynamicGroupTest = $result.dynamic_group_action_test
if (-not $dynamicGroupTest -or -not [bool]$dynamicGroupTest.passed -or
    [string]$dynamicGroupTest.local_listen_command -cne 'rx_policy.replace' -or
    [string]$dynamicGroupTest.activation_command -cne 'network_subscription.quick_call_join' -or
    [uint64]$dynamicGroupTest.destination_id -ne 46001 -or [uint64]$dynamicGroupTest.slot -ne 2 -or
    [uint64]$dynamicGroupTest.frames_sent -ne 2 -or [bool]$dynamicGroupTest.replayed -or
    -not [bool]$dynamicGroupTest.rx_tx_unchanged_after_activation -or
    -not [bool]$dynamicGroupTest.source_block_preserved -or
    [bool]$dynamicGroupTest.bm_connected -or [string]$dynamicGroupTest.bm_state -cne 'not_started' -or
    -not [bool]$dynamicGroupTest.used_memory_sink) {
    throw ('WPF dynamic-group button flow did not preserve the explicit offline RX/TX contract: {0}' -f $result.message)
}
$saved = Read-BridgeUserConnectionProfile -Path $profilePath
if (@($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 1 -or
    @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 46001 -and [uint64]$_.slot -eq 2 }).Count -ne 1 -or
    @($saved.rx_policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 0 -or
    @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
    [uint64]$saved.tx_target.destination_id -ne 53000 -or $saved.tx_target.kind -cne 'group' -or
    [uint64]$saved.tx_target.slot -ne 2 -or -not $saved.transmit_enabled) {
    throw 'WPF diagnostic profile did not preserve its RX/TX result and source filter.'
}
if ([System.IO.File]::Exists((Join-Path $isolated 'password-file-path.txt')) -or
    [System.IO.Directory]::Exists((Join-Path $isolated 'ui-runs'))) {
    throw 'Routing diagnostic unexpectedly accessed normal password/run preparation paths.'
}
$canonicalHashAfterRun = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
if ($canonicalHashBefore -cne $canonicalHashAfterRun) { throw 'Canonical user-config sentinel changed during diagnostic.' }
Write-Output ('通过：WPF 实际按钮→Supervisor→Native 诊断覆盖 RX/TX设置、来源屏蔽、独立TG46001/TS2本机收听与动态组激活命令；QuickCall只经内存sink验证header+EOT，没有连接BM；TX许可/目标和源屏蔽保留；隔离目录与canonical配置均通过。' + $result.message)
