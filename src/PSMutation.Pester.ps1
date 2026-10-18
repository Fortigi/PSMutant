<#
.SYNOPSIS
    Everything this module knows about Pester: which one is loaded, where it lives, and
    the contract a child runspace imports it under.

.DESCRIPTION
    This is the module's boundary with the one dependency it cannot abstract, and it is
    one file so that the answer to "which Pester" is given ONCE.

    Two callers need that answer and need the same one: the version guard, and the path
    handed to every child runspace. If they ever disagree the process validates one Pester
    and mutates under another -- and that failure is silent, not loud. A child runspace
    that dies on an assembly collision returns no verdict, and anything-but-Passed reads
    as a kill, so every mutant "dies" and the run reports a perfect, entirely fake 100%.
#>

$script:PSMutationPesterRequired = 'Pester 5.2.0 or later is required. Install-Module Pester -MinimumVersion 5.2.0 -Force -Scope CurrentUser'

function Get-PSMutationLoadedPester {
    <#
    .SYNOPSIS
        The Pester this process has already loaded, or $null if none is.
    .DESCRIPTION
        The single answer to "which Pester", because both callers below must reach the
        same one -- see this file's header for what divergence costs.
    .OUTPUTS
        [psmoduleinfo] the loaded module, or $null.
    #>
    [OutputType([psmoduleinfo])]
    [CmdletBinding()]
    param()
    # Highest wins: two Pester 5.x releases CAN coexist in one process (the dll guard
    # only rejects a LOWER loaded version), and the newer of them is the one whose
    # assembly is actually serving calls.
    return Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1
}

function Assert-PSMutationPester {
    <#
    .SYNOPSIS
        Make sure a usable Pester is available, WITHOUT pulling in a second one.
    .DESCRIPTION
        `Import-Module Pester -MinimumVersion 5.2.0` is not the no-op it looks like when
        a satisfying Pester is already loaded: PowerShell re-resolves the name against
        PSModulePath, picks the NEWEST version installed, and on a machine that has two
        it collides with the Pester.dll already in the process -- which is fatal, and
        happens before a single mutant runs.

        So an already-loaded Pester is checked and accepted as it is, and the import
        only happens when nothing is loaded at all. That is also what lets the module
        honour the >= 5.2.0 in its manifest: it runs under the caller's Pester rather
        than choosing one for them.

        THE FLOOR IS 5.2.0, AND THERE ARE TWO REASONS. The first is the one #161 found and it
        is the weaker of them, so read the second before trying to lower this.

        1. `New-PesterConfiguration` arrives in 5.2.0 -- measured, 5.0.0 and 5.1.0 do not export
           it. Under those, the command is not found, PowerShell autoloads `Pester` by NAME to
           the newest installed, and that collides with the Pester.dll already in the process.

           THIS ONE IS SOLVABLE and was tried: 5.0.0 has the `-Configuration` parameter and the
           `[PesterConfiguration]` TYPE, so only the cmdlet that builds one is missing.
           `[PesterConfiguration]::Default` works on every version in range and returns a fresh
           instance rather than a shared singleton. Swapping it in gets 5.0.0 past this point.

        2. `CodeCoverage.CommandsExecuted` comes back UNUSABLE on 5.0.0 and 5.1.0. Measured over
           the same fixture:

               5.0.0  CommandsExecuted=1, no properties at all, File=[] Line=[]
               5.1.0  CommandsExecuted=1, no properties at all, File=[] Line=[]
               5.2.0  CommandsExecuted=2, File=/.../calc.ps1 Line=1

           `coveredLinesOnly` reads File and Line from those objects, and no guard can conjure
           data that is not there. Degrading to "mutate everything" instead would silently
           change the mutant set and the score on those two versions -- the quiet difference
           this tool exists to find in other people's code.

        So the floor is 5.2.0 for reason 2, not reason 1, and a guard around the constructor
        buys nothing on its own.
    #>
    [CmdletBinding()]
    param()
    $loaded = Get-PSMutationLoadedPester
    if ($loaded) {
        if ($loaded.Version -lt [version]'5.2.0') { throw $script:PSMutationPesterRequired }
        return
    }
    if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge '5.2.0')) {
        throw $script:PSMutationPesterRequired
    }
    Import-Module Pester -MinimumVersion 5.2.0
}

