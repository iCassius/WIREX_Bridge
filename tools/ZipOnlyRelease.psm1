$ErrorActionPreference = 'Stop'

$script:zipOnlyVersions = @('v0.1.1-test.2', 'v0.1.1')
$script:zipOnlyRuntimeSourceFiles = @(
    @{ Source='tools\bridge-user-config.psm1'; Destination='runtime/bridge-user-config.psm1' },
    @{ Source='tools\start-bm-radio-bridge.ps1'; Destination='runtime/start-bm-radio-bridge.ps1' },
    @{ Source='tools\start-ui.ps1'; Destination='runtime/start-ui.ps1' },
    @{ Source='ui\windows\BmManagement.psm1'; Destination='runtime/ui/windows/BmManagement.psm1' },
    @{ Source='ui\windows\BmManagementUi.ps1'; Destination='runtime/ui/windows/BmManagementUi.ps1' },
    @{ Source='ui\windows\BmServers.psm1'; Destination='runtime/ui/windows/BmServers.psm1' },
    @{ Source='ui\windows\bridge-ui.ps1'; Destination='runtime/ui/windows/bridge-ui.ps1' },
    @{ Source='ui\windows\BridgeSupervisor.cs'; Destination='runtime/ui/windows/BridgeSupervisor.cs' },
    @{ Source='ui\windows\ChannelActivationState.psm1'; Destination='runtime/ui/windows/ChannelActivationState.psm1' },
    @{ Source='ui\windows\MainWindow.xaml'; Destination='runtime/ui/windows/MainWindow.xaml' },
    @{ Source='ui\windows\PortableConfig.psm1'; Destination='runtime/ui/windows/PortableConfig.psm1' },
    @{ Source='ui\windows\UiLocalization.psm1'; Destination='runtime/ui/windows/UiLocalization.psm1' },
    @{ Source='ui\windows\RadioCat.psm1'; Destination='runtime/ui/windows/RadioCat.psm1' },
    @{ Source='ui\windows\RadioCatUi.ps1'; Destination='runtime/ui/windows/RadioCatUi.ps1' },
    @{ Source='ui\windows\RadioDevices.psm1'; Destination='runtime/ui/windows/RadioDevices.psm1' },
    @{ Source='ui\windows\RadioIdentity.psm1'; Destination='runtime/ui/windows/RadioIdentity.psm1' },
    @{ Source='ui\windows\SettingsWindow.xaml'; Destination='runtime/ui/windows/SettingsWindow.xaml' },
    @{ Source='third_party\dmr_signal\COPYING.GPL-3.0.txt'; Destination='runtime/licenses/dmr_signal/COPYING.GPL-3.0.txt' },
    @{ Source='third_party\dmr_signal\NOTICE.md'; Destination='runtime/licenses/dmr_signal/NOTICE.md' },
    @{ Source='third_party\droidstar_mbe\COPYING.GPL-3.0.txt'; Destination='runtime/licenses/droidstar_mbe/COPYING.GPL-3.0.txt' },
    @{ Source='third_party\droidstar_mbe\ISC-NOTICE.txt'; Destination='runtime/licenses/droidstar_mbe/ISC-NOTICE.txt' }
)
$script:zipOnlyRuntimeFiles = @($script:zipOnlyRuntimeSourceFiles | ForEach-Object { [string]$_.Destination }) + @(
    'runtime/private/device-y.bin',
    'runtime/wirex_bridge.exe'
)
$script:zipOnlyPackageFiles = @('WirexBridge.exe') + $script:zipOnlyRuntimeFiles
$script:zipOnlyDirectories = @(
    'runtime',
    'runtime/licenses',
    'runtime/licenses/dmr_signal',
    'runtime/licenses/droidstar_mbe',
    'runtime/private',
    'runtime/ui',
    'runtime/ui/windows'
)
$script:zipOnlyApprovedFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'

function Test-WirexZipOnlyVersion {
    param([Parameter(Mandatory=$true)][string]$Version)
    return ($script:zipOnlyVersions -ccontains $Version)
}

function Get-WirexZipOnlyReleaseVersions { return @($script:zipOnlyVersions) }

