<#
.SYNOPSIS
    Load a STAGED PSMutant package and prove it works, before it is published.

.DESCRIPTION
    A version on the PowerShell Gallery cannot be replaced or withdrawn, so the package is
    the one artifact in this project whose defects are permanent. Until this script existed
    it was also the only artifact nothing ever loaded: `publish.yml` assembled it from a
    hand-maintained copy list and pushed it, and the first execution of that exact folder
    happened on a consumer's machine.

    Four checks, cheapest first:

      1. the manifest parses and its declared version is the one being shipped
      2. every .ps1 in the package's src/ is dot-sourced by the package's .psm1 -- the
         realistic packaging failure, since `Copy-Item ./src -Recurse` ships a new file
         whether or not anyone remembered to add it to the load list
      3. the package imports IN A FRESH PROCESS and every name in FunctionsToExport
         resolves -- a consumer's first two minutes, reproduced
      4. a real mutation run over a throwaway fixture returns a sane, non-vacuous result

    Check 4 is the one that matters. The fixture's covering test is deliberately weak, so a
    working package MUST report both kills and survivors; a package that reports everything
    killed, or nothing at all, is broken in exactly the way #16 was.

.PARAMETER Path
    The staged module folder -- the directory Publish-Module will push. Must be named
    PSMutant and contain the manifest.

.EXAMPLE
    ./tools/Test-PSMutantPackage.ps1 -Path /tmp/PSMutant
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string]$Path)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')

$stage = (Resolve-Path $Path).Path
Write-Host "Testing staged package: $stage"

# --- 1. the manifest -------------------------------------------------------------------
$manifestPath = Join-Path $stage 'PSMutant.psd1'
if (-not (Test-Path $manifestPath)) { throw "No PSMutant.psd1 in the staged package at $stage" }
$manifest = Test-ModuleManifest $manifestPath
Write-Host "  manifest OK - $($manifest.Name) $($manifest.Version)"

# --- 2. every shipped source file is actually loaded ------------------------------------
# Copy-Item ./src -Recurse ships every file; PSMutant.psm1 dot-sources an explicit list.
# A file in the first and not the second imports cleanly and is silently missing its
# functions, which is unfixable once published.
$psm1 = Get-Content (Join-Path $stage 'PSMutant.psm1') -Raw
$shipped = Get-ChildItem (Join-Path $stage 'src') -Filter *.ps1 -Recurse
$unloaded = @(Get-PSMutantUnloadedFile -RootModuleText $psm1 -ShippedName $shipped.Name)
if ($unloaded.Count -gt 0) {
    throw ("These files ship in the package but are never dot-sourced by PSMutant.psm1: " +
        ($unloaded -join ', '))
}
Write-Host "  all $($shipped.Count) shipped src file(s) are dot-sourced"

# --- 3 and 4. import in a FRESH process and run a real mutation --------------------------
# A fresh process, because importing here would be indistinguishable from the repo copy
# already loaded in this session -- which is the mistake that let #16 survive so long.
$proj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-pkg-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'tests') -Force | Out-Null
try {
    # Get-Sign is asserted properly so its mutants die; Test-Flag is asserted only for
    # "does not throw", so its mutants must survive. Both halves matter: all-killed is the
    # #16 failure, and all-survived would mean the covering tests never ran.
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
        reportPath       = 'reports/package.json'
    } | ConvertTo-Json -Depth 6 | Set-Content $configFile -Encoding utf8

    $child = @'
param($Stage, $ConfigFile, $SourceRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Stage 'PSMutant.psd1') -Force

$declared = (Import-PowerShellDataFile (Join-Path $Stage 'PSMutant.psd1')).FunctionsToExport
foreach ($name in $declared) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "FunctionsToExport names '$name' but importing the package does not provide it"
    }
}
Write-Host "  exports resolve: $($declared -join ', ')"

$r = Invoke-PSMutation -ConfigFile $ConfigFile -SourceRoot $SourceRoot -Quiet
"RESULT|$($r.Total)|$($r.Killed)|$($r.Survived)|$($r.Score)"
'@
    $childFile = Join-Path $proj 'child.ps1'
    $child | Set-Content $childFile -Encoding utf8

    $output = & pwsh -NoProfile -File $childFile -Stage $stage -ConfigFile $configFile -SourceRoot $proj
    if ($LASTEXITCODE -ne 0) { throw "The staged package failed to load or run (exit $LASTEXITCODE)" }
    $output | Where-Object { $_ -notlike 'RESULT|*' } | ForEach-Object { Write-Host $_ }

    $line = $output | Where-Object { $_ -like 'RESULT|*' } | Select-Object -Last 1
    if (-not $line) { throw 'The staged package produced no mutation result' }
    $null, $total, $killed, $survived, $score = $line -split '\|'
    Write-Host "  mutation run: score $score% - $killed killed, $survived survived, $total total"

    # One tested decision, shared with the compatibility guard (#27).
    $why = Get-PSMutantMutationFailure -Total ([int]$total) -Killed ([int]$killed) -Survived ([int]$survived) -Subject 'The staged package'
    if ($why) { throw $why }

    Write-Host 'Staged package OK - it imports, exports what it declares, and mutates correctly.' -ForegroundColor Green
}
finally {
    Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
}
