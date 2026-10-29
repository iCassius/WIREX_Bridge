[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
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
$wantedFunctions = @('Test-UiSourceIdentityRecord', 'Get-UiSourceIdentityDisplay', 'Get-UiCompletedRunRecord',
    'Get-UiNativeIdentityCallsign', 'Save-UiNativeIdentityDeferredMapping', 'Test-AndMarkUiNativeIdentityCallRefresh',
    'Get-UiRunDirectorySize', 'Invoke-UiRunLogRetention', 'Test-UiStatusRecord', 'Test-UiStatusFreshness',
    'Test-UiRunRecordAcceptance', 'Get-VisibleUiEventText', 'Apply-StatusRecord', 'Set-StaleDisplay',
    'Reset-UiControlState',
    'Format-ProfileTarget', 'Format-ProfileReceiveTarget', 'Format-ProfileTransmitPermission', 'Set-MainTargetSummary', 'On-UiTimerTick')
$found = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantedFunctions -ccontains $node.Name }, $true))
Assert-UiStatus ($found.Count -eq $wantedFunctions.Count) '没有找到状态记录验证函数。'
foreach ($functionAst in $found) { Invoke-Expression $functionAst.Extent.Text }
Import-Module -Name (Join-Path (Join-Path $repoRoot 'ui\windows') 'RadioIdentity.psm1') -Force
$script:radioIdentityModuleLoaded = $true

function Update-UiPlaybackGainDisplay {
    param([object]$Record=$null)
}
function Update-UiReceiveMetricsDisplay {
    param([object]$Record=$null)
}
function Add-UiCallHistoryRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
}
function Update-UiIdentityActionState { }
function Set-UiIdentityRowVisibility {
    param([string]$Row,[object]$Visibility=$null)
    if (-not $script:mockIdentityRows) { $script:mockIdentityRows = @{} }
    $script:mockIdentityRows[$Row] = if ($null -eq $Visibility) { 'Visible' } else { [string]$Visibility }
}
function Update-DynamicGroupControls { }
function Update-UiRadioCatControls { }
function Complete-UiIdentityQuery { }
function Format-UiRadioIdentity {
    param([Parameter(Mandatory=$true)][uint64]$RadioId)
    return ('DMR ID ' + $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture))
}
function Format-UiRadioIdentityDetails {
    param([Parameter(Mandatory=$true)][uint64]$RadioId,[AllowNull()][object]$Identity=$null)
    return ('DMR ID ' + $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture))
}

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
    current_call_valid = $false
    current_call_phase = 'none'
    current_call_source_id = [int64]0
    current_call_destination_id = [int64]0
    current_call_slot = [int64]0
    current_call_kind = 'none'
    current_call_color_code = [int64]0
    current_call_link_control_validated = $false
    current_call_color_code_known = $false
    current_call_generation = [int64]0
    receive_media_state = 'idle'
    lcd_source_identity = [pscustomobject][ordered]@{
        prepared = $false
        source_id = [int64]0
        receive_generation = [int64]0
        label = ''
        display = 'unknown'
        label_kind = 'none'
        cache_revision = [uint64]0
        serial_write_state = 'not_sent'
    }
}
Assert-UiStatus (Test-UiStatusRecord $valid) '有效的 native 状态对象被拒绝。'

$legacyIdentity = [pscustomobject][ordered]@{
    prepared = $false
    source_id = [int64]0
    receive_generation = [int64]0
    label = ''
    display = 'unknown'
}
$legacyStatus = $valid.PSObject.Copy(); $legacyStatus.lcd_source_identity = $legacyIdentity
Assert-UiStatus (Test-UiStatusRecord $legacyStatus) '旧五字段 HRI 来源标签状态应继续接受。'

