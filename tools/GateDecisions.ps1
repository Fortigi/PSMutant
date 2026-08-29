<#
.SYNOPSIS
    The pass/fail decisions the CI gates make, as pure functions.

.DESCRIPTION
    The scripts in tools/ decide whether this project's own quality claims hold, and they
    were the only code here that nothing examined -- no tests, no coverage, no mutants
    (issue #27). The failure mode is specific and total: an inverted comparison or a default
    quietly lowered, and a gate passes forever while the number it prints becomes fiction.

    The orchestration around these decisions is not worth testing directly -- running Pester,
    staging a package, spawning a child process -- and it is not worth mutating either: those
    scripts are side effects end to end, so every mutant would cost a full gate run. The
    DECISIONS are a different matter. They are arithmetic and string comparison, they are
    where an inversion hides, and they are free to test.

    Each returns a REASON STRING when the gate should fail, or $null when it should pass.
    Returning the reason rather than throwing keeps them pure, lets the caller decide how to
    report, and makes the tests read as a table of inputs to verdicts.
#>

function Get-PSMutantCoverageFailure {
    <#
    .SYNOPSIS
        Why the coverage gate should fail, or $null if it should pass.
    .DESCRIPTION
        A red suite is checked first and separately. Lines are still executed on the way to a
        failure, so a broken build can still measure 100% -- reporting the percentage in that
        state would be worse than reporting nothing.

        The boundary is inclusive: coverage exactly equal to the minimum passes. A gate that
        rejected its own target would be unmeetable.
    .OUTPUTS
        [string] the reason, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Percent,
        [Parameter(Mandatory)] [double]$Minimum,
        [int]$FailedTestCount = 0
    )
    if ($FailedTestCount -gt 0) {
        return "$FailedTestCount test(s) failed - the coverage figure would not mean anything"
    }
    if ($Percent -lt $Minimum) {
        return "Coverage $Percent% is below the required $Minimum%"
    }
    return $null
}

function Get-PSMutantLintFault {
    <#
    .SYNOPSIS
        Why the lint gate should fail, or $null if it should pass.
    .DESCRIPTION
        One finding is enough. Severity plays no part here and no -Severity filter reaches the
        analyzer either: rules are excluded by NAME in PSScriptAnalyzerSettings.psd1, each with
        a reason, so anything still reported is a rule somebody decided to keep.

        A count rather than the findings themselves, because the decision is arithmetic and the
        rendering is the caller's business.
    .OUTPUTS
        [string] the reason, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$FindingCount)
    if ($FindingCount -gt 0) {
        return "$FindingCount PSScriptAnalyzer finding(s) - lint gate failed"
    }
    return $null
}

function Get-PSMutantMutationFailure {
    <#
    .SYNOPSIS
        Why a gate's own mutation run should be rejected, or $null if it looks sane.
    .DESCRIPTION
        Shared by the package smoke test and the Pester compatibility guard, which were
        making this same three-way judgement in two places.

        Both gates run a fixture whose covering test is deliberately weak, so a working
        module MUST report kills AND survivors:

          * no mutants at all means the fixture produced nothing to test
          * nothing killed means the covering tests never really ran
          * nothing survived is the #16 failure -- a child that cannot run is silence, and
            silence used to be scored as a kill, giving a perfect and entirely fake score

        The third is the one that matters, and it is the reason "everything was killed" must
        read as broken rather than excellent.
    .OUTPUTS
        [string] the reason, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Total,
        [Parameter(Mandatory)] [int]$Killed,
        [Parameter(Mandatory)] [int]$Survived,
        [string]$Subject = 'The run'
    )
    if ($Total -le 0) { return "$Subject evaluated no mutants" }
    if ($Killed -le 0) { return "$Subject killed nothing - the covering tests never really ran" }
    if ($Survived -le 0) {
        return "$Subject reported every mutant killed. The fixture is deliberately under-asserted and MUST leave survivors, so this is broken, not a good score."
    }
    return $null
}

