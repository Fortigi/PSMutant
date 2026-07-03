# PSMutant — mutation testing for PowerShell.
# Dot-source the implementation files (small, single-responsibility) and export the
# public surface. Load order matters: operators/sandbox/report before the runner and
# the public Invoke-PSMutation that tie them together.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @(
        'PSMutation.Operators.ps1'
        'PSMutation.Sandbox.ps1'
        'PSMutation.Report.ps1'
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
