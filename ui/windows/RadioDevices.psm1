Set-StrictMode -Version 2.0

function Get-RadioDeviceProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { if ([string]::Equals([string]$key,$Name,[StringComparison]::OrdinalIgnoreCase)) { return $InputObject[$key] } }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-RadioPortName {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.StartsWith('\\.\',[StringComparison]::Ordinal)) { $text = $text.Substring(4) }
    $match = [regex]::Match($text,'(?i)(?:^|\()COM0*([1-9][0-9]*)\)?$')
    if (-not $match.Success) { return $null }
    try { return 'COM' + [int]$match.Groups[1].Value } catch { return $null }
}

function Get-RadioSerialRegistryPorts {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $key = $null
    $status = 'unavailable'
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM',$false)
        if ($key) {
            $status = 'ready'
            foreach ($valueName in $key.GetValueNames()) {
                $portName = ConvertTo-RadioPortName $key.GetValue($valueName)
                if ($portName) {
                    $items.Add([pscustomobject]@{ PortName=$portName; FriendlyName=''; InstanceId=''; HardwareIds=@(); DeviceSource='registry' })
                }
            }
        } else { $status = 'unavailable' }
    } catch {
        $status = 'error'
    } finally {
        if ($key) { $key.Dispose() }
    }
    return [pscustomobject]@{ status=$status; records=$items.ToArray() }
}

function Get-RadioSerialCimPorts {
    $items = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ status='unavailable'; records=$items.ToArray() } }
    $status = 'ready'
    try {
        foreach ($device in @(Get-CimInstance -ClassName Win32_SerialPort -ErrorAction Stop)) {
            $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $device 'DeviceID')
            if (-not $portName) { $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $device 'Name') }
            if (-not $portName) { continue }
            $instanceId = [string](Get-RadioDeviceProperty $device 'PNPDeviceID')
            $hardwareIds = @()
            $rawHardwareIds = Get-RadioDeviceProperty $device 'HardwareID'
            if ($rawHardwareIds -is [array]) { $hardwareIds = @($rawHardwareIds | ForEach-Object { [string]$_ }) }
            elseif ($rawHardwareIds -is [string] -and $rawHardwareIds) { $hardwareIds = @([string]$rawHardwareIds) }
            if ($instanceId) { $hardwareIds += $instanceId }
            $items.Add([pscustomobject]@{
                PortName=$portName
                FriendlyName=[string](Get-RadioDeviceProperty $device 'Name')
                InstanceId=$instanceId
                HardwareIds=@($hardwareIds | Select-Object -Unique)
                DeviceSource='cim'
            })
        }
    } catch {
        $status = 'error'
    }
    return [pscustomobject]@{ status=$status; records=$items.ToArray() }
}