$callSignStatus = $valid.PSObject.Copy(); $callSignStatus.lcd_source_identity = [pscustomobject][ordered]@{
    prepared = $true; source_id = [int64]1234; receive_generation = [uint64]7
    label = 'N0TEST    '; display = 'unknown'; label_kind = 'callsign'
    cache_revision = [uint64]3; serial_write_state = 'pending'
}
$callSignStatus.current_call_valid = $true; $callSignStatus.current_call_phase = 'playing'
$callSignStatus.current_call_source_id = [int64]1234; $callSignStatus.current_call_generation = [uint64]7
$callSignStatus.current_call_destination_id = [int64]91; $callSignStatus.current_call_slot = [int64]2
$callSignStatus.current_call_kind = 'G'; $callSignStatus.receive_media_state = 'playing'
Assert-UiStatus (Test-UiStatusRecord $callSignStatus) '新八字段状态应接受规范呼号标签和匹配的来源/代次。'

$legacyPrepared = $callSignStatus.PSObject.Copy()
$legacyPrepared.lcd_source_identity = [pscustomobject][ordered]@{
    prepared = $true; source_id = [int64]1234; receive_generation = [uint64]7
    label = 'ID1234    '; display = 'unknown'
}
Assert-UiStatus (Test-UiStatusRecord $legacyPrepared) '旧五字段状态的精确数字 ID 标签应继续接受。'
$legacyCallsign = $legacyPrepared.PSObject.Copy()
$legacyCallsign.lcd_source_identity = $legacyPrepared.lcd_source_identity.PSObject.Copy()
$legacyCallsign.lcd_source_identity.label = 'N0TEST    '
Assert-UiStatus (-not (Test-UiStatusRecord $legacyCallsign)) '旧五字段状态不得把呼号当作旧协议支持的身份标签。'

$fallbackStatus = $callSignStatus.PSObject.Copy()
$fallbackStatus.lcd_source_identity = [pscustomobject][ordered]@{
    prepared = $true; source_id = [int64]1234; receive_generation = [uint64]7
    label = 'ID1234    '; display = 'unknown'; label_kind = 'dmr_id'
    cache_revision = [uint64]0; serial_write_state = 'attempted'
}
Assert-UiStatus (Test-UiStatusRecord $fallbackStatus) '新八字段状态应接受精确 DMR ID fallback 标签。'

