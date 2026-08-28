# Compatibility gate: prove PSMutant still drives a Pester it did not pick for itself.
#
# The manifest promises Pester >= 5.0.0. This repo's own suite runs on exactly one pinned
# version, so nothing in it exercises the case that actually broke: a child runspace resolves
# `Pester` by NAME and gets the newest on disk, assemblies are per-process, the child dies on an
# incompatible Pester.dll, returns no verdict, and every mutant is classified Killed. The run
# reported a silent, entirely fake 100% -- no error, no failed test, a perfect score over tests
# that never ran.
#
# ONE VERSION PER CHILD PROCESS, always. Assemblies are per-process, so proving two Pesters in
# one process is not a stronger test; it is a different and impossible one. The script
# re-invokes ITSELF with -Child rather than spawning a here-string, so the analyzer and the
# parser see every line that runs -- a child contract written as an unparsed string is code no
# gate can read.
#
# It used to take a single -PesterVersion and CI passed it one number, so the floor the manifest
# promises had never been executed (#161). Floor-plus-latest was considered and is not enough:
# a defect that arrives mid-range is invisible at both ends. One leg per MINOR, newest patch of
# each, with no exception for the floor -- a rule with one exception is two rules.
[CmdletBinding()]
param(
    # Deliberately not the version tests/ uses. Empty means read PESTER_COMPAT_VERSIONS from the
    # environment or .github/pins.env, so running this by hand and running it in CI are the same
    # run with no setup step.
    [string[]]$PesterVersion,
    [switch]$Child,
    [string]$FixtureRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')
$root = Split-Path -Parent $PSScriptRoot

if (-not $PesterVersion) {
    # Environment first so a workflow can override, then the pins file, then refuse. Defaulting
    # to some version here would be the failure this gate exists to find: a compatibility claim
    # proven against a number nobody chose.
    $fromEnv = $env:PESTER_COMPAT_VERSIONS
    if (-not $fromEnv) {
        $pins = Join-Path -Path $root -ChildPath '.github/pins.env'
        $fromEnv = Get-PSMutantPinValue -Line (Get-Content -LiteralPath $pins) -Name 'PESTER_COMPAT_VERSIONS'
    }
    $PesterVersion = @($fromEnv -split ' ' | Where-Object { $_ })
    if (-not $PesterVersion) {
        throw 'PESTER_COMPAT_VERSIONS is set neither in the environment nor in .github/pins.env. Refusing to run: a compatibility gate over zero versions passes every time.'
    }
}

function Build-PSMutantCompatFixture {
    <#
    .SYNOPSIS
        A consumer project whose covering suite is deliberately weak, plus a control.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root)

    New-Item -ItemType Directory -Path (Join-Path $Root 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'tests') -Force | Out-Null

    # Get-Sign is asserted properly so its mutants die; Test-Flag is asserted only for "does not
    # throw", so its mutants must survive. BOTH halves matter: all-killed is the failure being
    # guarded against, and all-survived would mean nothing ran.
    @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
function Test-Flag { param($x) if ($x) { return $true } else { return $false } }
'@ | Set-Content (Join-Path $Root 'src/calc.ps1') -Encoding utf8

    @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos for positive' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg for non-positive' { Get-Sign -5 | Should -Be 'neg' }
}
Describe 'Test-Flag' {
    It 'returns something for a truthy input' { { Test-Flag $true } | Should -Not -Throw }
}
'@ | Set-Content (Join-Path $Root 'tests/calc.Tests.ps1') -Encoding utf8

    # The CONTROL. Asserts nothing about this module -- it asks whether the requested Pester can
    # execute a test at all on this host. Without it, a Pester that is broken here looks exactly
    # like a PSMutant incompatibility, and the gate accuses the wrong code.
    @'
Describe 'control -- can this Pester run anything at all' {
    It 'evaluates a trivial assertion' { (1 + 1) | Should -Be 2 }
}
'@ | Set-Content (Join-Path $Root 'Control.Tests.ps1') -Encoding utf8

    $configFile = Join-Path $Root 'psmutant.json'
    [ordered]@{
        sandboxSubtrees  = @('src', 'tests')
        mutate           = @('src/calc.ps1')
        tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
        coveredLinesOnly = $true
        operators        = @('BinaryOperator', 'BooleanLiteral')
        reportPath       = 'reports/compat.json'
    } | ConvertTo-Json -Depth 6 | Set-Content $configFile -Encoding utf8
    return $configFile
}

