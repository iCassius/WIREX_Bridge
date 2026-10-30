[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-UiIdentity {
    param([object]$Condition,[string]$Message)
    if ($Condition -is [array]) {
        $stack = Get-PSCallStack
        throw "UI 身份测试断言收到数组，调用行 $($stack[1].ScriptLineNumber)：$Message"
    }
    if (-not [bool]$Condition) { throw "UI 身份测试失败：$Message" }
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行本测试，以创建真实 WPF Dispatcher。'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$modulePath = Join-Path $repoRoot 'ui\windows\RadioIdentity.psm1'
$fixturePath = Join-Path $PSScriptRoot 'test-radio-identity-http-server.ps1'
$tokens = $null
$parseErrors = $null
$uiAst = [Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
Assert-UiIdentity ($parseErrors.Count -eq 0) ("bridge-ui.ps1 必须能被 PowerShell 5.1 解析。 errors=" + (($parseErrors | ForEach-Object { $_.Message + '@' + $_.Extent.StartLineNumber }) -join '; '))

$functionNames = @(
    'Get-UiRadioIdentity','Get-UiNativeIdentityCallsign','Add-UiNativeIdentityMappingToQueue',
    'Save-UiNativeIdentityDeferredMapping','Test-AndMarkUiNativeIdentityCallRefresh','Expire-UiNativeIdentityUpdate',
    'Initialize-UiNativeIdentitySync','Start-NextUiNativeIdentityUpdate','Complete-UiNativeIdentityUpdate',
    'Format-UiRadioIdentity','Format-UiRadioIdentityDetails',
    'Update-UiCallHistoryActionState','Update-UiIdentityActionState',
    'Add-UiIdentityDiagnostic','Set-UiIdentityError','Clear-UiIdentityError','Set-UiIdentityRowVisibility',
    'Get-UiIdentityContextKey','Add-UiIdentityQueryContext','New-UiIdentityQueryContext',
    'Clear-UiIdentityQueryQueue','Set-UiIdentityFailureCooldown','Start-NextUiIdentityQuery',
    'Start-UiIdentityQuery','Update-UiIdentityHistoryEntry','Test-UiIdentityResultMatchesCurrent',
    'Complete-UiIdentityQueryResources','Stop-UiIdentityQuery','Complete-UiIdentityQuery',
    'Get-UiCallHistoryKey','Add-UiCallHistoryRecord','Request-StopAndExit','On-UiTimerTick'
)
foreach ($name in $functionNames) {
    $functionAst = $uiAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true)
    Assert-UiIdentity ($null -ne $functionAst) "缺少函数 $name"
    Invoke-Expression $functionAst.Extent.Text
}

Import-Module -Name $modulePath -Force
function Get-UiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    return $script:mainWindow.FindName($Name)
}
function Set-MainText {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $control = $script:mainWindow.FindName($Name)
    if ($control) { $control.Text = $Text }
}
function Set-ConnectionButtonState { }
function Complete-UiDeviceDiscovery { }
function Complete-BridgePreparation { }
function Complete-BridgeStop { return $false }
function Process-UiControlEvents { }
function Read-StatusUpdates { }
function Set-StaleDisplay { }
# 身份回归只验证自己的 Dispatcher 路径；CAT/BM timer 槽位保持空实现。
function Complete-UiRadioCatOperation { return $false }
function Invoke-UiRadioCatPollTick { return $false }
function Update-UiRadioCatControls { }
function Add-UiEvent { param([string]$Text) }

function New-TestWindow {
    $window = New-Object System.Windows.Window
    $window.Title = 'identity fixture'
    $window.Width = 420
    $window.Height = 220
    $root = New-Object System.Windows.Controls.StackPanel
    $window.Content = $root
    [System.Windows.NameScope]::SetNameScope($window,(New-Object System.Windows.NameScope))
    foreach ($item in @(
        @{name='QueryCurrentIdentityButton'; type='button'},
        @{name='CurrentCallPanel'; type='panel'},
        @{name='CurrentCallValue'; type='text'},
        @{name='CurrentCallDetail'; type='text'},
        @{name='RecentCallPanel'; type='panel'},
        @{name='RecentCaller'; type='text'},
        @{name='HistoryPanel'; type='panel'},
        @{name='HistoryActionsPanel'; type='panel'},
        @{name='CallHistoryList'; type='list'},
        @{name='IdentityLookupStatusValue'; type='text'},
        @{name='FooterText'; type='text'},
        @{name='StopButton'; type='button'}
    )) {
        switch ($item.type) {
            'button' { $control = New-Object System.Windows.Controls.Button; $control.Content = $item.name }
            'panel' { $control = New-Object System.Windows.Controls.StackPanel }
            'list' { $control = New-Object System.Windows.Controls.ListBox }
            default { $control = New-Object System.Windows.Controls.TextBlock }
        }
        $control.Name = $item.name
        if ($item.name -in @('CurrentCallPanel','RecentCallPanel','HistoryPanel','HistoryActionsPanel','IdentityLookupStatusValue')) {
            $control.Visibility = [System.Windows.Visibility]::Collapsed
        }
        [void]$window.RegisterName($item.name,$control)
        [void]$root.Children.Add($control)
    }
    $window.Show()
    return $window
}

function Initialize-TestState {
    param([Parameter(Mandatory=$true)][string]$TestDirectory,[Parameter(Mandatory=$true)][string]$ApiBaseUri)
    $script:mainWindow = New-TestWindow
    # bridge-ui initializes both windows in the application state. This fixture only
    # needs the routing window to be explicitly absent while identity callbacks run.
    $script:settingsWindow = $null
    $script:radioCatOperationPowerShell = $null
    $script:radioCatOperationAsync = $null
    $script:radioCatOperationStopAsync = $null
    $script:radioCatOperationOwnerWindow = $null
    $script:radioCatOperationKind = ''
    $script:radioCatPollingActive = $false
    $script:radioCatCloseMainAfterOperation = $false
    $script:radioCatCloseSettingsAfterOperation = $false
    $script:radioCatPowerNeedsUserChoice = $false
    $script:radioCatResult = $null
    $script:radioCatObserved = $null
    $script:radioModeApplyAfterStop = $null
    $script:radioModePreviousHriPortName = ''
    $script:RenderOnly = $false
    $script:radioIdentityModuleLoaded = $true
    $script:identityModulePath = $modulePath
    $script:identityCachePath = Join-Path $TestDirectory 'identity-cache.json'
    $script:identityDiagnosticPath = Join-Path $TestDirectory 'identity-query-errors.jsonl'
    $script:identityApiBaseUri = $ApiBaseUri
    $script:identityHttpTimeoutSec = 5
    $script:identityRequestIntervalMs = 1000
    $script:identityQueueLimit = 16
    $script:identityQueueCooldownSeconds = 30
    $script:identityQueueCooldownMaxSeconds = 900
    $script:identityQuery = $null
    $script:identityQueryQueue = New-Object 'System.Collections.Generic.List[object]'
    $script:identityQueuedById = @{}
    $script:identityFailureCooldown = @{}
    $script:identityNextRequestUtc = [DateTime]::MinValue
    $script:identityQuerySequence = 0
    $script:callIdentityCache = @{}
    $script:identityNativeCapability = $false
    $script:identityNativeRunId = ''
    $script:identityNativeRevision = [uint64]0
    $script:identityNativeQueue = New-Object 'System.Collections.Generic.List[object]'
    $script:identityNativeInFlight = $null
    $script:identityNativeDeferredBySource = @{}
    $script:identityNativeDeferredOrder = New-Object 'System.Collections.Generic.List[string]'
    $script:expiredIdentityNativeRequests = @{}
    $script:identityNativeCallRefreshKeys = @{}
    $script:identityNativeCallRefreshOrder = New-Object 'System.Collections.Generic.List[string]'
    $script:identityNativeSent = New-Object 'System.Collections.Generic.List[object]'
    $script:pendingControlRequests = @{}
    $script:callHistoryKeys = @{}
    $script:latestStatus = $null
    $script:lastStatusUtc = [DateTime]::MinValue
    $script:supervisor = $null
    $script:pendingRoutingMutation = $null
    $script:pendingQuickCall = $null
    $script:pendingDynamicCallTarget = $null
    $script:timedOutRoutingMutations = @{}
    $script:routingMutationFence = $false
    $script:prepareStopAsync = $null
    $script:preparePowerShell = $null
    $script:preparationStarted = $false
    $script:stopTask = $null
    $script:bmCloseWhenDisposed = $false
    $script:bmManagementUiDisposed = $false
    $script:closingAfterStop = $false
    $script:closingAfterIdentityQuery = $false
    $script:allowWindowClose = $false
    $script:windowClosed = $false
    $script:dispatcherUnhandled = $null
    $script:mainWindow.Add_Closed({ $script:windowClosed = $true })
}

function New-TestIdentitySupervisor {
    $supervisor = [pscustomobject]@{ HasExited=$false }
    $supervisor | Add-Member -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$ParametersJson)
        $script:identityNativeSent.Add([pscustomobject][ordered]@{
            request_id=$RequestId; command=$Command; parameters_json=$ParametersJson
        })
        return $true
    }
    return $supervisor
}

