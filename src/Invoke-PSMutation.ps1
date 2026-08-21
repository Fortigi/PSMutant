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
        Path to a JSON config (see about_PSMutant / the README): mutate, tests,
        operators, coveredLinesOnly, thresholds, reportPath, sandboxSubtrees.

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
        [pscustomobject] @{ Score; Killed; Survived; Total; ExitCode }, or for
        -RecheckFrom, @{ Mode; PriorSurvivors; Rechecked; NowKilled; StillSurviving }.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./psmutant.config.json

        A full run. Prints a coloured score, lists the survivors to go and kill, and
        writes the JSON report named by the config's reportPath.

    .EXAMPLE
        $r = Invoke-PSMutation -ConfigFile ./psmutant.config.json -Quiet
        if ($r.ExitCode -ne 0) { throw "Mutation score $($r.Score)% is below the threshold" }

        A CI gate. -Quiet drops the per-mutant progress lines, which are worth watching
        interactively and are noise in a build log. ExitCode is 0 unless thresholds.break
        is set and unmet, so a config without it is report-only.

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

    $subtrees = Get-PSMutationSubtree -Cfg $cfg
    $sandbox = New-PSMutationSandbox -RepoRoot $root -Subtrees $subtrees
    try {
        $t = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $root -SandboxRoot $sandbox

        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Banner' `
                -Text "`nPSMutant - PowerShell mutation testing (sandboxed)`n  Running baseline suite...")
        $baseline = Invoke-PSMutationBaseline -TestPath $t.AllTests -MutateFiles $t.Mutate
        Assert-PSMutationBaselineGreen -Baseline $baseline
        $timeout = Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds $baseline.DurationSeconds
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Good' `
                -Text ("  Baseline green in {0:N1}s (per-mutant timeout {1}s)" -f $baseline.DurationSeconds, $timeout))

        $ops = Get-PSMutationOperatorList -Cfg $cfg
        $cands = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops -CoveredLinesOnly (Get-PSMutationCoveredLinesOnly -Cfg $cfg) -CoveredLines $baseline.CoveredLines
        $hashes = Get-PSMutationSourceHashMap -MutateFiles $t.Mutate -SandboxRoot $sandbox
        $reportPath = Join-Path $root $cfg.reportPath

        # Gathered here, in the wiring, because the two impure inputs -- the clock and the
        # loaded module -- are what would make New-PSMutationProvenance untestable. It stays
        # pure and is handed values.
        $provenance = {
            New-PSMutationProvenance -ModuleVersion (Get-Module PSMutant).Version `
                -BaselineSeconds $baseline.DurationSeconds -PerMutantTimeoutSeconds $timeout `
                -TotalSeconds $runClock.Elapsed.TotalSeconds
        }

        if ($RecheckFrom) {
            return Invoke-PSMutationRecheckRun -RecheckFrom $RecheckFrom -Candidates $cands -Plan $t `
                -SourceHashes $hashes -Operators $ops -TimeoutSeconds $timeout -SandboxRoot $sandbox `
                -ReportPath $reportPath -Equivalents $cfg.equivalents -Provenance $provenance -Quiet:$Quiet
        }

        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Detail' `
                -Text "  Mutants to evaluate: $($cands.Count)`n")

        $results = Invoke-PSMutationLoop -Candidates $cands -TestsByFile $t.TestsByFile -AllTests $t.AllTests -TimeoutSeconds $timeout -SandboxRoot $sandbox -Quiet:$Quiet
        # Invoked here, not above: the elapsed time has to be read AFTER the loop, or
        # totalSeconds records how long the run took to start rather than to finish.
        $summary = Write-PSMutationReport -Results $results -ReportPath $reportPath -Thresholds $cfg.thresholds `
            -SourceHashes $hashes -Operators $ops -Equivalents $cfg.equivalents -Provenance (& $provenance)
        $band = Get-PSMutationScoreBand -Cfg $cfg
        Write-PSMutationOutput -Quiet:$Quiet -Lines (Get-PSMutationSummaryLine -Summary $summary -Results $results `
                -High $band.High -Low $band.Low -ReportPath $reportPath -Equivalents $cfg.equivalents)

        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds
        return ConvertTo-PSMutationRunResult -Summary $summary -ExitCode $exit
    }
    finally {
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
