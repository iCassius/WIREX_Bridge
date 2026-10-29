Set-StrictMode -Version 2.0

$script:Ftx1CatDefaultTimeoutMs = 2500
$script:Ftx1CatMaxTimeoutMs = 3000
$script:Ftx1CatMaxFrameLength = 64
$script:Ftx1CatBaudRates = @(4800, 9600, 19200, 38400, 115200)
$script:Ftx1CatModeByName = [ordered]@{
    'FM' = '4'
    'FM-N' = 'B'
    'C4FM-DN' = 'H'
    'C4FM-VW' = 'I'
}
$script:Ftx1CatModeByCode = @{
    '0' = 'UNUSED'
    '1' = 'LSB'
    '2' = 'USB'
    '3' = 'CW-U'
    '4' = 'FM'
    '5' = 'AM'
    '6' = 'RTTY-L'
    '7' = 'CW-L'
    '8' = 'DATA-L'
    '9' = 'RTTY-U'
    'A' = 'DATA-FM'
    'B' = 'FM-N'
    'C' = 'DATA-U'
    'D' = 'AM-N'
    'E' = 'PSK'
    'F' = 'DATA-FM-N'
    'H' = 'C4FM-DN'
    'I' = 'C4FM-VW'
}
$script:Ftx1CatVoiceModes = @('FM', 'FM-N', 'C4FM-DN', 'C4FM-VW')
$script:Ftx1CatSource = 'FTX-1 CAT-1'

function New-Ftx1CatModeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Main', 'Sub')]
        [string]$Side,
        [Parameter(Mandatory = $true)]
        [ValidateSet('FM', 'FM-N', 'C4FM-DN', 'C4FM-VW')]
        [string]$Mode
    )

    $canonicalSide = if ($Side -ieq 'Main') { 'Main' } else { 'Sub' }
    $canonicalMode = $null
    foreach ($candidateMode in $script:Ftx1CatModeByName.Keys) {
        if ([string]::Equals([string]$candidateMode, $Mode, [StringComparison]::OrdinalIgnoreCase)) {
            $canonicalMode = [string]$candidateMode
            break
        }
    }
    $sideCode = if ($canonicalSide -ceq 'Main') { '0' } else { '1' }
    $modeCode = [string]$script:Ftx1CatModeByName[$canonicalMode]
    return "MD$sideCode$modeCode;"
}

function New-Ftx1CatFrequencyCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(30000, 470000000)]
        [long]$FrequencyHz
    )

    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'FA{0:D9};', $FrequencyHz)
}

function New-Ftx1CatPowerCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('FieldHead', 'Spa1')]
        [string]$PowerPath,
        [Parameter(Mandatory = $true)]
        [ValidateRange(5, 50)]
        [int]$Watts
    )

    $canonicalPowerPath = if ($PowerPath -ieq 'FieldHead') { 'FieldHead' } else { 'Spa1' }
    $pathCode = if ($canonicalPowerPath -ceq 'FieldHead') { '1' } else { '2' }
    $maximum = if ($pathCode -ceq '1') { 10 } else { 50 }
    if ($Watts -gt $maximum) {
        throw [System.ArgumentOutOfRangeException]::new('Watts', "${canonicalPowerPath} 的应用功率范围为 5-$maximum W；不会自动钳位。")
    }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'PC{0}{1:D3};', $pathCode, $Watts)
}

function ConvertFrom-Ftx1CatFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Frame,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ID', 'AI', 'TX', 'FA', 'FB', 'MD', 'PC')]
        [string]$ExpectedCommand
    )

    $raw = $Frame
    if ($Frame -cne $Frame.Trim() -or $Frame.Length -gt $script:Ftx1CatMaxFrameLength) {
        return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'invalid_frame' }
    }
    if ($Frame -ceq '?;') {
        return [pscustomobject]@{ status = 'radio_error'; command = '?'; raw = $raw; value = $null; error_code = 'radio_rejected_command' }
    }

    $pattern = $null
    switch ($ExpectedCommand) {
        'ID' { $pattern = '^ID([0-9]{4});$' }
        'AI' { $pattern = '^AI([01]);$' }
        'TX' { $pattern = '^TX([012]);$' }
        'FA' { $pattern = '^FA([0-9]{9});$' }
        'FB' { $pattern = '^FB([0-9]{9});$' }
        'MD' { $pattern = '^MD([01])([0-9A-I]);$' }
        'PC' { $pattern = '^PC([12])([0-9]{3});$' }
    }
    $match = [regex]::Match($Frame, $pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'unexpected_response' }
    }

    $value = $null
    switch ($ExpectedCommand) {
        'ID' {
            $value = [pscustomobject]@{ radio_id = $match.Groups[1].Value }
        }
        'AI' {
            $value = [pscustomobject]@{ enabled = ($match.Groups[1].Value -ceq '1') }
        }
        'TX' {
            $value = [pscustomobject]@{ state = [int]$match.Groups[1].Value }
        }
        'FA' {
            $frequency = [long]0
            if (-not [long]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$frequency) -or
                $frequency -lt 30000 -or $frequency -gt 470000000) {
                return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'frequency_out_of_range' }
            }
            $value = [pscustomobject]@{ frequency_hz = $frequency }
        }
        'FB' {
            $frequency = [long]0
            if (-not [long]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$frequency) -or
                $frequency -lt 30000 -or $frequency -gt 470000000) {
                return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'frequency_out_of_range' }
            }
            $value = [pscustomobject]@{ frequency_hz = $frequency }
        }
        'MD' {
            $modeCode = $match.Groups[2].Value.ToUpperInvariant()
            if (-not $script:Ftx1CatModeByCode.ContainsKey($modeCode)) {
                return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'unknown_mode_code' }
            }
            $value = [pscustomobject]@{
                side = if ($match.Groups[1].Value -ceq '0') { 'Main' } else { 'Sub' }
                side_code = $match.Groups[1].Value
                mode_code = $modeCode
                mode = [string]$script:Ftx1CatModeByCode[$modeCode]
            }
        }
        'PC' {
            $path = $match.Groups[1].Value
            $watts = [int]$match.Groups[2].Value
            $maximum = if ($path -ceq '1') { 10 } else { 100 }
            if ($watts -lt 5 -or $watts -gt $maximum) {
                return [pscustomobject]@{ status = 'protocol_error'; command = $ExpectedCommand; raw = $raw; value = $null; error_code = 'power_out_of_range' }
            }
            $value = [pscustomobject]@{
                path = if ($path -ceq '1') { 'FieldHead' } else { 'Spa1' }
                path_code = $path
                watts = $watts
            }
        }
    }

    return [pscustomobject]@{ status = 'ok'; command = $ExpectedCommand; raw = $raw; value = $value; error_code = $null }
}

