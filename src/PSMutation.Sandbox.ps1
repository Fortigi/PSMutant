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

function New-PSMutationSandboxName {
    # A sandbox directory name no other local user can predict.
    #
    # The name used to be exactly "psmut-sandbox-$PID", in a world-writable temp directory. That is
    # guessable -- process ids are small, visible, and a watcher can simply wait -- so another local
    # user could create that path FIRST, as a symlink to a directory they own. The run then copied
    # the source through it. Reproduced end to end on Linux with the sticky bit set and
    # fs.protected_symlinks=1, which does not help here: that guard only covers the FINAL path
    # component, and the planted symlink is an intermediate one.
    #
    # The process id stays in the name because the stale sweep identifies an owner by it. What makes
    # the name unguessable is the suffix, and it comes from a cryptographic RNG rather than
    # Get-Random or a GUID: those are about uniqueness, and the property needed here is that an
    # attacker cannot predict the next value. RandomNumberGenerator.Create() predates .NET Core 1.0,
    # so it costs nothing against this module's PowerShell 7.2 floor.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns a string, changes no system state. New-PSMutationSandbox below is the one that creates something, and it does support ShouldProcess.')]
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $bytes = [byte[]]::new(16)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return "psmut-sandbox-$PID-" + [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Assert-PSMutationSandboxPath {
    # Refuse a sandbox path that already exists, rather than clearing it.
    #
    # The old code removed whatever was there first. That is what made the attack above work: on a
    # sticky temp directory the removal of another user's entry FAILS, the failure is
    # non-terminating, and execution carried on to write through the entry that was left. Refusing
    # is both safer and simpler -- with an unguessable name a collision is not a case worth
    # recovering from, so an existing path means something is wrong and the run should say so
    # instead of clearing it.
    #
    # Checked again AFTER creation by the caller, because a check followed by a create is a race.
    # Nothing about this refusal depends on winning it: the name is unguessable, so an attacker
    # cannot aim at it, and the post-creation check catches the case where the path we ended up
    # with is not the directory we asked for.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    throw ("Refusing to use the mutation sandbox '$Path': something is already there. The name " +
        'carries 128 bits of randomness, so this is not an ordinary collision -- it is either a ' +
        'leftover nothing cleaned up, or another local user placing something where this run was ' +
        'about to write. Delete it if you recognise it; investigate if you do not.')
}

function Assert-PSMutationSandboxReal {
    # Refuse a sandbox that is not the plain directory we just created.
    #
    # A reparse point here -- a symlink or a junction -- means writes land somewhere else, which is
    # the whole of the vulnerability this pair of guards closes. Checked after creation rather than
    # only before it, so a path substituted between the two is still caught.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or $item.LinkType) {
        throw ("Refusing to use the mutation sandbox '$Path': it is a " +
            "$($item.LinkType ? "$($item.LinkType) to '$($item.Target -join ', ')'" : 'file'), " +
            'not a directory this run created. Writes would land outside the sandbox, which is the ' +
            'one thing the sandbox exists to prevent.')
    }
}

