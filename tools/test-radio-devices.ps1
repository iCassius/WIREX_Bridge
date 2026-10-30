$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\ui\windows\RadioDevices.psm1'
Import-Module -Name $modulePath -Force
$script:assertionCount = 0
function Assert-RadioDevices {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "FAIL: $Message" }
}

$registry = @(
    [pscustomobject]@{ PortName='COM11'; FriendlyName=''; InstanceId=''; HardwareIds=@(); DeviceSource='registry' },
    [pscustomobject]@{ PortName='COM10'; FriendlyName=''; InstanceId=''; HardwareIds=@(); DeviceSource='registry' },
    [pscustomobject]@{ PortName='COM5'; FriendlyName=''; InstanceId=''; HardwareIds=@(); DeviceSource='registry' }
)
$cim = @(
    [pscustomobject]@{ DeviceID='COM11'; Name='Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM11)'; PNPDeviceID='USB\VID_10C4&PID_EA70&MI_00\A' },
    [pscustomobject]@{ DeviceID='COM10'; Name='Silicon Labs Dual CP2105 USB to UART Bridge: Standard COM Port (COM10)'; PNPDeviceID='USB\VID_10C4&PID_EA70&MI_01\A' },
    [pscustomobject]@{ DeviceID='COM5'; Name='USB 串行设备 (COM5)'; PNPDeviceID='USB\VID_26AA&PID_0030\A' },
    [pscustomobject]@{ DeviceID='COM8'; Name='Generic UART (COM8)'; PNPDeviceID='USB\VID_1234&PID_ABCD\A' }
)
$catalog = Get-RadioDeviceCatalog -SerialPortsInput $registry -CimPortsInput $cim
Assert-RadioDevices ($catalog.discovery_status -ceq 'synthetic') 'Injected fixtures must not enumerate physical devices.'
Assert-RadioDevices ($catalog.serial_ready -and $null -eq $catalog.PSObject.Properties['audio_ready'] -and $catalog.source_status.registry -ceq 'synthetic' -and $catalog.source_status.cim -ceq 'synthetic') 'The fixture exposes serial readiness independently from audio state and identifies synthetic sources.'
Assert-RadioDevices ($catalog.serial_ports.Count -eq 4 -and @($catalog.serial_ports | Select-Object -ExpandProperty PortName -Unique).Count -eq 4) 'Every discovered serial port is present once in serial_ports.'
Assert-RadioDevices ($catalog.hri_ports.Count -eq 1 -and $catalog.hri_ports[0].PortName -ceq 'COM5') 'VID_26AA/PID_0030 identifies the HRI port.'
Assert-RadioDevices ($catalog.cat_ports.Count -eq 3 -and @($catalog.cat_ports | Where-Object { $_.IsCatCandidate }).Count -eq 3) 'All non-HRI ports remain selectable in cat_ports, including an unknown device.'
Assert-RadioDevices (@($catalog.serial_ports | Where-Object { $_.PortName -ceq 'COM11' -and $_.DeviceSource.Count -eq 2 }).Count -eq 1) 'Registry and CIM evidence for one port is merged.'

$enhanced = @($catalog.cat_ports | Where-Object PortName -ceq 'COM11')[0]
$standard = @($catalog.cat_ports | Where-Object PortName -ceq 'COM10')[0]
$unknown = @($catalog.cat_ports | Where-Object PortName -ceq 'COM8')[0]
Assert-RadioDevices ($enhanced.CatMatchRank -gt $standard.CatMatchRank -and $enhanced.CatMatchReason -match 'Enhanced') 'CP2105 Enhanced outranks CP2105 Standard.'
Assert-RadioDevices ($unknown.IsCatCandidate -and $unknown.CatMatchRank -eq 0) 'Unrecognized serial ports stay hand-selectable without an automatic match.'

$auto = Resolve-RadioDevicePortSelection -Catalog $catalog -SavedHriPort 'auto' -SavedCatPort 'missing'
Assert-RadioDevices ($auto.hri_port -ceq 'COM5' -and $auto.cat_port -ceq 'COM11') 'Unique HRI and strongest Enhanced CAT matches are selected without hardcoded COM numbers.'
Assert-RadioDevices (-not $auto.needs_manual_hri -and -not $auto.needs_manual_cat) 'Successful automatic matches do not request manual selection.'

