<#
.SYNOPSIS
    Report pinned modules that have a newer release on the PowerShell Gallery.

.DESCRIPTION
    A pin is a decision that was correct on the day it was made. Nothing watched them here, and
    the failure mode is asymmetric: a stale pin never breaks the build, it just quietly stops
    protecting you. The sibling repo's pin on THIS module sat at 0.1.0 across two majors -- one
    of which fixed a bug that scored every mutant killed -- and its CI was green throughout.

    Reports rather than throws. A stale pin is a decision to make, not a build to break, and a
    scheduled job that goes red for something nobody chose gets muted -- the same outcome as
    not watching.

.OUTPUTS
    [string[]] one sentence per stale or unverifiable pin. Empty means every pin is current.
#>
[CmdletBinding()]
[OutputType([string[]])]
param([string]$PinsPath)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')
$repo = Split-Path -Parent $PSScriptRoot
if (-not $PinsPath) { $PinsPath = Join-Path $repo '.github/pins.env' }
if (-not (Test-Path -LiteralPath $PinsPath)) { throw "Cannot check pins: '$PinsPath' does not exist." }

$pins = Get-Content -LiteralPath $PinsPath
# Gallery name -> pins.env key. BOTH Pester keys are watched and they are different decisions:
# PESTER_VERSION is the estate pin, PESTER_COMPAT_VERSION is the OTHER version the
# compatibility guard runs under, and it is deliberately old. They go stale independently, and
# the compat pin going stale is the one that would quietly stop proving the >= 5.0.0 promise.
# PESTER_COMPAT_VERSION is deliberately absent: it is the version the suite does NOT use, and
# "is there a newer one" is the wrong question for a pin whose purpose is to be behind. Its
# invariant -- that it differs from the estate pin, and is older -- is checked separately below.
$watched = @(
    @{ Name = 'Pester';           Key = 'PESTER_VERSION' }
    @{ Name = 'PSScriptAnalyzer'; Key = 'PSSA_VERSION' }
    @{ Name = 'PSComplexity';     Key = 'PSCOMPLEXITY_VERSION' }
    @{ Name = 'ConvertToSARIF';   Key = 'CONVERTTOSARIF_VERSION' }
)

# Queried once per module, not once per key: two keys naming Pester must not cost two calls.
$latestByName = @{}
foreach ($name in ($watched.Name | Sort-Object -Unique)) {
    try { $latestByName[$name] = [string](Find-Module -Name $name -ErrorAction Stop).Version }
    catch {
        # Left empty on purpose: the decision reports "could not look" as its own fault rather
        # than as good news.
        $latestByName[$name] = ''
        Write-Verbose "Find-Module failed for ${name}: $($_.Exception.Message)"
    }
}

$faults = [System.Collections.Generic.List[string]]::new()
foreach ($w in $watched) {
    $pinned = Get-PSMutantPinValue -Line $pins -Name $w.Key
    $fault = Get-PSMutantStalePinFault -Name "$($w.Name) ($($w.Key))" -Pinned $pinned -Latest $latestByName[$w.Name]
    if ($fault) { $faults.Add($fault) }
}

# The compatibility pin, on its own terms.
$compat = Get-PSMutantCompatPinFault `
    -EstateVersion (Get-PSMutantPinValue -Line $pins -Name 'PESTER_VERSION') `
    -CompatVersion (Get-PSMutantPinValue -Line $pins -Name 'PESTER_COMPAT_VERSION')
if ($compat) { $faults.Add($compat) }

return [string[]]@($faults)
