<#
.SYNOPSIS
    Public entry point for PSMutant — mutation testing for PowerShell.
#>

function Assert-PSMutationPester {
    [CmdletBinding()]
    param()
    if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge '5.0.0')) {
        throw 'Pester 5+ is required. Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser'
    }
    Import-Module Pester -MinimumVersion 5.0.0
}

function Get-PSMutationSandboxTargets {
    # Translate the config's source-relative mutate/tests into sandbox absolute paths.
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

function Invoke-PSMutation {
    <#
    .SYNOPSIS
        Run mutation testing over a set of PowerShell files and score how many
        injected faults ("mutants") the Pester suite catches ("kills").

    .DESCRIPTION
        All work happens in a throwaway temp sandbox: the source subtrees are copied
        out, mutants are spliced into the COPY, and the tests run from the copy — so
        tracked source is never modified, even if the run is killed mid-way. Returns
        a summary object; report-only unless the config sets thresholds.break.

    .PARAMETER ConfigFile
        Path to a JSON config (see about_PSMutant / the README): mutate, tests,
        operators, coveredLinesOnly, thresholds, reportPath, sandboxSubtrees.

    .PARAMETER SourceRoot
        Root of the code under test; config paths are relative to it. Defaults to the
        current directory.

    .OUTPUTS
        [pscustomobject] @{ Score; Killed; Survived; Total; ExitCode }

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./psmutant.config.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigFile,
        [string]$SourceRoot = (Get-Location).Path,
        [switch]$Quiet
    )

    $root = (Resolve-Path $SourceRoot).Path
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Assert-PSMutationPester
    Clear-PSMutationStaleSandbox

    $subtrees = if ($cfg.sandboxSubtrees) { @($cfg.sandboxSubtrees) } else { $script:PSMutationSandboxSubtrees }
    $sandbox = New-PSMutationSandbox -RepoRoot $root -Subtrees $subtrees
    try {
        $t = Get-PSMutationSandboxTargets -Cfg $cfg -SourceRoot $root -SandboxRoot $sandbox

        if (-not $Quiet) { Write-Host "`nPSMutant — PowerShell mutation testing (sandboxed)`n  Running baseline suite..." -ForegroundColor Cyan }
        $baseline = Invoke-PSMutationBaseline -TestPath $t.AllTests -MutateFiles $t.Mutate
        if (-not $baseline.Passed) { throw 'Baseline suite is not green — fix the tests before mutating.' }
        if (-not $Quiet) { Write-Host ("  Baseline green in {0:N1}s" -f $baseline.DurationSeconds) -ForegroundColor Green }

        $ops = if ($cfg.operators) { @($cfg.operators) } else { $script:PSMutationDefaultOperators }
        $cands = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops -CoveredLinesOnly ([bool]$cfg.coveredLinesOnly) -CoveredLines $baseline.CoveredLines
        if (-not $Quiet) { Write-Host "  Mutants to evaluate: $($cands.Count)`n" -ForegroundColor Gray }

        $results = Invoke-PSMutationLoop -Candidates $cands -TestsByFile $t.TestsByFile -AllTests $t.AllTests -SandboxRoot $sandbox -Quiet:$Quiet
        $reportPath = Join-Path $root $cfg.reportPath
        $summary = Write-PSMutationReport -Results $results -ReportPath $reportPath -Thresholds $cfg.thresholds
        if (-not $Quiet) { Show-PSMutationSummary -Summary $summary -Results $results -Thresholds $cfg.thresholds -ReportPath $reportPath }

        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds
        return [pscustomobject]@{
            Score = $summary.Score; Killed = $summary.Killed
            Survived = $summary.Survived; Total = $summary.Total; ExitCode = $exit
        }
    }
    finally {
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
