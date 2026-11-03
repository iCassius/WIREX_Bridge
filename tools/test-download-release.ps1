$ErrorActionPreference = 'Stop'

$script:stableReleaseContractPath = Join-Path $PSScriptRoot 'StableReleaseContract.psm1'
Import-Module -Name $script:stableReleaseContractPath -Force -Scope Global -ErrorAction Stop
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
$script:maximumPackageBytes = 256MB
$script:maximumStablePackageBytes = [long]$script:stableReleaseLimits.MaximumUncompressedBytes
$script:maximumStableArchiveBytes = [long]$script:stableReleaseLimits.MaximumArchiveBytes
$script:maximumDownloaderAssetBytes = 512KB
$script:releaseDownloaderAssetName = 'download-release.ps1'
$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:releaseAssetRedirectHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
)
$script:assertionCount = 0
$script:offlineSkippedCases = New-Object 'System.Collections.Generic.List[string]'
$downloadProfiles = @{}
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12', 'v0.1.0-alpha.13', 'v0.1.0-alpha.14', 'v0.1.0-alpha.15', 'v0.1.0-alpha.16', 'v0.1.0-alpha.17', 'v0.1.0-alpha.18', 'v0.1.0-alpha.19')) {
    $downloadProfiles[$tag] = [pscustomobject]@{
        Files = @(Get-ExpectedReleaseFiles -Tag $tag)
        Tests = @(Get-ExpectedReleaseTests -Tag $tag)
    }
}
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
    $excludedPrivateFiles = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
    if ($Tag -ceq 'v0.1.0-alpha.9') {
        $excludedPrivateFiles += @('private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json')
    }
    if ($Tag -ceq 'v0.1.0-alpha.10') {
        $excludedPrivateFiles += @('private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt')
    }
    if ($Tag -ceq 'v0.1.0-alpha.11') {
        $excludedPrivateFiles += @('private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt')
    }
    if ($Tag -ceq 'v0.1.0-alpha.12') {
        $excludedPrivateFiles += @('private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json')
    }
    if ($Tag -ceq 'v0.1.0-alpha.13') {
        $excludedPrivateFiles += @('private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json', 'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json')
    }
    if ($Tag -cin @('v0.1.0-alpha.14', 'v0.1.0-alpha.15', 'v0.1.0-alpha.16', 'v0.1.0-alpha.17', 'v0.1.0-alpha.18', 'v0.1.0-alpha.19')) {
        $excludedPrivateFiles += @(
            'config.json', 'config.*.backup*', 'credentials/', 'tempSecrets/',
            'private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json', 'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json'
        )
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
        excluded_private_files = $excludedPrivateFiles
        runtime_directories = @('logs/ (empty at package creation)')
        manifest_asset_name = 'manifest.json'
        files = $records
    }
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

$validManifest = New-TestManifest
$validated = Test-ManifestDocument -Manifest $validManifest -RequestedTag 'v0.1.0-alpha.1'
Assert-True ($validated.Files.Count -eq (Get-ExpectedReleaseFiles).Count) 'valid manifest includes the fixed package inventory'
Assert-True ($validated.TotalBytes -gt 0) 'validated size total is accumulated'
$alpha2Manifest = New-TestManifest -Tag 'v0.1.0-alpha.2'
$alpha2Validated = Test-ManifestDocument -Manifest $alpha2Manifest -RequestedTag 'v0.1.0-alpha.2'
Assert-True ($alpha2Validated.Files.Count -eq 26) 'alpha.2 manifest includes the 26-file package inventory'
Assert-True (@($alpha2Manifest.build.passed_tests).Count -eq 28 -and
    $alpha2Manifest.build.passed_tests[15] -ceq 'ui_pipe_test') 'alpha.2 manifest records the exact builder test order'
Assert-Throws { Test-ManifestDocument -Manifest $alpha2Manifest -RequestedTag 'v0.1.0-alpha.1' } 'alpha.2 manifest is rejected for alpha.1 tag'
$alpha3Manifest = New-TestManifest -Tag 'v0.1.0-alpha.3'
$alpha3Validated = Test-ManifestDocument -Manifest $alpha3Manifest -RequestedTag 'v0.1.0-alpha.3'
Assert-True ($alpha3Validated.Files.Count -eq 27) 'alpha.3 manifest includes the 27-file inventory'
Assert-True (@($alpha3Manifest.build.passed_tests).Count -eq 35 -and
    $alpha3Manifest.build.passed_tests[3] -ceq 'hri_call_header_test' -and
    $alpha3Manifest.build.passed_tests[19] -ceq 'ui_pipe_test' -and
    $alpha3Manifest.build.passed_tests[34] -ceq 'bm_bridge_loopback_test') `
    'alpha.3 manifest records the exact 35-test builder order'
Assert-True (@($alpha3Validated.Files | Where-Object {
    $_.path -ceq 'docs/BM来话身份显示.md' -and $_.asset_name -ceq 'docs__bm-call-identity.md'
}).Count -eq 1) 'alpha.3 maps the BM call identity guide to one ASCII asset name'
Assert-Throws { Test-ManifestDocument -Manifest $alpha3Manifest -RequestedTag 'v0.1.0-alpha.2' } 'alpha.3 manifest is rejected for alpha.2 tag'
$alpha4Manifest = New-TestManifest -Tag 'v0.1.0-alpha.4'
$alpha4Validated = Test-ManifestDocument -Manifest $alpha4Manifest -RequestedTag 'v0.1.0-alpha.4'
Assert-True ($alpha4Validated.Files.Count -eq 27) 'alpha.4 keeps the 27-file alpha.3 package inventory'
Assert-True (@($alpha4Manifest.build.passed_tests).Count -eq 35 -and
    [string]::Join('|', @($alpha4Manifest.build.passed_tests)) -ceq
        [string]::Join('|', @($alpha3Manifest.build.passed_tests))) `
    'alpha.4 preserves all 35 alpha.3 C++ tests in the same order'
