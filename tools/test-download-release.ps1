$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'download-release.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { '{0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message }) -join "`n"
    throw "download-release.ps1 AST parse failed:`n$details"
}

$functionAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($functionAst in $functionAsts) {
    Invoke-Expression $functionAst.Extent.Text
}

$script:maximumManifestBytes = 2MB
$script:maximumAssetBytes = 128MB
$script:maximumPackageBytes = 256MB
$script:maximumDownloaderAssetBytes = 512KB
$script:releaseDownloaderAssetName = 'download-release.ps1'
$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:releaseAssetRedirectHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
)
$script:assertionCount = 0
$downloadProfiles = @{}
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2')) {
    $downloadProfiles[$tag] = [pscustomobject]@{
        Files = @(Get-ExpectedReleaseFiles -Tag $tag)
        Tests = @(Get-ExpectedReleaseTests -Tag $tag)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $didThrow = $false
    try { & $Action | Out-Null } catch { $didThrow = $true }
    if (-not $didThrow) { throw "Expected failure: $Message" }
    $script:assertionCount++
}

function New-TestManifest {
    param([string]$Tag = 'v0.1.0-alpha.1')
    $commit = '0123456789abcdef0123456789abcdef01234567'
    $records = @()
    foreach ($expected in (Get-ExpectedReleaseFiles -Tag $Tag)) {
        $hash = 'a' * 64
        $length = 7
        if ($expected.Path -ceq 'wirex_bridge.exe') { $hash = 'b' * 64; $length = 10 }
        if ($expected.Path -ceq 'build-provenance.json') { $hash = 'c' * 64; $length = 20 }
        if ($expected.Path -ceq 'private/device-y.bin') { $hash = $script:approvedYFixtureSha256; $length = 100 }
        $records += ,([pscustomobject]@{
            path = $expected.Path
            asset_name = $expected.AssetName
            length_bytes = [long]$length
            sha256 = $hash
            source = "source commit $commit`: $($expected.Path)"
        })
    }
    return [pscustomobject]@{
        schema_version = 1
        package_kind = 'wirex_bridge_private_alpha_release_green_directory'
        package_status = 'root_audit_passed'
        version = $Tag
        tag_candidate = $Tag
        tag_created = $false
        github_release_published = $false
        source = [pscustomobject]@{
            repository = 'https://github.com/iCassius/WIREX_Bridge.git'
            commit = $commit
            working_tree_clean = $true
        }
        build = [pscustomobject]@{
            source_commit = $commit
            source_tree_clean = $true
            compile_only = $false
            build_completed = $true
            output_directory = 'build/_work/wirex-bridge-0123456-20261025-120000'
            evidence_log = 'build/_work/build-0123456.log'
            evidence_log_sha256 = 'd' * 64
            provenance_asset = 'build-provenance.json'
            provenance_sha256 = 'c' * 64
            result = 'passed'
            passed_test_count = (Get-ExpectedReleaseTests -Tag $Tag).Count
            passed_tests = @(Get-ExpectedReleaseTests -Tag $Tag)
            compiler_warnings = 0
            compiler_errors = 0
            executable_sha256 = 'b' * 64
        }
        release_scope = 'FTX-1 DIRECT personal terminal with BrandMeister voice bridging'
        not_included = @('LCD text/routing integration')
        hardware_validation = [pscustomobject]@{ current_release_hil = 'not performed' }
        approved_y_fixture = [pscustomobject]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $script:approvedYFixtureSha256
        }
        excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
        runtime_directories = @('logs/ (empty at package creation)')
        manifest_asset_name = 'manifest.json'
        files = $records
    }
}

