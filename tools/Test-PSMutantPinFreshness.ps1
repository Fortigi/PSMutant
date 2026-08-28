<#
.SYNOPSIS
    Report pinned modules that have a newer release on the PowerShell Gallery.

.DESCRIPTION
    A pin is a decision that was correct on the day it was made. Nothing watched them here, and
    the failure mode is asymmetric: a stale pin never breaks the build, it just quietly stops
    protecting you. A consumer's pin on a gating module sat at 0.1.0 across two majors -- one
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
# PESTER_VERSION is the estate pin. PESTER_COMPAT_VERSIONS is deliberately absent from this
# list: those legs are the versions the suite does NOT use, and "is there a newer one" is the
# wrong question for pins whose purpose is to be behind. Their invariant -- that the list still
# reaches below the estate pin, and covers the declared floor -- is checked separately below.
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

# The compatibility legs, on their own terms. The floor comes from the module's own guard rather
# than a number repeated here: a copy would be one more place for the promise to drift from what
# the code enforces, which is the drift #161 was filed about.
$floor = Get-PSMutantPesterFloor -Line (Get-Content -LiteralPath (Join-Path $repo 'src/PSMutation.Pester.ps1'))
$compat = Get-PSMutantCompatPinFault `
    -EstateVersion (Get-PSMutantPinValue -Line $pins -Name 'PESTER_VERSION') `
    -CompatVersion @((Get-PSMutantPinValue -Line $pins -Name 'PESTER_COMPAT_VERSIONS') -split ' ' | Where-Object { $_ }) `
    -FloorVersion $floor
if ($compat) { $faults.Add($compat) }

# --- the LISTS, against what has actually been released -------------------------------------------
# The guard above asks whether the Pester list still holds together INTERNALLY -- reaches below the
# estate pin, covers the declared floor. It cannot see the world move: every leg could be current
# and the list still be missing a minor that shipped last week.
#
# That gap is the whole point. PSMutant.psd1 says PowerShellVersion = '7.0' and the module requires
# Pester >= 5.2.0, neither with an upper bound, so EVERY version released from now on is already
# promised. A promise that grows by itself needs a watcher; nothing was watching these two lists.
#
# Asked as three tiers rather than one "something is newer", because they are three different
# decisions: a patch bump is mechanical, a new minor is a small choice, and a whole new major may
# not run at all. Flattening them puts the same weight on all three and the one that matters reads
# as noise.
$lists = @(
    @{ Name = 'Pester'; Key = 'PESTER_COMPAT_VERSIONS'; ExemptKey = 'PESTER_COMPAT_EXEMPT_MINORS'; Source = 'gallery' }
    @{ Name = 'PowerShell'; Key = 'PS_COMPAT_VERSIONS'; ExemptKey = 'PS_COMPAT_EXEMPT_MINORS'; Source = 'github' }
)
foreach ($list in $lists) {
    $ours = @((Get-PSMutantPinValue -Line $pins -Name $list.Key) -split ' ' | Where-Object { $_ })
    $exempt = @((Get-PSMutantPinValue -Line $pins -Name $list.ExemptKey) -split ' ' | Where-Object { $_ })
    $available = @()
    try {
        if ($list.Source -eq 'gallery') {
            $available = @(Find-Module -Name $list.Name -AllVersions -ErrorAction Stop | ForEach-Object { [string]$_.Version })
        }
        else {
            # PowerShell is a RUNTIME, not a gallery module, so its releases come from where the
            # compatibility gate downloads them. Prereleases are excluded: a leg pins something
            # installable, and reporting a beta as an uncovered minor would be noise every month.
            #
            # PAGED, and that is not tidiness. One page of 100 reaches back only to 7.2.3 -- so a
            # single request cannot see 7.0 or 7.1 at all, and the watcher would be blind to its own
            # FLOOR going stale while reporting cheerfully on everything newer. A checker whose
            # blind spot is the oldest thing it guards is worse than none.
            #
            # The cap exists so a paging bug cannot turn a weekly job into an unbounded crawl; ten
            # pages is roughly triple the releases that exist above the floor today.
            #
            # Assigned WITHOUT @( ), which is the opposite of the usual advice and is load-bearing.
            # Invoke-RestMethod hands back a JSON array as a SINGLE object, so @( ) wraps rather than
            # flattens: the result is one element whose .tag_name is every tag at once, .Count is 1,
            # the loop breaks after one page, and the filter removes the lone nested entry. The
            # symptom is a watcher that silently sees nothing while reporting no faults.
            $available = @()
            for ($page = 1; $page -le 10; $page++) {
                $batch = Invoke-RestMethod -ErrorAction Stop -Headers @{ 'User-Agent' = 'PSMutant-pin-freshness' } `
                    -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=100&page=$page"
                if (-not $batch) { break }
                $available += @($batch | Where-Object { -not $_.prerelease } | ForEach-Object { $_.tag_name -replace '^v', '' })
                if ($batch.Count -lt 100) { break }
            }
        }
    }
    catch {
        # Left empty on purpose, exactly as above: the decision reports "could not look" itself.
        Write-Verbose "Version lookup failed for $($list.Name): $($_.Exception.Message)"
    }
    foreach ($f in (Get-PSMutantVersionListFault -Name $list.Name -Ours $ours -Available $available -ExemptMinor $exempt)) {
        $faults.Add($f)
    }
}

return [string[]]@($faults)
