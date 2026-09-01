<#
.SYNOPSIS
    Execution engine for the PowerShell mutation runner - baseline, candidate
    selection, and per-mutant Pester runs. Operates entirely on SANDBOX paths
    (see PSMutation.Sandbox.ps1); tracked source is never touched.

.DESCRIPTION
    Depends on PSMutation.Operators.ps1 for candidates and PSMutation.Pester.ps1 for the
    child runspace's import contract. Each function is small and single-purpose so
    every unit stays under the complexity ceiling. Each mutant's covering tests run in a
    cancellable runspace under a wall-clock timeout: the loop-condition guard is a speed
    optimisation that avoids obviously-doomed condition mutants, but the timeout is the real
    safety net -- a mutated loop *body* can still make a guarded loop never terminate, and
    Stop() interrupts it so the run never hangs.

    Mutants are dispatched across a pool of WORKERS, each with its own sandbox copy and its own
    Pester-loaded runspace. A serial run is a pool of one through the same scheduler rather than
    a separate path, and finished mutants are retired in candidate order, so the report does not
    depend on which worker happened to finish first.
#>

function Invoke-PSMutationBaseline {
    <#
    .SYNOPSIS
        Run the suite once (green-gate) and capture per-file covered line numbers,
        so we only mutate lines a test actually exercises (Stryker's perTest idea).
    .OUTPUTS
        @{ Passed = <bool>; DurationSeconds = <double>; CoveredLines = @{ file = HashSet[int] };
           FailedTest = <string[]> }
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$TestPath,
        # AllowEmptyCollection: a -ChangedFile run over a docs-only pull request has nothing to
        # mutate and still needs its green gate. A mandatory [string[]] refuses an empty array
        # outright, which turned that ordinary case into a binding failure.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        # Where Pester's coverage XML goes. Mandatory rather than defaulted to temp: the sandbox is
        # the one directory this run owns and disposes of, and a default would put the file back in
        # shared temp for any caller who forgot.
        [Parameter(Mandatory)] [string]$SandboxRoot,
        # Instrument for coverage. OFF by default, because the green gate is what every run needs
        # and the covered lines are what only some do -- see Test-PSMutationCoverageNeeded. A
        # baseline without it returns an empty CoveredLines, which is the true answer: nothing was
        # measured. It must not then be handed to a filter, and one decision drives both.
        [switch]$Coverage
    )

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $cfg.CodeCoverage.Enabled = [bool]$Coverage
    $cfg.CodeCoverage.Path = $MutateFiles
    # Coverage is read from the RESULT OBJECT below; this file is never opened. The path exists
    # only because Pester writes one somewhere, and its default is a coverage.xml in the working
    # tree -- which is the thing to avoid.
    #
    # It goes in the SANDBOX, not temp. In temp it was "psmut-coverage-$PID.xml", which nothing
    # ever deleted: the startup sweep matches directories named psmut-sandbox-*, so it could not
    # match this file by construction, and they accumulated for the life of the machine -- 67 of
    # them on the box this was found on. The sandbox is already removed in the run's finally, so
    # putting it there makes the cleanup the one that already exists rather than a second one to
    # keep in step.
    #
    # It also stops a predictable write into world-writable temp, which is the same shape as the
    # sandbox path that was fixed in #95 -- lesser, because the content is coverage data rather
    # than source, but there is no reason to keep one after removing the other.
    $cfg.CodeCoverage.OutputPath = Join-Path $SandboxRoot 'coverage.xml'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Pester -Configuration $cfg
    $sw.Stop()

    # A foreach STATEMENT, not a pipeline, and that is the whole of a bug this uncovered. With the
    # tracer off Pester reports no CommandsExecuted, and `$null | ForEach-Object` runs its body
    # ONCE with $_ = $null -- so GetFullPath was handed an empty string and the run died inside
    # the baseline. Wrapping in @( ) does not help: @($null) has one element, which is $null.
    # `foreach ($x in $null)` iterates zero times, which is the answer this wants. Measured all
    # three; the numbers are 1, 1 and 0.
    #
    # It was unreachable while coverage was unconditional, which is why it sat here until the
    # tracer became optional.
    $covered = @{}
    foreach ($cmd in $result.CodeCoverage.CommandsExecuted) {
        $f = [System.IO.Path]::GetFullPath($cmd.File)
        if (-not $covered.ContainsKey($f)) { $covered[$f] = [System.Collections.Generic.HashSet[int]]::new() }
        [void]$covered[$f].Add([int]$cmd.Line)
    }

    return @{
        Passed          = ($result.Result -eq 'Passed')
        DurationSeconds = $sw.Elapsed.TotalSeconds
        CoveredLines    = $covered
        # Carried so the guard can NAME what broke, and say why. A red baseline is reported by
        # a gate that runs -Quiet, where the whole run prints one line -- so "not green", or
        # even a bare test name, sends the reader to reproduce a failure that by definition is
        # not happening on the machine they are standing on.
        #
        # The FIRST line only. A Pester message is an expectation, then the actual, then a
        # stack; the first line is the one that says what went wrong, and any later line reads
        # as a fact about nothing once separated from it.
        #
        # Split on \r?\n rather than on "`n": a CRLF message otherwise keeps a trailing
        # carriage return, which travels into an exception message and prints as a stray line
        # break in the middle of the gate's one line of output.
        FailedTest      = @($result.Failed | ForEach-Object {
                # ErrorRecord is a COLLECTION, not one record -- a test can fail for more than
                # one reason, and Pester hands back a List. Reading `.Exception.Message` off the
                # list itself works only by PowerShell's member enumeration, which yields the
                # inner value for a ONE-element list and NOTHING for a longer one. So the reason
                # came back '' exactly when a test had several errors, and the gate printed
                # "Failed: Some.Test -- ."
                #
                # That is the bare test name this whole field exists to improve on: a run reported
                # by a -Quiet gate prints one line, and a name with no reason sends the reader to
                # reproduce a failure that by definition is not happening on their machine.
                #
                # It reproduces under ErrorActionPreference = Stop, which is what CI sets and a
                # developer machine usually does not -- so it was invisible locally and red on
                # both legs. Taking [0] is the FIRST reason, matching the first-line rule below:
                # later errors are usually cascade from it.
                $record = @($_.ErrorRecord)[0]
                # And the first NON-EMPTY line of that record. A Pester message is an expectation,
                # then the actual, then a stack; index 1 would report "at <ScriptBlock>" as the
                # reason, which is a fact about nothing, and a leading blank line would report ''.
                $lines = @($record.Exception.Message -split "\r?\n" |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $why = ''
                if ($lines.Count -gt 0) { $why = $lines[0].Trim() }
                # NO dangling separator when there is nothing to say. A test can carry no error
                # record at all -- when a BeforeAll dies under ErrorActionPreference = Stop, Pester
                # marks every test in the block Failed and attaches the error to the CONTAINER, not
                # to the test. The name alone is then the honest answer; "Some.Test -- ." reads as
                # a reason that was lost rather than one that never existed.
                #
                # The container-level record is deliberately NOT reached for. In that case it holds
                # Pester's own break/continue guard text, which says nothing about the consumer's
                # failure -- the same "fact about nothing" the first-line rule above avoids.
                $why ? "$($_.ExpandedPath) -- $why" : [string]$_.ExpandedPath
            })
    }
}

function Assert-PSMutationBaselineGreen {
    # Refuse to mutate against a failing suite. Every mutant would "die" for the
    # reason the suite was already red, producing a perfect score that means nothing
    # -- the single most misleading result this tool could hand back.
    #
    # Lives beside Invoke-PSMutationBaseline, whose output it is the only reader of.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Baseline)
    if ($Baseline.Passed) { return }
    # Named, and capped at ten. A wholly broken suite would otherwise paste hundreds of names
    # into one exception and bury the first, which is the one most likely to explain the rest.
    $named = @($Baseline.FailedTest)
    $detail = ''
    if ($named.Count -gt 0) {
        $shown = @($named | Select-Object -First 10)
        $more = ''
        if ($named.Count -gt $shown.Count) { $more = " (and $($named.Count - $shown.Count) more)" }
        $detail = " Failed: $($shown -join '; ')$more."
    }
    throw "Baseline suite is not green - fix the tests before mutating.$detail"
}

function Test-PSMutantCovered {
    # True if a candidate's line was executed by the baseline run. Pure.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Candidate, [Parameter(Mandatory)] [hashtable]$CoveredLines)
    $f = [System.IO.Path]::GetFullPath($Candidate.File)
    return $CoveredLines.ContainsKey($f) -and $CoveredLines[$f].Contains([int]$Candidate.Line)
}

function Get-PSMutationRunBaseline {
    <#
    .SYNOPSIS
        The baseline this run will size its budget from -- measured, or the stand-in a preview uses.
    .DESCRIPTION
        A run must measure: it needs a green suite to mutate against and a duration to derive the
        per-mutant timeout from. A preview with no coverage filter to satisfy needs neither, and a
        suite run would buy it nothing.

        The stand-in is a FUNCTION rather than two lines inside an else, because its zeros are
        otherwise unobservable: nothing in a preview reads a duration, so every mutant of them
        survives a test that can only assert the preview did not throw. Returned from a named
        function, the contract -- no time taken, no coverage measured -- is something a test can
        state.

        It carries no Passed flag. A green verdict is the one thing this did not establish, and
        fabricating one here is exactly the "a number nobody measured, reported as one" failure
        the module exists to catch.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [switch]$Measure,
        [switch]$Coverage,
        [switch]$Quiet
    )
    if (-not $Measure) { return [pscustomobject]@{ DurationSeconds = 0.0; CoveredLines = @{} } }
    Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Banner' `
            -Text "`nPSMutant - PowerShell mutation testing (sandboxed)`n  Running baseline suite...")
    $baseline = Invoke-PSMutationBaseline -TestPath $Plan.AllTests -MutateFiles $Plan.Mutate `
        -SandboxRoot $SandboxRoot -Coverage:$Coverage
    Assert-PSMutationBaselineGreen -Baseline $baseline
    return $baseline
}

function ConvertTo-PSMutationDisplayPerFile {
    <#
    .SYNOPSIS
        The per-file tally with its paths made repo-relative, for anything a human reads.
    .DESCRIPTION
        Select-PSMutationCandidate works in the SANDBOX, so every File it reports is an absolute
        path under a temp directory whose name changes on every run. That is the right value to
        mutate and the wrong one to print or to persist: it cannot be matched against a checkout,
        it differs between two runs of the same commit, and it names a directory that is deleted
        before the reader sees it. It reached the report's `filesWithNoMutants` and the summary's
        uncovered caveat that way.

        Converted ONCE, here, rather than at each of the places that display it -- the candidates
        themselves keep their sandbox paths, because that is where the loop reads them from.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    return , @($PerFile | ForEach-Object {
            [pscustomobject]@{
                File       = (ConvertFrom-PSMutationSandboxPath -Path $_.File -SandboxRoot $SandboxRoot)
                Produced   = $_.Produced
                Kept       = $_.Kept
                ByOperator = $_.ByOperator
            }
        })
}

function Get-PSMutationCandidateByOperator {
    # One file's candidate counts, split by the operator that produced them.
    #
    # BOTH numbers per operator, because they answer different questions and only the pair
    # locates the fault. `Produced` says which operators matched the file at all -- zero across
    # the board means the file has nothing this module knows how to mutate, and no amount of
    # test-writing changes that. `Kept` says how many survived the coverage filter -- produced
    # but not kept means the mapped suite does not reach those lines, which IS a test problem.
    # Reported as one number, a file scoring a vacuous 100% looks the same either way.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Produced,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Kept
    )
    $byOp = [ordered]@{}
    foreach ($c in $Produced) {
        if (-not $byOp.Contains($c.Operator)) { $byOp[$c.Operator] = @{ Produced = 0; Kept = 0 } }
        $byOp[$c.Operator].Produced++
    }
    # No guard on the key: Kept is a subset of Produced by construction, so a missing key here
    # would mean the caller passed two unrelated sets, which is a fault to surface rather than
    # to absorb into a zero.
    foreach ($c in $Kept) { $byOp[$c.Operator].Kept++ }
    return $byOp
}

function Select-PSMutationCandidate {
    # Enumerate candidates across the mutate files, keeping only covered ones (opt), and
    # report what that removed.
    #
    # Returns BOTH, rather than only the survivors, because the coverage filter can empty a
    # whole mutate file and the score then answers for a smaller set than the config asked
    # for -- upward, and silently. It fires the moment a file joins `mutate` before its tests
    # exist, or a refactor stops a suite exercising a module. The per-file tally is the only
    # place the pre-filter count still exists; recomputing it later would mean parsing every
    # file a second time.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # AllowEmptyCollection, like the baseline's: a -ChangedFile run over a docs-only pull
        # request has no file to enumerate, and that is an ordinary outcome rather than a
        # binding failure. It yields no candidates, which is the true answer.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        [Parameter(Mandatory)] [string[]]$Operators,
        [bool]$CoveredLinesOnly,
        $CoveredLines
    )
    $out = [System.Collections.Generic.List[object]]::new()
    $perFile = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $MutateFiles) {
        $produced = @(Get-PSMutationCandidate -Path $file -Operators $Operators)
        $kept = @($produced | Where-Object { -not $CoveredLinesOnly -or (Test-PSMutantCovered -Candidate $_ -CoveredLines $CoveredLines) })
        foreach ($c in $kept) { $out.Add($c) }
        $perFile.Add([pscustomobject]@{ File = $file; Produced = $produced.Count; Kept = $kept.Count
                ByOperator = (Get-PSMutationCandidateByOperator -Produced $produced -Kept $kept)
            })
    }
    return [pscustomobject]@{ Candidates = $out.ToArray(); PerFile = $perFile.ToArray() }
}

# The outcomes this module understands from a covering-test run. Pester's run-level result
# supplies 'Passed' and 'Failed'; 'TimedOut' is minted here by Stop-PSMutationJob. Anything
# outside this set is refused rather than scored -- see Get-PSMutationVerdict.
$script:PSMutationKnownOutcomes = @('Passed', 'Failed', 'TimedOut')

function Start-PSMutantEvaluation {
    <#
    .SYNOPSIS
        Splice one mutant into ITS WORKER'S sandbox file and set the covering tests running,
        without waiting for them.
    .DESCRIPTION
        Half of what used to be one synchronous function, and the split is what makes parallel
        evaluation possible: the caller can have one of these in flight per worker and collect
        whichever finishes first.

        There is exactly ONE execution path. A serial run is a pool of one worker through this
        same pair, rather than a second, simpler route -- two paths would be two places for the
        verdict to be decided, and they would disagree in whichever case nobody tests.

        The ORDER of the last two statements is load-bearing. The shell is obtained BEFORE the
        file is written, so a Pester import that fails leaves the sandbox exactly as it was
        found. The old shape wrote first and leaned on a `finally` to undo it; this needs no
        undo at all.
    .OUTPUTS
        The in-flight job: the worker it belongs to, its handle, and everything needed to
        collect it and put the file back.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside the throwaway sandbox; tracked source is never touched.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # The mutant addressed in the WORKER'S sandbox -- this is the file that gets written.
        [Parameter(Mandatory)] $Candidate,
        # The same mutant addressed in the PRIMARY sandbox, which is what the report says. Carried
        # because a row must not name a per-worker temp directory: which worker ran a mutant is
        # scheduling, and scheduling must not be visible in the answer.
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [string]$MutatedContent,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$OriginalContent,
        [Parameter(Mandatory)] [string[]]$CoveringTests,
        [Parameter(Mandatory)] [int]$WorkerId,
        [switch]$RecordAllKillers
    )
    $ps = Get-PSMutationWarmShell -WorkerId $WorkerId
    $ps.Commands.Clear()
    [void]$ps.AddScript((Get-PSMutationWarmPesterScript).ToString()).AddParameter('tests', $CoveringTests).
        AddParameter('recordAllKillers', [bool]$RecordAllKillers)
    [System.IO.File]::WriteAllText($Candidate.File, $MutatedContent)
    # The clock starts at BeginInvoke rather than when the candidate was queued, so a mutant's
    # measured seconds are what it spent running and not what it spent waiting for a worker.
    # The per-mutant budget is a statement about the child, and a queue time folded into it would
    # turn a busy pool into a run full of timeouts.
    return [pscustomobject]@{
        WorkerId = $WorkerId; Shell = $ps; Async = $ps.BeginInvoke()
        Candidate = $Candidate; Source = $Source; Index = $Index
        OriginalContent = $OriginalContent
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Stop-PSMutationJob {
    # Cut off a mutant that outlived its budget, and discard the runspace it was using.
    #
    # Stop() leaves a runspace unusable, so it is discarded rather than handed to the next mutant.
    # A timeout is rare; paying a cold start after one is the cheap half of the trade -- and it is
    # now one WORKER'S cold start rather than the pool's.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops an in-process pipeline; there is no system state to confirm.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Job)
    $Job.Shell.Stop()
    Close-PSMutationWarmRunspace -WorkerId $Job.WorkerId
    # No killers on a timeout, and an EMPTY list rather than none: the caller reads .Killers
    # unconditionally, and a missing property would make "nothing killed it" and "we never
    # looked" the same answer at the one point where they differ most.
    return [pscustomobject]@{ Result = 'TimedOut'; Killers = @() }
}

function Receive-PSMutationJob {
    # The finished child's verdict.
    #
    # A child that returned no verdict proved nothing about the mutant. Handing that back would
    # classify it Killed -- anything but 'Passed' is a kill -- so a broken child reads as a
    # perfect score. That is exactly how the Pester version collision stayed invisible for so
    # long. Fail the run instead of scoring it.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Job)
    $result = $Job.Shell.EndInvoke($Job.Async) | Select-Object -Last 1
    $outcome = [string]$result.Result
    if (-not $outcome) {
        $why = Get-PSMutationRunspaceError -Runspace $Job.Shell
        Close-PSMutationWarmRunspace -WorkerId $Job.WorkerId
        throw "The covering tests produced no result: $why"
    }
    return [pscustomobject]@{ Result = $outcome; Killers = @($result.Killers) }
}

function Get-PSMutationVerdict {
    <#
    .SYNOPSIS
        What one covering-test outcome says about the mutant. Pure.
    .OUTPUTS
        'Killed' | 'Survived' | 'TimedOut' -- Survived only if the suite still fully
        passes. A timeout scores WITH the kills, because a mutant that hangs the suite is a
        fault, but it is reported apart from them: "the suite proved this fault is caught"
        and "the suite hung and we assumed so" are different claims and only the first is
        evidence. Folded together, a suite that is merely too slow inflates the score.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Run)
    $outcome = $Run.Result
    # The verdict and the killers travel together from here, so a caller cannot record one
    # without the other. Survived and TimedOut carry an empty list rather than none, because
    # "nothing killed it" and "we did not look" must not be the same value.
    if ($outcome -eq 'Passed') { return [pscustomobject]@{ Status = 'Survived'; Killers = @() } }
    if ($outcome -eq 'TimedOut') { return [pscustomobject]@{ Status = 'TimedOut'; Killers = @() } }
    # A CLOSED vocabulary. Everything above is a value this module understands; anything
    # else is an outcome nobody modelled, and the fall-through below scores it Killed --
    # toward the flattering answer, silently, with no test failing.
    #
    # The collapse is correct for every shipping Pester, whose run-level result is
    # two-valued. The risk is a WIDENED vocabulary rather than a renamed one: a rename
    # fails loudly at the baseline, which compares against the literal 'Passed', but a
    # third state that coexists with it leaves the baseline green and scores every mutant
    # returning it as killed. That is a perfect score over tests that proved nothing --
    # the same shape as the Pester-collision bug, reached through a door its fix left open.
    if ($outcome -notin $script:PSMutationKnownOutcomes) {
        throw ("The covering tests returned an outcome this version of PSMutant does not " +
            "model: '$outcome'. Known outcomes are $($script:PSMutationKnownOutcomes -join ', '). " +
            "Scoring it would guess, and the guess flatters the score.")
    }
    return [pscustomobject]@{ Status = 'Killed'; Killers = @($Run.Killers) }
}

function Complete-PSMutantEvaluation {
    <#
    .SYNOPSIS
        Collect one dispatched mutant's verdict and put its sandbox file back.
    .DESCRIPTION
        -Expired is the SCHEDULER'S decision, not this function's, because only the scheduler
        knows what else is in flight: it waits on every handle at once and hands back whichever
        it found finished or past its budget. Asking here would mean a second clock reading and
        a second answer to a question already settled.
    .OUTPUTS
        @{ Status; Killers } -- see Get-PSMutationVerdict.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside the throwaway sandbox; tracked source is never touched.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Job, [switch]$Expired)
    try {
        return Get-PSMutationVerdict -Run ($Expired ? (Stop-PSMutationJob -Job $Job) : (Receive-PSMutationJob -Job $Job))
    }
    finally {
        # Still restored per mutant, and deliberately. The next mutant on this worker writes the
        # whole file anyway, so this write is redundant between two mutants of the SAME file in
        # the SAME worker -- but it is what makes the pair self-contained: a mutant that throws,
        # or a run killed here, leaves the sandbox as it found it.
        [System.IO.File]::WriteAllText($Job.Candidate.File, $Job.OriginalContent)
    }
}

function Get-PSMutationProgressLine {
    # One per-mutant progress line. Pure, and emitted as the loop goes rather than
    # collected: a run of several hundred mutants takes minutes, and a progress report
    # delivered at the end is not a progress report.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([int]$Index, [int]$Total, $Result, [string]$DisplayFile)
    $survived = $Result.Status -eq 'Survived'
    $glyph = $survived ? '.' : 'x'
    $role = $survived ? 'Warn' : 'Muted'
    return New-PSMutationLine -Role $role -Data $Result `
        -Text ("  [{0}/{1}] {2} {3}:{4} {5}" -f $Index, $Total, $glyph, $DisplayFile, $Result.Line, $Result.Description)
}

