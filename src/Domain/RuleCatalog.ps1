# The selectable rule groups. Display names live in the web UI, keyed by Id.
# gitPointerFile is off by default until the daemon is confirmed to keep [File] black_name.

function Get-RuleCatalog {
    return @(
        @{ Id = 'git'; Default = $true; Directories = @('.git'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'worktrees'; Default = $true; Directories = @('worktrees', '.worktrees'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'gitPointerFile'; Default = $false; Directories = @(); FileNames = @('.git'); FileSuffixes = @() }
        @{ Id = 'fankeel'; Default = $true; Directories = @('.fankeel'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'node'; Default = $true; Directories = @('node_modules', '.node-gyp'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'python'; Default = $true; Directories = @('.venv', 'venv', '__pycache__', '.pytest_cache', '.ruff_cache', '.mypy_cache'); FileNames = @(); FileSuffixes = @('.pyc', '.pyo') }
        @{ Id = 'build'; Default = $true; Directories = @('dist', 'build', '.next', '.svelte-kit', '.turbo', '.vite', '.parcel-cache'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'tools'; Default = $true; Directories = @('.cache', '.gradle', '.idea', 'coverage', '.playwright-mcp'); FileNames = @(); FileSuffixes = @() }
        @{ Id = 'system'; Default = $true; Directories = @('@tmp', '@eaDir', '.SynologyWorkingDirectory', '#recycle', 'desktop.ini', '.ds_store', 'Icon\r', 'thumbs.db', '$Recycle.Bin', '@sharebin', 'System Volume Information', 'Program Files', 'Program Files (x86)', 'ProgramData', '#snapshot'); FileNames = @(); FileSuffixes = @('tmp', 'temp', '.swp', '.lnk', '.pst') }
    )
}

function Add-RuleGroup {
    param([hashtable]$Document, [hashtable]$Group)

    if ($Group.Directories.Count -gt 0) { Add-FilterValues -Document $Document -Section 'Directory' -Key 'black_name' -Values $Group.Directories }
    if ($Group.FileNames.Count -gt 0) { Add-FilterValues -Document $Document -Section 'File' -Key 'black_name' -Values $Group.FileNames }
    if ($Group.FileSuffixes.Count -gt 0) { Add-FilterValues -Document $Document -Section 'File' -Key 'black_suffix' -Values $Group.FileSuffixes }
}

function Test-RuleGroupApplied {
    param([hashtable]$Document, [hashtable]$Group)

    $checks = @(
        @{ Section = 'Directory'; Key = 'black_name'; Wanted = $Group.Directories }
        @{ Section = 'File'; Key = 'black_name'; Wanted = $Group.FileNames }
        @{ Section = 'File'; Key = 'black_suffix'; Wanted = $Group.FileSuffixes }
    )
    foreach ($check in $checks) {
        $present = @(Get-FilterValues -Document $Document -Section $check.Section -Key $check.Key |
                ForEach-Object { Get-NormalizedFilterValue -Value $_ -Key $check.Key })
        foreach ($wanted in $check.Wanted) {
            if ($present -notcontains (Get-NormalizedFilterValue -Value $wanted -Key $check.Key)) { return $false }
        }
    }
    return $true
}
