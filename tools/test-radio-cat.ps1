Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\ui\windows\RadioCat.psm1'
Import-Module -Name $modulePath -Force

$script:assertionCount = 0
function Assert-RadioCatTest {
    param([bool]$Condition, [string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "FAILED: $Message" }
}

function Assert-RadioCatThrows {
    param([scriptblock]$Action, [string]$Message)
    $script:assertionCount++
    try { & $Action | Out-Null } catch { return }
    throw "FAILED: expected an exception: $Message"
}

function New-RadioCatSerialPortLike {
    param([bool]$CloseThrows = $false, [bool]$DisposeThrows = $false)
    $bytes = New-Object 'System.Collections.Generic.Queue[int]'
    $writes = New-Object 'System.Collections.Generic.List[string]'
    $serialLike = [pscustomobject]@{
        IsOpen = $false
        Encoding = $null
        Handshake = $null
        DtrEnable = $true
        RtsEnable = $true
        ReadTimeout = 0
        WriteTimeout = 0
        Bytes = $bytes
        Writes = $writes
        CloseThrows = $CloseThrows
        DisposeThrows = $DisposeThrows
        Disposed = $false
    }
    $serialLike | Add-Member -MemberType ScriptMethod -Name Open -Value { $this.IsOpen = $true }
    $serialLike | Add-Member -MemberType ScriptMethod -Name DiscardInBuffer -Value { $this.Bytes.Clear() }
    $serialLike | Add-Member -MemberType ScriptMethod -Name ReadByte -Value {
        if ($this.Bytes.Count -eq 0) { throw [System.TimeoutException]::new('Fake serial byte queue is empty.') }
        return $this.Bytes.Dequeue()
    }
    $serialLike | Add-Member -MemberType ScriptMethod -Name Write -Value { param([string]$Value) $this.Writes.Add($Value) }
    $serialLike | Add-Member -MemberType ScriptMethod -Name Close -Value {
        if ($this.CloseThrows) { throw [System.IO.IOException]::new('Fake serial Close failure.') }
        $this.IsOpen = $false
    }
    $serialLike | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
        if ($this.DisposeThrows) { throw [System.IO.IOException]::new('Fake serial Dispose failure.') }
    }
    return $serialLike
}

function New-RadioCatFakeState {
    param(
        [string]$RadioId = '0840',
        [bool]$AutoInformation = $false,
        [int]$TxState = 0,
        [int[]]$TxSequence = @(),
        [string]$PowerPath = '2',
        [int]$PowerWatts = 25,
        [string]$MainMode = '4',
        [string]$SubMode = '4',
        [string]$AsyncBeforeMd0 = '',
        [bool]$RejectModeWrite = $false,
        [bool]$RejectPowerWrite = $false,
        [bool]$RejectFrequencyWrite = $false,
        [bool]$CloseThrows = $false,
        [string]$NoResponseFor = ''
    )
    $txResponseQueue = New-Object 'System.Collections.Generic.Queue[int]'
    foreach ($stateValue in $TxSequence) { $txResponseQueue.Enqueue($stateValue) }
    return @{
        radio_id = $RadioId
        ai = $AutoInformation
        tx = $TxState
        tx_sequence = $txResponseQueue
        power_path = $PowerPath
        power_watts = $PowerWatts
        modes = @{ '0' = $MainMode; '1' = $SubMode }
        async_before_md0 = $AsyncBeforeMd0
        frequency_main = '014250000'
        frequency_sub = '014300000'
        reject_mode_write = $RejectModeWrite
        reject_power_write = $RejectPowerWrite
        reject_frequency_write = $RejectFrequencyWrite
        close_throws = $CloseThrows
        no_response_for = $NoResponseFor
        opened = $false
        closed = $false
        writes = New-Object 'System.Collections.Generic.List[string]'
        responses = New-Object 'System.Collections.Generic.Queue[string]'
    }
}