$copy = $valid.PSObject.Copy(); $copy.lcd_source_identity = $copy.lcd_source_identity.PSObject.Copy()
$copy.lcd_source_identity.prepared = $true; $copy.lcd_source_identity.source_id = [int64]1234
$copy.lcd_source_identity.receive_generation = [int64]7; $copy.lcd_source_identity.label = 'ID1234    '
$copy.lcd_source_identity.label_kind = 'dmr_id'; $copy.lcd_source_identity.cache_revision = [uint64]0
$copy.lcd_source_identity.serial_write_state = 'pending'
$copy.current_call_valid = $true; $copy.current_call_phase = 'playing'; $copy.receive_media_state = 'playing'
$copy.current_call_source_id = [int64]1234; $copy.current_call_destination_id = [int64]91
$copy.current_call_slot = [int64]2; $copy.current_call_kind = 'G'; $copy.current_call_generation = [int64]7
Assert-UiStatus (Test-UiStatusRecord $copy) '与当前 BM 来话匹配的已准备 HRI 来源标签应接受。'
$identityDisplay = Get-UiSourceIdentityDisplay -Identity $copy.lcd_source_identity
Assert-UiStatus ($identityDisplay.value -ceq 'ID1234 · 已准备' -and $identityDisplay.radio_display -ceq 'FTX-1 屏幕：未知') '已准备标签显示应去掉字段填充空格并明确屏幕结果未知。'
$draining = $copy.PSObject.Copy(); $draining.lcd_source_identity = $copy.lcd_source_identity.PSObject.Copy()
$draining.current_call_valid = $false; $draining.current_call_phase = 'none'; $draining.receive_media_state = 'draining'
$draining.current_call_source_id = [int64]0; $draining.current_call_destination_id = [int64]0
$draining.current_call_slot = [int64]0; $draining.current_call_kind = 'none'; $draining.current_call_generation = [int64]0
Assert-UiStatus (Test-UiStatusRecord $draining) 'BM EOT 后、HRI 播放收尾前应保留已准备来源标签。'
$stopping = $draining.PSObject.Copy(); $stopping.lcd_source_identity = $draining.lcd_source_identity.PSObject.Copy()
$stopping.receive_media_state = 'stopping'
Assert-UiStatus (Test-UiStatusRecord $stopping) 'HRI 停止确认待处理时应接受 stopping，且当前来话仍保持无效。'
foreach ($mutation in @('bad-source', 'bad-generation', 'bad-label', 'bad-display', 'extra-field', 'bad-type',
        'bad-kind', 'bad-revision', 'bad-serial-state', 'wrong-call-source', 'wrong-call-generation', 'bad-callsign')) {
    $invalidIdentity = $callSignStatus.PSObject.Copy()
    $invalidIdentity.lcd_source_identity = $callSignStatus.lcd_source_identity.PSObject.Copy()
    switch ($mutation) {
        'bad-source' { $invalidIdentity.lcd_source_identity.source_id = [int64]16777216 }
        'bad-generation' { $invalidIdentity.lcd_source_identity.receive_generation = [int64]0 }
        'bad-label' { $invalidIdentity.lcd_source_identity.label = 'N0 TEST   ' }
        'bad-display' { $invalidIdentity.lcd_source_identity.display = 'displayed' }
        'extra-field' { $invalidIdentity.lcd_source_identity | Add-Member -NotePropertyName source_name -NotePropertyValue 'untrusted' }
        'bad-type' { $invalidIdentity.lcd_source_identity.prepared = 'true' }
        'bad-kind' { $invalidIdentity.lcd_source_identity.label_kind = 'unknown' }
        'bad-revision' { $invalidIdentity.lcd_source_identity.cache_revision = [int64]0 }
        'bad-serial-state' { $invalidIdentity.lcd_source_identity.serial_write_state = 'written_to_radio' }
        'wrong-call-source' { $invalidIdentity.current_call_source_id = [int64]1235 }
        'wrong-call-generation' { $invalidIdentity.current_call_generation = [int64]8 }
        'bad-callsign' { $invalidIdentity.lcd_source_identity.label = 'n0test    ' }
    }
    Assert-UiStatus (-not (Test-UiStatusRecord $invalidIdentity)) ("无效 HRI 来源标签字段未被拒绝：$mutation")
}
$missingIdentityField = $callSignStatus.PSObject.Copy()
$missingIdentityField.lcd_source_identity = $callSignStatus.lcd_source_identity.PSObject.Copy()
[void]$missingIdentityField.lcd_source_identity.PSObject.Properties.Remove('cache_revision')
Assert-UiStatus (-not (Test-UiStatusRecord $missingIdentityField)) '缺少 cache_revision 的八字段状态应拒绝。'
$unprepared = $valid.PSObject.Copy(); $unprepared.lcd_source_identity = $valid.lcd_source_identity.PSObject.Copy()
$unprepared.lcd_source_identity.source_id = [int64]1
Assert-UiStatus (-not (Test-UiStatusRecord $unprepared)) 'prepared=false 状态携带非零来源 ID 时应拒绝。'

$currentCallNames = @(
    'current_call_valid', 'current_call_phase', 'current_call_source_id', 'current_call_destination_id',
    'current_call_slot', 'current_call_kind', 'current_call_color_code',
    'current_call_link_control_validated', 'current_call_color_code_known', 'current_call_generation',
    'receive_media_state'
)
$legacy = $valid.PSObject.Copy()
foreach ($name in $currentCallNames) { [void]$legacy.PSObject.Properties.Remove($name) }
$legacy.PSObject.Properties.Remove('lcd_source_identity') | Out-Null
Assert-UiStatus (Test-UiStatusRecord $legacy) '缺少整组当前来话字段的旧 native 状态应兼容为无活动信息。'
$partial = $valid.PSObject.Copy(); [void]$partial.PSObject.Properties.Remove('current_call_source_id')
Assert-UiStatus (-not (Test-UiStatusRecord $partial)) '只缺一项当前来话字段的记录应整条拒绝。'