function Get-WirexZipOnlyReleaseProfile {
    param([Parameter(Mandatory=$true)][string]$Version)
    if (-not (Test-WirexZipOnlyVersion -Version $Version)) { throw 'Unknown ZIP-only release profile.' }
    $archiveName = 'WIREX_Bridge_' + $Version + '.zip'
    $assetMap = [ordered]@{}
    foreach ($path in $script:zipOnlyPackageFiles) { $assetMap[[string]$path] = [string]$path }
    return [pscustomobject]@{
        Version = $Version
        ArchiveName = $archiveName
        IsPrerelease = ($Version -ceq 'v0.1.1-test.2')
        PackageFiles = @($script:zipOnlyPackageFiles)
        Directories = @($script:zipOnlyDirectories)
        SourceFiles = @($script:zipOnlyRuntimeSourceFiles)
        AssetMap = $assetMap
        TestNames = @()
        ReleaseScope = 'R126 ZIP-only portable desktop package'
        NotIncluded = @()
    }
}

function Test-WirexZipOnlyPackageInventory {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [Parameter(Mandatory=$true)][string]$Version)
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    if (-not [System.IO.Directory]::Exists($root)) { throw 'ZIP-only package directory is missing.' }
    $items = @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'ZIP-only package contains a reparse point.'
        }
    }
    $actualFiles = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $_.FullName.Substring($root.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\','/')
    } | Sort-Object -CaseSensitive)
    $expectedFiles = @($profile.PackageFiles | Sort-Object -CaseSensitive)
    if (($actualFiles -join "`n") -cne ($expectedFiles -join "`n")) {
        throw 'ZIP-only package files differ from the fixed runtime inventory.'
    }
    $actualDirectories = @($items | Where-Object { $_.PSIsContainer } | ForEach-Object {
        $_.FullName.Substring($root.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\','/')
    } | Sort-Object -CaseSensitive)
    $expectedDirectories = @($profile.Directories | Sort-Object -CaseSensitive)
    if (($actualDirectories -join "`n") -cne ($expectedDirectories -join "`n")) {
        throw 'ZIP-only package directories differ from the fixed runtime inventory.'
    }
    $rootFiles = @($actualFiles | Where-Object { $_ -notmatch '/' })
    if ($rootFiles.Count -ne 1 -or $rootFiles[0] -cne 'WirexBridge.exe') {
        throw 'ZIP-only package root must contain only WirexBridge.exe.'
    }
    $fixturePath = Join-Path $root 'runtime\private\device-y.bin'
    $fixture = Get-Item -LiteralPath $fixturePath -ErrorAction Stop
    $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fixture.Length -ne 100 -or $fixtureHash -cne $script:zipOnlyApprovedFixtureSha256) {
        throw 'ZIP-only package contains a different HRI protocol template.'
    }
    return [pscustomobject]@{ FileCount=$actualFiles.Count; DirectoryCount=$actualDirectories.Count; Files=$actualFiles; Directories=$actualDirectories }
}

function New-WirexZipOnlyPackageTree {
    param([Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$Version,[Parameter(Mandatory=$true)][string]$LauncherExecutable,
        [Parameter(Mandatory=$true)][string]$NativeExecutable,[Parameter(Mandatory=$true)][string]$FixturePath)
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    $repository = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    if ([System.IO.Directory]::Exists($root) -or [System.IO.File]::Exists($root)) { throw 'ZIP-only package output already exists.' }
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        foreach ($relativeDirectory in $profile.Directories) {
            [System.IO.Directory]::CreateDirectory((Join-Path $root ([string]$relativeDirectory).Replace('/',[System.IO.Path]::DirectorySeparatorChar))) | Out-Null
        }
        Copy-Item -LiteralPath $LauncherExecutable -Destination (Join-Path $root 'WirexBridge.exe') -ErrorAction Stop
        foreach ($entry in $profile.SourceFiles) {
            $source = Join-Path $repository ([string]$entry.Source)
            $destination = Join-Path $root ([string]$entry.Destination).Replace('/',[System.IO.Path]::DirectorySeparatorChar)
            if (-not [System.IO.File]::Exists($source)) { throw ('Required ZIP-only runtime source is missing: ' + [string]$entry.Source) }
            Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
        }
        Copy-Item -LiteralPath $NativeExecutable -Destination (Join-Path $root 'runtime\wirex_bridge.exe') -ErrorAction Stop
        Copy-Item -LiteralPath $FixturePath -Destination (Join-Path $root 'runtime\private\device-y.bin') -ErrorAction Stop
        [void](Test-WirexZipOnlyPackageInventory -PackageRoot $root -Version $Version)
        return $root
    } catch {
        throw
    }
}

