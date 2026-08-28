<#
.SYNOPSIS
    Prove PSMutant loads and mutates identically on every supported PowerShell.

.DESCRIPTION
    The manifest declares a PowerShellVersion floor and CI runs whatever the runners ship, which is
    several minors newer. So the number consumers are told had never been executed (#157), and a
    floor nothing runs on is a claim rather than a guarantee -- the same defect the Pester gate
    beside this one closed, from the other side.

    The legs run on WINDOWS, and that is a hosting fact rather than a preference: measured on a
    current Linux image, PowerShell 7.0 dies before running a line ("No usable version of libssl
    was found" -- .NET Core 3.1 needs libssl 1.1, and Fedora 44 offers no compatibility package),
    and starting 7.2 needs an ICU package the image may not carry. The Windows archives are
    self-contained, so the floor legs can only be proven there.

    UNLIKE THE SIBLING'S EQUIVALENT, THIS GATE MUST BRING A PESTER. PSComplexity can assert
    directly because nothing in its src/ calls a Pester API; PSMutant exists to drive Pester, so a
    PowerShell leg cannot avoid choosing a version. It is pinned rather than resolved, because
    resolving by name takes the NEWEST installed: measured, Pester 6.1.0 fails on PowerShell 7.2
    with "Unable to find type [PesterConfiguration]" and works on 7.4, while its own manifest
    claims PowerShellVersion 5.1. Left unpinned, the floor leg would fail for a reason that has
    nothing to do with this module -- which is the accusation the control in the Pester gate exists
    to prevent, arriving here through the choice of dependency instead.

    Each leg runs in a SEPARATE PROCESS, because that is what a different PowerShell is. The script
    re-invokes ITSELF with -Child under the downloaded host rather than passing a here-string, so
    every line each leg runs is parsed, linted and diffable.

    EQUIVALENCE ACROSS HOSTS, not numbers written here. Each leg must reproduce what THIS host
    measured from the same fixture. Hardcoding an expected score would pin the metric a second time
    and would need editing whenever it legitimately changes -- exactly when a compatibility gate
    should keep working. The fixture is built so that one mutant dies and two survive: a run where
    everything comes back Killed is the failure this project exists to prevent, so a leg that
    observes a real kill AND a real survivor is evidence the child runspace, the Pester invocation
    and the classifier all work on that host.

.PARAMETER Version
    PowerShell versions to prove. Empty means read PS_COMPAT_VERSIONS from the environment or
    .github/pins.env, so running this by hand and running it in CI are the same run.

.PARAMETER RuntimeRoot
    Where downloaded runtimes are kept. Defaults to a stable directory under TEMP, so a second run
    on the same machine downloads nothing.

.EXAMPLE
    ./tools/Test-PSMutantPowerShellCompatibility.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Version,
    [switch]$Child,
    [string]$FixtureRoot,
    [string]$RuntimeRoot,
    [string]$PesterVersion,
    [string]$Expected
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-PSMutantPinnedList {
    # Environment first so a workflow can override, then the pins file, then nothing. Defaulting
    # to some version here would be the failure this gate exists to find: a compatibility claim
    # proven against a number nobody chose.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$RepoRoot)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not $value) {
        $pins = Join-Path -Path $RepoRoot -ChildPath '.github/pins.env'
        $value = Get-PSMutantPinValue -Line (Get-Content -LiteralPath $pins) -Name $Name
    }
    return [string[]]@($value -split ' ' | Where-Object { $_ })
}

function Build-PSMutantHostFixture {
    <#
    .SYNOPSIS
        A consumer project with one well-tested function and one barely-tested one.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root)

    New-Item -ItemType Directory -Path (Join-Path $Root 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'tests') -Force | Out-Null

    @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
function Test-Flag { param($x) if ($x) { return $true } else { return $false } }
'@ | Set-Content (Join-Path $Root 'src/calc.ps1') -Encoding utf8

    @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos for positive' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg for non-positive' { Get-Sign (-5) | Should -Be 'neg' }
}
Describe 'Test-Flag' {
    It 'returns something for a truthy input' { { Test-Flag $true } | Should -Not -Throw }
}
'@ | Set-Content (Join-Path $Root 'tests/calc.Tests.ps1') -Encoding utf8

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

function Get-PSMutantHostRow {
    <#
    .SYNOPSIS
        One mutation run reduced to a canonical string, for comparing hosts.
    .DESCRIPTION
        Every mutant, sorted, with its verdict -- not just the score. Two hosts can reach the same
        percentage while disagreeing about WHICH mutants died, and that disagreement is precisely
        what a host difference would look like.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$ReportPath)
    $rows = @(
        "score=$($Result.Score) killed=$($Result.Killed) survived=$($Result.Survived) total=$($Result.Total)"
    )
    $doc = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $rows += @($doc.mutants | ForEach-Object { "$($_.line)|$($_.description)|$($_.status)" } | Sort-Object)
    return ($rows -join [Environment]::NewLine)
}

