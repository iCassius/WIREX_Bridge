Set-StrictMode -Version 2.0

$script:BmApiBaseUri = 'https://api.brandmeister.network/v2/device'
$script:BmMaximumDeviceId = [uint64]4294967295
$script:BmMaximumDmrId = [uint64]16777215

function ConvertTo-BmNumericValue {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][uint64]$Maximum,
        [Parameter()][switch]$AllowZero
    )

    $parsed = [uint64]0
    if (-not [uint64]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Label 必须是十进制整数。"
    }
    if ((-not $AllowZero -and $parsed -eq 0) -or $parsed -gt $Maximum) {
        throw "$Label 超出允许范围。"
    }
    return $parsed
}

function Get-BmObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
    if ($null -eq $property) { return $null }
    if ($property.Value -is [array]) { return ,$property.Value }
    return $property.Value
}

function Test-BmObjectHasProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    return $null -ne ($InputObject.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1)
}

function ConvertFrom-BmSubscriptionArray {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][object]$Items,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Items)) {
        if ($null -eq $item) { throw "$Label 包含空项。" }
        if (-not (Test-BmObjectHasProperty -InputObject $item -Name 'talkgroup') -or
            -not (Test-BmObjectHasProperty -InputObject $item -Name 'slot')) {
            throw "$Label 项缺少 talkgroup 或 slot 字段。"
        }
        $talkgroup = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $item -Name 'talkgroup') `
            -Label "$Label talkgroup" -Maximum $script:BmMaximumDmrId
        $slot = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $item -Name 'slot') `
            -Label "$Label slot" -Maximum 2 -AllowZero
        $result.Add([pscustomobject][ordered]@{
            talkgroup = [uint32]$talkgroup
            slot = [int]$slot
        })
    }
    return $result.ToArray()
}

function New-BmProfileStatePrivate {
    param(
        [Parameter(Mandatory = $true)][string]$ParseState,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Reason,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][string]$ObservationId,
        [Parameter(Mandatory = $true)][string]$ObservedAtUtc,
        [Parameter()][AllowEmptyString()][string]$RequestStartedAtUtc = '',
        [Parameter()][AllowEmptyString()][string]$AfterMutationRequestId,
        [Parameter()][object[]]$StaticSubscriptions = @(),
        [Parameter()][object[]]$DynamicSubscriptions = @()
    )

    return [pscustomobject][ordered]@{
        parse_state = $ParseState
        reason = $Reason
        device_id = $DeviceId
        observation_id = $ObservationId
        observed_at_utc = $ObservedAtUtc
        request_started_at_utc = $RequestStartedAtUtc
        after_mutation_request_id = $AfterMutationRequestId
        static_subscriptions = @($StaticSubscriptions)
        dynamic_subscriptions = @($DynamicSubscriptions)
    }
}