function Get-WirexZipOnlyFileRecords {
    param([Parameter(Mandatory=$true)][string]$PackageRoot)
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    $records = @()
    foreach ($relativePath in $script:zipOnlyPackageFiles) {
        $filePath = Join-Path $root $relativePath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $filePath -ErrorAction Stop
        $records += ,([ordered]@{
            path = [string]$relativePath
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    return $records
}

function New-WirexZipOnlyAuditManifest {
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$AuditDirectory,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$SourceCommit,
        [Parameter(Mandatory=$true)][string]$NativeSourceCommit,
        [Parameter(Mandatory=$true)][string]$LauncherSourceCommit,
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][object[]]$PassedTests,
        [Parameter(Mandatory=$true)][string]$NativeBuildProvenanceSha256,
        [Parameter(Mandatory=$true)][string]$LauncherBuildProvenanceSha256
    )
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    [void](Test-WirexZipOnlyPackageInventory -PackageRoot $PackageRoot -Version $Version)
    foreach ($commit in @($SourceCommit,$NativeSourceCommit,$LauncherSourceCommit)) {
        if ([string]$commit -cnotmatch '^[0-9a-f]{40}$') { throw 'ZIP-only audit source commit is invalid.' }
    }
    $auditRoot = [System.IO.Path]::GetFullPath($AuditDirectory)
    if ([System.IO.Directory]::Exists($auditRoot) -or [System.IO.File]::Exists($auditRoot)) {
        throw 'ZIP-only audit directory already exists; refusing to overwrite it.'
    }
    [System.IO.Directory]::CreateDirectory($auditRoot) | Out-Null
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_zip_only_portable'
        package_status = 'awaiting_root_audit'
        version = $Version
        tag_candidate = $Version
        archive_name = $profile.ArchiveName
        source = [ordered]@{ repository=$Repository; commit=$SourceCommit; working_tree_clean=$true }
        build = [ordered]@{
            result='passed'; native_source_commit=$NativeSourceCommit; launcher_source_commit=$LauncherSourceCommit
            native_inputs_unchanged=$true; native_input_paths=@('CMakeLists.txt','include/','src/','tests/','third_party/','tools/build-bm-bridge.ps1')
            passed_tests=@($PassedTests); passed_test_count=@($PassedTests).Count
            native_build_provenance_sha256=$NativeBuildProvenanceSha256.ToLowerInvariant()
            launcher_build_provenance_sha256=$LauncherBuildProvenanceSha256.ToLowerInvariant()
        }
        package = [ordered]@{ root_files=@('WirexBridge.exe'); directories=@($profile.Directories); first_run_config='config.json' }
        files = @(Get-WirexZipOnlyFileRecords -PackageRoot $PackageRoot)
        archive = $null
    }
    $manifestPath = Join-Path $auditRoot 'manifest.json'
    $json = ConvertTo-Json -InputObject $manifest -Depth 10
    [System.IO.File]::WriteAllText($manifestPath,$json + "`n",(New-Object System.Text.UTF8Encoding($false)))
    return $manifestPath
}