Assert-Throws { Test-ManifestDocument -Manifest $alpha4Manifest -RequestedTag 'v0.1.0-alpha.3' } 'alpha.4 manifest is rejected for alpha.3 tag'
$alpha5Manifest = New-TestManifest -Tag 'v0.1.0-alpha.5'
$alpha5Validated = Test-ManifestDocument -Manifest $alpha5Manifest -RequestedTag 'v0.1.0-alpha.5'
Assert-True ($alpha5Validated.Files.Count -eq 33) 'alpha.5 manifest contains the 27 alpha.4 files plus two guides and four test entry files'
Assert-True (@($alpha5Manifest.build.passed_tests).Count -eq 36 -and
    [string]::Join('|', @($alpha5Manifest.build.passed_tests[0..34])) -ceq
        [string]::Join('|', @($alpha4Manifest.build.passed_tests)) -and
    $alpha5Manifest.build.passed_tests[35] -ceq 'ui_control_protocol_v2_test') `
    'alpha.5 manifest retains all 35 alpha.4 tests in order then appends the IPC v2 test'
Assert-Throws { Test-ManifestDocument -Manifest $alpha5Manifest -RequestedTag 'v0.1.0-alpha.4' } 'alpha.5 manifest is rejected for alpha.4 tag'
$alpha6Manifest = New-TestManifest -Tag 'v0.1.0-alpha.6'
$alpha6Validated = Test-ManifestDocument -Manifest $alpha6Manifest -RequestedTag 'v0.1.0-alpha.6'
Assert-True ($alpha6Validated.Files.Count -eq 36) 'alpha.6 manifest contains the 33 alpha.5 package files plus the R108 guide and two merged-entry files'
Assert-True (@($alpha6Manifest.build.passed_tests).Count -eq 39 -and
    [string]::Join('|', @($alpha6Manifest.build.passed_tests[0..35])) -ceq
        [string]::Join('|', @($alpha5Manifest.build.passed_tests)) -and
    $alpha6Manifest.build.passed_tests[36] -ceq 'talkgroup_routing_test' -and
    $alpha6Manifest.build.passed_tests[37] -ceq 'bm_routing_lifecycle_test' -and
    $alpha6Manifest.build.passed_tests[38] -ceq 'routing_state_test') `
    'alpha.6 manifest keeps alpha.5 tests and appends the three fixed R108 tests in builder order'
Assert-Throws { Test-ManifestDocument -Manifest $alpha6Manifest -RequestedTag 'v0.1.0-alpha.5' } 'alpha.6 manifest is rejected for alpha.5 tag'
$alpha7Manifest = New-TestManifest -Tag 'v0.1.0-alpha.7'
$alpha7Validated = Test-ManifestDocument -Manifest $alpha7Manifest -RequestedTag 'v0.1.0-alpha.7'
Assert-True ($alpha7Validated.Files.Count -eq 38) 'alpha.7 manifest contains the 36 alpha.6 package files plus two R109 guides'
Assert-True (@($alpha7Manifest.build.passed_tests).Count -eq 39 -and
    [string]::Join('|', @($alpha7Manifest.build.passed_tests)) -ceq
        [string]::Join('|', @($alpha6Manifest.build.passed_tests))) `
    'alpha.7 manifest retains the exact 39 alpha.6 C++ tests in order'
Assert-True (@($alpha7Validated.Files | Where-Object {
    $_.path -ceq 'docs/R109_下行状态与动态组修复.md' -and
    $_.asset_name -ceq 'docs__r109-downlink-dynamic-groups.md'
}).Count -eq 1) 'alpha.7 R109 guide is mapped to one fixed ASCII asset name'
Assert-True (@($alpha7Validated.Files | Where-Object {
    $_.path -ceq 'docs/R109_动态组激活实现.md' -and
    $_.asset_name -ceq 'docs__r109-dynamic-group-activation.md'
}).Count -eq 1) 'alpha.7 dynamic-group guide is mapped to one fixed ASCII asset name'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.7') 'alpha.7 is an explicitly supported release tag'
Assert-Throws { Test-ManifestDocument -Manifest $alpha7Manifest -RequestedTag 'v0.1.0-alpha.6' } 'alpha.7 manifest is rejected for alpha.6 tag'
$alpha8Manifest = New-TestManifest -Tag 'v0.1.0-alpha.8'
$alpha8Validated = Test-ManifestDocument -Manifest $alpha8Manifest -RequestedTag 'v0.1.0-alpha.8'
Assert-True ($alpha8Validated.Files.Count -eq 28) 'alpha.8 inventory removes legacy entry scripts and adds one command and one technical launcher'
Assert-True (@($alpha8Manifest.build.passed_tests).Count -eq 39 -and
    [string]::Join('|', @($alpha8Manifest.build.passed_tests)) -ceq
        [string]::Join('|', @($alpha7Manifest.build.passed_tests))) `
    'alpha.8 retains the exact 39 alpha.7 C++ tests in order'
Assert-True (@($alpha8Validated.Files | Where-Object {
    $_.path -ceq 'start-wirex-bridge.cmd' -and $_.asset_name -ceq 'start-wirex-bridge.cmd'
}).Count -eq 1 -and @($alpha8Validated.Files | Where-Object {
    $_.path -ceq 'tools/start-wirex-bridge.ps1' -and $_.asset_name -ceq 'tools__start-wirex-bridge.ps1'
}).Count -eq 1) 'alpha.8 maps the sole root command and hidden technical launcher to fixed ASCII asset names'
Assert-True (@($alpha8Validated.Files | Where-Object {
    $_.path -match '\.cmd$' -and $_.path -cne 'start-wirex-bridge.cmd'
}).Count -eq 0) 'alpha.8 contains no additional CMD entry points'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.8') 'alpha.8 is an explicitly supported release tag'
Assert-Throws { Test-ManifestDocument -Manifest $alpha8Manifest -RequestedTag 'v0.1.0-alpha.7' } 'alpha.8 manifest is rejected for alpha.7 tag'
$alpha9Manifest = New-TestManifest -Tag 'v0.1.0-alpha.9'
$alpha9Validated = Test-ManifestDocument -Manifest $alpha9Manifest -RequestedTag 'v0.1.0-alpha.9'
Assert-True ($alpha9Validated.Files.Count -eq 32) 'alpha.9 inventory adds RadioIdentity runtime and three R111 documents to alpha.8'
Assert-True (@($alpha9Manifest.build.passed_tests).Count -eq 39 -and
    [string]::Join('|', @($alpha9Manifest.build.passed_tests)) -ceq
        [string]::Join('|', @($alpha8Manifest.build.passed_tests))) `
    'alpha.9 retains the exact 39 alpha.8 C++ tests in order'
foreach ($mapping in @(
    @{ Path='ui/windows/RadioIdentity.psm1'; AssetName='ui__windows__radio-identity.psm1' },
    @{ Path='docs/R111_UI与音量.md'; AssetName='docs__r111-ui-audio.md' },
    @{ Path='docs/R111_BM订阅与收听优先级.md'; AssetName='docs__r111-bm-listening-policy.md' },
    @{ Path='docs/R111_用户资料与电台显示.md'; AssetName='docs__r111-radio-identity-display.md' }
)) {
    Assert-True (@($alpha9Validated.Files | Where-Object {
        $_.path -ceq $mapping.Path -and $_.asset_name -ceq $mapping.AssetName
    }).Count -eq 1) "alpha.9 maps $($mapping.Path) to a fixed ASCII asset"
}
Assert-True (@($alpha9Validated.Files | Where-Object {
    $_.path -match '(?i)(radio-identity-cache\.json|channel-favorites\.json|test-radio-identity(?:-http-server)?\.ps1|private/user-config/)'
}).Count -eq 0) 'alpha.9 allowlist contains neither local identity cache nor developer/private configuration files'
Assert-True (@($alpha9Manifest.excluded_private_files | Where-Object {
    $_ -ceq 'private/user-config-directory.txt' -or
    $_ -ceq 'private/user-config/radio-identity-cache.json' -or
    $_ -ceq 'private/user-config/channel-favorites.json'
}).Count -eq 3) 'alpha.9 manifest explicitly names local pointer, identity cache, and channel favorites exclusions'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.9') 'alpha.9 is an explicitly supported release tag'
Assert-Throws { Test-ManifestDocument -Manifest $alpha9Manifest -RequestedTag 'v0.1.0-alpha.8' } 'alpha.9 manifest is rejected for alpha.8 tag'
$missingAlpha9CacheExclusion = New-TestManifest -Tag 'v0.1.0-alpha.9'
$missingAlpha9CacheExclusion.excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha9CacheExclusion -RequestedTag 'v0.1.0-alpha.9' } `
    'alpha.9 downloader rejects manifest without explicit local cache exclusions'
