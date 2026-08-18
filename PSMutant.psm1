# PSMutant - mutation testing for PowerShell.
# Dot-source the implementation files (small, single-responsibility) and export the
# public surface. The LIST is load-bearing -- a file missing from it is never loaded -- but
# the ORDER within it is not: every cross-file reference happens inside a function body, so
# it resolves at call time once all seven are dot-sourced. Verified by loading them in exact
# reverse order, which behaves identically. This comment previously claimed order mattered.
# Nothing enforces the layering the order was meant to express; see issue #52.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @(
        'PSMutation.Operators.ps1'
        'PSMutation.Sandbox.ps1'
        'PSMutation.Config.ps1'
        'PSMutation.Report.ps1'
        'PSMutation.Recheck.ps1'
        'PSMutation.Runner.ps1'
        'Invoke-PSMutation.ps1'
    )) {
    . (Join-Path $src $file)
}

Export-ModuleMember -Function @(
    'Invoke-PSMutation'
    'Get-PSMutationCandidate'
    'Set-PSMutationText'
)