function Get-RadioDeviceCatalog {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$SerialPortsInput,
        [Parameter()][AllowNull()][object[]]$CimPortsInput
    )
    $injected = $PSBoundParameters.ContainsKey('SerialPortsInput') -or $PSBoundParameters.ContainsKey('CimPortsInput')
    $serialRecords = New-Object 'System.Collections.Generic.List[object]'
    $cimRecords = New-Object 'System.Collections.Generic.List[object]'
    $sourceStatus = [ordered]@{ registry='not_requested'; cim='not_requested' }
    if ($injected) {
        if ($PSBoundParameters.ContainsKey('SerialPortsInput')) { foreach ($item in @($SerialPortsInput)) { if ($null -ne $item) { $serialRecords.Add($item) } } }
        if ($PSBoundParameters.ContainsKey('CimPortsInput')) { foreach ($item in @($CimPortsInput)) { if ($null -ne $item) { $cimRecords.Add($item) } } }
        $sourceStatus.registry = 'synthetic'
        $sourceStatus.cim = if ($PSBoundParameters.ContainsKey('CimPortsInput')) { 'synthetic' } else { 'not_requested' }
    } else {
        $registryResult = Get-RadioSerialRegistryPorts
        $sourceStatus.registry = [string]$registryResult.status
        foreach ($item in @($registryResult.records)) { $serialRecords.Add($item) }
        $cimResult = Get-RadioSerialCimPorts
        $sourceStatus.cim = [string]$cimResult.status
        foreach ($item in @($cimResult.records)) { $cimRecords.Add($item) }
    }

    $recordsByPort = @{}
    foreach ($record in @($serialRecords.ToArray()) + @($cimRecords.ToArray())) {
        $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $record 'PortName')
        if (-not $portName) { $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $record 'DeviceID') }
        if (-not $portName) { $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $record 'FriendlyName') }
        if (-not $portName) { $portName = ConvertTo-RadioPortName (Get-RadioDeviceProperty $record 'Name') }
        if (-not $portName) { continue }
        if (-not $recordsByPort.ContainsKey($portName)) {
            $recordsByPort[$portName] = [ordered]@{ PortName=$portName; FriendlyNames=(New-Object 'System.Collections.Generic.List[string]'); InstanceIds=(New-Object 'System.Collections.Generic.List[string]'); HardwareIds=(New-Object 'System.Collections.Generic.List[string]'); Sources=(New-Object 'System.Collections.Generic.List[string]') }
        }
        $entry = $recordsByPort[$portName]
        foreach ($propertyName in @('FriendlyName','Name')) {
            $value = [string](Get-RadioDeviceProperty $record $propertyName)
            if ($value -and -not $entry.FriendlyNames.Contains($value)) { $entry.FriendlyNames.Add($value) }
        }
        foreach ($propertyName in @('InstanceId','PNPDeviceID')) {
            $value = [string](Get-RadioDeviceProperty $record $propertyName)
            if ($value -and -not $entry.InstanceIds.Contains($value)) { $entry.InstanceIds.Add($value) }
        }
        $hardwareValues = Get-RadioDeviceProperty $record 'HardwareIds'
        if ($null -eq $hardwareValues) { $hardwareValues = Get-RadioDeviceProperty $record 'HardwareID' }
        if ($hardwareValues -is [string]) { $hardwareValues = @($hardwareValues) }
        foreach ($value in @($hardwareValues)) {
            $value = [string]$value
            if ($value -and -not $entry.HardwareIds.Contains($value)) { $entry.HardwareIds.Add($value) }
        }
        $source = [string](Get-RadioDeviceProperty $record 'DeviceSource')
        if (-not $source) { $source = if ($injected) { 'input' } else { 'unknown' } }
        foreach ($sourceItem in @($source -split '[,;|]')) {
            if ($sourceItem -and -not $entry.Sources.Contains($sourceItem)) { $entry.Sources.Add($sourceItem) }
        }
    }

    $allPorts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($portName in @($recordsByPort.Keys | Sort-Object { [int]($_ -replace '^COM','') })) {
        $entry = $recordsByPort[$portName]
        $friendly = [string](@($entry.FriendlyNames | Select-Object -First 1)[0])
        $instanceId = [string](@($entry.InstanceIds | Select-Object -First 1)[0])
        $hardwareIds = @($entry.HardwareIds.ToArray())
        $identityText = (@($entry.InstanceIds.ToArray()) + @($entry.HardwareIds.ToArray())) -join ';'
        $descriptionText = (@($entry.FriendlyNames.ToArray()) + @($entry.InstanceIds.ToArray()) + @($entry.HardwareIds.ToArray())) -join ' '
        $isHri = ($identityText -match '(?i)VID_26AA&PID_0030') -or ($descriptionText -match '(?i)\bHRI\b')
        $catRank = 0
        $catReason = '未识别的串口；可手动选择'
        if (-not $isHri) {
            if ($descriptionText -match '(?i)(CP2105|CP210X|CP210x).*(Enhanced|MI_00)|(Enhanced|MI_00).*(CP2105|CP210X|CP210x)') {
                $catRank = 300; $catReason = 'CP210x Enhanced 串口匹配'
            } elseif ($descriptionText -match '(?i)VID_10C4&PID_EA70.*MI_00|MI_00.*VID_10C4&PID_EA70') {
                $catRank = 300; $catReason = 'Silicon Labs CP2105 Enhanced 接口匹配'
            } elseif ($descriptionText -match '(?i)CP2105.*Enhanced|Enhanced.*CP2105') {
                $catRank = 300; $catReason = 'CP2105 Enhanced 串口匹配'
            } elseif ($descriptionText -match '(?i)CP2105') {
                $catRank = 250; $catReason = 'CP2105 串口匹配'
            } elseif ($descriptionText -match '(?i)CP210x|CP210X') {
                $catRank = 220; $catReason = 'CP210x 串口匹配'
            } elseif ($descriptionText -match '(?i)VID_10C4') {
                $catRank = 180; $catReason = 'Silicon Labs 串口匹配'
            } elseif ($descriptionText -match '(?i)USB Serial|USB-to-UART|USB to UART') {
                $catRank = 100; $catReason = 'USB 串行接口候选'
            }
        }
        $port = [pscustomobject][ordered]@{
            PortName=$portName
            FriendlyName=$friendly
            InstanceId=$instanceId
            HardwareIds=$hardwareIds
            DeviceSource=@($entry.Sources.ToArray())
            IsHri=[bool]$isHri
            IsCatCandidate=([bool](-not $isHri))
            CatMatchRank=[int]$catRank
            CatMatchReason=$catReason
            Confidence=if ($isHri) { 'high' } elseif ($catRank -gt 0) { 'medium' } else { 'unknown' }
        }
        $allPorts.Add($port)
    }
    $ports = @($allPorts.ToArray())
    $hriPorts = @($ports | Where-Object { $_.IsHri })
    $catPorts = @($ports | Where-Object { $_.IsCatCandidate })
    $successfulSources = @($sourceStatus.Values | Where-Object { $_ -ceq 'ready' }).Count
    $catalogStatus = if ($injected) { 'synthetic' } elseif ($ports.Count -gt 0) { 'ready' } elseif ($successfulSources -gt 0) { 'empty' } else { 'failed' }
    return [pscustomobject][ordered]@{
        schema_version=1
        discovery_status=$catalogStatus
        serial_ready=($ports.Count -gt 0)
        source_status=[pscustomobject]$sourceStatus
        serial_ports=$ports
        hri_ports=$hriPorts
        cat_ports=$catPorts
        wave_inputs=@()
        wave_outputs=@()
    }
}

