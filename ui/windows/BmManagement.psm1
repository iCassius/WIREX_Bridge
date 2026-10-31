#requires -Version 5.1
Set-StrictMode -Version Latest

$script:BmManagementApiOrigin = 'https://api.brandmeister.network'
$script:BmManagementApiPrefix = '/v2/device/'
$script:BmManagementMaxResponseBytes = 1048576
$script:BmManagementDefaultTimeoutMs = 3000
$script:BmManagementMaxTimeoutMs = 10000

function Set-BmManagementApiKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ref]$ApiKeyValue,
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath
    )

    $hasApiKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
    $hasFilePath = -not [string]::IsNullOrWhiteSpace($ApiKeyFilePath)
    if ($hasApiKey -eq $hasFilePath) {
        throw [System.ArgumentException]::new('必须且只能提供一个 BM API key 来源。')
    }

    if ($hasApiKey) {
        $candidate = $ApiKey.Trim()
    } else {
        if (-not [System.IO.Path]::IsPathRooted($ApiKeyFilePath)) {
            throw [System.ArgumentException]::new('BM API 文件必须使用完整路径。')
        }
        if (-not (Test-Path -LiteralPath $ApiKeyFilePath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new('找不到 BM API 文件。')
        }

        try {
            $content = [System.IO.File]::ReadAllText($ApiKeyFilePath, [System.Text.Encoding]::UTF8)
        } catch {
            throw [System.InvalidOperationException]::new('无法读取已指定的 BM API 文件。')
        }

        $candidate = $content.Trim()
        # Retain the old file format only for migration and compatibility.
        if ($candidate -match '(?im)^\s*apikey\s*=\s*(\S+)\s*$') {
            $candidate = $Matches[1]
        }
    }
    if ($candidate.Length -lt 200 -or $candidate -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
        throw [System.InvalidOperationException]::new('BM API key 格式无效；需要 BrandMeister API v2 token。')
    }
    $ApiKeyValue.Value = $candidate
}

function Test-BmManagementCancellation {
    param([Parameter(Mandatory = $true)][System.Threading.CancellationToken]$CancellationToken)
    if ($CancellationToken.IsCancellationRequested) {
        throw [System.OperationCanceledException]::new('BM API 操作已取消。')
    }
}