function Get-PSMutantUnloadedFile {
    <#
    .SYNOPSIS
        Shipped source files that the root module never dot-sources.
    .DESCRIPTION
        `Copy-Item ./src -Recurse` ships every file, while PSMutant.psm1 dot-sources an
        explicit list. A file in the first and not the second produces a package that imports
        cleanly and is silently missing its functions -- unfixable once published, because a
        Gallery version cannot be withdrawn.
    .OUTPUTS
        [string[]] the file names that are shipped but never loaded.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$RootModuleText,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ShippedName
    )
    # No comma-wrap: callers wrap in @(), and a comma would hand them one item containing
    # the array (see #38).
    #
    # Typed rather than @()-wrapped, for the same reason as Get-PSMutationCandidate: @(...)
    # infers System.Object[] and trips PSUseOutputTypeCorrectly, an Information rule the lint
    # gate's -Severity filter hides and code scanning reports.
    # The cast is on the EXPRESSION, and @() stays inside it. Both halves matter: without
    # the @() an empty result casts to $null instead of an empty array, and with the cast on
    # the variable rather than the expression the analyzer still infers System.Object[] and
    # reports PSUseOutputTypeCorrectly -- an Information rule the lint gate's -Severity
    # filter hides and code scanning surfaces.
    $unloaded = [string[]]@($ShippedName | Where-Object { $RootModuleText -notmatch [regex]::Escape($_) })
    return $unloaded
}

function Get-PSMutantHostFloorFault {
    <#
    .SYNOPSIS
        The fault, if any, between the declared PowerShell floor and the legs that execute it.
    .DESCRIPTION
        #157 in one rule: the manifest declared 7.2 and nothing ever ran on it. A floor nothing
        executes is a claim, not a guarantee, and this is what makes the two move together --
        lower the floor without adding its leg and the gate refuses.

        The floor's MINOR must be covered, not its exact patch: legs are the newest patch of each
        minor and are free to advance, which is the same rule the Pester legs follow.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Declared,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Leg
    )
    $legs = @($Leg | Where-Object { $_ })
    if ([string]::IsNullOrWhiteSpace($Declared)) {
        return 'PSMutant.psd1 declares no PowerShellVersion, so there is no floor for a leg to execute.'
    }
    if ($legs.Count -eq 0) {
        return 'PS_COMPAT_VERSIONS is empty: a compatibility gate over zero hosts passes every time.'
    }
    $floor = [version]$Declared
    $minors = @($legs | ForEach-Object { $v = [version]$_; "$($v.Major).$($v.Minor)" })
    if ($minors -notcontains "$($floor.Major).$($floor.Minor)") {
        return ("PS_COMPAT_VERSIONS has no leg on PowerShell $($floor.Major).$($floor.Minor), which is the floor " +
            "PSMutant.psd1 declares. The number consumers are told has to be one the legs execute -- " +
            'that it was not is exactly what #157 was filed about.')
    }
    foreach ($l in $legs) {
        if ([version]$l -lt $floor) {
            return ("PS_COMPAT_VERSIONS lists PowerShell $l, which is BELOW the declared floor of $Declared. " +
                'A leg under the floor either proves something nobody promised or fails for a version ' +
                'consumers were told not to use; lower the floor deliberately, or drop the leg.')
        }
    }
    return $null
}

function Get-PSMutantPesterFloor {
    <#
    .SYNOPSIS
        The Pester floor the module actually ENFORCES, read from its own guard.
    .DESCRIPTION
        Read rather than repeated. The floor appears in the manifest description, the README and
        this guard, and #161 is what happens when those drift: the promise said 5.0.0, the code
        needed 5.2.0, and nothing compared them. A gate that hard-coded the number here would be
        a fourth copy to keep in step.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Line)
    foreach ($l in $Line) {
        if ($l -match "\`$loaded\.Version -lt \[version\]'([0-9]+\.[0-9]+\.[0-9]+)'") { return $Matches[1] }
    }
    return $null
}

