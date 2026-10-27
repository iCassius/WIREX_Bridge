[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'publish-release.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    $didThrow = $false
    try { & $Action } catch { $didThrow = $true }
    if (-not $didThrow) { throw ('Expected rejection: ' + $Message) }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$testRoot = Join-Path $repositoryRoot ('build/_work/publish-release-test-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $testRoot 'package'
$fakeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$fixtureBytes = New-Object byte[] 100
$fixtureHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($fixtureBytes))).Replace('-', '').ToLowerInvariant()
$script:approvedFixtureSha256 = $fixtureHash

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($directory in $script:expectedDirectories) {
        New-Item -ItemType Directory -Path (Join-Path $packageRoot $directory.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) -Force | Out-Null
    }

    $records = @()
    foreach ($path in $script:assetPathMap.Keys) {
        $fullPath = Join-Path $packageRoot $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if ($path -ceq 'private/device-y.bin') {
            [System.IO.File]::WriteAllBytes($fullPath, $fixtureBytes)
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic package content: ' + $path)
        }
        $item = Get-Item -LiteralPath $fullPath
        $records += ,([ordered]@{
            path = $path
            asset_name = (Get-PublishAssetName -RelativePath $path)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_private_alpha_release_green_directory'
        package_status = 'root_audit_passed'
        version = 'v0.1.0-alpha.1'
        tag_candidate = 'v0.1.0-alpha.1'
        manifest_asset_name = 'manifest.json'
        source = [ordered]@{
            repository = $script:repositoryUrl
            commit = $fakeCommit
            working_tree_clean = $true
        }
        build = [ordered]@{
            source_commit = $fakeCommit
            source_tree_clean = $true
            compile_only = $false
            build_completed = $true
            result = 'passed'
            passed_test_count = $script:expectedTestNames.Count
            passed_tests = @($script:expectedTestNames)
        }
        approved_y_fixture = [ordered]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $fixtureHash
        }
        files = $records
    }
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $validManifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
    Write-Utf8NoBom -Path $manifestPath -Text ($validManifestJson + "`n")

    $valid = Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit
    Assert-True ($valid.Assets.Count -eq 17) '16 package files plus standalone manifest are accepted'
    Assert-True (@($valid.Assets | Where-Object { $_.Name -ceq 'manifest.json' }).Count -eq 1) 'manifest is a separate release asset'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/连接配置.md') -ceq 'docs__connection-profile.md') 'PowerShell reads the Chinese connection-profile path correctly'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/音量调节.md') -ceq 'docs__audio-gain.md') 'PowerShell reads the Chinese audio-settings path correctly'

    $alpha2Root = Join-Path $testRoot 'package-alpha2'
    Copy-Item -LiteralPath $packageRoot -Destination $alpha2Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.2')
    $alpha2ExtraPaths = @(
        'start-user-config.cmd', 'start-user-config.ps1', 'bridge-user-config.psm1', 'start-ui.cmd', 'start-ui.ps1',
        'docs/配置与桌面操作.md', 'ui/windows/bridge-ui.ps1', 'ui/windows/BridgeSupervisor.cs',
        'ui/windows/MainWindow.xaml', 'ui/windows/SettingsWindow.xaml'
    )
    foreach ($relativePath in $alpha2ExtraPaths) {
        $fullPath = Join-Path $alpha2Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.2 package content: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $manifest.version = 'v0.1.0-alpha.2'
    $manifest.tag_candidate = 'v0.1.0-alpha.2'
    $manifest.build.passed_test_count = $script:expectedTestNames.Count
    $manifest.build.passed_tests = @($script:expectedTestNames)
    $alpha2ManifestPath = Join-Path $alpha2Root 'manifest.json'
    $validAlpha2ManifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
    Write-Utf8NoBom -Path $alpha2ManifestPath -Text ($validAlpha2ManifestJson + "`n")
    $alpha2Package = Assert-PublishPackage -PackageRoot $alpha2Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.2'
    Assert-True ($alpha2Package.Assets.Count -eq 27) 'alpha.2 package accepts 26 files plus standalone manifest'
    Assert-True (@($alpha2Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__SettingsWindow.xaml' }).Count -eq 1) 'alpha.2 UI asset mapping is fixed'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha2Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.1' } 'alpha.2 package cannot pass the alpha.1 profile'

    $alpha3Root = Join-Path $testRoot 'package-alpha3'
    Copy-Item -LiteralPath $alpha2Root -Destination $alpha3Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.3')
    $alpha3IdentityPath = Join-Path $alpha3Root 'docs\BM来话身份显示.md'
    Write-Utf8NoBom -Path $alpha3IdentityPath -Text 'synthetic alpha.3 identity guide'
    $alpha3IdentityItem = Get-Item -LiteralPath $alpha3IdentityPath
    $alpha3ManifestPath = Join-Path $alpha3Root 'manifest.json'
    $alpha3Manifest = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha3Manifest.files += ,([ordered]@{
        path = 'docs/BM来话身份显示.md'
        asset_name = (Get-PublishAssetName -RelativePath 'docs/BM来话身份显示.md')
        length_bytes = [long]$alpha3IdentityItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha3IdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic test content'
    })
    $alpha3Manifest.version = 'v0.1.0-alpha.3'
    $alpha3Manifest.tag_candidate = 'v0.1.0-alpha.3'
    $alpha3Manifest.build.passed_test_count = $script:expectedTestNames.Count
    $alpha3Manifest.build.passed_tests = @($script:expectedTestNames)
    Write-Utf8NoBom -Path $alpha3ManifestPath -Text ((ConvertTo-Json -InputObject $alpha3Manifest -Depth 12) + "`n")
    $alpha3Package = Assert-PublishPackage -PackageRoot $alpha3Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.3'
    Assert-True ($alpha3Package.Assets.Count -eq 28) 'alpha.3 package accepts 27 files plus standalone manifest'
    Assert-True (@($alpha3Package.Assets | Where-Object { $_.Name -ceq 'docs__bm-call-identity.md' }).Count -eq 1) `
        'alpha.3 identity guide asset mapping is fixed'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha3Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.2' } `
        'alpha.3 package cannot pass the alpha.2 profile'
    $validAlpha3ManifestJson = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8)
    $alpha4Root = Join-Path $testRoot 'package-alpha4'
    Copy-Item -LiteralPath $alpha3Root -Destination $alpha4Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.4')
    $alpha4ManifestPath = Join-Path $alpha4Root 'manifest.json'
    $alpha4ReadmePath = Join-Path $alpha4Root 'README.md'
    Write-Utf8NoBom -Path $alpha4ReadmePath -Text 'synthetic alpha.4 package README'
    $alpha4Manifest = [System.IO.File]::ReadAllText($alpha4ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha4ReadmeItem = Get-Item -LiteralPath $alpha4ReadmePath
    $alpha4ReadmeRecord = @($alpha4Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha4ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.3 manifest must contain one README record.' }
    $alpha4ReadmeRecord[0].length_bytes = [long]$alpha4ReadmeItem.Length
    $alpha4ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha4ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha4Manifest.version = 'v0.1.0-alpha.4'
    $alpha4Manifest.tag_candidate = 'v0.1.0-alpha.4'
    $alpha4Manifest.build.passed_test_count = $script:expectedTestNames.Count
    $alpha4Manifest.build.passed_tests = @($script:expectedTestNames)
    $validAlpha4ManifestJson = ConvertTo-Json -InputObject $alpha4Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha4ManifestPath -Text ($validAlpha4ManifestJson + "`n")
    $alpha4Package = Assert-PublishPackage -PackageRoot $alpha4Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.4'
    Assert-True ($alpha4Package.Assets.Count -eq 28) 'alpha.4 package keeps alpha.3 27-file inventory plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.4').AssetPathMap.Count -eq
        (Set-PublishProfile -Tag 'v0.1.0-alpha.3').AssetPathMap.Count) 'alpha.4 keeps alpha.3 asset map size'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha4Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.3' } `
        'alpha.4 package cannot pass the alpha.3 profile'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.4')
    $validAlpha4ManifestJson = [System.IO.File]::ReadAllText($alpha4ManifestPath, [System.Text.Encoding]::UTF8)
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.1')
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    $realTagObject = 'refs/tags/v0.1.0-alpha.1^{commit}'
    $realTagCommit = Get-GitText -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--verify', $realTagObject)
    $realNotesPath = Join-Path $repositoryRoot 'docs/releases/v0.1.0-alpha.1.md'
    $realNotes = Get-PublishNotes -Path $realNotesPath -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit
    Assert-True (-not [string]::IsNullOrWhiteSpace($realNotes)) 'fixed release notes match both the real tag commit and current HEAD'
    Assert-Throws { Get-PublishNotes -Path (Join-Path $repositoryRoot 'README.md') -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit } 'non-release notes path is rejected'

    $manifest.package_status = 'awaiting_root_audit'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unapproved package status'
    $manifest.package_status = 'root_audit_passed'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")

    $readmePath = Join-Path $packageRoot 'README.md'
    $goodReadme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $readmePath -Text 'tampered bytes'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'file hash mismatch'
    Write-Utf8NoBom -Path $readmePath -Text $goodReadme

    $extraPath = Join-Path $packageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $extraPath -Text '{}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unexpected private configuration file'
    Remove-Item -LiteralPath $extraPath -Force

    $record = @($manifest.files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    $record.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'duplicate asset name'

    $unknown = New-UnknownOutcomeError
    Assert-True (Test-UnknownOutcomeError -Exception $unknown) 'mutation recovery recognizes unknown outcomes'
    Assert-True (-not (Test-UnknownOutcomeError -Exception (New-Object System.Exception('known failure')))) 'known API failures are not treated as unknown outcomes'

    $streamBytes = [System.Text.Encoding]::UTF8.GetBytes('synthetic release asset')
    $streamHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($streamBytes))).Replace('-', '').ToLowerInvariant()
    $memoryStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-True ((Get-StreamSha256 -Stream $memoryStream -ExpectedLength $streamBytes.Length) -ceq $streamHash) 'asset stream hash and byte count match' }
    finally { $memoryStream.Dispose() }
    $shortStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-Throws { Get-StreamSha256 -Stream $shortStream -ExpectedLength ($streamBytes.Length - 1) } 'oversized asset stream is rejected' }
    finally { $shortStream.Dispose() }
    $localAsset = [pscustomobject]@{ Name='one.bin'; Length=$streamBytes.Length; Sha256=$streamHash }
    $remoteAsset = [pscustomobject]@{ name='one.bin'; size=$streamBytes.Length; digest=('sha256:' + $streamHash) }
    Assert-True (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset) 'GitHub SHA-256 digest matches local asset'
    $remoteAsset.digest = 'sha256:' + ('0' * 64)
    Assert-True (-not (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset)) 'different GitHub SHA-256 digest is rejected'
    $remoteAsset.digest = 'sha256:' + $streamHash
    $expectedRemote = @([pscustomobject]@{ Name='one.bin' }, [pscustomobject]@{ Name='two.bin' })
    $actualRemote = @([pscustomobject]@{ name='one.bin' }, [pscustomobject]@{ name='two.bin' })
    Assert-True ((Assert-ExactRemoteAssetNames -RemoteAssets $actualRemote -ExpectedAssets $expectedRemote) -eq $null) 'fixed remote asset inventory is accepted'
    Assert-Throws { Assert-ExactRemoteAssetNames -RemoteAssets ($actualRemote + [pscustomobject]@{ name='extra.bin' }) -ExpectedAssets $expectedRemote } 'extra remote asset is rejected'

    $httpClients = New-PublishHttpClients
    try {
        Assert-True ($httpClients.Authenticated -is [System.Net.Http.HttpClient]) 'HTTP client construction works without using a network'
        Assert-True ($null -eq $httpClients.Authenticated.DefaultRequestHeaders.Authorization) 'HTTP client has no credential before runtime initialization'
    } finally {
        $httpClients.Authenticated.Dispose()
        $httpClients.Anonymous.Dispose()
    }
    foreach ($cdnHost in @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
        Assert-True (Test-AllowedReleaseAssetHost -HostName $cdnHost) "known GitHub asset host is accepted: $cdnHost"
    }
    Assert-True (-not (Test-AllowedReleaseAssetHost -HostName 'other.githubusercontent.com')) 'unlisted githubusercontent.com host is rejected'

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'publish-release.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'publisher script parses without errors'

    $mockDraft = [pscustomobject]@{
        id = 77
        tag_name = 'v0.1.0-alpha.1'
        target_commitish = $fakeCommit
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($mockDraft)
    $script:mockCalls = New-Object System.Collections.ArrayList
    function Send-GitHubRequest {
        param([string]$Method, [string]$Uri, [System.Net.Http.HttpContent]$Content=$null, [switch]$AllowNotFound)
        [void]$script:mockCalls.Add([pscustomobject]@{ Method=$Method; Uri=$Uri })
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases/tags/')) { return [pscustomobject]@{ Status=404; Data=$null } }
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases?per_page=')) { return [pscustomobject]@{ Status=200; Data=@($script:mockReleases) } }
        if ($Method -ceq 'POST' -and $Uri.EndsWith('/releases')) { throw (New-UnknownOutcomeError) }
        throw 'Unexpected mocked request.'
    }
    $recovered = New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n"
    Assert-True ([long]$recovered.id -eq 77) 'by-tag 404 falls back to the release list and recovers the existing draft'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq 1) 'unknown POST is not repeated after recovering the draft'
    $script:mockReleases = @($mockDraft, $mockDraft)
    Assert-Throws { Get-ReleaseByTag } 'multiple exact-tag entries in release list are rejected'
    $inconsistentDraft = [pscustomobject]@{
        id = 78
        tag_name = 'v0.1.0-alpha.1'
        target_commitish = ('b' * 40)
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($inconsistentDraft)
    $postsBeforeMismatch = @($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count
    Assert-Throws { New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'inconsistent draft recovered after unknown POST is rejected'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq ($postsBeforeMismatch + 1)) 'inconsistent recovery does not cause a second POST'
    Assert-True ((Get-PublishReleaseAction -Release $mockDraft -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'publish') 'matching draft is eligible for the single publish patch'
    $alreadyPublished = $mockDraft | Select-Object *
    $alreadyPublished.draft = $false
    Assert-True ((Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'already-published') 'matching published prerelease is an idempotent completion'
    $alreadyPublished.prerelease = $false
    Assert-Throws { Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'stable release is rejected'
    foreach ($badMode in @('draft', 'PUBLISH', 'DrAfT')) {
        $modeError = ''
        try {
            Invoke-ReleasePublisher -PackagePath '' -Commit $fakeCommit -NotesFile '' -PublisherMode $badMode -RepositoryRoot ''
        } catch { $modeError = $_.Exception.Message }
        Assert-True ($modeError -ceq 'Mode must be exactly Draft or Publish.') "mode spelling '$badMode' is rejected before local validation or credentials"
    }
    Assert-True ($script:mockCalls.Count -eq 8) 'invalid mode spellings do not issue mocked GitHub requests'

    $script:approvedFixtureSha256 = $fixtureHash
    $preflightRepo = Join-Path $testRoot 'preflight-repo'
    New-Item -ItemType Directory -Path $preflightRepo -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'tools') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'docs/releases') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'download-release.ps1') -Destination (Join-Path $preflightRepo 'tools/download-release.ps1')
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4')) {
        Write-Utf8NoBom -Path (Join-Path $preflightRepo ('docs/releases/' + $tag + '.md')) -Text ('Synthetic offline release notes for ' + $tag + "`n")
    }
    $gitInit = @(& git -C $preflightRepo init --quiet 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the temporary offline Git repository.' }
    foreach ($gitSetting in @(
        @('config', 'user.name', 'WIREX Offline Test'),
        @('config', 'user.email', 'wirex-offline-test@example.invalid'),
        @('remote', 'add', 'origin', $script:repositoryUrl),
        @('add', '--', 'tools/download-release.ps1', 'docs/releases/v0.1.0-alpha.1.md', 'docs/releases/v0.1.0-alpha.2.md', 'docs/releases/v0.1.0-alpha.3.md', 'docs/releases/v0.1.0-alpha.4.md'),
        @('commit', '--quiet', '-m', 'offline publisher preflight fixture')
    )) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $gitOutput = @(& git -C $preflightRepo @gitSetting 2>$null)
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the temporary offline Git repository.' }
    }
    $preflightCommit = [string](@(& git -C $preflightRepo rev-parse HEAD 2>$null)[0]).Trim()
    if ($LASTEXITCODE -ne 0 -or $preflightCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not identify the temporary offline commit.' }
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'build/_work') -Force | Out-Null
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4')) {
        $sourcePackage = switch ($tag) {
            'v0.1.0-alpha.1' { $packageRoot; break }
            'v0.1.0-alpha.2' { $alpha2Root; break }
            'v0.1.0-alpha.3' { $alpha3Root; break }
            'v0.1.0-alpha.4' { $alpha4Root; break }
        }
        $targetPackage = Join-Path $preflightRepo ('build/releases/' + $tag)
        $targetParent = Split-Path -Parent $targetPackage
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        Copy-Item -LiteralPath $sourcePackage -Destination $targetPackage -Recurse
        $sourceManifestText = switch ($tag) {
            'v0.1.0-alpha.1' { $validManifestJson; break }
            'v0.1.0-alpha.2' { $validAlpha2ManifestJson; break }
            'v0.1.0-alpha.3' { $validAlpha3ManifestJson; break }
            'v0.1.0-alpha.4' { $validAlpha4ManifestJson; break }
        }
        $preflightManifest = $sourceManifestText | ConvertFrom-Json
        $preflightManifest.source.commit = $preflightCommit
        $preflightManifest.build.source_commit = $preflightCommit
        Write-Utf8NoBom -Path (Join-Path $targetPackage 'manifest.json') `
            -Text ((ConvertTo-Json -InputObject $preflightManifest -Depth 12) + "`n")
    }

    $helperTempBefore = @(Get-ChildItem -LiteralPath (Join-Path $preflightRepo 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
    $script:preflightBoundaryReached = $false
    $script:credentialAttempted = $false
    function Initialize-GitHubClient {
        $script:preflightBoundaryReached = $true
        throw 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY'
    }
    function Get-GitCredentialToken {
        $script:credentialAttempted = $true
        throw 'OFFLINE_TEST_CREDENTIAL_ACCESS_BLOCKED'
    }
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4')) {
        $script:preflightBoundaryReached = $false
        $boundaryMessage = ''
        try {
            Invoke-ReleasePublisher -PackagePath (Join-Path $preflightRepo ('build/releases/' + $tag)) `
                -Commit $preflightCommit -NotesFile (Join-Path $preflightRepo ('docs/releases/' + $tag + '.md')) `
                -PublisherMode 'Draft' -RepositoryRoot $preflightRepo -Tag $tag
        } catch { $boundaryMessage = $_.Exception.Message }
        Assert-True ($script:preflightBoundaryReached -and $boundaryMessage -ceq 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY') `
            ($tag + ' clean dry package, tag helper blob and notes preflight reaches the mocked network boundary; local result=' + $boundaryMessage)
    }
    $helperTempAfter = @(Get-ChildItem -LiteralPath (Join-Path $preflightRepo 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
    Assert-True (-not $script:credentialAttempted -and $script:mockCalls.Count -eq 8) 'clean dry preflights stop before credentials and API requests'
    Assert-True ($helperTempAfter -eq $helperTempBefore) 'temporary byte-exact helper blobs are removed after the offline boundary stop'

    Write-Output ('Publisher offline assertions passed: ' + $script:assertions + '; no network requests or credentials were used.')
} finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PublishPathWithin -Path $testRoot -Directory (Join-Path $repositoryRoot 'build/_work')) -and
        [System.IO.Path]::GetFileName($testRoot) -match '^publish-release-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
