[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-UiIdentity {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "UI 身份测试失败：$Message" }
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
    'Get-UiRadioIdentity','Format-UiRadioIdentity','Format-UiRadioIdentityDetails',
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
    $script:closingAfterStop = $false
    $script:closingAfterIdentityQuery = $false
    $script:allowWindowClose = $false
    $script:windowClosed = $false
    $script:dispatcherUnhandled = $null
    $script:mainWindow.Add_Closed({ $script:windowClosed = $true })
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
    param([Parameter(Mandatory=$true)][ValidateSet('ok','delay_headers_timeout')][string]$Mode,
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
        ("成功查询应更新匹配的当前来话和历史呼号。 current=[$currentLabel], history=[$historyLabel], identity_status=[$($queryOwned.identity_result.status)], error=[$($queryOwned.error_code)]")
    Assert-UiIdentity (([IO.File]::ReadAllText($fixture.request_file,[Text.Encoding]::ASCII) -match 'id=7654321') -and
        (Wait-LocalFixtureExit -Process $fixture.process -TimeoutMs 3000)) '本机 fixture 应只收到单 ID 查询并自行退出。'
    $successDiagnostic = if ([IO.File]::Exists($script:identityDiagnosticPath)) { [IO.File]::ReadAllText($script:identityDiagnosticPath) } else { '' }
    Assert-UiIdentity (-not [IO.File]::Exists($script:identityDiagnosticPath)) `
        ("成功查询不得生成错误日志。 diagnostic=[$successDiagnostic]")
    $script:mainWindow.Close()

    # An automatic timeout keeps the original DMR ID and does not surface a failure banner.
    $timeoutDirectory = Join-Path $testDirectory 'timeout'
    [void][IO.Directory]::CreateDirectory($timeoutDirectory)
    $fixture = Start-LocalIdentityFixture -Mode delay_headers_timeout -Directory $timeoutDirectory
    $activeFixtures.Add($fixture.process)
    Initialize-TestState -TestDirectory $timeoutDirectory `
        -ApiBaseUri ('http://127.0.0.1:{0}/api/dmr/user/' -f $fixture.port)
    Set-TestLatestStatus -RadioId 7654322 -RunId 'timeout-run' -Generation 8
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
        '停止并退出应在取消和资源释放后关闭窗口。'
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

    Write-Output '通过：真实 WPF Button 和 Dispatcher 回调、来话自动查询、ID 合并、单条本机 HTTP 查询、超时保留 ID、查询关闭收尾和异常隔离。'
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
