# Minimal loopback HTTP server. TcpListener needs no URL ACL or administrator rights.
# Requests are handled one at a time, so a shutdown can never interrupt a write.

function Read-HttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)

    $Client.ReceiveTimeout = 1000
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 1000
    $buffer = New-Object byte[] 8192
    $received = New-Object System.IO.MemoryStream
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) { return $null }
        $received.Write($buffer, 0, $count)
        if ($received.Length -gt 16384) { return $null }
        $headerEnd = ([Text.Encoding]::ASCII.GetString($received.ToArray())).IndexOf("`r`n`r`n")
    }

    $all = $received.ToArray()
    $lines = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd) -split "`r`n"
    $first = $lines[0] -split ' '
    if ($first.Count -lt 3) { return $null }

    $headers = @{}
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $separator = $line.IndexOf(':')
        if ($separator -gt 0) { $headers[$line.Substring(0, $separator).ToLowerInvariant()] = $line.Substring($separator + 1).Trim() }
    }

    $length = 0
    if ($headers['content-length'] -and -not [int]::TryParse($headers['content-length'], [ref]$length)) { return $null }
    if ($length -lt 0 -or $length -gt 65536) { return $null }

    $bodyStart = $headerEnd + 4
    while (($received.Length - $bodyStart) -lt $length) {
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) { return $null }
        $received.Write($buffer, 0, $count)
    }

    $all = $received.ToArray()
    $parts = $first[1] -split '\?', 2
    return @{
        Method  = $first[0]
        Path    = $parts[0]
        Query   = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
        Headers = $headers
        Body    = [Text.Encoding]::UTF8.GetString($all, $bodyStart, $length)
    }
}

function Write-HttpResponse {
    param([System.Net.Sockets.TcpClient]$Client, [int]$Status, [string]$ContentType, [string]$Content)

    $body = [Text.Encoding]::UTF8.GetBytes($Content)
    $head = @(
        "HTTP/1.1 $Status Status"
        "Content-Type: $ContentType; charset=utf-8"
        "Content-Length: $($body.Length)"
        'Cache-Control: no-store'
        'Referrer-Policy: no-referrer'
        'X-Content-Type-Options: nosniff'
        "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"
        'Connection: close'
    ) -join "`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes("$head`r`n`r`n")
    $stream = $Client.GetStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
}

function Test-RequestTrusted {
    param([hashtable]$Request, [int]$Port, [string]$Token)

    $authority = "127.0.0.1:$Port"
    if ($Request.Headers['host'] -cne $authority) { return $false }
    if ($Request.Headers['origin'] -and $Request.Headers['origin'] -cne "http://$authority") { return $false }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/') { return ($Request.Query -ceq "t=$Token") }
    return ($Request.Headers['x-token'] -ceq $Token)
}

function ConvertTo-JsonText {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 10 -Compress)
}

function Invoke-ApiRequest {
    param([hashtable]$Ports, [hashtable]$Request)

    $payload = $null
    if ($Request.Body) { $payload = ConvertFrom-Json -InputObject $Request.Body }

    switch ($Request.Path) {
        '/api/scan' { return Invoke-Scan -Ports $Ports }
        '/api/running' { return Get-RunningState -Ports $Ports }
        '/api/preview' { return Invoke-Preview -Ports $Ports -Request $payload }
        '/api/apply' { return Invoke-Apply -Ports $Ports -Request $payload }
        '/api/rollback' { return Invoke-Rollback -Ports $Ports -Request $payload }
        default { return New-UseCaseError -Status 404 -Code 'not_found' }
    }
}

function Start-ToolServer {
    param([hashtable]$Ports, [string]$Html, [int]$BeatTimeoutSeconds = 150, [int]$IdleTimeoutSeconds = 900)

    $random = New-Object byte[] 24
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    $generator.GetBytes($random)
    $generator.Dispose()
    $token = ([BitConverter]::ToString($random) -replace '-', '').ToLowerInvariant()

    $listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $url = "http://127.0.0.1:$port/?t=$token"

    Write-Output "Synology Drive Filter Tool: $url"
    Write-Output 'Keep this window open. It closes itself when you press Finish in the browser.'
    if (-not $env:SYNOLOGY_FILTER_NO_BROWSER) { Start-Process $url }

    $lastActivity = Get-Date
    $lastBeat = $null
    $stop = $false

    try {
        while (-not $stop) {
            if (-not $listener.Pending()) {
                $now = Get-Date
                if ($lastBeat -and ($now - $lastBeat).TotalSeconds -gt $BeatTimeoutSeconds) { Write-Output 'Browser closed. Stopping.'; break }
                if (($now - $lastActivity).TotalSeconds -gt $IdleTimeoutSeconds) { Write-Output 'Idle timeout. Stopping.'; break }
                Start-Sleep -Milliseconds 100
                continue
            }

            $client = $listener.AcceptTcpClient()
            try {
                $request = Read-HttpRequest -Client $client
                if ($null -eq $request) { continue }

                if (-not (Test-RequestTrusted -Request $request -Port $port -Token $token)) {
                    Write-HttpResponse -Client $client -Status 403 -ContentType 'application/json' -Content '{"error":"forbidden"}'
                    continue
                }

                if ($request.Method -eq 'GET' -and $request.Path -eq '/') {
                    $lastActivity = Get-Date
                    Write-HttpResponse -Client $client -Status 200 -ContentType 'text/html' -Content $Html
                    continue
                }

                if ($request.Method -ne 'POST') {
                    Write-HttpResponse -Client $client -Status 404 -ContentType 'application/json' -Content '{"error":"not_found"}'
                    continue
                }

                if ($request.Path -eq '/api/heartbeat') {
                    $lastBeat = Get-Date
                    Write-HttpResponse -Client $client -Status 200 -ContentType 'application/json' -Content '{}'
                    continue
                }

                if ($request.Path -eq '/api/shutdown') {
                    Write-HttpResponse -Client $client -Status 200 -ContentType 'application/json' -Content '{}'
                    $stop = $true
                    continue
                }

                $lastActivity = Get-Date
                $result = try {
                    Invoke-ApiRequest -Ports $Ports -Request $request
                }
                catch {
                    Write-Warning $_.Exception.Message
                    New-UseCaseResult -Status 500 -Body @{ error = 'internal'; message = $_.Exception.Message }
                }
                Write-HttpResponse -Client $client -Status $result.Status -ContentType 'application/json' -Content (ConvertTo-JsonText $result.Body)
            }
            catch [System.IO.IOException] {
                Write-Verbose 'Client disconnected or sent nothing.'
            }
            finally {
                $client.Close()
            }
        }
    }
    finally {
        $listener.Stop()
    }
    Write-Output 'Stopped.'
}