function New-RadioCatFakeTransport {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $open = { $State.opened = $true }.GetNewClosure()
    $clearInput = { }.GetNewClosure()
    $setTimeout = { param([int]$RemainingMs) }.GetNewClosure()
    $writeFrame = {
        param([string]$Frame)
        $State.writes.Add($Frame)
        if ($State.no_response_for -ceq $Frame) { return }
        switch -Regex ($Frame) {
            '^ID;$' { $State.responses.Enqueue("ID$($State.radio_id);"); break }
            '^AI;$' { $aiCode = if ($State.ai) { '1' } else { '0' }; $State.responses.Enqueue("AI$aiCode;"); break }
            '^TX;$' {
                $txValue = if ($State.tx_sequence.Count -gt 0) { $State.tx_sequence.Dequeue() } else { $State.tx }
                $State.responses.Enqueue("TX$txValue;")
                break
            }
            '^FA;$' { $State.responses.Enqueue("FA$($State.frequency_main);"); break }
            '^FB;$' { $State.responses.Enqueue("FB$($State.frequency_sub);"); break }
            '^MD([01]);$' {
                $sideCode = [regex]::Match($Frame, '^MD([01]);$').Groups[1].Value
                if ($sideCode -ceq '0' -and $State.async_before_md0) {
                    $State.responses.Enqueue($State.async_before_md0)
                    $State.async_before_md0 = ''
                }
                $State.responses.Enqueue("MD$sideCode$($State.modes[$sideCode]);")
                break
            }
            '^MD([01])([0-9A-I]);$' {
                if (-not $State.reject_mode_write) {
                    $match = [regex]::Match($Frame, '^MD([01])([0-9A-I]);$')
                    $State.modes[$match.Groups[1].Value] = $match.Groups[2].Value
                }
                break
            }
            '^PC;$' { $State.responses.Enqueue("PC$($State.power_path)$('{0:D3}' -f $State.power_watts);"); break }
            '^PC([12])([0-9]{3});$' {
                if (-not $State.reject_power_write) {
                    $match = [regex]::Match($Frame, '^PC([12])([0-9]{3});$')
                    $State.power_path = $match.Groups[1].Value
                    $State.power_watts = [int]$match.Groups[2].Value
                }
                break
            }
            '^FA([0-9]{9});$' {
                $match = [regex]::Match($Frame, '^FA([0-9]{9});$')
                if (-not $State.reject_frequency_write) { $State.frequency_main = $match.Groups[1].Value }
                break
            }
            default { throw "Fake observed an unapproved CAT command: $Frame" }
        }
    }.GetNewClosure()
    $readFrame = {
        param([int]$RemainingMs)
        if ($State.responses.Count -eq 0) { return $null }
        return $State.responses.Dequeue()
    }.GetNewClosure()
    $close = {
        if ($State.close_throws) { throw [System.IO.IOException]::new('Fake transport Close failure.') }
        $State.closed = $true
    }.GetNewClosure()

    return [pscustomobject]@{
        Open = $open
        ClearInput = $clearInput
        SetTimeout = $setTimeout
        WriteFrame = $writeFrame
        ReadFrame = $readFrame
        Close = $close
    }
}

function Invoke-RadioCatFake {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [string]$PortName = 'COM11',
        [string]$HriPortName = 'COM5',
        [string]$Side = 'Main',
        [string]$Mode = 'FM',
        [int]$PowerWatts = 25,
        [long]$FrequencyHz = 14250000
    )
    $transport = New-RadioCatFakeTransport -State $State
    $arguments = @{
        Operation = $Operation
        PortName = $PortName
        PortRole = 'CAT-1'
        HriPortName = $HriPortName
        TimeoutMs = 2500
        Transport = $transport
    }
    if ($Operation -ceq 'setMode') { $arguments.Side = $Side; $arguments.Mode = $Mode }
    if ($Operation -ceq 'setPower') { $arguments.PowerWatts = $PowerWatts }
    if ($Operation -ceq 'setFrequency') { $arguments.Side = 'Main'; $arguments.FrequencyHz = $FrequencyHz }
    return Invoke-Ftx1CatOperation @arguments
}