function Get-Ftx1CatPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-Ftx1CatTransportMethod {
    param(
        [Parameter(Mandatory = $true)][object]$Transport,
        [Parameter(Mandatory = $true)][string]$MethodName,
        [Parameter()][object[]]$Arguments = @(),
        [switch]$Optional
    )

    $method = Get-Ftx1CatPropertyValue -InputObject $Transport -Name $MethodName
    if ($null -eq $method) {
        if ($Optional) { return $null }
        throw [System.InvalidOperationException]::new("Fake/serial transport 缺少 $MethodName 方法。")
    }
    if ($method -isnot [scriptblock]) {
        throw [System.InvalidOperationException]::new("Fake/serial transport 的 $MethodName 必须是 ScriptBlock。")
    }
    return (& $method @Arguments)
}

function New-Ftx1CatSerialTransport {
    param(
        [Parameter(Mandatory = $true)][string]$PortName,
        [Parameter(Mandatory = $true)][int]$BaudRate,
        [Parameter(Mandatory = $true)][string]$StopBits,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter()][AllowNull()][object]$SerialPortOverride
    )

    if ($null -ne $SerialPortOverride) {
        $serial = $SerialPortOverride
    } else {
        $serial = New-Object System.IO.Ports.SerialPort(
            $PortName,
            $BaudRate,
            [System.IO.Ports.Parity]::None,
            8,
            [System.IO.Ports.StopBits]::$StopBits
        )
    }
    $serial.Encoding = [System.Text.Encoding]::ASCII
    $serial.Handshake = [System.IO.Ports.Handshake]::None
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.ReadTimeout = $TimeoutMs
    $serial.WriteTimeout = $TimeoutMs

    $open = { $serial.Open() }.GetNewClosure()
    $clearInput = { if ($serial.IsOpen) { $serial.DiscardInBuffer() } }.GetNewClosure()
    $setTimeout = {
        param([int]$RemainingMs)
        $bounded = [Math]::Max(1, [Math]::Min(3000, $RemainingMs))
        $serial.ReadTimeout = $bounded
        $serial.WriteTimeout = $bounded
    }.GetNewClosure()
    $writeFrame = {
        param([string]$Frame)
        $serial.Write($Frame)
    }.GetNewClosure()
    $maxFrameLength = [int]$script:Ftx1CatMaxFrameLength
    $readFrame = {
        param([int]$RemainingMs)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $builder = New-Object System.Text.StringBuilder
        while ($watch.ElapsedMilliseconds -lt $RemainingMs) {
            $remaining = [Math]::Max(1, $RemainingMs - [int]$watch.ElapsedMilliseconds)
            $serial.ReadTimeout = $remaining
            $byteValue = $serial.ReadByte()
            if ($byteValue -eq 59) {
                [void]$builder.Append(';')
                return $builder.ToString()
            }
            if ($byteValue -lt 0x20 -or $byteValue -gt 0x7e) {
                throw [System.IO.InvalidDataException]::new('CAT 响应含非 ASCII 可打印字节。')
            }
            [void]$builder.Append([char]$byteValue)
            if ($builder.Length -gt $maxFrameLength) {
                throw [System.IO.InvalidDataException]::new('CAT 响应超过帧长限制。')
            }
        }
        return $null
    }.GetNewClosure()
    $close = {
        $closeException = $null
        try {
            if ($serial.IsOpen) { $serial.Close() }
        } catch {
            $closeException = $_.Exception
        }
        try {
            $serial.Dispose()
        } catch {
            if ($null -eq $closeException) { $closeException = $_.Exception }
        }
        if ($null -ne $closeException) { throw $closeException }
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

function New-Ftx1CatObservedValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter()][AllowNull()][object]$UpdatedAtUtc,
        [Parameter()][AllowNull()][object]$Source = $script:Ftx1CatSource
    )
    if ($null -eq $Value) { $Source = $null; $UpdatedAtUtc = $null }
    return [pscustomobject]@{ value = $Value; source = $Source; updated_at_utc = $UpdatedAtUtc }
}