function Get-PSMutationStalledFault {
    <#
    .SYNOPSIS
        The fault, if any, when one mutant's wall clock says the run stopped running.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$MutantSeconds,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [int]$Total
    )
    # The precise version of the run bound, and the one that fires within a single mutant instead
    # of at the end of a budget nobody wants to wait out. Every mutant is already bounded: the
    # child is given TimeoutSeconds and its handle is waited on for exactly that. So a mutant
    # whose WALL CLOCK is far past its own budget did not run slowly -- the mechanism that was
    # supposed to stop it did not fire.
    #
    # That is what an overnight hang looks like from inside: 875 minutes elapsed against 333
    # seconds of CPU, because the machine slept mid-run and the handle never came back. Comparing
    # the two numbers names the cause; a total-run deadline only reports the symptom, hours later.
    #
    # x4 and a +30s floor, so an ordinary overrun cannot trip it. A timed-out mutant already
    # costs its full budget plus the cost of discarding and rebuilding the runspace, and a loaded
    # machine can stretch that; four times the budget is not something a working run reaches.
    $limit = [math]::Max(($TimeoutSeconds * 4), ($TimeoutSeconds + 30))
    if ($MutantSeconds -le $limit) { return $null }
    return ("Mutant $Index of $Total took $([int]$MutantSeconds)s against a per-mutant budget of " +
        "${TimeoutSeconds}s. The bound on the child did not fire, which is what a suspended or " +
        'wedged run looks like rather than a slow one -- a machine that slept mid-run leaves the ' +
        'handle it was waiting on never signalling. Stopping here so the partial report says how ' +
        'far the run got.')
}