Assert-RadioCatTest ((New-Ftx1CatModeCommand -Side Main -Mode 'C4FM-DN') -ceq 'MD0H;') 'C4FM-DN uses the documented H mode code.'
Assert-RadioCatTest ((New-Ftx1CatModeCommand -Side Sub -Mode 'C4FM-VW') -ceq 'MD1I;') 'C4FM-VW uses the documented I mode code.'
Assert-RadioCatTest ((New-Ftx1CatModeCommand -Side Main -Mode 'FM') -ceq 'MD04;') 'FM uses the documented 4 mode code.'
Assert-RadioCatTest ((New-Ftx1CatModeCommand -Side 'main' -Mode 'fm') -ceq 'MD04;') 'Lowercase public mode arguments are normalized to MAIN FM.'
Assert-RadioCatTest ((New-Ftx1CatFrequencyCommand -FrequencyHz 14250000) -ceq 'FA014250000;') 'MAIN frequency is formatted as a fixed nine-digit Hz value.'
Assert-RadioCatThrows { New-Ftx1CatFrequencyCommand -FrequencyHz 29999 } 'MAIN frequency below the documented minimum is rejected.'
Assert-RadioCatTest ((New-Ftx1CatPowerCommand -PowerPath 'FieldHead' -Watts 10) -ceq 'PC1010;') 'FieldHead power command has one path digit and three watt digits.'
Assert-RadioCatTest ((New-Ftx1CatPowerCommand -PowerPath 'Spa1' -Watts 25) -ceq 'PC2025;') 'SPA-1 25 W command is formed exactly.'
Assert-RadioCatTest ((New-Ftx1CatPowerCommand -PowerPath 'fieldhead' -Watts 10) -ceq 'PC1010;') 'Lowercase FieldHead still selects power path 1.'
Assert-RadioCatThrows { New-Ftx1CatPowerCommand -PowerPath 'FieldHead' -Watts 25 } 'FieldHead power above 10 W is rejected.'
Assert-RadioCatThrows { New-Ftx1CatPowerCommand -PowerPath 'Spa1' -Watts 51 } 'App power above 50 W is rejected without clamping.'

$serialLike = New-RadioCatSerialPortLike
foreach ($character in 'ID0840;'.ToCharArray()) { $serialLike.Bytes.Enqueue([int][char]$character) }
$serialFactory = {
    param([object]$SerialPortLike)
    New-Ftx1CatSerialTransport -PortName 'FAKE-NO-HARDWARE' -BaudRate 38400 -StopBits Two -TimeoutMs 500 -SerialPortOverride $SerialPortLike
}
$serialAdapter = & (Get-Module RadioCat) $serialFactory $serialLike
& $serialAdapter.Open
$adapterFrame = & $serialAdapter.ReadFrame 500
Assert-RadioCatTest ($adapterFrame -ceq 'ID0840;' -and $serialLike.ReadTimeout -gt 0) 'Production serial adapter ReadFrame reads a complete frame from a SerialPort-like fake.'
Assert-RadioCatTest (-not $serialLike.RtsEnable -and -not $serialLike.DtrEnable) 'Production serial adapter forces RTS and DTR off.'
& $serialAdapter.Close
Assert-RadioCatTest (-not $serialLike.IsOpen -and $serialLike.Disposed) 'Production serial adapter closes and disposes its short-lived port.'

$closeFailSerialLike = New-RadioCatSerialPortLike -CloseThrows $true
$closeFailAdapter = & (Get-Module RadioCat) $serialFactory $closeFailSerialLike
& $closeFailAdapter.Open
$adapterCloseThrew = $false
try { & $closeFailAdapter.Close } catch { $adapterCloseThrew = $true }
Assert-RadioCatTest ($adapterCloseThrew -and $closeFailSerialLike.Disposed) 'Production adapter still disposes the port when Close throws.'

$disposeFailSerialLike = New-RadioCatSerialPortLike -DisposeThrows $true
$disposeFailAdapter = & (Get-Module RadioCat) $serialFactory $disposeFailSerialLike
& $disposeFailAdapter.Open
$adapterDisposeThrew = $false
try { & $disposeFailAdapter.Close } catch { $adapterDisposeThrew = $true }
Assert-RadioCatTest ($adapterDisposeThrew -and $disposeFailSerialLike.Disposed) 'A Dispose failure is surfaced as a failed adapter cleanup.'

