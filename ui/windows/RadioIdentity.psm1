Set-StrictMode -Version 2.0

$script:RadioIdentitySource = 'RadioID.net'
$script:RadioIdentityUserAgent = 'WIREX Bridge/0.1 (contact: https://github.com/iCassius)'
$script:RadioIdentityMaxId = 16777215
$script:RadioIdentityMaxResponseBytes = 262144
# Local cache policy only; these TTLs are not specified by RadioID.
$script:RadioIdentityPositiveTtl = [TimeSpan]::FromDays(30)
$script:RadioIdentityNegativeTtl = [TimeSpan]::FromDays(1)
# Keep interactive lookups bounded; this is not a local mirror or bulk database.
$script:RadioIdentityCacheEntryLimit = 128

function Test-RadioIdentityId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$RadioId)

    $parsed = [uint32]0
    if (-not [uint32]::TryParse([string]$RadioId, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $false
    }
    return $parsed -ge 1 -and $parsed -le $script:RadioIdentityMaxId
}

function Assert-RadioIdentityId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$RadioId)

    if (-not (Test-RadioIdentityId -RadioId $RadioId)) {
        throw [ArgumentOutOfRangeException]::new('RadioId', 'RadioId 必须是 1 到 16777215 之间的 24 位 DMR ID。')
    }
}

function Get-RadioIdentityCachePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$UserConfigDirectory)

    return [IO.Path]::Combine($UserConfigDirectory, 'radio-identity-cache.json')
}

function Get-RadioIdentityProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-RadioIdentityText {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value -replace '[\x00-\x1F\x7F]', '').Trim()
    if ($text.Length -eq 0) { return $null }
    if ($text.Length -gt 128) { $text = $text.Substring(0, 128) }
    return $text
}

function ConvertTo-RadioIdentityTimestamp {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        $dateTimeOffset = [DateTimeOffset]::new([DateTime]$Value)
        return $dateTimeOffset.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) {
        return $null
    }
    return $timestamp.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function New-RadioIdentityResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$RadioId,
        [Parameter()][AllowNull()][object]$Record,
        [Parameter(Mandatory = $true)][ValidateSet('found', 'not_found', 'stale', 'unavailable')][string]$Status,
        [Parameter()][AllowNull()][string]$FetchedAtUtc,
        [Parameter()][AllowNull()][string]$Source = $script:RadioIdentitySource,
        [Parameter()][bool]$CacheSaved = $true
    )

    $callsign = $null
    $name = $null
    $city = $null
    $state = $null
    $country = $null
    if ($null -ne $Record) {
        $callsign = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'callsign')
        $name = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $first = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'fname')
            $last = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'surname')
            if ($first -and $last) { $name = "$first $last" }
            elseif ($first) { $name = $first }
            elseif ($last) { $name = $last }
        }
        $city = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'city')
        $state = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'state')
        $country = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $Record -Name 'country')
    }

    $displayName = "DMR ID $RadioId"
    if ($Status -eq 'found' -and $callsign) {
        $displayName = $callsign
        if ($name) { $displayName = "$callsign ($name)" }
    } elseif ($Status -eq 'found' -and $name) {
        $displayName = $name
    }

    return [pscustomobject][ordered]@{
        id = [uint32]$RadioId
        source_id = [uint32]$RadioId
        callsign = $callsign
        name = $name
        city = $city
        state = $state
        country = $country
        source = $Source
        fetched_at_utc = $FetchedAtUtc
        status = $Status
        display_name = $displayName
        cache_saved = $CacheSaved
    }
}

function Read-RadioIdentityCache {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CachePath)

    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return @() }
    try {
        $cacheFile = Get-Item -LiteralPath $CachePath -ErrorAction Stop
        if ($cacheFile.Length -gt 1048576) { return @() }
        $json = [IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8)
        $document = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ([int]$document.schema_version -ne 1 -or $null -eq $document.entries) { return @() }
        return @($document.entries)
    } catch {
        return @()
    }
}