function Get-PSMutantRuntimeArchive {
    <#
    .SYNOPSIS
        The download URL and archive name for one PowerShell version on this platform.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PSVersion)
    $name = $IsWindows ? "PowerShell-$PSVersion-win-x64.zip" : "powershell-$PSVersion-linux-x64.tar.gz"
    return @{
        Name = $name
        Uri  = "https://github.com/PowerShell/PowerShell/releases/download/v$PSVersion/$name"
    }
}

function Install-PSMutantRuntime {
    <#
    .SYNOPSIS
        The pwsh path for one version, downloading and unpacking it only if it is not there.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PSVersion,
        [Parameter(Mandatory)] [string]$Root
    )
    $dir = Join-Path $Root $PSVersion
    # A ternary, not `(if ...)`. An if EXPRESSION is fine on the right of an assignment but not as
    # a command ARGUMENT: PowerShell parses `Join-Path $dir (if ...)` as a call to a command named
    # `if`, and the gate then reports every runtime as un-downloadable.
    $exe = Join-Path $dir ($IsWindows ? 'pwsh.exe' : 'pwsh')
    if (Test-Path -LiteralPath $exe) { return $exe }

    $archive = Get-PSMutantRuntimeArchive -PSVersion $PSVersion
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $Root $archive.Name
    # No progress written HERE: this function returns a path, and PSAvoidUsingWriteHost is not
    # excluded in this repo. The caller narrates.
    Invoke-WebRequest -Uri $archive.Uri -OutFile $file -UseBasicParsing
    if ($IsWindows) {
        Expand-Archive -LiteralPath $file -DestinationPath $dir -Force
    }
    else {
        tar -xzf $file -C $dir
        chmod +x $exe
    }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "PowerShell $PSVersion unpacked without producing $exe."
    }
    return $exe
}

if ($Child) {
    # FIRST, and load-bearing: it is how the caller tells a host that NEVER STARTED from a module
    # that misbehaved. PowerShell 7.0 and 7.1 are built on .NET Core 3.1 and .NET 5 and need
    # libssl 1.1, which a current Linux distribution no longer ships -- they die with "No usable
    # version of libssl was found" before executing a single line of this file, and the process
    # exit code alone is indistinguishable from a real difference. Borrowed from the sibling's
    # equivalent gate, which had it and this one did not.
    Write-Output "STARTED $($PSVersionTable.PSVersion)"

    # ABSENT is a distinct answer from broken, exactly as in the Pester gate.
    if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -eq [version]$PesterVersion })) {
        Write-Output "MISSING: Pester $PesterVersion is not installed where PowerShell $($PSVersionTable.PSVersion) can see it."
        exit 3
    }
    Import-Module Pester -RequiredVersion $PesterVersion -Force
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSMutant.psd1') -Force

    # THE CONTROL, and CI proved it was missing. Before any mutation, run the fixture's OWN suite
    # on this host. Without it, a fixture that does not pass here is indistinguishable from the
    # module misbehaving: the 7.0 leg failed with "Baseline suite is not green" and the gate
    # reported "PSMutant does not behave identically on it", which blamed the wrong code.
    #
    # This is the same control the Pester gate carries, and it was left out here on the assumption
    # that a fixture this small is portable. Observed, on 7.0 only -- 7.1 through 7.5 were
    # identical: `Get-Sign -5` did not return what every other host returns. The exact parsing
    # reason is not established here and the fixture no longer depends on it, since the call is
    # parenthesised; what matters is that a fixture difference now REPORTS as one.
    $control = Invoke-Pester -Path (Join-Path $FixtureRoot 'tests') -PassThru 6>$null
    if ($control.FailedCount -gt 0 -or $control.PassedCount -eq 0) {
        Write-Output "FIXTURE: the compatibility fixture's own suite does not pass on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output 'This is not a PSMutant failure -- nothing was mutated. The fixture is not portable to this host.'
        foreach ($f in $control.Failed) { Write-Output "  FAILED: $($f.Name)" }
        exit 4
    }

    $config = Join-Path $FixtureRoot 'psmutant.json'
    $result = Invoke-PSMutation -ConfigFile $config -SourceRoot $FixtureRoot -Quiet
    $row = Get-PSMutantHostRow -Result $result -ReportPath (Join-Path $FixtureRoot 'reports/compat.json')
    if ($row -ne $Expected) {
        Write-Output "PowerShell $($PSVersionTable.PSVersion) measured something different from the host that launched it."
        Write-Output "--- expected ---"; Write-Output $Expected
        Write-Output "--- actual ---";   Write-Output $row
        exit 1
    }
    Write-Output "PowerShell $($PSVersionTable.PSVersion): identical to the launching host."
    exit 0
}