function Get-PSMutationOverBudgetFault {
    <#
    .SYNOPSIS
        The fault, if any, when the whole run has outlived its wall-clock budget.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$ElapsedSeconds,
        [Parameter(Mandatory)] [int]$DeadlineSeconds,
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [int]$Total
    )
    # A pure decision rather than an inline comparison on a stopwatch, so its BOUNDARY can be
    # tested. Written inline it could not: elapsed wall-clock never lands exactly on the budget,
    # so nothing could tell -gt from -ge and self-mutation said so.
    if ($DeadlineSeconds -le 0) { return $null }
    if ($ElapsedSeconds -le $DeadlineSeconds) { return $null }
    return ("This run passed its wall-clock budget of ${DeadlineSeconds}s after $Index of " +
        "$Total mutant(s). Every mutant is bounded and the run was not, so a suspended or wedged " +
        'run used to sit there indefinitely and look exactly like a slow one. Raise ' +
        'runTimeoutSeconds, or set it to 0 if something else already kills wedged runs.')
}

function Get-PSMutationCoveringSuite {
    <#
    .SYNOPSIS
        The test files that cover one mutate file: its own mapping, or the whole suite.
    #>
    # BOTH types, and the second is the price of the comma-wrap: `, $x` is statically an
    # Object[] wrapper that PowerShell unrolls on return, so PSUseOutputTypeCorrectly
    # contradicts a bare [string[]]. Declaring only [object[]] would satisfy the analyzer
    # and stop documenting what a caller actually receives.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [hashtable]$TestsByFile,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$AllTests
    )
    # ONE place, because the loop and the verbose trace both need the answer and a second copy of
    # a fallback is a second thing to get wrong -- the trace's copy survived its own mutant, since
    # nothing asserted what it printed.
    # Comma-wrapped for the reason the report's two sibling collectors are: an empty result
    # would unroll to $null, and this feeds a -TestPath that would then bind nothing.
    $suite = [string[]]@($TestsByFile.ContainsKey($File) ? $TestsByFile[$File] : $AllTests)
    return , $suite
}