function Get-WirexZipOnlyAuditManifest {
    param([Parameter(Mandatory=$true)][string]$AuditManifestPath, [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$PackageRoot, [switch]$RequireRootAudit)
    $path = [System.IO.Path]::GetFullPath($AuditManifestPath)
    if (-not [System.IO.File]::Exists($path)) { throw 'ZIP-only private audit manifest is missing.' }
    try { $manifest = [System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'ZIP-only private audit manifest is invalid.' }
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    if ([int]$manifest.schema_version -ne 1 -or [string]$manifest.package_kind -cne 'wirex_bridge_zip_only_portable' -or
        [string]$manifest.version -cne $Version -or [string]$manifest.tag_candidate -cne $Version -or
        [string]$manifest.archive_name -cne $profile.ArchiveName -or $manifest.source.working_tree_clean -ne $true -or
        [string]$manifest.build.result -cne 'passed' -or
        ($RequireRootAudit -and [string]$manifest.package_status -cne 'root_audit_passed') -or
        (-not $RequireRootAudit -and [string]$manifest.package_status -notin @('awaiting_root_audit','root_audit_passed'))) {
        throw 'ZIP-only private audit metadata does not match the requested tag or review state.'
    }
    foreach ($commit in @([string]$manifest.source.commit,[string]$manifest.build.native_source_commit,[string]$manifest.build.launcher_source_commit)) {
        if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'ZIP-only audit source commit is invalid.' }
    }
    if ([string]$manifest.build.launcher_source_commit -cne [string]$manifest.source.commit -or
        $manifest.build.native_inputs_unchanged -ne $true -or
        (@($manifest.build.native_input_paths) -join '|') -cne 'CMakeLists.txt|include/|src/|tests/|third_party/|tools/build-bm-bridge.ps1') {
        throw 'ZIP-only audit does not prove the launcher and native source relationship.'
    }
    $inventory = Test-WirexZipOnlyPackageInventory -PackageRoot $PackageRoot -Version $Version
    $manifestFileCount = @($manifest.files).Count
    if ($manifestFileCount -ne $profile.PackageFiles.Count) {
        throw ('ZIP-only private audit file count is incorrect: ' + $manifestFileCount + ' / ' + $profile.PackageFiles.Count + '.')
    }
    $records = @{}
    foreach ($record in @($manifest.files)) {
        $entryPath = [string]$record.path
        if ($entryPath -notin $profile.PackageFiles -or $records.ContainsKey($entryPath)) { throw 'ZIP-only audit has an unknown or duplicate file path.' }
        $fullPath = Join-Path ([System.IO.Path]::GetFullPath($PackageRoot)) $entryPath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([long]$record.length_bytes -ne [long]$item.Length -or [string]$record.sha256 -cne $hash) {
            throw 'ZIP-only package file differs from the private audit record.'
        }
        $records[$entryPath] = $record
    }
    return [pscustomobject]@{ Manifest=$manifest; Records=$records; Inventory=$inventory; Path=$path }
}

function Test-WirexZipOnlyArchive {
    param([Parameter(Mandatory=$true)][string]$ArchivePath,[Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$AuditManifestPath,[Parameter(Mandatory=$true)][string]$PackageRoot)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $validated = Get-WirexZipOnlyAuditManifest -AuditManifestPath $AuditManifestPath -Version $Version -PackageRoot $PackageRoot
    $archive = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($ArchivePath))
    try {
        $expected = @($validated.Manifest.files | ForEach-Object { [string]$_.path } | Sort-Object -CaseSensitive)
        $actual = @($archive.Entries | ForEach-Object { [string]$_.FullName } | Sort-Object -CaseSensitive)
        if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'ZIP entries differ from the fixed ZIP-only package inventory.' }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(^/|(^|/)\.\.?(/|$)|:|\\)' -or [long]$entry.Length -gt 134217728) {
                throw 'ZIP contains an unsafe path or oversized entry.'
            }
            if (($entry.ExternalAttributes -band 0x400) -ne 0 -or ($entry.ExternalAttributes -band 0xa0000000) -ne 0) {
                throw 'ZIP contains a non-regular or reparse entry.'
            }
            $record = $validated.Records[[string]$entry.FullName]
            if ($null -eq $record -or [long]$entry.Length -ne [long]$record.length_bytes) {
                throw 'ZIP entry size differs from the private audit inventory.'
            }
            $stream = $entry.Open()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $buffer = New-Object byte[] 65536
                while (($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0) { [void]$sha.TransformBlock($buffer,0,$read,$buffer,0) }
                [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
                $hash = [System.BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
                if ($hash -cne [string]$record.sha256) { throw 'ZIP entry differs from the private audit SHA-256.' }
            } finally { $stream.Dispose(); $sha.Dispose() }
        }
        return [pscustomobject]@{ EntryCount=$archive.Entries.Count; ArchiveLength=[long](Get-Item -LiteralPath $ArchivePath).Length }
    } finally { $archive.Dispose() }
}

