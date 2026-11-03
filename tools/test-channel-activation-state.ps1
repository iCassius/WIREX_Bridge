#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module -Name (Join-Path (Join-Path $repoRoot 'ui\windows') 'ChannelActivationState.psm1') -Force

function Assert-ChannelActivationState {
    param([Parameter(Mandatory=$true)][bool]$Condition,[Parameter(Mandatory=$true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$runId = '5201-1730592000123'
$state = New-WirexChannelActivationState
Assert-ChannelActivationState ($state.run_id -ceq '' -and $state.pending_by_request.Count -eq 0 -and
    $state.latest_request_by_slot.Count -eq 0 -and $state.request_sent_by_target.Count -eq 0) '初始状态没有清空所有索引。'
Reset-WirexChannelActivationState -State $state -RunId $runId | Out-Null
Assert-ChannelActivationState ($state.run_id -ceq $runId) '状态没有绑定当前 run_id。'

$requestA = '8a16b667-7eb7-4a8b-9086-a7d26775eaa1'
$requestB = '8a16b667-7eb7-4a8b-9086-a7d26775eaa2'
$requestC = '8a16b667-7eb7-4a8b-9086-a7d26775eaa3'
$requestD = '8a16b667-7eb7-4a8b-9086-a7d26775eaa4'
$requestE = '8a16b667-7eb7-4a8b-9086-a7d26775eaa5'
$requestF = '8a16b667-7eb7-4a8b-9086-a7d26775eaa6'

Assert-ChannelActivationState (-not (Start-WirexChannelActivationRequest -State $state -RunId '5202-1730592000123' `
    -RequestId $requestA -ChannelKey 'group:12345:2' -DestinationId 12345 -Slot 2)) '其他 run_id 可以创建请求。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestA -ChannelKey 'group:12345:2' -DestinationId 12345 -Slot 2) '有效组呼请求未能进入 pending。'
Assert-ChannelActivationState (Test-WirexChannelActivationPending -State $state -RunId $runId) 'pending 状态没有被识别。'
Assert-ChannelActivationState (Test-WirexChannelActivationPending -State $state -RunId $runId -ChannelKey 'group:12345:2') '按频道查 pending 失败。'
Assert-ChannelActivationState (-not (Test-WirexChannelActivationPending -State $state -RunId $runId -ChannelKey 'group:23456:2')) 'pending 错误归到另一频道。'
Assert-ChannelActivationState (-not (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestB -ChannelKey 'group:23456:2' -DestinationId 23456 -Slot 2)) '未结束的请求被覆盖。'

Assert-ChannelActivationState (Set-WirexChannelActivationRequestTimedOut -State $state -RunId $runId -RequestId $requestA) 'pending 请求无法标记超时。'
Assert-ChannelActivationState (-not (Test-WirexChannelActivationPending -State $state -RunId $runId)) '超时请求仍被当作等待中的请求。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestB -ChannelKey 'group:23456:2' -DestinationId 23456 -Slot 2) '超时后不能重试。'
$late = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestA -Result ok `
    -ActivationStatus request_sent -DestinationId 12345 -Slot 2 -FramesSent 2
Assert-ChannelActivationState (-not $late.matched -and -not $late.current -and -not $late.sent) '同槽新请求替代后，旧请求迟到 ACK 没有被忽略。'
$sentB = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestB -Result ok `
    -ActivationStatus request_sent -DestinationId 23456 -Slot 2 -FramesSent 2
Assert-ChannelActivationState ($sentB.matched -and $sentB.current -and $sentB.sent) '匹配的两帧 request_sent 没有完成请求。'
Assert-ChannelActivationState ((Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:23456:2' -Slot 2).request_id -ceq $requestB) '成功状态未按 run/channel/slot 保存。'
Assert-ChannelActivationState ($null -eq (Get-WirexChannelActivationRequestSent -State $state -RunId '5202-1730592000123' `
    -ChannelKey 'group:23456:2' -Slot 2)) '成功状态泄漏到另一个 run_id。'
Assert-ChannelActivationState ($null -eq (Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:12345:2' -Slot 2)) '成功状态泄漏到另一个频道 key。'

Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestC -ChannelKey 'group:33333:1' -DestinationId 33333 -Slot 1) '不同软件时隙的请求被拒绝。'
$sentC = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestC -Result ok `
    -ActivationStatus request_sent -DestinationId 33333 -Slot 1 -FramesSent 2
Assert-ChannelActivationState ($sentC.sent) 'slot 1 的匹配请求没有记录发送状态。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestD -ChannelKey 'group:44444:2' -DestinationId 44444 -Slot 2) 'slot 2 后续请求被拒绝。'
Assert-ChannelActivationState ($null -ne (Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:23456:2' -Slot 2)) '同槽新目标请求抹掉了旧目标的本地发送记录。'
Assert-ChannelActivationState ($null -ne (Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:33333:1' -Slot 1)) '清同槽状态时误清了另一个软件时隙。'
$short = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestD -Result ok `
    -ActivationStatus request_sent -DestinationId 44444 -Slot 2 -FramesSent 1
Assert-ChannelActivationState ($short.matched -and $short.current -and -not $short.sent) '单帧结果被当作成功。'
Assert-ChannelActivationState (-not (Test-WirexChannelActivationPending -State $state -RunId $runId)) '无效 ACK 没有释放请求供手动重试。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestE -ChannelKey 'group:44444:2' -DestinationId 44444 -Slot 2) '无效 ACK 后无法手动重试。'
$rejected = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestE -Result rejected `
    -ErrorAction Stop
Assert-ChannelActivationState ($rejected.matched -and $rejected.current -and -not $rejected.sent) '拒绝响应被当作发送成功。'
Assert-ChannelActivationState ((Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:23456:2' -Slot 2) -and
    $null -eq (Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:44444:2' -Slot 2)) 'NACK 提前清掉了同槽旧发送记录或新增了虚假的成功记录。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $state -RunId $runId `
    -RequestId $requestF -ChannelKey 'group:44444:2' -DestinationId 44444 -Slot 2) '拒绝后无法重新请求同槽目标。'
$sentF = Complete-WirexChannelActivationRequest -State $state -RunId $runId -RequestId $requestF -Result ok `
    -ActivationStatus request_sent -DestinationId 44444 -Slot 2 -FramesSent 2
Assert-ChannelActivationState ($sentF.sent -and
    $null -eq (Get-WirexChannelActivationRequestSent -State $state -RunId $runId -ChannelKey 'group:23456:2' -Slot 2) -and
    (Get-WirexChannelActivationRequestSent -State $state -RunId $runId -ChannelKey 'group:44444:2' -Slot 2)) `
    '同槽新目标得到有效两帧结果后，没有更新本机最后一次发送记录。'

foreach ($invalid in @(
    @{ request=$requestA; key='group:4000:2'; id=4000; slot=2 },
    @{ request='not-a-guid'; key='group:12345:2'; id=12345; slot=2 },
    @{ request=$requestA; key='group:12345:2'; id=12346; slot=2 },
    @{ request=$requestA; key='group:12345:3'; id=12345; slot=3 },
    @{ request=$requestA; key='private:12345:2'; id=12345; slot=2 }
)) {
    Assert-ChannelActivationState (-not (Start-WirexChannelActivationRequest -State $state -RunId $runId `
        -RequestId ([string]$invalid.request) -ChannelKey ([string]$invalid.key) `
        -DestinationId $invalid.id -Slot $invalid.slot)) ('拒绝了无效请求目标：' + [string]$invalid.key)
}

Assert-ChannelActivationState (Clear-WirexChannelActivationSlot -State $state -RunId $runId -Slot 1) 'slot 1 状态清理失败。'
Assert-ChannelActivationState ($null -eq (Get-WirexChannelActivationRequestSent -State $state -RunId $runId `
    -ChannelKey 'group:33333:1' -Slot 1)) 'slot 1 清理后仍有本地发送状态。'
Reset-WirexChannelActivationState -State $state -RunId '5202-1730592000123' | Out-Null
Assert-ChannelActivationState ($state.run_id -ceq '5202-1730592000123' -and $state.pending_by_request.Count -eq 0 -and
    $state.latest_request_by_slot.Count -eq 0 -and $state.request_sent_by_target.Count -eq 0) '切换 run_id 后保留了旧状态。'

$growthState = New-WirexChannelActivationState
Reset-WirexChannelActivationState -State $growthState -RunId $runId | Out-Null
$firstRetryRequestId = ''
$latestRetryRequestId = ''
for ($index = 0; $index -lt 100; $index++) {
    $retryRequestId = [guid]::NewGuid().ToString()
    if ($index -eq 0) { $firstRetryRequestId = $retryRequestId }
    $latestRetryRequestId = $retryRequestId
    Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $growthState -RunId $runId `
        -RequestId $retryRequestId -ChannelKey 'group:55555:1' -DestinationId 55555 -Slot 1) '连续超时重试未能启动。'
    Assert-ChannelActivationState ($growthState.pending_by_request.Count -le 1) '同槽重试后保留了超过一条 pending/timeout 记录。'
    Assert-ChannelActivationState (Set-WirexChannelActivationRequestTimedOut -State $growthState `
        -RunId $runId -RequestId $retryRequestId) '连续重试请求无法标记超时。'
}
Assert-ChannelActivationState ($growthState.pending_by_request.Count -eq 1) '100 次同槽超时重试后没有只保留最新一条记录。'
$oldRetryLateAck = Complete-WirexChannelActivationRequest -State $growthState -RunId $runId `
    -RequestId $firstRetryRequestId -Result ok -ActivationStatus request_sent -DestinationId 55555 -Slot 1 -FramesSent 2
Assert-ChannelActivationState (-not $oldRetryLateAck.matched) '被同槽新请求替代的旧迟到 ACK 仍然匹配。'
$latestRetryLateAck = Complete-WirexChannelActivationRequest -State $growthState -RunId $runId `
    -RequestId $latestRetryRequestId -Result ok -ActivationStatus request_sent -DestinationId 55555 -Slot 1 -FramesSent 2
Assert-ChannelActivationState ($latestRetryLateAck.matched -and $latestRetryLateAck.current -and $latestRetryLateAck.sent) `
    '同槽最新超时请求的有效迟到 ACK 没有完成当前状态。'

$crossSlotState = New-WirexChannelActivationState
Reset-WirexChannelActivationState -State $crossSlotState -RunId $runId | Out-Null
$slotOneOldRequestId = [guid]::NewGuid().ToString()
$slotTwoLatestRequestId = [guid]::NewGuid().ToString()
$slotOneLatestRequestId = [guid]::NewGuid().ToString()
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotOneOldRequestId -ChannelKey 'group:11111:1' -DestinationId 11111 -Slot 1) 'slot 1 首次超时请求未启动。'
Assert-ChannelActivationState (Set-WirexChannelActivationRequestTimedOut -State $crossSlotState `
    -RunId $runId -RequestId $slotOneOldRequestId) 'slot 1 首次请求无法标记超时。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotTwoLatestRequestId -ChannelKey 'group:22222:2' -DestinationId 22222 -Slot 2) 'slot 2 最新超时请求未启动。'
Assert-ChannelActivationState (Set-WirexChannelActivationRequestTimedOut -State $crossSlotState `
    -RunId $runId -RequestId $slotTwoLatestRequestId) 'slot 2 最新请求无法标记超时。'
Assert-ChannelActivationState (Start-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotOneLatestRequestId -ChannelKey 'group:33333:1' -DestinationId 33333 -Slot 1) 'slot 1 新请求未能替代旧超时记录。'
Assert-ChannelActivationState ($crossSlotState.pending_by_request.Count -eq 2) '同槽旧记录清理时误删另一槽最新超时记录。'
$slotOneOldLateAck = Complete-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotOneOldRequestId -Result ok -ActivationStatus request_sent -DestinationId 11111 -Slot 1 -FramesSent 2
Assert-ChannelActivationState (-not $slotOneOldLateAck.matched) '被同槽新请求替代的迟到 ACK 仍然匹配。'
$slotTwoLateAck = Complete-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotTwoLatestRequestId -Result ok -ActivationStatus request_sent -DestinationId 22222 -Slot 2 -FramesSent 2
Assert-ChannelActivationState ($slotTwoLateAck.matched -and $slotTwoLateAck.current -and $slotTwoLateAck.sent) `
    '另一槽仍为最新的超时请求没有接受有效迟到 ACK。'
$slotOneLatestLateAck = Complete-WirexChannelActivationRequest -State $crossSlotState -RunId $runId `
    -RequestId $slotOneLatestRequestId -Result ok -ActivationStatus request_sent -DestinationId 33333 -Slot 1 -FramesSent 2
Assert-ChannelActivationState ($slotOneLatestLateAck.matched -and $slotOneLatestLateAck.current -and $slotOneLatestLateAck.sent) `
    '当前槽最新请求没有接受有效 ACK。'

Write-Output ('通过：频道激活状态模块独立 smoke（{0} 项断言；仅内存状态，不连接 BM、Native 或硬件）。' -f $script:assertionCount)