function New-PSMutationResultRow {
    <#
    .SYNOPSIS
        One mutant's result as the report publishes it. Pure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure projection: returns an object, changes no state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] $Verdict,
        [Parameter(Mandatory)] [string]$DisplayFile
    )
    return [pscustomobject]@{
        # Function is carried so an equivalence declaration can address this mutant by
        # the function it lives in rather than by a line number, which moves whenever
        # anything above the mutant is edited and takes the declaration stale with it.
        #
        # This row is the report's published shape. Adding a field widens what every
        # consumer may depend on, so a test asserts the exact list: widening should
        # cost a deliberate edit, not happen as a side effect of an internal rename.
        #
        # Which WORKER ran the mutant is deliberately absent. It is scheduling, it differs
        # between two runs that must be identical, and a field that changes with the machine
        # is one a consumer would eventually diff.
        Id = $Candidate.Id; Function = $Candidate.Function; File = $DisplayFile; Line = $Candidate.Line
        Operator = $Candidate.Operator; Description = $Candidate.Description; Status = $Verdict.Status
        # The tests that noticed. TRUNCATED under the default configuration and complete under
        # -RecordAllKillers, which is stated at run level rather than inferred from the length
        # of this list.
        #
        # Truncated is not the same as "exactly one", measured: over 118 killed mutants the
        # default still reported more than one killer for 20 of them, because several tests can
        # be marked failed before Pester's early stop takes hold. So the length here says
        # nothing about how many tests really kill a mutant -- the same run with every killer
        # recorded found 85. Read killersComplete, never the count.
        KilledBy = @($Verdict.Killers)
    }
}