function Get-PSMutantCompatPinFault {
    <#
    .SYNOPSIS
        The fault, if any, in the compatibility LEG LIST.
    .DESCRIPTION
        This used to guard a single deliberately-old pin, and its invariant was difference: the
        compat version had to be OLDER than the estate version, or the guard ran under the same
        Pester as the suite and proved nothing while looking more up to date.

        It is a list now (#161), one leg per supported minor, and the invariant moves with it.
        Freshness is still the wrong question -- most of these are meant to be behind -- but
        "differs from the estate pin" no longer describes it either, because the newest leg
        legitimately IS the estate version. What has to stay true is that the list still reaches
        BELOW the estate pin: a list that crept up until every leg matched the suite's own Pester
        would pass every gate and prove nothing about the range the manifest promises.

        The floor is checked here rather than assumed, for the reason #161 exists: the number
        consumers are given must be one the legs actually execute.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$EstateVersion,
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]]$CompatVersion,
        # The floor the manifest promises. A leg must cover its MINOR -- not its exact patch,
        # which is free to advance under the newest-patch-per-minor rule.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FloorVersion
    )
    $legs = @($CompatVersion | Where-Object { $_ })
    if ([string]::IsNullOrWhiteSpace($EstateVersion) -or $legs.Count -eq 0) {
        return 'PESTER_VERSION and PESTER_COMPAT_VERSIONS must both be set: a compatibility gate over zero versions passes every time.'
    }
    $seen = @{}
    foreach ($leg in $legs) {
        if ($seen.ContainsKey($leg)) {
            return "PESTER_COMPAT_VERSIONS lists $leg twice. A repeated leg costs a whole run and proves nothing the first did not."
        }
        $seen[$leg] = $true
    }
    if (-not (@($legs | Where-Object { [version]$_ -lt [version]$EstateVersion }).Count)) {
        return ("PESTER_COMPAT_VERSIONS has no leg older than PESTER_VERSION ($EstateVersion). " +
            'Every leg would then run under a Pester at least as new as the suite uses, which ' +
            "proves nothing about the range the manifest promises.")
    }
    if ([string]::IsNullOrWhiteSpace($FloorVersion)) {
        return 'The Pester floor is not set, so nothing can check that a leg covers it.'
    }
    $floor = [version]$FloorVersion
    $minors = @($legs | ForEach-Object { $v = [version]$_; "$($v.Major).$($v.Minor)" })
    if ($minors -notcontains "$($floor.Major).$($floor.Minor)") {
        return ("PESTER_COMPAT_VERSIONS has no leg on Pester $($floor.Major).$($floor.Minor), which is the floor " +
            'the manifest promises. The number consumers are given has to be one the legs execute -- ' +
            'that it was not is exactly what #161 was filed about.')
    }
    return $null
}

function Get-PSMutantVersionMinor {
    # 'MAJOR.MINOR' for a version string, or $null when it is not one.
    #
    # Its own function because every tier below groups by it, and because a gallery feed answers
    # with prerelease strings like '6.2.0-beta1' that [version] refuses outright -- taking the part
    # before the dash keeps one bad entry from failing the whole check.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Version)
    if ($Version.Split('-')[0] -match '^(\d+)\.(\d+)') { return "$($Matches[1]).$($Matches[2])" }
    return $null
}

function Get-PSMutantVersionListFault {
    <#
    .SYNOPSIS
        Every way a per-minor compatibility list has fallen behind what has been released.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Ours,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Available,
        # Minors deliberately not covered, each of which must still exist and still be uncovered.
        [AllowEmptyCollection()] [string[]]$ExemptMinor = @()
    )
    # A single pin is stale when something newer exists. A LIST is stale in three ways, and they are
    # three different decisions -- bumping a patch is mechanical, adding a minor is a small choice,
    # and a whole new major may not run at all. Flattening them into "something is newer" would put
    # the same weight on all three, and the one that matters would be read as noise.
    $faults = [System.Collections.Generic.List[string]]::new()
    if (-not $Ours) { return [string[]]@("$Name has no compatibility versions pinned.") }
    # "Could not look" is not "nothing newer", for the same reason it is not in Get-PSMutantStalePinFault:
    # a checker that reads an unreachable feed as good news stops being able to fail.
    if (-not $Available) {
        return [string[]]@("$Name compatibility versions could not be checked; the feed did not answer, so freshness is unknown.")
    }

    $ourMinors = @($Ours | ForEach-Object { Get-PSMutantVersionMinor -Version $_ } | Where-Object { $_ })

    # The promise is open-ended UPWARD and bounded downward, so everything below the floor is out of
    # scope rather than uncovered. Without this the first run reported Pester 3.0 through 4.10 and
    # two whole majors as gaps -- versions the module never claimed and which predate the assertion
    # style the suite is written in.
    #
    # The floor is the lowest leg rather than a separate pin, because the list IS the compatibility
    # claim everywhere else in this repo, and a second source for the same number is a second thing
    # to keep in step. It cannot drift silently: tests/Release.Tests.ps1 asserts the floor's minor is
    # present, and for PowerShell ties it to the manifest's own PowerShellVersion.
    $floor = @($ourMinors | Sort-Object { [version]$_ })[0]
    $availMinors = @($Available | ForEach-Object { Get-PSMutantVersionMinor -Version $_ } |
            Where-Object { $_ -and [version]$_ -ge [version]$floor } | Sort-Object -Unique)

    # Tier 1 -- a leg that is no longer the newest patch of its own minor. The rule for these lists
    # is the newest patch of every minor, with no exception, so this needs no judgement to act on.
    foreach ($leg in $Ours) {
        $minor = Get-PSMutantVersionMinor -Version $leg
        $newest = @($Available | Where-Object { (Get-PSMutantVersionMinor -Version $_) -eq $minor } |
                Sort-Object { [version]($_.Split('-')[0]) })[-1]
        if ($newest -and [version]($newest.Split('-')[0]) -gt [version]($leg.Split('-')[0])) {
            $faults.Add("PATCH: $Name leg $leg is superseded by $newest.")
        }
    }
    # Tier 2 -- a released minor no leg covers. The promise has no upper bound, so this is a version
    # already claimed and not proven.
    foreach ($m in $availMinors) {
        if ($m -in $ourMinors -or $m -in $ExemptMinor) { continue }
        $faults.Add("MINOR: $Name $m has been released and no leg covers it.")
    }
    # Tier 3 -- a whole major nobody covers. Stated separately because it is the one that may not be
    # a bump at all: a major is where a construct disappears rather than appears.
    $ourMajors = @($ourMinors | ForEach-Object { $_.Split('.')[0] } | Sort-Object -Unique)
    foreach ($maj in @($availMinors | ForEach-Object { $_.Split('.')[0] } | Sort-Object -Unique)) {
        if ($maj -in $ourMajors) { continue }
        $faults.Add("MAJOR: $Name $maj.x exists and nothing tests it. Decide whether the supported range still means what it says.")
    }
    # An exemption is a claim, and a claim that stopped describing anything is how a list quietly
    # widens. Same rule as a stale equivalence declaration: it fails rather than being ignored.
    foreach ($ex in $ExemptMinor) {
        if ($ex -notin $availMinors) { $faults.Add("EXEMPTION: $Name $ex is exempted but has never been released.") }
        elseif ($ex -in $ourMinors) { $faults.Add("EXEMPTION: $Name $ex is exempted and also covered by a leg; one of the two is wrong.") }
    }
    return $faults.ToArray()
}