function Find-RadioIdentityCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][uint32]$RadioId
    )

    foreach ($entry in @(Read-RadioIdentityCache -CachePath $CachePath)) {
        if ($null -eq $entry) { continue }
        $entryId = [uint32]0
        if ([uint32]::TryParse([string](Get-RadioIdentityProperty -InputObject $entry -Name 'id'),
                [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$entryId) -and
            $entryId -eq $RadioId) {
            return $entry
        }
    }
    return $null
}

function Get-RadioIdentityCacheFreshness {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entry)

    $status = [string](Get-RadioIdentityProperty -InputObject $Entry -Name 'status')
    if ($status -notin @('found', 'not_found')) { return $false }
    $fetchedText = ConvertTo-RadioIdentityTimestamp (Get-RadioIdentityProperty -InputObject $Entry -Name 'fetched_at_utc')
    if ([string]::IsNullOrWhiteSpace($fetchedText)) { return $false }
    $fetched = [DateTimeOffset]::Parse($fetchedText, [Globalization.CultureInfo]::InvariantCulture)
    if ($fetched -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $false }
    $ttl = if ($status -eq 'not_found') { $script:RadioIdentityNegativeTtl } else { $script:RadioIdentityPositiveTtl }
    return (([DateTimeOffset]::UtcNow - $fetched) -lt $ttl)
}

