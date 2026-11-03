$ErrorActionPreference = 'Stop'

$script:stableReleaseContractPath = Join-Path $PSScriptRoot 'StableReleaseContract.psm1'
Import-Module -Name $script:stableReleaseContractPath -Force -Scope Global -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'ZipOnlyRelease.psm1') -Force -Scope Global -ErrorAction Stop
$script:stableReleaseLimits = Get-WirexStableReleaseLimits
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

function Open-ReleaseHttpResponse {
    throw 'Offline downloader tests block HTTP unless a test supplies an explicit mock.'
}

$script:maximumManifestBytes = 2MB
$script:maximumAssetBytes = 128MB
$script:maximumStablePackageBytes = [long]$script:stableReleaseLimits.MaximumUncompressedBytes
$script:maximumStableArchiveBytes = [long]$script:stableReleaseLimits.MaximumArchiveBytes
$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:releaseAssetRedirectHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
)
$script:assertionCount = 0
$script:offlineSkippedCases = New-Object 'System.Collections.Generic.List[string]'
$downloadProfiles = @{}
$downloadProfiles['v0.1.0'] = [pscustomobject]@{
    Files = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0')
    Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0')
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

function New-StableTestManifest {
    $commit = '0123456789abcdef0123456789abcdef01234567'
    $records = @()
    foreach ($expected in (Get-ExpectedStableReleaseFiles)) {
        $hash = 'a' * 64
        $length = [long]7
        switch -CaseSensitive ([string]$expected.Path) {
            'WirexBridge.exe' { $hash='b' * 64; $length=10; break }
            'build-provenance.json' { $hash='c' * 64; $length=20; break }
            'launcher-build-provenance.json' { $hash='f' * 64; $length=21; break }
            'runtime/wirex_bridge.exe' { $hash='e' * 64; $length=16; break }
            'runtime/private/device-y.bin' { $hash=$script:approvedYFixtureSha256; $length=100; break }
        }
        $records += ,([pscustomobject]@{
            path=[string]$expected.Path; asset_name=[string]$expected.AssetName
            length_bytes=[long]$length; sha256=[string]$hash
            source=('source commit ' + $commit + ': ' + [string]$expected.Path)
        })
    }
    $tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0')
    return [pscustomobject]@{
        schema_version=1
        package_kind='wirex_bridge_stable_release_green_directory'
        package_status='root_audit_passed'
        version='v0.1.0'; tag_candidate='v0.1.0'; tag_created=$false; github_release_published=$false
        source=[pscustomobject]@{ repository='https://github.com/iCassius/WIREX_Bridge.git'; commit=$commit; working_tree_clean=$true }
        build=[pscustomobject]@{
            source_commit=$commit; source_tree_clean=$true; compile_only=$false; build_completed=$true
            output_directory='build/_work/synthetic-native-build'; evidence_log='build/_work/synthetic-native-build.log'
            evidence_log_sha256=('1' * 64); provenance_asset='build-provenance.json'; provenance_sha256=('c' * 64)
            result='passed'; passed_test_count=$tests.Count; passed_tests=$tests
            compiler_warnings=0; compiler_errors=0; executable_sha256=('e' * 64)
        }
        release_scope='R124 stable portable folder test fixture'
        not_included=@('No hardware, audio, PTT, or RF validation in this synthetic fixture')
        hardware_validation=[pscustomobject]@{ current_release_hil='not performed' }
        approved_y_fixture=[pscustomobject]@{
            path='runtime/private/device-y.bin'; length_bytes=100; sha256=$script:approvedYFixtureSha256
        }
        excluded_private_files=@(
            'config.json','runtime/config.json','credentials/','tempSecrets/','logs/',
            'runtime/private/credentials/','callsign','password','api_key'
        )
        runtime_directories=@(Get-ExpectedReleaseDirectories -Tag 'v0.1.0')
        manifest_asset_name='manifest.json'
        files=$records
        launcher_build=[pscustomobject]@{
            source_commit=$commit; source_path='ui/launcher/WirexBridgeLauncher.cs'; source_sha256=('1' * 64)
            compiler_family='Microsoft .NET Framework csc.exe'; compiler_version='synthetic-test'
            target='x64 Windows GUI executable'; output_directory='build/_work/synthetic-launcher-build'
            executable_asset='WirexBridge.exe'; executable_sha256=('b' * 64)
            provenance_asset='launcher-build-provenance.json'; provenance_sha256=('f' * 64)
            build_log_path='build/_work/synthetic-launcher-build/launcher-build.log'; build_log_sha256=('2' * 64)
        }
    }
}

function New-StableArchiveFixture {
    $manifest = New-StableTestManifest
    $commit = [string]$manifest.source.commit
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $contents = @{}
    foreach ($expected in (Get-ExpectedStableReleaseFiles)) {
        $path = [string]$expected.Path
        switch -CaseSensitive ($path) {
            'WirexBridge.exe' { $contents[$path] = $encoding.GetBytes('synthetic launcher bytes'); break }
            'build-provenance.json' { break }
            'launcher-build-provenance.json' { break }
            'runtime/wirex_bridge.exe' { $contents[$path] = [byte[]]@(1,2,3,4,5,6,7,8); break }
            'runtime/private/device-y.bin' {
                $fixturePath = Join-Path $PSScriptRoot '..\private\fixtures\device-y.bin'
                $contents[$path] = [System.IO.File]::ReadAllBytes($fixturePath)
                break
            }
            'SOURCE.txt' { $contents[$path] = $encoding.GetBytes(('Synthetic source revision ' + $commit + "`n")); break }
            default { $contents[$path] = $encoding.GetBytes(('synthetic stable asset: ' + $path)) }
        }
    }
    $nativeBytes = [byte[]]$contents['runtime/wirex_bridge.exe']
    $nativeHash = Get-ByteArraySha256 -Bytes $nativeBytes
    $launcherBytes = [byte[]]$contents['WirexBridge.exe']
    $launcherHash = Get-ByteArraySha256 -Bytes $launcherBytes
    $stableTests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0')
    $buildProvenance = [pscustomobject]@{
        schema_version=1; source_commit=$commit; source_tree_clean=$true; compile_only=$false
        build_completed=$true; result='passed'; output_directory=[string]$manifest.build.output_directory
        started_utc='2026-11-03T00:00:00Z'; completed_utc='2026-11-03T00:01:00Z'
        executable=[pscustomobject]@{ path='wirex_bridge.exe'; length_bytes=[long]$nativeBytes.Length; sha256=$nativeHash }
        tests=@($stableTests | ForEach-Object { [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 } })
    }
    $buildBytes = $encoding.GetBytes(((ConvertTo-Json -InputObject $buildProvenance -Depth 12) + "`n"))
    $contents['build-provenance.json'] = $buildBytes
    $buildHash = Get-ByteArraySha256 -Bytes $buildBytes

    $launcherProvenance = [pscustomobject]@{
        schema_version=1; result='passed'
        source=[pscustomobject]@{ path='ui/launcher/WirexBridgeLauncher.cs'; commit=$commit; sha256=[string]$manifest.launcher_build.source_sha256 }
        compiler=[pscustomobject]@{
            family='Microsoft .NET Framework csc.exe'; version=[string]$manifest.launcher_build.compiler_version
            target='x64 Windows GUI executable'
            command='csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001'
        }
        output=[pscustomobject]@{
            directory=[string]$manifest.launcher_build.output_directory; path='WirexBridge.exe'
            length_bytes=[long]$launcherBytes.Length; sha256=$launcherHash
        }
        build_log=[pscustomobject]@{
            path=[string]$manifest.launcher_build.build_log_path; sha256=[string]$manifest.launcher_build.build_log_sha256
        }
    }
    $launcherProvenanceBytes = $encoding.GetBytes(((ConvertTo-Json -InputObject $launcherProvenance -Depth 12) + "`n"))
    $contents['launcher-build-provenance.json'] = $launcherProvenanceBytes
    $launcherProvenanceHash = Get-ByteArraySha256 -Bytes $launcherProvenanceBytes
    $manifest.build.provenance_sha256 = $buildHash
    $manifest.build.executable_sha256 = $nativeHash
    $manifest.launcher_build.executable_sha256 = $launcherHash
    $manifest.launcher_build.provenance_sha256 = $launcherProvenanceHash
    foreach ($record in $manifest.files) {
        $fileBytes = [byte[]]$contents[[string]$record.path]
        $record.length_bytes = [long]$fileBytes.Length
        $record.sha256 = Get-ByteArraySha256 -Bytes $fileBytes
        $record.source = 'synthetic source commit ' + $commit + ': ' + [string]$record.path
    }
    $manifestBytes = $encoding.GetBytes(((ConvertTo-Json -InputObject $manifest -Depth 20) + "`n"))
    $validated = Test-ManifestDocument -Manifest $manifest -RequestedTag 'v0.1.0'
    return [pscustomobject]@{ Manifest=$manifest; Validated=$validated; ManifestBytes=$manifestBytes; Contents=$contents }
}

function New-StableTestZipArchive {
    param([string]$Path,[object[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        foreach ($item in $Entries) {
            $entry = $archive.CreateEntry([string]$item.Path,[System.IO.Compression.CompressionLevel]::Optimal)
            if ($null -ne $item.PSObject.Properties['Attributes']) { $entry.ExternalAttributes = [int]$item.Attributes }
            $entryStream = $entry.Open()
            try { $entryStream.Write([byte[]]$item.Bytes,0,([byte[]]$item.Bytes).Length) }
            finally { $entryStream.Dispose() }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

$downloadScriptText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
Assert-True ($downloadScriptText.Contains("https://api.github.com/repos/iCassius/WIREX_Bridge")) 'API root is fixed to the approved repository'
Assert-True ($downloadScriptText.Contains("package_status -cne 'root_audit_passed'")) 'only root-audited package manifests are accepted'
Assert-True ($downloadScriptText.Contains("-AllowDraft 只接受 draft 且 prerelease 状态符合 tag 类型的 Release")) 'draft use is explicit and restricted'
Assert-True ($downloadScriptText.Contains("$([char]36)request.AllowAutoRedirect = `$false")) 'redirects are validated manually'
Assert-True ($downloadScriptText.Contains('objects.githubusercontent.com') -and $downloadScriptText.Contains('github-releases.githubusercontent.com')) 'redirect allowlist contains the additional explicit GitHub asset hosts'
Assert-True ($downloadScriptText.Contains('WaitForExit(15000)') -and $downloadScriptText.Contains('WaitForExit(5000)')) 'credential helper waits and forced-exit confirmation are bounded'
Assert-True ($downloadScriptText.Contains('终止凭据助手后仍无法确认其退出')) 'credential-helper failure to exit is reported'
Assert-True ($downloadScriptText.Contains('target_commitish 与 manifest.source.commit')) 'release target commit is compared with the manifest source commit'
Assert-True ($downloadScriptText -notmatch 'Remove-Item[^\r\n]*SilentlyContinue') 'download staging cleanup failures are not suppressed'
Assert-True ($downloadScriptText -notmatch '(?i)Invoke-(WebRequest|RestMethod)|Expand-Archive|Start-Process') 'downloader does not use shell download/install/launch helpers'
Assert-True ($downloadScriptText.Contains('New-DownloadStagingRoot -Path $context.Staging') -and
    $downloadScriptText.Contains('Assert-DownloadStagingRoot -Path $context.Staging')) `
    'download creates the chosen staging root exclusively and checks it before publishing'
Assert-True ($downloadScriptText.Contains('Test-WirexStableRegularZipEntry') -and
    $downloadScriptText.Contains('Resolve-WirexStableCanonicalPath') -and
    $downloadScriptText.Contains('Test-WirexStableLengthWithinLimit -Length ([long]$entry.Length) -MaximumBytes $maximumFileBytes') -and
    $downloadScriptText.Contains('Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes ([long]$limits.MaximumUncompressedBytes)')) `
    'stable ZIP production path uses shared type, canonical path, per-file, and expanded-size checks'
foreach ($cdnHost in @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
    Assert-True (Test-AllowedReleaseAssetRedirectHost -HostName $cdnHost) "approved GitHub CDN host is accepted: $cdnHost"
}
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'other.githubusercontent.com')) 'unlisted GitHub CDN host is rejected'
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'evil.release-assets.githubusercontent.com')) 'unlisted wildcard subdomain is rejected'
Assert-True (-not (Test-AllowedReleaseAssetRedirectHost -HostName 'release-assets.githubusercontent.com.attacker.example')) 'hostname suffix attack is rejected'

$invalid = New-StableTestManifest; $invalid.package_status = 'awaiting_root_audit'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'unreviewed package status is rejected'
$invalid = New-StableTestManifest; $invalid.files[0].path = '../wirex_bridge.exe'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'path traversal is rejected'
$invalid = New-StableTestManifest; $invalid.files[1].path = $invalid.files[0].path
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'duplicate package paths are rejected'
$invalid = New-StableTestManifest; $invalid.files[1].asset_name = $invalid.files[0].asset_name
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'duplicate or remapped asset names are rejected'
$invalid = New-StableTestManifest; $invalid.source.commit = 'ffffffffffffffffffffffffffffffffffffffff'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'build/source commit mismatch is rejected'
$invalid = New-StableTestManifest; $invalid.build.compile_only = $true
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'compile-only build is rejected'
$invalid = New-StableTestManifest; $invalid.approved_y_fixture.sha256 = '0' * 64
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'unapproved fixture digest is rejected'
$invalid = New-StableTestManifest; Add-Member -InputObject $invalid -MemberType NoteProperty -Name unexpected -Value 'extra'
Assert-Throws { Test-ManifestDocument -Manifest $invalid -RequestedTag 'v0.1.0' } 'unknown manifest fields are rejected'
Assert-Throws { ConvertFrom-StrictJson -JsonText '{"x":1,"x":2}' -Label 'duplicate test' } 'duplicate JSON keys are rejected'
Assert-Throws { ConvertFrom-StrictJson -JsonText '{"x":1,"X":2}' -Label 'case duplicate test' } 'case-insensitive duplicate JSON keys are rejected'
Assert-True ((Assert-RelativeMetadataPath -Path 'docs/example.md' -Label 'test') -ceq 'docs/example.md') 'normal relative POSIX paths are accepted'
foreach ($badPath in @('../secret', '/rooted', 'C:/absolute', 'docs//file', 'docs\file', 'docs/./file')) {
    Assert-Throws { Assert-RelativeMetadataPath -Path $badPath -Label 'test' } "unsafe path is rejected: $badPath"
}

$stableManifest = New-StableTestManifest
$stableValidated = Test-ManifestDocument -Manifest $stableManifest -RequestedTag 'v0.1.0'
$stableExpectedFiles = @(Get-ExpectedStableReleaseFiles)
Assert-True (Test-ReleaseTag -Tag 'v0.1.0') 'v0.1.0 is a registered stable release tag'
Assert-True ($stableValidated.Files.Count -eq $stableExpectedFiles.Count -and
    $stableValidated.Files.Count -eq $downloadProfiles['v0.1.0'].Files.Count) `
    'stable manifest accepts the complete fixed file inventory, including the new channel activation module'
Assert-True (@($stableValidated.Files | Where-Object {
    [string]$_.path -ceq 'runtime/ui/windows/ChannelActivationState.psm1' -and
    [string]$_.asset_name -ceq 'runtime__ui__windows__channel-activation-state.psm1'
}).Count -eq 1) 'stable downloader pins the channel activation module path and asset name'
Assert-True ([string]$stableValidated.Manifest.approved_y_fixture.path -ceq 'runtime/private/device-y.bin' -and
    [long]$stableValidated.Manifest.approved_y_fixture.length_bytes -eq 100) `
    'stable manifest keeps the approved 100-byte HRI protocol template'
$missingStableModule = New-StableTestManifest
$missingStableModule.files = @($missingStableModule.files | Where-Object { [string]$_.path -cne 'runtime/ui/windows/ChannelActivationState.psm1' })
Assert-Throws { Test-ManifestDocument -Manifest $missingStableModule -RequestedTag 'v0.1.0' } `
    'stable manifest rejects a missing ChannelActivationState runtime dependency'
$badStableExclusions = New-StableTestManifest
$badStableExclusions.excluded_private_files = @($badStableExclusions.excluded_private_files | Where-Object { [string]$_ -cne 'credentials/' })
Assert-Throws { Test-ManifestDocument -Manifest $badStableExclusions -RequestedTag 'v0.1.0' } `
    'stable manifest must explicitly exclude credential directories'
$badStableFixture = New-StableTestManifest
$badStableFixture.approved_y_fixture.sha256 = '0' * 64
Assert-Throws { Test-ManifestDocument -Manifest $badStableFixture -RequestedTag 'v0.1.0' } `
    'stable manifest rejects a changed HRI protocol fixture hash'
$badStableMapping = New-StableTestManifest
(@($badStableMapping.files | Where-Object { [string]$_.path -ceq 'runtime/ui/windows/ChannelActivationState.psm1' })[0]).asset_name = 'channel-state.psm1'
Assert-Throws { Test-ManifestDocument -Manifest $badStableMapping -RequestedTag 'v0.1.0' } `
    'stable manifest rejects a remapped channel activation asset name'
$stableRelease = [pscustomobject]@{ tag_name='v0.1.0'; draft=$false; prerelease=$false }
Assert-True ([long]$script:stableReleaseLimits.MaximumArchiveBytes -eq 512MB -and
    [long]$script:stableReleaseLimits.MaximumUncompressedBytes -eq 2GB -and
    [long]$script:stableReleaseLimits.MaximumManifestBytes -eq 2MB) `
    'stable shared limits pin compressed ZIP, expanded package, and standalone manifest maxima'
Assert-True ((Test-WirexStableLengthWithinLimit -Length 512MB -MaximumBytes ([long]$script:stableReleaseLimits.MaximumArchiveBytes)) -and
    -not (Test-WirexStableLengthWithinLimit -Length (512MB + 1) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumArchiveBytes))) `
    'stable compressed ZIP size helper accepts the boundary and rejects one byte above it'
Assert-True ((Test-WirexStableLengthWithinLimit -Length 2GB -MaximumBytes ([long]$script:stableReleaseLimits.MaximumUncompressedBytes)) -and
    -not (Test-WirexStableLengthWithinLimit -Length (2GB + 1) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumUncompressedBytes))) `
    'stable expanded size helper accepts the boundary and rejects one byte above it'
Assert-True ((Test-WirexStableLengthWithinLimit -Length 2MB -MaximumBytes ([long]$script:stableReleaseLimits.MaximumManifestBytes)) -and
    -not (Test-WirexStableLengthWithinLimit -Length (2MB + 1) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumManifestBytes))) `
    'stable standalone manifest size helper accepts its boundary and rejects one byte above it'
foreach ($stableFile in $stableExpectedFiles) {
    $stableFilePath = [string]$stableFile.Path
    $stableFileMaximum = [long](Get-WirexStableMaximumFileBytes -Path $stableFilePath)
    Assert-True ([long]$stableFile.MaximumBytes -eq $stableFileMaximum -and
        (Test-WirexStableLengthWithinLimit -Length $stableFileMaximum -MaximumBytes $stableFileMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($stableFileMaximum + 1) -MaximumBytes $stableFileMaximum)) `
        ('stable shared per-file cap and helper boundary match: ' + $stableFilePath)
    $atCapManifest = New-StableTestManifest
    $atCapRecord = @($atCapManifest.files | Where-Object { [string]$_.path -ceq $stableFilePath })[0]
    $atCapRecord.length_bytes = $stableFileMaximum
    Assert-True ((Test-ManifestDocument -Manifest $atCapManifest -RequestedTag 'v0.1.0').Files.Count -eq $stableExpectedFiles.Count) `
        ('stable manifest production validator accepts the per-file cap: ' + $stableFilePath)
    $overCapManifest = New-StableTestManifest
    $overCapRecord = @($overCapManifest.files | Where-Object { [string]$_.path -ceq $stableFilePath })[0]
    $overCapRecord.length_bytes = $stableFileMaximum + 1
    Assert-Throws { Test-ManifestDocument -Manifest $overCapManifest -RequestedTag 'v0.1.0' } `
        ('stable manifest production validator rejects one byte over the per-file cap: ' + $stableFilePath)
}
foreach ($invalidEntryType in @(
        ([int]0xa000 -shl 16), ([int]0x1000 -shl 16), ([int]0x2000 -shl 16),
        ([int]0x6000 -shl 16), ([int]0xc000 -shl 16), ([int]0x4000 -shl 16), 0x10)) {
    Assert-True (-not (Test-WirexStableRegularZipEntry -ExternalAttributes $invalidEntryType -Length 1)) `
        ('shared stable entry classifier rejects unsupported ZIP type bits: ' + $invalidEntryType)
}
Assert-True ((Test-WirexStableRegularZipEntry -ExternalAttributes 0 -Length 1) -and
    (Test-WirexStableRegularZipEntry -ExternalAttributes ([int]0x8000 -shl 16) -Length 1)) `
    'shared stable entry classifier accepts unspecified and Unix regular file types'
Assert-True ((Select-ReleaseCandidate -Releases @($stableRelease) -RequestedTag 'v0.1.0').tag_name -ceq 'v0.1.0') `
    'published v0.1.0 is selected only as a stable release'
Assert-Throws { Select-ReleaseCandidate -Releases @([pscustomobject]@{tag_name='v0.1.0';draft=$false;prerelease=$true}) -RequestedTag 'v0.1.0' } `
    'stable tag is rejected if GitHub marks it as prerelease'
$stableDraft = [pscustomobject]@{ tag_name='v0.1.0'; draft=$true; prerelease=$false }
Assert-True ((Select-ReleaseCandidate -Releases @($stableDraft) -RequestedTag 'v0.1.0' -AllowDraft).draft) `
    'explicit stable draft validation keeps prerelease=false'
$stableTarget = [pscustomobject]@{ target_commitish=[string]$stableManifest.source.commit }
Assert-True (Assert-ReleaseTargetCommitish -Release $stableTarget -SourceCommit ([string]$stableManifest.source.commit)) `
    'stable release target commit must match its manifest source commit'
$stableAssets = @(
    [pscustomobject]@{ id=2001; name='WIREX_Bridge_v0.1.0.zip'; size=2048; state='uploaded' },
    [pscustomobject]@{ id=2002; name='manifest.json'; size=4096; state='uploaded' },
    [pscustomobject]@{ id=2003; name='SHA256SUMS.txt'; size=256; state='uploaded' }
)
Add-Member -InputObject $stableRelease -MemberType NoteProperty -Name assets -Value $stableAssets
$stableAssetMap = Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.0'
Assert-True ($stableAssetMap.Count -eq 3 -and $stableAssetMap.ContainsKey('WIREX_Bridge_v0.1.0.zip')) `
    'stable Release accepts exactly its ZIP, manifest, and detached checksum assets'
$stableArchiveMaximum = [long]$script:stableReleaseLimits.MaximumArchiveBytes
$stableAssets[0].size = $stableArchiveMaximum
Assert-True ((Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.0').Count -eq 3) `
    'stable Release metadata validator accepts the compressed ZIP cap without creating a large archive'
$stableAssets[0].size = $stableArchiveMaximum + 1
Assert-Throws { Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.0' } `
    'stable Release metadata validator rejects a ZIP asset one byte above the compressed cap'
$stableAssets[0].size = 2048
$stableManifestMaximum = [long]$script:stableReleaseLimits.MaximumManifestBytes
$stableAssets[1].size = $stableManifestMaximum
Assert-True ((Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.0').Count -eq 3) `
    'stable Release metadata validator accepts the standalone manifest cap'
$stableAssets[1].size = $stableManifestMaximum + 1
Assert-Throws { Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.0' } `
    'stable Release metadata validator rejects a manifest asset one byte above its cap'
$stableAssets[1].size = 4096
$archiveDownloadError = $null
try {
    Write-ReleaseAssetToFile -Asset ([pscustomobject]@{
        id=2999; name='WIREX_Bridge_v0.1.0.zip'; size=($stableArchiveMaximum + 1); digest=''
    }) -Token 'offline-test-only' -Path 'unused-offline-archive.part' -ExpectedLength ($stableArchiveMaximum + 1) `
        -MaximumBytes $stableArchiveMaximum
} catch { $archiveDownloadError = $_.Exception.Message }
Assert-True ($archiveDownloadError -ceq 'Release asset 大小与 manifest 不一致：WIREX_Bridge_v0.1.0.zip') `
    ('stable archive asset downloader rejects an over-cap length before HTTP or file creation; observed error: ' + [string]$archiveDownloadError)
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{assets=@($stableAssets + [pscustomobject]@{id=2004;name='download-release.ps1';size=10;state='uploaded'})}) -ValidatedManifest $stableValidated -Tag 'v0.1.0' } `
    'stable Release rejects an extra flat asset'
foreach ($unsafeZipPath in @('../escape.txt','runtime/../../escape.txt','runtime/config.json:stream','runtime\escape.txt',
        'runtime/file.','runtime/file ','runtime//file','runtime/')) {
    Assert-Throws { Assert-StableArchiveEntryPath -Path $unsafeZipPath } ('stable ZIP rejects unsafe Windows path syntax: ' + $unsafeZipPath)
}
Assert-True ((Assert-StableArchiveEntryPath -Path 'runtime/ui/windows/ChannelActivationState.psm1') -eq $null) `
    'stable ZIP accepts a normalized relative runtime file path'
$publishedRelease = [pscustomobject]@{ tag_name='v0.1.1-test.2'; draft=$false; prerelease=$true }
$draftRelease = [pscustomobject]@{ tag_name='v0.1.1-test.2'; draft=$true; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedRelease) -RequestedTag 'v0.1.1-test.2').tag_name -ceq 'v0.1.1-test.2') 'published prerelease is selected by exact tag'
Assert-Throws { Select-ReleaseCandidate -Releases @($draftRelease) -RequestedTag 'v0.1.1-test.2' } 'draft is rejected by default'
Assert-True ((Select-ReleaseCandidate -Releases @($draftRelease) -RequestedTag 'v0.1.1-test.2' -AllowDraft).draft) 'explicit draft mode accepts owner-visible draft prerelease'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedRelease, $publishedRelease) -RequestedTag 'v0.1.1-test.2' } 'ambiguous tag match is rejected'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedRelease) -RequestedTag 'v0.1.1' } 'different tag is rejected'
Assert-Throws { Select-ReleaseCandidate -Releases @([pscustomobject]@{ tag_name='v0.1.1-test.2'; draft=$false; prerelease=$false }) -RequestedTag 'v0.1.1-test.2' } 'prerelease tag is rejected when GitHub marks it stable'
Assert-Throws { Select-ReleaseCandidate -Releases @($publishedRelease) -RequestedTag 'V0.1.1-TEST.2' } 'release profile tag is case-sensitive'
foreach ($zipOnlyTag in @('v0.1.1-test.2','v0.1.1')) {
    $zipOnlyProfile = Get-WirexZipOnlyReleaseProfile -Version $zipOnlyTag
    Assert-True (Test-ReleaseTag -Tag $zipOnlyTag) ($zipOnlyTag + ' is an explicitly supported ZIP-only release tag')
    Assert-True ([string]::Join('|',(Get-ExpectedReleaseDirectories -Tag $zipOnlyTag)) -ceq
        [string]::Join('|',$zipOnlyProfile.Directories)) ($zipOnlyTag + ' uses the fixed ZIP-only directory inventory')
    Assert-True (@($zipOnlyProfile.PackageFiles | Where-Object { $_ -ceq 'WirexBridge.exe' }).Count -eq 1 -and
        @($zipOnlyProfile.PackageFiles | Where-Object { $_ -ceq 'runtime/ui/windows/UiLocalization.psm1' }).Count -eq 1) `
        ($zipOnlyTag + ' includes one root launcher and the required UI localization module')
}
Assert-True ((Select-ReleaseCandidate -Releases @([pscustomobject]@{
    tag_name='v0.1.1-test.2'; draft=$false; prerelease=$true
}) -RequestedTag 'v0.1.1-test.2').tag_name -ceq 'v0.1.1-test.2') `
    'v0.1.1-test.2 requires prerelease=true'
Assert-True ((Select-ReleaseCandidate -Releases @([pscustomobject]@{
    tag_name='v0.1.1'; draft=$false; prerelease=$false
}) -RequestedTag 'v0.1.1').tag_name -ceq 'v0.1.1') `
    'v0.1.1 requires prerelease=false'
Assert-True (-not (Test-ReleaseTag -Tag 'v0.1.1-test.1')) 'unregistered ZIP-only tags are rejected'
Assert-True (-not (Test-ReleaseTag -Tag 'v0.1.0-alpha.19')) 'retired alpha tags are no longer downloadable'
Assert-Throws { Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.19' } 'retired alpha tags have no fixed Native test inventory'
Assert-Throws { Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.19' } 'retired alpha tags have no fixed file inventory'
Assert-Throws { Test-ManifestDocument -Manifest $stableManifest -RequestedTag 'v0.1.0-alpha.19' } 'retired alpha tags are rejected by manifest validation'

$wrongTarget = [pscustomobject]@{ target_commitish='main' }
Assert-Throws { Assert-ReleaseTargetCommitish -Release $wrongTarget -SourceCommit ([string]$stableManifest.source.commit) } 'branch target is rejected when it differs from the source commit'
Assert-Throws { Assert-ReleaseTargetCommitish -Release ([pscustomobject]@{ target_commitish=('f' * 40) }) -SourceCommit ([string]$stableManifest.source.commit) } 'release target commit mismatch is rejected'
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{assets=@($stableAssets | Select-Object -First 2)}) -ValidatedManifest $stableValidated -Tag 'v0.1.0' } `
    'stable Release rejects a missing distribution asset'
Assert-Throws { Resolve-ReleaseAssetInventory -Release ([pscustomobject]@{assets=@($stableAssets[0], $stableAssets[1], [pscustomobject]@{id=2005;name='manifest.json';size=256;state='uploaded'})}) -ValidatedManifest $stableValidated -Tag 'v0.1.0' } `
    'stable Release rejects duplicate asset names'
Assert-Throws { Resolve-ReleaseAssetInventory -Release $stableRelease -ValidatedManifest $stableValidated -Tag 'v0.1.1' } `
    'manifest asset inventory is only defined for the stable v0.1.0 Release'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-release-download-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null
try {
    $context = Get-DownloadDestinationContext -Destination (Join-Path $temporaryRoot 'output')
    Assert-True (Test-PathWithinDirectory -Path $context.Staging -Directory $context.Parent) 'staging is a child of its chosen parent'
    Assert-Throws { Get-DownloadDestinationContext -Destination $temporaryRoot } 'existing target directory is not overwritten'
    Assert-Throws { Get-DownloadDestinationContext -Destination (Join-Path $temporaryRoot 'missing\output') } 'missing parent directory is rejected'

    $protectedTarget = Join-Path $temporaryRoot 'protected-target'
    [System.IO.Directory]::CreateDirectory($protectedTarget) | Out-Null
    $protectedTargetFile = Join-Path $protectedTarget 'keep.txt'
    [System.IO.File]::WriteAllText($protectedTargetFile, 'preserve target')
    [System.IO.Directory]::CreateDirectory($context.Staging) | Out-Null
    $occupiedStageFile = Join-Path $context.Staging 'keep.txt'
    [System.IO.File]::WriteAllText($occupiedStageFile, 'preserve occupied stage')
    Assert-Throws { New-DownloadStagingRoot -Path $context.Staging } 'an occupied GUID staging directory is rejected'
    Assert-True ([System.IO.File]::ReadAllText($occupiedStageFile) -ceq 'preserve occupied stage' -and
        [System.IO.File]::ReadAllText($protectedTargetFile) -ceq 'preserve target') `
        'occupied staging contents and an unrelated existing target remain untouched'
    $freshStage = Join-Path $temporaryRoot 'fresh-exclusive-stage'
    Assert-True ((New-DownloadStagingRoot -Path $freshStage) -and
        (Assert-DownloadStagingRoot -Path $freshStage) -eq $null) `
        'a newly created staging root is immediately checked as a regular directory'
    Assert-Throws { New-DownloadStagingRoot -Path $freshStage } 'exclusive staging creation rejects a path created by an earlier call'

    $smallFile = Join-Path $temporaryRoot 'small.bin'
    [System.IO.File]::WriteAllBytes($smallFile, [System.Text.Encoding]::UTF8.GetBytes('offline'))
    $smallHash = (Get-FileHash -LiteralPath $smallFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ((Test-DownloadedFile -Path $smallFile -ExpectedLength 7 -ExpectedSha256 $smallHash) -ceq $smallHash) 'downloaded file length and hash are checked'
    Assert-Throws { Test-DownloadedFile -Path $smallFile -ExpectedLength 6 -ExpectedSha256 $smallHash } 'altered length is rejected'
    Assert-Throws { Test-DownloadedFile -Path $smallFile -ExpectedLength 7 -ExpectedSha256 ('0' * 64) } 'altered digest is rejected'

    $stableArchiveFixture = New-StableArchiveFixture
    $stableZipEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $stableArchiveFixture.Contents.Keys) {
        $stableZipEntries.Add([pscustomobject]@{ Path=[string]$path; Bytes=[byte[]]$stableArchiveFixture.Contents[$path] })
    }
    $stableZipEntries.Add([pscustomobject]@{ Path='manifest.json'; Bytes=[byte[]]$stableArchiveFixture.ManifestBytes })
    $validStableArchive = Join-Path $temporaryRoot 'stable-valid.zip'
    New-StableTestZipArchive -Path $validStableArchive -Entries $stableZipEntries.ToArray()

    $stableArchiveHash = (Get-FileHash -LiteralPath $validStableArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $stableManifestHash = Get-ByteArraySha256 -Bytes $stableArchiveFixture.ManifestBytes
    $stableChecksumText = $stableArchiveHash + '  WIREX_Bridge_v0.1.0.zip' + "`n" +
        $stableManifestHash + '  manifest.json' + "`n"
    $stableChecksumBytes = [System.Text.Encoding]::UTF8.GetBytes($stableChecksumText)
    $script:stableFakeAssetPayloads = @{}
    $script:stableFakeAssetPayloads[[long]3101] = $stableChecksumBytes
    $script:stableFakeAssetPayloads[[long]3102] = [System.IO.File]::ReadAllBytes($validStableArchive)
    $productionGetAssetResponse = (Get-Item -Path 'Function:Get-ReleaseAssetResponse').ScriptBlock
    try {
        Set-Item -Path 'Function:Get-ReleaseAssetResponse' -Value {
            param([long]$AssetId, [string]$Token)
            $payload = $script:stableFakeAssetPayloads[[long]$AssetId]
            if ($null -eq $payload) { throw 'Fake HTTP server received an unregistered asset id.' }
            $fakeResponse = [pscustomobject]@{ ContentLength=[long]$payload.Length; Bytes=[byte[]]$payload }
            Add-Member -InputObject $fakeResponse -MemberType ScriptMethod -Name GetResponseStream -Value {
                return [System.IO.MemoryStream]::new([byte[]]$this.Bytes, $false)
            } -Force
            Add-Member -InputObject $fakeResponse -MemberType ScriptMethod -Name Close -Value { } -Force
            return $fakeResponse
        }
        $stableProductionStage = Join-Path $temporaryRoot 'stable-production-stage'
        $stableAssetScratch = Join-Path $temporaryRoot ('.wirex-release-assets-' + [guid]::NewGuid().ToString('N'))
        [void](New-DownloadStagingRoot -Path $stableProductionStage)
        [void](New-DownloadStagingRoot -Path $stableAssetScratch)
        $stableIntegrationAssets = @{
            'SHA256SUMS.txt'=[pscustomobject]@{ id=3101; name='SHA256SUMS.txt'; size=[long]$stableChecksumBytes.Length; digest='' }
            'WIREX_Bridge_v0.1.0.zip'=[pscustomobject]@{ id=3102; name='WIREX_Bridge_v0.1.0.zip'; size=[long](Get-Item -LiteralPath $validStableArchive).Length; digest='' }
        }
        Invoke-StableArchiveDownload -Staging $stableProductionStage -AssetStaging $stableAssetScratch `
            -Token 'offline-fake-http' -AssetMap $stableIntegrationAssets `
            -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes
        Assert-True ((Test-StableExtractedInventory -Directory $stableProductionStage) -eq $true -and
            (Test-StablePackageProvenance -Directory $stableProductionStage -ValidatedManifest $stableArchiveFixture.Validated) -eq $null) `
            'production stable asset-download path validates extracted inventory and provenance with asset parts isolated in sibling scratch'
        Assert-True (@(Get-ChildItem -LiteralPath $stableAssetScratch -Force).Count -eq 0) `
            'production stable asset-download path removes both temporary files before returning'
    } finally {
        Set-Item -Path 'Function:Get-ReleaseAssetResponse' -Value $productionGetAssetResponse
        $script:stableFakeAssetPayloads = $null
    }

    $stableExtraction = Join-Path $temporaryRoot 'stable-extracted'
    [System.IO.Directory]::CreateDirectory($stableExtraction) | Out-Null
    Expand-StablePackageArchive -ArchivePath $validStableArchive -Destination $stableExtraction `
        -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes
    Assert-True ((Test-StableExtractedInventory -Directory $stableExtraction) -eq $true) `
        'valid stable ZIP extracts to the exact manifest file and eight-directory inventory'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$stableArchiveFixture.ManifestBytes,
        [byte[]][System.IO.File]::ReadAllBytes((Join-Path $stableExtraction 'manifest.json')))) `
        'stable ZIP extraction preserves original manifest bytes'
    Assert-True (-not [System.IO.Directory]::Exists((Join-Path $stableExtraction 'runtime/tools'))) `
        'stable ZIP extraction does not invent the removed runtime/tools directory'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $stableExtraction 'runtime/private/device-y.bin') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
        $script:approvedYFixtureSha256) 'stable ZIP extraction retains the approved HRI template bytes'

    $caseRenamedEntries = @($stableZipEntries | ForEach-Object { [pscustomobject]@{ Path=[string]$_.Path; Bytes=[byte[]]$_.Bytes } })
    $activationEntry = @($caseRenamedEntries | Where-Object { [string]$_.Path -ceq 'runtime/ui/windows/ChannelActivationState.psm1' })[0]
    $activationEntry.Path = 'runtime/ui/windows/channelActivationState.psm1'
    $caseRenamedArchive = Join-Path $temporaryRoot 'stable-case-renamed.zip'
    New-StableTestZipArchive -Path $caseRenamedArchive -Entries $caseRenamedEntries
    $caseRenamedDestination = Join-Path $temporaryRoot 'stable-case-renamed-output'
    [System.IO.Directory]::CreateDirectory($caseRenamedDestination) | Out-Null
    Assert-Throws { Expand-StablePackageArchive -ArchivePath $caseRenamedArchive -Destination $caseRenamedDestination `
        -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
        'stable downloader rejects a single non-canonical case variant even without a duplicate entry'

    $zipSlipEntries = @($stableZipEntries | ForEach-Object { [pscustomobject]@{ Path=[string]$_.Path; Bytes=[byte[]]$_.Bytes } })
    $zipSlipEntries[0].Path = '../escape.txt'
    $zipSlipPath = Join-Path $temporaryRoot 'stable-zip-slip.zip'
    New-StableTestZipArchive -Path $zipSlipPath -Entries $zipSlipEntries
    $zipSlipDestination = Join-Path $temporaryRoot 'stable-zip-slip-output'
    [System.IO.Directory]::CreateDirectory($zipSlipDestination) | Out-Null
    Assert-Throws { Expand-StablePackageArchive -ArchivePath $zipSlipPath -Destination $zipSlipDestination `
        -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
        'stable downloader refuses ZIP-slip paths before writing files'

    $adsEntries = @($stableZipEntries | ForEach-Object { [pscustomobject]@{ Path=[string]$_.Path; Bytes=[byte[]]$_.Bytes } })
    $adsEntries[0].Path = 'runtime/config.json:stream'
    $adsPath = Join-Path $temporaryRoot 'stable-ads.zip'
    New-StableTestZipArchive -Path $adsPath -Entries $adsEntries
    $adsDestination = Join-Path $temporaryRoot 'stable-ads-output'
    [System.IO.Directory]::CreateDirectory($adsDestination) | Out-Null
    Assert-Throws { Expand-StablePackageArchive -ArchivePath $adsPath -Destination $adsDestination `
        -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
        'stable downloader refuses NTFS alternate data stream paths'

    $duplicateEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $stableZipEntries) { $duplicateEntries.Add([pscustomobject]@{ Path=[string]$item.Path; Bytes=[byte[]]$item.Bytes }) }
    $sourceIndex = -1
    for ($index = 0; $index -lt $duplicateEntries.Count; $index++) {
        if ($duplicateEntries[$index].Path -ceq 'SOURCE.txt') { $sourceIndex = $index; break }
    }
    if ($sourceIndex -lt 0) { throw 'Stable ZIP fixture did not contain SOURCE.txt.' }
    $duplicateEntries.RemoveAt($sourceIndex)
    $launcherEntry = @($stableZipEntries | Where-Object { [string]$_.Path -ceq 'WirexBridge.exe' })[0]
    $duplicateEntries.Add([pscustomobject]@{ Path='wirexbridge.exe'; Bytes=[byte[]]$launcherEntry.Bytes })
    $duplicatePath = Join-Path $temporaryRoot 'stable-case-duplicate.zip'
    New-StableTestZipArchive -Path $duplicatePath -Entries $duplicateEntries.ToArray()
    $duplicateDestination = Join-Path $temporaryRoot 'stable-case-duplicate-output'
    [System.IO.Directory]::CreateDirectory($duplicateDestination) | Out-Null
    Assert-Throws { Expand-StablePackageArchive -ArchivePath $duplicatePath -Destination $duplicateDestination `
        -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
        'stable downloader refuses case-insensitive duplicate ZIP paths'

    $entryTypeCases = @(
        [pscustomobject]@{ Name='symlink'; Attributes=([int]0xa000 -shl 16) },
        [pscustomobject]@{ Name='fifo'; Attributes=([int]0x1000 -shl 16) },
        [pscustomobject]@{ Name='character-device'; Attributes=([int]0x2000 -shl 16) },
        [pscustomobject]@{ Name='block-device'; Attributes=([int]0x6000 -shl 16) },
        [pscustomobject]@{ Name='socket'; Attributes=([int]0xc000 -shl 16) },
        [pscustomobject]@{ Name='directory'; Attributes=([int]0x4000 -shl 16) },
        [pscustomobject]@{ Name='dos-directory-bit'; Attributes=0x10 }
    )
    foreach ($entryTypeCase in $entryTypeCases) {
        $invalidEntries = @($stableZipEntries | ForEach-Object { [pscustomobject]@{ Path=[string]$_.Path; Bytes=[byte[]]$_.Bytes } })
        Add-Member -InputObject $invalidEntries[0] -NotePropertyName Attributes -NotePropertyValue ([int]$entryTypeCase.Attributes)
        $invalidArchive = Join-Path $temporaryRoot ('stable-type-' + [string]$entryTypeCase.Name + '.zip')
        New-StableTestZipArchive -Path $invalidArchive -Entries $invalidEntries
        $invalidDestination = Join-Path $temporaryRoot ('stable-type-' + [string]$entryTypeCase.Name + '-output')
        [System.IO.Directory]::CreateDirectory($invalidDestination) | Out-Null
        Assert-Throws { Expand-StablePackageArchive -ArchivePath $invalidArchive -Destination $invalidDestination `
            -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
            ('stable downloader rejects non-regular ZIP entry type: ' + [string]$entryTypeCase.Name)
    }

    $junctionTarget = Join-Path $temporaryRoot 'junction-target'
    $junctionPath = Join-Path $temporaryRoot 'staging-junction'
    [System.IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    $junctionCreationFailure = $null
    try { New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null }
    catch { $junctionCreationFailure = $_.Exception.Message }
    if ([System.IO.Directory]::Exists($junctionPath)) {
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force -ErrorAction Stop
        if (($junctionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw 'The junction test path exists but is not a reparse point.'
        }
        Assert-Throws { Assert-DownloadStagingRoot -Path $junctionPath } 'download staging root reparse point is rejected'
        Assert-Throws { Test-StableExtractedInventory -Directory $junctionPath } 'final stable inventory rejects a reparse staging root'
        Assert-Throws { Expand-StablePackageArchive -ArchivePath $validStableArchive -Destination $junctionPath `
            -ValidatedManifest $stableArchiveFixture.Validated -ManifestBytes $stableArchiveFixture.ManifestBytes } `
            'stable archive expansion rejects a reparse staging root at entry'
        Remove-Item -LiteralPath $junctionPath -Force -ErrorAction Stop
        Assert-True ([System.IO.Directory]::Exists($junctionTarget) -and (Get-ChildItem -LiteralPath $junctionTarget -Force).Count -eq 0) `
            'reparse-root checks and junction cleanup leave the target directory intact'
    } else {
        $skipReason = 'Junction creation was denied by this environment.'
        if (-not [string]::IsNullOrWhiteSpace($junctionCreationFailure)) { $skipReason += ' ' + $junctionCreationFailure }
        [void]$script:offlineSkippedCases.Add('staging-root junction rejection: ' + $skipReason)
        Write-Host ('SKIP: staging-root junction rejection was not tested because ' + $skipReason)
    }
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
$stablePackageProfile = Set-ReleaseVersion -Version 'v0.1.0'
$stableDownloadFiles = @(Get-ExpectedStableReleaseFiles)
$stablePackageFiles = @($stablePackageProfile.PackageFiles | Where-Object { [string]$_ -cne 'manifest.json' })
$stablePublisherProfile = Set-PublishProfile -Tag 'v0.1.0'
$stablePublisherRecords = @(Get-ExpectedStablePackageRecords)
Assert-True ($stableDownloadFiles.Count -eq $stablePackageFiles.Count -and
    $stableDownloadFiles.Count -eq $stablePublisherRecords.Count -and
    $stablePackageProfile.TestNames.Count -eq $downloadProfiles['v0.1.0'].Tests.Count -and
    $stablePublisherProfile.TestNames.Count -eq $downloadProfiles['v0.1.0'].Tests.Count) `
    'stable package, downloader, and publisher retain the same complete fixed file and test inventories'
foreach ($downloadFile in $stableDownloadFiles) {
    Assert-True (@($stablePackageProfile.PackageFiles | Where-Object { [string]$_ -ceq [string]$downloadFile.Path }).Count -eq 1 -and
        [string]$stablePackageProfile.AssetMap[[string]$downloadFile.Path] -ceq [string]$downloadFile.AssetName -and
        @($stablePublisherRecords | Where-Object { [string]$_.Path -ceq [string]$downloadFile.Path -and
            [string]$_.AssetName -ceq [string]$downloadFile.AssetName }).Count -eq 1) `
        ('stable package, downloader, and publisher asset mapping match: ' + [string]$downloadFile.Path)
}
Assert-True ([string]::Join('|', $stablePackageProfile.Directories) -ceq
    [string]::Join('|', (Get-ExpectedReleaseDirectories -Tag 'v0.1.0')) -and
    [string]::Join('|', $stablePublisherProfile.Directories) -ceq
    [string]::Join('|', (Get-ExpectedReleaseDirectories -Tag 'v0.1.0')) -and
    @($stablePackageProfile.Directories | Where-Object { [string]$_ -ceq 'runtime/tools' }).Count -eq 0) `
    'stable package, downloader, and publisher use the same exact directory inventory without runtime/tools'
for ($index = 0; $index -lt $downloadProfiles['v0.1.0'].Tests.Count; $index++) {
    Assert-True ([string]$stablePackageProfile.TestNames[$index] -ceq [string]$downloadProfiles['v0.1.0'].Tests[$index] -and
        [string]$stablePublisherProfile.TestNames[$index] -ceq [string]$downloadProfiles['v0.1.0'].Tests[$index]) `
        "stable package, downloader, and publisher test order matches at index $index"
}

Write-Host "PASS: $script:assertionCount offline release-downloader assertions; Windows PowerShell $($PSVersionTable.PSVersion); no network, Release download, installation, or executable launch."
if ($script:offlineSkippedCases.Count -gt 0) {
    Write-Host ('SKIPPED: ' + $script:offlineSkippedCases.Count + ' environment-dependent check(s): ' + [string]::Join(' | ', $script:offlineSkippedCases))
} else {
    Write-Host 'SKIPPED: 0 environment-dependent checks.'
}
