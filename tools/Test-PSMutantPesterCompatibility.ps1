<#
.SYNOPSIS
    Prove PSMutant still drives a Pester it did not pick for itself.

.DESCRIPTION
    The manifest promises Pester >= 5.0.0, but this repo's own suite runs on exactly one
    pinned version -- so nothing in it exercises the case that actually broke.

    That case needs TWO versions installed and the OLDER one loaded. A child runspace
    resolves "Pester" by name and gets the newest on disk; assemblies are per-process,
    so the child dies on an incompatible Pester.dll, returns no verdict, and every
    mutant used to be classified Killed. The run reported a silent, entirely fake 100%
    -- no error, no failed test, just a perfect score over tests that never ran.

    So this loads the version the suite does NOT use and runs a real mutation over a
    fixture whose covering test is deliberately weak. A working run leaves survivors.
    A broken one reports everything killed, which is what this fails on.

.PARAMETER PesterVersion
    The version to load before running -- deliberately NOT the version the test estate
    is pinned to. Both must already be installed.

.EXAMPLE
    ./tools/Test-PSMutantPesterCompatibility.ps1 -PesterVersion 5.8.0
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string]$PesterVersion)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$installed = @(Get-Module Pester -ListAvailable | Select-Object -ExpandProperty Version -Unique)
if (@($installed).Count -lt 2) {
    throw "This guard needs two Pester versions installed; found: $($installed -join ', ')"
}

Import-Module Pester -RequiredVersion $PesterVersion -Force
Write-Host "Loaded Pester $((Get-Module Pester).Version) (newest installed: $(($installed | Sort-Object -Descending)[0]))"

Import-Module (Join-Path $root 'PSMutant.psd1') -Force

$proj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-compat-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'tests') -Force | Out-Null
try {
    # Get-Sign is asserted properly so its mutants die; Test-Flag is asserted only for
    # "does not throw", so its mutants must survive. Both halves matter: all-killed is
    # the failure being guarded against, and all-survived would mean nothing ran.
    @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
function Test-Flag { param($x) if ($x) { return $true } else { return $false } }
'@ | Set-Content (Join-Path $proj 'src/calc.ps1') -Encoding utf8

    @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos for positive' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg for non-positive' { Get-Sign -5 | Should -Be 'neg' }
}
Describe 'Test-Flag' {
    It 'returns something for a truthy input' { { Test-Flag $true } | Should -Not -Throw }
}
'@ | Set-Content (Join-Path $proj 'tests/calc.Tests.ps1') -Encoding utf8

    $configFile = Join-Path $proj 'psmutant.json'
    [ordered]@{
        sandboxSubtrees  = @('src', 'tests')
        mutate           = @('src/calc.ps1')
        tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
        coveredLinesOnly = $true
        operators        = @('BinaryOperator', 'BooleanLiteral')
        reportPath       = 'reports/compat.json'
    } | ConvertTo-Json -Depth 6 | Set-Content $configFile -Encoding utf8

    $r = Invoke-PSMutation -ConfigFile $configFile -SourceRoot $proj -Quiet
    Write-Host "Score $($r.Score)% - $($r.Killed) killed, $($r.Survived) survived, $($r.Total) total"

    if ($r.Total -le 0) { throw 'No mutants were evaluated - the fixture produced nothing to test' }
    if ($r.Killed -le 0) { throw 'Nothing was killed - the covering tests never really ran' }
    if ($r.Survived -le 0) {
        throw "Every mutant was reported Killed under Pester $PesterVersion. The under-asserted fixture MUST leave survivors, so this is the version collision reappearing: the child runspace is dying and its silence is being scored as a kill."
    }
    Write-Host "Pester $PesterVersion compatibility OK - survivors present, so mutants really were evaluated." -ForegroundColor Green
}
finally {
    Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
}