function Get-PSMutantStalePinFault {
    <#
    .SYNOPSIS
        The fault, if any, when a pinned module has a newer release available.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Pinned,
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string]$Latest
    )
    # A pin is a decision that was correct on the day it was made. Without a watcher it decays
    # into a decision nobody is making, and the failure is asymmetric: a stale pin never breaks
    # the build, it just quietly stops protecting you. Observed: a consumer's pin on a gating
    # module sat at 0.1.0 across two majors -- one of which fixed a bug that scored every mutant
    # killed -- and its CI was green throughout.
    if ([string]::IsNullOrWhiteSpace($Pinned)) { return "$Name has no pinned version in .github/pins.env." }
    # "Could not look" is not "nothing newer". Reported as its own fault, because a checker
    # that reads an unreachable gallery as good news has stopped being able to fail at all.
    if ([string]::IsNullOrWhiteSpace($Latest)) {
        return "$Name is pinned at $Pinned and the gallery did not answer, so freshness is unknown."
    }
    # Compared as versions, not strings: 6.1.0 sorts after 10.0.0 as text, so a pin AHEAD of
    # the gallery -- which a prerelease or a yanked version leaves behind -- would read stale.
    if ([version]$Latest -le [version]$Pinned) { return $null }
    return "$Name is pinned at $Pinned; $Latest is available."
}

function Get-PSMutantPinValue {
    <#
    .SYNOPSIS
        The value of one key in .github/pins.env, or $null when it is not there.
    .DESCRIPTION
        A decision rather than plumbing, and the reason it lives here: the analyzer gate
        derives the paths it scans from PSSA_PATHS. A parser that quietly returns nothing
        makes that gate scan NOTHING and pass -- green, fast, and blind. The caller turns
        $null into an error, but only because this reports it faithfully.

        Split on the FIRST '=' only. Values legitimately contain both '=' and spaces:
        PSSA_PATHS is a space-separated list. Comment and blank lines are ignored, and the
        key must match in full, so PSSA_VERSION does not answer for PSSA_VERSION_EXTRA.
    .OUTPUTS
        [string] the value, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # AllowEmptyString as well as AllowEmptyCollection: pins.env has blank lines, and a
        # Mandatory [string[]] otherwise refuses the whole file over one of them.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Line,
        [Parameter(Mandatory)] [string]$Name
    )
    foreach ($l in $Line) {
        $trimmed = $l.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        if ($trimmed.Substring(0, $split) -ne $Name) { continue }
        return $trimmed.Substring($split + 1).Trim()
    }
    return $null
}