function ConvertFrom-BmDeviceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory = $true)][object]$ReadInvocation
    )

    $normalizedDeviceId = ''
    $observationId = ''
    $observedAtText = ''
    $requestStartedAtText = ''
    $afterMutationRequestId = ''
    $readContextValid = $true
    try {
        if ([string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'plan_action') -cne 'ReadProfile') {
            $readContextValid = $false
        }
        $normalizedDeviceId = [string](ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $ReadInvocation -Name 'device_id') `
            -Label 'DeviceId' -Maximum $script:BmMaximumDeviceId)
        $observationId = [string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'request_id')
        if ([string]::IsNullOrWhiteSpace($observationId)) { $readContextValid = $false }
        $observedAtText = [string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'request_completed_at_utc')
        $requestStartedAtText = [string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'request_started_at_utc')
        $observedAtParsed = [DateTime]::MinValue
        $requestStartedAtParsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($observedAtText, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$observedAtParsed)) { $readContextValid = $false }
        if (-not [DateTime]::TryParse($requestStartedAtText, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$requestStartedAtParsed) -or $requestStartedAtParsed -gt $observedAtParsed) {
            $readContextValid = $false
        }
        $afterMutationRequestId = [string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'after_mutation_request_id')
        $readResponse = Get-BmObjectProperty -InputObject $ReadInvocation -Name 'response'
        $readStatus = Get-BmObjectProperty -InputObject $readResponse -Name 'status_code'
        $readStatusNumber = 0
        if (-not [int]::TryParse([string]$readStatus, [ref]$readStatusNumber) -or
            $readStatusNumber -lt 200 -or $readStatusNumber -ge 300 -or
            [string](Get-BmObjectProperty -InputObject $ReadInvocation -Name 'result_state') -cne 'read_response_received') {
            $readContextValid = $false
        }
    } catch {
        $readContextValid = $false
    }
    try {
        $profile = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    } catch {
        return New-BmProfileStatePrivate -ParseState 'unknown' -Reason 'invalid_json' `
            -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
            -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId
    }

    if ($null -eq $profile -or $profile -isnot [System.Management.Automation.PSCustomObject]) {
        return New-BmProfileStatePrivate -ParseState 'unknown' -Reason 'profile_root_is_not_object' `
            -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
            -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId
    }

    if (-not $readContextValid) {
        return New-BmProfileStatePrivate -ParseState 'unknown' -Reason 'profile_read_context_unverified' `
            -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
            -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId
    }

    if (-not (Test-BmObjectHasProperty -InputObject $profile -Name 'staticSubscriptions') -or
        -not (Test-BmObjectHasProperty -InputObject $profile -Name 'dynamicSubscriptions')) {
        return New-BmProfileStatePrivate -ParseState 'unknown' -Reason 'profile_schema_unrecognized' `
            -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
            -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId
    }

    try {
        $staticProfileField = Get-BmObjectProperty -InputObject $profile -Name 'staticSubscriptions'
        $dynamicProfileField = Get-BmObjectProperty -InputObject $profile -Name 'dynamicSubscriptions'
        if ($null -eq $staticProfileField -or $staticProfileField -isnot [array] -or
            $null -eq $dynamicProfileField -or $dynamicProfileField -isnot [array]) {
            throw 'Subscription collections must be non-null JSON arrays.'
        }
        $staticItems = ConvertFrom-BmSubscriptionArray -Items $staticProfileField `
            -Label 'staticSubscriptions'
        $dynamicItems = ConvertFrom-BmSubscriptionArray -Items $dynamicProfileField `
            -Label 'dynamicSubscriptions'
        if ($null -eq $staticItems) { $staticItems = @() }
        if ($null -eq $dynamicItems) { $dynamicItems = @() }
    } catch {
        return New-BmProfileStatePrivate -ParseState 'unknown' -Reason 'profile_fields_unrecognized' `
            -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
            -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId
    }

    return New-BmProfileStatePrivate -ParseState 'known' -Reason '' `
        -DeviceId $normalizedDeviceId -ObservationId $observationId -ObservedAtUtc $observedAtText `
        -RequestStartedAtUtc $requestStartedAtText -AfterMutationRequestId $afterMutationRequestId `
        -StaticSubscriptions $staticItems -DynamicSubscriptions $dynamicItems
}

function New-BmApiRequestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('ReadProfile', 'AddStatic', 'RemoveStatic', 'DropDynamic', 'DropCallRoute')][string]$Action,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter()][ValidateRange(0, 2)][int]$ApiSlot,
        [Parameter()][uint32]$Talkgroup,
        [Parameter()][AllowEmptyString()][string]$AfterMutationRequestId
    )

    $hasApiSlot = $PSBoundParameters.ContainsKey('ApiSlot')
    $hasAfterMutationRequestId = $PSBoundParameters.ContainsKey('AfterMutationRequestId')
    if ($Action -ne 'ReadProfile' -and -not $hasApiSlot) {
        throw "$Action 必须显式提供 API slot。"
    }
    if ($Action -ne 'ReadProfile' -and $hasAfterMutationRequestId) {
        throw 'AfterMutationRequestId 只用于标记变更后的 profile 读回请求。'
    }
    $deviceNumber = ConvertTo-BmNumericValue -Value $DeviceId -Label 'DeviceId' -Maximum $script:BmMaximumDeviceId
    $planId = [guid]::NewGuid().ToString('N')
    $plannedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $baseUri = "$($script:BmApiBaseUri)/$deviceNumber"
    $method = ''
    $uri = ''
    $body = $null
    $requiresReadback = $false
    $expectedPresence = $null
    $isAction = $false

    switch ($Action) {
        'ReadProfile' {
            $method = 'GET'
            $uri = "$baseUri/profile"
        }
        'AddStatic' {
            if (-not $PSBoundParameters.ContainsKey('Talkgroup')) { throw 'AddStatic 必须提供 Talkgroup。' }
            $group = ConvertTo-BmNumericValue -Value $Talkgroup -Label 'Talkgroup' -Maximum $script:BmMaximumDmrId
            $method = 'POST'
            $uri = "$baseUri/talkgroup"
            $body = ConvertTo-Json -InputObject ([ordered]@{ slot = $ApiSlot; group = [uint32]$group }) -Compress
            $requiresReadback = $true
            $expectedPresence = $true
        }
        'RemoveStatic' {
            if (-not $PSBoundParameters.ContainsKey('Talkgroup')) { throw 'RemoveStatic 必须提供 Talkgroup。' }
            $group = ConvertTo-BmNumericValue -Value $Talkgroup -Label 'Talkgroup' -Maximum $script:BmMaximumDmrId
            $method = 'DELETE'
            $uri = "$baseUri/talkgroup/$ApiSlot/$group"
            $requiresReadback = $true
            $expectedPresence = $false
        }
        'DropDynamic' {
            $method = 'GET'
            $uri = "$baseUri/action/dropDynamicGroups/$ApiSlot"
            $requiresReadback = $true
            $isAction = $true
        }
        'DropCallRoute' {
            $method = 'GET'
            $uri = "$baseUri/action/dropCallRoute/$ApiSlot"
            $requiresReadback = $true
            $isAction = $true
        }
    }

    return [pscustomobject][ordered]@{
        plan_id = $planId
        planned_at_utc = $plannedAtUtc
        action = $Action
        method = $method
        uri = $uri
        body = $body
        device_id = [string]$deviceNumber
        api_slot = if ($hasApiSlot) { $ApiSlot } else { $null }
        talkgroup = if ($PSBoundParameters.ContainsKey('Talkgroup')) { [uint32]$Talkgroup } else { $null }
        expected_presence = $expectedPresence
        requires_readback = $requiresReadback
        is_action = $isAction
        after_mutation_request_id = if ($hasAfterMutationRequestId) { $AfterMutationRequestId } else { $null }
    }
}

function New-BmStaticReconciliationPlans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ProfileState,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2)][int]$ApiSlot,
        [Parameter()][uint32[]]$ManagedTalkgroups = @(),
        [Parameter()][uint32[]]$DesiredTalkgroups = @()
    )

    $profileParseState = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'parse_state')
    $profileDeviceId = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'device_id')
    $profileObservationId = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'observation_id')
    if ($profileParseState -cne 'known' -or $profileDeviceId -cne ([string]$DeviceId) -or
        [string]::IsNullOrWhiteSpace($profileObservationId) -or
        -not (Test-BmObjectHasProperty -InputObject $ProfileState -Name 'static_subscriptions')) { return @() }
    $staticSubscriptions = Get-BmObjectProperty -InputObject $ProfileState -Name 'static_subscriptions'
    if ($staticSubscriptions -isnot [array]) { return @() }
    $normalizedSubscriptions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($subscription in $staticSubscriptions) {
        if ($null -eq $subscription -or
            -not (Test-BmObjectHasProperty -InputObject $subscription -Name 'slot') -or
            -not (Test-BmObjectHasProperty -InputObject $subscription -Name 'talkgroup')) { return @() }
        try {
            $subscriptionSlot = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $subscription -Name 'slot') `
                -Label 'Profile slot' -Maximum 2 -AllowZero
            $subscriptionTalkgroup = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $subscription -Name 'talkgroup') `
                -Label 'Profile talkgroup' -Maximum $script:BmMaximumDmrId
        } catch {
            return @()
        }
        $normalizedSubscriptions.Add([pscustomobject]@{ slot = [int]$subscriptionSlot; talkgroup = [uint32]$subscriptionTalkgroup })
    }
    $managed = @($ManagedTalkgroups | ForEach-Object { [uint32](ConvertTo-BmNumericValue -Value $_ -Label 'ManagedTalkgroup' -Maximum $script:BmMaximumDmrId) } | Select-Object -Unique)
    $desired = @($DesiredTalkgroups | ForEach-Object { [uint32](ConvertTo-BmNumericValue -Value $_ -Label 'DesiredTalkgroup' -Maximum $script:BmMaximumDmrId) } | Select-Object -Unique)
    $ownedCurrent = @($normalizedSubscriptions | Where-Object {
        $_.slot -eq $ApiSlot -and $managed -contains [uint32]$_.talkgroup
    } | ForEach-Object { [uint32]$_.talkgroup } | Select-Object -Unique)
    $result = New-Object 'System.Collections.Generic.List[object]'

    foreach ($group in $desired) {
        $present = @($normalizedSubscriptions | Where-Object {
            $_.slot -eq $ApiSlot -and [uint32]$_.talkgroup -eq $group
        }).Count -gt 0
        if (-not $present) {
            $result.Add((New-BmApiRequestPlan -Action AddStatic -DeviceId $DeviceId -ApiSlot $ApiSlot -Talkgroup $group))
        }
    }
    foreach ($group in $ownedCurrent) {
        if ($desired -notcontains $group) {
            $result.Add((New-BmApiRequestPlan -Action RemoveStatic -DeviceId $DeviceId -ApiSlot $ApiSlot -Talkgroup $group))
        }
    }
    return $result.ToArray()
}

function Read-BmApiTokenFilePrivate {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { throw 'BM API token file does not exist.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $token = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s') {
        throw 'BM API token file must contain exactly one non-empty token line.'
    }
    return $token
}

function Get-BmHttpOutcomeStatePrivate {
    param(
        [Parameter()][object]$StatusCode,
        [Parameter(Mandatory = $true)][bool]$RequiresReadback
    )

    if ($null -eq $StatusCode) {
        return 'transport_outcome_unknown'
    }
    $status = [int]$StatusCode
    if ($status -eq 202) { return 'accepted_awaiting_readback' }
    if ($status -ge 200 -and $status -lt 300) {
        if ($RequiresReadback) { return 'success_awaiting_readback' }
        return 'read_response_received'
    }
    if ($status -eq 429) { return 'rate_limited_re_read_before_retry' }
    if ($status -ge 500) { return 'server_outcome_uncertain_readback_required' }
    if ($status -ge 400) { return 'request_rejected' }
    return 'unexpected_http_status'
}

function ConvertTo-BmSafeTransportResponsePrivate {
    param(
        [Parameter()][AllowNull()][object]$Response,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $statusValue = Get-BmObjectProperty -InputObject $Response -Name 'StatusCode'
    $safeStatus = $null
    if ($null -ne $statusValue) {
        $parsedStatus = 0
        if ([int]::TryParse([string]$statusValue, [ref]$parsedStatus) -and $parsedStatus -ge 100 -and $parsedStatus -le 599) {
            $safeStatus = $parsedStatus
        }
    }
    $bodyValue = Get-BmObjectProperty -InputObject $Response -Name 'Body'
    $safeBody = $null
    if ($null -ne $bodyValue) {
        if ($bodyValue -is [string]) {
            $safeBody = [string]$bodyValue
        } else {
            try {
                $safeBody = ConvertTo-Json -InputObject $bodyValue -Depth 12 -Compress -ErrorAction Stop
            } catch {
                $safeBody = '[UNSERIALIZABLE RESPONSE BODY]'
            }
        }
        if (-not [string]::IsNullOrEmpty($Token)) {
            $safeBody = $safeBody.Replace($Token, '[REDACTED]')
        }
    }
    return [pscustomobject][ordered]@{
        status_code = $safeStatus
        body = $safeBody
    }
}

function Invoke-BmApiRequestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$ApiTokenFile,
        [Parameter(Mandatory = $true)][scriptblock]$Transport
    )

    if ([string]$Plan.uri -notmatch '^https://api\.brandmeister\.network/v2/device/[0-9]+/') {
        throw 'Request plan host/path is outside the fixed BrandMeister v2 device API.'
    }
    $token = Read-BmApiTokenFilePrivate -Path $ApiTokenFile
    $headers = [ordered]@{
        Accept = 'application/json'
        Authorization = "Bearer $token"
        'Cache-Control' = 'no-store'
    }
    $request = [pscustomobject][ordered]@{
        Method = [string]$Plan.method
        Uri = [string]$Plan.uri
        Headers = $headers
        ContentType = if ($null -ne $Plan.body) { 'application/json' } else { $null }
        Body = $Plan.body
        IsAction = [bool]$Plan.is_action
    }
    $requestStartedAtUtc = [DateTime]::UtcNow
    try {
        try {
            $transportResponse = & $Transport $request
            $response = ConvertTo-BmSafeTransportResponsePrivate -Response $transportResponse -Token $token
        } catch {
            $response = [pscustomobject][ordered]@{ status_code = $null; body = $null }
        }
    } finally {
        $token = $null
        $headers.Authorization = 'Bearer [REDACTED]'
    }
    return [pscustomobject][ordered]@{
        response = $response
        request_id = [string]$Plan.plan_id
        plan_action = [string]$Plan.action
        device_id = [string]$Plan.device_id
        after_mutation_request_id = [string]$Plan.after_mutation_request_id
        request_started_at_utc = $requestStartedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        request_completed_at_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        result_state = Get-BmHttpOutcomeStatePrivate -StatusCode $response.status_code -RequiresReadback ([bool]$Plan.requires_readback)
        confirmation = if ([bool]$Plan.requires_readback) { 'readback_required' } else { 'not_a_mutation' }
    }
}

function Get-BmStaticMutationReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$ProfileState,
        [Parameter(Mandatory = $true)][object]$MutationInvocation
    )

    $readbackState = 'unknown'
    $reason = ''
    $planAction = [string](Get-BmObjectProperty -InputObject $Plan -Name 'action')
    $planId = [string](Get-BmObjectProperty -InputObject $Plan -Name 'plan_id')
    $planDeviceId = [string](Get-BmObjectProperty -InputObject $Plan -Name 'device_id')
    $planApiSlot = Get-BmObjectProperty -InputObject $Plan -Name 'api_slot'
    $planTalkgroup = Get-BmObjectProperty -InputObject $Plan -Name 'talkgroup'
    $planExpectedPresence = Get-BmObjectProperty -InputObject $Plan -Name 'expected_presence'
    $profileParseState = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'parse_state')
    $profileDeviceId = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'device_id')
    $profileObservationId = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'observation_id')
    $profileObservedAtUtc = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'observed_at_utc')
    $profileRequestStartedAtUtc = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'request_started_at_utc')
    $profileAfterMutationRequestId = [string](Get-BmObjectProperty -InputObject $ProfileState -Name 'after_mutation_request_id')
    $mutationRequestId = [string](Get-BmObjectProperty -InputObject $MutationInvocation -Name 'request_id')
    $mutationDeviceId = [string](Get-BmObjectProperty -InputObject $MutationInvocation -Name 'device_id')
    $mutationPlanAction = [string](Get-BmObjectProperty -InputObject $MutationInvocation -Name 'plan_action')
    $mutationOutcomePresent = Test-BmObjectHasProperty -InputObject $MutationInvocation -Name 'result_state'
    $mutationOutcome = [string](Get-BmObjectProperty -InputObject $MutationInvocation -Name 'result_state')
    $mutationCompletedAtUtc = [string](Get-BmObjectProperty -InputObject $MutationInvocation -Name 'request_completed_at_utc')
    $staticSubscriptionsPresent = Test-BmObjectHasProperty -InputObject $ProfileState -Name 'static_subscriptions'
    $staticSubscriptions = Get-BmObjectProperty -InputObject $ProfileState -Name 'static_subscriptions'

    if ([string]::IsNullOrWhiteSpace($planId) -or [string]::IsNullOrWhiteSpace($planDeviceId) -or
        -not (Test-BmObjectHasProperty -InputObject $Plan -Name 'api_slot') -or
        -not (Test-BmObjectHasProperty -InputObject $Plan -Name 'talkgroup') -or
        -not (Test-BmObjectHasProperty -InputObject $Plan -Name 'expected_presence')) {
        $reason = 'mutation_plan_scope_missing'
    } elseif ($planAction -notin @('AddStatic', 'RemoveStatic')) {
        $reason = 'action_requires_other_readback'
    } elseif ($profileParseState -cne 'known') {
        $reason = 'profile_schema_unrecognized'
    } elseif ([string]::IsNullOrWhiteSpace($profileDeviceId) -or $profileDeviceId -cne $planDeviceId) {
        $reason = 'profile_device_mismatch'
    } elseif (-not $staticSubscriptionsPresent -or $staticSubscriptions -isnot [array]) {
        $reason = 'profile_schema_unrecognized'
    } elseif ([string]::IsNullOrWhiteSpace($mutationDeviceId) -or $mutationDeviceId -cne $planDeviceId -or
        $mutationPlanAction -cne $planAction) {
        $reason = 'mutation_request_scope_mismatch'
    } elseif ([string]::IsNullOrWhiteSpace($mutationRequestId) -or $mutationRequestId -cne $planId) {
        $reason = 'mutation_request_mismatch'
    } elseif (-not $mutationOutcomePresent) {
        $reason = 'mutation_outcome_missing'
    } elseif ($mutationOutcome -in @('request_rejected', 'unexpected_http_status', 'not_a_mutation')) {
        $reason = 'mutation_request_not_accepted_for_readback_confirmation'
    } elseif ($profileAfterMutationRequestId -cne $planId) {
        $reason = 'profile_not_linked_to_mutation_request'
    } elseif ([string]::IsNullOrWhiteSpace($profileObservationId)) {
        $reason = 'profile_observation_id_missing'
    } elseif ([string]::IsNullOrWhiteSpace($profileRequestStartedAtUtc)) {
        $reason = 'profile_request_start_missing'
    } else {
        $planApiSlotNumber = [uint64]0
        $planTalkgroupNumber = [uint64]0
        try {
            $planApiSlotNumber = ConvertTo-BmNumericValue -Value $planApiSlot -Label 'ApiSlot' -Maximum 2 -AllowZero
            $planTalkgroupNumber = ConvertTo-BmNumericValue -Value $planTalkgroup -Label 'Talkgroup' -Maximum $script:BmMaximumDmrId
        } catch {
            $reason = 'mutation_plan_scope_invalid'
        }

        $mutationCompletedAt = [DateTime]::MinValue
        $profileRequestStartedAt = [DateTime]::MinValue
        $profileObservedAt = [DateTime]::MinValue
        $mutationTimeParsed = [DateTime]::TryParse($mutationCompletedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$mutationCompletedAt)
        $profileStartTimeParsed = [DateTime]::TryParse($profileRequestStartedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$profileRequestStartedAt)
        $profileTimeParsed = [DateTime]::TryParse($profileObservedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$profileObservedAt)
        if ([string]::IsNullOrEmpty($reason) -and
            (-not $mutationTimeParsed -or -not $profileStartTimeParsed -or -not $profileTimeParsed -or
                $profileRequestStartedAt -le $mutationCompletedAt -or $profileObservedAt -lt $profileRequestStartedAt)) {
            $reason = 'profile_observation_not_after_mutation'
        }

        $present = $false
        if ([string]::IsNullOrEmpty($reason)) {
            foreach ($subscription in $staticSubscriptions) {
                if ($null -eq $subscription -or
                    -not (Test-BmObjectHasProperty -InputObject $subscription -Name 'slot') -or
                    -not (Test-BmObjectHasProperty -InputObject $subscription -Name 'talkgroup')) {
                    $reason = 'profile_schema_unrecognized'
                    break
                }
                try {
                    $subscriptionSlot = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $subscription -Name 'slot') `
                        -Label 'Profile slot' -Maximum 2 -AllowZero
                    $subscriptionTalkgroup = ConvertTo-BmNumericValue -Value (Get-BmObjectProperty -InputObject $subscription -Name 'talkgroup') `
                        -Label 'Profile talkgroup' -Maximum $script:BmMaximumDmrId
                } catch {
                    $reason = 'profile_schema_unrecognized'
                    break
                }
                if ($subscriptionSlot -eq $planApiSlotNumber -and $subscriptionTalkgroup -eq $planTalkgroupNumber) {
                    $present = $true
                }
            }
        }

        if ([string]::IsNullOrEmpty($reason)) {
            if ([bool]$planExpectedPresence -eq $present) {
                $readbackState = 'confirmed'
                $reason = 'profile_matches_requested_state'
            } else {
                $readbackState = 'pending'
                $reason = 'profile_does_not_yet_match_requested_state'
            }
        }
    }

    return [pscustomobject][ordered]@{
        state = $readbackState
        reason = $reason
        plan_id = $planId
        device_id = $profileDeviceId
        observation_id = $profileObservationId
        request_started_at_utc = $profileRequestStartedAtUtc
        observed_at_utc = $profileObservedAtUtc
    }
}

function Resolve-BmMutationConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][int]$HttpStatusCode,
        [Parameter()][object]$Readback
    )

    if (-not [bool](Get-BmObjectProperty -InputObject $Plan -Name 'requires_readback')) {
        return [pscustomobject][ordered]@{
            state = 'not_applicable'; state_observed = 'not_applicable'; mutation_outcome = 'not_applicable'; reason = 'read_only_request'
        }
    }
    if ($null -eq $Readback) {
        return [pscustomobject][ordered]@{
            state = 'unknown'; state_observed = 'unknown'; mutation_outcome = 'unknown'; reason = 'readback_missing'
        }
    }
    if (-not (Test-BmObjectHasProperty -InputObject $Readback -Name 'plan_id') -or
        -not (Test-BmObjectHasProperty -InputObject $Readback -Name 'device_id') -or
        -not (Test-BmObjectHasProperty -InputObject $Readback -Name 'observation_id') -or
        -not (Test-BmObjectHasProperty -InputObject $Readback -Name 'request_started_at_utc') -or
        -not (Test-BmObjectHasProperty -InputObject $Readback -Name 'observed_at_utc') -or
        [string](Get-BmObjectProperty -InputObject $Readback -Name 'plan_id') -cne [string](Get-BmObjectProperty -InputObject $Plan -Name 'plan_id') -or
        [string](Get-BmObjectProperty -InputObject $Readback -Name 'device_id') -cne [string](Get-BmObjectProperty -InputObject $Plan -Name 'device_id') -or
        [string]::IsNullOrWhiteSpace([string](Get-BmObjectProperty -InputObject $Readback -Name 'observation_id')) -or
        [string]::IsNullOrWhiteSpace([string](Get-BmObjectProperty -InputObject $Readback -Name 'request_started_at_utc')) -or
        [string]::IsNullOrWhiteSpace([string](Get-BmObjectProperty -InputObject $Readback -Name 'observed_at_utc'))) {
        return [pscustomobject][ordered]@{
            state = 'unknown'; state_observed = 'unknown'; mutation_outcome = 'unknown'; reason = 'readback_scope_or_request_mismatch'
        }
    }
    $readbackState = [string](Get-BmObjectProperty -InputObject $Readback -Name 'state')
    if ($HttpStatusCode -ge 400 -and $HttpStatusCode -lt 500) {
        return [pscustomobject][ordered]@{
            state = 'unknown'; state_observed = $readbackState; mutation_outcome = 'rejected';
            reason = 'mutation_rejected_server_state_observed'
        }
    }
    if ($HttpStatusCode -lt 200 -or $HttpStatusCode -ge 300) {
        return [pscustomobject][ordered]@{
            state = 'unknown'; state_observed = $readbackState; mutation_outcome = 'uncertain';
            reason = if ($HttpStatusCode -eq 202) { 'accepted_response_requires_confirmation' } else { 'mutation_outcome_uncertain' }
        }
    }
    if ($readbackState -ceq 'confirmed') {
        return [pscustomobject][ordered]@{
            state = 'confirmed'; state_observed = 'confirmed'; mutation_outcome = 'accepted'; reason = 'server_readback_matches'
        }
    }
    if ($readbackState -ceq 'pending') {
        return [pscustomobject][ordered]@{
            state = 'pending'; state_observed = 'pending'; mutation_outcome = 'accepted'; reason = 'server_readback_not_yet_matching'
        }
    }
    return [pscustomobject][ordered]@{
        state = 'unknown'; state_observed = $readbackState; mutation_outcome = 'accepted'; reason = 'readback_unconfirmed'
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-BmDeviceProfile',
    'Get-BmStaticMutationReadback',
    'Invoke-BmApiRequestPlan',
    'New-BmApiRequestPlan',
    'New-BmStaticReconciliationPlans',
    'Resolve-BmMutationConfirmation'
)