$saved = Resolve-RadioDevicePortSelection -Catalog $catalog -SavedHriPort COM5 -SavedCatPort COM10
Assert-RadioDevices ($saved.hri_port -ceq 'COM5' -and $saved.cat_port -ceq 'COM10' -and $saved.cat_match_reason -match '已保存') 'Available saved port choices take priority over inferred matching.'

$conflict = Resolve-RadioDevicePortSelection -Catalog $catalog -SavedHriPort COM5 -SavedCatPort COM5
Assert-RadioDevices ($conflict.hri_port -ceq 'COM5' -and $null -eq $conflict.cat_port -and $conflict.cat_conflict -and $conflict.needs_manual_cat) 'A saved CAT port that is also HRI is rejected instead of silently falling back.'

$twoEnhanced = Get-RadioDeviceCatalog -SerialPortsInput @(
    [pscustomobject]@{ PortName='COM5'; FriendlyName='USB Serial Device (COM5)'; InstanceId='USB\VID_26AA&PID_0030\A'; DeviceSource='input' },
    [pscustomobject]@{ PortName='COM11'; FriendlyName='CP2105 Enhanced COM Port (COM11)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\A'; DeviceSource='input' },
    [pscustomobject]@{ PortName='COM12'; FriendlyName='CP2105 Enhanced COM Port (COM12)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\B'; DeviceSource='input' }
)
$tie = Resolve-RadioDevicePortSelection -Catalog $twoEnhanced -SavedHriPort auto -SavedCatPort auto
Assert-RadioDevices ($null -eq $tie.cat_port -and $tie.needs_manual_cat) 'Multiple top-ranked Enhanced devices require a manual CAT choice.'

$emptyCatalog = Get-RadioDeviceCatalog -SerialPortsInput @() -CimPortsInput @()
$manual = Resolve-RadioDevicePortSelection -Catalog $emptyCatalog -SavedHriPort auto -SavedCatPort auto -ManualCatPort COM11
Assert-RadioDevices ($manual.cat_port -ceq 'COM11' -and $manual.cat_port_source -ceq 'manual' -and -not $manual.cat_conflict) 'A syntactically valid manual COM choice remains available when enumeration returns no ports.'
$manualConflict = Resolve-RadioDevicePortSelection -Catalog $catalog -SavedHriPort COM5 -SavedCatPort auto -ManualCatPort COM5
Assert-RadioDevices ($null -eq $manualConflict.cat_port -and $manualConflict.cat_conflict) 'A manual CAT port that conflicts with the saved/identified HRI port is rejected.'
$manualBad = $false
try { [void](Resolve-RadioDevicePortSelection -Catalog $emptyCatalog -ManualCatPort 'COM0') } catch { $manualBad = $true }
Assert-RadioDevices $manualBad 'Manual CAT input is validated as a COM1–COM999 name.'

$unknownOnlyCatalog = Get-RadioDeviceCatalog -SerialPortsInput @([pscustomobject]@{ PortName='COM7'; FriendlyName='Unidentified UART (COM7)'; InstanceId=''; HardwareIds=@(); DeviceSource='input' })
$manual = Resolve-RadioDevicePortSelection -Catalog $unknownOnlyCatalog -SavedHriPort auto -SavedCatPort auto
Assert-RadioDevices ($unknownOnlyCatalog.cat_ports.Count -eq 1 -and $manual.cat_port -eq $null -and $manual.needs_manual_cat) 'Unknown ports appear for manual selection, and no arbitrary CAT port is auto-selected.'

$aliasCatalog = Get-RadioDeviceCatalog -SerialPortsInput @(
    [pscustomobject]@{ PortName='\\.\COM011'; FriendlyName='CP2105 Enhanced COM Port (COM11)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\A'; DeviceSource='input' },
    [pscustomobject]@{ PortName='COM5'; FriendlyName='HRI (COM5)'; InstanceId=''; DeviceSource='input' }
)
Assert-RadioDevices ($aliasCatalog.serial_ports.Count -eq 2 -and @($aliasCatalog.serial_ports | Where-Object PortName -ceq 'COM11').Count -eq 1) 'COM namespace aliases are normalized and deduplicated.'

Write-Output "PASS: $script:assertionCount device catalog and match assertions (synthetic inputs only; no port opened)."