foreach ($field in @('audio_endpoints_validated', 'hri_serial_open', 'hri_ready', 'hri_y_zero_ready', 'last_rx_header_valid')) {
    $copy = $valid.PSObject.Copy()
    $copy.$field = 'false'
    Assert-UiStatus (-not (Test-UiStatusRecord $copy)) ("字符串 false 不应被当作布尔值：$field")
}
$copy = $valid.PSObject.Copy(); $copy.current_call_valid = 'false'
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '字符串 false 不应被当作当前来话布尔值。'
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
$copy = $valid.PSObject.Copy(); $copy.current_call_color_code = [int64]16
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) '越界的当前呼叫 CC 未被拒绝。'
$copy = $valid.PSObject.Copy(); $copy.current_call_valid = $true; $copy.current_call_phase = 'playing'; $copy.receive_media_state = 'playing'
$copy.current_call_source_id = [int64]1234; $copy.current_call_destination_id = [int64]91
$copy.current_call_slot = [int64]2; $copy.current_call_kind = 'G'; $copy.current_call_generation = [int64]1
Assert-UiStatus (Test-UiStatusRecord $copy) 'CC 尚未知但字段清零的活动呼叫应接受。'
$copy.current_call_color_code = [int64]1
Assert-UiStatus (-not (Test-UiStatusRecord $copy)) 'CC 未知时非零颜色码应拒绝。'
$copy.current_call_color_code_known = $true; $copy.current_call_color_code = [int64]1
Assert-UiStatus (Test-UiStatusRecord $copy) '有效活动呼叫字段被拒绝。'
$copy.current_call_valid = $false; $copy.current_call_phase = 'none'; $copy.receive_media_state = 'draining'
$copy.current_call_source_id = [int64]0; $copy.current_call_destination_id = [int64]0
$copy.current_call_slot = [int64]0; $copy.current_call_kind = 'none'; $copy.current_call_generation = [int64]0
$copy.current_call_color_code = [int64]0; $copy.current_call_color_code_known = $false
Assert-UiStatus (Test-UiStatusRecord $copy) 'EOT 后仍有本机回放排空的状态应允许清除活动话者。'

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
function Get-UiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    return $null
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
Assert-UiStatus ([string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallDetail']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') '空闲记录应隐藏空的当前来话栏。'

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

$active = $valid.PSObject.Copy()
$active.seq = [int64]3; $active.event = 'runtime_snapshot'; $active.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$active.current_call_valid = $true; $active.current_call_phase = 'playing'; $active.receive_media_state = 'playing'
$active.current_call_source_id = [int64]1234; $active.current_call_destination_id = [int64]91
$active.current_call_slot = [int64]2; $active.current_call_kind = 'G'; $active.current_call_color_code = [int64]1
$active.current_call_link_control_validated = $true; $active.current_call_color_code_known = $true
$active.current_call_generation = [int64]7
$active.lcd_source_identity = [pscustomobject][ordered]@{
    prepared = $true; source_id = [int64]1234; receive_generation = [int64]7; label = 'ID1234    '; display = 'unknown'
    label_kind = 'dmr_id'; cache_revision = [uint64]0; serial_write_state = 'pending'
}
Apply-StatusRecord -Record $active
Assert-UiStatus ($script:lastSequence -eq 3 -and $script:mockUiFields['CurrentCallValue'] -ceq 'DMR ID 1234') '活动来话没有显示数字 DMR ID。'
Assert-UiStatus ($script:mockUiFields['CurrentCallDetail'] -match 'TG 91.*TS2' -and
    $script:mockUiFields['CurrentCallDetail'] -notmatch 'CC|LC|接收中|缓冲中|未知') '活动来话应只显示组别和时隙等实际通话信息。'
Assert-UiStatus ($script:mockUiFields['HriSourceIdentityValue'] -ceq 'ID1234 · 已准备' -and
    $script:mockUiFields['RadioDisplayValue'] -ceq 'FTX-1 屏幕：未知') '活动来话没有显示已准备的 HRI 来源标签并将屏显保留为未知。'

$ended = $active.PSObject.Copy()
$ended.seq = [int64]4; $ended.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$ended.current_call_valid = $false; $ended.current_call_phase = 'none'; $ended.receive_media_state = 'draining'
$ended.current_call_source_id = [int64]0; $ended.current_call_destination_id = [int64]0
$ended.current_call_slot = [int64]0; $ended.current_call_kind = 'none'; $ended.current_call_color_code = [int64]0
$ended.current_call_link_control_validated = $false; $ended.current_call_color_code_known = $false
$ended.current_call_generation = [int64]0
Apply-StatusRecord -Record $ended
Assert-UiStatus ($script:lastSequence -eq 4 -and [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallDetail']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') 'BM EOT 后应隐藏已结束的活动话者。'
Assert-UiStatus ($script:mockUiFields['HriSourceIdentityValue'] -ceq 'ID1234 · 已准备') 'BM EOT 时过早清除了仍待 HRI T0 收尾的标签。'

$idle = $valid.PSObject.Copy()
$idle.seq = [int64]5; $idle.event = 'runtime_snapshot'; $idle.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Apply-StatusRecord -Record $idle
Assert-UiStatus ($script:lastSequence -eq 5 -and [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') '排空结束后应隐藏空的当前来话栏。'

$legacy.timestamp_utc_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $legacy.seq = [int64]6
Apply-StatusRecord -Record $legacy
Assert-UiStatus ($script:lastSequence -eq 6 -and [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') '旧 native 状态缺少来话字段时应隐藏空的当前来话栏。'
Assert-UiStatus ($script:mockUiFields['HriSourceIdentityValue'] -ceq '当前核心未提供来源标签字段' -and
    $script:mockUiFields['RadioDisplayValue'] -ceq 'FTX-1 屏幕：未知' -and
    $script:mockIdentityRows['recent'] -ceq 'Collapsed') '旧核心的身份状态数据应保留在折叠区，不出现在主界面。'

$script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
$script:mockUiFields['CurrentCallValue'] = 'DMR ID 1234'
Set-StaleDisplay
Assert-UiStatus ([string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') '状态过期时仍显示旧活动 BM 话者。'
Assert-UiStatus ([string]::IsNullOrEmpty([string]$script:mockUiFields['HriSourceIdentityValue']) -and
    [string]::IsNullOrEmpty([string]$script:mockUiFields['RadioDisplayValue']) -and
    $script:mockIdentityRows['recent'] -ceq 'Collapsed') ('过期身份状态应清空可见来话行并隐藏屏显区域：recent={0}, current={1}, display={2}' -f `
        $script:mockIdentityRows['recent'],$script:mockIdentityRows['current'],$script:mockUiFields['RadioDisplayValue'])

function Complete-PreparationStop {}
function Complete-UiDeviceDiscovery {}
function Complete-BridgePreparation {}
function Complete-BridgeStop { return $false }
function Set-ConnectionButtonState {}
$script:mainWindow = $null
$script:identityNativeDeferredBySource = @{}
$script:identityNativeDeferredOrder = New-Object 'System.Collections.Generic.List[string]'
$script:identityNativeQueue = New-Object 'System.Collections.Generic.List[object]'
$script:identityNativeInFlight = [pscustomobject][ordered]@{
    request_id='radioid-6'; source_id=[uint64]901; callsign='N0PENDING'
}
$script:identityNativeQueue.Add([pscustomobject][ordered]@{ source_id=[uint64]902; callsign=$null })
$script:identityNativeCapability = $true
$script:identityNativeRunId = 'old-run'
$script:controlRunId = 'old-run'
Reset-UiControlState
Assert-UiStatus ($script:identityNativeDeferredBySource.Count -eq 2 -and
    $script:identityNativeDeferredBySource.ContainsKey('901') -and
    $null -eq $script:identityNativeDeferredBySource['902'].callsign -and
    $null -eq $script:identityNativeInFlight -and $script:identityNativeQueue.Count -eq 0) `
    '新 run 初始化前应将旧 run 的 in-flight 和 queued 身份同步有界保存，包括 null 删除'
$script:prepareStopAsync = $null
$script:supervisor = [pscustomobject]@{ HasExited = $true }
$script:supervisor | Add-Member -MemberType ScriptMethod -Name TryGetExitCode -Value {
    param([ref]$exitCode)
    $exitCode.Value = 7
    return $true
}
$script:stopTask = $null
$script:activeTargetLabel = '测试目标'
$script:activeTargetTag = 'test'
$script:lastUiBmState = 'ready'
$script:lastUiHriState = 'ready'
$script:statusStream = $null
$script:targetLabel = '启动目标'
$script:mockUiFields['CurrentCallValue'] = 'DMR ID 1234'
On-UiTimerTick
Assert-UiStatus ([string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallValue']) -and
    [string]::IsNullOrEmpty([string]$script:mockUiFields['CurrentCallDetail']) -and
    $script:mockIdentityRows['current'] -ceq 'Collapsed') '核心意外退出时仍显示上次活动 BM 话者。'
Assert-UiStatus ($script:mockUiFields['HriSourceIdentityValue'] -ceq '本次运行已结束' -and
    $script:mockUiFields['RadioDisplayValue'] -ceq 'FTX-1 屏幕：未知') '核心退出时仍显示旧 HRI 来源标签。'

$retentionRoot = Join-Path $env:TEMP ('wirex-ui-retention-' + [guid]::NewGuid().ToString('N'))
$runRoot = Join-Path $retentionRoot 'ui-runs'
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
function New-UiRetentionRun {
    param([string]$Event, [int]$ProcessId, [DateTime]$ModifiedUtc, [bool]$WriteStatus = $true)
    $path = Join-Path $runRoot ([guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    if ($WriteStatus) {
        $record = $valid.PSObject.Copy()
        $record.run_id = ('{0}-78123' -f $ProcessId)
        $record.event = $Event
        $json = (ConvertTo-Json -InputObject $record -Compress) + "`n"
        [System.IO.File]::WriteAllText((Join-Path $path 'status.jsonl'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    [System.IO.Directory]::SetLastWriteTimeUtc($path, $ModifiedUtc)
    return $path
}
try {
    $deadPid = 2147483647
    while ($deadPid -gt 1000000000) {
        $process = $null
        try { $process = [System.Diagnostics.Process]::GetProcessById($deadPid); $process.Dispose(); $deadPid-- }
        catch [System.ArgumentException] { break }
        catch { throw '无法为 UI 运行日志保留测试找到空闲 PID。' }
    }
    Assert-UiStatus ($deadPid -gt 1000000000) '没有找到测试用的空闲 PID。'
    $oldRun = New-UiRetentionRun -Event 'stopped' -ProcessId $deadPid -ModifiedUtc ([DateTime]::UtcNow.AddDays(-2))
    $newRun = New-UiRetentionRun -Event 'stopped_with_failure' -ProcessId ($deadPid - 1) -ModifiedUtc ([DateTime]::UtcNow.AddDays(-1))
    $currentRun = New-UiRetentionRun -Event 'stopped' -ProcessId ($deadPid - 2) -ModifiedUtc ([DateTime]::UtcNow.AddDays(-3))
    $activeRun = New-UiRetentionRun -Event 'stopped' -ProcessId ([System.Diagnostics.Process]::GetCurrentProcess().Id) -ModifiedUtc ([DateTime]::UtcNow.AddDays(-4))
    $unknownRun = New-UiRetentionRun -Event 'runtime_snapshot' -ProcessId $deadPid -ModifiedUtc ([DateTime]::UtcNow.AddDays(-5))
    $unknownOnlyRun = New-UiRetentionRun -Event 'stopped' -ProcessId $deadPid -ModifiedUtc ([DateTime]::UtcNow.AddDays(-6)) -WriteStatus:$false
    $retentionResult = Invoke-UiRunLogRetention -RunRoot $runRoot -ConfigRoot $retentionRoot `
        -CurrentRunDirectory $currentRun -MaximumCompletedRuns 1 -MaximumCompletedBytes 1048576
    Assert-UiStatus ($retentionResult.removed -eq 1 -and $retentionResult.retained -eq 1) '完成日志保留数量上限没有清理最旧的可确认终态目录。'
    Assert-UiStatus (-not [System.IO.Directory]::Exists($oldRun) -and [System.IO.Directory]::Exists($newRun)) '运行目录排序没有保留较新的终态记录。'
    Assert-UiStatus ([System.IO.Directory]::Exists($currentRun) -and [System.IO.Directory]::Exists($activeRun) -and
        [System.IO.Directory]::Exists($unknownRun) -and [System.IO.Directory]::Exists($unknownOnlyRun)) '清理删除了当前、仍活动或状态未知的运行目录。'
    $byteLimited = Invoke-UiRunLogRetention -RunRoot $runRoot -ConfigRoot $retentionRoot `
        -CurrentRunDirectory $currentRun -MaximumCompletedRuns 10 -MaximumCompletedBytes 0
    Assert-UiStatus ($byteLimited.removed -eq 1 -and -not [System.IO.Directory]::Exists($newRun)) '完成日志累计大小上限没有删除超出上限的终态目录。'
    Assert-UiStatus ([System.IO.Directory]::Exists($currentRun) -and [System.IO.Directory]::Exists($activeRun) -and
        [System.IO.Directory]::Exists($unknownRun) -and [System.IO.Directory]::Exists($unknownOnlyRun)) '大小清理删除了仍活动、当前或状态未知的目录。'

    $countConfigRoot = Join-Path $retentionRoot 'default-count-case'
    $runRoot = Join-Path $countConfigRoot 'ui-runs'
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $defaultCountRuns = @()
    for ($index = 0; $index -lt 11; $index++) {
        $defaultCountRuns += New-UiRetentionRun -Event 'stopped' -ProcessId $deadPid `
            -ModifiedUtc ([DateTime]::UtcNow.AddMinutes(-$index))
    }
    $defaultCountResult = Invoke-UiRunLogRetention -RunRoot $runRoot -ConfigRoot $countConfigRoot
    Assert-UiStatus ($defaultCountResult.removed -eq 1 -and $defaultCountResult.retained -eq 10) '默认清理没有保留最近 10 个已完成运行目录。'
    Assert-UiStatus (-not [System.IO.Directory]::Exists($defaultCountRuns[10]) -and
        @($defaultCountRuns | Where-Object { [System.IO.Directory]::Exists($_) }).Count -eq 10) '默认数量上限没有删除最旧的一项。'

    $bytesConfigRoot = Join-Path $retentionRoot 'default-bytes-case'
    $runRoot = Join-Path $bytesConfigRoot 'ui-runs'
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $oversizedRun = New-UiRetentionRun -Event 'stopped' -ProcessId $deadPid -ModifiedUtc ([DateTime]::UtcNow.AddMinutes(1))
    $oversizedPath = Join-Path $oversizedRun 'retention-size-fixture.bin'
    $oversizedStream = [System.IO.File]::Open($oversizedPath, [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $oversizedStream.SetLength([int64]52428801) } finally { $oversizedStream.Dispose() }
    $defaultBytesResult = Invoke-UiRunLogRetention -RunRoot $runRoot -ConfigRoot $bytesConfigRoot
    Assert-UiStatus ($defaultBytesResult.removed -eq 1 -and -not [System.IO.Directory]::Exists($oversizedRun)) '默认 50 MiB 上限没有删除超限的已完成运行目录。'
} finally {
    if ([System.IO.Directory]::Exists($retentionRoot)) { [System.IO.Directory]::Delete($retentionRoot, $true) }
}

Write-Output '通过：PS5.1 状态记录、来源标签、run_id/序号/新鲜度、生命周期清理及已完成运行日志保留检查。'
