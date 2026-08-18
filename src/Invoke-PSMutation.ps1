<#
.SYNOPSIS
    Public entry point for PSMutant - mutation testing for PowerShell.
#>

function Assert-PSMutationPester {
    [CmdletBinding()]
    param()
    if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge '5.0.0')) {
        throw 'Pester 5+ is required. Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser'
    }
    Import-Module Pester -MinimumVersion 5.0.0
}

function Get-PSMutationSandboxPlan {
    # Translate the config's source-relative mutate/tests into sandbox absolute paths.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'SourceRoot and SandboxRoot are used inside the $toSb closure, which the analyzer does not track.')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$SourceRoot, [Parameter(Mandatory)] [string]$SandboxRoot)
    $toSb = { param($p) ConvertTo-PSMutationSandboxPath -Path (Join-Path $SourceRoot $p) -RepoRoot $SourceRoot -SandboxRoot $SandboxRoot }
    $byFile = @{}
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in $Cfg.tests.PSObject.Properties) {
        $vals = @($prop.Value | ForEach-Object { & $toSb $_ })
        $byFile[(& $toSb $prop.Name)] = $vals
        $vals | ForEach-Object { $all.Add($_) }
    }
    return @{
        Mutate      = @($Cfg.mutate | ForEach-Object { & $toSb $_ })
        TestsByFile = $byFile
        AllTests    = $all.ToArray()
    }
}

function Invoke-PSMutationRecheckRun {
    # The whole -RecheckFrom path, kept out of Invoke-PSMutation so the entry point
    # stays an orchestrator rather than growing a second mode inline.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RecheckFrom,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [string]$ReportPath,
        [switch]$Quiet
    )
    $prior = Get-Content $RecheckFrom -Raw | ConvertFrom-Json
    # Refuse rather than guess. Mutant ids are AST-walk positions: if the source or
    # the operator set moved, the ids in the report point at different mutants now,
    # and a recheck would answer confidently about the wrong ones.
    $why = Test-PSMutationRecheckCompatible -Report $prior -SourceHashes $SourceHashes -Operators $Operators
    if ($why.Count -gt 0) {
        throw ("Cannot recheck against '$RecheckFrom': " + ($why -join '; ') + '. Run the full set to regenerate the report.')
    }
    $targets = Select-PSMutationRecheckCandidate -Candidates $Candidates -Report $prior -SandboxRoot $SandboxRoot
    if (-not $Quiet) { Write-Host "  Rechecking $($targets.Count) previous survivor(s)`n" -ForegroundColor Gray }

    $results = Invoke-PSMutationLoop -Candidates $targets -TestsByFile $Plan.TestsByFile -AllTests $Plan.AllTests `
        -TimeoutSeconds $TimeoutSeconds -SandboxRoot $SandboxRoot -Quiet:$Quiet
    $recheckPath = Get-PSMutationRecheckReportPath -ReportPath $ReportPath
    $summary = Write-PSMutationRecheckReport -Results $results -ReportPath $recheckPath `
        -PriorSurvivorCount @($prior.survivors).Count -SourceReportPath $RecheckFrom
    if (-not $Quiet) { Show-PSMutationRecheckSummary -Summary $summary -Results $results -ReportPath $recheckPath }
    return $summary
}

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
        Path to a report from a previous run. Evaluates ONLY the mutants that report
        recorded as survivors, which is the fast inner loop while you are writing
        assertions to kill them.

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
        $cands = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops -CoveredLinesOnly ([bool]$cfg.coveredLinesOnly) -CoveredLines $baseline.CoveredLines
        $hashes = Get-PSMutationSourceHashMap -MutateFiles $t.Mutate -SandboxRoot $sandbox
        $reportPath = Join-Path $root $cfg.reportPath

        if ($RecheckFrom) {
            return Invoke-PSMutationRecheckRun -RecheckFrom $RecheckFrom -Candidates $cands -Plan $t `
                -SourceHashes $hashes -Operators $ops -TimeoutSeconds $timeout -SandboxRoot $sandbox `
                -ReportPath $reportPath -Quiet:$Quiet
        }

        if (-not $Quiet) { Write-Host "  Mutants to evaluate: $($cands.Count)`n" -ForegroundColor Gray }

        $results = Invoke-PSMutationLoop -Candidates $cands -TestsByFile $t.TestsByFile -AllTests $t.AllTests -TimeoutSeconds $timeout -SandboxRoot $sandbox -Quiet:$Quiet
        $summary = Write-PSMutationReport -Results $results -ReportPath $reportPath -Thresholds $cfg.thresholds `
            -SourceHashes $hashes -Operators $ops -Equivalents $cfg.equivalents
        if (-not $Quiet) { Show-PSMutationSummary -Summary $summary -Results $results -Thresholds $cfg.thresholds -ReportPath $reportPath -Equivalents $cfg.equivalents }

        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds
        return ConvertTo-PSMutationRunResult -Summary $summary -ExitCode $exit
    }
    finally {
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
