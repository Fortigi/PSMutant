<#
.SYNOPSIS
    Public entry point for PSMutant - mutation testing for PowerShell.

.DESCRIPTION
    One function, and deliberately nothing else: this file is WIRING. Every decision it
    reaches for lives in a pure unit elsewhere -- guards, resolvers, scoring, the report
    shape -- so each can be unit-tested and self-mutated on its own terms.

    It used to also hold a Pester guard, a message constant and a second complete
    orchestrator for the recheck mode, none of which the synopsis above described (#45).
    A new decision belongs in the file that owns its subject, not here.
#>

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

    .OUTPUTS
        [pscustomobject] @{ Score; Killed; Survived; Total; ExitCode }, or for
        -RecheckFrom, @{ Mode; PriorSurvivors; Rechecked; NowKilled; StillSurviving }.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./psmutant.config.json

    .EXAMPLE
        # Write assertions, then re-run just the survivors instead of the whole set.
        Invoke-PSMutation -ConfigFile ./psmutant.config.json -RecheckFrom ./reports/ps-mutation.json
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigFile,
        [string]$SourceRoot = (Get-Location).Path,
        [string]$RecheckFrom,
        [switch]$Quiet
    )

    $root = (Resolve-Path $SourceRoot).Path
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Assert-PSMutationConfig -Cfg $cfg
    Assert-PSMutationPester
    Clear-PSMutationStaleSandbox

    $subtrees = Get-PSMutationSubtree -Cfg $cfg
    $sandbox = New-PSMutationSandbox -RepoRoot $root -Subtrees $subtrees
    try {
        $t = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $root -SandboxRoot $sandbox

        if (-not $Quiet) { Write-Host "`nPSMutant - PowerShell mutation testing (sandboxed)`n  Running baseline suite..." -ForegroundColor Cyan }
        $baseline = Invoke-PSMutationBaseline -TestPath $t.AllTests -MutateFiles $t.Mutate
        Assert-PSMutationBaselineGreen -Baseline $baseline
        $timeout = Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds $baseline.DurationSeconds
        if (-not $Quiet) { Write-Host ("  Baseline green in {0:N1}s (per-mutant timeout {1}s)" -f $baseline.DurationSeconds, $timeout) -ForegroundColor Green }

        $ops = Get-PSMutationOperatorList -Cfg $cfg
        $cands = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops -CoveredLinesOnly (Get-PSMutationCoveredLinesOnly -Cfg $cfg) -CoveredLines $baseline.CoveredLines
        $hashes = Get-PSMutationSourceHashMap -MutateFiles $t.Mutate -SandboxRoot $sandbox
        $reportPath = Join-Path $root $cfg.reportPath

        if ($RecheckFrom) {
            return Invoke-PSMutationRecheckRun -RecheckFrom $RecheckFrom -Candidates $cands -Plan $t `
                -SourceHashes $hashes -Operators $ops -TimeoutSeconds $timeout -SandboxRoot $sandbox `
                -ReportPath $reportPath -Equivalents $cfg.equivalents -Quiet:$Quiet
        }

        if (-not $Quiet) { Write-Host "  Mutants to evaluate: $($cands.Count)`n" -ForegroundColor Gray }

        $results = Invoke-PSMutationLoop -Candidates $cands -TestsByFile $t.TestsByFile -AllTests $t.AllTests -TimeoutSeconds $timeout -SandboxRoot $sandbox -Quiet:$Quiet
        $summary = Write-PSMutationReport -Results $results -ReportPath $reportPath -Thresholds $cfg.thresholds `
            -SourceHashes $hashes -Operators $ops -Equivalents $cfg.equivalents
        $band = Get-PSMutationScoreBand -Cfg $cfg
        if (-not $Quiet) { Show-PSMutationSummary -Summary $summary -Results $results -High $band.High -Low $band.Low -ReportPath $reportPath -Equivalents $cfg.equivalents }

        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds
        return ConvertTo-PSMutationRunResult -Summary $summary -ExitCode $exit
    }
    finally {
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
