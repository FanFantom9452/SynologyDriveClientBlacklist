# Real implementations of the use-case ports: the file system, processes and Synology logs.

function Get-SynologyHome {
    if ($env:SYNOLOGY_FILTER_HOME) { return $env:SYNOLOGY_FILTER_HOME }
    return (Join-Path $env:LOCALAPPDATA 'SynologyDrive')
}

function Get-SessionFilters {
    param([string]$SynologyHome)

    $pattern = Join-Path $SynologyHome 'data\session\*\conf\blacklist.filter'
    return @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $id = $_.Directory.Parent.Name
            if ($id -match '^\d+$') { @{ Id = $id; FilterPath = $_.FullName } }
        } | Sort-Object { [int]$_.Id })
}

# Daemon log lines carry no session id next to local paths, so a root is only
# attributed when the logs show a single active session. Anything else stays unknown.
function Resolve-SessionRoots {
    param([string]$SynologyHome, [string[]]$SessionIds)

    $roots = @{}
    foreach ($id in $SessionIds) { $roots[$id] = $null }

    $logs = @(Get-ChildItem -Path (Join-Path $SynologyHome 'log\daemon.log*') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    if ($logs.Count -eq 0) { return $roots }

    try {
        $active = @{}
        $candidates = @{}
        $pattern = "Session \((\d+)\)|'([A-Za-z]:\\[^'/]*)/"
        foreach ($hit in (Select-String -Path $logs.FullName -Pattern $pattern -AllMatches -ErrorAction Stop)) {
            foreach ($match in $hit.Matches) {
                if ($match.Groups[1].Success) { $active[$match.Groups[1].Value] = $true }
                if ($match.Groups[2].Success) { $candidates[$match.Groups[2].Value] = 1 + [int]$candidates[$match.Groups[2].Value] }
            }
        }
        if ($active.Count -ne 1) { return $roots }

        $sessionId = @($active.Keys)[0]
        if (-not $roots.ContainsKey($sessionId)) { return $roots }
        $ranked = $candidates.GetEnumerator() | Sort-Object Value -Descending
        foreach ($candidate in $ranked) {
            if (Test-Path -LiteralPath (Join-Path $candidate.Key '.SynologyWorkingDirectory')) {
                $roots[$sessionId] = $candidate.Key
                break
            }
        }
    }
    catch {
        Write-Verbose "Cannot read Synology logs: $($_.Exception.Message)"
    }
    return $roots
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)

    $temporary = "$Path.writing-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
        # PowerShell turns $null into '' for string arguments; Replace needs a real null.
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function New-SynologyPorts {
    param([string]$SynologyHome, [string]$TemplateText)

    $rootCache = @{ Value = $null }
    # GetNewClosure blocks cannot see functions from the bundle scope, so capture them.
    $findSessions = ${function:Get-SessionFilters}
    $findRoots = ${function:Resolve-SessionRoots}

    return @{
        TemplateText        = $TemplateText
        IsInstalled         = { Test-Path -LiteralPath (Join-Path $SynologyHome 'data\session') }.GetNewClosure()
        ListSessions        = { & $findSessions -SynologyHome $SynologyHome }.GetNewClosure()
        ResolveRoots        = {
            param($ids)
            if ($null -eq $rootCache.Value) { $rootCache.Value = & $findRoots -SynologyHome $SynologyHome -SessionIds $ids }
            return $rootCache.Value
        }.GetNewClosure()
        ReadText            = { param($path) return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
        WriteText           = { param($path, $text) Write-TextAtomic -Path $path -Text $text }
        GetStamp            = { return (Get-Date -Format 'yyyyMMdd-HHmmss') }
        CreateBackup        = {
            param($path, $stamp)
            $backup = "$path.bak-$stamp"
            [IO.File]::Copy($path, $backup, $false)
            return (Split-Path -Leaf $backup)
        }
        ListBackups         = {
            param($path)
            return @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter 'blacklist.filter.bak-*' |
                    Sort-Object Name -Descending | ForEach-Object { $_.Name })
        }
        RestoreSource       = {
            param($path, $backup)
            return [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $path) $backup), [Text.Encoding]::UTF8)
        }
        GetRunningProcesses = {
            return @(Get-Process -Name 'cloud-drive-ui', 'cloud-drive-connect', 'cloud-drive-daemon' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
        }
    }
}
