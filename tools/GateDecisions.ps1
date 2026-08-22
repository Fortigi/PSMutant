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
