# Public entry point for PSMutant: wiring, and nothing else.

function Invoke-PSMutation {
    <#
    .SYNOPSIS
        Run mutation testing over a set of PowerShell files and score how many
        injected faults ("mutants") the Pester suite catches ("kills").

    .DESCRIPTION
        All work happens in a throwaway temp sandbox: the source subtrees are copied
        out, mutants are spliced into the COPY, and the tests run from the copy - so
        tracked source is never modified, even if the run is killed mid-way. Returns
        a summary object; report-only unless the config sets thresholds.break.

    .PARAMETER ConfigFile
        Path to a JSON config: mutate, tests, operators, coveredLinesOnly, thresholds,
        reportPath, sandboxSubtrees.

        The format is DEFINED by schemas/v1/config.schema.json, which ships beside this module
        and is what the module itself validates against -- so it cannot describe a config this
        module would reject. Point a config's $schema at it for editor completion. The README
        carries the same table with prose around it.

    .PARAMETER SourceRoot
        Root of the code under test; config paths are relative to it. Defaults to the
        current directory.

    .PARAMETER RecheckFrom
        Path to a report from a previous run -- full or from an earlier recheck.
        Evaluates ONLY the mutants that report recorded as survivors, minus any declared
        equivalent, which is the fast inner loop while you are writing assertions.

        Chaining is the point: recheck a recheck and each round evaluates only what the
        previous one left alive, so the loop shortens as you close in rather than
        restarting from the full set every time. Rounds overwrite one
        <report>.recheck.json; the full report is never written by a recheck.

        This is not a measurement and does not produce a score: the set is filtered,
        so no percentage over it means anything, thresholds are not applied, and the
        result is written to a separate <report>.recheck.json so the full baseline
        cannot be overwritten by a partial run.

        It is also only sound for test changes that purely ADD assertions. Editing or
        deleting an existing test can revive a mutant that was killed before, and a
        recheck never evaluates those -- so finish with a full run before trusting a
        number or moving a threshold.

    .PARAMETER Quiet
        Suppress the console output: the banner, the per-mutant progress lines and the
        closing summary. The JSON report is still written and the result object is still
        returned, so nothing is lost -- only the narration.

        Worth using in CI, where a build log gains nothing from a line per mutant. Worth
        leaving OFF interactively, where those lines are the only sign of progress during
        a run that can take minutes, and survivors appear in yellow as they are found
        rather than all at the end.

    .OUTPUTS
        [pscustomobject]. Two shapes, sharing Mode, ExitCode and FailureReason so a caller that
        did not choose the mode can still branch on the result:

            full     @{ Mode='Full'; Score; Killed; Survived; Total; ExitCode; FailureReason;
                        StaleEquivalents; DeclaredEquivalent }
            recheck  @{ Mode='Recheck'; PriorSurvivors; Rechecked; NowKilled; StillSurviving;
                        ExitCode; FailureReason }

        FailureReason is 'None', 'StaleEquivalents' or 'BelowThreshold'. It exists because
        ExitCode 1 means either of the last two, and the difference decides what to go and fix:
        a stale declaration is a false statement in the config inflating the score, not a
        shortfall to write tests against.

        A recheck ExitCode is always 0. It applies no thresholds by design -- it answers "is this
        one dead yet" over a set you chose, and a verdict over a chosen subset is the filtered
        number this module exists to stop people quoting. Read StillSurviving.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./psmutant.config.json

        A full run. Prints a coloured score, lists the survivors to go and kill, and
        writes the JSON report named by the config's reportPath.

    .EXAMPLE
        $r = Invoke-PSMutation -ConfigFile ./psmutant.config.json -Quiet
        if ($r.ExitCode -ne 0) { throw "Mutation run failed: $($r.FailureReason)" }

        A CI gate. -Quiet drops the per-mutant progress lines, which are worth watching
        interactively and are noise in a build log.

        Read FailureReason rather than assuming the score. ExitCode 1 also means a stale
        equivalence declaration, which fires at any score and in report-only mode -- so a
        message hardcoded to "below the threshold" is a false statement about that run, and on
        a destroyed CI runner it is the only thing left.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json

        Re-run ONLY the mutants the previous report recorded as survivors -- the fast
        inner loop while you are writing assertions to kill them. Declared equivalents
        are skipped, since the config already argues no test can kill those.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.recheck.json

        A recheck report seeds the next recheck, so the loop NARROWS: five survivors,
        kill two, and the second round evaluates three rather than five again. Each round
        overwrites the same *.recheck.json; the full report is never touched.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -SourceRoot ../other-repo

        Mutate a different repository. Every path in the config is relative to
        -SourceRoot, which defaults to the current directory.

    .LINK
        https://github.com/Fortigi/PSMutant
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigFile,
        [string]$SourceRoot = (Get-Location).Path,
        [string]$RecheckFrom,
        [switch]$Quiet
    )

    # Started before anything else so `totalSeconds` covers what a user actually waits for,
    # sandbox setup and baseline included, rather than only the mutation loop.
    $runClock = [System.Diagnostics.Stopwatch]::StartNew()
    $root = (Resolve-Path $SourceRoot).Path
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Assert-PSMutationConfig -Cfg $cfg
    Assert-PSMutationPester
    Clear-PSMutationStaleSandbox

    $subtrees = Get-PSMutationSubtree -Cfg $cfg -SourceRoot $root
    $sandbox = New-PSMutationSandbox -RepoRoot $root -Subtrees $subtrees
    try {
        $t = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $root -SandboxRoot $sandbox

        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Banner' `
                -Text "`nPSMutant - PowerShell mutation testing (sandboxed)`n  Running baseline suite...")
        # Before the baseline, because after it the answer is a false statement about the
        # tests rather than a true one about the config.
        $missing = Get-PSMutationMissingSandboxPath -Paths (@($t.Mutate) + @($t.AllTests)) -Subtrees $subtrees
        if ($missing) { throw $missing }
        $baseline = Invoke-PSMutationBaseline -TestPath $t.AllTests -MutateFiles $t.Mutate -SandboxRoot $sandbox
        Assert-PSMutationBaselineGreen -Baseline $baseline
        $timeout = Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds $baseline.DurationSeconds
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Good' `
                -Text ("  Baseline green in {0:N1}s (per-mutant timeout {1}s)" -f $baseline.DurationSeconds, $timeout))

        $ops = Get-PSMutationOperatorList -Cfg $cfg
        $selection = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops -CoveredLinesOnly (Get-PSMutationCoveredLinesOnly -Cfg $cfg) -CoveredLines $baseline.CoveredLines
        $cands = $selection.Candidates
        # Derived here in the wiring and carried, because the pre-filter counts exist only
        # inside the selection; recomputing them later means parsing every file again.
        $exclusion = Get-PSMutationCoverageExclusion -PerFile $selection.PerFile
        $hashes = Get-PSMutationSourceHashMap -MutateFiles $t.Mutate -SandboxRoot $sandbox
        $reportPath = Get-PSMutationReportPath -Cfg $cfg -SourceRoot $root

        # Gathered here, in the wiring, because the two impure inputs -- the clock and the
        # loaded module -- are what would make New-PSMutationProvenance untestable. It stays
        # pure and is handed values.
        $provenance = {
            New-PSMutationProvenance -ModuleVersion (Get-Module PSMutant).Version `
                -BaselineSeconds $baseline.DurationSeconds -PerMutantTimeoutSeconds $timeout `
                -TotalSeconds $runClock.Elapsed.TotalSeconds
        }

        # Two clusters, each shared by two of the three callees below: what a run EXECUTES
        # with, and what the report DOCUMENTS itself with. A value is spelled once here, so
        # adding one is an edit at its source rather than at every call site forwarding it.
        # Provenance stays explicit because the two callees want different things from it --
        # the recheck takes the scriptblock and invokes it after its own loop, the report
        # takes the already-invoked result.
        $exec = @{ Candidates = $cands; TimeoutSeconds = $timeout; SandboxRoot = $sandbox; Quiet = $Quiet }
        # NOT in $exec, which is splatted into the recheck run as well. A recheck evaluates its
        # mutants through the same loop and still records a first killer per row; what it does
        # not do is pay for the complete list, because its report carries no killersComplete
        # disclosure to make one readable.
        $allKillers = Get-PSMutationRecordEveryKiller -Cfg $cfg
        $doc = @{ SourceHashes = $hashes; Operators = $ops; Equivalents = $cfg.equivalents; ReportPath = $reportPath }

        if ($RecheckFrom) {
            return Invoke-PSMutationRecheckRun @exec @doc -RecheckFrom $RecheckFrom -Plan $t -Provenance $provenance
        }

        # Said before the loop, because that is when it can still be acted on -- the cost it
        # names is paid on every mutant that follows.
        # Wrapped: a PowerShell function returning an empty collection unrolls it to NOTHING,
        # so this binds $null on the ordinary path however carefully the callee types its
        # output. That $null is what reached the report as `[null]` in #158.
        $unmapped = @(Get-PSMutationUnmappedMutateFile -MutateFiles $t.Mutate -TestsByFile $t.TestsByFile)
        if ($unmapped.Count -gt 0) {
            Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                    -Text ("  {0} mutate file(s) have no tests entry, so every one of their mutants runs the WHOLE suite: {1}" -f `
                            $unmapped.Count, (($unmapped | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))
        }
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Detail' `
                -Text "  Mutants to evaluate: $($cands.Count)`n")

        # FINALLY, not catch, and the difference is the whole feature. Ctrl-C and a cancelled CI
        # job raise a pipeline STOP, which a catch block never sees -- measured: a catch beside
        # this one does not run, a finally does. Written with a catch, the partial report would
        # appear for a crash and be missing for the interruption people actually hit.
        #
        # $done is the flag rather than testing $results, because the loop returning normally
        # with zero rows is a legitimate outcome (a config whose files contribute no covered
        # candidates) and must write the ordinary empty report, not a partial one.
        $partial = [System.Collections.Generic.List[object]]::new()
        $done = $false
        try {
            $results = Invoke-PSMutationLoop @exec -TestsByFile $t.TestsByFile -AllTests $t.AllTests -Sink $partial -RecordAllKillers:$allKillers
            $done = $true
        }
        finally {
            if (-not $done) {
                $written = Write-PSMutationPartialReport -Results @($partial) -Planned $cands.Count `
                    -ReportPath $reportPath -Operators $ops -SourceHashes $hashes -Provenance (& $provenance)
                # Printed rather than returned: the run is being torn down, so there is no caller
                # left to hand a value to, and a file written where nobody was told about it is
                # only marginally better than no file.
                Write-PSMutationOutput -Quiet:$false -Lines (New-PSMutationLine -Role 'Muted' `
                        -Text ("`n  Interrupted after {0} of {1} mutant(s). Wrote a PARTIAL report to {2} -- counts only, no score." -f `
                                $partial.Count, $cands.Count, $written))
            }
        }
        # Invoked here, not above: the elapsed time has to be read AFTER the loop, or
        # totalSeconds records how long the run took to start rather than to finish.
        $summary = Write-PSMutationReport @doc -Results $results -Thresholds $cfg.thresholds -Provenance (& $provenance) -Exclusion $exclusion -UnmappedFiles $unmapped -MutateFiles $t.Mutate -KillersComplete $allKillers -MappedTests $t.AllTests
        $band = Get-PSMutationScoreBand -Cfg $cfg
        $summaryLines = Get-PSMutationSummaryLine -Summary $summary -Results $results `
            -High $band.High -Low $band.Low -ReportPath $reportPath -Equivalents $cfg.equivalents -Exclusion $exclusion -PerFile (Get-PSMutationPerFileScore -Results $results -Equivalents $cfg.equivalents)
        Write-PSMutationOutput -Quiet:$Quiet -Lines $summaryLines
        # Annotations are NOT passed -Quiet, and that is the point rather than an oversight.
        # -Quiet exists so a CI log is not filled with several hundred progress lines, and CI is
        # exactly where a survivor most needs to be visible: suppressing both leaves a failed
        # gate printing a score and nothing else, which is a backstop that cannot say what
        # failed. The switch silences the LOG; a finding is not log.
        if (Test-PSMutationAnnotationHost) {
            # @() because a run with NOTHING to annotate yields no lines at all, and -Lines
            # accepts an empty collection but not $null. Without it a clean run under Actions
            # throws on binding -- so the green path would be the one that crashed.
            # -Quiet:$false rather than omitting the switch. Not decoration: an omitted switch
            # is UNBOUND on the call, and a Should-Invoke filter that mentions $Quiet then has
            # to resolve it -- $false, or the caller's own $Quiet further up the scope chain --
            # and the two answers are not the same on every PowerShell. Binding it explicitly
            # makes every renderer call carry the parameter, so no filter anywhere can be
            # ambiguous about which calls it selected.
            #
            # It also says the thing out loud at the call site: annotations are deliberately
            # NOT suppressed, because -Quiet silences the log and a finding is not log.
            Write-PSMutationOutput -Quiet:$false -Lines @(Get-PSMutationAnnotationLine -Lines $summaryLines)
        }

        # The reason first, and the exit code derived from it, so the two cannot disagree about
        # the same run.
        $reason = Get-PSMutationFailureReason -Summary $summary -Thresholds $cfg.thresholds
        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds
        return ConvertTo-PSMutationRunResult -Summary $summary -ExitCode $exit -FailureReason $reason
    }
    finally {
        # The warm mutant runspace outlives individual mutants by design; it must not outlive the
        # run, or a long-lived host keeps a Pester-loaded runspace per completed run.
        Close-PSMutationWarmRunspace
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