function Get-PSMutantTestRunFault {
    <#
    .SYNOPSIS
        Pure: why a Pester run must not be treated as green, or $null when it may be.

    .DESCRIPTION
        FailedCount alone is not enough, and that is the whole reason this exists. A test
        file that fails to PARSE contributes zero tests and zero failures, so the run reports

            total=429  passed=429  failed=0      <- every gate says green
            Report.Tests.ps1  result=Failed      <- the covering suite never ran

        and each gate that asks only about the failure count agrees. Observed here, not
        theorised: appending an unclosed Describe to tests/Report.Tests.ps1 produced exactly
        that, and the unit-test gate passed.

        Only the coverage gate noticed, and for the wrong reason -- an unrun file stops
        exercising its source, so the percentage drops and the build fails talking about
        COVERAGE. That is two gates agreeing by accident, and it holds only while the
        coverage bar is 100.

    .PARAMETER FailedCount
        Failing tests in the run.

    .PARAMETER ContainerResult
        One result string per container: 'Passed', 'Failed', 'Skipped'...

    .PARAMETER ContainerName
        Names for the message, aligned with ContainerResult.

    .OUTPUTS
        [string] the fault, or $null when the run may be trusted.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$FailedCount,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ContainerResult,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ContainerName
    )
    # Failures first: when a test genuinely fails its container is 'Failed' too, and
    # "3 tests failed" points the reader somewhere better than "a file did not run".
    if ($FailedCount -gt 0) { return "$FailedCount test(s) failed." }

    $unrun = @()
    for ($i = 0; $i -lt $ContainerResult.Count; $i++) {
        # Skipped is legitimate -- a container can be filtered out deliberately. Anything
        # else, with no failures behind it, means the file did not run at all.
        if ($ContainerResult[$i] -ne 'Passed' -and $ContainerResult[$i] -ne 'Skipped') {
            $unrun += $(if ($i -lt $ContainerName.Count) { $ContainerName[$i] } else { "container $i" })
        }
    }
    if ($unrun.Count -gt 0) {
        return ("$($unrun.Count) test file(s) reported no failures because they never ran: " +
            ($unrun -join ', ') + '. A parse error in a test file looks exactly like a green suite.')
    }
    return $null
}

function Get-PSMutantProcessStateFault {
    # Why a suite run must be treated as having leaked, or $null when it has not.
    #
    # A test file can only change how a LATER file behaves if what it changed outlives it. So
    # comparing the process before against after asks the question that matters: did the suite
    # leave anything behind. That is the precondition for order-dependence, and it is
    # direction-blind -- it fires on the file that leaks rather than on the file that happens to
    # read, which is the half a reversed run can miss. The leak this repo actually shipped was an
    # AfterEach that cleared a variable and never put it back.
    #
    # Keys are named and values are NEVER printed. An environment variable holds tokens as often
    # as it holds flags, and a gate that quotes one into a public build log has turned a tidiness
    # check into a disclosure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # Process state as key -> value, keyed by the path you would type: environment variables
        # arrive as 'env:NAME'. One map rather than a parameter per kind of state, so a new kind
        # is a new key at the call site and not a new comparison here to keep in step.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Before,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$After
    )
    $added = @($After.Keys | Where-Object { -not $Before.ContainsKey($_) } | Sort-Object)
    $removed = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) } | Sort-Object)
    # Compare with -cne: on Linux two variables differing only in case are two variables, and a
    # case-insensitive compare would call a genuine change no change at all.
    $changed = @($Before.Keys |
            Where-Object { $After.ContainsKey($_) -and [string]$Before[$_] -cne [string]$After[$_] } |
            Sort-Object)

    $parts = @()
    foreach ($set in @(@{ N = 'added'; V = $added }, @{ N = 'removed'; V = $removed },
            @{ N = 'changed'; V = $changed })) {
        if ($set.V.Count -gt 0) { $parts += "$($set.N): $($set.V -join ', ')" }
    }
    if ($parts.Count -eq 0) { return $null }

    return ('The suite changed process state it did not create -- ' + ($parts -join '; ') +
        '. A test file that leaves the process different from how it found it decides what every ' +
        'file after it sees, so the answer starts depending on the order. Restore it where you ' +
        'change it. (Values are withheld: an environment variable can hold a token.)')
}


# ---------------------------------------------------------------------------------------------
# Release consistency. These lived inside tools/Test-PSMutantRelease.ps1, which made this repo
# hold two conventions for one idea: thirteen gate decisions here, nine more inside the script
# that used them. Anyone looking for "where do the tested decisions live" got the right answer
# about half the time, and the sibling repo -- which keeps all of them in one file -- grew a
# gallery-staleness check this one did not, because its decision had an obvious home and this
# one did not.
#
# The script still dot-sources this file and keeps its entry-point guard, so tests reach these
# either way.
# ---------------------------------------------------------------------------------------------