function Get-PSMutationFreeWorker {
    # The lowest-numbered worker with nothing in flight, or -1 when every worker is busy. Pure.
    #
    # LOWEST rather than any, so a serial run and a parallel one dispatch the same way for as
    # long as the pool is idle, and so the choice is a fact about the schedule rather than about
    # whichever enumeration order a hashtable felt like today.
    [OutputType([int])]
    [CmdletBinding()]
    # [AllowNull()] beside the mandatory, and it is not decoration. An IDLE POOL is an array whose
    # every element is $null, and PowerShell's mandatory check unwraps a single-element collection
    # before testing it: a one-worker pool with nothing in flight is `@($null)`, which binds as
    # null and is refused. So the serial case -- the only one every existing test exercises --
    # failed at the first dispatch while every parallel one bound fine.
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InFlight)
    for ($i = 0; $i -lt $InFlight.Count; $i++) {
        if ($null -eq $InFlight[$i]) { return $i }
    }
    return -1
}

function Get-PSMutationJobState {
    <#
    .SYNOPSIS
        'Complete', 'Expired' or 'Running' for one in-flight mutant. Pure.
    .DESCRIPTION
        Completion is asked FIRST. A child that finished a hair before its budget ran out has
        a verdict, and reading the clock first would throw that verdict away and score the
        mutant Killed on a timeout it did not have -- toward the flattering answer, which is
        the direction this module refuses to guess in.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$Completed,
        [Parameter(Mandatory)] [double]$ElapsedSeconds,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )
    if ($Completed) { return 'Complete' }
    if ($ElapsedSeconds -ge $TimeoutSeconds) { return 'Expired' }
    return 'Running'
}