$invalidAlpha9 = New-TestManifest -Tag 'v0.1.0-alpha.9'
$invalidAlpha9.files += [pscustomobject]@{
    path='radio-identity-cache.json'; asset_name='radio-identity-cache.json'; length_bytes=1
    sha256=('0' * 64); source='synthetic forbidden cache'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha9 -RequestedTag 'v0.1.0-alpha.9' } `
    'alpha.9 downloader rejects personal RadioID cache from the manifest'
$invalidAlpha9Favorites = New-TestManifest -Tag 'v0.1.0-alpha.9'
$invalidAlpha9Favorites.files += [pscustomobject]@{
    path='channel-favorites.json'; asset_name='channel-favorites.json'; length_bytes=1
    sha256=('0' * 64); source='synthetic forbidden local favorites'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha9Favorites -RequestedTag 'v0.1.0-alpha.9' } `
    'alpha.9 downloader rejects user-maintained channel favorites from the manifest'
$invalidAlpha9TestHelper = New-TestManifest -Tag 'v0.1.0-alpha.9'
$invalidAlpha9TestHelper.files += [pscustomobject]@{
    path='tools/test-radio-identity-http-server.ps1'; asset_name='tools__test-radio-identity-http-server.ps1'
    length_bytes=1; sha256=('0' * 64); source='synthetic local test helper'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha9TestHelper -RequestedTag 'v0.1.0-alpha.9' } `
    'alpha.9 downloader rejects the local HTTP test helper from the manifest'
$alpha10Manifest = New-TestManifest -Tag 'v0.1.0-alpha.10'
$alpha10Validated = Test-ManifestDocument -Manifest $alpha10Manifest -RequestedTag 'v0.1.0-alpha.10'
Assert-True ($alpha10Validated.Files.Count -eq $alpha9Validated.Files.Count) 'alpha.10 replaces three R111 documents with three R112 documents without changing the asset count'
Assert-True (@($alpha10Manifest.build.passed_tests).Count -eq 39 -and
    [string]::Join('|', @($alpha10Manifest.build.passed_tests)) -ceq
        [string]::Join('|', @($alpha9Manifest.build.passed_tests))) `
    'alpha.10 retains the exact 39 alpha.9 C++ tests in order'
foreach ($mapping in @(
    @{ Path='docs/R112_A_身份查询实施.md'; AssetName='docs__r112-a-identity-lookup.md' },
    @{ Path='docs/R112_A_网络音频指标.md'; AssetName='docs__r112-a-network-audio-metrics.md' },
    @{ Path='docs/R112_A_UI精简.md'; AssetName='docs__r112-a-ui-compact.md' }
)) {
    Assert-True (@($alpha10Validated.Files | Where-Object {
        $_.path -ceq $mapping.Path -and $_.asset_name -ceq $mapping.AssetName
    }).Count -eq 1) "alpha.10 maps $($mapping.Path) to a fixed ASCII asset"
}
Assert-True (@($alpha10Validated.Files | Where-Object {
    $_.path -match '(?i)(radio-identity-cache\.json|channel-favorites\.json|password-file-path\.txt|test-ui-identity\.ps1|test-radio-identity(?:-http-server)?\.ps1|private/user-config/)'
}).Count -eq 0) 'alpha.10 allowlist excludes personal profile, cache, favorites, password-path file and test helpers'
Assert-True (@($alpha10Validated.Files | Where-Object { [string]$_.path -like 'docs/R111_*' }).Count -eq 0) `
    'alpha.10 downloader excludes the three superseded R111 documents'
Assert-True (@($alpha10Manifest.excluded_private_files | Where-Object {
    $_ -ceq 'private/user-config-directory.txt' -or
    $_ -ceq 'private/user-config/radio-identity-cache.json' -or
    $_ -ceq 'private/user-config/channel-favorites.json' -or
    $_ -ceq 'private/user-config/password-file-path.txt'
}).Count -eq 4) 'alpha.10 manifest explicitly lists all local profile and password-path exclusions'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.10') 'alpha.10 is an explicitly supported release tag'
Assert-Throws { Test-ManifestDocument -Manifest $alpha10Manifest -RequestedTag 'v0.1.0-alpha.9' } 'alpha.10 manifest is rejected for alpha.9 tag'
$missingAlpha10PrivateExclusion = New-TestManifest -Tag 'v0.1.0-alpha.10'
$missingAlpha10PrivateExclusion.excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha10PrivateExclusion -RequestedTag 'v0.1.0-alpha.10' } `
    'alpha.10 downloader rejects manifest without personal profile and password-path exclusions'
$invalidAlpha10PasswordPath = New-TestManifest -Tag 'v0.1.0-alpha.10'
$invalidAlpha10PasswordPath.files += [pscustomobject]@{
    path='private/user-config/password-file-path.txt'; asset_name='private__user-config__password-file-path.txt'
    length_bytes=1; sha256=('0' * 64); source='synthetic forbidden password path'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha10PasswordPath -RequestedTag 'v0.1.0-alpha.10' } `
    'alpha.10 downloader rejects a personal password-path file from the manifest'

$alpha11Manifest = New-TestManifest -Tag 'v0.1.0-alpha.11'
$alpha11Manifest.release_scope = 'R113 DIRECT: cached RadioID callsign in the existing mode-4 T90 SrcCallSign field'
$alpha11Validated = Test-ManifestDocument -Manifest $alpha11Manifest -RequestedTag 'v0.1.0-alpha.11'
Assert-True ($alpha11Validated.Files.Count -eq $alpha10Validated.Files.Count) `
    'alpha.11 replaces two R112 documents with two R113 documents and retains the network-audio guide'