function Get-PSMutationPesterPath {
    <#
    .SYNOPSIS
        File path of the Pester ALREADY LOADED in this process, so a child runspace can
        import that one by path instead of resolving the name for itself.
    .DESCRIPTION
        A fresh runspace resolves `Pester` by NAME against PSModulePath and gets the
        NEWEST version installed -- which is not necessarily the version this process
        already loaded. Assemblies are per-process, so when the two differ the child
        dies on "An incompatible version of the Pester.dll assembly is already loaded".
        A child that dies produces no verdict, and anything-but-Passed reads as a kill --
        so on any machine with two Pesters installed every mutant dies and the run reports
        a silent, entirely fake 100%. Receive-PSMutationJob throws rather than returning
        nothing for that reason.

        Importing by PATH is what makes the module version-agnostic in the way the
        manifest promises: whatever Pester >= 5 the consuming repo runs, the mutant
        runs under that same one.
    .OUTPUTS
        [string] path to the loaded Pester module file.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $loaded = Get-PSMutationLoadedPester
    if (-not $loaded) {
        throw 'Pester is not loaded in this session, so a mutant cannot be run against it.'
    }
    return $loaded.Path
}

function Get-PSMutationBoundedPesterScript {
    <#
    .SYNOPSIS
        The script a mutant's child runspace runs: import the pinned Pester, run the
        covering tests, emit the one-word result.
    .DESCRIPTION
        Named rather than inlined because it is the child's whole contract. Two things
        in it are load-bearing and easy to "simplify" away:

        * `Import-Module $pester` imports by PATH. Importing by name lets the runspace
          resolve Pester itself, which picks the newest installed rather than the one
          this process loaded -- the collision Get-PSMutationPesterPath exists to stop.
        * `-ErrorAction Stop` makes a failed import terminate the child, so the caller
          gets an exception instead of an empty result that reads as a dead mutant.
    .OUTPUTS
        [string] the script text.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return @'
param($tests, $pester)
Import-Module $pester -Force -ErrorAction Stop
$c = New-PesterConfiguration
$c.Run.Path = $tests
$c.Run.PassThru = $true
$c.Output.Verbosity = 'None'
if ($c.Run.PSObject.Properties['SkipRemainingOnFailure']) { $c.Run.SkipRemainingOnFailure = 'Run' }
(Invoke-Pester -Configuration $c).Result
'@
}

function Get-PSMutationRunspaceError {
    # Whatever the child wrote to its error stream, as one line. Reported rather than
    # swallowed: without it a failed child is indistinguishable from a killed mutant.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Runspace)
    $messages = @($Runspace.Streams.Error | ForEach-Object { $_.Exception.Message })
    if (-not $messages) { return 'the child runspace reported no error' }
    return ($messages -join '; ')
}

# --- WARM RUNSPACE POOL ---------------------------------------------------------------------
# One runspace PER WORKER, Pester imported into each once, reused across mutants.
#
# Measured on PSComplexity as the target: a fresh runspace plus Import-Module Pester costs about
# 396 ms, paid on EVERY mutant -- 219s of an 801s run, 27%, spent re-importing a module that does
# not change. Reused, the same call costs about 28 ms.
#
# Correctness rests on the child re-reading the mutated file each time, which it already does: the
# covering suite dot-sources the source under test, so nothing about the mutant is cached in the
# runspace. What COULD leak is state a suite leaves behind, which is why a runspace is recycled
# on a fixed interval and unconditionally after a timeout -- Stop() leaves a runspace unusable.
#
# KEYED BY WORKER, and that is what parallel evaluation needed from this file. A singleton would
# hand the same [PowerShell] instance to two workers at once, and a second BeginInvoke on a busy
# instance throws -- so the failure would not be a subtle wrong answer, but it would be a run that
# dies at random depending on scheduling. Each worker owns a runspace and nothing else touches it,
# which is also what makes the per-worker recycle and the post-timeout discard mean the same thing
# they meant when there was one.
$script:PSMutationWarmRunspace = @{}
$script:PSMutationWarmShell = @{}
$script:PSMutationWarmUses = @{}

