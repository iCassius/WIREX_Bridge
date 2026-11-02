$script:wirexStableLimits = [pscustomobject]@{
    MaximumArchiveBytes = [long]536870912
    MaximumUncompressedBytes = [long]2147483648
    MaximumManifestBytes = [long]2097152
    DefaultFileBytes = [long]1048576
}

function Get-WirexStableReleaseLimits {
    return $script:wirexStableLimits
}

function Test-WirexStableLengthWithinLimit {
    param([long]$Length,[long]$MaximumBytes)
    return ($Length -ge 0 -and $MaximumBytes -ge 0 -and $Length -le $MaximumBytes)
}

function Test-WirexStableRegularZipEntry {
    param([int]$ExternalAttributes,[long]$Length)
    if ($Length -lt 0) { return $false }
    $unixType = ($ExternalAttributes -shr 16) -band 0xf000
    if ($unixType -ne 0 -and $unixType -ne 0x8000) { return $false }
    if (($ExternalAttributes -band 0x10) -ne 0) { return $false }
    return $true
}

function New-WirexStableCanonicalPathMap {
    param([Parameter(Mandatory=$true)][string[]]$Paths)
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or $map.ContainsKey($path)) {
            throw 'Stable inventory contains an empty or case-insensitive duplicate path.'
        }
        $map[$path] = $path
    }
    return $map
}

function Resolve-WirexStableCanonicalPath {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][System.Collections.IDictionary]$CanonicalPathMap)
    if (-not $CanonicalPathMap.Contains($Path)) { throw 'Stable archive contains an unexpected path.' }
    $canonicalPath = [string]$CanonicalPathMap[$Path]
    if ($Path -cne $canonicalPath) { throw 'Stable archive path does not use its canonical spelling.' }
    return $canonicalPath
}

function Get-WirexStableMaximumFileBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    switch -CaseSensitive ($Path) {
        'WirexBridge.exe' { return [long]134217728 }
        'runtime/wirex_bridge.exe' { return [long]134217728 }
        'runtime/private/device-y.bin' { return [long]100 }
        'build-provenance.json' { return [long]2097152 }
        'launcher-build-provenance.json' { return [long]2097152 }
        'manifest.json' { return [long]$script:wirexStableLimits.MaximumManifestBytes }
        'README.md' { return [long]4194304 }
        'SOURCE.txt' { return [long]$script:wirexStableLimits.DefaultFileBytes }
        'runtime/ui/windows/bridge-ui.ps1' { return [long]4194304 }
        'runtime/ui/windows/BridgeSupervisor.cs' { return [long]4194304 }
        'runtime/ui/windows/MainWindow.xaml' { return [long]4194304 }
        'runtime/ui/windows/SettingsWindow.xaml' { return [long]4194304 }
    }
    if ($Path -like 'runtime/docs/*') { return [long]4194304 }
    if ($Path -match '^runtime/licenses/.*/(COPYING\.GPL-3\.0\.txt|source-manifest\.json)$') { return [long]4194304 }
    if ($Path -match '^runtime/licenses/.*/(NOTICE\.md|ISC-NOTICE\.txt)$') { return [long]$script:wirexStableLimits.DefaultFileBytes }
    if ($Path -match '^runtime/ui/windows/[^/]+\.(ps1|psm1)$') { return [long]$script:wirexStableLimits.DefaultFileBytes }
    if ($Path -ceq 'runtime/start-bm-radio-bridge.ps1' -or $Path -ceq 'runtime/start-ui.ps1' -or
        $Path -ceq 'runtime/bridge-user-config.psm1') { return [long]$script:wirexStableLimits.DefaultFileBytes }
    throw 'Stable inventory path has no fixed per-file size limit.'
}

Export-ModuleMember -Function Get-WirexStableReleaseLimits, Test-WirexStableLengthWithinLimit,
    Test-WirexStableRegularZipEntry, New-WirexStableCanonicalPathMap,
    Resolve-WirexStableCanonicalPath, Get-WirexStableMaximumFileBytes