$expectedAlpha11Tests = @($alpha10Manifest.build.passed_tests[0..5] + 'radio_identity_cache_test' +
    $alpha10Manifest.build.passed_tests[6..($alpha10Manifest.build.passed_tests.Count - 1)])
Assert-True (@($alpha11Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha11Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha11Tests)) `
    'alpha.11 pins all 40 native tests with radio_identity_cache_test in builder provenance order'
foreach ($mapping in @(
    @{ Path='docs/R112_A_网络音频指标.md'; AssetName='docs__r112-a-network-audio-metrics.md' },
    @{ Path='docs/R113_LCD核心实现.md'; AssetName='docs__r113-lcd-core-implementation.md' },
    @{ Path='docs/R113_身份与LCD接线.md'; AssetName='docs__r113-identity-lcd-integration.md' }
)) {
    Assert-True (@($alpha11Validated.Files | Where-Object {
        $_.path -ceq $mapping.Path -and $_.asset_name -ceq $mapping.AssetName
    }).Count -eq 1) "alpha.11 maps $($mapping.Path) to a fixed ASCII asset"
}
Assert-True (@($alpha11Validated.Files | Where-Object {
    [string]$_.path -ceq 'docs/R112_A_身份查询实施.md' -or [string]$_.path -ceq 'docs/R112_A_UI精简.md' -or
    [string]$_.path -like 'docs/R111_*'
}).Count -eq 0) 'alpha.11 downloader excludes retired R111 and R112 identity/UI documents'
Assert-True (@($alpha11Validated.Files | Where-Object {
    $_.path -match '(?i)(radio-identity-cache\.json|channel-favorites\.json|password-file-path\.txt|test-ui-identity\.ps1|test-radio-identity(?:-http-server)?\.ps1|private/user-config/)'
}).Count -eq 0) 'alpha.11 allowlist excludes personal profile, cache, favorites, password-path file and test helpers'
Assert-True (@($alpha11Manifest.excluded_private_files | Where-Object {
    $_ -ceq 'private/user-config-directory.txt' -or
    $_ -ceq 'private/user-config/radio-identity-cache.json' -or
    $_ -ceq 'private/user-config/channel-favorites.json' -or
    $_ -ceq 'private/user-config/password-file-path.txt'
}).Count -eq 4) 'alpha.11 manifest explicitly lists all local profile and password-path exclusions'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.11') 'alpha.11 is an explicitly supported release tag'
Assert-Throws { Test-ManifestDocument -Manifest $alpha11Manifest -RequestedTag 'v0.1.0-alpha.10' } `
    'alpha.11 manifest is rejected for alpha.10 tag'