$parsedId = ConvertFrom-Ftx1CatFrame -Frame 'ID0840;' -ExpectedCommand ID
$parsedMode = ConvertFrom-Ftx1CatFrame -Frame 'MD0H;' -ExpectedCommand MD
$parsedPower = ConvertFrom-Ftx1CatFrame -Frame 'PC2025;' -ExpectedCommand PC
$parsedTx = ConvertFrom-Ftx1CatFrame -Frame 'TX2;' -ExpectedCommand TX
Assert-RadioCatTest ($parsedId.status -ceq 'ok' -and $parsedId.value.radio_id -ceq '0840') 'ID response is parsed exactly.'
Assert-RadioCatTest ($parsedMode.status -ceq 'ok' -and $parsedMode.value.mode -ceq 'C4FM-DN') 'MD response exposes the exact mode name.'
Assert-RadioCatTest ($parsedPower.status -ceq 'ok' -and $parsedPower.value.path -ceq 'Spa1' -and $parsedPower.value.watts -eq 25) 'PC response separates path and setting watts.'
Assert-RadioCatTest ($parsedTx.status -ceq 'ok' -and $parsedTx.value.state -eq 2) 'TX2 parses as radio TX active.'
Assert-RadioCatTest ((ConvertFrom-Ftx1CatFrame -Frame '?;' -ExpectedCommand PC).status -ceq 'radio_error') 'Radio ?; error is never accepted as a value.'
Assert-RadioCatTest ((ConvertFrom-Ftx1CatFrame -Frame 'MD0G;' -ExpectedCommand MD).status -ceq 'protocol_error') 'Reserved mode codes are rejected.'

$queryState = New-RadioCatFakeState
$query = Invoke-RadioCatFake -Operation query -State $queryState
Assert-RadioCatTest ($query.status -ceq 'confirmed' -and $query.observed.radio_id.value -ceq '0840') 'Query confirms the FTX-1 identity before returning CAT values.'
Assert-RadioCatTest ($query.observed.main_mode.value.mode -ceq 'FM' -and $query.observed.power.value.watts -eq 25) 'Query returns the live-read mode and CAT power setting.'
Assert-RadioCatTest ($query.observed.power.value.path -ceq 'Spa1' -and $query.capabilities.set_power.maximum_watts -eq 50) 'SPA-1 application capability is capped at 50 W.'
Assert-RadioCatTest ($query.source -ceq 'CAT test transport' -and $query.observed.power.source -ceq 'CAT test transport' -and $query.observed.power.updated_at_utc) 'Injected transport data is explicitly labeled as test data with a read time.'
Assert-RadioCatTest ($queryState.closed -and $query.cleanup_status -ceq 'closed') 'Query closes its short-lived serial session.'

$setPowerState = New-RadioCatFakeState
$setPower = Invoke-RadioCatFake -Operation setPower -State $setPowerState -PowerWatts 30
Assert-RadioCatTest ($setPower.status -ceq 'confirmed' -and $setPower.observed.power.value.watts -eq 30) 'Power setting is confirmed only after PC readback.'
Assert-RadioCatTest ($setPowerState.writes -contains 'PC2030;') 'Power write uses the active path and requested watts.'
Assert-RadioCatTest (-not ($setPowerState.writes -match '^TX[01];$')) 'No TX-set command is written.'
Assert-RadioCatTest ($setPowerState.closed) 'Power operation closes its serial session.'

$unchangedPowerState = New-RadioCatFakeState
$unchangedPower = Invoke-RadioCatFake -Operation setPower -State $unchangedPowerState -PowerWatts 25
Assert-RadioCatTest ($unchangedPower.status -ceq 'confirmed' -and @($unchangedPowerState.writes | Where-Object { $_ -ceq 'TX;' }).Count -eq 1) 'Same-value power confirmation skips the extra pre-write TX read because no set frame is sent.'

$unchangedModeState = New-RadioCatFakeState
$unchangedMode = Invoke-RadioCatFake -Operation setMode -State $unchangedModeState -Mode 'FM'
Assert-RadioCatTest ($unchangedMode.status -ceq 'confirmed' -and $unchangedMode.observed.main_mode.value.mode -ceq 'FM' -and
    -not ($unchangedModeState.writes -contains 'MD04;')) 'Same-value MAIN mode is confirmed by readback without sending a mode write.'