function New-TestAssetList {
    param([object]$Manifest, [switch]$Extra, [switch]$Duplicate)
    $assets = @()
    $assetId = [long]1000
    $assets += ,([pscustomobject]@{ id=$assetId; name='manifest.json'; size=128; state='uploaded'; digest='' })
    $assetId++
    $assets += ,([pscustomobject]@{ id=$assetId; name='download-release.ps1'; size=16384; state='uploaded'; digest='' })
    foreach ($record in $Manifest.files) {
        $assetId++
        $name = [string]$record.asset_name
        if ($Duplicate -and $assets.Count -eq 3) { $name = [string]$assets[1].name }
        $assets += ,([pscustomobject]@{ id=$assetId; name=$name; size=[long]$record.length_bytes; state='uploaded'; digest='' })
    }
    if ($Extra) {
        $assets += ,([pscustomobject]@{ id=9999; name='unexpected.bin'; size=1; state='uploaded'; digest='' })
    }
    return ,$assets
}

$downloadScriptText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
Assert-True ($downloadScriptText.Contains("https://api.github.com/repos/iCassius/WIREX_Bridge")) 'API root is fixed to the approved repository'
Assert-True ($downloadScriptText.Contains("package_status -cne 'root_audit_passed'")) 'only root-audited package manifests are accepted'
Assert-True ($downloadScriptText.Contains("-AllowDraft 只接受唯一匹配的 draft prerelease")) 'draft use is explicit and restricted'
Assert-True ($downloadScriptText.Contains("$([char]36)request.AllowAutoRedirect = `$false")) 'redirects are validated manually'
Assert-True ($downloadScriptText.Contains('objects.githubusercontent.com') -and $downloadScriptText.Contains('github-releases.githubusercontent.com')) 'redirect allowlist contains the additional explicit GitHub asset hosts'
Assert-True ($downloadScriptText.Contains('WaitForExit(15000)') -and $downloadScriptText.Contains('WaitForExit(5000)')) 'credential helper waits and forced-exit confirmation are bounded'
Assert-True ($downloadScriptText.Contains('终止凭据助手后仍无法确认其退出')) 'credential-helper failure to exit is reported'
Assert-True ($downloadScriptText.Contains('target_commitish 与 manifest.source.commit')) 'release target commit is compared with the manifest source commit'
Assert-True ($downloadScriptText -notmatch 'Remove-Item[^\r\n]*SilentlyContinue') 'download staging cleanup failures are not suppressed'
Assert-True ($downloadScriptText -notmatch '(?i)Invoke-(WebRequest|RestMethod)|Expand-Archive|Start-Process') 'downloader does not use shell download/install/launch helpers'
foreach ($cdnHost in @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
    Assert-True (Test-AllowedReleaseAssetRedirectHost -HostName $cdnHost) "approved GitHub CDN host is accepted: $cdnHost"
}
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'other.githubusercontent.com')) 'unlisted GitHub CDN host is rejected'
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'evil.release-assets.githubusercontent.com')) 'unlisted wildcard subdomain is rejected'
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'release-assets.githubusercontent.com.attacker.example')) 'hostname suffix attack is rejected'

$validManifest = New-TestManifest
$validated = Test-ManifestDocument -Manifest $validManifest -RequestedTag 'v0.1.0-alpha.1'
Assert-True ($validated.Files.Count -eq (Get-ExpectedReleaseFiles).Count) 'valid manifest includes the fixed package inventory'
Assert-True ($validated.TotalBytes -gt 0) 'validated size total is accumulated'
$alpha2Manifest = New-TestManifest -Tag 'v0.1.0-alpha.2'
$alpha2Validated = Test-ManifestDocument -Manifest $alpha2Manifest -RequestedTag 'v0.1.0-alpha.2'
Assert-True ($alpha2Validated.Files.Count -eq 24) 'alpha.2 manifest includes the 24-file package inventory'
Assert-True (@($alpha2Manifest.build.passed_tests).Count -eq 28 -and
    $alpha2Manifest.build.passed_tests[15] -ceq 'ui_pipe_test') 'alpha.2 manifest records the exact builder test order'
Assert-Throws { Test-ManifestDocument -Manifest $alpha2Manifest -RequestedTag 'v0.1.0-alpha.1' } 'alpha.2 manifest is rejected for alpha.1 tag'