function Get-PSMutationWaitBudget {
    <#
    .SYNOPSIS
        How long the scheduler may block before it MUST look again, in MILLISECONDS: the least
        budget any in-flight mutant has left. Pure.
    .DESCRIPTION
        The least, not the average and not a fixed poll interval, because a mutant is cut off
        on its OWN budget and one that expires while the scheduler is asleep on somebody else's
        clock has overrun by however long the nap was. A fixed interval would answer the same
        question by waking up constantly and would still be wrong at the boundary.

        Floored at 1ms rather than 0: a zero timeout makes WaitAny a non-blocking poll, so a
        mutant already past its budget would spin the scheduler at full speed for as long as it
        takes the sweep to reach it.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]]$ElapsedSeconds,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )
    # The OLDEST in-flight mutant has the least budget left, so this asks for a maximum rather
    # than tracking a minimum in a loop -- and that is not tidiness. `if ($left -lt $least)` and
    # `-le` produce identical output for every input, because assigning an equal value changes
    # nothing: an equivalent mutant that would have to be argued for in the config rather than
    # killed by a test. Asking for a maximum has no boundary to get wrong.
    #
    # The 0.0 is what makes an empty list answer the whole budget rather than $null, and it is
    # observable: raise it and a scheduler with nothing in flight waits for less than it should.
    $oldest = (@($ElapsedSeconds) + @(0.0) | Measure-Object -Maximum).Maximum
    return [int][math]::Max(1, [math]::Ceiling(($TimeoutSeconds - $oldest) * 1000))
}

