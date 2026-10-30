#requires -Version 5.1
Set-StrictMode -Version Latest

$script:BmServerCatalogSource = 'https://www.pistar.uk/downloads/DMR_Hosts.txt'
$script:BmServerCatalogHostFileUpdated = '2026-10-28'
$script:BmServerCatalogChecked = '2026-10-30'

# Offline snapshot from Pi-Star's published DMR_Hosts.txt. 4602's IPv4
# address is retained as an alias so the existing local profile remains
# recognizable without replacing its saved address with a hostname.
$script:BmServerCatalog = @(
    [pscustomobject][ordered]@{
        selection_id = 'bm-china-4602'
        label = 'BM China · 4602'
        master_id = 4602
        region = 'China'
        hostname = '4602.master.brandmeister.network'
        port = 62031
        address_aliases = @('43.129.83.124')
    }
    [pscustomobject][ordered]@{
        selection_id = 'bm-south-korea-4501'
        label = 'BM South Korea · 4501'
        master_id = 4501
        region = 'South Korea'
        hostname = '4501.master.brandmeister.network'
        port = 62031
        address_aliases = @()
    }
    [pscustomobject][ordered]@{
        selection_id = 'bm-malaysia-5021'
        label = 'BM Malaysia · 5021'
        master_id = 5021
        region = 'Malaysia'
        hostname = '5021.master.brandmeister.network'
        port = 62031
        address_aliases = @()
    }
    [pscustomobject][ordered]@{
        selection_id = 'bm-us-3102'
        label = 'BM United States · 3102'
        master_id = 3102
        region = 'United States'
        hostname = '3102.master.brandmeister.network'
        port = 62031
        address_aliases = @()
    }
    [pscustomobject][ordered]@{
        selection_id = 'bm-greece-2022'
        label = 'BM Greece · 2022'
        master_id = 2022
        region = 'Greece'
        hostname = '2022.master.brandmeister.network'
        port = 62031
        address_aliases = @()
    }
)

function Get-BmServerCatalog {
    [CmdletBinding()]
    param()

    $catalog = @()
    foreach ($entry in $script:BmServerCatalog) {
        $catalog += [pscustomobject][ordered]@{
            selection_id = [string]$entry.selection_id
            label = [string]$entry.label
            master_id = [int]$entry.master_id
            region = [string]$entry.region
            hostname = [string]$entry.hostname
            port = [int]$entry.port
            address_aliases = @($entry.address_aliases)
            source_url = $script:BmServerCatalogSource
            source_hostfile_updated = $script:BmServerCatalogHostFileUpdated
            source_checked = $script:BmServerCatalogChecked
        }
    }
    return $catalog
}

