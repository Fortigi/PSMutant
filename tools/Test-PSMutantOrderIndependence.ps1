# Run the suite in reverse file order, and fail if that changes the answer or if the run leaves
# an environment variable behind.
#
# This project runs its own suite in TWO orders and nothing checked they agree. Invoke-Pester over
# ./tests discovers files alphabetically; the mutation baseline runs the mapped covering suites in
# the order psmutant.self.config.json lists them, which is not alphabetical. Those orders have
# already disagreed here: Output.Tests.ps1 sorts first and its AfterEach cleared an environment
# variable, so Recheck.Tests.ps1 saw the ambient value in config order and the cleared one
# alphabetically. The suite was green locally and red in the gate, and three CI rounds went into
# finding out why. That leak is fixed; nothing would have caught the next one.
#
# Two checks, because they fail on opposite halves of the problem:
#
#   The reversed RUN catches a dependency by its symptom. It is a probe rather than a proof: it
#   exercises one more permutation, not all of them, so a dependency whose two files happen to keep
#   their relative order under reversal survives it.
#
#   The environment COMPARISON catches the cause, and is direction-blind. Anything a file leaves
#   behind is visible to every file after it, so a leak is order-dependence waiting for a reader --
#   and this fires on the file that leaks whether or not anything reads it yet. Reversal alone can
#   miss exactly that, because it moves the reader in front of the leaker as readily as behind it.
#
# It is a committed script rather than a snippet in ci.yml so that running it by hand and running
# it in CI cannot drift, and so a developer can settle "is this mine?" without pushing.
#
# Known limit, stated rather than left to be rediscovered: the comparison spans the whole run, so a
# file that leaks and a later file that coincidentally restores cancel out. Per-file granularity
# needs a hook Pester does not offer, and would cost one process per file.
#
# Two other kinds of state were tried and are deliberately NOT compared. Both were measured on this
# suite, and both would have been checks that cannot do their job -- which reads exactly like a
# check that keeps passing:
#
#   The working DIRECTORY. Pester restores it around a run, so a test file that wanders off with
#   Set-Location leaves it back where it started. Verified two ways: a test that changes directory
#   and passes leaves the location unchanged, and a full run of this suite ends where it began. A
#   cwd comparison here could never fire.
#
#   GLOBAL variables. A clean run of this suite already leaves several behind -- d, p, root and
#   LASTEXITCODE, measured. The comparison would fail on a green suite, and the only way to keep it
#   would be an allowlist that grows with the tests it is supposed to be watching. Those three are
#   not read as ambient input by anything today, which is the difference between untidy and broken.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Get-ProcessStateSnapshot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'The literal @{} is case-INSENSITIVE, which is the one property this map must not have. On Linux PATH and Path are two different variables and the literal would silently merge them into one entry, so a change to either would compare equal.')]
    param()
    $snap = [hashtable]::new(0, [StringComparer]::Ordinal)
    # Keyed by the path you would type, so the failure message names something the reader can go
    # and look at. A second kind of state, if one ever earns its place, is a second key prefix here
    # rather than a second comparison someone has to remember to invert correctly.
    foreach ($item in Get-ChildItem env:) { $snap["env:$($item.Name)"] = [string]$item.Value }
    return $snap
}

$before = Get-ProcessStateSnapshot

$files = @(Get-ChildItem (Join-Path $root 'tests') -Filter *.Tests.ps1 |
        Sort-Object Name -Descending | ForEach-Object FullName)
# Refuse to certify order-independence over fewer than two files. Reversing a list of one yields
# the same list, so the run would pass without ever having exercised a second order -- the shape of
# green this whole script exists to distrust.
if ($files.Count -lt 2) {
    throw ("Found $($files.Count) test file(s) under $(Join-Path $root 'tests'): reversing that " +
        'exercises no second order, so a pass here would certify nothing.')
}

Import-Module (Join-Path $root 'PSMutant.psd1') -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = $files
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
# Match the gates: the classic `Should -Be` form is an error here too, so the reversed run cannot
# pass over a suite the ordinary run would reject.
$cfg.Should.DisableV5 = $true
$result = Invoke-Pester -Configuration $cfg

# Pester is asked for a specific list; a file silently dropped from it would leave the run green
# over less than it was given, and the count is the only place that shows.
if ($result.Containers.Count -ne $files.Count) {
    throw ("Asked Pester for $($files.Count) test file(s) and it ran $($result.Containers.Count). " +
        'A reversed run over a subset proves nothing about the whole.')
}

. (Join-Path $PSScriptRoot 'GateDecisions.ps1')
$fault = Get-PSMutantTestRunFault -FailedCount $result.FailedCount `
    -ContainerResult @($result.Containers | ForEach-Object { [string]$_.Result }) `
    -ContainerName @($result.Containers | ForEach-Object { Split-Path $_.Item -Leaf })
if ($fault) {
    throw ("$fault This is the suite in REVERSE file order. If it passes alphabetically, the " +
        'failure is not in the test that reported it -- it is in what ran before it.')
}

$stateFault = Get-PSMutantProcessStateFault -Before $before -After (Get-ProcessStateSnapshot)
if ($stateFault) { throw $stateFault }

Write-Output ("Order independence: $($files.Count) test file(s) reversed, " +
    "$($result.PassedCount) test(s) passed, environment unchanged.")