function New-PSMutationSandbox {
    # Copy the source subtrees into a fresh temp dir; return its root path.
    #
    # -Subtrees is mandatory rather than defaulted. What to copy is a config decision,
    # and this file is mechanism: giving it an opinion about the repo's layout would put
    # the default here, where the resolver that owns it would have to reach across files
    # to read it.
    #
    # -Name defaults to an UNGUESSABLE name; see New-PSMutationSandboxName for why, and
    # Assert-PSMutationSandboxPath for why an existing path is refused rather than cleared.
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string[]]$Subtrees,
        [string]$Name = (New-PSMutationSandboxName)
    )
    $root = Join-Path ([System.IO.Path]::GetTempPath()) $Name
    if ($PSCmdlet.ShouldProcess($root, 'Create mutation sandbox')) {
        Assert-PSMutationSandboxPath -Path $root
        New-Item -ItemType Directory -Path $root | Out-Null
        Assert-PSMutationSandboxReal -Path $root
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
    # "psmut-sandbox-<pid>-<random>"; anything else in temp is somebody else's and is left alone.
    #
    # The random suffix is OPTIONAL in this pattern, and that is not laxity: sandboxes created
    # before the name was randomised are called "psmut-sandbox-<pid>" and still need reclaiming.
    # Refusing to recognise them would orphan every one of them permanently the moment this
    # version ships. The suffix is what makes a name unguessable when it is WRITTEN; reading one
    # is a different question.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)
    if ($Name -match '^psmut-sandbox-(\d+)(-[0-9a-f]+)?$') { return [int]$Matches[1] }
    # The other artefact a run used to leave named after its process: Pester's coverage XML, which
    # older versions wrote to temp as "psmut-coverage-<pid>.xml". Nothing ever deleted it -- the
    # sweep looked only at DIRECTORIES named psmut-sandbox-*, so it could not match by construction,
    # and they accumulated for the life of the machine. The coverage file now lives inside the
    # sandbox and goes with it, so this arm is TRANSITIONAL: it exists to reclaim what earlier
    # versions left behind, and can be deleted once no machine plausibly still has any.
    if ($Name -match '^psmut-coverage-(\d+)\.xml$') { return [int]$Matches[1] }
    return          # emits nothing, so the caller's variable is $null
}

function Test-PSMutationSandboxAbandoned {
    # True when a sandbox can be deleted: its owning process is gone. A sandbox whose
    # owner is still ALIVE belongs to a concurrent run and must be left alone, or two
    # runs on one machine delete each other's working files mid-flight.
    [OutputType([bool])]
    [CmdletBinding()]
    # No -CurrentProcessId parameter any more. It existed only for the carve-out that compared a
    # sandbox's owner against our own id, and with that gone nothing read it -- lint said so. A
    # seam kept for a future caller that nothing exercises is the shape this repo refuses
    # elsewhere; #1 can add one that does something when it needs one.
    param([Parameter(Mandatory)] $Directory)
    $owner = Get-PSMutationSandboxOwnerId -Name $Directory.Name
    if ($null -eq $owner) { return $false }
    # NO CARVE-OUT FOR OUR OWN ID, and its removal is the point of this change. It used to
    # return $true here, on the argument that "a directory already holding our id is a leftover
    # from a previous process that happened to get it, and we are about to recreate it anyway".
    # That was true while the name was exactly psmut-sandbox-<pid>, where a new run DID land on
    # the same path. Since the name gained 128 bits of randomness the second half stopped being
    # true -- a new run creates a different directory -- and all the first half did was make this
    # process's OWN live sandboxes reclaimable. Measured: with the carve-out, a sibling run's
    # sandbox and the caller's own both read as abandoned.
    #
    # Falling through instead answers correctly for both. Our process is alive, so Get-Process
    # finds it, and it started BEFORE the sandbox it created -- so the recycled-id test below
    # says "not abandoned" and the directory is left alone.
    #
    # What is given up is reclaiming a crashed run's leftovers while the same process still runs.
    # That is the right trade: with the process alive there is no way to tell a dead run's
    # directory from a live sibling's, and deleting a live run's working files is worse than
    # leaving one directory until the process exits. This is clause 4 of "Process, state and
    # concurrency" narrowing from "one run per process" toward "one run per RUN".
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
        # Directories AND files. The coverage XML older versions left in temp is a file, and a
        # sweep restricted to directories is what let 67 of them pile up on the machine this was
        # found on. Both shapes are named after the process that made them, so one ownership test
        # answers for both -- Test-PSMutationSandboxAbandoned reads Name and CreationTime, which a
        # FileInfo carries exactly as a DirectoryInfo does.
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'psmut-sandbox-*' -ErrorAction SilentlyContinue) +
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -File -Filter 'psmut-coverage-*.xml' -ErrorAction SilentlyContinue) |
            # A reparse point is skipped rather than swept. Temp is world-writable, so anyone can
            # leave a symlink named like a sandbox; recursively removing one asks the sweep to
            # follow a path an attacker chose. Nothing this module creates is ever a link, so
            # skipping costs nothing and removes the sweep as a deletion primitive.
            Where-Object { -not $_.LinkType } |
            Where-Object { Test-PSMutationSandboxAbandoned -Directory $_ } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