# --- WORKER PROCESSES (#256) ----------------------------------------------------------------
# With more than one worker, each worker's runspace lives in a pwsh process of its own. Runspaces
# in one process share its GC heap and stop scaling: measured on PSComplexity's own suites, runspace
# workers were no faster at 16 than at 4, and process workers were 2.3x faster than runspaces at
# 16, with equal times at one worker. A process also gives each worker its own environment block
# and its own $PID, which removes both documented parallel-safety hazards.
#
# worker id -> its PowerShellProcessInstance; absent for an in-process runspace. The out-of-process
# runspace never notices that its process died -- measured on Windows and Linux: killed, or ended
# by [Environment]::Exit, the pipeline stays Running and disposing the runspace hangs -- so the
# runner watches the process itself, and a dead or killed worker is released through this instance
# alone, whose Dispose ends the process and returns at once.
$script:PSMutationWarmProcess = @{}

# Runspaces taken out of the pool after a timeout, whose stop has been REQUESTED and may not have
# finished (#250). PowerShell's Stop() is synchronous and waits for a blocking .NET call to
# return -- measured: 7.4s for an 8s Thread.Sleep -- and the scheduler is single-threaded, so
# every worker stalled for it. BeginStop returns at once; the runspace waits here until its stop
# completes, and is disposed then.
$script:PSMutationRetiredRunspace = [System.Collections.Generic.List[object]]::new()

# How many mutants one runspace serves before it is rebuilt. Bounds any state a covering suite
# leaves behind: the saving is already 93% of the floor at this interval, so a larger number buys
# almost nothing and widens the window in which a leak could go unnoticed.
$script:PSMutationWarmRunspaceLifetime = 50

# The same bound for a worker PROCESS (#256), set by the same rule and so a different number. A new
# process compiles Pester and the code under test afresh, which a runspace in this process does not:
# measured against PSComplexity's whole config on four cores, renewing every fifty mutants cost about
# 12 worker-seconds a renewal -- 65% more CPU and 3% slower than runspace workers, where without
# renewal the same run was 28% faster with the same CPU. At 500 the renewal is about 4% of what a
# mutant costs there, back inside the 93% this interval was chosen for.
$script:PSMutationWarmProcessLifetime = 500

function Close-PSMutationWarmRunspace {
    # Dispose ONE worker's warm runspace, if it has one. Safe to call when it does not.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes an in-process runspace; there is no system state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    # ONE guard for both, because the two are always set together and always cleared together --
    # Get-PSMutationWarmShell assigns them in the same breath and nothing else touches either.
    # Written as two guards they imply a state where one exists without the other, which cannot
    # happen, and the mutation gate proved the cost of pretending otherwise: forcing either guard
    # false left the OTHER object disposed, so a test asking whether the shell still works threw
    # anyway and both mutants survived. One guard is both simpler and observable.
    # A worker whose process has died is released by its process alone: disposing a runspace whose
    # process is gone waits for it forever.
    if ($script:PSMutationWarmShell.ContainsKey($WorkerId) -and -not (Test-PSMutationWorkerExited -WorkerId $WorkerId)) {
        $script:PSMutationWarmShell[$WorkerId].Dispose()
        $script:PSMutationWarmRunspace[$WorkerId].Dispose()
    }
    # Removed rather than set to $null. A key whose value is $null still answers ContainsKey, so
    # the guard above would fire on the next close and dispose $null -- and Get-PSMutationWarmShell
    # would hand back nothing while believing it had a shell.
    $script:PSMutationWarmShell.Remove($WorkerId)
    $script:PSMutationWarmRunspace.Remove($WorkerId)
    $script:PSMutationWarmUses.Remove($WorkerId)
    Close-PSMutationWorkerProcess -WorkerId $WorkerId
}

