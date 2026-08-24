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

function Get-PSMutantCompatPinFault {
    <#
    .SYNOPSIS
        The fault, if any, in the deliberately-old compatibility pin.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$EstateVersion,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$CompatVersion
    )
    # "Is there a newer version" is the WRONG QUESTION for this pin, and asking it was a real
    # mistake caught by running the watcher: it reported 5.8.0 as stale against 6.1.0. The
    # compatibility guard exists to run a real mutation under the Pester the suite does NOT
    # use, proving the manifest's >= 5.0.0 promise. Bumped to the newest, it would equal the
    # estate pin and prove nothing -- while looking more up to date.
    #
    # So the invariant is difference, not freshness.
    if ([string]::IsNullOrWhiteSpace($EstateVersion) -or [string]::IsNullOrWhiteSpace($CompatVersion)) {
        return 'PESTER_VERSION and PESTER_COMPAT_VERSION must both be set: the compatibility guard runs under the one the suite does not.'
    }
    if ([version]$CompatVersion -eq [version]$EstateVersion) {
        return ("PESTER_COMPAT_VERSION ($CompatVersion) equals PESTER_VERSION. The compatibility " +
            'guard would then run under the same Pester as the suite and prove nothing about the ' +
            "manifest's >= 5.0.0 promise -- while looking more up to date than a pin that works.")
    }
    if ([version]$CompatVersion -gt [version]$EstateVersion) {
        return ("PESTER_COMPAT_VERSION ($CompatVersion) is newer than PESTER_VERSION ($EstateVersion). " +
            'The guard is meant to prove the module works under an OLDER Pester than the estate uses.')
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