function New-Ftx1CatCapabilities {
    param(
        [Parameter()][AllowNull()][object]$PowerPath,
        [Parameter()][bool]$PowerReadable = $false,
        [Parameter()][bool]$PowerWritable = $false,
        [Parameter()][AllowNull()][object]$PowerUnavailableReason,
        [Parameter()][bool]$RadioAvailable = $false,
        [Parameter()][bool]$SettingsWritable = $false
    )
    $powerMax = $null
    if ($PowerPath -ceq 'FieldHead') { $powerMax = 10 }
    elseif ($PowerPath -ceq 'Spa1') { $powerMax = 50 }
    return [pscustomobject]@{
        query = [pscustomobject]@{ supported = $true; available = $RadioAvailable }
        set_frequency = [pscustomobject]@{
            supported = $true
            available = $SettingsWritable
            target_side = 'Main'
            minimum_hz = [long]30000
            maximum_hz = [long]470000000
            step_hz = [long]1
        }
        set_mode = [pscustomobject]@{
            supported = $true
            available = $SettingsWritable
            modes = @('FM', 'FM-N', 'C4FM-DN', 'C4FM-VW')
            target_side = 'Main or Sub, one side per operation'
        }
        set_power = [pscustomobject]@{
            supported = $true
            available = ($PowerReadable -and $PowerWritable -and $SettingsWritable)
            readable = $PowerReadable
            active_path = $PowerPath
            minimum_watts = if ($PowerReadable) { 5 } else { $null }
            maximum_watts = $powerMax
            step_watts = 1
            unavailable_reason = $PowerUnavailableReason
            value_semantics = 'CAT power setting; not measured RF output'
        }
        hri_mode = [pscustomobject]@{ supported = $false; available = $false; reason = 'No documented CAT command in Yaesu FTX-1 CAT manual 2512-D.' }
        node_mode = [pscustomobject]@{ supported = $false; available = $false; reason = 'No documented CAT command in Yaesu FTX-1 CAT manual 2512-D.' }
    }
}

function New-Ftx1CatResult {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$PortName,
        [Parameter()][AllowNull()][object]$Observed,
        [Parameter()][AllowNull()][object]$Prior,
        [Parameter()][AllowNull()][object]$Desired,
        [Parameter()][AllowNull()][object]$Capabilities,
        [Parameter()][AllowNull()][object]$UpdatedAtUtc,
        [Parameter()][AllowNull()][object]$ErrorCode,
        [Parameter()][AllowNull()][object]$ErrorMessage,
        [Parameter()][AllowNull()][object]$Source = $script:Ftx1CatSource,
        [Parameter()][string]$CleanupStatus = 'not_opened',
        [Parameter()][AllowNull()][string]$StartedAtUtc
    )
    return [pscustomobject][ordered]@{
        schema_version = 1
        operation = $Operation
        status = $Status
        source = if ($null -ne $Observed -and $null -ne $UpdatedAtUtc) { $Source } else { $null }
        port_name = $PortName
        port_role = 'CAT-1'
        started_at_utc = $StartedAtUtc
        updated_at_utc = $UpdatedAtUtc
        desired = $Desired
        prior = $Prior
        observed = $Observed
        capabilities = $Capabilities
        cleanup_status = $CleanupStatus
        error_code = $ErrorCode
        error_message = $ErrorMessage
    }
}

function Normalize-Ftx1CatPortName {
    param([Parameter(Mandatory = $true)][string]$PortName)
    $normalized = $PortName.Trim().ToUpperInvariant()
    if ($normalized.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    if ($normalized -match '^COM0*([0-9]+)$') {
        return 'COM' + [int]$Matches[1]
    }
    return $normalized
}

function Get-Ftx1CatRemainingMs {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Watch, [Parameter(Mandatory = $true)][int]$TimeoutMs)
    return [Math]::Max(0, $TimeoutMs - [int]$Watch.ElapsedMilliseconds)
}

function Invoke-Ftx1CatTransportRead {
    param(
        [Parameter(Mandatory = $true)][object]$Transport,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Watch,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )

    $remaining = Get-Ftx1CatRemainingMs -Watch $Watch -TimeoutMs $TimeoutMs
    if ($remaining -le 0) { throw [System.TimeoutException]::new('CAT session deadline elapsed before write.') }
    [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'SetTimeout' -Arguments @($remaining) -Optional)
    [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'WriteFrame' -Arguments @($Command))
}