function ConvertFrom-RadioIdentityCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$RadioId,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][ValidateSet('found', 'not_found', 'stale')][string]$Status
    )

    $record = [pscustomobject][ordered]@{
        callsign = Get-RadioIdentityProperty -InputObject $Entry -Name 'callsign'
        name = Get-RadioIdentityProperty -InputObject $Entry -Name 'name'
        city = Get-RadioIdentityProperty -InputObject $Entry -Name 'city'
        state = Get-RadioIdentityProperty -InputObject $Entry -Name 'state'
        country = Get-RadioIdentityProperty -InputObject $Entry -Name 'country'
    }
    $fetched = ConvertTo-RadioIdentityTimestamp (Get-RadioIdentityProperty -InputObject $Entry -Name 'fetched_at_utc')
    return New-RadioIdentityResult -RadioId $RadioId -Record $record -Status $Status `
        -FetchedAtUtc $fetched -Source ([string](Get-RadioIdentityProperty -InputObject $Entry -Name 'source'))
}

function Resolve-RadioIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$RadioId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CachePath
    )

    Assert-RadioIdentityId -RadioId $RadioId
    $entry = Find-RadioIdentityCacheEntry -CachePath $CachePath -RadioId $RadioId
    if ($null -eq $entry) {
        return New-RadioIdentityResult -RadioId $RadioId -Record $null -Status unavailable `
            -FetchedAtUtc $null -Source $null
    }
    $cachedStatus = [string](Get-RadioIdentityProperty -InputObject $entry -Name 'status')
    if ($cachedStatus -notin @('found', 'not_found')) {
        return New-RadioIdentityResult -RadioId $RadioId -Record $null -Status unavailable `
            -FetchedAtUtc $null -Source $null
    }
    $status = if (Get-RadioIdentityCacheFreshness -Entry $entry) { $cachedStatus } else { 'stale' }
    return ConvertFrom-RadioIdentityCacheEntry -RadioId $RadioId -Entry $entry -Status $status
}

function Save-RadioIdentityCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    $fullPath = [IO.Path]::GetFullPath($CachePath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw 'CachePath 必须包含父目录。' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $allEntries = New-Object 'System.Collections.Generic.List[object]'
    $entryId = [uint32]$Entry.id
    foreach ($current in @(Read-RadioIdentityCache -CachePath $fullPath)) {
        if ($null -eq $current) { continue }
        $currentId = [uint32]0
        if (-not [uint32]::TryParse([string](Get-RadioIdentityProperty -InputObject $current -Name 'id'),
                [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$currentId)) { continue }
        if ($currentId -eq $entryId) { continue }
        $allEntries.Add($current)
    }
    $allEntries.Insert(0, $Entry)
    $retained = @($allEntries | Select-Object -First $script:RadioIdentityCacheEntryLimit)
    $document = [pscustomobject][ordered]@{ schema_version = 1; entries = $retained }
    $json = ConvertTo-Json -InputObject $document -Depth 8
    $tempPath = Join-Path $directory ('.radio-identity-cache-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $directory ('.radio-identity-cache-' + [guid]::NewGuid().ToString('N') + '.bak')
    $encoding = New-Object System.Text.UTF8Encoding($true)
    try {
        [IO.File]::WriteAllText($tempPath, $json, $encoding)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Replace($tempPath, $fullPath, $backupPath)
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        } else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RadioIdentityHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Request)

    $webRequest = [Net.HttpWebRequest][Net.WebRequest]::Create([string]$Request.uri)
    $webRequest.Method = 'GET'
    $webRequest.Accept = 'application/json'
    $webRequest.UserAgent = [string]$Request.user_agent
    $webRequest.Timeout = [int]$Request.timeout_milliseconds
    $webRequest.ReadWriteTimeout = [int]$Request.timeout_milliseconds
    $webRequest.AllowAutoRedirect = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $responseTask = $null
    $readTask = $null
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $responseTask = $webRequest.GetResponseAsync()
        while (-not $responseTask.IsCompleted) {
            if ($PSCmdlet.Stopping) {
                $webRequest.Abort()
                throw [OperationCanceledException]::new('RadioID 查询已取消。')
            }
            $remaining = [int]$Request.timeout_milliseconds - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                $webRequest.Abort()
                $abortClock = [Diagnostics.Stopwatch]::StartNew()
                while (-not $responseTask.IsCompleted -and $abortClock.ElapsedMilliseconds -lt 250) {
                    Start-Sleep -Milliseconds 25
                }
                throw 'RadioID 查询超过时间限制。'
            }
            Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
        }
        if ($clock.ElapsedMilliseconds -gt [int]$Request.timeout_milliseconds) {
            throw 'RadioID 查询超过时间限制。'
        }
        try {
            $response = [Net.HttpWebResponse]$responseTask.GetAwaiter().GetResult()
        } catch {
            $caught = $_.Exception
            $webException = $null
            while ($null -ne $caught) {
                if ($caught -is [Net.WebException]) {
                    $webException = $caught
                    break
                }
                $caught = $caught.InnerException
            }
            if ($null -ne $webException -and $null -ne $webException.Response) {
                $response = [Net.HttpWebResponse]$webException.Response
            } else {
                throw
            }
        }
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) {
            return [pscustomobject]@{ status_code = $statusCode; body = '' }
        }
        if ($response.ContentLength -gt [long]$Request.max_response_bytes) {
            throw 'RadioID 响应超过大小限制。'
        }
        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { throw 'RadioID 响应没有可读取的正文。' }
        $memory = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 8192
        while ($true) {
            if ($PSCmdlet.Stopping) {
                $webRequest.Abort()
                throw [OperationCanceledException]::new('RadioID 查询已取消。')
            }
            $remaining = [int]$Request.timeout_milliseconds - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'RadioID 响应超过时间限制。' }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
            while (-not $readTask.IsCompleted) {
                if ($PSCmdlet.Stopping) {
                    $webRequest.Abort()
                    throw [OperationCanceledException]::new('RadioID 查询已取消。')
                }
                $remaining = [int]$Request.timeout_milliseconds - [int]$clock.ElapsedMilliseconds
                if ($remaining -le 0) {
                    $webRequest.Abort()
                    throw 'RadioID 响应超过时间限制。'
                }
                [Threading.Thread]::Sleep([Math]::Min(100, $remaining))
            }
            if ($clock.ElapsedMilliseconds -gt [int]$Request.timeout_milliseconds) {
                throw 'RadioID 响应超过时间限制。'
            }
            $count = [int]$readTask.GetAwaiter().GetResult()
            $readTask = $null
            if ($count -le 0) { break }
            if ($memory.Length + $count -gt [long]$Request.max_response_bytes) {
                throw 'RadioID 响应超过大小限制。'
            }
            $memory.Write($buffer, 0, $count)
        }
        $encoding = [Text.Encoding]::UTF8
        if (-not [string]::IsNullOrWhiteSpace($response.CharacterSet)) {
            try { $encoding = [Text.Encoding]::GetEncoding($response.CharacterSet) } catch { }
        }
        return [pscustomobject]@{ status_code = $statusCode; body = $encoding.GetString($memory.ToArray()) }
    } finally {
        $webRequest.Abort()
        if (($null -ne $responseTask -and -not $responseTask.IsCompleted) -or
            ($null -ne $readTask -and -not $readTask.IsCompleted)) {
            $abortClock = [Diagnostics.Stopwatch]::StartNew()
            while (((($null -ne $responseTask) -and -not $responseTask.IsCompleted) -or
                    (($null -ne $readTask) -and -not $readTask.IsCompleted)) -and $abortClock.ElapsedMilliseconds -lt 250) {
                [Threading.Thread]::Sleep(25)
            }
        }
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function ConvertFrom-RadioIdentityResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][uint32]$RequestedId
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Body) -gt $script:RadioIdentityMaxResponseBytes) {
        return [pscustomobject]@{ state = 'invalid'; record = $null }
    }
    try {
        $root = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ state = 'invalid'; record = $null }
    }

    $records = @()
    if ($null -eq $root) {
        return [pscustomobject]@{ state = 'invalid'; record = $null }
    } elseif ($root -is [array]) {
        $records = @($root)
    } elseif ($null -ne $root.PSObject.Properties['results']) {
        $results = $root.PSObject.Properties['results'].Value
        if ($null -eq $results) { $records = @() }
        elseif ($results -is [array]) { $records = @($results) }
        else { return [pscustomobject]@{ state = 'invalid'; record = $null } }
    } elseif ($null -ne $root.PSObject.Properties['id'] -or $null -ne $root.PSObject.Properties['radio_id']) {
        $records = @($root)
    } else {
        return [pscustomobject]@{ state = 'invalid'; record = $null }
    }

    if ($records.Count -eq 0) { return [pscustomobject]@{ state = 'not_found'; record = $null } }
    $exact = New-Object 'System.Collections.Generic.List[object]'
    $validIdCount = 0
    foreach ($candidate in $records) {
        if ($null -eq $candidate) { continue }
        $rawId = Get-RadioIdentityProperty -InputObject $candidate -Name 'id'
        if ($null -eq $rawId) { $rawId = Get-RadioIdentityProperty -InputObject $candidate -Name 'radio_id' }
        $candidateId = [uint32]0
        if (-not [uint32]::TryParse([string]$rawId, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$candidateId)) { continue }
        $validIdCount++
        if ($candidateId -eq $RequestedId) { $exact.Add($candidate) }
    }
    if ($exact.Count -eq 0) {
        $state = if ($validIdCount -gt 0) { 'mismatch' } else { 'invalid' }
        return [pscustomobject]@{ state = $state; record = $null }
    }

    $normalized = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $exact) {
        $record = [pscustomobject][ordered]@{
            callsign = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'callsign')
            name = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'name')
            fname = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'fname')
            surname = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'surname')
            city = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'city')
            state = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'state')
            country = ConvertTo-RadioIdentityText (Get-RadioIdentityProperty -InputObject $candidate -Name 'country')
        }
        if ([string]::IsNullOrWhiteSpace($record.name)) {
            if ($record.fname -and $record.surname) { $record.name = "$($record.fname) $($record.surname)" }
            elseif ($record.fname) { $record.name = $record.fname }
            elseif ($record.surname) { $record.name = $record.surname }
        }
        $normalized.Add($record)
    }

    $selected = $normalized[0]
    foreach ($candidate in $normalized | Select-Object -Skip 1) {
        foreach ($field in @('callsign', 'name', 'city', 'state', 'country')) {
            if ([string]$candidate.$field -cne [string]$selected.$field) {
                return [pscustomobject]@{ state = 'conflict'; record = $null }
            }
        }
    }
    return [pscustomobject]@{ state = 'found'; record = $selected }
}

function Get-RadioIdentityFallbackResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$RadioId,
        [Parameter(Mandatory = $true)][string]$CachePath
    )

    $entry = Find-RadioIdentityCacheEntry -CachePath $CachePath -RadioId $RadioId
    if ($null -ne $entry) {
        return ConvertFrom-RadioIdentityCacheEntry -RadioId $RadioId -Entry $entry -Status stale
    }
    return New-RadioIdentityResult -RadioId $RadioId -Record $null -Status unavailable `
        -FetchedAtUtc $null -Source $script:RadioIdentitySource
}