function Add-TestIdentityClickHandler {
    (Get-UiControl 'QueryCurrentIdentityButton').Add_Click({
        try {
            $call = $script:latestStatus
            if (-not $call -or -not [bool]$call.current_call_valid) { throw '当前没有有效来话来源可查询。' }
            $generation = if ($call.PSObject.Properties['current_call_generation']) { [uint64]$call.current_call_generation } else { [uint64]0 }
            Start-UiIdentityQuery -RadioId ([uint64]$call.current_call_source_id) -ContextKind current `
                -RunId ([string]$call.run_id) -Generation $generation
        } catch {
            Set-UiIdentityError -ErrorCode 'user_action' -Message $_.Exception.Message `
                -Detail $_.Exception.Message -Stage 'manual_query' -ShowToUser
        }
    })
}

function Start-LocalIdentityFixture {
    param([Parameter(Mandatory=$true)][ValidateSet('ok','not_found','invalid_callsign','delay_headers_timeout')][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Directory)
    $readyFile = Join-Path $Directory 'fixture-ready.txt'
    $requestFile = Join-Path $Directory 'fixture-request.txt'
    $hostPath = (Get-Process -Id $PID).Path
    if ([IO.Path]::GetFileNameWithoutExtension($hostPath) -notin @('pwsh','powershell')) {
        $hostPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    }
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -ReadyFile "{2}" -RequestRecordFile "{3}"' -f `
        $fixturePath,$Mode,$readyFile,$requestFile
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($readyFile) -and -not $process.HasExited -and $clock.ElapsedMilliseconds -lt 8000) {
        Start-Sleep -Milliseconds 25
    }
    if (-not [IO.File]::Exists($readyFile)) {
        $code = if ($process.HasExited) { $process.ExitCode } else { 'still running' }
        throw "本机 HTTP fixture 未启动（$code）。"
    }
    $port = [int][IO.File]::ReadAllText($readyFile,[Text.Encoding]::ASCII)
    return [pscustomobject]@{ process=$process; port=$port; request_file=$requestFile; ready_file=$readyFile }
}