function Invoke-BmManagementRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateSet('profile', 'talkgroup')][string]$Resource,
        [Parameter()][AllowNull()][string]$ResourceSuffix = '',
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath,
        [Parameter()][AllowNull()][string]$Body,
        [Parameter()][ValidateRange(1, 10000)][int]$TimeoutMs = $script:BmManagementDefaultTimeoutMs,
        [Parameter()][System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [Parameter()][scriptblock]$Transport
    )

    Test-BmManagementCancellation -CancellationToken $CancellationToken
    if ($DeviceId -notmatch '^[0-9]{1,10}$') {
        throw [System.ArgumentException]::new('BM 设备 ID 必须是 1 到 4294967295 的十进制整数。')
    }
    $deviceNumber = [uint64]0
    if (-not [uint64]::TryParse($DeviceId, [ref]$deviceNumber) -or $deviceNumber -lt 1 -or $deviceNumber -gt 4294967295) {
        throw [System.ArgumentException]::new('BM 设备 ID 必须是 1 到 4294967295 的十进制整数。')
    }
    if ($ResourceSuffix -and ($ResourceSuffix -notmatch '^/[0-9]+/[0-9]+$' -or $Resource -cne 'talkgroup' -or $Method -cne 'DELETE')) {
        throw [System.ArgumentException]::new('BM API 路径参数无效。')
    }

    $uriText = '{0}{1}{2}/{3}{4}' -f $script:BmManagementApiOrigin, $script:BmManagementApiPrefix,
        [System.Uri]::EscapeDataString($DeviceId), $Resource, $ResourceSuffix
    $uri = [System.Uri]$uriText
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'api.brandmeister.network' -or $uri.Port -ne 443) {
        throw [System.InvalidOperationException]::new('BM API 只允许使用官方 HTTPS 服务地址。')
    }

    $resolvedApiKey = ''
    Set-BmManagementApiKey -ApiKeyValue ([ref]$resolvedApiKey) -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath
    $request = $null
    $response = $null
    $handler = $null
    $client = $null
    $timeoutSource = $null
    $httpRequest = $null
    $httpResponse = $null
    try {
        Test-BmManagementCancellation -CancellationToken $CancellationToken
        $request = [pscustomobject][ordered]@{
            method = $Method
            uri = $uri.AbsoluteUri
            headers = [pscustomobject][ordered]@{
                Authorization = 'Bearer ' + $resolvedApiKey
                Accept = 'application/json'
                ContentType = if ($Method -ceq 'POST') { 'application/json; charset=utf-8' } else { '' }
            }
            body = if ($Method -ceq 'POST') { [string]$Body } else { '' }
            timeout_ms = [int]$TimeoutMs
            cancellation_token = $CancellationToken
        }

        if ($Transport) {
            try {
                $response = & $Transport $request
            } catch [System.OperationCanceledException] {
                throw [System.OperationCanceledException]::new('BM API 操作已取消。')
            } catch [System.TimeoutException] {
                throw [System.TimeoutException]::new('BM API 操作超过时限。')
            } catch {
                throw [System.InvalidOperationException]::new('BM API fake transport 调用失败。')
            }
            if ($null -eq $response -or $null -eq $response.PSObject.Properties['status_code']) {
                throw [System.InvalidOperationException]::new('BM API transport 没有返回 HTTP 状态。')
            }
            $statusCode = [int]$response.status_code
            $responseBody = if ($null -ne $response.PSObject.Properties['body']) { [string]$response.body } else { '' }
        } else {
            try {
                Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
                $handler = New-Object System.Net.Http.HttpClientHandler
                $handler.AllowAutoRedirect = $false
                $client = [System.Net.Http.HttpClient]::new($handler)
                $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
                $timeoutSource = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
                $timeoutSource.CancelAfter($TimeoutMs)
                $httpRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $uri)
                $httpRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $resolvedApiKey)
                [void]$httpRequest.Headers.Accept.ParseAdd('application/json')
                if ($Method -ceq 'POST') {
                    $httpRequest.Content = [System.Net.Http.StringContent]::new([string]$Body, [System.Text.Encoding]::UTF8, 'application/json')
                }
                $httpResponse = $client.SendAsync(
                    $httpRequest,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $timeoutSource.Token
                ).GetAwaiter().GetResult()
                $statusCode = [int]$httpResponse.StatusCode
                $responseBody = ''
                if ($Method -ceq 'GET' -and $statusCode -ge 200 -and $statusCode -lt 300) {
                    if ($httpResponse.Content.Headers.ContentLength -gt $script:BmManagementMaxResponseBytes) {
                        throw [System.InvalidOperationException]::new('BM API 返回内容超过大小上限。')
                    }
                    $stream = $httpResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $memory = New-Object System.IO.MemoryStream
                    $buffer = New-Object byte[] 8192
                    while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length, $timeoutSource.Token).GetAwaiter().GetResult()) -gt 0) {
                        Test-BmManagementCancellation -CancellationToken $CancellationToken
                        if ($memory.Length + $read -gt $script:BmManagementMaxResponseBytes) {
                            throw [System.InvalidOperationException]::new('BM API 返回内容超过大小上限。')
                        }
                        $memory.Write($buffer, 0, $read)
                    }
                    $responseBody = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($memory.ToArray())
                    $memory.Dispose()
                    $stream.Dispose()
                }
            } catch [System.OperationCanceledException] {
                if ($CancellationToken.IsCancellationRequested) {
                    throw [System.OperationCanceledException]::new('BM API 操作已取消。')
                }
                throw [System.TimeoutException]::new('BM API 操作超过时限。')
            } catch [System.TimeoutException] {
                throw [System.TimeoutException]::new('BM API 操作超过时限。')
            } catch [System.InvalidOperationException] {
                throw
            } catch {
                throw [System.InvalidOperationException]::new('BM API 请求失败；没有保存或显示 API token。')
            } finally {
                if ($httpResponse) { $httpResponse.Dispose() }
                if ($httpRequest) { $httpRequest.Dispose() }
                if ($client) { $client.Dispose() }
                if ($handler) { $handler.Dispose() }
                if ($timeoutSource) { $timeoutSource.Dispose() }
            }
        }

        Test-BmManagementCancellation -CancellationToken $CancellationToken
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw [System.InvalidOperationException]::new(('BM API 返回 HTTP {0}。' -f $statusCode))
        }
        if ($Method -ceq 'GET' -and [System.Text.Encoding]::UTF8.GetByteCount([string]$responseBody) -gt $script:BmManagementMaxResponseBytes) {
            throw [System.InvalidOperationException]::new('BM API 返回内容超过大小上限。')
        }
        return [pscustomobject][ordered]@{ status_code = $statusCode; body = $responseBody }
    } finally {
        $resolvedApiKey = $null
        if ($request -and $request.headers) { $request.headers.Authorization = '' }
    }
}

