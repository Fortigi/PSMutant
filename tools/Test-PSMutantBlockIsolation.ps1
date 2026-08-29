<#
.SYNOPSIS
    Assert every Pester block in the covering suites still passes when run on its own.

.DESCRIPTION
    Running one Describe or Context is the normal inner loop while working on a file -- the VS Code
    Pester adapter and -FullNameFilter both do it. A block that only passes because a sibling ran
    first fails for reasons unrelated to what it asserts, which costs time and trains people to
    distrust the suite.

    Worse than the ergonomics: a top-level `$script:` assignment runs during Pester's DISCOVERY
    phase and never reaches the run phase, so such a block does not merely lose its fixture -- it
    silently reads whatever a sibling Describe's BeforeAll left under the same name. Measured here,
    a Describe naming GetTempPath() was reading a fake repo under TestDrive, and passed for two
    releases because its assertions only ever checked a file name.

    This is the SYMPTOM half. tests/SuiteHygiene.Tests.ps1 catches the cause statically and
    instantly; the two are kept apart for the reason the order-independence gate keeps its two
    halves apart -- this one is a probe over the blocks that exist rather than a proof, while the
    static check fires on a file that leaks whether or not anything reads it yet.

    Throws on a fault, so the exit code is the answer and running it by hand is the same as
    passing it.

.PARAMETER TestPath
    Test files to check. Defaults to the covering suites named in psmutant.self.config.json --
    the files a mutant's verdict actually depends on.

.PARAMETER PassThru
    Return the faults instead of throwing.

.OUTPUTS
    [string[]] with -PassThru; nothing otherwise.
#>
[CmdletBinding()]
[OutputType([string[]])]
param(
    [string[]]$TestPath,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not $TestPath) {
    $cfg = Get-Content -LiteralPath (Join-Path $repo 'psmutant.self.config.json') -Raw | ConvertFrom-Json
    $TestPath = @($cfg.tests.PSObject.Properties.Value | ForEach-Object { $_ } | Sort-Object -Unique |
            ForEach-Object { Join-Path $repo $_ })
}
$files = @($TestPath | Where-Object { Test-Path -LiteralPath $_ })
if (-not $files) {
    throw "No test files to check. A run over zero files passes every block it did not look at, which is the failure this gate exists to find."
}

$faults = [System.Collections.Generic.List[string]]::new()
$checked = 0
foreach ($f in $files) {
    # Discovery only: gives the block tree without running anything.
    $d = New-PesterConfiguration
    $d.Run.Path = $f; $d.Run.PassThru = $true; $d.Run.SkipRun = $true; $d.Output.Verbosity = 'None'
    $tree = Invoke-Pester -Configuration $d

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($container in $tree.Containers) {
        foreach ($block in $container.Blocks) {
            # The finest granularity that is a fixture BOUNDARY. An It shares its Describe's
            # BeforeAll by design, so isolating one would report a fault for the arrangement
            # Pester documents; a Context is where a file may legitimately keep its own setup.
            foreach ($inner in $block.Blocks) { $names.Add("$($block.Name).$($inner.Name)") }
            if (-not $block.Blocks) { $names.Add($block.Name) }
        }
    }
    if (-not $names) {
        $faults.Add("$(Split-Path $f -Leaf) declares no Pester block. Either it is not a test file or discovery has changed shape, and every block below would pass over it in silence.")
        continue
    }

    foreach ($name in ($names | Sort-Object -Unique)) {
        $checked++
        $c = New-PesterConfiguration
        $c.Run.Path = $f; $c.Run.PassThru = $true; $c.Output.Verbosity = 'None'
        # Escaped: a block name may contain characters the filter treats as wildcards, and an
        # over-broad filter runs siblings, which is the one thing this gate must not do.
        $c.Filter.FullName = "$name.*"
        $r = Invoke-Pester -Configuration $c
        if ($r.FailedCount -gt 0) {
            $first = @($r.Failed)[0]
            $why = ($first.ErrorRecord[0].Exception.Message -split [Environment]::NewLine)[0]
            $faults.Add("$(Split-Path $f -Leaf) :: '$name' fails when run on its own ($($r.FailedCount) test(s)); first: $($first.ExpandedName) -- $why")
        }
        elseif ($r.PassedCount -eq 0) {
            $faults.Add("$(Split-Path $f -Leaf) :: '$name' ran ZERO tests when filtered to itself, so this gate proved nothing about it.")
        }
    }
}

if ($PassThru) { return [string[]]@($faults) }

if ($faults) {
    $body = ($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "Block isolation: $($faults.Count) fault(s) across $($files.Count) file(s), $checked block(s).$([Environment]::NewLine)$body"
}
Write-Output "Block isolation: $checked block(s) across $($files.Count) file(s) each pass alone."
