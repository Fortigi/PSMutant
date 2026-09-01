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

# How many mutants one runspace serves before it is rebuilt. Bounds any state a covering suite
# leaves behind: the saving is already 93% of the floor at this interval, so a larger number buys
# almost nothing and widens the window in which a leak could go unnoticed.
$script:PSMutationWarmRunspaceLifetime = 50

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
    if ($script:PSMutationWarmShell.ContainsKey($WorkerId)) {
        $script:PSMutationWarmShell[$WorkerId].Dispose()
        $script:PSMutationWarmRunspace[$WorkerId].Dispose()
    }
    # Removed rather than set to $null. A key whose value is $null still answers ContainsKey, so
    # the guard above would fire on the next close and dispose $null -- and Get-PSMutationWarmShell
    # would hand back nothing while believing it had a shell.
    $script:PSMutationWarmShell.Remove($WorkerId)
    $script:PSMutationWarmRunspace.Remove($WorkerId)
    $script:PSMutationWarmUses.Remove($WorkerId)
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
}

function Get-PSMutationWarmShell {
    # A PowerShell instance on a runspace that already has Pester loaded, belonging to one worker.
    [OutputType([powershell])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$WorkerId)
    if ($script:PSMutationWarmShell.ContainsKey($WorkerId) -and
        $script:PSMutationWarmUses[$WorkerId] -lt $script:PSMutationWarmRunspaceLifetime) {
        $script:PSMutationWarmUses[$WorkerId]++
        return $script:PSMutationWarmShell[$WorkerId]
    }
    Close-PSMutationWarmRunspace -WorkerId $WorkerId
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $shell = [PowerShell]::Create()
    $shell.Runspace = $rs
    [void]$shell.AddScript('param($pester) Import-Module $pester -Force -ErrorAction Stop').
        AddParameter('pester', (Get-PSMutationPesterPath))
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
        throw "Could not import Pester into the mutant runspace: $($_.Exception.Message)"
    }
    $shell.Commands.Clear()
    $script:PSMutationWarmRunspace[$WorkerId] = $rs
    $script:PSMutationWarmShell[$WorkerId] = $shell
    $script:PSMutationWarmUses[$WorkerId] = 1
    return $shell
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
    $sb = {
        param($tests, $recordAllKillers)
        $c = New-PesterConfiguration
        $c.Run.Path = $tests
        $c.Run.PassThru = $true
        $c.Output.Verbosity = 'None'
        # SkipRemainingOnFailure stops the suite at the first failing test. A mutant only ever asks
        # one question -- does ANY test notice -- and once one has, every test after it is work
        # whose outcome cannot change the verdict. Measured against a killed mutant in this repo's
        # sibling: a 2.03s covering suite finishes in 0.34s, 83% less, with the result identical.
        # A SURVIVOR is unaffected by construction: nothing fails, so nothing is skipped.
        #
        # Set only when the loaded Pester HAS the property. It arrived in Pester 5.3.0 -- measured,
        # not looked up: 5.2.0 does not carry it and 5.3.0 does -- so the guard exists for Pester
        # 5.2.x and nothing else. Assigning a property that does not exist would fail the whole run
        # for a speed optimisation, on a version this module still promises to support.
        if (-not $recordAllKillers -and $c.Run.PSObject.Properties['SkipRemainingOnFailure']) {
            $c.Run.SkipRemainingOnFailure = 'Run'
        }
        $r = Invoke-Pester -Configuration $c
        # ExpandedName, not Name: a -ForEach case is one name and many tests, and a killer nobody
        # can tell apart from its siblings is not an answer to "which test killed this".
        [pscustomobject]@{ Result = [string]$r.Result; Killers = @($r.Failed | ForEach-Object { $_.ExpandedName }) }
    }
    # Returned as a SCRIPTBLOCK; the runner stringifies at the boundary where the runspace needs
    # text. Handing back .ToString() here looked equivalent and is not: a caller can only get the
    # code back by re-creating it, and a re-created block has no file association, so nothing it
    # executes is attributed to these lines. Coverage sat at 98.95% with the body untested
    # precisely because the only way to run it was through a copy.
    return $sb
}
