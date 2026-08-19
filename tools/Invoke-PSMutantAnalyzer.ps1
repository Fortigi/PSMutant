<#
.SYNOPSIS
    Run PSScriptAnalyzer the one way this project runs it, and return the findings.

.DESCRIPTION
    Two workflows analyse this repo: the lint gate in ci.yml, which fails the build, and
    code-scanning.yml, which uploads SARIF and is a REQUIRED check. They each spelled the
    invocation out inline, sharing PSSA_PATHS and the settings file but not the severity
    filter -- ci.yml passed `-Severity Error, Warning` and code scanning passed nothing.

    So every Information-severity rule was invisible to the gate that fails and visible to
    the gate that blocks. A finding in that band passed lint, locally and in CI, and then
    surfaced as a code scanning alert where nobody was looking. It happened twice in one
    PR (#76): PSUseOutputTypeCorrectly fired on Get-PSMutationCandidate after a change to
    how it builds its return value, and a second instance had been sitting unnoticed in
    Get-PSMutantUnloadedFile.

    Dropping the filter from ci.yml would have fixed that instance. This exists so the
    class cannot recur: there is now one definition of how the analyzer is invoked, and
    both workflows call it. That is the same reason Measure-PSMutantCoverage.ps1 exists
    rather than living in ci.yml -- a gate spelled out in two places is a gate that will
    eventually disagree with itself.

    Paths and the analyzer version come from .github/pins.env, read directly when the
    environment does not already carry them, so running this by hand is identical to
    running it in CI without any setup step.

.OUTPUTS
    [object[]] the findings, empty when clean. Callers decide what to do with them: ci.yml
    throws, code-scanning.yml converts them to SARIF.

.EXAMPLE
    ./tools/Invoke-PSMutantAnalyzer.ps1
    # Nothing printed and an empty result means clean.

.EXAMPLE
    $findings = ./tools/Invoke-PSMutantAnalyzer.ps1
    $findings | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize
#>
[CmdletBinding()]
param(
    # Defaults to PSSA_PATHS. Override only to analyse a subset while iterating; the gates
    # must always run the full set.
    [string[]]$Path,

    # Defaults to PSSA_VERSION. The exact version matters: rules and their inference change
    # between releases, so an unpinned analyzer can report a finding CI does not, or miss one
    # it does.
    [string]$AnalyzerVersion
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-PSMutantPin {
    # One pinned value, preferring what the environment already holds.
    #
    # The workflows load pins.env into $env: after checkout, so in CI this reads the
    # environment. Run by hand there is no such step, and falling back to the file is what
    # stops a local run from using a different analyzer or a different path list than the
    # gate does. The parsing itself is Get-PSMutantPinValue, which is tested.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)

    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if ($fromEnv) { return $fromEnv }

    $pins = Join-Path -Path $repoRoot -ChildPath '.github' -AdditionalChildPath 'pins.env'
    $value = Get-PSMutantPinValue -Line (Get-Content $pins) -Name $Name
    if (-not $value) { throw "$Name is set neither in the environment nor in $pins." }
    return $value
}

if (-not $Path) { $Path = (Get-PSMutantPin -Name 'PSSA_PATHS') -split ' ' | Where-Object { $_ } }
if (-not $AnalyzerVersion) { $AnalyzerVersion = Get-PSMutantPin -Name 'PSSA_VERSION' }

# Refuse to analyse nothing. Without this an empty or misparsed PSSA_PATHS makes both gates
# report clean over zero files -- a lint gate that cannot fail, which looks exactly like a
# lint gate that has nothing to say.
if (@($Path).Count -eq 0) { throw 'No paths to analyse: PSSA_PATHS resolved to nothing.' }
foreach ($p in $Path) {
    if (-not (Test-Path (Join-Path -Path $repoRoot -ChildPath $p))) {
        throw "PSSA_PATHS names '$p', which does not exist under $repoRoot."
    }
}

Import-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion

$settings = Join-Path -Path $repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'

# NO -Severity. Rules are excluded by name in the settings file, with a reason, which is a
# decision someone made; a severity filter mutes a whole band nobody decided about. One
# invocation, every rule, both gates.
#
# -Path takes a single item, so the loop is required rather than stylistic: passing the
# array fails with "Cannot convert 'System.Object[]' to the type 'System.String'".
$findings = $Path | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings }

# @() so a single finding is still a collection and callers can count it. No comma-wrap:
# callers pipe this, and `, $array` would enter the pipeline as one item.
return [object[]]@($findings)
