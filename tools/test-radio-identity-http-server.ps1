[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('ok', 'not_found', 'invalid_callsign', 'status', 'oversized', 'oversized_chunked', 'delay_headers', 'delay_headers_timeout', 'slow_body')][string]$Mode,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ReadyFile,
    [Parameter()][string]$RequestRecordFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-FakeHttpResponse {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][byte[]]$Body
    )

    $headerText = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$client = $null
$stream = $null
$requestBytes = $null
$accepted = $false
try {
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    [IO.File]::WriteAllText($ReadyFile, [string]$port, [Text.Encoding]::ASCII)
    $acceptClock = [Diagnostics.Stopwatch]::StartNew()
    while (-not $listener.Pending() -and $acceptClock.ElapsedMilliseconds -lt 8000) {
        [Threading.Thread]::Sleep(25)
    }
    if (-not $listener.Pending()) { throw 'Local HTTP fixture timed out waiting for its single client.' }
    $client = $listener.AcceptTcpClient()
    $accepted = $true
    $stream = $client.GetStream()
    $stream.ReadTimeout = 2000
    $stream.WriteTimeout = 2000

    $requestBytes = New-Object IO.MemoryStream
    $oneByte = New-Object byte[] 1
    while ($requestBytes.Length -lt 16384) {
        $read = $stream.Read($oneByte, 0, 1)
        if ($read -le 0) { throw [IO.IOException]::new('Client closed before sending HTTP headers.') }
        $requestBytes.Write($oneByte, 0, $read)
        $header = $requestBytes.ToArray()
        $length = $header.Length
        if ($length -ge 4 -and $header[$length - 4] -eq 13 -and $header[$length - 3] -eq 10 -and
            $header[$length - 2] -eq 13 -and $header[$length - 1] -eq 10) { break }
    }
    $requestBytes.Dispose()
    $requestBytes = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestRecordFile)) {
        [IO.File]::WriteAllText($RequestRecordFile,[Text.Encoding]::ASCII.GetString($header),[Text.Encoding]::ASCII)
    }

    switch ($Mode) {
        'ok' {
            $body = [Text.Encoding]::UTF8.GetBytes('{"results":[{"id":7654321,"callsign":"N0TEST"}]}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'not_found' {
            $body = [Text.Encoding]::UTF8.GetBytes('{"results":[]}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'invalid_callsign' {
            $body = [Text.Encoding]::UTF8.GetBytes('{"results":[{"id":7654321,"callsign":"NO CALL"}]}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'status' {
            $body = [Text.Encoding]::UTF8.GetBytes('{"error":true}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 503 -Reason 'Service Unavailable' -Body $body
        }
        'oversized' {
            $body = [Text.Encoding]::UTF8.GetBytes('1234567890123456789012345678901234567890')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'oversized_chunked' {
            $body = [Text.Encoding]::ASCII.GetBytes('1234567890123456789012345678901234567890')
            $headerText = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n"
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
            $chunkPrefix = [Text.Encoding]::ASCII.GetBytes(('{0:X}`r`n' -f $body.Length))
            $chunkSuffix = [Text.Encoding]::ASCII.GetBytes("`r`n0`r`n`r`n")
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($chunkPrefix, 0, $chunkPrefix.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Write($chunkSuffix, 0, $chunkSuffix.Length)
            $stream.Flush()
        }
        'delay_headers' {
            Start-Sleep -Milliseconds 700
            $body = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'delay_headers_timeout' {
            Start-Sleep -Milliseconds 6500
            $body = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            Write-FakeHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body $body
        }
        'slow_body' {
            $body = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            $headerText = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($body, 0, 1)
            $stream.Flush()
            Start-Sleep -Milliseconds 700
            $stream.Write($body, 1, $body.Length - 1)
            $stream.Flush()
        }
    }
} catch {
    if (-not $accepted) { throw }
    # A client timeout closes the socket while the delayed fixture is writing.
} finally {
    if ($null -ne $requestBytes) { $requestBytes.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $client) { $client.Close() }
    $listener.Stop()
}