function Get-TestCallRecord {
    param([uint64]$RadioId,[string]$RunId='run-ui-test',[uint64]$Generation=7)
    return [pscustomobject][ordered]@{
        run_id=$RunId; timestamp_utc_ms=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        current_call_valid=$true; current_call_source_id=$RadioId; current_call_destination_id=[uint64]91
        current_call_slot=[uint64]2; current_call_kind='G'; current_call_generation=$Generation
    }
}

function Set-TestLatestStatus {
    param([uint64]$RadioId,[string]$RunId='run-ui-test',[uint64]$Generation=7)
    $script:latestStatus = [pscustomobject][ordered]@{
        run_id=$RunId; current_call_valid=$true; current_call_source_id=$RadioId
        current_call_generation=$Generation; last_rx_header_valid=$true; last_rx_source_id=$RadioId
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $script:supervisor = [pscustomobject]@{ HasExited=$false }
}

function Seed-TestNativeIdentityMap {
    param([uint64]$RadioId,[string]$RunId='run-ui-test')
    $script:controlRunId = $RunId
    $script:controlConfirmed = $true
    $script:identityNativeCapability = $true
    $script:identityNativeRunId = $RunId
    $script:supervisor = New-TestIdentitySupervisor
    if (-not (Add-UiNativeIdentityMappingToQueue -SourceId $RadioId -Callsign 'N0OLD') -or
        $script:identityNativeSent.Count -ne 1 -or $script:identityNativeSent[0].request_id -cne 'radioid-1') {
        throw '测试 Native 正向缓存映射没有按预期发送。'
    }
    $ack = [pscustomobject][ordered]@{
        run_id=$RunId; request_id='radioid-1'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    if (-not (Complete-UiNativeIdentityUpdate -Record $ack)) { throw '测试 Native 正向缓存映射 ACK 未被接受。' }
    $script:identityNativeSent.Clear()
}

function Invoke-TestDispatcherUntil {
    param([Parameter(Mandatory=$true)][scriptblock]$Condition,[Parameter(Mandatory=$true)][int]$TimeoutMs)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition) -and $clock.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $script:mainWindow.Dispatcher.Invoke([Action]{
                $script:insideWpfDispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.CheckAccess()
                On-UiTimerTick
            },[System.Windows.Threading.DispatcherPriority]::Background)
        } catch { $script:dispatcherUnhandled = $_.Exception.Message }
        if (& $Condition) { break }
        Start-Sleep -Milliseconds 25
    }
    return (& $Condition)
}

