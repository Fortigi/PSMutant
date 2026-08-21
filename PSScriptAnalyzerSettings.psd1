@{
    # PSScriptAnalyzer settings for code scanning.
    #
    # PSAvoidUsingWriteHost is excluded because the gate SCRIPTS in tools/ print for a
    # living -- they are CLIs whose whole output is progress and verdicts.
    #
    # It is NOT what keeps src/ honest. The module has exactly one Write-Host, in
    # Write-PSMutationOutput, and tests/Layering.Tests.ps1 asserts that: an added one
    # anywhere else in src/ fails with a message naming the renderer it should have gone
    # through, which is more use than a generic rule warning. Write-PSMutationOutput also
    # carries a targeted suppression, so if tools/ ever stops printing this exclusion can
    # be deleted outright.
    #
    # Every other rule is enforced; source is kept ASCII so no BOM is needed.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