$unchangedFrequencyState = New-RadioCatFakeState
$unchangedFrequency = Invoke-RadioCatFake -Operation setFrequency -State $unchangedFrequencyState -FrequencyHz 14250000
Assert-RadioCatTest ($unchangedFrequency.status -ceq 'confirmed' -and $unchangedFrequency.observed.main_frequency_hz.value -eq [long]14250000 -and
    -not ($unchangedFrequencyState.writes -contains 'FA014250000;')) 'Same-value MAIN frequency is confirmed by readback without sending a frequency write.'

$txRaceState = New-RadioCatFakeState -TxSequence @(0, 2)
$txRace = Invoke-RadioCatFake -Operation setPower -State $txRaceState -PowerWatts 30
Assert-RadioCatTest ($txRace.status -ceq 'busy' -and $txRace.observed.tx_state.value -eq 2 -and -not ($txRaceState.writes -match '^PC[12][0-9]{3};$')) 'A fresh TX2 response immediately before a write blocks that write.'

$lowercaseModeState = New-RadioCatFakeState
$lowercaseMode = Invoke-RadioCatFake -Operation setMode -State $lowercaseModeState -Side 'main' -Mode 'fm'
Assert-RadioCatTest ($lowercaseMode.status -ceq 'confirmed' -and $lowercaseMode.observed.main_mode.value.mode -ceq 'FM') 'Lowercase FM request confirms the existing FM mode without selecting SUB.'

$fieldState = New-RadioCatFakeState -PowerPath '1' -PowerWatts 10
$fieldSet = Invoke-RadioCatFake -Operation setPower -State $fieldState -PowerWatts 25
Assert-RadioCatTest ($fieldSet.status -ceq 'rejected' -and $fieldSet.error_code -ceq 'power_out_of_range') 'FieldHead default 25 W is rejected instead of clamped.'
Assert-RadioCatTest (-not ($fieldState.writes -match '^PC1[0-9]{3};$')) 'Rejected FieldHead power never reaches the write command.'

$setModeState = New-RadioCatFakeState
$setMode = Invoke-RadioCatFake -Operation setMode -State $setModeState -Mode 'C4FM-DN'
Assert-RadioCatTest ($setMode.status -ceq 'confirmed' -and $setMode.observed.main_mode.value.mode -ceq 'C4FM-DN') 'Mode setting requires exact same-side readback.'
Assert-RadioCatTest ($setModeState.writes -contains 'MD0H;') 'C4FM-DN write is sent only after identity/TX/mode reads.'

$wrongIdentityState = New-RadioCatFakeState -RadioId '1234'
$wrongIdentity = Invoke-RadioCatFake -Operation setMode -State $wrongIdentityState -Mode 'FM-N'
Assert-RadioCatTest ($wrongIdentity.status -ceq 'identity_mismatch' -and $wrongIdentityState.writes.Count -eq 1) 'Wrong ID stops before mode or power commands.'

$busyState = New-RadioCatFakeState -TxState 2
$busy = Invoke-RadioCatFake -Operation setPower -State $busyState -PowerWatts 30
Assert-RadioCatTest ($busy.status -ceq 'busy' -and -not ($busyState.writes -match '^PC[12][0-9]{3};$')) 'TX2 blocks setting changes.'

$aiState = New-RadioCatFakeState -AutoInformation $true
$aiResult = Invoke-RadioCatFake -Operation setMode -State $aiState -Mode 'FM-N'
Assert-RadioCatTest ($aiResult.status -ceq 'confirmed' -and $aiResult.observed.auto_information_enabled.value) 'Auto Information is reported but does not block a strictly matched operation.'

$asyncState = New-RadioCatFakeState -AsyncBeforeMd0 'MD1H;'
$asyncResult = Invoke-RadioCatFake -Operation setMode -State $asyncState -Mode 'C4FM-DN'
Assert-RadioCatTest ($asyncResult.status -ceq 'confirmed' -and $asyncResult.observed.main_mode.value.mode -ceq 'C4FM-DN') 'A complete asynchronous response for the other side is skipped before matching MAIN readback.'

