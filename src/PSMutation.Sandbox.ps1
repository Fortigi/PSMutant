<#
.SYNOPSIS
    Sandbox isolation for the PowerShell mutation runner.

.DESCRIPTION
    Mutants must NEVER be written into tracked source -- not even transiently, so a
    hard kill (Ctrl-C / TaskStop) can't leave a mutated file staged in git. So instead
    of mutating the real file in place, the runner copies the source subtrees into a
    throwaway temp sandbox and mutates only the copy. The tests run from the sandbox
    too, so their $PSScriptRoot-relative dot-sources resolve to the sandboxed modules.
    On any exit -- clean or killed -- only a temp dir is dirty, and it's disposable.

    Each function stays tiny (well under the complexity ceiling) and side-effects are
    confined here.
#>

function New-PSMutationSandbox {
    # Copy the source subtrees into a fresh temp dir; return its root path.
    #
    # -Subtrees is mandatory rather than defaulted. What to copy is a config decision,
    # and this file is mechanism: giving it an opinion about the repo's layout would put
    # the default here, where the resolver that owns it would have to reach across files
    # to read it.
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string[]]$Subtrees,
        [string]$Name = "psmut-sandbox-$PID"
    )
    $root = Join-Path ([System.IO.Path]::GetTempPath()) $Name
    if ($PSCmdlet.ShouldProcess($root, 'Create mutation sandbox')) {
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $Subtrees |
            Where-Object { Test-Path (Join-Path $RepoRoot $_) } |
            ForEach-Object { Copy-Item (Join-Path $RepoRoot $_) (Join-Path $root $_) -Recurse -Force }
    }
    return $root
}

function ConvertTo-PSMutationSandboxPath {
    # Map a repo path to its position inside the sandbox (structure is preserved). Pure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $rel = [System.IO.Path]::GetRelativePath($RepoRoot, [System.IO.Path]::GetFullPath($Path))
    $mapped = [System.IO.Path]::GetFullPath((Join-Path $SandboxRoot $rel))

    # Refuse a path that lands OUTSIDE the sandbox, because the caller writes to whatever
    # comes back. A leading `..` survives the round trip above, so a config naming a file
    # above the source root gets mutated where it lives -- and the promise that a hard kill
    # cannot leave a mutant in tracked source then rests entirely on the `finally` that
    # restores it, rather than on the mutant never touching a real file at all.
    #
    # Asked as a relative path rather than by string-matching for '..', because a path may
    # contain '..' and still resolve inside: `src/../src/a.ps1` is `src/a.ps1`, and refusing
    # that would reject a config that was never ambiguous.
    $back = [System.IO.Path]::GetRelativePath($SandboxRoot, $mapped)
    if ([System.IO.Path]::IsPathRooted($back) -or $back -eq '..' -or
        $back.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar)) {
        throw ("Config path '$Path' resolves outside the source root, to '$mapped'. Every path " +
            "in a config is copied into a temp sandbox and mutated there; one that escapes would " +
            "be mutated in place, in the directory the sandbox exists to replace. Use a path " +
            "inside '$RepoRoot', or point -SourceRoot at the directory that contains them all.")
    }
    return $mapped
}

function ConvertFrom-PSMutationSandboxPath {
    # Inverse of ConvertTo -- sandbox path back to a repo-relative display path. Pure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    return [System.IO.Path]::GetRelativePath($SandboxRoot, [System.IO.Path]::GetFullPath($Path)) -replace '\\', '/'
}

function Remove-PSMutationSandbox {
    # Delete a sandbox. Best-effort -- a leftover temp dir is harmless, never tracked.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)] [string]$SandboxRoot)
    if ($PSCmdlet.ShouldProcess($SandboxRoot, 'Remove mutation sandbox')) {
        if (Test-Path $SandboxRoot) { Remove-Item $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PSMutationSandboxOwnerId {
    # The process id encoded in a sandbox directory name, or $null when the name is
    # not one the runner produces. New-PSMutationSandbox names them
    # "psmut-sandbox-$PID"; anything else in temp is somebody else's and is left alone.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)
    if ($Name -match '^psmut-sandbox-(\d+)$') { return [int]$Matches[1] }
    return          # emits nothing, so the caller's variable is $null
}

function Test-PSMutationSandboxAbandoned {
    # True when a sandbox can be deleted: its owning process is gone. A sandbox whose
    # owner is still ALIVE belongs to a concurrent run and must be left alone, or two
    # runs on one machine delete each other's working files mid-flight.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Directory,
        [int]$CurrentProcessId = $PID
    )
    $owner = Get-PSMutationSandboxOwnerId -Name $Directory.Name
    if ($null -eq $owner) { return $false }
    # Our own id: any directory already holding it is a leftover from a previous
    # process that happened to get this id, and we are about to recreate it anyway.
    if ($owner -eq $CurrentProcessId) { return $true }
    $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if (-not $proc) { return $true }
    # The id is live but may have been RECYCLED onto an unrelated process. A process
    # that started after the sandbox did cannot be the one that created it, so the
    # sandbox is abandoned despite the id being in use.
    return (Get-PSMutationProcessStart -Process $proc) -gt $Directory.CreationTime
}

function Get-PSMutationProcessStart {
    # StartTime is not readable for every process -- protected/system ones fail. That
    # failure is NON-TERMINATING in PowerShell: the property yields $null instead of
    # raising, so a try/catch around it never runs (coverage proved the catch was
    # unreachable, which is why there isn't one). Testing the value is the whole
    # contract. An unreadable start time becomes a time far in the past, which reads
    # as "cannot prove this sandbox is stale" and so keeps it, rather than risking a
    # live run's files.
    [OutputType([datetime])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Process)
    $start = $Process.StartTime
    if ($null -eq $start) { return [datetime]::MinValue }
    return $start
}

function Clear-PSMutationStaleSandbox {
    # Sweep sandboxes left by a previously killed run (belt-and-braces at startup),
    # WITHOUT touching one that a concurrent run is using.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if ($PSCmdlet.ShouldProcess('temp', 'Clear stale mutation sandboxes')) {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'psmut-sandbox-*' -ErrorAction SilentlyContinue |
            Where-Object { Test-PSMutationSandboxAbandoned -Directory $_ } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
