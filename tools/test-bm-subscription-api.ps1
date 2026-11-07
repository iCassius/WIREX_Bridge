param(
    [string]$ModulePath = (Join-Path $PSScriptRoot 'bm-subscription-api.psm1')
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "预期拒绝但操作成功：$Message" }
}

function New-ProfileFixture {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [string]$DeviceId = '460999901',
        [string]$ObservationId = ([guid]::NewGuid().ToString('N')),
        [datetime]$ObservedAtUtc = [DateTime]::UtcNow,
        [datetime]$RequestStartedAtUtc,
        [AllowEmptyString()][string]$AfterMutationRequestId = '',
        [int]$HttpStatusCode = 200
    )
    if (-not $PSBoundParameters.ContainsKey('RequestStartedAtUtc')) {
        $RequestStartedAtUtc = $ObservedAtUtc.AddSeconds(-1)
    }
    $readInvocation = [pscustomobject]@{
        plan_action = 'ReadProfile'
        request_id = $ObservationId
        device_id = $DeviceId
        request_started_at_utc = $RequestStartedAtUtc.ToUniversalTime().ToString('o')
        request_completed_at_utc = $ObservedAtUtc.ToUniversalTime().ToString('o')
        after_mutation_request_id = $AfterMutationRequestId
        result_state = if ($HttpStatusCode -ge 200 -and $HttpStatusCode -lt 300) { 'read_response_received' } else { 'request_rejected' }
        response = [pscustomobject]@{ status_code = $HttpStatusCode; body = $Json }
    }
    return ConvertFrom-BmDeviceProfile -Json $Json -ReadInvocation $readInvocation
}

$tokens = $null
$parseErrors = $null
$moduleFullPath = [System.IO.Path]::GetFullPath($ModulePath)
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $moduleFullPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "BM API module PowerShell 5.1 语法解析失败：$messages"
}