function ConvertFrom-BmStaticSubscriptionProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$DeviceId
    )

    try { $profile = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { throw [System.InvalidOperationException]::new('BM API 返回的静态组资料不是有效 JSON。') }
    if ($null -eq $profile -or $null -eq $profile.PSObject.Properties['staticSubscriptions'] -or
        $profile.staticSubscriptions -isnot [System.Array]) {
        throw [System.InvalidOperationException]::new('BM API 返回的资料缺少静态组列表。')
    }

    $groups = @()
    $seen = @{}
    foreach ($item in @($profile.staticSubscriptions)) {
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['talkgroup'] -or
            $null -eq $item.PSObject.Properties['slot']) {
            throw [System.InvalidOperationException]::new('BM API 静态组项目缺少 TG 或时隙。')
        }
        $tg = [uint64]0
        $slot = [int]0
        $tgText = [string]$item.talkgroup
        $slotText = [string]$item.slot
        if ($tgText -notmatch '^[0-9]{1,8}$' -or -not [uint64]::TryParse($tgText, [ref]$tg) -or $tg -lt 1 -or $tg -gt 16777215 -or
            $slotText -notmatch '^[0-2]$' -or -not [int]::TryParse($slotText, [ref]$slot)) {
            throw [System.InvalidOperationException]::new('BM API 静态组项目含有无效 TG 或时隙。')
        }
        $key = '{0}/{1}' -f $tg, $slot
        if ($seen.ContainsKey($key)) { throw [System.InvalidOperationException]::new('BM API 静态组列表含有重复项目。') }
        $seen[$key] = $true
        $groups += [pscustomobject][ordered]@{
            device_id = [string]$DeviceId
            talkgroup = [uint64]$tg
            slot = [int]$slot
            type = 'static'
        }
    }
    return $groups
}