function Wait-PSMutationWorker {
    <#
    .SYNOPSIS
        Block until an in-flight mutant finishes or the earliest per-mutant budget runs out.
    .DESCRIPTION
        There is ALWAYS something in flight when this is called, and that is an invariant of
        the loop rather than a hope. Every candidate is in exactly one of four states -- not
        yet dispatched, in flight, parked, retired -- and the loop only reaches here with at
        least one not retired. The next one to retire is not parked, because retirement drains
        every parked mutant whose turn has come; so it is either in flight, or not yet
        dispatched -- and in the second case dispatch stopped because every worker was busy.
        Both leave something in flight.

        It is not guarded, deliberately. A guard for a state the loop cannot reach is a branch
        no test can distinguish from its own absence, and it would quietly turn a future
        scheduling bug into a spin instead of an exception.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Schedule, [Parameter(Mandatory)] $Context)
    $jobs = @($Schedule.InFlight | Where-Object { $null -ne $_ })
    $budget = Get-PSMutationWaitBudget -TimeoutSeconds $Context.TimeoutSeconds `
        -ElapsedSeconds @($jobs | ForEach-Object { $_.Clock.Elapsed.TotalSeconds })
    [void][System.Threading.WaitHandle]::WaitAny(
        [System.Threading.WaitHandle[]]@($jobs | ForEach-Object { $_.Async.AsyncWaitHandle }), $budget)
}

function Start-PSMutationWorkerJob {
    # Dispatch the next candidate to one idle worker, addressed inside THAT worker's sandbox copy.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside the throwaway sandbox; tracked source is never touched.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Schedule,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$WorkerId
    )
    $c = $Context.Candidates[$Schedule.Next]
    # One read per FILE, not per mutant. A file contributes many candidates -- 125 for the largest
    # in this repo's sibling -- and every one of them re-read the same unchanged bytes to splice
    # against. Keyed on the PRIMARY path, so every worker shares one read: the copies are byte
    # identical by construction, and reading each worker's own copy would be the same bytes off
    # disk once per worker to produce strings that are equal.
    if (-not $Context.Originals.ContainsKey($c.File)) {
        $Context.Originals[$c.File] = [System.IO.File]::ReadAllText($c.File)
    }
    $content = $Context.Originals[$c.File]
    $root = $Context.Roots[$WorkerId]
    # A COPY, because the candidate list is shared across workers and re-rooting in place would
    # point every later worker at whichever sandbox happened to run it last.
    $exec = $c.PSObject.Copy()
    $exec.File = Get-PSMutationWorkerPath -Path $c.File -SandboxRoot $Context.SandboxRoot -WorkerRoot $root
    $covering = Get-PSMutationCoveringSuite -File $c.File -TestsByFile $Context.TestsByFile -AllTests $Context.AllTests
    # The TESTS are re-rooted too, and that is the half that is easy to forget. A worker running
    # the primary sandbox's test files would dot-source the primary sandbox's source, so every
    # mutant would run against unmutated code and survive -- a score of zero, arrived at silently.
    $tests = [string[]]@($covering | ForEach-Object {
            Get-PSMutationWorkerPath -Path $_ -SandboxRoot $Context.SandboxRoot -WorkerRoot $root
        })
    return Start-PSMutantEvaluation -Candidate $exec -Source $c -Index $Schedule.Next `
        -MutatedContent (Set-PSMutationText -Content $content -Candidate $c) -OriginalContent $content `
        -CoveringTests $tests -WorkerId $WorkerId -RecordAllKillers:$Context.RecordAllKillers
}

function Start-PSMutationDispatch {
    # Hand the next candidate to every idle worker, until one of the two runs out.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside the throwaway sandbox; tracked source is never touched.')]
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Schedule, [Parameter(Mandatory)] $Context)
    while ($Schedule.Next -lt $Context.Total) {
        $w = Get-PSMutationFreeWorker -InFlight $Schedule.InFlight
        if ($w -lt 0) { break }
        $Schedule.InFlight[$w] = Start-PSMutationWorkerJob -Schedule $Schedule -Context $Context -WorkerId $w
        $Schedule.Next++
    }
}

function Get-PSMutationFinishedMutant {
    <#
    .SYNOPSIS
        One finished mutant, collected: its published row and the seconds it took.
    .DESCRIPTION
        The seconds are carried BESIDE the row rather than in it. The row's field list is the
        report's contract, and a wall clock is a fact about this run on this machine rather than
        about the mutant -- putting it in the row would make two identical runs produce different
        reports.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Job,
        [Parameter(Mandatory)] [string]$State,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$SandboxRoot
    )
    $verdict = Complete-PSMutantEvaluation -Job $Job -Expired:($State -eq 'Expired')
    return [pscustomobject]@{
        Row = New-PSMutationResultRow -Candidate $Job.Source -Verdict $verdict `
            -DisplayFile (ConvertFrom-PSMutationSandboxPath -Path $Job.Source.File -SandboxRoot $SandboxRoot)
        Seconds = $Job.Clock.Elapsed.TotalSeconds
    }
}

function Complete-PSMutationSweep {
    # Collect every worker whose mutant has finished or run out of budget, and free its slot.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Schedule, [Parameter(Mandatory)] $Context)
    # Over the JOBS, not over slot indices, and the job says which slot it came from. Written as a
    # `for` over `0..Count-1` the bound is a boundary nothing can observe: reading one slot past
    # the end yields $null, which the idle-slot guard skips, so `-lt` and `-le` produce identical
    # output -- an equivalent mutant that would have to be argued for rather than killed.
    foreach ($job in @($Schedule.InFlight | Where-Object { $null -ne $_ })) {
        $state = Get-PSMutationJobState -Completed $job.Async.IsCompleted `
            -ElapsedSeconds $job.Clock.Elapsed.TotalSeconds -TimeoutSeconds $Context.TimeoutSeconds
        if ($state -eq 'Running') { continue }
        # Freed BEFORE collecting, so a collection that throws cannot leave a slot pointing at a
        # job nobody will ever wait on again.
        $Schedule.InFlight[$job.WorkerId] = $null
        $Schedule.Parked[$job.Index] = Get-PSMutationFinishedMutant -Job $job -State $state -SandboxRoot $Context.SandboxRoot
    }
}

function Get-PSMutationLoopFault {
    <#
    .SYNOPSIS
        The fault, if any, that should stop the run after one mutant is retired.
    .DESCRIPTION
        Sequenced in ONE place because the two are different questions and the order is the
        answer's quality: a mutant whose own clock says its bound never fired names the cause,
        and a run past its total budget names only the symptom.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$MutantSeconds,
        [Parameter(Mandatory)] [double]$ElapsedSeconds,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [int]$DeadlineSeconds,
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [int]$Total
    )
    $stalled = Get-PSMutationStalledFault -MutantSeconds $MutantSeconds -TimeoutSeconds $TimeoutSeconds `
        -Index $Index -Total $Total
    if ($stalled) { return $stalled }
    return Get-PSMutationOverBudgetFault -ElapsedSeconds $ElapsedSeconds -DeadlineSeconds $DeadlineSeconds `
        -Index $Index -Total $Total
}

function Complete-PSMutationRetirement {
    <#
    .SYNOPSIS
        Record every finished mutant whose turn has come, IN CANDIDATE ORDER.
    .DESCRIPTION
        Workers finish out of order -- a killed mutant stops at the first failing test and a
        survivor runs the whole suite, which is a 6x spread measured on this repo's sibling --
        and a report whose row order depended on that would differ between two runs of the same
        config. So a finished mutant is parked under its candidate index and only recorded once
        every mutant before it has been.

        That is one mechanism answering three requirements at once. The report is deterministic,
        the progress line stays a monotonic [n/total] rather than jumping about, and the partial
        report an interrupted run writes is a genuine PREFIX of the full one instead of whichever
        mutants happened to land first. Nothing waits on it: at most one worker-count's worth of
        mutants can be finished and unrecorded, and they are still finished.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Schedule, [Parameter(Mandatory)] $Context)
    while ($Schedule.Parked.ContainsKey($Schedule.Retired)) {
        $done = $Schedule.Parked[$Schedule.Retired]
        $Schedule.Parked.Remove($Schedule.Retired)
        $Schedule.Retired++
        $Context.Sink.Add($done.Row)
        Write-PSMutationOutput -Quiet:$Context.Quiet -Lines (Get-PSMutationProgressLine -Index $Schedule.Retired `
                -Total $Context.Total -Result $done.Row -DisplayFile (Split-Path $done.Row.File -Leaf))
        # Not passed -Quiet: a non-interactive host renders no progress at all, so there is
        # nothing for -Quiet to silence, and a local run keeps the one signal that tells a hung
        # run from a slow one even when the log is off.
        Write-PSMutationProgress -Index $Schedule.Retired -Total $Context.Total -Activity 'Evaluating mutants'
        # Checked AFTER the row is in the sink. A run stopped here has already recorded
        # everything it finished, so the partial report written on the way out says how far it
        # got -- which is the difference between a diagnosable stop and the zero-byte report an
        # overnight hang leaves.
        $fault = Get-PSMutationLoopFault -MutantSeconds $done.Seconds -TimeoutSeconds $Context.TimeoutSeconds `
            -ElapsedSeconds $Context.RunClock.Elapsed.TotalSeconds -DeadlineSeconds $Context.DeadlineSeconds `
            -Index $Schedule.Retired -Total $Context.Total
        if ($fault) { throw $fault }
    }
}