function Read-Ftx1CatValue {
    param(
        [Parameter(Mandatory = $true)][object]$Transport,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Watch,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter()][AllowNull()][string]$ExpectedSideCode
    )

    [void](Invoke-Ftx1CatTransportRead -Transport $Transport -Command $Command -Watch $Watch -TimeoutMs $TimeoutMs)
    while ($true) {
        $remaining = Get-Ftx1CatRemainingMs -Watch $Watch -TimeoutMs $TimeoutMs
        if ($remaining -le 0) { throw [System.TimeoutException]::new("CAT 命令 $Command 在 session deadline 内没有收到匹配响应。") }
        [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'SetTimeout' -Arguments @($remaining) -Optional)
        $frame = Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'ReadFrame' -Arguments @($remaining)
        if ($null -eq $frame) { throw [System.TimeoutException]::new("CAT 命令 $Command 在 session deadline 内没有收到匹配响应。") }
        $frame = [string]$frame
        if ($frame -ceq '?;') {
            $exception = [System.InvalidOperationException]::new("FTX-1 CAT 在请求 $Command 时返回错误帧 ?;。")
            $exception.Data['Ftx1CatErrorCode'] = 'radio_rejected_command'
            throw $exception
        }

        $frameCommandMatch = [regex]::Match($frame, '^([A-Z]{2})([\x20-\x7E]*);$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $frameCommandMatch.Success) {
            $exception = [System.IO.InvalidDataException]::new("FTX-1 CAT 返回语法无效的完整帧：$frame")
            $exception.Data['Ftx1CatErrorCode'] = 'invalid_frame'
            throw $exception
        }
        $frameCommand = $frameCommandMatch.Groups[1].Value
        if ($frameCommand -cne $ExpectedCommand) {
            continue
        }

        if ($ExpectedCommand -ceq 'MD' -and $ExpectedSideCode) {
            $mdSideMatch = [regex]::Match($frame, '^MD([01])')
            if ($mdSideMatch.Success -and $mdSideMatch.Groups[1].Value -cne $ExpectedSideCode) {
                continue
            }
        }

        $parsed = ConvertFrom-Ftx1CatFrame -Frame $frame -ExpectedCommand $ExpectedCommand
        if ($parsed.status -cne 'ok') {
            $exception = [System.IO.InvalidDataException]::new("FTX-1 CAT 响应无效：$frame")
            $exception.Data['Ftx1CatErrorCode'] = [string]$parsed.error_code
            throw $exception
        }
        if ($ExpectedSideCode -and [string](Get-Ftx1CatPropertyValue $parsed.value 'side_code') -cne $ExpectedSideCode) {
            $exception = [System.IO.InvalidDataException]::new("CAT 响应侧别与请求不符：$frame")
            $exception.Data['Ftx1CatErrorCode'] = 'side_mismatch'
            throw $exception
        }
        return $parsed.value
    }
}