function New-WirexZipOnlyArchive {
    param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$AuditManifestPath,
        [Parameter(Mandatory=$true)][string]$Version,[Parameter(Mandatory=$true)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    $audit = Get-WirexZipOnlyAuditManifest -AuditManifestPath $AuditManifestPath -Version $Version -PackageRoot $PackageRoot
    $target = [System.IO.Path]::GetFullPath($ArchivePath)
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) { throw 'ZIP output already exists; refusing to overwrite it.' }
    $stream = [System.IO.File]::Open($target,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        foreach ($relativePath in $profile.PackageFiles) {
            $entry = $archive.CreateEntry([string]$relativePath,[System.IO.Compression.CompressionLevel]::Optimal)
            $input = [System.IO.File]::OpenRead((Join-Path ([System.IO.Path]::GetFullPath($PackageRoot)) ([string]$relativePath).Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
            $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } catch {
        if ($null -ne $archive) { $archive.Dispose(); $archive=$null }
        $stream.Dispose()
        if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) }
        throw
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    $result = Test-WirexZipOnlyArchive -ArchivePath $target -Version $Version -AuditManifestPath $audit.Path -PackageRoot $PackageRoot
    $manifest = $audit.Manifest
    $manifest.archive = [ordered]@{
        name = $profile.ArchiveName
        length_bytes = [long](Get-Item -LiteralPath $target).Length
        sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $json = ConvertTo-Json -InputObject $manifest -Depth 10
    [System.IO.File]::WriteAllText($audit.Path,$json + "`n",(New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path=$target; EntryCount=$result.EntryCount; Length=[long](Get-Item -LiteralPath $target).Length; Sha256=$manifest.archive.sha256 }
}

function Expand-WirexZipOnlyArchive {
    param([Parameter(Mandatory=$true)][string]$ArchivePath,[Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $profile = Get-WirexZipOnlyReleaseProfile -Version $Version
    $archivePathFull = [System.IO.Path]::GetFullPath($ArchivePath)
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination)
    if ([System.IO.File]::Exists($destinationRoot)) { throw 'ZIP extraction destination is a file.' }
    if ([System.IO.Directory]::Exists($destinationRoot)) {
        if (@(Get-ChildItem -LiteralPath $destinationRoot -Force -ErrorAction Stop).Count -ne 0) {
            throw 'ZIP extraction destination must be empty.'
        }
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePathFull)
    try {
        $expected = @($profile.PackageFiles | Sort-Object -CaseSensitive)
        $actual = @($archive.Entries | ForEach-Object { [string]$_.FullName } | Sort-Object -CaseSensitive)
        if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Downloaded ZIP does not contain the fixed R126 file inventory.' }
        if ([long](Get-Item -LiteralPath $archivePathFull).Length -gt 536870912) { throw 'Downloaded ZIP exceeds the fixed size limit.' }
        [System.IO.Directory]::CreateDirectory($destinationRoot) | Out-Null
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(^/|(^|/)\.\.?(/|$)|:|\\)' -or [long]$entry.Length -gt 134217728 -or
                ($entry.ExternalAttributes -band 0x400) -ne 0 -or ($entry.ExternalAttributes -band 0xa0000000) -ne 0) {
                throw 'Downloaded ZIP contains an unsafe entry.'
            }
            $full = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot $entry.FullName.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
            $prefix = $destinationRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Downloaded ZIP entry escaped its staging directory.' }
            $parent = [System.IO.Path]::GetDirectoryName($full)
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            $out = [System.IO.File]::Open($full,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
            $input = $entry.Open()
            try { $input.CopyTo($out) } finally { $input.Dispose(); $out.Dispose() }
        }
    } catch {
        $archive.Dispose()
        throw
    }
    $archive.Dispose()
    [void](Test-WirexZipOnlyPackageInventory -PackageRoot $destinationRoot -Version $Version)
}

Export-ModuleMember -Function Test-WirexZipOnlyVersion, Get-WirexZipOnlyReleaseVersions, Get-WirexZipOnlyReleaseProfile,
    Test-WirexZipOnlyPackageInventory, New-WirexZipOnlyPackageTree, Get-WirexZipOnlyFileRecords, New-WirexZipOnlyAuditManifest,
    Get-WirexZipOnlyAuditManifest, Test-WirexZipOnlyArchive, New-WirexZipOnlyArchive, Expand-WirexZipOnlyArchive