# Whether the list came from the shipped pins or from the caller, because the floor check below
# applies to one and not the other.
$fromPins = -not $Version
if ($fromPins) { $Version = Get-PSMutantPinnedList -Name 'PS_COMPAT_VERSIONS' -RepoRoot $repoRoot }
if (-not $Version) {
    throw 'PS_COMPAT_VERSIONS is set neither in the environment nor in .github/pins.env. Refusing to run: a compatibility gate over zero versions passes every time.'
}
if (-not $PesterVersion) {
    $PesterVersion = @(Get-PSMutantPinnedList -Name 'PS_COMPAT_PESTER' -RepoRoot $repoRoot)[0]
}
if (-not $PesterVersion) {
    throw 'PS_COMPAT_PESTER is set neither in the environment nor in .github/pins.env. This gate drives Pester, so it cannot pick one by accident: resolving by name takes the newest, which does not load on the oldest supported host.'
}
# Only for the SHIPPED list. An explicit -Version is how a single failing leg gets reproduced, and
# refusing that because one run does not cover the floor would make the gate hardest to use exactly
# when it has just found something. The shipped configuration is asserted by the suite as well,
# which is where the guarantee actually lives.
if ($fromPins) {
    $floorFault = Get-PSMutantHostFloorFault `
        -Declared (Import-PowerShellDataFile (Join-Path $repoRoot 'PSMutant.psd1')).PowerShellVersion -Leg $Version
    if ($floorFault) { throw $floorFault }
}
else {
    Write-Output "Running an explicit subset ($($Version -join ', ')); the floor check applies to the shipped list, which the suite asserts."
}

if (-not $RuntimeRoot) { $RuntimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'psmut-pwsh' }
New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
$root = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-host-$([System.Guid]::NewGuid().ToString('N'))"
try {
    # Built ONCE and measured ONCE, on the host running this script. That measurement is the
    # expectation every leg is held to.
    $null = Build-PSMutantHostFixture -Root $root
    Import-Module Pester -RequiredVersion $PesterVersion -Force
    Import-Module (Join-Path $repoRoot 'PSMutant.psd1') -Force
    $baseline = Invoke-PSMutation -ConfigFile (Join-Path $root 'psmutant.json') -SourceRoot $root -Quiet
    $expected = Get-PSMutantHostRow -Result $baseline -ReportPath (Join-Path $root 'reports/compat.json')
    Write-Output "This host ($($PSVersionTable.PSVersion), Pester $PesterVersion) measured:"
    Write-Output $expected

    # A fixture that only ever passes cannot tell a working gate from one that returns success
    # unconditionally. Refusing here rather than in each leg means the failure names the fixture.
    if ($baseline.Killed -lt 1 -or $baseline.Survived -lt 1) {
        throw "The fixture must produce BOTH a kill and a survivor, or a leg proves nothing; this host saw killed=$($baseline.Killed) survived=$($baseline.Survived)."
    }

    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $Version) {
        Write-Output "Proving PowerShell $v (downloading if absent)."
        try { $exe = Install-PSMutantRuntime -PSVersion $v -Root $RuntimeRoot }
        catch {
            # A runtime that cannot be OBTAINED is reported as that, never as the module failing.
            $faults.Add("PowerShell ${v}: could not be downloaded or unpacked -- $($_.Exception.Message)")
            continue
        }
        # Captured rather than streamed, so the STARTED marker can be looked for. Written out
        # afterwards either way: a leg that fails is exactly when its output is wanted.
        $out = & $exe -NoProfile -File $PSCommandPath -Version $v -FixtureRoot $root `
            -PesterVersion $PesterVersion -Expected $expected -Child 2>&1
        $code = $LASTEXITCODE
        $out | ForEach-Object { Write-Output "  $_" }
        if (-not (@($out) -match '^STARTED ')) {
            $faults.Add("PowerShell ${v}: the host never started, so nothing was proven about this module. On Linux this is usually a missing system library the old runtime needs.")
            continue
        }
        switch ($code) {
            0 { }
            3 { $faults.Add("PowerShell ${v}: Pester $PesterVersion not visible from that host; the gate could not run.") }
            4 { $faults.Add("PowerShell ${v}: the FIXTURE does not run there, so nothing was proven about this module.") }
            default { $faults.Add("PowerShell ${v}: PSMutant does not behave identically on it.") }
        }
    }
    if ($faults.Count -gt 0) {
        throw ("PowerShell compatibility gate failed for $($faults.Count) of $(@($Version).Count) version(s):" +
            [Environment]::NewLine + (($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine))
    }
    Write-Output "PowerShell compatibility gate passed for $(@($Version).Count) version(s): $($Version -join ', ')."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
