function New-WirexChannelActivationState {
    return [pscustomobject][ordered]@{
        run_id = ''
        pending_by_request = @{}
        latest_request_by_slot = @{}
        request_sent_by_target = @{}
    }
}

function Reset-WirexChannelActivationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter()][AllowEmptyString()][string]$RunId = ''
    )
    $State.run_id = $RunId
    $State.pending_by_request = @{}
    $State.latest_request_by_slot = @{}
    $State.request_sent_by_target = @{}
    return $State
}

function Get-WirexChannelActivationSlotKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Slot
    )
    return ('{0}|slot:{1}' -f $RunId, $Slot)
}

function Get-WirexChannelActivationRequestKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RequestId
    )
    return ('{0}|request:{1}' -f $RunId, $RequestId)
}

function Get-WirexChannelActivationTargetKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ChannelKey,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Slot
    )
    return ('{0}|{1}|slot:{2}' -f $RunId, $ChannelKey, $Slot)
}

function Test-WirexChannelActivationTarget {
    param(
        [string]$RunId,
        [string]$RequestId,
        [string]$ChannelKey,
        [object]$DestinationId,
        [object]$Slot
    )
    if ([string]::IsNullOrWhiteSpace($RunId) -or $RunId.Length -gt 128 -or
        [string]::IsNullOrWhiteSpace($ChannelKey) -or $ChannelKey -cnotmatch '^group:([1-9][0-9]{0,7}):([12])$') { return $false }
    $requestGuid = [guid]::Empty
    if (-not [guid]::TryParse($RequestId, [ref]$requestGuid)) { return $false }
    $id = [uint64]0
    $slotNumber = 0
    if (-not [uint64]::TryParse([string]$DestinationId, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$id) -or $id -lt 1 -or $id -gt 16777215 -or $id -eq 4000 -or
        -not [int]::TryParse([string]$Slot, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$slotNumber) -or $slotNumber -notin @(1, 2)) { return $false }
    return ([uint64]$Matches[1] -eq $id -and [int]$Matches[2] -eq $slotNumber)
}