function Resolve-RadioDevicePortSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNull()][object]$Catalog,
        [Parameter()][AllowEmptyString()][string]$SavedHriPort='auto',
        [Parameter()][AllowEmptyString()][string]$SavedCatPort='auto',
        [Parameter()][AllowEmptyString()][string]$ManualCatPort=''
    )
    $allPorts = @((Get-RadioDeviceProperty $Catalog 'serial_ports'))
    $hriPorts = @((Get-RadioDeviceProperty $Catalog 'hri_ports'))
    $catPortsValue = Get-RadioDeviceProperty $Catalog 'cat_ports'
    $catPorts = if ($null -ne $catPortsValue) { @($catPortsValue) } else { @($allPorts | Where-Object { -not [bool](Get-RadioDeviceProperty $_ 'IsHri') }) }
    $savedHri = ConvertTo-RadioPortName $SavedHriPort
    $savedCat = ConvertTo-RadioPortName $SavedCatPort
    $hriPort = $null; $hriReason = '未发现唯一的 HRI 设备匹配，请手动选择。'
    $savedHriMatch = @($hriPorts | Where-Object { (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -ceq $savedHri })
    if ($savedHri -and $savedHriMatch.Count -eq 1) {
        $hriPort = $savedHri; $hriReason = '沿用已保存且当前存在的 HRI 串口。'
    } elseif ($hriPorts.Count -eq 1) {
        $hriPort = ConvertTo-RadioPortName (Get-RadioDeviceProperty $hriPorts[0] 'PortName'); $hriReason = '唯一的 HRI 硬件匹配。'
    }

    $catPort = $null; $catReason = '没有唯一的已识别 CAT 串口匹配，请手动选择。'
    $catSource = $null
    $catConflict = $false
    $savedCatMatch = @($catPorts | Where-Object {
        (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -ceq $savedCat -and
        (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -cne $hriPort
    })
    $savedCatIsHri = $false
    if ($savedCat) {
        $savedCatIsHri = (($savedCat -ceq $hriPort) -or @($hriPorts | Where-Object {
            (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -ceq $savedCat
        }).Count -gt 0)
    }
    $manualCat = ConvertTo-RadioPortName $ManualCatPort
    if (-not [string]::IsNullOrWhiteSpace($ManualCatPort) -and
        ($manualCat -notmatch '^COM[1-9][0-9]{0,2}$' -or $manualCat -cne $ManualCatPort.Trim().ToUpperInvariant())) {
        throw '手动 CAT 串口必须是 COM1 到 COM999 格式。'
    }
    $manualCatIsHri = $false
    if ($manualCat) {
        $manualCatIsHri = (($manualCat -ceq $hriPort) -or ($manualCat -ceq $savedHri) -or @($hriPorts | Where-Object {
            (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -ceq $manualCat
        }).Count -gt 0)
    }
    if ($savedCatIsHri) {
        $catConflict = $true
        $catReason = '已保存的 CAT 端口当前与 HRI 端口相同或被识别为 HRI；拒绝共用，请手动选择其他端口。'
    } elseif ($manualCatIsHri) {
        $catConflict = $true
        $catReason = '手动 CAT 端口与 HRI 端口相同或被识别为 HRI；拒绝共用，请手动选择其他端口。'
    } elseif ($manualCat) {
        $catPort = $manualCat
        $catSource = 'manual'
        $catReason = '用户手动输入；当前设备枚举未确认此端口身份。'
    } elseif ($savedCat -and $savedCatMatch.Count -eq 1) {
        $catPort = $savedCat; $catReason = '沿用已保存且当前存在的 CAT 串口。'
        $catSource = 'saved'
    } else {
        $ranked = @($catPorts | Where-Object {
            [int](Get-RadioDeviceProperty $_ 'CatMatchRank') -gt 0 -and
            (ConvertTo-RadioPortName (Get-RadioDeviceProperty $_ 'PortName')) -cne $hriPort
        } | Sort-Object { -[int](Get-RadioDeviceProperty $_ 'CatMatchRank') })
        if ($ranked.Count -gt 0) {
            $bestRank = [int](Get-RadioDeviceProperty $ranked[0] 'CatMatchRank')
            $best = @($ranked | Where-Object { [int](Get-RadioDeviceProperty $_ 'CatMatchRank') -eq $bestRank })
            if ($best.Count -eq 1) {
                $catPort = ConvertTo-RadioPortName (Get-RadioDeviceProperty $best[0] 'PortName')
                $catReason = [string](Get-RadioDeviceProperty $best[0] 'CatMatchReason')
                $catSource = 'matched'
            }
        }
    }
    if ($catPort -and $hriPort -and $catPort -ceq $hriPort) {
        $catPort = $null; $catReason = 'CAT 与 HRI 端口不能相同，请手动选择其他 CAT 串口。'
    }
    return [pscustomobject][ordered]@{
        hri_port=$hriPort
        cat_port=$catPort
        hri_match_reason=$hriReason
        cat_match_reason=$catReason
        cat_port_source=$catSource
        cat_conflict=$catConflict
        needs_manual_hri=($null -eq $hriPort)
        needs_manual_cat=($null -eq $catPort)
    }
}

Export-ModuleMember -Function @('Get-RadioDeviceCatalog','Resolve-RadioDevicePortSelection')