function Close-PSMutationWorkerProcess {
    # End ONE worker's process, if it has one, at once: a clean close, a timeout and a crash alike.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Ends a worker process this module started; there is no user state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    if (-not $script:PSMutationWarmProcess.ContainsKey($WorkerId)) { return }
    $script:PSMutationWarmProcess[$WorkerId].Dispose()
    $script:PSMutationWarmProcess.Remove($WorkerId)
}

function Resume-PSMutationWorkerBreakpoint {
    # Continue a worker PROCESS stopped at a breakpoint, as a runspace in this process does on its
    # own: with no debugger attached, a breakpoint there runs on. Nothing for any other worker.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resumes a worker process this module owns; there is no user state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    # No guard on the kind of worker: an in-process runspace never stops at a breakpoint, a worker
    # that is not there has no debugger, and a dead process answers at once -- the self-mutation
    # gate showed a guard here changed nothing. Asked, because resuming a debugger that is not
    # stopped THROWS (measured).
    $debugger = $script:PSMutationWarmRunspace[$WorkerId].Debugger
    if ($debugger.InBreakpoint) { $debugger.SetDebuggerAction([System.Management.Automation.DebuggerResumeAction]::Continue) }
}

function Test-PSMutationWorkerExited {
    # True when this worker runs in a process and that process has ended -- crashed, or killed.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    return $script:PSMutationWarmProcess.ContainsKey($WorkerId) -and $script:PSMutationWarmProcess[$WorkerId].Process.HasExited
}

function Stop-PSMutationWarmRunspace {
    # Retire ONE worker's runspace without waiting for it to stop (#250). The worker's next shell is
    # a fresh one, exactly as after a synchronous stop; only the waiting is gone.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops an in-process runspace; there is no system state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    if (-not $script:PSMutationWarmShell.ContainsKey($WorkerId)) { return }
    # A worker PROCESS is ended outright (#256): killing it stops even a blocking .NET call, which
    # a stop request cannot, and its runspace is abandoned rather than parked -- disposing it would
    # wait forever on a process that is gone.
    if ($script:PSMutationWarmProcess.ContainsKey($WorkerId)) {
        Close-PSMutationWorkerProcess -WorkerId $WorkerId
        $script:PSMutationWarmShell.Remove($WorkerId)
        $script:PSMutationWarmRunspace.Remove($WorkerId)
        $script:PSMutationWarmUses.Remove($WorkerId)
        return
    }
    $shell = $script:PSMutationWarmShell[$WorkerId]
    $script:PSMutationRetiredRunspace.Add([pscustomobject]@{
            Shell = $shell; Runspace = $script:PSMutationWarmRunspace[$WorkerId]
            Stop = $shell.BeginStop($null, $null)
        })
    # Removed, not closed: closing disposes, and disposing a running shell waits for it -- the
    # very wait this exists to avoid.
    $script:PSMutationWarmShell.Remove($WorkerId)
    $script:PSMutationWarmRunspace.Remove($WorkerId)
    $script:PSMutationWarmUses.Remove($WorkerId)
}

function Clear-PSMutationRetiredRunspace {
    # Dispose every retired runspace whose stop has finished; leave the rest. One still stuck in a
    # blocking call is left for the process to reclaim when the call returns, rather than making
    # anyone wait for it -- which is the whole point of retiring it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes in-process runspaces; there is no system state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param()
    foreach ($r in @($script:PSMutationRetiredRunspace)) {
        if (-not $r.Stop.IsCompleted) { continue }
        $r.Shell.Dispose()
        $r.Runspace.Dispose()
        [void]$script:PSMutationRetiredRunspace.Remove($r)
    }
}

