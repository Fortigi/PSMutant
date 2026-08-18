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
    return @($ShippedName | Where-Object { $RootModuleText -notmatch [regex]::Escape($_) })
}
