# Use cases. All side effects go through the $Ports hashtable of script blocks:
#   ListSessions, ReadText, WriteText, CreateBackup, ListBackups, RestoreSource,
#   GetRunningProcesses, ResolveRoots, IsInstalled, GetStamp, TemplateText

function New-UseCaseResult {
    param([int]$Status = 200, [hashtable]$Body = @{})
    return @{ Status = $Status; Body = $Body }
}

function New-UseCaseError {
    param([int]$Status, [string]$Code)
    return New-UseCaseResult -Status $Status -Body @{ error = $Code }
}

function Get-RunningRefusal {
    param([hashtable]$Ports)
    $running = @(& $Ports.GetRunningProcesses)
    if ($running.Count -eq 0) { return $null }
    return New-UseCaseResult -Status 409 -Body @{ error = 'synology_running'; running = $running }
}

function Get-RunningState {
    param([hashtable]$Ports)
    return New-UseCaseResult -Body @{ running = @(& $Ports.GetRunningProcesses) }
}

function Invoke-Scan {
    param([hashtable]$Ports)

    $catalog = @(Get-RuleCatalog)
    $sessions = @(& $Ports.ListSessions)
    $roots = & $Ports.ResolveRoots @($sessions | ForEach-Object { $_.Id })

    $resultSessions = @(foreach ($session in $sessions) {
            $document = ConvertFrom-FilterText -Text (& $Ports.ReadText $session.FilterPath)
            $current = New-Object System.Collections.ArrayList
            foreach ($section in $document.Sections) {
                foreach ($entry in $section.Entries) {
                    if ($null -eq $entry.Key -or -not $entry.IsList) { continue }
                    [void]$current.Add(@{ section = $section.Name; key = $entry.Key; values = @($entry.Values) })
                }
            }
            @{
                id           = $session.Id
                filterPath   = $session.FilterPath
                root         = $roots[$session.Id]
                missing      = @($catalog | Where-Object { -not (Test-RuleGroupApplied -Document $document -Group $_) } | ForEach-Object { $_.Id })
                current      = @($current)
                backups      = @(& $Ports.ListBackups $session.FilterPath)
            }
        })

    return New-UseCaseResult -Body @{
        installed = [bool](& $Ports.IsInstalled)
        running   = @(& $Ports.GetRunningProcesses)
        sessions  = $resultSessions
        groups    = @($catalog | ForEach-Object {
                @{ id = $_.Id; default = $_.Default; directories = $_.Directories; fileNames = $_.FileNames; fileSuffixes = $_.FileSuffixes }
            })
    }
}

# Resolves request values against what the tool found itself; returns an error result or a plan.
function Resolve-ChangeRequest {
    param([hashtable]$Ports, $Request)

    if (@('merge', 'overwrite') -notcontains $Request.mode) { return @{ Error = (New-UseCaseError -Status 400 -Code 'bad_mode') } }

    $known = @{}
    foreach ($session in @(& $Ports.ListSessions)) { $known[$session.Id] = $session }
    $wantedSessions = @($Request.sessions)
    if ($wantedSessions.Count -eq 0) { return @{ Error = (New-UseCaseError -Status 400 -Code 'no_session') } }
    foreach ($id in $wantedSessions) {
        if (-not $known.ContainsKey([string]$id)) { return @{ Error = (New-UseCaseError -Status 400 -Code 'unknown_session') } }
    }

    $catalog = @{}
    foreach ($group in @(Get-RuleCatalog)) { $catalog[$group.Id] = $group }
    $groups = @()
    if ($Request.mode -eq 'merge') {
        $wantedGroups = @($Request.groups)
        if ($wantedGroups.Count -eq 0) { return @{ Error = (New-UseCaseError -Status 400 -Code 'no_group') } }
        foreach ($id in $wantedGroups) {
            if (-not $catalog.ContainsKey([string]$id)) { return @{ Error = (New-UseCaseError -Status 400 -Code 'unknown_group') } }
            $groups += $catalog[[string]$id]
        }
    }

    $plans = @(foreach ($id in $wantedSessions) {
            $session = $known[[string]$id]
            $beforeText = & $Ports.ReadText $session.FilterPath
            $before = ConvertFrom-FilterText -Text $beforeText
            if ($Request.mode -eq 'overwrite') {
                $afterText = $Ports.TemplateText
                $after = ConvertFrom-FilterText -Text $afterText
            }
            else {
                $after = ConvertFrom-FilterText -Text $beforeText
                foreach ($group in $groups) { Add-RuleGroup -Document $after -Group $group }
                $afterText = ConvertTo-FilterText -Document $after
            }
            @{ Session = $session; AfterText = $afterText; Changes = (Get-FilterDiff -Before $before -After $after) }
        })
    return @{ Plans = $plans }
}

function ConvertTo-ChangeView {
    param($Changes)
    return @($Changes | ForEach-Object { @{ section = $_.Section; key = $_.Key; added = $_.Added; removed = $_.Removed } })
}

function Invoke-Preview {
    param([hashtable]$Ports, $Request)

    $resolved = Resolve-ChangeRequest -Ports $Ports -Request $Request
    if ($resolved.Error) { return $resolved.Error }
    return New-UseCaseResult -Body @{
        previews = @($resolved.Plans | ForEach-Object { @{ id = $_.Session.Id; changes = (ConvertTo-ChangeView $_.Changes) } })
    }
}

function Invoke-Apply {
    param([hashtable]$Ports, $Request)

    $resolved = Resolve-ChangeRequest -Ports $Ports -Request $Request
    if ($resolved.Error) { return $resolved.Error }
    $refusal = Get-RunningRefusal -Ports $Ports
    if ($refusal) { return $refusal }

    $stamp = & $Ports.GetStamp
    $results = @(foreach ($plan in $resolved.Plans) {
            try {
                if ($plan.Changes.Count -eq 0) {
                    @{ id = $plan.Session.Id; ok = $true; unchanged = $true }
                    continue
                }
                $backup = & $Ports.CreateBackup $plan.Session.FilterPath $stamp
                & $Ports.WriteText $plan.Session.FilterPath $plan.AfterText
                @{ id = $plan.Session.Id; ok = $true; backup = $backup }
            }
            catch {
                @{ id = $plan.Session.Id; ok = $false; message = $_.Exception.Message }
            }
        })
    return New-UseCaseResult -Body @{ results = $results }
}

function Invoke-Rollback {
    param([hashtable]$Ports, $Request)

    $session = @(& $Ports.ListSessions) | Where-Object { $_.Id -eq [string]$Request.session } | Select-Object -First 1
    if ($null -eq $session) { return New-UseCaseError -Status 400 -Code 'unknown_session' }
    $backups = @(& $Ports.ListBackups $session.FilterPath)
    if ($backups -cnotcontains [string]$Request.backup) { return New-UseCaseError -Status 400 -Code 'unknown_backup' }
    $refusal = Get-RunningRefusal -Ports $Ports
    if ($refusal) { return $refusal }

    $text = & $Ports.RestoreSource $session.FilterPath $Request.backup
    $safety = & $Ports.CreateBackup $session.FilterPath (& $Ports.GetStamp)
    & $Ports.WriteText $session.FilterPath $text
    return New-UseCaseResult -Body @{ id = $session.Id; backup = $safety }
}