function Get-PSMutantChangelogHeading {
    # Pure: every "## [Name]" heading with its line index, in file order.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog)
    $out = [System.Collections.Generic.List[object]]::new()
    $lines = $Changelog -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+\[([^\]]+)\]') {
            $out.Add([pscustomobject]@{ Name = $Matches[1]; Index = $i })
        }
    }
    # NO comma-wrap: every caller wraps this in @(), and `, $array` would arrive as a
    # single item -- so @() would produce a one-element array containing the array, and
    # $mine[0].Index would be an array of indexes. This repo runs both conventions (#38);
    # this one is the enumerating half.
    return $out.ToArray()
}

function Get-PSMutantChangelogBody {
    # Pure: the body under one heading, or $null when that heading is absent.
    #
    # Deliberately carries NO ordering rules. Those belong to the release check, and
    # [Unreleased] can never satisfy them -- reusing the checked version here reported every
    # changelog as having nothing stranded, which is the opposite of the truth.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog,
        [Parameter(Mandatory)] [string]$Name
    )
    $lines = $Changelog -split "`r?`n"
    $headings = @(Get-PSMutantChangelogHeading -Changelog $Changelog)
    $mine = @($headings | Where-Object { $_.Name -eq $Name })
    if ($mine.Count -eq 0) { return $null }
    $start = $mine[0].Index + 1
    $next = @($headings | Where-Object { $_.Index -gt $mine[0].Index })
    # No following heading means this section runs to the end of the file.
    $end = if ($next.Count -gt 0) { $next[0].Index - 1 } else { $lines.Count - 1 }
    if ($end -lt $start) { return '' }
    return ($lines[$start..$end] -join "`n").Trim()
}

function Get-PSMutantReleaseSection {
    <#
    .SYNOPSIS
        Pure: given a changelog and the version being released, return that section's body.
    .DESCRIPTION
        Throws, naming the fix, when the release would be inconsistent:

          * a heading for the version exists -- without it the published version is one the
            changelog says was never released
          * it is the newest VERSIONED heading -- an Unreleased heading above it is
            conventional and fine, an older version above it means the file is out of order
          * its body is not empty -- a heading with nothing under it looks deliberate on a
            Gallery page that cannot be corrected afterwards
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog,
        [Parameter(Mandatory)] [string]$Version
    )

    $headings = @(Get-PSMutantChangelogHeading -Changelog $Changelog)
    $mine = @($headings | Where-Object { $_.Name -eq $Version })
    if ($mine.Count -eq 0) {
        throw "CHANGELOG.md has no heading for $Version. The manifest says $Version is being released, so rename the Unreleased heading to that version before tagging."
    }
    if ($mine.Count -gt 1) {
        throw "CHANGELOG.md has $($mine.Count) headings for version $Version. There must be exactly one."
    }

    $versioned = @($headings | Where-Object { $_.Name -ne 'Unreleased' })
    if ($versioned[0].Name -ne $Version) {
        throw "CHANGELOG.md lists version $($versioned[0].Name) above $Version. The version being released must be the newest versioned heading."
    }

    $body = Get-PSMutantChangelogBody -Changelog $Changelog -Name $Version
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "The section for version $Version in CHANGELOG.md is empty. A version with no notes reads as deliberate, and the Gallery page cannot be corrected afterwards."
    }
    return $body
}

function Get-PSMutantConsumerNotes {
    <#
    .SYNOPSIS
        Pure: the "### For consumers" block out of a changelog section, or $null when the
        section does not have one.

    .DESCRIPTION
        CHANGELOG.md is written for a MAINTAINER. That is deliberate and worth keeping: its
        entries carry issue numbers, the argument for a decision, and what a stated reason
        used to claim. None of that survives the trip to a gallery page. A consumer has no
        access to this repo's issue tracker, so `([#48])` renders as literal text pointing
        nowhere, and "un-exporting them did not dissolve that contract, it relocated it" is
        an argument addressed to someone who is not reading.

        0.3.0 shipped exactly that: 9646 characters of maintainer prose, opening mid-document
        at "### Changed", carrying ten unresolvable issue links. A gallery version cannot be
        edited or withdrawn, so it is permanent.

        So each version section carries a "### For consumers" block, written for the person
        deciding whether to upgrade: what changed for them, what breaks, what to do about it.
        The rest of the section stays as it is.

    .PARAMETER Section
        The body of one version's changelog section.

    .OUTPUTS
        [string] the block, without its heading, or $null when there is none.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Notes is a mass noun and names the manifest field these become. A singular "ConsumerNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Section)

    $lines = $Section -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^###\s+For consumers\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        # Any following heading of the same level or higher ends the block. Without this the
        # block would swallow the maintainer sections beneath it, which is the failure this
        # whole separation exists to prevent.
        if ($lines[$i] -match '^#{1,3}\s') { break }
        $body.Add($lines[$i])
    }
    return ($body -join "`n").Trim()
}

