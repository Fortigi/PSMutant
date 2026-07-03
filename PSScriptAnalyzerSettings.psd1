@{
    # PSScriptAnalyzer settings for code scanning.
    # Write-Host is the intended progress-output mechanism for this CLI tool (colour-
    # coded status lines), so its rule is excluded rather than worked around. Every
    # other rule is enforced; source is kept ASCII so no BOM is needed.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
