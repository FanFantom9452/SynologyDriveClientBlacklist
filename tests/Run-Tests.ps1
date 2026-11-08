# Uses temporary fixtures only; never touches the real Synology folder.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. "$root\src\Domain\FilterDocument.ps1"
. "$root\src\Domain\RuleCatalog.ps1"
. "$root\src\Application\UseCases.ps1"

$script:failed = 0
function Assert {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Output "PASS  $Name" }
    else { Write-Output "FAIL  $Name"; $script:failed++ }
}

$daemonText = @'
[Version]
major = 1
minor = 1

[Common]
black_dir_prefix = "/#recycle", "/\x24Recycle.Bin",
"/\x40tmp", "/Icon\x0d"

black_prefix = "."
max_length = 0

[File]
black_suffix = ".lnk", ".pyc",
"\x40tmp", "tmp"
max_size = 0

[Directory]

[EA]
'@

# Domain
$doc = ConvertFrom-FilterText -Text $daemonText
Assert 'parses multi-line lists' (@(Get-FilterValues -Document $doc -Section 'Common' -Key 'black_dir_prefix').Count -eq 4)
Assert 'normalizes escapes' ((Get-NormalizedFilterValue -Value '/\x24Recycle.Bin' -Key 'black_dir_prefix') -eq '$recycle.bin')
Assert 'treats \r and \x0d alike' ((Get-NormalizedFilterValue -Value 'Icon\r' -Key 'k') -eq (Get-NormalizedFilterValue -Value 'Icon\x0d' -Key 'k'))

foreach ($group in Get-RuleCatalog) { Add-RuleGroup -Document $doc -Group $group }
$text = ConvertTo-FilterText -Document $doc
$again = ConvertFrom-FilterText -Text $text
$suffixes = @(Get-FilterValues -Document $again -Section 'File' -Key 'black_suffix')
Assert 'merge keeps custom black_prefix' ((@(Get-FilterValues -Document $again -Section 'Common' -Key 'black_prefix') -join '') -eq '.')
Assert 'merge fills empty Directory' (@(Get-FilterValues -Document $again -Section 'Directory' -Key 'black_name') -contains '.fankeel')
Assert 'merge does not duplicate .pyc' (@($suffixes | Where-Object { $_ -eq '.pyc' }).Count -eq 1)
Assert 'merge keeps daemon spelling' ($suffixes -contains '\x40tmp')
Assert 'keeps scalar values' ($text -match 'max_size = 0')

$before = ConvertFrom-FilterText -Text $daemonText
$diff = Get-FilterDiff -Before $before -After (ConvertFrom-FilterText -Text $text)
Assert 'merge never reports removals' (@($diff | Where-Object { $_.Removed.Count -gt 0 }).Count -eq 0)

$repo = ConvertFrom-FilterText -Text ([IO.File]::ReadAllText("$root\blacklist.filter", [Text.Encoding]::UTF8))
$catalogDirs = @(Get-RuleCatalog | ForEach-Object { $_.Directories })
$uncovered = @(Get-FilterValues -Document $repo -Section 'Directory' -Key 'black_name' | Where-Object { $catalogDirs -notcontains $_ })
Assert "catalog covers blacklist.filter directories ($($uncovered -join ','))" ($uncovered.Count -eq 0)