function Close-PSMutationWarmRunspacePool {
    # Dispose every worker's warm runspace. The run's exit path, so a long-lived host does not
    # keep a Pester-loaded runspace per completed run -- once per WORKER now, which is the whole
    # reason this is not just the singleton's close under a new name.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes in-process runspaces; there is no system state to confirm.')]
    [OutputType([void])]
    [CmdletBinding()]
    param()
    # Snapshotted with @(), because Close-PSMutationWarmRunspace removes the key it is given and
    # a hashtable being enumerated cannot be modified -- iterating .Keys directly throws on the
    # second worker, which is a failure that only appears once somebody runs in parallel.
    foreach ($id in @($script:PSMutationWarmShell.Keys)) { Close-PSMutationWarmRunspace -WorkerId $id }
    Clear-PSMutationRetiredRunspace
}

function Get-PSMutationWarmShell {
    # A PowerShell instance on a runspace that already has Pester loaded, belonging to one worker.
    [OutputType([powershell])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$WorkerId,
        # In a pwsh process of its own rather than in this one (#256).
        [switch]$Process
    )
    # Opportunistic: a retired runspace whose stop has since finished is disposed here, so a long
    # run with many timeouts does not hold them all until the end.
    Clear-PSMutationRetiredRunspace
    # Reused only where it lives where it was asked for -- a run cannot be handed the other kind --
    # and never once its process has died: its runspace would wait on it forever.
    $lifetime = $Process ? $script:PSMutationWarmProcessLifetime : $script:PSMutationWarmRunspaceLifetime
    if ($script:PSMutationWarmShell.ContainsKey($WorkerId) -and
        $script:PSMutationWarmUses[$WorkerId] -lt $lifetime -and
        $script:PSMutationWarmProcess.ContainsKey($WorkerId) -eq [bool]$Process -and
        -not (Test-PSMutationWorkerExited -WorkerId $WorkerId)) {
        $script:PSMutationWarmUses[$WorkerId]++
        return $script:PSMutationWarmShell[$WorkerId]
    }
    Close-PSMutationWarmRunspace -WorkerId $WorkerId
    $rs = New-PSMutationWorkerRunspace -WorkerId $WorkerId -Process:$Process
    $rs.Open()
    # A worker process refuses Set-PSBreakpoint until its client says it can debug it -- measured:
    # "remote debugging is not supported by the current host" -- so Pester's breakpoint coverage,
    # and any suite that traces with a breakpoint action, failed in a worker and passed in this
    # process. RemoteScript allows them. A breakpoint that STOPS then waits for the client, where
    # in-process it runs on; Resume-PSMutationWorkerBreakpoint resumes it.
    if ($Process) { $rs.Debugger.SetDebugMode([System.Management.Automation.DebugModes]::RemoteScript) }
    $shell = [PowerShell]::Create()
    $shell.Runspace = $rs
    # Started where an in-process runspace starts: the process's current directory. A worker
    # process starts in the user's home instead, measured, and a suite reading a relative path
    # would read it from there.
    [void]$shell.AddScript('param($pester, $cwd) Set-Location -LiteralPath $cwd; Import-Module $pester -Force -ErrorAction Stop').
        AddParameter('pester', (Get-PSMutationPesterPath)).AddParameter('cwd', [System.Environment]::CurrentDirectory)
    # Caught and re-thrown with context, not swallowed. The child's -ErrorAction Stop makes a
    # failed import TERMINATING, so this arrives as an exception from Invoke() rather than on the
    # error stream -- which is why there is no HadErrors check beside it: with the import
    # terminating, that branch could never fire, and a branch that cannot fire looks exactly like
    # one that keeps passing.
    #
    # The runspace is disposed before rethrowing so a failed warm-up cannot be handed to the next
    # caller. A shell without Pester would run every covering suite into a command-not-found and
    # report no verdict, which the verdict reader treats as a KILL -- the same shape as the version
    # collision this file exists to prevent.
    try { $null = $shell.Invoke() }
    catch {
        $shell.Dispose(); $rs.Dispose()
        Close-PSMutationWorkerProcess -WorkerId $WorkerId
        throw "Could not import Pester into the mutant runspace: $($_.Exception.Message)"
    }
    $shell.Commands.Clear()
    $script:PSMutationWarmRunspace[$WorkerId] = $rs
    $script:PSMutationWarmShell[$WorkerId] = $shell
    $script:PSMutationWarmUses[$WorkerId] = 1
    return $shell
}

