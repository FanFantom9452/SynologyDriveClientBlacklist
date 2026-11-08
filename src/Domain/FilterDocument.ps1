# Parses, edits and serializes blacklist.filter text. Pure: no I/O.
# Values keep the spelling found in the file, so daemon-escaped items survive a merge.

function New-FilterSection {
    param([string]$Name)
    return @{ Name = $Name; Entries = (New-Object System.Collections.ArrayList) }
}

function ConvertFrom-FilterText {
    param([string]$Text)

    $sections = New-Object System.Collections.ArrayList
    $current = $null
    $lines = [regex]::Split($Text, '\r?\n')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }

        if ($line -match '^\[(.+)\]$') {
            $current = New-FilterSection -Name $Matches[1]
            [void]$sections.Add($current)
            continue
        }

        if ($null -eq $current) {
            $current = New-FilterSection -Name ''
            [void]$sections.Add($current)
        }

        if ($line -notmatch '^([^=\s]+)\s*=\s*(.*)$') {
            [void]$current.Entries.Add(@{ Key = $null; Raw = $line })
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2]
        while ($value.TrimEnd().EndsWith(',') -and ($i + 1) -lt $lines.Count) {
            $i++
            $value = $value.TrimEnd() + ' ' + $lines[$i].Trim()
        }

        if ($value.StartsWith('"')) {
            $values = New-Object System.Collections.ArrayList
            foreach ($match in [regex]::Matches($value, '"((?:[^"\\]|\\.)*)"')) {
                [void]$values.Add($match.Groups[1].Value)
            }
            [void]$current.Entries.Add(@{ Key = $key; IsList = $true; Values = $values })
        }
        else {
            [void]$current.Entries.Add(@{ Key = $key; IsList = $false; Raw = $value })
        }
    }

    return @{ Sections = $sections }
}

function ConvertTo-FilterText {
    param([hashtable]$Document)

    $output = New-Object System.Collections.ArrayList
    foreach ($section in $Document.Sections) {
        if ($section.Name -ne '') { [void]$output.Add("[$($section.Name)]") }
        foreach ($entry in $section.Entries) {
            if ($null -eq $entry.Key) {
                [void]$output.Add($entry.Raw)
            }
            elseif ($entry.IsList) {
                $quoted = @($entry.Values | ForEach-Object { '"' + $_ + '"' })
                [void]$output.Add("$($entry.Key) = $($quoted -join ', ')")
            }
            else {
                [void]$output.Add("$($entry.Key) = $($entry.Raw)")
            }
        }
        [void]$output.Add('')
    }
    return ($output -join "`r`n")
}

# Canonical form for comparing the repo spelling with the daemon spelling,
# e.g. "$Recycle.Bin" with "\x24Recycle.Bin" and "@tmp" with "/\x40tmp".
function Get-NormalizedFilterValue {
    param([string]$Value, [string]$Key)

    $decoded = [regex]::Replace($Value, '\\(x[0-9a-fA-F]{2}|.)', {
            param($match)
            $code = $match.Groups[1].Value
            if ($code.Length -eq 3) { return [string][char][Convert]::ToInt32($code.Substring(1), 16) }
            switch -CaseSensitive ($code) {
                'r' { return "`r" }
                'n' { return "`n" }
                't' { return "`t" }
                default { return $code }
            }
        })

    if ($Key -eq 'black_dir_prefix' -and $decoded.StartsWith('/')) { $decoded = $decoded.Substring(1) }
    return $decoded.ToLowerInvariant()
}

function Get-FilterSection {
    param([hashtable]$Document, [string]$Name, [switch]$Create)

    foreach ($section in $Document.Sections) {
        if ($section.Name -eq $Name) { return $section }
    }
    if (-not $Create) { return $null }

    $section = New-FilterSection -Name $Name
    [void]$Document.Sections.Add($section)
    return $section
}

function Get-FilterValues {
    param([hashtable]$Document, [string]$Section, [string]$Key)

    $found = Get-FilterSection -Document $Document -Name $Section
    if ($null -eq $found) { return @() }
    foreach ($entry in $found.Entries) {
        if ($entry.Key -eq $Key -and $entry.IsList) { return @($entry.Values) }
    }
    return @()
}

# Appends values that are not present yet. Never removes or rewrites an existing value.
function Add-FilterValues {
    param([hashtable]$Document, [string]$Section, [string]$Key, [string[]]$Values)

    $target = Get-FilterSection -Document $Document -Name $Section -Create
    $entry = $null
    foreach ($candidate in $target.Entries) {
        if ($candidate.Key -eq $Key) { $entry = $candidate; break }
    }

    if ($null -eq $entry) {
        $entry = @{ Key = $Key; IsList = $true; Values = (New-Object System.Collections.ArrayList) }
        [void]$target.Entries.Add($entry)
    }
    elseif (-not $entry.IsList) {
        if ($entry.Raw -ne '') { throw "Cannot add to non-list key [$Section] $Key" }
        $entry.IsList = $true
        $entry.Values = New-Object System.Collections.ArrayList
    }

    $known = @{}
    foreach ($value in $entry.Values) { $known[(Get-NormalizedFilterValue -Value $value -Key $Key)] = $true }
    foreach ($value in $Values) {
        $normalized = Get-NormalizedFilterValue -Value $value -Key $Key
        if (-not $known.ContainsKey($normalized)) {
            [void]$entry.Values.Add($value)
            $known[$normalized] = $true
        }
    }
}

function Get-FilterValueMap {
    param([hashtable]$Document)

    $map = @{}
    foreach ($section in $Document.Sections) {
        foreach ($entry in $section.Entries) {
            if ($null -eq $entry.Key) { continue }
            $id = "$($section.Name)|$($entry.Key)"
            if (-not $map.ContainsKey($id)) { $map[$id] = @{} }
            $values = if ($entry.IsList) { @($entry.Values) } elseif ($entry.Raw -ne '') { @($entry.Raw) } else { @() }
            foreach ($value in $values) {
                $map[$id][(Get-NormalizedFilterValue -Value $value -Key $entry.Key)] = $value
            }
        }
    }
    return $map
}

# Value-level difference, so a spelling change alone is not reported.
function Get-FilterDiff {
    param([hashtable]$Before, [hashtable]$After)

    $beforeMap = Get-FilterValueMap -Document $Before
    $afterMap = Get-FilterValueMap -Document $After
    $changes = New-Object System.Collections.ArrayList

    foreach ($id in @(@($beforeMap.Keys) + @($afterMap.Keys) | Sort-Object -Unique)) {
        $old = if ($beforeMap.ContainsKey($id)) { $beforeMap[$id] } else { @{} }
        $new = if ($afterMap.ContainsKey($id)) { $afterMap[$id] } else { @{} }
        $added = @($new.Keys | Where-Object { -not $old.ContainsKey($_) } | ForEach-Object { $new[$_] } | Sort-Object)
        $removed = @($old.Keys | Where-Object { -not $new.ContainsKey($_) } | ForEach-Object { $old[$_] } | Sort-Object)
        if ($added.Count -gt 0 -or $removed.Count -gt 0) {
            $parts = $id.Split('|')
            [void]$changes.Add(@{ Section = $parts[0]; Key = $parts[1]; Added = $added; Removed = $removed })
        }
    }
    return , @($changes)
}