function Get-PSMutantBoundedReleaseNotes {
    <#
    .SYNOPSIS
        Pure: release notes cut to fit the gallery's ReleaseNotes limit, with a pointer to
        the rest.

    .DESCRIPTION
        The gallery enforces TWO different limits, and the smaller one is the one that
        applies here. A generic NuGet package may carry 35000 characters of ReleaseNotes; a
        package whose notes are EXTRACTED FROM A POWERSHELL MANIFEST may carry 10600. Only
        the first is mentioned when you exceed it:

            400 (A package's ReleaseNotes property may not be more than 35000 characters long.)
            400 (The package is invalid. The error encountered was:'A package's ReleaseNotes
                 property extracted from the PowerShell manifest may not be more than 10600
                 characters long.')

        Both were hit publishing 0.3.0, in that order -- the second only after truncating to
        26290 to satisfy the first. So the number below is 10600, and the reason it is not
        35000 is written down here because the larger number is what the first failure tells
        you, and believing it costs a second failed release.

        It rejects at the LAST step either way. The 0.3.0 publish reached Publish-Module
        having passed release consistency, staging, and the package smoke test that loads the
        artifact and runs a real mutation.

        Truncating rather than failing is deliberate. Nothing about the run is weakened by
        shorter notes: they are gallery-page prose, not a gate. Failing the release instead
        would pressure whoever writes the changelog to write less, which is the opposite of
        what this project wants -- and the changelog stays the complete record either way.

        The cut lands on a HEADING boundary, never mid-sentence, so what ships reads as a
        finished document rather than a truncated one. If no heading fits, it falls back to
        a blank-line boundary, then to a hard cut -- each fallback is one step worse for the
        reader and none of them can produce something over the limit.

    .PARAMETER Notes
        The full section body.

    .PARAMETER Version
        The version being released, used to point at the tagged changelog.

    .PARAMETER Limit
        Maximum characters. The gallery's own limit, kept as a parameter so a test can drive
        the boundary without a fixture the size of the real limit.

    .OUTPUTS
        [string] the notes to publish. Never longer than -Limit.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'ReleaseNotes is the name of the manifest field this produces. A singular "ReleaseNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Notes,
        [Parameter(Mandatory)] [string]$Version,
        [int]$Limit = 10600
    )
    if ($Notes.Length -le $Limit) { return $Notes }

    $pointer = "`n`n---`n`nThese notes are abridged. The complete entry for $Version is in " +
    "CHANGELOG.md: https://github.com/Fortigi/PSMutant/blob/v$Version/CHANGELOG.md`n"
    $room = $Limit - $pointer.Length
    $head = $Notes.Substring(0, $room)

    # Prefer a heading boundary, then a paragraph break, then give up and cut. Each candidate
    # is searched for in the text that already FITS, so every branch returns something short
    # enough -- there is no arrangement of input that lets an over-long string through.
    $cut = $head.LastIndexOf("`n## ")
    if ($cut -lt 1) { $cut = $head.LastIndexOf("`n### ") }
    if ($cut -lt 1) { $cut = $head.LastIndexOf("`n`n") }
    if ($cut -lt 1) { $cut = $head.Length }

    return $head.Substring(0, $cut).TrimEnd() + $pointer
}

function Test-PSMutantUnreleasedEmpty {
    # True when Unreleased holds nothing, or does not exist. Not a failure -- a maintainer
    # may be staging a later change -- but at release time it usually means entries that
    # belong to this version were left under the wrong heading, which is what happened
    # for 0.2.2.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog)
    $body = Get-PSMutantChangelogBody -Changelog $Changelog -Name 'Unreleased'
    return [string]::IsNullOrWhiteSpace($body)
}

function Get-PSMutantStaleVersionFault {
    <#
    .SYNOPSIS
        The fault, if any, when main claims a version that has already shipped.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ModuleVersion,
        [Parameter(Mandatory)] [bool]$IsPublished,
        [Parameter(Mandatory)] [bool]$HasUnreleasedContent
    )
    # The question left open after ModuleVersion, the newest heading and ReleaseNotes all agree:
    # has the version they agree on already shipped? It once had -- main carried two merged bug
    # fixes at 0.3.1 while 0.3.1 was on the gallery, and every gate passed. The three answer
    # "are these internally consistent", never "does this version already exist somewhere the
    # world can install it".
    #
    # BOTH conditions, because either alone is a normal state. Sitting on a published version
    # with nothing unreleased is exactly where a repo rests between releases; unreleased work
    # under a version not yet shipped is a release being prepared. Only the pair is wrong, and a
    # rule that fired on either would fail on every ordinary day and be muted within a week.
    if (-not $IsPublished) { return $null }
    if (-not $HasUnreleasedContent) { return $null }
    return ("ModuleVersion $ModuleVersion is already on the gallery, and CHANGELOG.md has " +
        "unreleased entries above it. Anyone installing $ModuleVersion gets different code " +
        "depending on whether they took it from the gallery or from this repository. Bump " +
        "ModuleVersion and give the entries their own heading.")
}

