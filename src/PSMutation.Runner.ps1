<#
.SYNOPSIS
    Execution engine for the PowerShell mutation runner - baseline, candidate
    selection, and per-mutant Pester runs. Operates entirely on SANDBOX paths
    (see PSMutation.Sandbox.ps1); tracked source is never touched.

.DESCRIPTION
    Depends on PSMutation.Operators.ps1 for candidates and PSMutation.Pester.ps1 for the
    child runspace's import contract. Each function is small and single-purpose so
    every unit stays under the complexity ceiling. Each mutant's covering tests run in a
    cancellable runspace under a wall-clock timeout (Invoke-PSBoundedPester): the loop-
    condition guard is a speed optimisation that avoids obviously-doomed condition
    mutants, but the timeout is the real safety net -- a mutated loop *body* can still
    make a guarded loop never terminate, and Stop() interrupts it so the run never hangs.
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
        [Parameter(Mandatory)] [string[]]$MutateFiles,
        # Where Pester's coverage XML goes. Mandatory rather than defaulted to temp: the sandbox is
        # the one directory this run owns and disposes of, and a default would put the file back in
        # shared temp for any caller who forgot.
        [Parameter(Mandatory)] [string]$SandboxRoot
    )

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $cfg.CodeCoverage.Enabled = $true
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

    $covered = @{}
    $result.CodeCoverage.CommandsExecuted | ForEach-Object {
        $f = [System.IO.Path]::GetFullPath($_.File)
        if (-not $covered.ContainsKey($f)) { $covered[$f] = [System.Collections.Generic.HashSet[int]]::new() }
        [void]$covered[$f].Add([int]$_.Line)
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
        [Parameter(Mandatory)] [string[]]$MutateFiles,
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
        $perFile.Add([pscustomobject]@{ File = $file; Produced = $produced.Count; Kept = $kept.Count })
    }
    return [pscustomobject]@{ Candidates = $out.ToArray(); PerFile = $perFile.ToArray() }
}

# The outcomes this module understands from a covering-test run. Pester's run-level result
# supplies 'Passed' and 'Failed'; 'TimedOut' is minted here by Invoke-PSBoundedPester. Anything
# outside this set is refused rather than scored -- see Invoke-PSMutant.
$script:PSMutationKnownOutcomes = @('Passed', 'Failed', 'TimedOut')

function Invoke-PSBoundedPester {
    <#
    .SYNOPSIS
        Run the covering tests in a CANCELLABLE runspace with a wall-clock timeout.
    .DESCRIPTION
        The loop-condition guard prevents a flipped *condition* from spinning, but a
        mutated loop *body* (e.g. `$i + 1` -> `$i - 1`) can still make a guarded loop
        never terminate. There is no way to know that statically, so each mutant runs
        under a hard timeout: a fresh PowerShell/runspace whose pipeline is Stop()'d
        when it overruns -- Stop() interrupts even a tight loop, so the run never hangs.

        The child imports Pester by PATH (see Get-PSMutationPesterPath) rather than
        letting the runspace resolve the name to whatever is newest on disk.
    .OUTPUTS
        The Pester result string ('Passed'/'Failed'/...), or 'TimedOut'.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$CoveringTests, [Parameter(Mandatory)] [int]$TimeoutSeconds)
    # The runspace is REUSED across mutants and Pester is imported into it once. Creating one and
    # importing Pester per mutant cost about 396 ms every time -- 27% of a measured 801s run over
    # PSComplexity -- to re-import a module that does not change between mutants.
    #
    # Nothing about the mutant is cached: the covering suite dot-sources the file under test, so
    # each run reads the spliced source afresh. Get-PSMutationWarmShell recycles on a fixed
    # interval to bound any state a suite leaves behind.
    $ps = Get-PSMutationWarmShell
    $ps.Commands.Clear()
    [void]$ps.AddScript((Get-PSMutationWarmPesterScript)).AddParameter('tests', $CoveringTests)
    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))) {
        $ps.Stop()
        # Stop() leaves the runspace unusable, so it is discarded rather than handed to the next
        # mutant. A timeout is rare; paying a cold start after one is the cheap half of the trade.
        Close-PSMutationWarmRunspace
        return 'TimedOut'
    }
    $outcome = [string]($ps.EndInvoke($async) | Select-Object -Last 1)
    # A child that returned no verdict proved nothing about the mutant. Handing
    # that back would classify it Killed -- anything but 'Passed' is a kill -- so a
    # broken child reads as a perfect score. That is exactly how the Pester version
    # collision stayed invisible for so long. Fail the run instead of scoring it.
    if (-not $outcome) {
        $why = Get-PSMutationRunspaceError -Runspace $ps
        Close-PSMutationWarmRunspace
        throw "The covering tests produced no result: $why"
    }
    return $outcome
}

