#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-BmServers {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Utf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-BmServers -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        -Message ("UTF-8 BOM missing from {0}" -f [System.IO.Path]::GetFileName($Path))
}

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui\windows\BmServers.psm1'
Assert-Utf8Bom -Path $PSCommandPath
Assert-Utf8Bom -Path $modulePath
Import-Module $modulePath -Force -ErrorAction Stop

$catalog = @(Get-BmServerCatalog)
Assert-BmServers ($catalog.Count -ge 5) 'catalog should contain multiple current BM masters'
Assert-BmServers ($catalog[0].selection_id -ceq 'bm-china-4602') '4602 must be first in the catalog'
Assert-BmServers ($catalog[0].hostname -ceq '4602.master.brandmeister.network') '4602 hostname must match the published hostfile'
Assert-BmServers ([int]$catalog[0].port -eq 62031) '4602 must use Homebrew UDP port 62031'
Assert-BmServers (@($catalog | Where-Object { $_.selection_id -ceq 'bm-south-korea-4501' }).Count -eq 1) 'catalog should include current BM 4501'
Assert-BmServers (@($catalog | Where-Object { $_.selection_id -ceq 'bm-us-3102' }).Count -eq 1) 'catalog should include current BM 3102'
Assert-BmServers ($catalog[0].source_hostfile_updated -ceq '2026-10-28') 'catalog should retain the hostfile update date'
Assert-BmServers ($catalog[0].source_checked -ceq '2026-10-30') 'catalog should retain the local verification date'

$defaultState = Resolve-BmServerSelection
Assert-BmServers ($defaultState.selection_id -ceq 'bm-china-4602') 'empty selector should default to BM China 4602'
Assert-BmServers ($defaultState.effective_address -ceq '4602.master.brandmeister.network') 'empty profile should display the 4602 hostname as its effective default'
Assert-BmServers ([int]$defaultState.effective_port -eq 62031) 'empty profile should use the catalog UDP port as its displayed default'

$saved4602 = Resolve-BmServerSelection -ActualAddress '43.129.83.124' -Port 62031
Assert-BmServers ($saved4602.selection_id -ceq 'bm-china-4602') 'saved 4602 IPv4 should resolve to the 4602 selector'
Assert-BmServers ($saved4602.selection_source -ceq 'profile') 'saved address matching should be identified as profile-derived'
Assert-BmServers ($saved4602.profile_matches_selection) 'saved IPv4 and port should match the 4602 selector'
Assert-BmServers ($saved4602.profile_actualaddress -ceq '43.129.83.124') 'resolving the selector must preserve the saved profile address'
Assert-BmServers ([int]$saved4602.profile_port -eq 62031) 'resolving the selector must preserve the saved profile port'

$preferenceState = Resolve-BmServerSelection -SelectionId 'bm-china-4602' -ActualAddress '43.129.83.124' -Port 62031
Assert-BmServers ($preferenceState.selection_source -ceq 'preference') 'explicit selector preference should win'
Assert-BmServers ($preferenceState.profile_matches_selection) 'explicit 4602 preference should still recognize saved IPv4'
Assert-BmServers ($preferenceState.profile_actualaddress -ceq '43.129.83.124') 'selector preference must not rewrite saved profile data'

$customState = Resolve-BmServerSelection -ActualAddress 'private-master.example' -Port 62031
Assert-BmServers ($customState.is_custom) 'unlisted hand-entered master must remain usable as custom'
Assert-BmServers ($customState.profile_actualaddress -ceq 'private-master.example') 'custom address must be preserved'

$savedValues = New-BmServerSelectionValues -SelectionId 'bm-china-4602' -ActualAddress '43.129.83.124' -Port 62031
Assert-BmServers ($savedValues.profile_fields.master -ceq '43.129.83.124') 'explicit selection of the current 4602 endpoint should retain its IPv4'
Assert-BmServers ([int]$savedValues.profile_fields.master_port -eq 62031) 'profile target should retain the existing 4602 port'
Assert-BmServers ($savedValues.ui_preferences.bm_server_selection_id -ceq 'bm-china-4602') 'selector id must be stored separately as UI preference'
Assert-BmServers ($null -eq $savedValues.profile_fields.PSObject.Properties['bm_server_selection_id']) 'selector id must not enter the strict profile fields'

$newMaster = New-BmServerSelectionValues -SelectionId 'bm-south-korea-4501' -ActualAddress '43.129.83.124' -Port 62031
Assert-BmServers ($newMaster.profile_fields.master -ceq '4501.master.brandmeister.network') 'an explicit different selection should use its catalog hostname'
Assert-BmServers ([int]$newMaster.profile_fields.master_port -eq 62031) 'catalog master should retain its published port'

$customValues = New-BmServerSelectionValues -SelectionId custom -ActualAddress 'my-master.example' -Port 62099
Assert-BmServers ($customValues.profile_fields.master -ceq 'my-master.example') 'custom selector should accept a hand-entered address'
Assert-BmServers ([int]$customValues.profile_fields.master_port -eq 62099) 'custom selector should accept a hand-entered port'

$failedUnknown = $false
try { [void](New-BmServerSelectionValues -SelectionId 'bm-not-in-catalog' -ActualAddress 'custom.example' -Port 62031) }
catch { $failedUnknown = $true }
Assert-BmServers $failedUnknown 'unknown selection ids must be rejected instead of silently mapped'

Write-Output ("PASS: test-bm-servers.ps1 ({0} assertions; PowerShell {1})" -f $script:assertionCount, $PSVersionTable.PSVersion)