function Get-PSMutantRewrittenManifest {
    <#
    .SYNOPSIS
        Pure: the manifest TEXT with only its ReleaseNotes value replaced. Writes nothing.

    .DESCRIPTION
        Not Update-ModuleManifest. That does not update a manifest, it REGENERATES one from
        the data it parsed: the hand-written layout goes, a "Generated on <today>" header
        arrives that churns on every run, and every comment justifying a setting is dropped.
        This manifest's most load-bearing line is a comment -- the one saying Pester is
        deliberately absent from RequiredModules, without which someone re-adds it and
        recreates the collision that shipped a fake 100%.

        A release note is one string, so changing it touches one string.

    .PARAMETER ManifestText
        The manifest source.

    .PARAMETER Notes
        The value to place in ReleaseNotes.

    .OUTPUTS
        [string] the manifest text, with that one value replaced.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ManifestText,
        [Parameter(Mandatory)] [string]$Notes
    )
    # A literal quote inside a single-quoted PowerShell string is escaped by doubling it.
    # Without this an apostrophe closes the string and the manifest stops parsing at all --
    # discovered at publish, on the one step that cannot be undone.
    $literal = "'" + ($Notes -replace "'", "''") + "'"

    # The pattern must understand that escaping too, and for a long time it did not (#171).
    # It was `'.*?'` guarded by a lookahead for a newline or a closing brace, which reads
    # correctly until the value being REPLACED already contains a doubled quote. Then the
    # second quote of an escaped pair, followed by ` }` or a line break, satisfies the
    # lookahead: the match ends INSIDE the old value, the new one is spliced in there, and
    # the remainder is left behind as bare tokens. The manifest stops parsing, and the error
    # names a stray word rather than the cause. Any quoted phrase at the end of a line is
    # enough -- it took two -Apply runs and no other change to produce it.
    #
    # This is the unrolled-loop spelling of a single-quoted PowerShell string: an opening
    # quote, then runs of non-quotes separated by DOUBLED quotes, then the close. It consumes
    # an escaped quote as content, so the match can only end at the real terminator, and it
    # backtracks linearly rather than exponentially on a long value. Being exact, it needs no
    # lookahead -- the old one was doing the work the body should have done.
    $pattern = "(ReleaseNotes\s*=\s*)'[^']*(?:''[^']*)*'"
    if ($ManifestText -notmatch $pattern) {
        throw 'Manifest has no single-quoted ReleaseNotes value to replace.'
    }
    return [regex]::Replace($ManifestText, $pattern, { param($m) $m.Groups[1].Value + $literal }, 1)
}

function Get-PSMutantManifestNotesFault {
    # The manifest's ReleaseNotes against what the CHANGELOG produces, as a sentence.
    #
    # Publishing overwrites a STAGED copy, so this field never reaches the gallery -- which is
    # exactly why it drifts: it is a second copy of the same prose that nothing reads and
    # nothing checks. Someone reading the manifest, or publishing by hand, gets the stale one.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Actual,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Expected
    )
    # Compared with line endings normalised, because they are not ours to control. The
    # changelog extractor joins with `n, and git rewrites newlines INSIDE the stored string
    # on checkout: the same commit reads LF on a Linux runner and CRLF on a Windows one. An
    # exact comparison therefore passes in CI and fails on a maintainer's machine, which is
    # a gate that reports on the checkout rather than on the content.
    $left = $Actual -replace "`r`n", "`n"
    $right = $Expected -replace "`r`n", "`n"
    if ($left -eq $right) { return $null }
    return ("PSMutant.psd1 ReleaseNotes do not match the '### For consumers' block in " +
        "CHANGELOG.md. The changelog is the source; run ./tools/Test-PSMutantRelease.ps1 -Apply " +
        "to regenerate the manifest field from it.")
}