function New-PSMutationWorkerRunspace {
    # An unopened runspace for one worker: in this process, or in a pwsh process of its own (#256),
    # which is recorded so the runner can watch it and end it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts a worker process this module owns and ends; there is no user state to confirm.')]
    [OutputType([runspace])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId, [switch]$Process)
    if (-not $Process) { return [runspacefactory]::CreateRunspace() }
    # The process running this one, by default: the same pwsh, so the same PowerShell version.
    $instance = [System.Management.Automation.Runspaces.PowerShellProcessInstance]::new()
    $script:PSMutationWarmProcess[$WorkerId] = $instance
    return [runspacefactory]::CreateOutOfProcessRunspace(
        [System.Management.Automation.Runspaces.TypeTable]::LoadDefaultTypeFiles(), $instance)
}

function Get-PSMutationWarmPesterScript {
    <#
    .SYNOPSIS
        The child body a mutant runs, WITHOUT the import -- the warm runspace already has Pester.
    .DESCRIPTION
        Two things in it are load-bearing.

        SkipRemainingOnFailure stops the suite at the first failing test. A mutant only ever asks
        one question -- does ANY test notice -- and once one has, every test after it is work whose
        outcome cannot change the verdict. Measured against a killed mutant in this repo's sibling:
        a 2.03s covering suite finishes in 0.34s, 83% less, with the run result identical. A
        SURVIVOR is unaffected by construction: nothing fails, so nothing is skipped, and the whole
        suite runs exactly as before.

        It is set only when the loaded Pester HAS it. `SkipRemainingOnFailure` arrived in **Pester
        5.3.0** (2021-08-17) -- measured, not looked up: 5.2.0 does not carry the property and 5.3.0
        does. So the guard exists for **Pester 5.2.x** and nothing else; from 5.3.0 onward
        every consumer takes the fast path whatever their version.

        That window is narrow and old, and the guard is kept anyway because this module promises to
        run under whatever Pester >= 5.2.0 the consumer already has. Assigning a property that does
        not exist would fail the whole run for a speed optimisation, which is a bad trade in the
        direction that matters: the point of the promise is that PSMutant bends to the consumer's
        Pester rather than the other way round.

        Detected rather than version-compared, because the question is whether this Pester supports
        the property, not what it is called -- and a version comparison would have encoded 5.5,
        which is what this comment said before the versions were actually measured.
    .OUTPUTS
        [string] the script text.
    #>
    [OutputType([scriptblock])]
    [CmdletBinding()]
    param()
    # A SCRIPTBLOCK, not a here-string, and the difference is that this is real code rather than
    # text that happens to look like it. Every mutant verdict in every run passes through these
    # lines, and as a string nothing ever examined them: PSScriptAnalyzer sees a string literal,
    # the parser sees nothing until AddScript at runtime, and a test can only string-match. A typo
    # here failed no lint, no parse and no test, and surfaced on a consumer's machine mid-run as
    # "the covering tests produced no result" -- a message pointing at the mutant rather than at
    # this. The version-resolution bug that produced #16 lived in this script's predecessor.
    #
    # Written this way the parser checks it when this file is dot-sourced, the analyzer lints it,
    # and tests/Pester.Tests.ps1 asserts that it parses.
    #
    # The early-stop decision moved INSIDE the block for the same reason. It was briefly a line
    # the caller concatenated in or left out, which made the thing handed to the runspace
    # assembled text again -- one conditional away from the problem this fixes. It is now a
    # parameter the child reads, so there is exactly one script and it is always the same one.
    $sb = ${function:Invoke-PSMutationChild}
    # Returned as a SCRIPTBLOCK; the runner stringifies at the boundary where the runspace needs
    # text. Handing back .ToString() here looked equivalent and is not: a caller can only get the
    # code back by re-creating it, and a re-created block has no file association, so nothing it
    # executes is attributed to these lines. Coverage sat at 98.95% with the body untested
    # precisely because the only way to run it was through a copy.
    return $sb
}