function Invoke-PSMutantCompatControl {
    <#
    .SYNOPSIS
        The oldest Pester 5 surface there is, so the control can reach the declared floor.
    .DESCRIPTION
        The SIMPLE parameter set, deliberately. A configuration object needs
        New-PesterConfiguration, which did not exist until Pester 5.1.0 -- and asking for it
        under 5.0.x does not fail cleanly: the command is not found, PowerShell autoloads
        `Pester` by NAME to the newest installed, and that collides with the Pester.dll already
        in the process. The error names assembly versions and never mentions this module, so a
        gate built that way cannot test the floor it defends and reports the module broken when
        pointed at it. That trap is not unique to this module -- a gate built on a command that
        arrived mid-range cannot reach the floor it defends.

        6>$null replaces Output.Verbosity = 'None', which lives on the configuration object this
        can no longer build. Pester writes its progress to the information stream.
    #>
    [OutputType([object])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    return Invoke-Pester -Path $Path -PassThru 6>$null
}

if ($Child) {
    # A NEW variable rather than reassigning the parameter. $PesterVersion is declared [string[]],
    # and a typed parameter re-applies its constraint on every assignment -- so assigning one
    # element back to it produces a one-element ARRAY again, and [version] on it then fails with a
    # cast error naming String[] and nothing about Pester.
    $compatVersion = @($PesterVersion)[0]

    # ABSENT is a third answer, distinct from "broken here" and "the module is wrong". The import
    # failure alone says "no valid module file was found", which reads as this module failing
    # under a version nobody installed.
    if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -eq [version]$compatVersion })) {
        Write-Output "MISSING: Pester $compatVersion is not installed on this machine."
        Write-Output 'The gate proves nothing without it. Install it, or pass -PesterVersion.'
        exit 3
    }
    Import-Module Pester -RequiredVersion $compatVersion -Force
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSMutant.psd1') -Force

    # A THROW here is an environment failure exactly as a failed assertion is, and it has to be
    # caught to be one. Uncaught, the child dies with an ordinary non-zero exit, the caller cannot
    # tell it from a consumer failure, and it reports that this module does not work under a
    # Pester that never managed to start -- the accusation this control exists to prevent,
    # arriving through the one door it did not cover.
    try {
        $control = Invoke-PSMutantCompatControl -Path (Join-Path $FixtureRoot 'Control.Tests.ps1')
    }
    catch {
        Write-Output "ENVIRONMENT: Pester $compatVersion could not run the control on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output "This is not a PSMutant failure. The control threw: $($_.Exception.Message)"
        exit 2
    }
    # PassedCount, not FailedCount. A control that failed to PARSE reports neither, so asking only
    # about failures would read "this Pester works" from a file that never ran.
    if ($control.PassedCount -eq 0) {
        Write-Output "ENVIRONMENT: Pester $compatVersion cannot run a trivial test on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output 'This is not a PSMutant failure. The control assertion (1 + 1 = 2) failed.'
        exit 2
    }

    $r = Invoke-PSMutation -ConfigFile (Join-Path $FixtureRoot 'psmutant.json') -SourceRoot $FixtureRoot -Quiet
    Write-Output "Pester ${compatVersion}: score $($r.Score)% - $($r.Killed) killed, $($r.Survived) survived, $($r.Total) total."

    # The same three-way judgement the package gate makes, in one tested place (#27).
    $why = Get-PSMutantMutationFailure -Total $r.Total -Killed $r.Killed -Survived $r.Survived `
        -Subject "The run under Pester $compatVersion"
    if ($why) {
        Write-Output ($why + ' For this guard that means the version collision has reappeared: the child runspace is dying and its silence is being scored as a kill.')
        exit 1
    }
    exit 0
}

$installed = @(Get-Module Pester -ListAvailable | Select-Object -ExpandProperty Version -Unique)
if (@($installed).Count -lt 2) {
    throw "This guard needs at least two Pester versions installed; found: $($installed -join ', '). With one on disk a child runspace cannot resolve the WRONG one, which is the collision being tested."
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-compat-$([System.Guid]::NewGuid().ToString('N'))"
try {
    # Built ONCE, outside the loop. It is version-independent, and rebuilding it per leg would
    # mean each version proving itself against a different directory.
    $null = Build-PSMutantCompatFixture -Root $root

    # Every version is tried and every fault COLLECTED, rather than stopping at the first. The
    # legs are seconds apart and a CI round is not: learning about the second broken version only
    # after fixing the first costs another full round.
    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($version in $PesterVersion) {
        Write-Output "Proving PSMutant drives Pester $version (child process)."
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath `
            -PesterVersion $version -FixtureRoot $root -Child
        # The three non-zero codes are three different accusations, and only one is about this
        # module. Flattening them would put the blame for an absent or broken Pester here.
        switch ($LASTEXITCODE) {
            0 { }
            2 { $faults.Add("Pester ${version}: unusable on this PowerShell; the gate could not run.") }
            3 { $faults.Add("Pester ${version}: not installed; the gate could not run.") }
            default { $faults.Add("Pester ${version}: PSMutant does not drive it correctly.") }
        }
    }
    if ($faults.Count -gt 0) {
        throw ("Pester compatibility gate failed for $($faults.Count) of $(@($PesterVersion).Count) version(s):" +
            [Environment]::NewLine + (($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine))
    }
    Write-Output "Pester compatibility gate passed for $(@($PesterVersion).Count) version(s): $($PesterVersion -join ', ')."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