# Call only from an explicit user refresh action. Transport injection is for offline tests.
function Invoke-RadioIdentityQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$RadioId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CachePath,
        [Parameter()][ValidateRange(1, 5)][int]$TimeoutSec = 5,
        [Parameter()][scriptblock]$Transport,
        [Parameter()][ValidateNotNullOrEmpty()][string]$UserAgent = $script:RadioIdentityUserAgent
    )

    Assert-RadioIdentityId -RadioId $RadioId
    if ($UserAgent -notmatch '(?i)WIREX\s+Bridge' -or $UserAgent -notmatch '(?i)contact\s*:') {
        throw 'User-Agent 必须标识 WIREX Bridge 并包含联系地址。'
    }
    $escapedId = [Uri]::EscapeDataString([string]$RadioId)
    $uri = "https://radioid.net/api/dmr/user/?id=$escapedId&id_sel=%3D"
    $request = [pscustomobject][ordered]@{
        method = 'GET'
        uri = $uri
        timeout_seconds = $TimeoutSec
        timeout_milliseconds = [int]($TimeoutSec * 1000)
        max_response_bytes = $script:RadioIdentityMaxResponseBytes
        user_agent = $UserAgent.Trim()
        accept = 'application/json'
    }

    try {
        if ($null -ne $Transport) { $response = & $Transport $request }
        else { $response = Invoke-RadioIdentityHttpRequest -Request $request }
        if ($null -eq $response) { throw 'RadioID 查询没有返回响应。' }
        $statusCode = [int](Get-RadioIdentityProperty -InputObject $response -Name 'status_code')
        $body = Get-RadioIdentityProperty -InputObject $response -Name 'body'
        if ($body -is [byte[]]) { $body = [Text.Encoding]::UTF8.GetString($body) }
        if ($body -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount([string]$body) -gt $script:RadioIdentityMaxResponseBytes) {
            throw 'RadioID 响应缺失或超过大小限制。'
        }
        if ($statusCode -ne 200) { throw "RadioID 查询返回 HTTP 状态 $statusCode。" }

        $parsed = ConvertFrom-RadioIdentityResponse -Body $body -RequestedId $RadioId
        if ($parsed.state -eq 'not_found') {
            $fetchedAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $entry = [pscustomobject][ordered]@{
                id = [uint32]$RadioId; callsign = $null; name = $null; city = $null; state = $null; country = $null
                source = $script:RadioIdentitySource; fetched_at_utc = $fetchedAt; status = 'not_found'
            }
            try { Save-RadioIdentityCacheEntry -CachePath $CachePath -Entry $entry }
            catch { return New-RadioIdentityResult -RadioId $RadioId -Record $null -Status not_found -FetchedAtUtc $fetchedAt -CacheSaved $false }
            return New-RadioIdentityResult -RadioId $RadioId -Record $entry -Status not_found -FetchedAtUtc $fetchedAt
        }
        if ($parsed.state -ne 'found') { throw "RadioID 查询结果不唯一或 ID 不匹配（$($parsed.state)）。" }

        $fetchedAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $entry = [pscustomobject][ordered]@{
            id = [uint32]$RadioId; callsign = $parsed.record.callsign; name = $parsed.record.name
            city = $parsed.record.city; state = $parsed.record.state; country = $parsed.record.country
            source = $script:RadioIdentitySource; fetched_at_utc = $fetchedAt; status = 'found'
        }
        try { Save-RadioIdentityCacheEntry -CachePath $CachePath -Entry $entry }
        catch { return New-RadioIdentityResult -RadioId $RadioId -Record $entry -Status found -FetchedAtUtc $fetchedAt -CacheSaved $false }
        return New-RadioIdentityResult -RadioId $RadioId -Record $entry -Status found -FetchedAtUtc $fetchedAt
    } catch {
        return Get-RadioIdentityFallbackResult -RadioId $RadioId -CachePath $CachePath
    }
}

Export-ModuleMember -Function Get-RadioIdentityCachePath, Resolve-RadioIdentity, Invoke-RadioIdentityQuery