$missingAlpha11PrivateExclusion = New-TestManifest -Tag 'v0.1.0-alpha.11'
$missingAlpha11PrivateExclusion.excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha11PrivateExclusion -RequestedTag 'v0.1.0-alpha.11' } `
    'alpha.11 downloader rejects manifest without personal profile and password-path exclusions'
$invalidAlpha11PasswordPath = New-TestManifest -Tag 'v0.1.0-alpha.11'
$invalidAlpha11PasswordPath.files += [pscustomobject]@{
    path='private/user-config/password-file-path.txt'; asset_name='private__user-config__password-file-path.txt'
    length_bytes=1; sha256=('0' * 64); source='synthetic forbidden password path'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha11PasswordPath -RequestedTag 'v0.1.0-alpha.11' } `
    'alpha.11 downloader rejects a personal password-path file from the manifest'

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
$publishedAlpha3 = [pscustomobject]@{ tag_name='v0.1.0-alpha.3'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha3) -RequestedTag 'v0.1.0-alpha.3').tag_name -ceq 'v0.1.0-alpha.3') 'alpha.3 is selected by exact tag'
$publishedAlpha4 = [pscustomobject]@{ tag_name='v0.1.0-alpha.4'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha4) -RequestedTag 'v0.1.0-alpha.4').tag_name -ceq 'v0.1.0-alpha.4') 'alpha.4 is selected by exact tag'
$publishedAlpha5 = [pscustomobject]@{ tag_name='v0.1.0-alpha.5'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha5) -RequestedTag 'v0.1.0-alpha.5').tag_name -ceq 'v0.1.0-alpha.5') 'alpha.5 is selected by exact tag'
$publishedAlpha6 = [pscustomobject]@{ tag_name='v0.1.0-alpha.6'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha6) -RequestedTag 'v0.1.0-alpha.6').tag_name -ceq 'v0.1.0-alpha.6') 'alpha.6 is selected by exact tag'
$publishedAlpha7 = [pscustomobject]@{ tag_name='v0.1.0-alpha.7'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha7) -RequestedTag 'v0.1.0-alpha.7').tag_name -ceq 'v0.1.0-alpha.7') 'alpha.7 is selected by exact tag'
$publishedAlpha8 = [pscustomobject]@{ tag_name='v0.1.0-alpha.8'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha8) -RequestedTag 'v0.1.0-alpha.8').tag_name -ceq 'v0.1.0-alpha.8') 'alpha.8 is selected by exact tag'
$publishedAlpha9 = [pscustomobject]@{ tag_name='v0.1.0-alpha.9'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha9) -RequestedTag 'v0.1.0-alpha.9').tag_name -ceq 'v0.1.0-alpha.9') 'alpha.9 is selected by exact tag'
$publishedAlpha10 = [pscustomobject]@{ tag_name='v0.1.0-alpha.10'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha10) -RequestedTag 'v0.1.0-alpha.10').tag_name -ceq 'v0.1.0-alpha.10') 'alpha.10 is selected by exact tag'
$alpha12Manifest = New-TestManifest -Tag 'v0.1.0-alpha.12'
$alpha12Manifest.release_scope = 'R116 DIRECT: documented CAT queries and controls'
$alpha12Validated = Test-ManifestDocument -Manifest $alpha12Manifest -RequestedTag 'v0.1.0-alpha.12'
$alpha11ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.11')
Assert-True ($alpha12Validated.Files.Count -eq ($alpha11ExpectedFiles.Count + 3)) 'alpha.12 adds RadioCat and two R116 documents while retaining every alpha.11 file'
$expectedAlpha12Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.11')
Assert-True (@($alpha12Manifest.build.passed_tests).Count -eq 40 -and [string]::Join('|', @($alpha12Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha12Tests)) 'alpha.12 pins the same 40 native tests in the alpha.11 order'
foreach ($mapping in @(
    @{ Path='ui/windows/RadioCat.psm1'; AssetName='ui__windows__radio-cat.psm1' },
    @{ Path='docs/R116_CAT能力与控制实现.md'; AssetName='docs__r116-cat-controls.md' },
    @{ Path='docs/R116_电台控制界面.md'; AssetName='docs__r116-radio-controls-ui.md' }
)) {
    Assert-True (@($alpha12Validated.Files | Where-Object { [string]$_.path -ceq $mapping.Path -and [string]$_.asset_name -ceq $mapping.AssetName }).Count -eq 1) "alpha.12 maps $($mapping.Path) to a fixed ASCII asset"
}
Assert-True (@($alpha12Validated.Files | Where-Object { [string]$_.path -match '(?i)(radio-control-preferences\.json|private/user-config/)' }).Count -eq 0) 'alpha.12 allowlist excludes all local radio-control preferences'
Assert-True (@($alpha12Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/radio-control-preferences.json' }).Count -eq 1) 'alpha.12 manifest explicitly lists the local radio-control preference exclusion'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.12') 'alpha.12 is an explicitly supported release tag'
$missingAlpha12PreferenceExclusion = New-TestManifest -Tag 'v0.1.0-alpha.12'
$missingAlpha12PreferenceExclusion.excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha12PreferenceExclusion -RequestedTag 'v0.1.0-alpha.12' } 'alpha.12 downloader rejects a manifest without the local preference exclusion'
$invalidAlpha12Preference = New-TestManifest -Tag 'v0.1.0-alpha.12'
$invalidAlpha12Preference.files += [pscustomobject]@{
    path='private/user-config/radio-control-preferences.json'; asset_name='private__user-config__radio-control-preferences.json'
    length_bytes=1; sha256=('0' * 64); source='synthetic forbidden local preference'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha12Preference -RequestedTag 'v0.1.0-alpha.12' } 'alpha.12 downloader rejects a local radio-control preference file in the generic package'

$alpha13Manifest = New-TestManifest -Tag 'v0.1.0-alpha.13'
$alpha13Manifest.release_scope = 'R117 DIRECT: offline BM server selection and explicit static group management'
$alpha13Validated = Test-ManifestDocument -Manifest $alpha13Manifest -RequestedTag 'v0.1.0-alpha.13'
$alpha12ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.12')
Assert-True ($alpha13Validated.Files.Count -eq ($alpha12ExpectedFiles.Count + 5)) 'alpha.13 adds exactly five runtime assets while retaining every alpha.12 file'
$expectedAlpha13Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.12')
Assert-True (@($alpha13Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha13Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha13Tests)) 'alpha.13 pins the same 40 Native tests in the alpha.12 order'
foreach ($mapping in @(
    @{ Path='ui/windows/RadioCatUi.ps1'; AssetName='ui__windows__radio-cat-ui.ps1' },
    @{ Path='ui/windows/RadioDevices.psm1'; AssetName='ui__windows__radio-devices.psm1' },
    @{ Path='ui/windows/BmServers.psm1'; AssetName='ui__windows__bm-servers.psm1' },
    @{ Path='ui/windows/BmManagement.psm1'; AssetName='ui__windows__bm-management.psm1' },
    @{ Path='ui/windows/BmManagementUi.ps1'; AssetName='ui__windows__bm-management-ui.ps1' }
)) {
    Assert-True (@($alpha13Validated.Files | Where-Object { [string]$_.path -ceq $mapping.Path -and [string]$_.asset_name -ceq $mapping.AssetName }).Count -eq 1) `
        "alpha.13 maps $($mapping.Path) to its fixed ASCII asset"
}
Assert-True (@($alpha13Validated.Files | Where-Object { [string]$_.path -match '(?i)(bm-management-preferences\.json|private/user-config/)' }).Count -eq 0) `
    'alpha.13 allowlist excludes BM key-path and all other local preferences'
Assert-True (@($alpha13Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/bm-management-preferences.json' }).Count -eq 1) `
    'alpha.13 manifest explicitly lists the BM key-path preference exclusion'
Assert-True (@($alpha13Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/bm-server-preferences.json' }).Count -eq 1) `
    'alpha.13 manifest explicitly lists the BM server-selection preference exclusion'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.13') 'alpha.13 is an explicitly supported release tag'
$missingAlpha13PreferenceExclusion = New-TestManifest -Tag 'v0.1.0-alpha.13'
$missingAlpha13PreferenceExclusion.excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha13PreferenceExclusion -RequestedTag 'v0.1.0-alpha.13' } `
    'alpha.13 downloader rejects a manifest without local BM and CAT preference exclusions'
$missingAlpha13ServerPreferenceExclusion = New-TestManifest -Tag 'v0.1.0-alpha.13'
$missingAlpha13ServerPreferenceExclusion.excluded_private_files = @(
    $missingAlpha13ServerPreferenceExclusion.excluded_private_files | Where-Object {
        [string]$_ -cne 'private/user-config/bm-server-preferences.json'
    }
)
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha13ServerPreferenceExclusion -RequestedTag 'v0.1.0-alpha.13' } `
    'alpha.13 downloader rejects a manifest that omits the BM server-selection preference exclusion'
$invalidAlpha13Preference = New-TestManifest -Tag 'v0.1.0-alpha.13'
$invalidAlpha13Preference.files += [pscustomobject]@{
    path='private/user-config/bm-management-preferences.json'; asset_name='private__user-config__bm-management-preferences.json'
    length_bytes=1; sha256=('0' * 64); source='synthetic forbidden local BM preference'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha13Preference -RequestedTag 'v0.1.0-alpha.13' } `
    'alpha.13 downloader rejects a local BM API-key path preference in the generic package'
$invalidAlpha13ServerPreference = New-TestManifest -Tag 'v0.1.0-alpha.13'
$invalidAlpha13ServerPreference.files += [pscustomobject]@{
    path='private/user-config/bm-server-preferences.json'; asset_name='private__user-config__bm-server-preferences.json'
    length_bytes=1; sha256=('0' * 64); source='synthetic forbidden local BM server preference'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha13ServerPreference -RequestedTag 'v0.1.0-alpha.13' } `
    'alpha.13 downloader rejects local BM server-selection preferences in the generic package'

$alpha14Manifest = New-TestManifest -Tag 'v0.1.0-alpha.14'
$alpha14Manifest.release_scope = 'R118 DIRECT: portable package-root configuration and user-managed channel selection'
$alpha14Validated = Test-ManifestDocument -Manifest $alpha14Manifest -RequestedTag 'v0.1.0-alpha.14'
$alpha13ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.13')
Assert-True ($alpha14Validated.Files.Count -eq ($alpha13ExpectedFiles.Count + 1)) `
    'alpha.14 adds exactly PortableConfig.psm1 and retains every alpha.13 package asset'
$expectedAlpha14Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.13')
Assert-True (@($alpha14Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha14Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha14Tests)) `
    'alpha.14 pins the same 40 Native tests in the alpha.13 order'
Assert-True (@($alpha14Validated.Files | Where-Object {
    [string]$_.path -ceq 'ui/windows/PortableConfig.psm1' -and [string]$_.asset_name -ceq 'ui__windows__portable-config.psm1'
}).Count -eq 1) 'alpha.14 downloader requires PortableConfig under its fixed ASCII asset name'
Assert-True (@($alpha14Validated.Files | Where-Object {
    [string]$_.path -match '(?i)(^|/)(config\.json|config\..*\.backup[^/]*|credentials|tempSecrets)(/|$)'
}).Count -eq 0) 'alpha.14 allowlist does not contain user config, its backups, credential folders or temporary secrets'
foreach ($excludedPath in @('config.json', 'config.*.backup*', 'credentials/', 'tempSecrets/')) {
    Assert-True (@($alpha14Manifest.excluded_private_files | Where-Object { [string]$_ -ceq $excludedPath }).Count -eq 1) `
        "alpha.14 manifest explicitly excludes $excludedPath"
}
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.14') 'alpha.14 is an explicitly supported release tag'
$missingAlpha14ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.14'
$missingAlpha14ConfigExclusion.excluded_private_files = @($missingAlpha14ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha14ConfigExclusion -RequestedTag 'v0.1.0-alpha.14' } `
    'alpha.14 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha14Config = New-TestManifest -Tag 'v0.1.0-alpha.14'
$invalidAlpha14Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha14Config -RequestedTag 'v0.1.0-alpha.14' } `
    'alpha.14 downloader rejects a user-created package-root config file in the generic package'

$alpha15Manifest = New-TestManifest -Tag 'v0.1.0-alpha.15'
$alpha15Manifest.release_scope = 'R119 DIRECT: CAT polling stability and runtime audio gain control with alpha.14 configuration compatibility'
$alpha15Validated = Test-ManifestDocument -Manifest $alpha15Manifest -RequestedTag 'v0.1.0-alpha.15'
$alpha14ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.14')
Assert-True ($alpha15Validated.Files.Count -eq $alpha14ExpectedFiles.Count -and
    [string]::Join('|', @($alpha15Validated.Files | ForEach-Object { [string]$_.path })) -ceq
        [string]::Join('|', @($alpha14ExpectedFiles | ForEach-Object { [string]$_.Path }))) `
    'alpha.15 downloader keeps the exact alpha.14 asset inventory without adding a runtime file'
$expectedAlpha15Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.14')
Assert-True (@($alpha15Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha15Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha15Tests)) `
    'alpha.15 pins the inherited 40 Native tests in the alpha.14 order'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.15') 'alpha.15 is an explicitly supported release tag'
$missingAlpha15ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.15'
$missingAlpha15ConfigExclusion.excluded_private_files = @($missingAlpha15ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha15ConfigExclusion -RequestedTag 'v0.1.0-alpha.15' } `
    'alpha.15 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha15Config = New-TestManifest -Tag 'v0.1.0-alpha.15'
$invalidAlpha15Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha15Config -RequestedTag 'v0.1.0-alpha.15' } `
    'alpha.15 downloader rejects a user-created package-root config file in the generic package'

$alpha16Manifest = New-TestManifest -Tag 'v0.1.0-alpha.16'
$alpha16Manifest.release_scope = 'R120 DIRECT: BrandMeister static talkgroup management inheriting alpha.15 runtime assets'
$alpha16Validated = Test-ManifestDocument -Manifest $alpha16Manifest -RequestedTag 'v0.1.0-alpha.16'
$alpha15ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.15')
Assert-True ($alpha16Validated.Files.Count -eq $alpha15ExpectedFiles.Count -and
    [string]::Join('|', @($alpha16Validated.Files | ForEach-Object { [string]$_.path })) -ceq
        [string]::Join('|', @($alpha15ExpectedFiles | ForEach-Object { [string]$_.Path }))) `
    'alpha.16 downloader keeps the exact alpha.15 asset inventory without adding a runtime file'
$expectedAlpha16Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.15')
Assert-True (@($alpha16Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha16Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha16Tests)) `
    'alpha.16 pins the inherited 40 Native tests in the alpha.15 order'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.16') 'alpha.16 is an explicitly supported release tag'
$missingAlpha16ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.16'
$missingAlpha16ConfigExclusion.excluded_private_files = @($missingAlpha16ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha16ConfigExclusion -RequestedTag 'v0.1.0-alpha.16' } `
    'alpha.16 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha16Config = New-TestManifest -Tag 'v0.1.0-alpha.16'
$invalidAlpha16Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha16Config -RequestedTag 'v0.1.0-alpha.16' } `
    'alpha.16 downloader rejects a user-created package-root config file in the generic package'

$alpha17Manifest = New-TestManifest -Tag 'v0.1.0-alpha.17'
$alpha17Manifest.release_scope = 'R121 DIRECT: fixed no-scroll console and independent BM/serial controls'
$alpha17Validated = Test-ManifestDocument -Manifest $alpha17Manifest -RequestedTag 'v0.1.0-alpha.17'
$alpha16ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.16')
Assert-True ($alpha17Validated.Files.Count -eq 41 -and
    [string]::Join('|', @($alpha17Validated.Files | ForEach-Object { [string]$_.path })) -ceq
        [string]::Join('|', @($alpha16ExpectedFiles | ForEach-Object { [string]$_.Path }))) `
    'alpha.17 downloader accepts the exact 41-file alpha.16 inventory without runtime asset additions'
$expectedAlpha17Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.16')
Assert-True (@($alpha17Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha17Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha17Tests)) `
    'alpha.17 pins the inherited 40 Native tests in their existing order'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.17') 'alpha.17 is an explicitly supported release tag'
$missingAlpha17ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.17'
$missingAlpha17ConfigExclusion.excluded_private_files = @($missingAlpha17ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha17ConfigExclusion -RequestedTag 'v0.1.0-alpha.17' } `
    'alpha.17 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha17Config = New-TestManifest -Tag 'v0.1.0-alpha.17'
$invalidAlpha17Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha17Config -RequestedTag 'v0.1.0-alpha.17' } `
    'alpha.17 downloader rejects a user-created package-root config file in the generic package'

$alpha18Manifest = New-TestManifest -Tag 'v0.1.0-alpha.18'
$alpha18Manifest.release_scope = 'R122 DIRECT: fixed WPF layout and consolidated CAT settings'
$alpha18Validated = Test-ManifestDocument -Manifest $alpha18Manifest -RequestedTag 'v0.1.0-alpha.18'
$alpha17ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.17')
Assert-True ($alpha18Validated.Files.Count -eq 41 -and
    [string]::Join('|', @($alpha18Validated.Files | ForEach-Object { [string]$_.path })) -ceq
        [string]::Join('|', @($alpha17ExpectedFiles | ForEach-Object { [string]$_.Path }))) `
    'alpha.18 downloader accepts the exact 41-file alpha.17 inventory without runtime asset additions'
$expectedAlpha18Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.17')
Assert-True (@($alpha18Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha18Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha18Tests)) `
    'alpha.18 pins the inherited 40 Native tests in their existing order'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.18') 'alpha.18 is an explicitly supported release tag'
$missingAlpha18ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.18'
$missingAlpha18ConfigExclusion.excluded_private_files = @($missingAlpha18ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha18ConfigExclusion -RequestedTag 'v0.1.0-alpha.18' } `
    'alpha.18 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha18Config = New-TestManifest -Tag 'v0.1.0-alpha.18'
$invalidAlpha18Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha18Config -RequestedTag 'v0.1.0-alpha.18' } `
    'alpha.18 downloader rejects a user-created package-root config file in the generic package'

$alpha19Manifest = New-TestManifest -Tag 'v0.1.0-alpha.19'
$alpha19Manifest.release_scope = 'R123 DIRECT: fixed WPF console layout and one-line status'
$alpha19Validated = Test-ManifestDocument -Manifest $alpha19Manifest -RequestedTag 'v0.1.0-alpha.19'
$alpha18ExpectedFiles = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.18')
Assert-True ($alpha19Validated.Files.Count -eq 41 -and
    [string]::Join('|', @($alpha19Validated.Files | ForEach-Object { [string]$_.path })) -ceq
        [string]::Join('|', @($alpha18ExpectedFiles | ForEach-Object { [string]$_.Path }))) `
    'alpha.19 downloader accepts the exact 41-file alpha.18 inventory without runtime asset additions'
$expectedAlpha19Tests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.18')
Assert-True (@($alpha19Manifest.build.passed_tests).Count -eq 40 -and
    [string]::Join('|', @($alpha19Manifest.build.passed_tests)) -ceq [string]::Join('|', $expectedAlpha19Tests)) `
    'alpha.19 pins the inherited 40 Native tests in their existing order'
Assert-True (Test-ReleaseTag -Tag 'v0.1.0-alpha.19') 'alpha.19 is an explicitly supported release tag'
$missingAlpha19ConfigExclusion = New-TestManifest -Tag 'v0.1.0-alpha.19'
$missingAlpha19ConfigExclusion.excluded_private_files = @($missingAlpha19ConfigExclusion.excluded_private_files | Where-Object {
    [string]$_ -cne 'config.json'
})
Assert-Throws { Test-ManifestDocument -Manifest $missingAlpha19ConfigExclusion -RequestedTag 'v0.1.0-alpha.19' } `
    'alpha.19 downloader rejects a manifest that omits the package-root config exclusion'
$invalidAlpha19Config = New-TestManifest -Tag 'v0.1.0-alpha.19'
$invalidAlpha19Config.files += [pscustomobject]@{
    path='config.json'; asset_name='config.json'; length_bytes=1; sha256=('0' * 64); source='synthetic forbidden user config'
}
Assert-Throws { Test-ManifestDocument -Manifest $invalidAlpha19Config -RequestedTag 'v0.1.0-alpha.19' } `
    'alpha.19 downloader rejects a user-created package-root config file in the generic package'

$publishedAlpha11 = [pscustomobject]@{ tag_name='v0.1.0-alpha.11'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha11) -RequestedTag 'v0.1.0-alpha.11').tag_name -ceq 'v0.1.0-alpha.11') 'alpha.11 is selected by exact tag'
$publishedAlpha12 = [pscustomobject]@{ tag_name='v0.1.0-alpha.12'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha12) -RequestedTag 'v0.1.0-alpha.12').tag_name -ceq 'v0.1.0-alpha.12') 'alpha.12 is selected by exact tag'
$publishedAlpha13 = [pscustomobject]@{ tag_name='v0.1.0-alpha.13'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha13) -RequestedTag 'v0.1.0-alpha.13').tag_name -ceq 'v0.1.0-alpha.13') 'alpha.13 is selected by exact tag'
$publishedAlpha14 = [pscustomobject]@{ tag_name='v0.1.0-alpha.14'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha14) -RequestedTag 'v0.1.0-alpha.14').tag_name -ceq 'v0.1.0-alpha.14') 'alpha.14 is selected by exact tag'
$publishedAlpha15 = [pscustomobject]@{ tag_name='v0.1.0-alpha.15'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha15) -RequestedTag 'v0.1.0-alpha.15').tag_name -ceq 'v0.1.0-alpha.15') 'alpha.15 is selected by exact tag'
$publishedAlpha16 = [pscustomobject]@{ tag_name='v0.1.0-alpha.16'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha16) -RequestedTag 'v0.1.0-alpha.16').tag_name -ceq 'v0.1.0-alpha.16') 'alpha.16 is selected by exact tag'
$publishedAlpha17 = [pscustomobject]@{ tag_name='v0.1.0-alpha.17'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha17) -RequestedTag 'v0.1.0-alpha.17').tag_name -ceq 'v0.1.0-alpha.17') 'alpha.17 is selected by exact tag'
$publishedAlpha18 = [pscustomobject]@{ tag_name='v0.1.0-alpha.18'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha18) -RequestedTag 'v0.1.0-alpha.18').tag_name -ceq 'v0.1.0-alpha.18') 'alpha.18 is selected by exact tag'
$publishedAlpha19 = [pscustomobject]@{ tag_name='v0.1.0-alpha.19'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha19) -RequestedTag 'v0.1.0-alpha.19').tag_name -ceq 'v0.1.0-alpha.19') 'alpha.19 is selected by exact tag'

$goodAssets = New-TestAssetList -Manifest $validManifest
$release = [pscustomobject]@{ assets=$goodAssets; target_commitish=[string]$validManifest.source.commit }
$assetMap = Resolve-ReleaseAssetInventory -Release $release -ValidatedManifest $validated
Assert-True ($assetMap.Count -eq $goodAssets.Count) 'release asset inventory matches manifest exactly'
Assert-True ($assetMap.ContainsKey('download-release.ps1')) 'fixed helper is the sole permitted non-manifest release asset'
Assert-True (Assert-ReleaseTargetCommitish -Release $release -SourceCommit ([string]$validManifest.source.commit)) 'release target commit matches the manifest source commit'
$alpha2GoodAssets = New-TestAssetList -Manifest $alpha2Manifest
$alpha2Release = [pscustomobject]@{ assets=$alpha2GoodAssets; target_commitish=[string]$alpha2Manifest.source.commit }
$alpha2AssetMap = Resolve-ReleaseAssetInventory -Release $alpha2Release -ValidatedManifest $alpha2Validated
Assert-True ($alpha2AssetMap.Count -eq 28 -and $alpha2AssetMap.ContainsKey('download-release.ps1')) `
    'alpha.2 remote inventory contains 26 package files, manifest and helper'
$alpha3GoodAssets = New-TestAssetList -Manifest $alpha3Manifest
$alpha3Release = [pscustomobject]@{ assets=$alpha3GoodAssets; target_commitish=[string]$alpha3Manifest.source.commit }
$alpha3AssetMap = Resolve-ReleaseAssetInventory -Release $alpha3Release -ValidatedManifest $alpha3Validated
Assert-True ($alpha3AssetMap.Count -eq 29 -and $alpha3AssetMap.ContainsKey('download-release.ps1') -and
    $alpha3AssetMap.ContainsKey('docs__bm-call-identity.md')) `
    'alpha.3 remote inventory contains 27 package files, manifest and helper'
$alpha4GoodAssets = New-TestAssetList -Manifest $alpha4Manifest
$alpha4Release = [pscustomobject]@{ assets=$alpha4GoodAssets; target_commitish=[string]$alpha4Manifest.source.commit }
$alpha4AssetMap = Resolve-ReleaseAssetInventory -Release $alpha4Release -ValidatedManifest $alpha4Validated
Assert-True ($alpha4AssetMap.Count -eq 29 -and $alpha4AssetMap.ContainsKey('download-release.ps1') -and
    $alpha4AssetMap.ContainsKey('docs__bm-call-identity.md')) `
    'alpha.4 remote inventory keeps 27 package files, manifest and helper'
$alpha5GoodAssets = New-TestAssetList -Manifest $alpha5Manifest
$alpha5Release = [pscustomobject]@{ assets=$alpha5GoodAssets; target_commitish=[string]$alpha5Manifest.source.commit }
$alpha5AssetMap = Resolve-ReleaseAssetInventory -Release $alpha5Release -ValidatedManifest $alpha5Validated
Assert-True ($alpha5AssetMap.Count -eq 35 -and $alpha5AssetMap.ContainsKey('download-release.ps1') -and
    $alpha5AssetMap.ContainsKey('docs__r106-ipc-v2.md') -and
    $alpha5AssetMap.ContainsKey('docs__r106-profile-migration-test.md') -and
    $alpha5AssetMap.ContainsKey('test-control.cmd') -and $alpha5AssetMap.ContainsKey('test-control.ps1') -and
    $alpha5AssetMap.ContainsKey('start-step1-test.cmd') -and $alpha5AssetMap.ContainsKey('start-step1-test.ps1')) `
    'alpha.5 remote inventory has 33 package files, manifest and downloader helper'
$alpha6GoodAssets = New-TestAssetList -Manifest $alpha6Manifest
$alpha6Release = [pscustomobject]@{ assets=$alpha6GoodAssets; target_commitish=[string]$alpha6Manifest.source.commit }
$alpha6AssetMap = Resolve-ReleaseAssetInventory -Release $alpha6Release -ValidatedManifest $alpha6Validated
Assert-True ($alpha6AssetMap.Count -eq 38 -and $alpha6AssetMap.ContainsKey('download-release.ps1') -and
    $alpha6AssetMap.ContainsKey('docs__r108-routing-state-alpha6.md') -and
    $alpha6AssetMap.ContainsKey('start-merged-test.cmd') -and $alpha6AssetMap.ContainsKey('start-merged-test.ps1')) `
    'alpha.6 remote inventory contains 36 package files, manifest and downloader helper'
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
$alpha3Provenance = $provenance | Select-Object *
$alpha3Provenance.tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.3') | ForEach-Object {
    [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
})
Assert-True (Test-BuildProvenanceDocument -Provenance $alpha3Provenance -ValidatedManifest $alpha3Validated) `
    'alpha.3 builder provenance includes all 35 tests in fixed order'
$alpha3Provenance.tests = @($alpha3Provenance.tests | Select-Object -SkipLast 1)
Assert-Throws { Test-BuildProvenanceDocument -Provenance $alpha3Provenance -ValidatedManifest $alpha3Validated } `
    'alpha.3 provenance missing a test is rejected'