$setFrequencyState = New-RadioCatFakeState
$setFrequency = Invoke-RadioCatFake -Operation setFrequency -State $setFrequencyState -FrequencyHz 145500000
Assert-RadioCatTest ($setFrequency.status -ceq 'confirmed' -and $setFrequency.observed.main_frequency_hz.value -eq [long]145500000) 'MAIN FA frequency is confirmed only after exact Hz readback.'
Assert-RadioCatTest ($setFrequencyState.writes -contains 'FA145500000;') 'MAIN frequency write uses the official FA command exactly once.'

$frequencyMismatchState = New-RadioCatFakeState -RejectFrequencyWrite $true
$frequencyMismatch = Invoke-RadioCatFake -Operation setFrequency -State $frequencyMismatchState -FrequencyHz 145500000
Assert-RadioCatTest ($frequencyMismatch.status -ceq 'mismatch' -and $frequencyMismatch.observed.main_frequency_hz.value -eq [long]14250000) 'A MAIN frequency write is not confirmed when FA readback differs.'

$frequencyOutOfRangeState = New-RadioCatFakeState
$frequencyOutOfRange = Invoke-RadioCatFake -Operation setFrequency -State $frequencyOutOfRangeState -FrequencyHz 29999
Assert-RadioCatTest ($frequencyOutOfRange.status -ceq 'rejected' -and -not $frequencyOutOfRangeState.opened) 'Out-of-range FA is rejected before opening CAT.'

$powerOutOfRangeState = New-RadioCatFakeState
$powerOutOfRange = Invoke-RadioCatFake -Operation setPower -State $powerOutOfRangeState -PowerWatts 51
Assert-RadioCatTest ($powerOutOfRange.status -ceq 'rejected' -and -not $powerOutOfRangeState.opened) 'Out-of-range power is rejected before opening CAT.'

$closeFailureState = New-RadioCatFakeState -CloseThrows $true
$closeFailureResult = Invoke-RadioCatFake -Operation query -State $closeFailureState
Assert-RadioCatTest ($closeFailureResult.status -ceq 'unknown' -and $closeFailureResult.cleanup_status -ceq 'close_failed' -and $closeFailureResult.error_code -ceq 'serial_close_failed' -and $null -ne $closeFailureResult.observed.power.value) 'A failed cleanup prevents an overall confirmed result while preserving CAT readback.'
Assert-RadioCatTest (-not $closeFailureResult.capabilities.set_frequency.available -and -not $closeFailureResult.capabilities.set_mode.available -and -not $closeFailureResult.capabilities.set_power.available) 'A failed close clears every CAT write capability even when readback values are present.'

$portConflictState = New-RadioCatFakeState
$portConflictTransport = New-RadioCatFakeTransport -State $portConflictState
$portConflict = Invoke-Ftx1CatOperation -Operation query -PortName 'COM11' -PortRole CAT-1 -HriPortName '\\.\COM011' -Transport $portConflictTransport
Assert-RadioCatTest ($portConflict.status -ceq 'rejected' -and -not $portConflictState.opened) 'CAT port aliases matching the HRI port are rejected before open.'

$timeoutState = New-RadioCatFakeState -NoResponseFor 'PC;'
$timeout = Invoke-RadioCatFake -Operation query -State $timeoutState
Assert-RadioCatTest ($timeout.status -ceq 'unknown' -and $timeout.error_code -ceq 'timeout') 'No data before the deadline remains unknown.'
Assert-RadioCatTest (-not $timeout.capabilities.query.available -and -not $timeout.capabilities.set_frequency.available -and -not $timeout.capabilities.set_mode.available -and -not $timeout.capabilities.set_power.available) 'A timed out query does not leave a stale CAT write permit.'
Assert-RadioCatTest ($timeoutState.closed) 'Timeout still closes the short-lived session.'

$unsafeCommandState = New-RadioCatFakeState
$unsafeTransport = New-RadioCatFakeTransport -State $unsafeCommandState
$unsafe = Invoke-Ftx1CatOperation -Operation query -PortName COM11 -PortRole CAT-1 -HriPortName COM5 -Transport $unsafeTransport
Assert-RadioCatTest (-not ($unsafeCommandState.writes | Where-Object { $_ -match '^(TX[01]|EX|MX|PS|AC)' })) 'No PTT, EX, MOX, power switch, or tuner-start command is sent.'

Write-Output "PASS: $script:assertionCount CAT fake assertions (no physical serial ports opened)."