function Invoke-PSMutant {
    <#
    .SYNOPSIS
        Evaluate one mutant: splice it into its SANDBOX file, run the covering tests
        under a timeout, classify, and restore the sandbox file for the next mutant.
    .OUTPUTS
        'Killed' | 'Survived' | 'TimedOut' -- Survived only if the suite still fully
        passes. A timeout scores WITH the kills, because a mutant that hangs the suite is a
        fault, but it is reported apart from them: "the suite proved this fault is caught"
        and "the suite hung and we assumed so" are different claims and only the first is
        evidence. Folded together, a suite that is merely too slow inflates the score.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] [string]$MutatedContent,
        # The file's UNMUTATED text, read once per file by the caller rather than once per mutant
        # here. It was read twice for every mutant -- once in the loop to splice against, and again
        # here to restore from -- which is the same bytes off disk twice to produce two strings that
        # are equal by construction. Mandatory rather than optional-with-a-fallback: a fallback that
        # re-read the file would be a second way to answer one question, and the two could differ
        # only if the sandbox had been changed underneath the run, which is the case where guessing
        # is worst.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$OriginalContent,
        [Parameter(Mandatory)] [string[]]$CoveringTests,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )
    try {
        [System.IO.File]::WriteAllText($Candidate.File, $MutatedContent)
        $outcome = Invoke-PSBoundedPester -CoveringTests $CoveringTests -TimeoutSeconds $TimeoutSeconds
        if ($outcome -eq 'Passed') { return 'Survived' }
        # Invoke-PSBoundedPester already distinguishes this; the verdict used to be
        # discarded one line later, which is the whole of the bug.
        if ($outcome -eq 'TimedOut') { return 'TimedOut' }
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
        return 'Killed'
    }
    finally {
        # Still restored per mutant, and deliberately. The next mutant writes the whole file anyway,
        # so this write is redundant between two mutants of the SAME file -- but it is what makes
        # this function self-contained: a mutant that throws, or a run killed here, leaves the
        # sandbox as it found it. That is a property worth one write, and the reads it used to sit
        # beside were the redundancy actually worth removing.
        [System.IO.File]::WriteAllText($Candidate.File, $OriginalContent)
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

function Invoke-PSMutationLoop {
    # Evaluate every candidate; return the result rows.
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
        [switch]$Quiet
    )
    $results = $Sink
    # One read per FILE, not per mutant. A file contributes many candidates -- 125 for the largest
    # in this repo's sibling -- and every one of them re-read the same unchanged bytes to splice
    # against, then Invoke-PSMutant re-read them again to restore from.
    #
    # Read here rather than by the caller because this is the loop that knows which files are
    # actually reached: a candidate list filtered by coverage can leave a mutate file contributing
    # nothing, and reading it would be work for a file no mutant touches.
    $originals = @{}
    $n = 0
    foreach ($c in $Candidates) {
        $n++
        if (-not $originals.ContainsKey($c.File)) { $originals[$c.File] = [System.IO.File]::ReadAllText($c.File) }
        $content = $originals[$c.File]
        $mutated = Set-PSMutationText -Content $content -Candidate $c
        $covering = $TestsByFile.ContainsKey($c.File) ? $TestsByFile[$c.File] : $AllTests
        $status = Invoke-PSMutant -Candidate $c -MutatedContent $mutated -OriginalContent $content `
            -CoveringTests $covering -TimeoutSeconds $TimeoutSeconds
        $display = ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot
        $row = [pscustomobject]@{
            # Function is carried so an equivalence declaration can address this mutant by
            # the function it lives in rather than by a line number, which moves whenever
            # anything above the mutant is edited and takes the declaration stale with it.
            #
            # This row is the report's published shape. Adding a field widens what every
            # consumer may depend on, so a test asserts the exact list: widening should
            # cost a deliberate edit, not happen as a side effect of an internal rename.
            Id = $c.Id; Function = $c.Function; File = $display; Line = $c.Line
            Operator = $c.Operator; Description = $c.Description; Status = $status
        }
        $results.Add($row)
        Write-PSMutationOutput -Quiet:$Quiet -Lines (Get-PSMutationProgressLine -Index $n `
                -Total $Candidates.Count -Result $row -DisplayFile (Split-Path $display -Leaf))
    }
    return , $results.ToArray()
}