function Invoke-Ftx1CatOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('query', 'setPower', 'setMode', 'setFrequency')]
        [string]$Operation,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$PortName,
        [Parameter(Mandatory = $true)][ValidateSet('CAT-1')][string]$PortRole,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HriPortName,
        [Parameter()][ValidateSet(4800, 9600, 19200, 38400, 115200)][int]$BaudRate = 38400,
        [Parameter()][ValidateSet('One', 'Two')][string]$StopBits = 'One',
        [Parameter()][ValidateRange(100, 3000)][int]$TimeoutMs = $script:Ftx1CatDefaultTimeoutMs,
        [Parameter()][ValidateSet('Main', 'Sub')][string]$Side = 'Main',
        [Parameter()][ValidateSet('FM', 'FM-N', 'C4FM-DN', 'C4FM-VW')][string]$Mode,
        [Parameter()][int]$PowerWatts,
        [Parameter()][long]$FrequencyHz,
        [Parameter()][AllowNull()][object]$Transport
    )

    $startedAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $operationSource = if ($null -ne $Transport) { 'CAT test transport' } else { $script:Ftx1CatSource }
    $Operation = switch ($Operation.ToLowerInvariant()) {
        'query' { 'query' }
        'setpower' { 'setPower' }
        'setmode' { 'setMode' }
        'setfrequency' { 'setFrequency' }
    }
    $Side = if ($Side -ieq 'Main') { 'Main' } else { 'Sub' }
    if ($Mode) {
        foreach ($candidateMode in $script:Ftx1CatModeByName.Keys) {
            if ([string]::Equals([string]$candidateMode, $Mode, [StringComparison]::OrdinalIgnoreCase)) {
                $Mode = [string]$candidateMode
                break
            }
        }
    }
    $StopBits = if ($StopBits -ieq 'One') { 'One' } else { 'Two' }
    $emptyObserved = [pscustomobject][ordered]@{
        radio_id = New-Ftx1CatObservedValue -Value $null
        auto_information_enabled = New-Ftx1CatObservedValue -Value $null
        tx_state = New-Ftx1CatObservedValue -Value $null
        main_frequency_hz = New-Ftx1CatObservedValue -Value $null
        sub_frequency_hz = New-Ftx1CatObservedValue -Value $null
        main_mode = New-Ftx1CatObservedValue -Value $null
        sub_mode = New-Ftx1CatObservedValue -Value $null
        power = New-Ftx1CatObservedValue -Value $null
    }
    $emptyCapabilities = New-Ftx1CatCapabilities
    $desired = $null
    $isOpen = $false
    $openCompleted = $false
    $closeError = $null
    $prior = $null
    $capabilities = $emptyCapabilities
    $updatedAt = $null
    if ($Operation -ceq 'setMode' -and $Mode) {
        $desired = [pscustomobject]@{ side = $Side; mode = $Mode }
    } elseif ($Operation -ceq 'setPower' -and $PSBoundParameters.ContainsKey('PowerWatts')) {
        $desired = [pscustomobject]@{ watts = $PowerWatts }
    } elseif ($Operation -ceq 'setFrequency' -and $PSBoundParameters.ContainsKey('FrequencyHz')) {
        $desired = [pscustomobject]@{ side = 'Main'; frequency_hz = [long]$FrequencyHz }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($PortName)) { throw [System.ArgumentException]::new('CAT-1 端口名不能为空。') }
        if ((Normalize-Ftx1CatPortName $PortName) -ceq (Normalize-Ftx1CatPortName $HriPortName)) {
            $exception = [System.InvalidOperationException]::new('CAT-1 端口与当前 HRI 端口相同；为避免两个协议共用串口，本次未打开端口。')
            $exception.Data['Ftx1CatErrorCode'] = 'hri_port_conflict'
            throw $exception
        }
        if ($Operation -ceq 'setMode' -and -not $PSBoundParameters.ContainsKey('Mode')) {
            throw [System.ArgumentException]::new('setMode 需要 Mode。')
        }
        if ($Operation -ceq 'setPower' -and -not $PSBoundParameters.ContainsKey('PowerWatts')) {
            throw [System.ArgumentException]::new('setPower 需要 PowerWatts。')
        }
        if ($Operation -ceq 'setPower' -and ($PowerWatts -lt 5 -or $PowerWatts -gt 50)) {
            $exception = [System.ArgumentOutOfRangeException]::new('PowerWatts', '本应用接受5–50 W的期望值；不会自动钳位。')
            $exception.Data['Ftx1CatErrorCode'] = 'power_out_of_range'
            throw $exception
        }
        if ($Operation -ceq 'setFrequency' -and -not $PSBoundParameters.ContainsKey('FrequencyHz')) {
            throw [System.ArgumentException]::new('setFrequency 需要 FrequencyHz。')
        }
        if ($Operation -ceq 'setFrequency' -and $Side -cne 'Main') {
            throw [System.ArgumentException]::new('本版本只允许设置 MAIN 侧 FA 频率。')
        }
        if ($Operation -ceq 'setFrequency' -and ($FrequencyHz -lt 30000 -or $FrequencyHz -gt 470000000)) {
            $exception = [System.ArgumentOutOfRangeException]::new('FrequencyHz', 'MAIN FA 频率范围为 30,000–470,000,000 Hz；不会自动钳位。')
            $exception.Data['Ftx1CatErrorCode'] = 'frequency_out_of_range'
            throw $exception
        }
        if ($BaudRate -notin $script:Ftx1CatBaudRates) {
            throw [System.ArgumentOutOfRangeException]::new('BaudRate', '波特率不在 FTX-1 CAT 手册列出的选项内。')
        }

        if ($null -eq $Transport) {
            $Transport = New-Ftx1CatSerialTransport -PortName $PortName -BaudRate $BaudRate -StopBits $StopBits -TimeoutMs $TimeoutMs
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'Open')
        $isOpen = $true
        $openCompleted = $true
        if ((Get-Ftx1CatRemainingMs -Watch $watch -TimeoutMs $TimeoutMs) -le 0) {
            throw [System.TimeoutException]::new('CAT session deadline elapsed while opening the port.')
        }
        [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'ClearInput' -Optional)

        $radioId = Read-Ftx1CatValue -Transport $Transport -Command 'ID;' -ExpectedCommand 'ID' -Watch $watch -TimeoutMs $TimeoutMs
        if ($radioId.radio_id -cne '0840') {
            $exception = [System.InvalidOperationException]::new("CAT identification mismatch: expected FTX-1 ID 0840, received $($radioId.radio_id).")
            $exception.Data['Ftx1CatErrorCode'] = 'identity_mismatch'
            throw $exception
        }
        $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $emptyObserved.radio_id = New-Ftx1CatObservedValue -Value $radioId.radio_id -UpdatedAtUtc $stamp -Source $operationSource
        $capabilities = New-Ftx1CatCapabilities -RadioAvailable $true

        $aiState = Read-Ftx1CatValue -Transport $Transport -Command 'AI;' -ExpectedCommand 'AI' -Watch $watch -TimeoutMs $TimeoutMs
        $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $emptyObserved.auto_information_enabled = New-Ftx1CatObservedValue -Value ([bool]$aiState.enabled) -UpdatedAtUtc $stamp -Source $operationSource

        $txState = Read-Ftx1CatValue -Transport $Transport -Command 'TX;' -ExpectedCommand 'TX' -Watch $watch -TimeoutMs $TimeoutMs
        $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $emptyObserved.tx_state = New-Ftx1CatObservedValue -Value ([int]$txState.state) -UpdatedAtUtc $stamp -Source $operationSource
        $capabilities = New-Ftx1CatCapabilities -RadioAvailable $true -SettingsWritable ($txState.state -eq 0)
        if ($Operation -cne 'query' -and $txState.state -ne 0) {
            $exception = [System.InvalidOperationException]::new("Radio is not idle (TX state $($txState.state)); the requested CAT setting was not written.")
            $exception.Data['Ftx1CatErrorCode'] = 'busy'
            throw $exception
        }

        $prior = $null
        if ($Operation -ceq 'query') {
            $fa = Read-Ftx1CatValue -Transport $Transport -Command 'FA;' -ExpectedCommand 'FA' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.main_frequency_hz = New-Ftx1CatObservedValue -Value ([long]$fa.frequency_hz) -UpdatedAtUtc $stamp -Source $operationSource
            $fb = Read-Ftx1CatValue -Transport $Transport -Command 'FB;' -ExpectedCommand 'FB' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.sub_frequency_hz = New-Ftx1CatObservedValue -Value ([long]$fb.frequency_hz) -UpdatedAtUtc $stamp -Source $operationSource
            $mainMode = Read-Ftx1CatValue -Transport $Transport -Command 'MD0;' -ExpectedCommand 'MD' -Watch $watch -TimeoutMs $TimeoutMs -ExpectedSideCode '0'
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.main_mode = New-Ftx1CatObservedValue -Value $mainMode -UpdatedAtUtc $stamp -Source $operationSource
            $subMode = Read-Ftx1CatValue -Transport $Transport -Command 'MD1;' -ExpectedCommand 'MD' -Watch $watch -TimeoutMs $TimeoutMs -ExpectedSideCode '1'
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.sub_mode = New-Ftx1CatObservedValue -Value $subMode -UpdatedAtUtc $stamp -Source $operationSource
            $power = Read-Ftx1CatValue -Transport $Transport -Command 'PC;' -ExpectedCommand 'PC' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.power = New-Ftx1CatObservedValue -Value $power -UpdatedAtUtc $stamp -Source $operationSource
            $maxPower = if ($power.path -ceq 'FieldHead') { 10 } else { 50 }
            $capabilities = New-Ftx1CatCapabilities -PowerPath $power.path -PowerReadable $true -PowerWritable $true -RadioAvailable $true -SettingsWritable ($txState.state -eq 0)
            $updatedAt = $stamp
        } elseif ($Operation -ceq 'setPower') {
            $mainMode = Read-Ftx1CatValue -Transport $Transport -Command 'MD0;' -ExpectedCommand 'MD' -Watch $watch -TimeoutMs $TimeoutMs -ExpectedSideCode '0'
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.main_mode = New-Ftx1CatObservedValue -Value $mainMode -UpdatedAtUtc $stamp -Source $operationSource
            if ($mainMode.mode -notin $script:Ftx1CatVoiceModes) {
                $exception = [System.InvalidOperationException]::new("Power change requires MAIN in FM/C4FM voice mode; observed $($mainMode.mode).")
                $exception.Data['Ftx1CatErrorCode'] = 'power_mode_not_supported'
                throw $exception
            }
            $oldPower = Read-Ftx1CatValue -Transport $Transport -Command 'PC;' -ExpectedCommand 'PC' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.power = New-Ftx1CatObservedValue -Value $oldPower -UpdatedAtUtc $stamp -Source $operationSource
            $maxPower = if ($oldPower.path -ceq 'FieldHead') { 10 } else { 50 }
            $capabilities = New-Ftx1CatCapabilities -PowerPath $oldPower.path -PowerReadable $true -PowerWritable $true -RadioAvailable $true -SettingsWritable $true
            $prior = [pscustomobject]@{ main_mode = $mainMode.mode; power = $oldPower }
            if ($PowerWatts -lt 5 -or $PowerWatts -gt $maxPower) {
                $exception = [System.ArgumentOutOfRangeException]::new('PowerWatts', "当前功率路径 $($oldPower.path) 的应用范围为 5-$maxPower W；不会自动钳位。")
                $exception.Data['Ftx1CatErrorCode'] = 'power_out_of_range'
                throw $exception
            }
            if ($oldPower.watts -ne $PowerWatts) {
                $setCommand = New-Ftx1CatPowerCommand -PowerPath $oldPower.path -Watts $PowerWatts
                $writeGate = Read-Ftx1CatValue -Transport $Transport -Command 'TX;' -ExpectedCommand 'TX' -Watch $watch -TimeoutMs $TimeoutMs
                $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $emptyObserved.tx_state = New-Ftx1CatObservedValue -Value ([int]$writeGate.state) -UpdatedAtUtc $stamp -Source $operationSource
                $capabilities = New-Ftx1CatCapabilities -PowerPath $oldPower.path -PowerReadable $true -PowerWritable $true -RadioAvailable $true -SettingsWritable ($writeGate.state -eq 0)
                if ($writeGate.state -ne 0) {
                    $exception = [System.InvalidOperationException]::new("Radio became active before the power write (TX state $($writeGate.state)); the setting was not written.")
                    $exception.Data['Ftx1CatErrorCode'] = 'busy'
                    throw $exception
                }
                $remaining = Get-Ftx1CatRemainingMs -Watch $watch -TimeoutMs $TimeoutMs
                if ($remaining -le 0) { throw [System.TimeoutException]::new('CAT session deadline elapsed before power write.') }
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'SetTimeout' -Arguments @($remaining) -Optional)
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'WriteFrame' -Arguments @($setCommand))
            }
            $power = Read-Ftx1CatValue -Transport $Transport -Command 'PC;' -ExpectedCommand 'PC' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.power = New-Ftx1CatObservedValue -Value $power -UpdatedAtUtc $stamp -Source $operationSource
            if ($power.path -cne $oldPower.path -or $power.watts -ne $PowerWatts) {
                $exception = [System.InvalidOperationException]::new("Power readback was $($power.path) $($power.watts) W, not $($oldPower.path) $PowerWatts W.")
                $exception.Data['Ftx1CatErrorCode'] = 'readback_mismatch'
                throw $exception
            }
            $updatedAt = $stamp
        } elseif ($Operation -ceq 'setFrequency') {
            $oldFrequency = Read-Ftx1CatValue -Transport $Transport -Command 'FA;' -ExpectedCommand 'FA' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.main_frequency_hz = New-Ftx1CatObservedValue -Value ([long]$oldFrequency.frequency_hz) -UpdatedAtUtc $stamp -Source $operationSource
            $prior = [pscustomobject]@{ side = 'Main'; frequency_hz = [long]$oldFrequency.frequency_hz }
            $capabilities = New-Ftx1CatCapabilities -PowerPath $null -PowerReadable $false -PowerWritable $false -PowerUnavailableReason 'Power path is not part of this frequency operation.' -RadioAvailable $true -SettingsWritable $true
            if ($oldFrequency.frequency_hz -ne $FrequencyHz) {
                $setCommand = New-Ftx1CatFrequencyCommand -FrequencyHz $FrequencyHz
                $writeGate = Read-Ftx1CatValue -Transport $Transport -Command 'TX;' -ExpectedCommand 'TX' -Watch $watch -TimeoutMs $TimeoutMs
                $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $emptyObserved.tx_state = New-Ftx1CatObservedValue -Value ([int]$writeGate.state) -UpdatedAtUtc $stamp -Source $operationSource
                $capabilities = New-Ftx1CatCapabilities -RadioAvailable $true -SettingsWritable ($writeGate.state -eq 0)
                if ($writeGate.state -ne 0) {
                    $exception = [System.InvalidOperationException]::new("Radio became active before the MAIN frequency write (TX state $($writeGate.state)); the setting was not written.")
                    $exception.Data['Ftx1CatErrorCode'] = 'busy'
                    throw $exception
                }
                $remaining = Get-Ftx1CatRemainingMs -Watch $watch -TimeoutMs $TimeoutMs
                if ($remaining -le 0) { throw [System.TimeoutException]::new('CAT session deadline elapsed before MAIN frequency write.') }
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'SetTimeout' -Arguments @($remaining) -Optional)
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'WriteFrame' -Arguments @($setCommand))
            }
            $verifiedFrequency = Read-Ftx1CatValue -Transport $Transport -Command 'FA;' -ExpectedCommand 'FA' -Watch $watch -TimeoutMs $TimeoutMs
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $emptyObserved.main_frequency_hz = New-Ftx1CatObservedValue -Value ([long]$verifiedFrequency.frequency_hz) -UpdatedAtUtc $stamp -Source $operationSource
            if ($verifiedFrequency.frequency_hz -ne $FrequencyHz) {
                $exception = [System.InvalidOperationException]::new("MAIN frequency readback was $($verifiedFrequency.frequency_hz) Hz, not $FrequencyHz Hz.")
                $exception.Data['Ftx1CatErrorCode'] = 'readback_mismatch'
                throw $exception
            }
            $updatedAt = $stamp
        } elseif ($Operation -ceq 'setMode') {
            $sideCode = if ($Side -ceq 'Main') { '0' } else { '1' }
            $readCommand = "MD$sideCode;"
            $oldMode = Read-Ftx1CatValue -Transport $Transport -Command $readCommand -ExpectedCommand 'MD' -Watch $watch -TimeoutMs $TimeoutMs -ExpectedSideCode $sideCode
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            if ($Side -ceq 'Main') { $emptyObserved.main_mode = New-Ftx1CatObservedValue -Value $oldMode -UpdatedAtUtc $stamp -Source $operationSource }
            else { $emptyObserved.sub_mode = New-Ftx1CatObservedValue -Value $oldMode -UpdatedAtUtc $stamp -Source $operationSource }
            $prior = [pscustomobject]@{ side = $Side; mode = $oldMode.mode }
            $capabilities = New-Ftx1CatCapabilities -PowerPath $null -PowerReadable $false -PowerWritable $false -PowerUnavailableReason 'Power path is not part of this mode operation.' -RadioAvailable $true -SettingsWritable $true
            if ($oldMode.mode -cne $Mode) {
                $setCommand = New-Ftx1CatModeCommand -Side $Side -Mode $Mode
                $writeGate = Read-Ftx1CatValue -Transport $Transport -Command 'TX;' -ExpectedCommand 'TX' -Watch $watch -TimeoutMs $TimeoutMs
                $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $emptyObserved.tx_state = New-Ftx1CatObservedValue -Value ([int]$writeGate.state) -UpdatedAtUtc $stamp -Source $operationSource
                $capabilities = New-Ftx1CatCapabilities -RadioAvailable $true -SettingsWritable ($writeGate.state -eq 0)
                if ($writeGate.state -ne 0) {
                    $exception = [System.InvalidOperationException]::new("Radio became active before the mode write (TX state $($writeGate.state)); the setting was not written.")
                    $exception.Data['Ftx1CatErrorCode'] = 'busy'
                    throw $exception
                }
                $remaining = Get-Ftx1CatRemainingMs -Watch $watch -TimeoutMs $TimeoutMs
                if ($remaining -le 0) { throw [System.TimeoutException]::new('CAT session deadline elapsed before mode write.') }
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'SetTimeout' -Arguments @($remaining) -Optional)
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'WriteFrame' -Arguments @($setCommand))
            }
            $verifiedMode = Read-Ftx1CatValue -Transport $Transport -Command $readCommand -ExpectedCommand 'MD' -Watch $watch -TimeoutMs $TimeoutMs -ExpectedSideCode $sideCode
            $stamp = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            if ($Side -ceq 'Main') { $emptyObserved.main_mode = New-Ftx1CatObservedValue -Value $verifiedMode -UpdatedAtUtc $stamp -Source $operationSource }
            else { $emptyObserved.sub_mode = New-Ftx1CatObservedValue -Value $verifiedMode -UpdatedAtUtc $stamp -Source $operationSource }
            if ($verifiedMode.mode -cne $Mode) {
                $exception = [System.InvalidOperationException]::new("Mode readback was $($verifiedMode.mode), not $Mode.")
                $exception.Data['Ftx1CatErrorCode'] = 'readback_mismatch'
                throw $exception
            }
            $updatedAt = $stamp
        }

        $cleanupStatus = 'closed'
        try {
            [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'Close')
            $isOpen = $false
        } catch {
            $cleanupStatus = 'close_failed'
            $closeError = $_.Exception.Message
            $isOpen = $false
        }
        $watch.Stop()
        $successMessage = $null
        $successCode = $null
        $resultStatus = 'confirmed'
        if ($watch.ElapsedMilliseconds -gt $TimeoutMs) {
            $resultStatus = 'unknown'
            $successCode = 'timeout'
            $successMessage = 'CAT session exceeded its bounded deadline; readback values are retained as observations, but this operation is not marked confirmed.'
        }
        if ($cleanupStatus -ceq 'close_failed') {
            $resultStatus = 'unknown'
            if ($null -eq $successCode) { $successCode = 'serial_close_failed' }
            if ($successMessage) { $successMessage = "$successMessage 串口关闭失败：$closeError" }
            else { $successMessage = "CAT 读回值与目标相符，但串口关闭失败；本次操作整体状态为 unknown：$closeError" }
        }
        return New-Ftx1CatResult -Operation $Operation -Status $resultStatus -PortName $PortName -Observed $emptyObserved -Prior $prior -Desired $desired -Capabilities $capabilities -UpdatedAtUtc $updatedAt -StartedAtUtc $startedAt -ErrorCode $successCode -ErrorMessage $successMessage -Source $operationSource -CleanupStatus $cleanupStatus
    } catch {
        $code = 'error'
        if ($_.Exception -is [System.TimeoutException]) { $code = 'timeout' }
        elseif ($_.Exception.Data.Contains('Ftx1CatErrorCode')) { $code = [string]$_.Exception.Data['Ftx1CatErrorCode'] }
        elseif ($_.Exception -is [System.ArgumentException] -or $_.Exception -is [System.ArgumentOutOfRangeException]) { $code = 'invalid_request' }
        elseif ($_.Exception -is [System.UnauthorizedAccessException]) { $code = 'port_busy_or_denied' }
        elseif ($_.Exception -is [System.IO.IOException]) { $code = 'serial_io_error' }
        $status = switch ($code) {
            'busy' { 'busy' }
            'identity_mismatch' { 'identity_mismatch' }
            'hri_port_conflict' { 'rejected' }
            'power_out_of_range' { 'rejected' }
            'frequency_out_of_range' { 'rejected' }
            'power_mode_not_supported' { 'rejected' }
            'invalid_request' { 'rejected' }
            'readback_mismatch' { 'mismatch' }
            'timeout' { 'unknown' }
            'port_busy_or_denied' { 'unknown' }
            'serial_io_error' { 'unknown' }
            'radio_rejected_command' { 'rejected' }
            'invalid_frame' { 'unknown' }
            'unexpected_response' { 'unknown' }
            'side_mismatch' { 'unknown' }
            default { 'unknown' }
        }
        $message = [string]$_.Exception.Message
        if ($code -ceq 'port_busy_or_denied') { $message = '无法打开 CAT-1 端口；端口可能被其他程序占用或访问被拒绝。' }
        if ($code -ceq 'serial_io_error') { $message = 'CAT-1 串口读写失败；本次没有报告设置已生效。' }
        if ($Transport -and $isOpen) {
            try {
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'Close')
                $isOpen = $false
            } catch {
                $isOpen = $false
                $closeError = $_.Exception.Message
            }
        }
        $cleanupStatus = if ($closeError) { 'close_failed' } elseif ($openCompleted -and -not $isOpen) { 'closed' } else { 'not_opened' }
        if ($closeError) { $message = "$message Serial close failed: $closeError" }
        return New-Ftx1CatResult -Operation $Operation -Status $status -PortName $PortName -Observed $emptyObserved -Prior $prior -Desired $desired -Capabilities $capabilities -UpdatedAtUtc $null -StartedAtUtc $startedAt -ErrorCode $code -ErrorMessage $message -Source $operationSource -CleanupStatus $cleanupStatus
    } finally {
        if ($Transport -and $isOpen) {
            try {
                [void](Invoke-Ftx1CatTransportMethod -Transport $Transport -MethodName 'Close')
                $isOpen = $false
            } catch {
                $isOpen = $false
            }
        }
    }
}

Export-ModuleMember -Function @(
    'New-Ftx1CatModeCommand',
    'New-Ftx1CatFrequencyCommand',
    'New-Ftx1CatPowerCommand',
    'ConvertFrom-Ftx1CatFrame',
    'Invoke-Ftx1CatOperation'
)