function Get-BmStaticGroups {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [Parameter()][ValidateRange(1, 10000)][int]$TimeoutMs = $script:BmManagementDefaultTimeoutMs,
        [Parameter()][System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [Parameter()][scriptblock]$Transport
    )

    $response = Invoke-BmManagementRequest -Method GET -DeviceId $DeviceId -Resource profile `
        -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath -TimeoutMs $TimeoutMs -CancellationToken $CancellationToken -Transport $Transport
    $groups = @(ConvertFrom-BmStaticSubscriptionProfile -Json $response.body -DeviceId $DeviceId)
    return [pscustomobject][ordered]@{
        operation = 'get_static_groups'
        device_id = [string]$DeviceId
        success = $true
        groups = $groups
        retrieved_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Add-BmStaticGroup {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 16777215)][uint64]$Talkgroup,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Slot,
        [Parameter()][ValidateRange(1, 10000)][int]$TimeoutMs = $script:BmManagementDefaultTimeoutMs,
        [Parameter()][System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [Parameter()][scriptblock]$Transport
    )

    $body = ConvertTo-Json -InputObject ([ordered]@{ slot = $Slot; group = $Talkgroup }) -Compress
    [void](Invoke-BmManagementRequest -Method POST -DeviceId $DeviceId -Resource talkgroup `
        -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath -Body $body -TimeoutMs $TimeoutMs -CancellationToken $CancellationToken -Transport $Transport)
    return Complete-BmStaticGroupWrite -Operation add_static_group -DeviceId $DeviceId -Talkgroup $Talkgroup `
        -Slot $Slot -ExpectedPresent $true -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath -TimeoutMs $TimeoutMs `
        -CancellationToken $CancellationToken -Transport $Transport
}

function Remove-BmStaticGroup {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 16777215)][uint64]$Talkgroup,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2)][int]$Slot,
        [Parameter()][ValidateRange(1, 10000)][int]$TimeoutMs = $script:BmManagementDefaultTimeoutMs,
        [Parameter()][System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [Parameter()][scriptblock]$Transport
    )

    [void](Invoke-BmManagementRequest -Method DELETE -DeviceId $DeviceId -Resource talkgroup `
        -ResourceSuffix ('/{0}/{1}' -f $Slot, $Talkgroup) -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath `
        -TimeoutMs $TimeoutMs -CancellationToken $CancellationToken -Transport $Transport)
    return Complete-BmStaticGroupWrite -Operation remove_static_group -DeviceId $DeviceId -Talkgroup $Talkgroup `
        -Slot $Slot -ExpectedPresent $false -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath -TimeoutMs $TimeoutMs `
        -CancellationToken $CancellationToken -Transport $Transport
}

function Complete-BmStaticGroupWrite {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][uint64]$Talkgroup,
        [Parameter(Mandatory = $true)][int]$Slot,
        [Parameter(Mandatory = $true)][bool]$ExpectedPresent,
        [Parameter()][AllowEmptyString()][string]$ApiKey,
        [Parameter()][AllowEmptyString()][string]$ApiKeyFilePath,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][System.Threading.CancellationToken]$CancellationToken,
        [Parameter()][scriptblock]$Transport
    )

    $readbackStatus = 'unavailable'
    $groups = @()
    $readbackError = ''
    try {
        $readback = Get-BmStaticGroups -ApiKey $ApiKey -ApiKeyFilePath $ApiKeyFilePath -DeviceId $DeviceId `
            -TimeoutMs $TimeoutMs -CancellationToken $CancellationToken -Transport $Transport
        $groups = @($readback.groups)
        $present = @($groups | Where-Object { [uint64]$_.talkgroup -eq $Talkgroup -and [int]$_.slot -eq $Slot }).Count -gt 0
        if ($present -eq $ExpectedPresent) { $readbackStatus = 'confirmed' } else { $readbackStatus = 'not_confirmed' }
    } catch [System.OperationCanceledException] {
        $readbackStatus = 'canceled'
        $readbackError = 'canceled'
    } catch [System.TimeoutException] {
        $readbackStatus = 'unavailable'
        $readbackError = 'timeout'
    } catch {
        $readbackStatus = 'unavailable'
        $readbackError = 'unavailable'
    }

    return [pscustomobject][ordered]@{
        operation = $Operation
        device_id = [string]$DeviceId
        talkgroup = [uint64]$Talkgroup
        slot = [int]$Slot
        write_accepted = $true
        readback_status = $readbackStatus
        readback_error = $readbackError
        groups = $groups
    }
}

Export-ModuleMember -Function Get-BmStaticGroups, Add-BmStaticGroup, Remove-BmStaticGroup