$invalid = New-TestManifest; $invalid.package_status = 'awaiting_root_audit'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'unreviewed package status is rejected'
$invalid = New-TestManifest; $invalid.files[0].path = '../wirex_bridge.exe'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'path traversal is rejected'
$invalid = New-TestManifest; $invalid.files[1].path = $invalid.files[0].path
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'duplicate package paths are rejected'
$invalid = New-TestManifest; $invalid.files[1].asset_name = $invalid.files[0].asset_name
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'duplicate or remapped asset names are rejected'
$invalid = New-TestManifest; $invalid.source.commit = 'ffffffffffffffffffffffffffffffffffffffff'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'build/source commit mismatch is rejected'
$invalid = New-TestManifest; $invalid.build.compile_only = $true
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'compile-only build is rejected'
$invalid = New-TestManifest; $invalid.approved_y_fixture.sha256 = '0' * 64
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'unapproved fixture digest is rejected'
$invalid = New-TestManifest; Add-Member -InputObject $invalid -MemberType NoteProperty -Name unexpected -Value 'extra'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0-alpha.1' } 'unknown manifest fields are rejected'
Assert-Throws { ConvertFrom-StrictJson -JsonText '{"x":1,"x":2}' -Label 'duplicate test' } 'duplicate JSON keys are rejected'
Assert-Throws { ConvertFrom-StrictJson -JsonText '{"x":1,"X":2}' -Label 'case duplicate test' } 'case-insensitive duplicate JSON keys are rejected'
Assert-True ((Assert-RelativeMetadataPath -Path 'docs/example.md' -Label 'test') -ceq 'docs/example.md') 'normal relative POSIX paths are accepted'
foreach ($badPath in @('../secret', '/rooted', 'C:/absolute', 'docs//file', 'docs\file', 'docs/./file')) {
    Assert-Throws { Assert-RelativeMetadataPath -Path $badPath -Label 'test' } "unsafe path is rejected: $badPath"
}

$publishedRelease = [pscustomobject]@{ tag_name='v0.1.0-alpha.1'; draft=$false; prerelease=$true }
$draftRelease = [pscustomobject]@{ tag_name='v0.1.0-alpha.1'; draft=$true; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedRelease) -RequestedTag 'v0.1.0-alpha.1').tag_name -ceq 'v0.1.0-alpha.1') 'published prerelease is selected by exact tag'
Assert-Throws { Select-ReleaseCandidate -Releases @($draftRelease) -RequestedTag 'v0.1.0-alpha.1' } 'draft is rejected by default'
Assert-True ((Select-ReleaseCandidate -Releases @($draftRelease) -RequestedTag 'v0.1.0-alpha.1' -AllowDraft).draft) 'explicit draft mode accepts owner-visible draft prerelease'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedRelease, $publishedRelease) -RequestedTag 'v0.1.0-alpha.1' } 'ambiguous tag match is rejected'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedRelease) -RequestedTag 'v0.1.0-alpha.2' } 'different tag is rejected'
Assert-Throws { Select-ReleaseCandidate -Releases @([pscustomobject]@{ tag_name='v0.1.0-alpha.1'; draft=$false; prerelease=$false }) -RequestedTag 'v0.1.0-alpha.1' } 'stable release is rejected'
$publishedAlpha2 = [pscustomobject]@{ tag_name='v0.1.0-alpha.2'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha2) -RequestedTag 'v0.1.0-alpha.2').tag_name -ceq 'v0.1.0-alpha.2') 'alpha.2 is selected by exact tag'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedAlpha2) -RequestedTag 'V0.1.0-alpha.2' } 'release profile tag is case-sensitive'

