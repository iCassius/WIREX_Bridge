[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
if (-not [System.IO.Directory]::Exists($workRoot)) { throw 'build/_work is required for the isolated R126 package test.' }
. (Join-Path $PSScriptRoot 'package-release.ps1')

$script:assertions = 0
function Assert-R126 {
    param([bool]$Condition,[string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('R126 ZIP-only assertion failed: ' + $Message) }
}

$testRoot = Join-Path $workRoot ('r126-package-test-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $testRoot 'package'
$auditRoot = Join-Path $testRoot 'private-audit'
$distributionRoot = Join-Path $testRoot 'distribution'
$extractRoot = Join-Path $testRoot 'extracted'
$created = $false
try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $created = $true
    $fixturePath = Join-Path $appRoot 'private\fixtures\device-y.bin'
    $previousPackage = Join-Path $appRoot 'build\releases\v0.1.0'
    $launcherPath = Join-Path $previousPackage 'WirexBridge.exe'
    $nativePath = Join-Path $previousPackage 'runtime\wirex_bridge.exe'
    foreach ($requiredPath in @($fixturePath,$launcherPath,$nativePath)) {
        if (-not [System.IO.File]::Exists($requiredPath)) { throw 'A read-only package fixture required for the producer test is missing.' }
    }

    $testVersions = @('v0.1.1-test.2','v0.1.1')
    foreach ($version in $testVersions) {
        $profile = Get-ReleaseProfile -Version $version
        Assert-R126 ($profile.PackageFiles.Count -eq 24) ($version + ' has the fixed 24-file runtime inventory')
        Assert-R126 (@($profile.PackageFiles | Where-Object { $_ -notmatch '/' }).Count -eq 1 -and
            $profile.PackageFiles -ccontains 'WirexBridge.exe') ($version + ' has only the launcher at package root')
        Assert-R126 ($profile.PackageFiles -cnotcontains 'README.md' -and $profile.PackageFiles -cnotcontains 'SOURCE.txt' -and
            $profile.PackageFiles -cnotcontains 'manifest.json' -and $profile.PackageFiles -cnotcontains 'SHA256SUMS.txt') `
            ($version + ' excludes user-facing audit and readme files')
        Assert-R126 (@($profile.PackageFiles | Where-Object { $_ -match '(^|/)docs/' }).Count -eq 0) ($version + ' excludes runtime documentation')
        Assert-R126 ($profile.PackageFiles -ccontains 'runtime/ui/windows/bridge-ui.ps1' -and
            $profile.PackageFiles -ccontains 'runtime/ui/windows/PortableConfig.psm1' -and
            $profile.PackageFiles -ccontains 'runtime/start-ui.ps1' -and
            $profile.PackageFiles -ccontains 'runtime/start-bm-radio-bridge.ps1' -and
            $profile.PackageFiles -ccontains 'runtime/ui/windows/UiLocalization.psm1' -and
            $profile.PackageFiles -ccontains 'runtime/wirex_bridge.exe' -and
            $profile.PackageFiles -ccontains 'runtime/private/device-y.bin') ($version + ' retains all direct startup dependencies')
        foreach ($licensePath in @(
            'runtime/licenses/dmr_signal/COPYING.GPL-3.0.txt',
            'runtime/licenses/dmr_signal/NOTICE.md',
            'runtime/licenses/droidstar_mbe/COPYING.GPL-3.0.txt',
            'runtime/licenses/droidstar_mbe/ISC-NOTICE.txt'
        )) { Assert-R126 ($profile.PackageFiles -ccontains $licensePath) ($version + ' keeps ' + $licensePath) }
    }
    Assert-R126 ((Get-ReleaseProfile -Version 'v0.1.0').PackageFiles -ccontains 'manifest.json') 'published v0.1.0 profile remains unchanged'

    $candidate = Get-ReleaseProfile -Version 'v0.1.1-test.2'
    [void](New-WirexZipOnlyPackageTree -RepositoryRoot $appRoot -PackageRoot $packageRoot -Version 'v0.1.1-test.2' `
        -LauncherExecutable $launcherPath -NativeExecutable $nativePath -FixturePath $fixturePath)
    $inventory = Assert-ReleasePackageInventory -PackageRoot $packageRoot -Version 'v0.1.1-test.2'
    Assert-R126 ($inventory.FileCount -eq 24 -and $inventory.DirectoryCount -eq 7) 'actual package producer emits the exact file and directory inventory'
    Assert-R126 (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'config.json'))) 'generic package does not contain config.json'

    $fakeCommit = '0123456789abcdef0123456789abcdef01234567'
    $auditPath = New-WirexZipOnlyAuditManifest -PackageRoot $packageRoot -AuditDirectory $auditRoot -Version 'v0.1.1-test.2' `
        -SourceCommit $fakeCommit -NativeSourceCommit $fakeCommit -LauncherSourceCommit $fakeCommit `
        -Repository 'https://github.com/iCassius/WIREX_Bridge.git' -PassedTests @($candidate.TestNames) `
        -NativeBuildProvenanceSha256 ('1' * 64) -LauncherBuildProvenanceSha256 ('2' * 64)
    [System.IO.Directory]::CreateDirectory($distributionRoot) | Out-Null
    $archivePath = Join-Path $distributionRoot 'WIREX_Bridge_v0.1.1-test.2.zip'
    $archive = New-WirexZipOnlyArchive -PackageRoot $packageRoot -AuditManifestPath $auditPath `
        -Version 'v0.1.1-test.2' -ArchivePath $archivePath
    $distributionItems = @(Get-ChildItem -LiteralPath $distributionRoot -Force)
    Assert-R126 ($distributionItems.Count -eq 1 -and $distributionItems[0].Name -ceq 'WIREX_Bridge_v0.1.1-test.2.zip') `
        'distribution directory contains exactly one ZIP asset'
    Assert-R126 ($archive.EntryCount -eq 24) 'ZIP archive contains only the approved runtime files'
    [void](Expand-WirexZipOnlyArchive -ArchivePath $archivePath -Version 'v0.1.1-test.2' -Destination $extractRoot)
    $extractedInventory = Test-WirexZipOnlyPackageInventory -PackageRoot $extractRoot -Version 'v0.1.1-test.2'
    Assert-R126 ($extractedInventory.FileCount -eq 24 -and -not (Test-Path -LiteralPath (Join-Path $extractRoot 'config.json'))) `
        'real ZIP extractor restores the root-only launcher and excludes generated configuration'

    . (Join-Path $appRoot 'tools\download-release.ps1') -Tag 'v0.1.1-test.2' -Destination (Join-Path $testRoot 'unused')
    $script:r126ZipBytes = [System.IO.File]::ReadAllBytes($archivePath)
    $zipHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:r126MockRelease = [pscustomobject]@{
        tag_name='v0.1.1-test.2'
        assets=@([pscustomobject]@{
            id=761; name='WIREX_Bridge_v0.1.1-test.2.zip'; state='uploaded'
            size=[long]$script:r126ZipBytes.Length; digest=('sha256:' + $zipHash)
        })
    }
    function Get-GitCredentialToken { return 'synthetic-r126-token' }
    function Get-ReleaseForTag {
        param([string]$RequestedTag,[string]$Token,[switch]$AllowDraft)
        if ($RequestedTag -cne 'v0.1.1-test.2') { throw 'Unexpected synthetic release tag.' }
        return $script:r126MockRelease
    }
    function Get-ReleaseAssetResponse {
        param([long]$AssetId,[string]$Token)
        if ($AssetId -ne 761) { throw 'Unexpected synthetic asset ID.' }
        $stream = [System.IO.MemoryStream]::new([byte[]]$script:r126ZipBytes)
        $response = [pscustomobject]@{ ContentLength=[long]$script:r126ZipBytes.Length; Stream=$stream }
        Add-Member -InputObject $response -MemberType ScriptMethod -Name GetResponseStream -Value { return $this.Stream }
        Add-Member -InputObject $response -MemberType ScriptMethod -Name Close -Value { }
        return $response
    }
    $downloadDestination = Join-Path $testRoot 'downloaded'
    Invoke-ReleaseDownload -RequestedTag 'v0.1.1-test.2' -OutputDirectory $downloadDestination
    $downloadedInventory = Test-WirexZipOnlyPackageInventory -PackageRoot $downloadDestination -Version 'v0.1.1-test.2'
    Assert-R126 ($downloadedInventory.FileCount -eq 24 -and
        -not (Test-Path -LiteralPath (Join-Path $downloadDestination 'config.json'))) `
        'ZIP-only downloader verifies the GitHub digest and extracts the fixed inventory without config.json'

    $script:r126MockRelease.assets[0].digest = 'sha256:' + ('0' * 64)
    $badDigestDestination = Join-Path $testRoot 'bad-digest'
    $badDigestRejected = $false
    try { Invoke-ReleaseDownload -RequestedTag 'v0.1.1-test.2' -OutputDirectory $badDigestDestination }
    catch { $badDigestRejected = $true }
    $leftoverScratch = @(Get-ChildItem -LiteralPath $testRoot -Force -Directory | Where-Object {
        $_.Name -like '.wirex-release-assets-*' -or $_.Name -like '.wirex-release-staging-*'
    })
    Assert-R126 ($badDigestRejected -and -not (Test-Path -LiteralPath $badDigestDestination) -and $leftoverScratch.Count -eq 0) `
        'ZIP-only downloader rejects a mismatched GitHub digest and cleans its new scratch directories'

    Write-Output ('R126 ZIP-only producer and downloader checks passed: ' + $script:assertions + ' assertions; no user configuration file was read.')
} finally {
    if ($created -and [System.IO.Directory]::Exists($testRoot)) {
        $resolvedWork = [System.IO.Path]::GetFullPath($workRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $resolvedTarget = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTarget.StartsWith($resolvedWork,[System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTarget) -notmatch '^r126-package-test-[0-9a-f]{32}$') {
            throw 'Refusing to remove an R126 test directory outside its newly created build/_work path.'
        }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction Stop
    }
}