Import-Module -Name $moduleFullPath -Force

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-bm-api-mock-' + [guid]::NewGuid().ToString('N'))
$temporaryRootFullPath = [System.IO.Path]::GetFullPath($temporaryRoot)
$tempParentFullPath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (-not $temporaryRootFullPath.StartsWith($tempParentFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '测试目录没有落在系统临时目录中。'
}
New-Item -ItemType Directory -Path $temporaryRootFullPath | Out-Null
$tokenFile = Join-Path $temporaryRootFullPath 'api-token.fixture.txt'
$fixtureToken = 'TEST-ONLY-BEARER-DO-NOT-USE'
[System.IO.File]::WriteAllText($tokenFile, $fixtureToken, (New-Object System.Text.UTF8Encoding($false)))

try {
    $validProfileJson = '{"staticSubscriptions":[{"talkgroup":91,"slot":0},{"talkgroup":3100,"slot":0}],"dynamicSubscriptions":[{"talkgroup":46001,"slot":0}]}'
    $profile = New-ProfileFixture -Json $validProfileJson
    Assert-True ($profile.parse_state -ceq 'known') '静态和动态数组应按已知字段解析'
    Assert-True ($profile.static_subscriptions.Count -eq 2) 'profile 应保留所有静态组'
    Assert-True ($profile.dynamic_subscriptions.Count -eq 1 -and $profile.dynamic_subscriptions[0].talkgroup -eq 46001) `
        'profile 应保留动态组及目标 ID'

    foreach ($unknownJson in @(
        '{bad json',
        'null',
        '"scalar"',
        '42',
        '[]',
        '[{"staticSubscriptions":[],"dynamicSubscriptions":[]}]',
        '{"staticSubscriptions":[],"talkgroups":[]}',
        '{"staticSubscriptions":[{"talkgroup":91}],"dynamicSubscriptions":[]}',
        '{"staticSubscriptions":[{"talkgroup":0,"slot":0}],"dynamicSubscriptions":[]}',
        '{"staticSubscriptions":[],"dynamicSubscriptions":[{"talkgroup":91,"slot":3}]}',
        '{"staticSubscriptions":null,"dynamicSubscriptions":[]}',
        '{"staticSubscriptions":[],"dynamicSubscriptions":null}'
    )) {
        $unknown = New-ProfileFixture -Json $unknownJson
        Assert-True ($unknown.parse_state -ceq 'unknown') '未知或格式错误的 profile 必须保持 Unknown'
        Assert-True ($unknown.static_subscriptions.Count -eq 0 -and $unknown.dynamic_subscriptions.Count -eq 0) `
            '未知 schema 不得泄漏部分解析出的订阅集合'
    }

    $readPlan = New-BmApiRequestPlan -Action ReadProfile -DeviceId '460999901'
    Assert-True ($readPlan.method -ceq 'GET') 'profile 读回必须使用 GET'
    Assert-True ($readPlan.uri -ceq 'https://api.brandmeister.network/v2/device/460999901/profile') 'profile URL 必须使用固定 HTTPS BM v2 host'
    Assert-True ($null -eq $readPlan.api_slot) '读取整台设备 profile 不应强制或虚构某一个 API slot'
    Assert-True (-not $readPlan.uri.Contains('62031')) 'DMR UDP 端口不得拼入 HTTPS API 请求'
    $maximumDevicePlan = New-BmApiRequestPlan -Action ReadProfile -DeviceId '4294967295'
    Assert-True ($maximumDevicePlan.device_id -ceq '4294967295') '设备 ID 不得使用未经 API 证据支持的窄范围'

    $addPlan = New-BmApiRequestPlan -Action AddStatic -DeviceId '460999901' -ApiSlot 0 -Talkgroup 91
    $addBody = ConvertFrom-Json -InputObject $addPlan.body -ErrorAction Stop
    Assert-True ($addPlan.method -ceq 'POST' -and $addPlan.uri -ceq 'https://api.brandmeister.network/v2/device/460999901/talkgroup') `
        '静态组添加必须使用 BM v2 POST 路径'
    Assert-True ($addBody.slot -eq 0 -and $addBody.group -eq 91) 'JSON body 应保留 API slot 0 与 TG 91'
    Assert-True ($null -eq $addPlan.PSObject.Properties['dmr_slot']) 'API slot 不得被伪装成 DMR 媒体时隙'

    $removePlan = New-BmApiRequestPlan -Action RemoveStatic -DeviceId '460999901' -ApiSlot 2 -Talkgroup 3100
    Assert-True ($removePlan.method -ceq 'DELETE' -and
        $removePlan.uri -ceq 'https://api.brandmeister.network/v2/device/460999901/talkgroup/2/3100') `
        '静态组删除必须精确指定 API slot 和 TG'

    $dropDynamicPlan = New-BmApiRequestPlan -Action DropDynamic -DeviceId '460999901' -ApiSlot 0
    $dropCallPlan = New-BmApiRequestPlan -Action DropCallRoute -DeviceId '460999901' -ApiSlot 2
    Assert-True ($dropDynamicPlan.method -ceq 'GET' -and $dropDynamicPlan.is_action -and
        $dropDynamicPlan.uri.EndsWith('/action/dropDynamicGroups/0')) '清除动态组虽然是 GET，仍必须标记为有副作用动作'
    Assert-True ($dropCallPlan.method -ceq 'GET' -and $dropCallPlan.is_action -and
        $dropCallPlan.uri.EndsWith('/action/dropCallRoute/2')) '结束 QSO 虽然是 GET，仍必须标记为有副作用动作'
    Assert-Throws { New-BmApiRequestPlan -Action ReadProfile -DeviceId 'not-a-device' -ApiSlot 0 } '设备 ID 不允许 URL 注入'
    Assert-Throws { New-BmApiRequestPlan -Action AddStatic -DeviceId '460999901' -ApiSlot 0 -Talkgroup 0 } 'TG 0 不作为静态订阅'
    Assert-Throws { New-BmApiRequestPlan -Action AddStatic -DeviceId '460999901' -Talkgroup 91 } '静态组写入必须显式给出 API slot'
    Assert-Throws { New-BmApiRequestPlan -Action QuickCall -DeviceId '460999901' -ApiSlot 0 -Talkgroup 91 } `
        'Quick Call 不是 BM REST API action'

    $diffPlans = @(New-BmStaticReconciliationPlans -ProfileState $profile -DeviceId '460999901' -ApiSlot 0 `
        -ManagedTalkgroups @(91) -DesiredTalkgroups @(93))
    Assert-True ($diffPlans.Count -eq 2) '静态组差集应生成一条添加与一条删除计划'
    Assert-True (@($diffPlans | Where-Object { $_.action -ceq 'AddStatic' -and $_.talkgroup -eq 93 }).Count -eq 1) `
        '目标集中缺失的 TG 应计划添加'
    Assert-True (@($diffPlans | Where-Object { $_.action -ceq 'RemoveStatic' -and $_.talkgroup -eq 91 }).Count -eq 1) `
        '仅管理集合中多余的 TG 应计划删除'
    Assert-True (@($diffPlans | Where-Object { $_.talkgroup -eq 3100 }).Count -eq 0) `
        '不属于 adapter 管理集合的静态 TG 应保留'
    $noDiffPlans = @(New-BmStaticReconciliationPlans -ProfileState $profile -DeviceId '460999901' -ApiSlot 0 `
        -ManagedTalkgroups @(91) -DesiredTalkgroups @(91))
    Assert-True ($noDiffPlans.Count -eq 0) '已符合目标状态时不得重复 POST/DELETE'
    $unknownPlans = @(New-BmStaticReconciliationPlans -ProfileState (New-ProfileFixture -Json '{"unexpected":true}') `
        -DeviceId '460999901' -ApiSlot 0 -ManagedTalkgroups @(91) -DesiredTalkgroups @(91, 93))
    Assert-True ($unknownPlans.Count -eq 0) 'profile schema 未知时不得计划写入'
    $missingScopePlans = @(New-BmStaticReconciliationPlans -ProfileState ([pscustomobject]@{}) `
        -DeviceId '460999901' -ApiSlot 0 -ManagedTalkgroups @(91) -DesiredTalkgroups @(93))
    Assert-True ($missingScopePlans.Count -eq 0) '缺少 ProfileState scope 字段时不得抛错或计划写入'
    $crossDevicePlans = @(New-BmStaticReconciliationPlans -ProfileState (New-ProfileFixture -Json $validProfileJson -DeviceId '460999902') `
        -DeviceId '460999901' -ApiSlot 0 -ManagedTalkgroups @(91) -DesiredTalkgroups @(91, 93))
    Assert-True ($crossDevicePlans.Count -eq 0) '静态差集必须绑定同一 BM device ID'

    $mockState = [pscustomobject]@{
        request_count = 0
        observed_auth = $false
        observed_cache_control = $false
        observed_body = ''
        status_code = 200
        transport_throws = $false
    }
    $mockTransport = {
        param($Request)
        $mockState.request_count++
        $mockState.observed_auth = ([string]$Request.Headers.Authorization -ceq "Bearer $fixtureToken")
        $mockState.observed_cache_control = ([string]$Request.Headers['Cache-Control'] -ceq 'no-store')
        $mockState.observed_body = [string]$Request.Body
        if ($mockState.transport_throws) { throw 'synthetic transport timeout' }
        return [pscustomobject]@{ StatusCode = $mockState.status_code; Body = '{"synthetic":true}' }
    }.GetNewClosure()

    $invocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ($mockState.request_count -eq 1) '注入的 fake transport 应收到且仅收到当前请求'
    Assert-True ($mockState.observed_auth) '合成 API token 应仅通过 Bearer header 传递'
    Assert-True ($mockState.observed_cache_control) '请求应禁止缓存'
    Assert-True ($mockState.observed_body -ceq '{"slot":0,"group":91}') 'transport 请求体应只含静态 TG 数据'
    Assert-True ([string]$invocation.confirmation -ceq 'readback_required') '写操作的 HTTP 响应本身不得确认为订阅成功'
    Assert-True ([string]$invocation.result_state -ceq 'success_awaiting_readback') 'HTTP 200 写响应仍需 profile readback'
    Assert-True ([string]$invocation -notmatch [regex]::Escape($fixtureToken)) '模块返回对象不得包含 API token'

    $syntheticMutationInvocation = [pscustomobject]@{
        request_id = $addPlan.plan_id
        plan_action = $addPlan.action
        device_id = $addPlan.device_id
        request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
        result_state = 'success_awaiting_readback'
    }
    $unknownReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState (New-ProfileFixture -Json '{"unknown":true}' -AfterMutationRequestId $addPlan.plan_id) `
        -MutationInvocation $syntheticMutationInvocation
    $unknownConfirmation = Resolve-BmMutationConfirmation -Plan $addPlan -HttpStatusCode 200 -Readback $unknownReadback
    Assert-True ($unknownConfirmation.state -ceq 'unknown') '未知 profile 不得确认订阅'
    $missingReadbackConfirmation = Resolve-BmMutationConfirmation -Plan $addPlan -HttpStatusCode 200
    Assert-True ($missingReadbackConfirmation.state -ceq 'unknown') '没有 profile readback 时 HTTP 200 也不得确认订阅'
    $acceptedOnlyConfirmation = Resolve-BmMutationConfirmation -Plan $addPlan -HttpStatusCode 202
    Assert-True ($acceptedOnlyConfirmation.state -ceq 'unknown') 'HTTP 202 Accepted 不得伪装成订阅已确认'
    $mockState.status_code = 202
    $acceptedInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ([string]$acceptedInvocation.result_state -ceq 'accepted_awaiting_readback') 'HTTP 202 应明确等待 profile readback'
    foreach ($rejectedStatus in @(401, 403, 404, 409)) {
        $mockState.status_code = $rejectedStatus
        $rejectedInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
        Assert-True ([string]$rejectedInvocation.result_state -ceq 'request_rejected') "HTTP $rejectedStatus 应作为拒绝状态返回"
        Assert-True ([string]$rejectedInvocation.confirmation -ceq 'readback_required') "HTTP $rejectedStatus 不得跳过 readback"
    }
    $mockState.status_code = 429
    $rateLimitedInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ([string]$rateLimitedInvocation.result_state -ceq 'rate_limited_re_read_before_retry') 'HTTP 429 应先读回再决定是否重试'
    $mockState.status_code = 500
    $serverErrorInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ([string]$serverErrorInvocation.result_state -ceq 'server_outcome_uncertain_readback_required') 'HTTP 5xx 后写入结果应视为不确定并读回'
    $mockState.status_code = 200
    $mockState.transport_throws = $true
    $transportErrorInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ([string]$transportErrorInvocation.result_state -ceq 'transport_outcome_unknown') '传输超时应隐藏异常正文并将远端结果标为未知'
    Assert-True ([string]$transportErrorInvocation -notmatch 'synthetic transport timeout') '异常正文不得进入用户可见结果'
    $mockState.transport_throws = $false
    $mockState.status_code = 200
    $postAddProfile = New-ProfileFixture -Json '{"staticSubscriptions":[{"talkgroup":91,"slot":0}],"dynamicSubscriptions":[]}' `
        -ObservationId 'synthetic-post-add-readback' -AfterMutationRequestId $addPlan.plan_id
    $confirmedReadback = Get-BmStaticMutationReadback -Plan $addPlan -ProfileState $postAddProfile `
        -MutationInvocation $syntheticMutationInvocation
    $pendingConfirmation = Resolve-BmMutationConfirmation -Plan $addPlan -HttpStatusCode 202 -Readback $confirmedReadback
    Assert-True ($pendingConfirmation.state -ceq 'confirmed') '只有读回包含所请求静态 TG 后才可确认，即便写接口返回 202'

    $afterAdd = Get-BmStaticMutationReadback -Plan $addPlan -ProfileState $postAddProfile `
        -MutationInvocation $syntheticMutationInvocation
    Assert-True ($afterAdd.state -ceq 'confirmed') '静态添加需在 profile 中按 API slot 和 TG 精确出现'
    $removeMutationInvocation = [pscustomobject]@{
        request_id = $removePlan.plan_id
        plan_action = $removePlan.action
        device_id = $removePlan.device_id
        request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
        result_state = 'accepted_awaiting_readback'
    }
    $afterRemoveProfile = New-ProfileFixture -Json '{"staticSubscriptions":[{"talkgroup":3100,"slot":0}],"dynamicSubscriptions":[]}' `
        -ObservationId 'synthetic-post-remove-readback' -AfterMutationRequestId $removePlan.plan_id
    $afterRemove = Get-BmStaticMutationReadback -Plan $removePlan -ProfileState $afterRemoveProfile `
        -MutationInvocation $removeMutationInvocation
    Assert-True ($afterRemove.state -ceq 'confirmed') '静态删除需从精确 API slot 和 TG 中读回缺失'
    $crossDeviceReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState (New-ProfileFixture -Json '{"staticSubscriptions":[{"talkgroup":91,"slot":0}],"dynamicSubscriptions":[]}' `
            -DeviceId '460999902' -AfterMutationRequestId $addPlan.plan_id) `
        -MutationInvocation $syntheticMutationInvocation
    Assert-True ($crossDeviceReadback.state -ceq 'unknown') '读回来自其他设备时不得确认'
    $crossDeviceMutationInvocation = [pscustomobject]@{
        request_id = $addPlan.plan_id
        plan_action = $addPlan.action
        device_id = '460999902'
        request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
        result_state = 'success_awaiting_readback'
    }
    $crossDeviceMutationReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $postAddProfile -MutationInvocation $crossDeviceMutationInvocation
    Assert-True ($crossDeviceMutationReadback.state -ceq 'unknown') 'mutation invocation 来自其他设备时不得确认'
    $crossActionMutationInvocation = [pscustomobject]@{
        request_id = $addPlan.plan_id
        plan_action = 'RemoveStatic'
        device_id = $addPlan.device_id
        request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
        result_state = 'success_awaiting_readback'
    }
    $crossActionMutationReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $postAddProfile -MutationInvocation $crossActionMutationInvocation
    Assert-True ($crossActionMutationReadback.state -ceq 'unknown') 'mutation invocation 的 action 不同時不得確認'
    $staleProfile = New-ProfileFixture -Json '{"staticSubscriptions":[{"talkgroup":91,"slot":0}],"dynamicSubscriptions":[]}' `
        -ObservationId 'synthetic-stale-readback' -ObservedAtUtc ([DateTime]::UtcNow.AddMinutes(-1)) `
        -AfterMutationRequestId $addPlan.plan_id
    $staleReadback = Get-BmStaticMutationReadback -Plan $addPlan -ProfileState $staleProfile `
        -MutationInvocation ([pscustomobject]@{
            request_id = $addPlan.plan_id
            plan_action = $addPlan.action
            device_id = $addPlan.device_id
            request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-20).ToString('o')
            result_state = 'server_outcome_uncertain_readback_required'
        })
    Assert-True ($staleReadback.state -ceq 'unknown') '变更前生成的 profile snapshot 不得确认变更'
    $mutationCompletedAt = [DateTime]::UtcNow.AddSeconds(-2)
    $concurrentReadProfile = New-ProfileFixture `
        -Json '{"staticSubscriptions":[{"talkgroup":91,"slot":0}],"dynamicSubscriptions":[]}' `
        -ObservationId 'synthetic-overlapping-readback' -ObservedAtUtc $mutationCompletedAt.AddSeconds(2) `
        -RequestStartedAtUtc $mutationCompletedAt.AddSeconds(-1) -AfterMutationRequestId $addPlan.plan_id
    $overlappingReadback = Get-BmStaticMutationReadback -Plan $addPlan -ProfileState $concurrentReadProfile `
        -MutationInvocation ([pscustomobject]@{
            request_id = $addPlan.plan_id
            plan_action = $addPlan.action
            device_id = $addPlan.device_id
            request_completed_at_utc = $mutationCompletedAt.ToString('o')
            result_state = 'success_awaiting_readback'
        })
    Assert-True ($overlappingReadback.state -ceq 'unknown') `
        'mutation 完成后才收到但在 mutation 完成前已开始的并发 GET 不得确认'
    $rejectedMutationReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $postAddProfile -MutationInvocation ([pscustomobject]@{
            request_id = $addPlan.plan_id
            plan_action = $addPlan.action
            device_id = $addPlan.device_id
            request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
            result_state = 'request_rejected'
        })
    Assert-True ($rejectedMutationReadback.state -ceq 'unknown') '401/403 等拒绝结果不得借较新的 profile 快照确认写入'
    $missingOutcomeReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $postAddProfile -MutationInvocation ([pscustomobject]@{
            request_id = $addPlan.plan_id
            plan_action = $addPlan.action
            device_id = $addPlan.device_id
            request_completed_at_utc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')
        })
    Assert-True ($missingOutcomeReadback.state -ceq 'unknown' -and $missingOutcomeReadback.reason -ceq 'mutation_outcome_missing') `
        '变更 transport 结果字段缺失时应保持 Unknown 且不抛错'
    $emptyProfileScopeReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState ([pscustomobject]@{}) -MutationInvocation $syntheticMutationInvocation
    Assert-True ($emptyProfileScopeReadback.state -ceq 'unknown' -and
        [string]::IsNullOrEmpty([string]$emptyProfileScopeReadback.device_id)) `
        'ProfileState 没有 scope 字段时应安全返回 Unknown'
    $missingDeviceProfileState = [pscustomobject]@{
        parse_state = 'known'
        observation_id = 'synthetic-missing-device'
        observed_at_utc = [DateTime]::UtcNow.ToString('o')
        after_mutation_request_id = $addPlan.plan_id
        static_subscriptions = @()
    }
    $missingDeviceReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $missingDeviceProfileState -MutationInvocation $syntheticMutationInvocation
    Assert-True ($missingDeviceReadback.state -ceq 'unknown') '缺失 device_id 的 profile 不得确认且不得抛错'
    $missingStaticArrayProfileState = [pscustomobject]@{
        parse_state = 'known'
        device_id = $addPlan.device_id
        observation_id = 'synthetic-missing-static-array'
        observed_at_utc = [DateTime]::UtcNow.ToString('o')
        after_mutation_request_id = $addPlan.plan_id
    }
    $missingStaticArrayReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $missingStaticArrayProfileState -MutationInvocation $syntheticMutationInvocation
    Assert-True ($missingStaticArrayReadback.state -ceq 'unknown') '缺失静态订阅字段的 profile 不得确认且不得抛错'
    $missingMutationTimestampReadback = Get-BmStaticMutationReadback -Plan $addPlan `
        -ProfileState $postAddProfile -MutationInvocation ([pscustomobject]@{
            request_id = $addPlan.plan_id
            plan_action = $addPlan.action
            device_id = $addPlan.device_id
            result_state = 'accepted_awaiting_readback'
        })
    Assert-True ($missingMutationTimestampReadback.state -ceq 'unknown') '缺失 mutation 完成时间时应保持 Unknown 且不得抛错'
    $crossPlanConfirmation = Resolve-BmMutationConfirmation -Plan $removePlan -HttpStatusCode 202 -Readback $afterAdd
    Assert-True ($crossPlanConfirmation.state -ceq 'unknown') '其他 mutation plan 的 readback 不得交叉确认'
    $rejectedConfirmation = Resolve-BmMutationConfirmation -Plan $addPlan -HttpStatusCode 401 -Readback $afterAdd
    Assert-True ($rejectedConfirmation.state -ceq 'unknown' -and
        $rejectedConfirmation.state_observed -ceq 'confirmed' -and
        $rejectedConfirmation.mutation_outcome -ceq 'rejected') `
        '401 不得宣称 mutation 成功，同时应单独保留已观察到的 profile 状态'

    $beforeDropInvocation = $mockState.request_count
    $actionInvocation = Invoke-BmApiRequestPlan -Plan $dropDynamicPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ([string]$actionInvocation.confirmation -ceq 'readback_required') '动态清理 GET 仍需后续读回确认'
    Assert-True ($mockState.request_count -eq ($beforeDropInvocation + 1)) '动态清理只在显式 Invoke 时才交给 transport'
    Assert-True ((Get-BmStaticMutationReadback -Plan $dropDynamicPlan -ProfileState $profile `
        -MutationInvocation ([pscustomobject]@{})).state -ceq 'unknown') `
        '静态写入 readback helper 不得误认动态清理结果'

    $beforeExplicitTransport = $mockState.request_count
    $explicitInvocation = Invoke-BmApiRequestPlan -Plan $readPlan -ApiTokenFile $tokenFile -Transport $mockTransport
    Assert-True ($mockState.request_count -eq ($beforeExplicitTransport + 1)) '模块只能调用显式注入的 transport'
    Assert-True ([string]$explicitInvocation.plan_action -ceq 'ReadProfile') '读取请求应保持独立的 profile action'
    $echoTransport = {
        param($Request)
        return [pscustomobject]@{ StatusCode = 200; Body = $Request }
    }.GetNewClosure()
    $echoInvocation = Invoke-BmApiRequestPlan -Plan $addPlan -ApiTokenFile $tokenFile -Transport $echoTransport
    Assert-True ($echoInvocation.response.PSObject.Properties.Name -join ',' -ceq 'status_code,body') `
        'transport 返回对象必须裁剪为 status_code 和已处理的 body'
    Assert-True ([string]$echoInvocation -notmatch [regex]::Escape($fixtureToken)) 'echo transport 不得把 Bearer token 带回调用方'
    Assert-True ([string]$echoInvocation -notmatch 'Bearer TEST-ONLY') 'echo transport 的认证头不得进入返回内容'
    Assert-True ([string]$echoInvocation.response.body -notmatch [regex]::Escape($fixtureToken)) `
        'echo transport 的嵌套 response body 不得包含合成 API token'
    $invalidTokenFile = Join-Path $temporaryRootFullPath 'multiline-token.fixture.txt'
    [System.IO.File]::WriteAllText($invalidTokenFile, "line-one`nline-two", (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Invoke-BmApiRequestPlan -Plan $readPlan -ApiTokenFile $invalidTokenFile -Transport $mockTransport } `
        '多行 token 文件必须拒绝'

    Write-Output '通过：BM v2 请求计划、profile unknown 保留、slot/TG 精确差集、Bearer 隔离、HTTP 202/readback 状态和 mock transport 检查。全程只使用合成 token 与 fake transport；未访问 BM、未发送 UDP/语音。'
} finally {
    Remove-Module bm-subscription-api -ErrorAction SilentlyContinue
    if ([System.IO.Directory]::Exists($temporaryRootFullPath)) {
        if (-not $temporaryRootFullPath.StartsWith($tempParentFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($temporaryRootFullPath) -notmatch '^wirex-bm-api-mock-[0-9a-f]{32}$') {
            throw '拒绝清理路径校验失败的测试目录。'
        }
        Remove-Item -LiteralPath $temporaryRootFullPath -Recurse -Force
    }
}
