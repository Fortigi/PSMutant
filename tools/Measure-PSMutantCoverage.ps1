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
$root = Split-Path -Parent $PSScriptRoot

$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.UseBreakpoints = $true
$cfg.CodeCoverage.Path = (Get-ChildItem (Join-Path $root 'src') -Filter *.ps1).FullName
# Steer the XML to temp: Pester's default output path would drop a coverage.xml in the
# working tree on every local run.
$cfg.CodeCoverage.OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "psmutant-coverage-$PID.xml"

$result = Invoke-Pester -Configuration $cfg

# A red suite makes the coverage figure meaningless rather than merely lower: lines are
# still executed on the way to a failure, so a broken build could still measure 100%.
if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) test(s) failed - the coverage figure would not mean anything"
}

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
if ($percent -lt $Minimum) {
    throw "Coverage $percent% is below the required $Minimum%"
}
