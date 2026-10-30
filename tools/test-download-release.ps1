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
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12', 'v0.1.0-alpha.13')) {
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

$publishedAlpha11 = [pscustomobject]@{ tag_name='v0.1.0-alpha.11'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha11) -RequestedTag 'v0.1.0-alpha.11').tag_name -ceq 'v0.1.0-alpha.11') 'alpha.11 is selected by exact tag'
$publishedAlpha12 = [pscustomobject]@{ tag_name='v0.1.0-alpha.12'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha12) -RequestedTag 'v0.1.0-alpha.12').tag_name -ceq 'v0.1.0-alpha.12') 'alpha.12 is selected by exact tag'
$publishedAlpha13 = [pscustomobject]@{ tag_name='v0.1.0-alpha.13'; draft=$false; prerelease=$true }
Assert-True ((Select-ReleaseCandidate -Releases @($publishedAlpha13) -RequestedTag 'v0.1.0-alpha.13').tag_name -ceq 'v0.1.0-alpha.13') 'alpha.13 is selected by exact tag'

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
foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12', 'v0.1.0-alpha.13')) {
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
