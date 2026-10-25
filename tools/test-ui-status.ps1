[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiStatus {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Assert-UiStatus ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$wantedFunctions = @('Test-UiStatusRecord', 'Test-UiStatusFreshness', 'Test-UiRunRecordAcceptance', 'Get-VisibleUiEventText', 'Apply-StatusRecord')
$found = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantedFunctions -ccontains $node.Name }, $true))
Assert-UiStatus ($found.Count -eq $wantedFunctions.Count) '没有找到状态记录验证函数。'
foreach ($functionAst in $found) { Invoke-Expression $functionAst.Extent.Text }

$valid = [pscustomobject][ordered]@{
    run_id = '4120-78123'
    seq = [int64]1
    timestamp_utc_ms = [int64]1793000000000
    elapsed_ms = [int64]0
    event = 'started'
    bm_state = 'idle'
    bm_failure = 'none'
    radio_state = 'unknown'
    hri_phase = 'not_started'
    audio_endpoints_validated = $false
    hri_serial_open = $false
    hri_ready = $false
    hri_y_zero_ready = $false
    wavein_state = 'closed'
    waveout_state = 'closed'
    last_rx_header_valid = $false
    last_rx_source_id = [int64]0
    last_rx_destination_id = [int64]0
    last_rx_slot = [int64]1
    last_rx_call_kind = 'G'
}
Assert-UiStatus (Test-UiStatusRecord $valid) '有效的 native 状态对象被拒绝。'

foreach ($field in @('audio_endpoints_validated', 'hri_serial_open', 'hri_ready', 'hri_y_zero_ready', 'last_rx_header_valid')) {
    $copy = $valid.PSObject.Copy()
    $copy.$field = 'false'
    Assert-UiStatus (-not (Test-UiStatusRecord $copy)) ("字符串 false 不应被当作布尔值：$field")
}
$copy = $valid.PSObject.Copy(); $copy.bm_state = 'connected'
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '未知 BM 状态枚举未被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.waveout_state = 'ready'
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '未知 WaveOut 状态枚举未被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.seq = [double]1.5
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '小数状态序号未被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.timestamp_utc_ms = '1793000000000'
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '字符串时间戳未被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.last_rx_destination_id = [int64]16777216
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '越界 DMR 目标 ID 未被拒绝。'

$now = [int64]1793000000000
Assert-UiStatus (Test-UiStatusFreshness -TimestampUtcMs ([uint64]$now) -NowUtcMs $now) '当前状态应被接受。'
Assert-UiStatus (Test-UiStatusFreshness -TimestampUtcMs ([uint64]($now - 3000)) -NowUtcMs $now) '3 秒边界状态应被接受。'
Assert-UiStatus (-not (Test-UiStatusFreshness -TimestampUtcMs ([uint64]($now - 3001)) -NowUtcMs $now)) '过期状态不应恢复 ready 显示。'
Assert-UiStatus (Test-UiStatusFreshness -TimestampUtcMs ([uint64]($now + 5000)) -NowUtcMs $now) '5 秒未来时钟偏差边界应被接受。'
Assert-UiStatus (-not (Test-UiStatusFreshness -TimestampUtcMs ([uint64]($now + 5001)) -NowUtcMs $now)) '显著未来时间戳应被拒绝。'
Assert-UiStatus (-not (Test-UiStatusFreshness -TimestampUtcMs ([uint64]253402300800000) -NowUtcMs $now)) '超出 DateTime 可表示范围的时间戳应被拒绝。'
Assert-UiStatus (Test-UiRunRecordAcceptance -Record $valid -ExpectedProcessId 4120 -NowUtcMs $now) '当前 PID 的首条有效运行记录应被接受。'
Assert-UiStatus (-not (Test-UiRunRecordAcceptance -Record $valid -ExpectedProcessId 4120 -LockedRunId '4120-99999' -NowUtcMs $now)) '同 PID 的另一个 run_id 应被拒绝。'
Assert-UiStatus (-not (Test-UiRunRecordAcceptance -Record $valid -ExpectedProcessId 4120 -LastSequence 1 -NowUtcMs $now)) '重复序号应被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.timestamp_utc_ms = [int64]($now - 3001)
Assert-UiStatus (-not (Test-UiRunRecordAcceptance -Record $copy -ExpectedProcessId 4120 -NowUtcMs $now)) '过期的排队状态不能恢复旧 ready 状态。'
$copy = $valid.PSObject.Copy(); $copy.hri_ready = 'false'
Assert-UiStatus (-not (Test-UiRunRecordAcceptance -Record $copy -ExpectedProcessId 4120 -NowUtcMs $now)) '类型错误的状态整条应被忽略。'

function Set-MainText {
    param([string]$Name, [string]$Text)
    $script:mockUiFields[$Name] = $Text
}
function Add-UiEvent {
    param([string]$Text)
    $script:mockUiEvents.Add($Text)
}

$script:mockUiFields = @{}
$script:mockUiEvents = New-Object 'System.Collections.Generic.List[string]'
$script:supervisor = [pscustomobject]@{ ProcessId = [uint32]4120; HasExited = $false }
$script:currentRunId = ''
$script:lastSequence = [uint64]0
$script:lastStatusUtc = [DateTime]::MinValue
$script:latestStatus = $null
$script:activeTargetLabel = 'TG 91 · TS2'
$script:lastUiBmState = ''
$script:lastUiHriState = ''
$valid.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Apply-StatusRecord -Record $valid
Assert-UiStatus ($script:currentRunId -ceq '4120-78123' -and $script:lastSequence -eq 1) '首条有效运行记录未锁定 run_id 与序号。'
$acceptedBmText = $script:mockUiFields['BmValue']

$copy = $valid.PSObject.Copy(); $copy.run_id = '4120-99999'; $copy.seq = [int64]2; $copy.bm_state = 'ready'
Apply-StatusRecord -Record $copy
Assert-UiStatus ($script:lastSequence -eq 1 -and $script:mockUiFields['BmValue'] -ceq $acceptedBmText) '同 PID 的另一个 run_id 改写了运行状态。'

$copy = $valid.PSObject.Copy(); $copy.seq = [int64]2; $copy.timestamp_utc_ms = [DateTimeOffset]::UtcNow.AddSeconds(-4).ToUnixTimeMilliseconds(); $copy.bm_state = 'ready'
Apply-StatusRecord -Record $copy
Assert-UiStatus ($script:lastSequence -eq 1 -and $script:mockUiFields['BmValue'] -ceq $acceptedBmText) '排队过期的 ready 记录改写了运行状态。'

$copy = $valid.PSObject.Copy(); $copy.seq = [int64]2; $copy.hri_ready = 'false'; $copy.bm_state = 'ready'
Apply-StatusRecord -Record $copy
Assert-UiStatus ($script:lastSequence -eq 1 -and $script:mockUiFields['BmValue'] -ceq $acceptedBmText) '字段类型错误的状态记录改写了运行状态。'

$copy = $valid.PSObject.Copy(); $copy.bm_state = 'ready'; $copy.event = 'runtime_snapshot'; $copy.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $copy.seq = [int64]2
Apply-StatusRecord -Record $copy
Assert-UiStatus ($script:lastSequence -eq 2 -and $script:mockUiFields['BmValue'] -ceq '已连接') '当前 run_id 的新状态没有更新界面字段。'

Write-Output '通过：PS5.1 状态记录严格类型、枚举与时间新鲜度检查。'
