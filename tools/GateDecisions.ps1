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
    # the build, it just quietly stops protecting you. The sibling repo's pin on THIS module sat
    # at 0.1.0 across two majors -- one of which fixed a bug that scored every mutant killed --
    # and its CI was green throughout.
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