function Invoke-PSMutationChild {
    # The body a mutant -- or a proof (#254) -- runs in a worker runspace. Its TEXT is what runs there:
    # Get-PSMutationWarmPesterScript hands this function's own scriptblock to the runner, which
    # stringifies it at the boundary. A function rather than a block inside one, so it is measured,
    # linted and tested as the unit it is.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        $tests, $recordAllKillers, [string]$sandboxRoot,
        # Run only the tests by these names (#254) -- the ones that killed a mutant's neighbours,
        # or the ones a proof asks about -- rather than the whole files. Empty runs everything.
        [string[]]$filter = @()
    )
    # Every module loaded from THIS worker's sandbox is removed first (#249). The runspace is
    # reused across mutants, and `Import-Module` without -Force hands back a module already
    # loaded -- measured: after the file changed, the second import returned the old code. So
    # a suite importing the code under test would run mutant 2 against mutant 1. Removed, the
    # next import reads the file as it is now; a module that defines a class reloads too.
    # Only the sandbox's: an installed dependency does not change between mutants, and
    # removing it would only make every run reload it.
    $own = $sandboxRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    Get-Module | Where-Object { $_.Path -and $_.Path.StartsWith($own, [System.StringComparison]::OrdinalIgnoreCase) } |
        Remove-Module -Force
    $c = New-PesterConfiguration
    $c.Run.Path = $tests
    $c.Run.PassThru = $true
    $c.Output.Verbosity = 'None'
    # Escaped: a filter is a -like pattern, and a test named with a bracket matches nothing
    # unescaped. Matched against the UNEXPANDED name, so a -ForEach test runs every case.
    $c.Filter.FullName = [string[]]@(foreach ($f in $filter) { [WildcardPattern]::Escape($f) })
    # SkipRemainingOnFailure stops the suite at the first failing test. A mutant only ever asks one
    # question -- does ANY test notice -- and once one has, every test after it is work whose
    # outcome cannot change the verdict. Measured against a killed mutant in this repo's sibling: a
    # 2.03s covering suite finishes in 0.34s, 83% less, with the result identical. A SURVIVOR is
    # unaffected by construction: nothing fails, so nothing is skipped.
    #
    # Set only when the loaded Pester HAS the property. It arrived in Pester 5.3.0 -- measured, not
    # looked up: 5.2.0 does not carry it and 5.3.0 does -- so the guard exists for Pester 5.2.x and
    # nothing else. Assigning a property that does not exist would fail the whole run for a speed
    # optimisation, on a version this module still promises to support.
    if (-not $recordAllKillers -and $c.Run.PSObject.Properties['SkipRemainingOnFailure']) {
        $c.Run.SkipRemainingOnFailure = 'Run'
    }
    $r = Invoke-Pester -Configuration $c
    # ExpandedName, not Name: a -ForEach case is one name and many tests, and a killer nobody
    # can tell apart from its siblings is not an answer to "which test killed this".
    #
    # Ran is how many tests reached a verdict (#251). A file whose discovery a mutant ended --
    # `exit`, `break` or `return` reached at the top of it, or in a Describe body -- loses its
    # tests silently, and Pester calls a run of none 'Passed'.
    #
    # Named twice more by the UNEXPANDED path a filter matches (#254): the tests that failed,
    # which the runner tries first on later mutants, and the tests that passed -- a proof trusts
    # a name that passed and did not fail.
    #
    # foreach STATEMENTS, which iterate zero times over a list that is not there. Measured on 6.1.0, a
    # green run's Failed is an empty collection rather than $null -- but a pipeline over $null would
    # run once, and nothing here should rest on which a given Pester returns.
    [pscustomobject]@{
        Result = [string]$r.Result; Ran = $r.PassedCount + $r.FailedCount
        Killers = @(foreach ($t in $r.Failed) { $t.ExpandedName })
        FailedPath = @(@(foreach ($t in $r.Failed) { $t.Path -join '.' }) | Select-Object -Unique)
        PassedPath = @(@(foreach ($t in $r.Passed) { $t.Path -join '.' }) | Select-Object -Unique)
    }
}