$goodAssets = New-TestAssetList -Manifest $validManifest
$release = [pscustomobject]@{ assets=$goodAssets; target_commitish=[string]$validManifest.source.commit }
$assetMap = Resolve-ReleaseAssetInventory -Release $release -ValidatedManifest $validated
Assert-True ($assetMap.Count -eq $goodAssets.Count) 'release asset inventory matches manifest exactly'
Assert-True ($assetMap.ContainsKey('download-release.ps1')) 'fixed helper is the sole permitted non-manifest release asset'
Assert-True (Assert-ReleaseTargetCommitish -Release $release -SourceCommit ([string]$validManifest.source.commit)) 'release target commit matches the manifest source commit'
$alpha2GoodAssets = New-TestAssetList -Manifest $alpha2Manifest
$alpha2Release = [pscustomobject]@{ assets=$alpha2GoodAssets; target_commitish=[string]$alpha2Manifest.source.commit }
$alpha2AssetMap = Resolve-ReleaseAssetInventory -Release $alpha2Release -ValidatedManifest $alpha2Validated
Assert-True ($alpha2AssetMap.Count -eq 26 -and $alpha2AssetMap.ContainsKey('download-release.ps1')) `
    'alpha.2 remote inventory contains 24 package files, manifest and helper'
$wrongTarget = [pscustomobject]@{ target_commitish='main' }
Assert-Throws { Assert-ReleaseTargetCommitish -Release $wrongTarget -SourceCommit ([string]$validManifest.source.commit) } 'branch target is rejected when it differs from the source commit'
Assert-Throws { Assert-ReleaseTargetCommitish -Release ([pscustomobject]@{ target_commitish=('f' * 40) }) -SourceCommit ([string]$validManifest.source.commit) } 'release target commit mismatch is rejected'
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{ assets=(New-TestAssetList -Manifest $validManifest -Extra) }) -ValidatedManifest $validated } 'unexpected release assets are rejected'
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{ assets=(New-TestAssetList -Manifest $validManifest -Duplicate) }) -ValidatedManifest $validated } 'duplicate release asset names are rejected'
$missingAssets = @($goodAssets | Select-Object -Skip 1)
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{ assets=$missingAssets }) -ValidatedManifest $validated } 'missing manifest asset is rejected'
$missingDownloader = @($goodAssets | Where-Object { $_.name -cne 'download-release.ps1' })
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{ assets=$missingDownloader }) -ValidatedManifest $validated } 'missing helper asset is rejected'
$oversizedDownloader = @($goodAssets | ForEach-Object { if ($_.name -ceq 'download-release.ps1') { $_.size = 512KB + 1 }; $_ })
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{ assets=$oversizedDownloader }) -ValidatedManifest $validated } 'oversized helper asset is rejected'

$provenance = [pscustomobject]@{
    schema_version = 1
    source_commit = [string]$validManifest.source.commit
    source_tree_clean = $true
    compile_only = $false
    build_completed = $true
    result = 'passed'
    output_directory = [string]$validManifest.build.output_directory
    started_utc = '2026-10-25T00:00:00Z'
    completed_utc = '2026-10-25T00:01:00Z'
    executable = [pscustomobject]@{ path='wirex_bridge.exe'; length_bytes=10; sha256=('b' * 64) }
    tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.1') | ForEach-Object {
        [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
    })
}
Assert-True (Test-BuildProvenanceDocument -Provenance $provenance -ValidatedManifest $validated) 'matching successful provenance is accepted'
$badProvenance = $provenance | Select-Object *; $badProvenance.source_commit = 'f' * 40
Assert-Throws { Test-BuildProvenanceDocument -Provenance $badProvenance -ValidatedManifest $validated } 'provenance source mismatch is rejected'
$badProvenance = $provenance | Select-Object *; $badProvenance.tests[0].exit_code = 1
Assert-Throws { Test-BuildProvenanceDocument -Provenance $badProvenance -ValidatedManifest $validated } 'failed provenance test is rejected'
$alpha2Provenance = $provenance | Select-Object *
$alpha2Provenance.tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.2') | ForEach-Object {
    [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
})
Assert-True (Test-BuildProvenanceDocument -Provenance $alpha2Provenance -ValidatedManifest $alpha2Validated) 'alpha.2 builder provenance includes the exact new test in builder order'
$alpha2Provenance.tests = @($alpha2Provenance.tests | Where-Object { $_.name -cne 'ui_pipe_test' })
Assert-Throws { Test-BuildProvenanceDocument -Provenance $alpha2Provenance -ValidatedManifest $alpha2Validated } 'alpha.2 provenance missing ui_pipe_test is rejected'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-release-download-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null
try {
    $context = Get-DownloadDestinationContext -Destination (Join-Path $temporaryRoot 'output')
    Assert-True (Test-PathWithinDirectory -Path $context.Staging -Directory $context.Parent) 'staging is a child of its chosen parent'
    Assert-Throws { Get-DownloadDestinationContext -Destination $temporaryRoot } 'existing target directory is not overwritten'
    Assert-Throws { Get-DownloadDestinationContext -Destination (Join-Path $temporaryRoot 'missing\output') } 'missing parent directory is rejected'

    $smallFile = Join-Path $temporaryRoot 'small.bin'
    [System.IO.File]::WriteAllBytes($smallFile, [System.Text.Encoding]::UTF8.GetBytes('offline'))
    $smallHash = (Get-FileHash -LiteralPath $smallFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ((Test-DownloadedFile -Path $smallFile -ExpectedLength 7 -ExpectedSha256 $smallHash) -ceq $smallHash) 'downloaded file length and hash are checked'
    Assert-Throws { Test-DownloadedFile -Path $smallFile -ExpectedLength 6 -ExpectedSha256 $smallHash } 'altered length is rejected'
    Assert-Throws { Test-DownloadedFile -Path $smallFile -ExpectedLength 7 -ExpectedSha256 ('0' * 64) } 'altered digest is rejected'
} finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($temporaryRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedTemp).StartsWith('wirex-release-download-offline-', [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedTemp) { throw 'Offline test temporary directory remains after cleanup.' }
    }
}

. (Join-Path $PSScriptRoot 'package-release.ps1')
. (Join-Path $PSScriptRoot 'publish-release.ps1')
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2')) {
    $packageProfile = Set-ReleaseVersion -Version $tag
    $packagePaths = @($packageProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' })
    $downloadFiles = @($downloadProfiles[$tag].Files)
    Assert-True ($downloadFiles.Count -eq $packagePaths.Count) "$tag package and downloader file counts match"
    foreach ($downloadFile in $downloadFiles) {
        if ($packagePaths -cnotcontains [string]$downloadFile.Path) { throw "Downloader path is absent from package profile: $($downloadFile.Path)" }
        Assert-True ((Get-ReleaseAssetName -RelativePath ([string]$downloadFile.Path)) -ceq [string]$downloadFile.AssetName) `
            "$tag package and downloader asset mapping match: $($downloadFile.Path)"
    }
    for ($index = 0; $index -lt $downloadProfiles[$tag].Tests.Count; $index++) {
        Assert-True ([string]$packageProfile.TestNames[$index] -ceq [string]$downloadProfiles[$tag].Tests[$index]) `
            "$tag package and downloader test order matches at index $index"
    }

    $publishProfile = Set-PublishProfile -Tag $tag
    Assert-True ($publishProfile.AssetPathMap.Count -eq $downloadFiles.Count) "$tag publisher and downloader file counts match"
    foreach ($downloadFile in $downloadFiles) {
        Assert-True ([string]$publishProfile.AssetPathMap[[string]$downloadFile.Path] -ceq [string]$downloadFile.AssetName) `
            "$tag publisher and downloader asset mapping match: $($downloadFile.Path)"
    }
    for ($index = 0; $index -lt $downloadProfiles[$tag].Tests.Count; $index++) {
        Assert-True ([string]$publishProfile.TestNames[$index] -ceq [string]$downloadProfiles[$tag].Tests[$index]) `
            "$tag publisher and downloader test order matches at index $index"
    }
}

Write-Host "PASS: $script:assertionCount offline release-downloader assertions; Windows PowerShell $($PSVersionTable.PSVersion); no network, Release download, installation, or executable launch."