function Wait-LocalFixtureExit {
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process,[int]$TimeoutMs=9000)
    if (-not $Process.WaitForExit($TimeoutMs)) { return $false }
    return $true
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('wirex-ui-identity-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$activeFixtures = New-Object 'System.Collections.Generic.List[Diagnostics.Process]'
try {
    # Successful lookup through the incoming-call path, a real Button.Click event,
    # the WPF dispatcher, and the owned background runspace.
    $fixture = Start-LocalIdentityFixture -Mode ok -Directory $testDirectory
    $activeFixtures.Add($fixture.process)
    $successDirectory = Join-Path $testDirectory 'success'
    [void][IO.Directory]::CreateDirectory($successDirectory)
    Initialize-TestState -TestDirectory $successDirectory `
        -ApiBaseUri ('http://127.0.0.1:{0}/api/dmr/user/' -f $fixture.port)
    Set-TestLatestStatus -RadioId 7654321
    $script:controlRunId = 'run-ui-test'
    $script:controlConfirmed = $true
    $script:identityNativeCapability = $true
    $script:identityNativeRunId = 'run-ui-test'
    $script:supervisor = New-TestIdentitySupervisor
    Add-TestIdentityClickHandler
    Set-MainText -Name 'CurrentCallValue' -Text 'DMR ID 7654321'
    Add-UiCallHistoryRecord -Record (Get-TestCallRecord -RadioId 7654321)
    Assert-UiIdentity ($null -ne $script:identityQuery) '来话入口应自动启动后台 ID 查询。'
    $queryOwned = $script:identityQuery
    Assert-UiIdentity ($queryOwned.contexts.Count -eq 1) '自动来话查询应先关联当前来话和历史记录。'
    (Get-UiControl 'QueryCurrentIdentityButton').RaiseEvent(
        [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiIdentity ($script:identityQuery.contexts.Count -eq 2) 'WPF 按钮点击应合并到同一 ID 查询。'
    $script:dispatcherUnhandled = $null
    $script:insideWpfDispatcher = $false
    $completed = Invoke-TestDispatcherUntil -Condition { $null -eq $script:identityQuery } -TimeoutMs 8000
    Assert-UiIdentity $completed '成功查询应在有限时间内完成。'
    Assert-UiIdentity ($null -eq $script:dispatcherUnhandled -and $script:insideWpfDispatcher) `
        ("查询结果不得从 WPF Dispatcher 回调抛出未处理异常。 error=[$script:dispatcherUnhandled], inside=[$script:insideWpfDispatcher]")
    Assert-UiIdentity ($queryOwned.disposed -and [string]$queryOwned.owned_runspace.RunspaceStateInfo.State -ceq 'Closed') `
        '成功结果必须先关闭并释放本查询独占的 runspace。'
    $currentLabel = [string](Get-UiControl 'CurrentCallValue').Text
    $historyLabel = [string](Get-UiControl 'CallHistoryList').Items[0].source_label
    Assert-UiIdentity ($currentLabel -match 'N0TEST' -and $historyLabel -match 'N0TEST') `
        ("成功查询应更新匹配的当前来话和历史呼号。 current=[$currentLabel], history=[$historyLabel], identity_status=[$($queryOwned.identity_result.status)], error=[$($queryOwned.error_code)], sent=[$($script:identityNativeSent.Count)], diagnostic=[$(if ([IO.File]::Exists($script:identityDiagnosticPath)) { [IO.File]::ReadAllText($script:identityDiagnosticPath,[Text.Encoding]::UTF8) })]")
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 1 -and
        $script:identityNativeSent[0].request_id -ceq 'radioid-1' -and
        $script:identityNativeSent[0].command -ceq 'radio_identity.cache_upsert') `
        '查得合法呼号后应经已确认的 Native 命令发送一次 cache upsert'
    $identityParameters = ConvertFrom-Json -InputObject $script:identityNativeSent[0].parameters_json -ErrorAction Stop
    $identityParameterNames = @($identityParameters.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-UiIdentity ($identityParameters.source_id -eq 7654321 -and $identityParameters.revision -eq 1 -and
        $identityParameters.callsign -ceq 'N0TEST' -and $identityParameterNames.Count -eq 3 -and
        @($identityParameterNames | Where-Object { $_ -in @('name','city','country','run_id','receive_generation') }).Count -eq 0) `
        'Native 收到的身份 payload 只含 Source ID、revision 和呼号，不含姓名、地区、run或通话代次'
    $identityAck = [pscustomobject][ordered]@{
        run_id='run-ui-test'; request_id='radioid-1'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    Assert-UiIdentity (Complete-UiNativeIdentityUpdate -Record $identityAck) '匹配当前 run 的 Native ACK 应结束 identity inflight'
    Assert-UiIdentity ($null -eq $script:identityNativeInFlight) '确认后不得遗留 Native identity inflight'
    Assert-UiIdentity (([IO.File]::ReadAllText($fixture.request_file,[Text.Encoding]::ASCII) -match 'id=7654321') -and
        (Wait-LocalFixtureExit -Process $fixture.process -TimeoutMs 3000)) '本机 fixture 应只收到单 ID 查询并自行退出。'
    $successDiagnostic = if ([IO.File]::Exists($script:identityDiagnosticPath)) { [IO.File]::ReadAllText($script:identityDiagnosticPath) } else { '' }
    Assert-UiIdentity (-not [IO.File]::Exists($script:identityDiagnosticPath)) `
        ("成功查询不得生成错误日志。 diagnostic=[$successDiagnostic]")
    $script:mainWindow.Close()

    # A fresh positive cache is sent only after HELLO has confirmed the identity command.
    $seedDirectory = Join-Path $testDirectory 'native-cache-seed'
    [void][IO.Directory]::CreateDirectory($seedDirectory)
    $seedCachePath = Join-Path $seedDirectory 'identity-cache.json'
    $seedTime = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $seedCache = [pscustomobject][ordered]@{
        schema_version=1
        entries=@(
            [pscustomobject][ordered]@{ id=7001001; callsign='n0seed'; fetched_at_utc=$seedTime; status='found' },
            [pscustomobject][ordered]@{ id=7001002; callsign='NO CALL'; fetched_at_utc=$seedTime; status='found' },
            [pscustomobject][ordered]@{ id=7001003; callsign='N3MISS'; fetched_at_utc=$seedTime; status='not_found' },
            [pscustomobject][ordered]@{ id=7001004; callsign='n4valid'; fetched_at_utc=$seedTime; status='found' }
        )
    }
    [IO.File]::WriteAllText($seedCachePath,(ConvertTo-Json -InputObject $seedCache -Depth 5),[Text.UTF8Encoding]::new($true))
    Initialize-TestState -TestDirectory $seedDirectory -ApiBaseUri 'http://127.0.0.1:1/api/dmr/user/'
    $script:identityCachePath = $seedCachePath
    $script:controlRunId = 'seed-run'
    $script:controlConfirmed = $true
    $script:supervisor = New-TestIdentitySupervisor
    Assert-UiIdentity (-not (Initialize-UiNativeIdentitySync) -and $script:identityNativeSent.Count -eq 0) `
        '未从 Native capability 声明身份命令前不得发送缓存映射'
    $script:identityNativeCapability = $true
    Assert-UiIdentity (Initialize-UiNativeIdentitySync) '已确认 identity capability 后应装载启动缓存'
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 1 -and $script:identityNativeQueue.Count -eq 1 -and
        $script:identityNativeSent[0].request_id -ceq 'radioid-1') `
        '启动只发送 fresh 正向 legal callsign cache entry 并使用本run revision'
    $seedParameters = ConvertFrom-Json -InputObject $script:identityNativeSent[0].parameters_json -ErrorAction Stop
    Assert-UiIdentity ($seedParameters.source_id -eq 7001001 -and $seedParameters.callsign -ceq 'N0SEED') `
        '启动预置使用规范化呼号，不把无效或 not_found cache entry 发给 Native'
    Assert-UiIdentity (-not (Start-NextUiNativeIdentityUpdate) -and $script:identityNativeSent.Count -eq 1) `
        '身份 sender 同时最多有一条 in-flight 请求'
    $wrongRunAck = [pscustomobject][ordered]@{
        run_id='old-seed-run'; request_id='radioid-1'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    Assert-UiIdentity (-not (Complete-UiNativeIdentityUpdate -Record $wrongRunAck) -and $script:identityNativeInFlight) `
        '旧run的身份ACK不得清除当前in-flight请求'
    $seedAck = [pscustomobject][ordered]@{
        run_id='seed-run'; request_id='radioid-1'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    Assert-UiIdentity (Complete-UiNativeIdentityUpdate -Record $seedAck) '当前run的启动缓存 ACK 应完成请求'
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 2 -and
        $script:identityNativeSent[1].request_id -ceq 'radioid-2') `
        '上一条ACK后才发送下一条缓存映射，并按发送顺序分配全局revision'
    $secondSeedParameters = ConvertFrom-Json -InputObject $script:identityNativeSent[1].parameters_json -ErrorAction Stop
    Assert-UiIdentity ($secondSeedParameters.source_id -eq 7001004 -and $secondSeedParameters.callsign -ceq 'N4VALID') `
        '队列保留其它合法 cache ID 并继续发送'
    $rejectedSeedAck = [pscustomobject][ordered]@{
        run_id='seed-run'; request_id='radioid-2'; command='radio_identity.cache_upsert'
        result='rejected'; replayed=$false; error='stale_identity_revision'
    }
    $rejectedAckHandled = Complete-UiNativeIdentityUpdate -Record $rejectedSeedAck
    Assert-UiIdentity $rejectedAckHandled `
        '拒绝的 identity ACK 应终止当前 Native 同步批次'
    Assert-UiIdentity (-not $script:identityNativeCapability -and $script:identityNativeQueue.Count -eq 0 -and
        $script:identityNativeDeferredBySource.ContainsKey('7001004')) `
        '拒绝时将未确认映射留给后续 run，避免继续提交未知 revision'
    $script:mainWindow.Close()

    foreach ($scenario in @(
        [pscustomobject]@{ mode='not_found'; expected='not_found'; run_id='remove-not-found-run' },
        [pscustomobject]@{ mode='invalid_callsign'; expected='found'; run_id='remove-invalid-run' }
    )) {
        $scenarioDirectory = Join-Path $testDirectory ([string]$scenario.mode)
        [void][IO.Directory]::CreateDirectory($scenarioDirectory)
        $fixture = Start-LocalIdentityFixture -Mode $scenario.mode -Directory $scenarioDirectory
        $activeFixtures.Add($fixture.process)
        Initialize-TestState -TestDirectory $scenarioDirectory `
            -ApiBaseUri ('http://127.0.0.1:{0}/api/dmr/user/' -f $fixture.port)
        Set-TestLatestStatus -RadioId 7654321 -RunId $scenario.run_id -Generation 11
        Seed-TestNativeIdentityMap -RadioId 7654321 -RunId $scenario.run_id
        Add-UiCallHistoryRecord -Record (Get-TestCallRecord -RadioId 7654321 -RunId $scenario.run_id -Generation 11)
        $scenarioQuery = $script:identityQuery
        Assert-UiIdentity ($null -ne $scenarioQuery) ("$($scenario.mode) fixture 应启动单 ID 查询")
        Assert-UiIdentity (Invoke-TestDispatcherUntil -Condition { $null -eq $script:identityQuery } -TimeoutMs 8000) `
            ("$($scenario.mode) 查询应在有限时间内完成")
        Assert-UiIdentity ([string]$scenarioQuery.identity_result.status -ceq [string]$scenario.expected) `
            ("$($scenario.mode) fixture 应得到预期权威状态")
        Assert-UiIdentity ($scenarioQuery.disposed -and [string]$scenarioQuery.owned_runspace.RunspaceStateInfo.State -ceq 'Closed') `
            ("$($scenario.mode) 查询应释放专属 runspace")
        Assert-UiIdentity ($script:identityNativeSent.Count -eq 1 -and
            $script:identityNativeSent[0].command -ceq 'radio_identity.cache_upsert' -and
            $script:identityNativeSent[0].request_id -ceq 'radioid-2') `
            ("$($scenario.mode) 权威结果应发送更高 revision 的删除")
        $removeParameters = ConvertFrom-Json -InputObject $script:identityNativeSent[0].parameters_json -ErrorAction Stop
        $removeNames = @($removeParameters.PSObject.Properties | ForEach-Object { [string]$_.Name })
        Assert-UiIdentity ($removeParameters.source_id -eq 7654321 -and $removeParameters.revision -eq 2 -and
            $null -eq $removeParameters.callsign -and $removeNames.Count -eq 3) `
            ("$($scenario.mode) 删除 payload 应只含 source_id、revision 和 null callsign")
        Assert-UiIdentity (Wait-LocalFixtureExit -Process $fixture.process -TimeoutMs 3000) `
            ("$($scenario.mode) fixture 进程应自行退出")
        $script:mainWindow.Close()
    }

    # Fresh local cache hits warm Native once per incoming call generation.
    $localCacheDirectory = Join-Path $testDirectory 'local-cache-hit'
    [void][IO.Directory]::CreateDirectory($localCacheDirectory)
    Initialize-TestState -TestDirectory $localCacheDirectory -ApiBaseUri 'http://127.0.0.1:1/api/dmr/user/'
    $cacheFetchedAt = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $cacheDocument = [pscustomobject][ordered]@{
        schema_version=1
        entries=@([pscustomobject][ordered]@{
            id=7654321; callsign='N0CACHE'; fetched_at_utc=$cacheFetchedAt; status='found'; source='radioid-api'
        })
    }
    [IO.File]::WriteAllText($script:identityCachePath,(ConvertTo-Json -InputObject $cacheDocument -Depth 5),[Text.UTF8Encoding]::new($true))
    Set-TestLatestStatus -RadioId 7654321 -RunId 'cache-hit-run' -Generation 12
    $script:controlRunId = 'cache-hit-run'; $script:controlConfirmed = $true
    $script:identityNativeCapability = $true; $script:identityNativeRunId = 'cache-hit-run'
    $script:supervisor = New-TestIdentitySupervisor
    $cacheCall = Get-TestCallRecord -RadioId 7654321 -RunId 'cache-hit-run' -Generation 12
    Add-UiCallHistoryRecord -Record $cacheCall
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 1 -and
        $script:identityNativeSent[0].request_id -ceq 'radioid-1') `
        '新来话的 fresh cache hit 应按 call generation 重新预置 Native 呼号映射'
    $cacheHitParameters = ConvertFrom-Json -InputObject $script:identityNativeSent[0].parameters_json -ErrorAction Stop
    Assert-UiIdentity ($cacheHitParameters.source_id -eq 7654321 -and $cacheHitParameters.callsign -ceq 'N0CACHE') `
        '来话 cache-hit 预置应传入规范化呼号'
    $cacheHitAck = [pscustomobject][ordered]@{
        run_id='cache-hit-run'; request_id='radioid-1'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    Assert-UiIdentity (Complete-UiNativeIdentityUpdate -Record $cacheHitAck) 'cache-hit 预置应接受匹配 ACK'
    Add-UiCallHistoryRecord -Record $cacheCall
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 1) '同一 generation 的重复状态不得重复预置身份映射'
    Add-UiCallHistoryRecord -Record (Get-TestCallRecord -RadioId 7654321 -RunId 'cache-hit-run' -Generation 13)
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 2 -and
        $script:identityNativeSent[1].request_id -ceq 'radioid-2') '相同 ID 的下一通话 generation 应允许再次更新 Native LRU'
    $script:mainWindow.Close()

    # Queue and deferred metadata remain bounded independently of routing request replay.
    $capacityDirectory = Join-Path $testDirectory 'identity-capacity'
    [void][IO.Directory]::CreateDirectory($capacityDirectory)
    Initialize-TestState -TestDirectory $capacityDirectory -ApiBaseUri 'http://127.0.0.1:1/api/dmr/user/'
    for ($id = 1; $id -le 130; $id++) {
        [void](Save-UiNativeIdentityDeferredMapping -Mapping ([pscustomobject][ordered]@{
            source_id=[uint64]$id; callsign=('N{0}' -f $id)
        }))
    }
    Assert-UiIdentity ($script:identityNativeDeferredBySource.Count -eq 128 -and
        -not $script:identityNativeDeferredBySource.ContainsKey('1') -and
        $script:identityNativeDeferredBySource.ContainsKey('130')) '跨 run deferred 映射超出128项时应淘汰最旧项'
    $script:controlRunId = 'capacity-run'; $script:controlConfirmed = $true
    $script:identityNativeCapability = $true; $script:identityNativeRunId = 'capacity-run'
    $script:supervisor = New-TestIdentitySupervisor
    $script:identityNativeInFlight = [pscustomobject]@{ request_id='radioid-blocker'; run_id='capacity-run' }
    for ($id = 1; $id -le 128; $id++) {
        $script:identityNativeQueue.Add([pscustomobject][ordered]@{ source_id=[uint64]$id; callsign=('N{0}' -f $id) })
    }
    [void](Add-UiNativeIdentityMappingToQueue -SourceId 129 -Callsign 'N129')
    Assert-UiIdentity ($script:identityNativeQueue.Count -eq 128 -and
        [uint64]$script:identityNativeQueue[0].source_id -eq 2 -and
        [uint64]$script:identityNativeQueue[127].source_id -eq 129) '等待 Native ACK 时 queue 超出128项应淘汰最旧的待同步映射'
    [void](Add-UiNativeIdentityMappingToQueue -SourceId 2 -Callsign 'N2NEW')
    Assert-UiIdentity ($script:identityNativeQueue.Count -eq 128 -and
        [uint64]$script:identityNativeQueue[0].source_id -eq 2 -and
        $script:identityNativeQueue[0].callsign -ceq 'N2NEW') '队列中同一 Source ID 应合并到最新呼号'
    [void](Add-UiNativeIdentityMappingToQueue -SourceId 1 -Callsign 'N1NEW')
    Assert-UiIdentity ($script:identityNativeQueue.Count -eq 128 -and
        [uint64]$script:identityNativeQueue[0].source_id -eq 3 -and
        [uint64]$script:identityNativeQueue[127].source_id -eq 1) '被淘汰的当前来源可在后续新通话时重新入队'
    $script:mainWindow.Close()

    # A missing ACK stops only metadata sync, saves a bounded retry set, and frees the in-flight slot.
    $timeoutAckDirectory = Join-Path $testDirectory 'identity-ack-timeout'
    [void][IO.Directory]::CreateDirectory($timeoutAckDirectory)
    Initialize-TestState -TestDirectory $timeoutAckDirectory -ApiBaseUri 'http://127.0.0.1:1/api/dmr/user/'
    $script:identityNativeCapability = $true
    $script:identityNativeRunId = 'ack-timeout-run'
    $script:controlRunId = 'ack-timeout-run'
    $script:identityNativeInFlight = [pscustomobject][ordered]@{
        request_id='radioid-4'; run_id='ack-timeout-run'; source_id=[uint64]7654321
        callsign='N0WAIT'; sent_utc=[DateTime]::UtcNow.AddSeconds(-6)
    }
    $script:identityNativeQueue.Add([pscustomobject][ordered]@{ source_id=[uint64]7654322; callsign=$null })
    $script:pendingControlRequests['radioid-4'] = 'radio_identity.cache_upsert'
    Assert-UiIdentity (Expire-UiNativeIdentityUpdate) 'Native metadata 缺少 ACK 达5秒时应终止本 run 身份同步'
    Assert-UiIdentity (-not $script:identityNativeCapability -and $null -eq $script:identityNativeInFlight -and
        $script:identityNativeQueue.Count -eq 0 -and -not $script:pendingControlRequests.ContainsKey('radioid-4')) `
        'ACK timeout 应清理单 in-flight 请求和队列，不影响其它请求预算'
    Assert-UiIdentity ($script:identityNativeDeferredBySource.Count -eq 2 -and
        $script:identityNativeDeferredBySource.ContainsKey('7654321') -and
        $null -eq $script:identityNativeDeferredBySource['7654322'].callsign) `
        'ACK timeout 应有界保留待更新的 positive 和 tombstone 映射'
    $lateAck = [pscustomobject][ordered]@{
        run_id='ack-timeout-run'; request_id='radioid-4'; command='radio_identity.cache_upsert'; result='ok'; replayed=$false
    }
    $lateAckKey = [string]$lateAck.run_id + '|' + [string]$lateAck.request_id
    Assert-UiIdentity ($script:expiredIdentityNativeRequests.ContainsKey($lateAckKey)) `
        '迟到 ACK 应标记为过期并由控制事件处理器忽略'
    $script:mainWindow.Close()

    # An automatic timeout keeps the original DMR ID and does not surface a failure banner.
    $timeoutDirectory = Join-Path $testDirectory 'timeout'
    [void][IO.Directory]::CreateDirectory($timeoutDirectory)
    $fixture = Start-LocalIdentityFixture -Mode delay_headers_timeout -Directory $timeoutDirectory
    $activeFixtures.Add($fixture.process)
    Initialize-TestState -TestDirectory $timeoutDirectory `
        -ApiBaseUri ('http://127.0.0.1:{0}/api/dmr/user/' -f $fixture.port)
    Set-TestLatestStatus -RadioId 7654322 -RunId 'timeout-run' -Generation 8
    Seed-TestNativeIdentityMap -RadioId 7654322 -RunId 'timeout-run'
    Add-TestIdentityClickHandler
    Set-MainText -Name 'CurrentCallValue' -Text 'DMR ID 7654322'
    Add-UiCallHistoryRecord -Record (Get-TestCallRecord -RadioId 7654322 -RunId 'timeout-run' -Generation 8)
    $timeoutOwned = $script:identityQuery
    Assert-UiIdentity ((Invoke-TestDispatcherUntil -Condition { $null -eq $script:identityQuery } -TimeoutMs 10000)) `
        '5 秒 HTTP 超时应释放后台查询，不阻塞 UI dispatcher。'
    Assert-UiIdentity ($timeoutOwned.disposed -and [string]$timeoutOwned.owned_runspace.RunspaceStateInfo.State -ceq 'Closed') `
        '超时结果必须释放独占 runspace。'
    Assert-UiIdentity ((Get-UiControl 'CurrentCallValue').Text -ceq 'DMR ID 7654322' -and
        [string](Get-UiControl 'CallHistoryList').Items[0].source_label -ceq 'DMR ID 7654322') `
        '自动查询超时时当前来话与历史必须继续显示原始 DMR ID。'
    Assert-UiIdentity ((Get-UiControl 'IdentityLookupStatusValue').Visibility -eq [System.Windows.Visibility]::Collapsed) `
        '自动查询超时不得打扰 UI 或显示查询失败状态。'
    Assert-UiIdentity ($script:identityFailureCooldown.ContainsKey('7654322')) '超时 ID 应进入有界失败冷却。'
    Assert-UiIdentity ($script:identityNativeSent.Count -eq 0) 'HTTP timeout 不得发送 callsign:null 或删除既有 Native 呼号映射。'
    Assert-UiIdentity (Wait-LocalFixtureExit -Process $fixture.process -TimeoutMs 9000) '超时 fixture 进程应自行退出。'
    $script:mainWindow.Close()

    # Stop-and-exit during a delayed request must cancel, close resources, and close the WPF window.
    $closeDirectory = Join-Path $testDirectory 'close'
    [void][IO.Directory]::CreateDirectory($closeDirectory)
    $fixture = Start-LocalIdentityFixture -Mode delay_headers_timeout -Directory $closeDirectory
    $activeFixtures.Add($fixture.process)
    Initialize-TestState -TestDirectory $closeDirectory `
        -ApiBaseUri ('http://127.0.0.1:{0}/api/dmr/user/' -f $fixture.port)
    Set-TestLatestStatus -RadioId 7654323 -RunId 'close-run' -Generation 9
    Set-MainText -Name 'CurrentCallValue' -Text 'DMR ID 7654323'
    Add-UiCallHistoryRecord -Record (Get-TestCallRecord -RadioId 7654323 -RunId 'close-run' -Generation 9)
    $closeOwned = $script:identityQuery
    $script:identityNativeCapability = $true
    $script:identityNativeRunId = 'close-run'
    $script:identityNativeInFlight = [pscustomobject][ordered]@{
        request_id='radioid-close'; run_id='close-run'; source_id=[uint64]7654323
        callsign='N0WAIT'; sent_utc=[DateTime]::UtcNow
    }
    $script:supervisor = $null
    $script:mainWindow.Add_Closing({
        param($sender,$eventArgs)
        if ($script:allowWindowClose -and -not $script:identityQuery) { return }
        if ($script:identityQuery) {
            $eventArgs.Cancel = $true
            $script:closingAfterIdentityQuery = $true
            if (-not $script:identityQuery.stop_async) { Stop-UiIdentityQuery -Query $script:identityQuery -Reason 'window_closed' }
        }
    })
    Request-StopAndExit
    Assert-UiIdentity ($closeOwned.stop_async -and -not $script:windowClosed) '关闭窗口时应先取消查询并保留 dispatcher 收尾机会。'
    Assert-UiIdentity (Invoke-TestDispatcherUntil -Condition { $script:windowClosed } -TimeoutMs 5000) `
        '停止并退出应取消查询和释放资源，不等待 Native 元数据 ACK。'
    Assert-UiIdentity ($closeOwned.disposed -and [string]$closeOwned.owned_runspace.RunspaceStateInfo.State -ceq 'Closed') `
        '关闭路径必须关闭并释放独占 runspace。'
    Assert-UiIdentity (Wait-LocalFixtureExit -Process $fixture.process -TimeoutMs 9000) `
        '关闭路径不得留下本机 HTTP fixture 子进程。'

    # Force a dispatcher completion exception and verify that the timer callback entry point isolates it.
    $exceptionDirectory = Join-Path $testDirectory 'dispatcher-exception'
    [void][IO.Directory]::CreateDirectory($exceptionDirectory)
    Initialize-TestState -TestDirectory $exceptionDirectory -ApiBaseUri 'http://127.0.0.1:1/api/dmr/user/'
    $originalComplete = Get-Item Function:\Complete-UiIdentityQuery
    function Complete-UiIdentityQuery { throw 'dispatcher exception fixture' }
    Assert-UiIdentity (Invoke-TestDispatcherUntil -Condition { [IO.File]::Exists($script:identityDiagnosticPath) } -TimeoutMs 1500) `
        'On-UiTimerTick 应隔离 Complete 异常並记录本机诊断。'
    Set-Item Function:\Complete-UiIdentityQuery $originalComplete
    Assert-UiIdentity ($null -eq $script:dispatcherUnhandled) 'Dispatcher 上不应泄漏 Complete 异常。'
    $diagnostic = [IO.File]::ReadAllText($script:identityDiagnosticPath,[Text.Encoding]::UTF8)
    Assert-UiIdentity ($diagnostic.Contains('dispatcher') -and $diagnostic.Contains('query_contract')) `
        'dispatcher 诊断应记录固定阶段和错误代码。'
    $script:mainWindow.Close()

    Write-Output '通过：真实 WPF Button 和 Dispatcher 回调、异步来话查询、RadioID 呼号到 Native revision/ACK 队列、缓存预置能力门控、超时保留 ID、关闭收尾和异常隔离。'
} finally {
    foreach ($process in $activeFixtures) {
        try {
            if (-not $process.HasExited) { [void]$process.WaitForExit(2000) }
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        } catch { }
    }
    if ($script:mainWindow -and $script:mainWindow.IsVisible) {
        try { $script:allowWindowClose = $true; $script:identityQuery = $null; $script:mainWindow.Close() } catch { }
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $targetPath = [IO.Path]::GetFullPath($testDirectory)
    if ($targetPath.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($targetPath)) {
        [IO.Directory]::Delete($targetPath,$true)
    }
}