# Application, with in-memory ports
function New-FakePorts {
    param([string[]]$Running = @())
    $state = @{ Files = @{ 'A' = $daemonText; 'B' = "[File]`r`nblack_prefix = `"~`"`r`n" }; Log = New-Object System.Collections.ArrayList; Backups = @{}; Running = $Running }
    return @{
        State               = $state
        TemplateText        = "[Directory]`r`nblack_name = `".git`"`r`n"
        IsInstalled         = { $true }
        ListSessions        = { @(@{ Id = '1'; FilterPath = 'A' }, @{ Id = '2'; FilterPath = 'B' }) }
        ResolveRoots        = { param($ids) @{ '1' = 'F:\x'; '2' = $null } }
        ReadText            = { param($p) $state.Files[$p] }.GetNewClosure()
        WriteText           = { param($p, $t) [void]$state.Log.Add("write:$p"); $state.Files[$p] = $t }.GetNewClosure()
        CreateBackup        = { param($p, $s) [void]$state.Log.Add("backup:$p"); $n = "bak-$s-$($state.Log.Count)"; $state.Backups[$n] = $state.Files[$p]; $n }.GetNewClosure()
        ListBackups         = { param($p) @($state.Backups.Keys) }.GetNewClosure()
        RestoreSource       = { param($p, $b) $state.Backups[$b] }.GetNewClosure()
        GetRunningProcesses = { @($state.Running) }.GetNewClosure()
        GetStamp            = { 'stamp' }
    }
}
$merge = [pscustomobject]@{ mode = 'merge'; sessions = @('1'); groups = @('fankeel', 'git') }

$ports = New-FakePorts
$scanResult = Invoke-Scan -Ports $ports
Assert 'scan reports missing groups' ($scanResult.Body.sessions[0].missing -contains 'fankeel')
Assert 'scan reports unknown root as null' ($null -eq $scanResult.Body.sessions[1].root)

$ports = New-FakePorts
$result = Invoke-Preview -Ports $ports -Request $merge
Assert 'preview writes nothing' ($ports.State.Log.Count -eq 0 -and $result.Status -eq 200)

$ports = New-FakePorts -Running @('cloud-drive-daemon')
$result = Invoke-Apply -Ports $ports -Request $merge
Assert 'apply refused while Synology runs' ($result.Status -eq 409 -and $ports.State.Log.Count -eq 0)

$ports = New-FakePorts
$result = Invoke-Apply -Ports $ports -Request $merge
Assert 'backup happens before write' (($ports.State.Log -join ',') -eq 'backup:A,write:A')
Assert 'apply keeps custom rule' ($ports.State.Files['A'] -match 'black_prefix = "\."')
$ports.State.Log.Clear()
$result = Invoke-Apply -Ports $ports -Request $merge
Assert 'second apply is a no-op' ($ports.State.Log.Count -eq 0 -and $result.Body.results[0].unchanged)

$ports = New-FakePorts
$request = [pscustomobject]@{ mode = 'overwrite'; sessions = @('1'); groups = @() }
$result = Invoke-Preview -Ports $ports -Request $request
Assert 'overwrite preview shows removals' (@($result.Body.previews[0].changes | Where-Object { $_.removed -contains '.' }).Count -eq 1)

$ports = New-FakePorts
Assert 'rejects unknown session' ((Invoke-Apply -Ports $ports -Request ([pscustomobject]@{ mode = 'merge'; sessions = @('9'); groups = @('git') })).Status -eq 400)
Assert 'rejects unknown group' ((Invoke-Apply -Ports $ports -Request ([pscustomobject]@{ mode = 'merge'; sessions = @('1'); groups = @('x') })).Status -eq 400)
Assert 'rejects bad mode' ((Invoke-Apply -Ports $ports -Request ([pscustomobject]@{ mode = 'x'; sessions = @('1'); groups = @('git') })).Status -eq 400)

$ports = New-FakePorts
$original = $ports.State.Files['A']
[void](Invoke-Apply -Ports $ports -Request $merge)
$backupName = @($ports.State.Backups.Keys)[0]
Assert 'rollback rejects unlisted backup' ((Invoke-Rollback -Ports $ports -Request ([pscustomobject]@{ session = '1'; backup = '..\..\x' })).Status -eq 400)
$result = Invoke-Rollback -Ports $ports -Request ([pscustomobject]@{ session = '1'; backup = $backupName })
Assert 'rollback restores content' ($result.Status -eq 200 -and $ports.State.Files['A'] -ceq $original)
Assert 'rollback backs up current first' ($ports.State.Backups.Count -eq 2)

# Real file-system ports against a temporary folder, with the process check stubbed
. "$root\src\Infrastructure\SynologyPorts.ps1"
$portFixture = Join-Path ([IO.Path]::GetTempPath()) ("synofilter-" + [guid]::NewGuid().ToString('N'))
try {
    $portConf = Join-Path $portFixture 'data\session\1\conf'
    New-Item -ItemType Directory -Force $portConf, (Join-Path $portFixture 'log'), (Join-Path $portFixture 'root\.SynologyWorkingDirectory') | Out-Null
    $portFilter = Join-Path $portConf 'blacklist.filter'
    [IO.File]::WriteAllText($portFilter, $daemonText)
    $syncRoot = Join-Path $portFixture 'root'
    [IO.File]::WriteAllLines((Join-Path $portFixture 'log\daemon.log'), @(
            "2026-01-01T00:00:00 (1:1) [INFO] x.cpp(1): Session (1): Path '/a/b' is ok",
            "2026-01-01T00:00:00 (1:1) [INFO] y.cpp(1): Worker (1): Reset for file '$syncRoot/a/b'"
        ))

    $realPorts = New-SynologyPorts -SynologyHome $portFixture -TemplateText ''
    $realPorts.GetRunningProcesses = { @() }
    $realScan = Invoke-Scan -Ports $realPorts
    Assert 'resolves root from a single active session' ($realScan.Body.sessions[0].root -eq $syncRoot)

    $result = Invoke-Apply -Ports $realPorts -Request $merge
    $written = [IO.File]::ReadAllText($portFilter)
    $portBackups = @(& $realPorts.ListBackups $portFilter)
    Assert 'real apply writes the merged file' ($result.Body.results[0].ok -and $written -match '\.fankeel')
    Assert 'real apply leaves a byte-exact backup' ($portBackups.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $portConf $portBackups[0])) -ceq $daemonText)
    Assert 'real apply leaves no temporary file' (@(Get-ChildItem -LiteralPath $portConf -Filter '*.writing-*').Count -eq 0)
    Assert 'written file has no BOM' ([IO.File]::ReadAllBytes($portFilter)[0] -ne 0xEF)
}
finally {
    Remove-Item -LiteralPath $portFixture -Recurse -Force
}