function Test-BmServerAddressMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$Address
    )

    if ([string]::Equals($Address, [string]$Entry.hostname, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    foreach ($alias in @($Entry.address_aliases)) {
        if ([string]::Equals($Address, [string]$alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Resolve-BmServerSelection {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][string]$SelectionId,
        [Parameter()][AllowNull()][string]$ActualAddress,
        [Parameter()][ValidateRange(0, 65535)][int]$Port = 0
    )

    $catalog = @(Get-BmServerCatalog)
    $selected = $null
    $selectionSource = 'custom'

    if (-not [string]::IsNullOrWhiteSpace($SelectionId)) {
        if ([string]::Equals($SelectionId, 'custom', [System.StringComparison]::OrdinalIgnoreCase)) {
            $selectionSource = 'preference'
        } else {
            $selected = $catalog | Where-Object { $_.selection_id -ceq $SelectionId } | Select-Object -First 1
            if ($selected) { $selectionSource = 'preference' }
        }
    }

    if (-not $selected -and $selectionSource -ne 'preference' -and
        -not [string]::IsNullOrWhiteSpace($ActualAddress) -and $Port -gt 0) {
        foreach ($entry in $catalog) {
            if ($Port -eq [int]$entry.port -and (Test-BmServerAddressMatch -Entry $entry -Address $ActualAddress)) {
                $selected = $entry
                $selectionSource = 'profile'
                break
            }
        }
    }

    if (-not $selected -and $selectionSource -ne 'preference' -and
        [string]::IsNullOrWhiteSpace($ActualAddress) -and $Port -eq 0) {
        $selected = $catalog | Where-Object { $_.selection_id -ceq 'bm-china-4602' } | Select-Object -First 1
        $selectionSource = 'default'
    }

    $selectionIdValue = if ($selected) { [string]$selected.selection_id } else { 'custom' }
    $labelValue = if ($selected) { [string]$selected.label } else { '自定义服务器' }
    $effectiveAddress = if (-not [string]::IsNullOrWhiteSpace($ActualAddress)) {
        $ActualAddress
    } elseif ($selected) {
        [string]$selected.hostname
    } else {
        ''
    }
    $effectivePort = if ($Port -gt 0) {
        $Port
    } elseif ($selected) {
        [int]$selected.port
    } else {
        0
    }
    $profileMatchesSelection = $false
    if ($selected -and -not [string]::IsNullOrWhiteSpace($ActualAddress) -and $Port -gt 0) {
        $profileMatchesSelection = ($Port -eq [int]$selected.port) -and
            (Test-BmServerAddressMatch -Entry $selected -Address $ActualAddress)
    }

    return [pscustomobject][ordered]@{
        selection_id = $selectionIdValue
        label = $labelValue
        selection_source = $selectionSource
        is_custom = ($null -eq $selected)
        profile_matches_selection = [bool]$profileMatchesSelection
        profile_actualaddress = if ($null -eq $ActualAddress) { '' } else { $ActualAddress }
        profile_port = $Port
        effective_address = $effectiveAddress
        effective_port = $effectivePort
        catalog_entry = $selected
    }
}

function New-BmServerSelectionValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SelectionId,
        [Parameter()][AllowNull()][string]$ActualAddress,
        [Parameter()][ValidateRange(0, 65535)][int]$Port = 0
    )

    if ([string]::Equals($SelectionId, 'custom', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($ActualAddress)) {
            throw [System.ArgumentException]::new('自定义服务器地址不能为空。')
        }
        if ($ActualAddress.Length -gt 253 -or $ActualAddress -match '\s') {
            throw [System.ArgumentException]::new('自定义服务器地址必须是不含空格且不超过 253 个字符的地址。')
        }
        if ($Port -lt 1 -or $Port -gt 65535) {
            throw [System.ArgumentOutOfRangeException]::new('Port', '自定义服务器 UDP 端口必须为 1 到 65535。')
        }
        $targetAddress = $ActualAddress
        $targetPort = $Port
        $resolvedSelectionId = 'custom'
    } else {
        $entry = @(Get-BmServerCatalog | Where-Object { $_.selection_id -ceq $SelectionId }) | Select-Object -First 1
        if (-not $entry) {
            throw [System.ArgumentException]::new('所选服务器不在离线目录中；请使用自定义服务器或刷新应用目录。')
        }

        # Keep the existing 4602 IPv4 profile when the operator selects the
        # same known master. A deliberate choice of a different master uses
        # the hostname from the offline catalog.
        $sameSavedEndpoint = $false
        if (-not [string]::IsNullOrWhiteSpace($ActualAddress) -and $Port -eq [int]$entry.port) {
            $sameSavedEndpoint = Test-BmServerAddressMatch -Entry $entry -Address $ActualAddress
        }
        $targetAddress = if ($sameSavedEndpoint) { $ActualAddress } else { [string]$entry.hostname }
        $targetPort = [int]$entry.port
        $resolvedSelectionId = [string]$entry.selection_id
    }

    # Strict profile fields stay separate from the UI-only selector preference.
    return [pscustomobject][ordered]@{
        profile_fields = [pscustomobject][ordered]@{
            master = [string]$targetAddress
            master_port = [int]$targetPort
        }
        ui_preferences = [pscustomobject][ordered]@{
            bm_server_selection_id = [string]$resolvedSelectionId
        }
    }
}

Export-ModuleMember -Function Get-BmServerCatalog, Resolve-BmServerSelection, New-BmServerSelectionValues