function Start-WirexChannelActivationRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][string]$ChannelKey,
        [Parameter(Mandatory = $true)][object]$DestinationId,
        [Parameter(Mandatory = $true)][object]$Slot
    )
    if ([string]$State.run_id -cne $RunId -or
        -not (Test-WirexChannelActivationTarget -RunId $RunId -RequestId $RequestId -ChannelKey $ChannelKey `
            -DestinationId $DestinationId -Slot $Slot)) { return $false }
    foreach ($pendingKey in @($State.pending_by_request.Keys)) {
        $pending = $State.pending_by_request[$pendingKey]
        if ([string]$pending.run_id -ceq $RunId -and -not [bool]$pending.timed_out) { return $false }
    }

    $slotNumber = [int]$Slot
    $slotKey = Get-WirexChannelActivationSlotKey -RunId $RunId -Slot $slotNumber
    $State.latest_request_by_slot[$slotKey] = $RequestId
    foreach ($pendingKey in @($State.pending_by_request.Keys)) {
        $pending = $State.pending_by_request[$pendingKey]
        if ([string]$pending.run_id -ceq $RunId -and [int]$pending.slot -eq $slotNumber -and
            [bool]$pending.timed_out -and [string]$pending.request_id -cne $RequestId) {
            [void]$State.pending_by_request.Remove($pendingKey)
        }
    }
    $requestKey = Get-WirexChannelActivationRequestKey -RunId $RunId -RequestId $RequestId
    $State.pending_by_request[$requestKey] = [pscustomobject][ordered]@{
        run_id = $RunId
        request_id = $RequestId
        channel_key = $ChannelKey
        destination_id = [uint64]$DestinationId
        slot = $slotNumber
        timed_out = $false
    }
    return $true
}

function Set-WirexChannelActivationRequestTimedOut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RequestId
    )
    if ([string]$State.run_id -cne $RunId) { return $false }
    $key = Get-WirexChannelActivationRequestKey -RunId $RunId -RequestId $RequestId
    if (-not $State.pending_by_request.ContainsKey($key)) { return $false }
    $State.pending_by_request[$key].timed_out = $true
    return $true
}

function Test-WirexChannelActivationPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter()][AllowEmptyString()][string]$ChannelKey = ''
    )
    if ([string]$State.run_id -cne $RunId) { return $false }
    foreach ($pending in $State.pending_by_request.Values) {
        if ([string]$pending.run_id -ceq $RunId -and -not [bool]$pending.timed_out -and
            (-not $ChannelKey -or [string]$pending.channel_key -ceq $ChannelKey)) { return $true }
    }
    return $false
}

function Complete-WirexChannelActivationRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'rejected', 'unsupported')][string]$Result,
        [Parameter()][AllowEmptyString()][string]$ActivationStatus = '',
        [Parameter()][object]$DestinationId,
        [Parameter()][object]$Slot,
        [Parameter()][object]$FramesSent,
        [Parameter()][bool]$Replayed = $false
    )
    if ([string]$State.run_id -cne $RunId) {
        return [pscustomobject][ordered]@{ matched = $false; current = $false; sent = $false; request = $null }
    }
    $requestKey = Get-WirexChannelActivationRequestKey -RunId $RunId -RequestId $RequestId
    if (-not $State.pending_by_request.ContainsKey($requestKey)) {
        return [pscustomobject][ordered]@{ matched = $false; current = $false; sent = $false; request = $null }
    }
    $pending = $State.pending_by_request[$requestKey]
    if ($Result -ceq 'ok') {
        $responseId = [uint64]0
        $responseSlot = 0
        $responseFrames = 0
        $validResponse = ($ActivationStatus -ceq 'request_sent' -and
            [uint64]::TryParse([string]$DestinationId, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$responseId) -and
            [int]::TryParse([string]$Slot, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$responseSlot) -and
            [int]::TryParse([string]$FramesSent, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$responseFrames) -and
            $responseId -eq [uint64]$pending.destination_id -and $responseSlot -eq [int]$pending.slot -and $responseFrames -eq 2)
        if (-not $validResponse) {
            [void]$State.pending_by_request.Remove($requestKey)
            $slotKey = Get-WirexChannelActivationSlotKey -RunId $RunId -Slot ([int]$pending.slot)
            $isLatest = ($State.latest_request_by_slot.ContainsKey($slotKey) -and
                [string]$State.latest_request_by_slot[$slotKey] -ceq $RequestId)
            if ($isLatest) { [void]$State.latest_request_by_slot.Remove($slotKey) }
            return [pscustomobject][ordered]@{ matched = $true; current = [bool]$isLatest; sent = $false; request = $pending }
        }
    }
    [void]$State.pending_by_request.Remove($requestKey)
    $slotKey = Get-WirexChannelActivationSlotKey -RunId $RunId -Slot ([int]$pending.slot)
    $isCurrent = ($State.latest_request_by_slot.ContainsKey($slotKey) -and
        [string]$State.latest_request_by_slot[$slotKey] -ceq $RequestId)
    if ($Result -ceq 'ok' -and $isCurrent) {
        foreach ($targetKey in @($State.request_sent_by_target.Keys)) {
            $sent = $State.request_sent_by_target[$targetKey]
            if ([string]$sent.run_id -ceq $RunId -and [int]$sent.slot -eq [int]$pending.slot) {
                [void]$State.request_sent_by_target.Remove($targetKey)
            }
        }
        $targetKey = Get-WirexChannelActivationTargetKey -RunId $RunId -ChannelKey ([string]$pending.channel_key) -Slot ([int]$pending.slot)
        $State.request_sent_by_target[$targetKey] = [pscustomobject][ordered]@{
            run_id = $RunId
            channel_key = [string]$pending.channel_key
            destination_id = [uint64]$pending.destination_id
            slot = [int]$pending.slot
            request_id = $RequestId
            activation_status = 'request_sent'
            frames_sent = 2
            replayed = [bool]$Replayed
            sent_utc = [DateTime]::UtcNow
        }
    }
    return [pscustomobject][ordered]@{ matched = $true; current = [bool]$isCurrent; sent = ([bool]($Result -ceq 'ok' -and $isCurrent)); request = $pending }
}

function Get-WirexChannelActivationRequestSent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ChannelKey,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Slot
    )
    if ([string]$State.run_id -cne $RunId) { return $null }
    $key = Get-WirexChannelActivationTargetKey -RunId $RunId -ChannelKey $ChannelKey -Slot $Slot
    if (-not $State.request_sent_by_target.ContainsKey($key)) { return $null }
    return $State.request_sent_by_target[$key]
}

function Clear-WirexChannelActivationSlot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Slot
    )
    if ([string]$State.run_id -cne $RunId) { return $false }
    foreach ($targetKey in @($State.request_sent_by_target.Keys)) {
        $sent = $State.request_sent_by_target[$targetKey]
        if ([string]$sent.run_id -ceq $RunId -and [int]$sent.slot -eq $Slot) {
            [void]$State.request_sent_by_target.Remove($targetKey)
        }
    }
    $slotKey = Get-WirexChannelActivationSlotKey -RunId $RunId -Slot $Slot
    [void]$State.latest_request_by_slot.Remove($slotKey)
    return $true
}

Export-ModuleMember -Function New-WirexChannelActivationState, Reset-WirexChannelActivationState,
    Start-WirexChannelActivationRequest, Set-WirexChannelActivationRequestTimedOut,
    Test-WirexChannelActivationPending, Complete-WirexChannelActivationRequest,
    Get-WirexChannelActivationRequestSent, Clear-WirexChannelActivationSlot