# End to end: the built run.ps1 against a fixture folder
$bundle = [IO.File]::ReadAllBytes("$root\run.ps1")
Assert 'run.ps1 is ASCII-only' (@($bundle | Where-Object { $_ -gt 127 }).Count -eq 0)

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("synofilter-" + [guid]::NewGuid().ToString('N'))
$conf = Join-Path $fixture 'data\session\1\conf'
New-Item -ItemType Directory -Force $conf | Out-Null
$filter = Join-Path $conf 'blacklist.filter'
[IO.File]::WriteAllText($filter, $daemonText)
$out = Join-Path $fixture 'stdout.txt'
$env:SYNOLOGY_FILTER_HOME = $fixture
$env:SYNOLOGY_FILTER_NO_BROWSER = '1'
$iexCommand = "[IO.File]::ReadAllText('$root\run.ps1') | Invoke-Expression"
$server = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $iexCommand -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
try {
    $url = $null
    for ($i = 0; $i -lt 100 -and -not $url; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $out) {
            $line = Select-String -Path $out -Pattern 'http://127\.0\.0\.1:\d+/\?t=\w+' | Select-Object -First 1
            if ($line) { $url = $line.Matches[0].Value }
        }
    }
    Assert 'server starts via Invoke-Expression' ([bool]$url)

    $uri = [Uri]$url
    $base = "http://127.0.0.1:$($uri.Port)"
    $token = $uri.Query.Substring(3)
    function Get-Status {
        param([string]$Path, [string]$Method = 'Post', [hashtable]$Headers = @{})
        try { return (Invoke-WebRequest -Uri "$base$Path" -Method $Method -Headers $Headers -UseBasicParsing).StatusCode }
        catch { return [int]$_.Exception.Response.StatusCode }
    }
    $auth = @{ 'X-Token' = $token }

    Assert 'page requires token' ((Get-Status -Path '/' -Method 'Get') -eq 403)
    Assert 'api requires token' ((Get-Status -Path '/api/scan') -eq 403)
    Assert 'foreign origin rejected' ((Get-Status -Path '/api/scan' -Headers @{ 'X-Token' = $token; Origin = 'http://evil.example' }) -eq 403)
    $page = Invoke-WebRequest -Uri $url -UseBasicParsing
    Assert 'serves bilingual page' ($page.Content -match 'English' -and $page.Content -match ([string][char]0x7E41 + [char]0x9AD4))
    $scan = Invoke-RestMethod -Uri "$base/api/scan" -Method Post -Headers $auth
    Assert 'scans fixture session' ($scan.sessions.Count -eq 1 -or $scan.sessions.id -eq '1')
    $beforeBytes = [IO.File]::ReadAllText($filter)
    $body = '{"mode":"merge","sessions":["1"],"groups":["fankeel"]}'
    $preview = Invoke-RestMethod -Uri "$base/api/preview" -Method Post -Headers $auth -Body $body -ContentType 'application/json'
    Assert 'preview lists .fankeel' (($preview.previews.changes.added) -contains '.fankeel')
    Assert 'preview leaves file unchanged' ([IO.File]::ReadAllText($filter) -ceq $beforeBytes)
    Assert 'shutdown accepted' ((Get-Status -Path '/api/shutdown' -Headers $auth) -eq 200)
    Assert 'server process exits' ($server.WaitForExit(10000))
}
finally {
    Remove-Item Env:SYNOLOGY_FILTER_HOME, Env:SYNOLOGY_FILTER_NO_BROWSER -ErrorAction SilentlyContinue
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

Write-Output "Failures: $script:failed"
if ($script:failed -gt 0) { exit 1 }