$alpha4Provenance = $provenance | Select-Object *
$alpha4Provenance.tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.4') | ForEach-Object {
    [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
})
Assert-True (Test-BuildProvenanceDocument -Provenance $alpha4Provenance -ValidatedManifest $alpha4Validated) `
    'alpha.4 provenance records the inherited 35-test order'
$alpha4Provenance.tests = @($alpha4Provenance.tests | Select-Object -SkipLast 1)
Assert-Throws { Test-BuildProvenanceDocument -Provenance $alpha4Provenance -ValidatedManifest $alpha4Validated } `
    'alpha.4 provenance missing a test is rejected'
$alpha5Provenance = $provenance | Select-Object *
$alpha5Provenance.tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.5') | ForEach-Object {
    [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
})
Assert-True (Test-BuildProvenanceDocument -Provenance $alpha5Provenance -ValidatedManifest $alpha5Validated) `
    'alpha.5 provenance records the 36-test order'
$alpha5Provenance.tests = @($alpha5Provenance.tests | Select-Object -SkipLast 1)
Assert-Throws { Test-BuildProvenanceDocument -Provenance $alpha5Provenance -ValidatedManifest $alpha5Validated } `
    'alpha.5 provenance missing the IPC v2 test is rejected'
$alpha6Provenance = $provenance | Select-Object *
$alpha6Provenance.tests = @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.6') | ForEach-Object {
    [pscustomobject]@{ name=[string]$_; result='passed'; exit_code=0 }
})
Assert-True (Test-BuildProvenanceDocument -Provenance $alpha6Provenance -ValidatedManifest $alpha6Validated) `
    'alpha.6 provenance records all 39 tests in fixed order'
$alpha6Provenance.tests = @($alpha6Provenance.tests | Select-Object -SkipLast 1)
Assert-Throws { Test-BuildProvenanceDocument -Provenance $alpha6Provenance -ValidatedManifest $alpha6Validated } `
    'alpha.6 provenance missing routing_state_test is rejected'

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
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12', 'v0.1.0-alpha.13', 'v0.1.0-alpha.14', 'v0.1.0-alpha.15', 'v0.1.0-alpha.16', 'v0.1.0-alpha.17', 'v0.1.0-alpha.18', 'v0.1.0-alpha.19')) {
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
