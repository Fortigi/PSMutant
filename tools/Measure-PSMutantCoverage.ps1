<#
.SYNOPSIS
    Measure line coverage over src/ and fail when it is below the required figure.

.DESCRIPTION
    The one invocation whose numbers can be trusted here. It is a committed script
    rather than a few lines inside ci.yml precisely so that a developer measuring by
    hand and the gate measuring in CI cannot drift apart -- the previous figures in
    this repo were folklore for exactly that reason.

    UseBreakpoints is the load-bearing setting. Pester 6 switched code coverage to the
    Profiler tracer by default, and a NESTED Pester run -- which tests/EndToEnd.Tests.ps1
    starts for real, because a full Invoke-PSMutation runs the baseline suite -- tears
    that tracer down. Every test file discovered after it then reports almost nothing,
    which looks like a plausible ~20% number for files that are in fact fully covered.
    Breakpoints survive the nested run, so the whole directory measures honestly in one
    pass and no file has to be excluded or exempted.

.PARAMETER Minimum
    Percentage the run must reach. Defaults to 100: this is a testing tool, so its own
    numbers are the product (see CLAUDE.md).

.EXAMPLE
    ./tools/Measure-PSMutantCoverage.ps1
#>
[CmdletBinding()]
param([double]$Minimum = 100)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')
$root = Split-Path -Parent $PSScriptRoot

$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
# The suite is fully on the v6 Should-* commands, so make the classic syntax an error
# rather than a style note. It cannot reach the fixture test files this repo writes out
# and runs in child runspaces -- those build their own configuration, and one of them is
# executed under Pester 5.8.0 by the compatibility guard, where Should-* does not exist.
$cfg.Should.DisableV5 = $true
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.UseBreakpoints = $true
$cfg.CodeCoverage.Path = (Get-ChildItem (Join-Path $root 'src') -Filter *.ps1).FullName
# Steer the XML to temp: Pester's default output path would drop a coverage.xml in the
# working tree on every local run.
$cfg.CodeCoverage.OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "psmutant-coverage-$PID.xml"

$result = Invoke-Pester -Configuration $cfg

$covered = $result.CodeCoverage.CommandsExecuted
$missed = $result.CodeCoverage.CommandsMissed
($covered + $missed) | Group-Object { Split-Path $_.File -Leaf } | Sort-Object Name | ForEach-Object {
    $hit = @($_.Group | Where-Object { $_.HitCount -gt 0 }).Count
    Write-Host ('  {0,-30} {1,4}/{2,-5} {3,6:N1}%' -f $_.Name, $hit, $_.Count, (100 * $hit / $_.Count))
}

$missed | Sort-Object File, Line | ForEach-Object {
    Write-Host ('  UNCOVERED {0}:{1}  {2}' -f (Split-Path $_.File -Leaf), $_.Line, $_.Command) -ForegroundColor Yellow
}

$percent = [math]::Round($result.CodeCoverage.CoveragePercent, 2)
Write-Host ("Coverage: $percent% over $(@($covered + $missed).Count) commands in src/")

# The verdict is a pure function so it can be tested (#27). A red suite is rejected before
# the percentage is believed: lines are still executed on the way to a failure, so a broken
# build could otherwise measure 100%.
$why = Get-PSMutantCoverageFailure -Percent $percent -Minimum $Minimum -FailedTestCount $result.FailedCount
if ($why) { throw $why }