function Invoke-PSMutationLoop {
    <#
    .SYNOPSIS
        Evaluate every candidate across one or more workers; return the result rows.
    .DESCRIPTION
        A serial run is a pool of ONE worker through this same scheduler, not a separate simpler
        route. Two paths would be two places where a verdict is decided, and they would disagree
        in whichever case nobody tests -- so `workers` changes how many mutants are in flight and
        nothing else. The report is identical either way, which tests/EndToEnd.Tests.ps1 asserts
        by running the same fixture both ways and comparing.

        Each worker owns its own sandbox copy and its own Pester-loaded runspace, so nothing is
        shared but the read-only candidate list. That is what the isolation rests on: two workers
        writing the same file would splice one mutant over another and score both against the
        wrong source.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        # Empty is a legitimate input, not an error: a mutate file may contribute no
        # covered candidates, and a recheck run whose previous survivors are all dead
        # has nothing left to evaluate. Both should report zero, not throw.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$TestsByFile,
        [Parameter(Mandatory)] [string[]]$AllTests,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        # The caller's accumulator, so an INTERRUPTED run still has its rows.
        #
        # A run is long -- long enough that losing one to Ctrl-C or a cancelled CI job is an
        # ordinary event rather than an exceptional one -- and every row lived in a local list
        # that died with the loop. Handing the list in means the caller still holds whatever was
        # evaluated after the loop stops, however it stopped.
        #
        # MANDATORY rather than optional-with-a-fallback. An internal list used when none was
        # supplied would be a branch whose two arms produce identical output, which no test could
        # tell from its own absence -- the same reason -UnitTable is mandatory in the sibling.
        # AllowEmptyCollection because it is ALWAYS empty here: a mandatory parameter refuses an
        # empty collection, so without this the loop threw on every single call.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Sink,
        [string]$SandboxRoot,
        # The EXTRA sandboxes, one per additional worker; worker 0 mutates the primary sandbox.
        # The worker count is derived from this rather than given beside it, so there is no way
        # to ask for four workers and hand over two sandboxes.
        [AllowEmptyCollection()] [string[]]$WorkerSandbox = @(),
        [switch]$Quiet,
        [switch]$RecordAllKillers,
        # Wall-clock budget for the whole loop. Zero disables it. Checked as a mutant is RETIRED,
        # never inside one, so the mutant it stops after has already had its file restored. Other
        # workers may still be mid-flight with a file spliced -- their sandboxes are removed by
        # the run's own finally, which is the same guarantee that covers a Ctrl-C.
        [int]$DeadlineSeconds = 0
    )
    $roots = [string[]]@(@($SandboxRoot) + @($WorkerSandbox))
    $context = [pscustomobject]@{
        Candidates = $Candidates; Total = $Candidates.Count; Roots = $roots; SandboxRoot = $SandboxRoot
        TestsByFile = $TestsByFile; AllTests = $AllTests; TimeoutSeconds = $TimeoutSeconds
        RecordAllKillers = [bool]$RecordAllKillers; Quiet = [bool]$Quiet
        DeadlineSeconds = $DeadlineSeconds; Originals = @{}; Sink = $Sink
        RunClock = [System.Diagnostics.Stopwatch]::StartNew()
    }
    # Mutable, and a pscustomobject rather than a hashtable so the four fields are named at every
    # use. The counters have to live here rather than in locals: dispatch, sweep and retirement
    # each move them, and PowerShell would give each function its own copy of a local.
    $schedule = [pscustomobject]@{
        InFlight = [object[]]::new($roots.Count); Parked = @{}; Next = 0; Retired = 0
    }
    while ($schedule.Retired -lt $context.Total) {
        Start-PSMutationDispatch -Schedule $schedule -Context $context
        Wait-PSMutationWorker -Schedule $schedule -Context $context
        Complete-PSMutationSweep -Schedule $schedule -Context $context
        Complete-PSMutationRetirement -Schedule $schedule -Context $context
    }
    return , $Sink.ToArray()
}
