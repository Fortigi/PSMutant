# PSMutant - mutation testing for PowerShell.
# Dot-source the implementation files (small, single-responsibility) and export the
# public surface. The LIST is load-bearing -- a file missing from it is never loaded -- but
# the ORDER within it is not: every cross-file reference happens inside a function body, so
# it resolves at call time once all eight are dot-sourced. Verified by loading them in exact
# reverse order, which behaves identically. This comment previously claimed order mattered.
#
# Keep the order anyway. It is a topological order of the real dependency graph -- pure
# layers, then the runner, then the entry point -- so reading the list top to bottom is the
# cheapest description of the architecture anyone gets. It is a readable convention, not a
# constraint, and nothing enforces the direction it expresses; see issue #52.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @(
        'PSMutation.Operators.ps1'
        'PSMutation.Sandbox.ps1'
        'PSMutation.Pester.ps1'
        'PSMutation.Config.ps1'
        'PSMutation.Report.ps1'
        'PSMutation.Recheck.ps1'
        'PSMutation.Runner.ps1'
        'Invoke-PSMutation.ps1'
    )) {
    . (Join-Path $src $file)
}

# Must agree with FunctionsToExport in the manifest, which filters this list anyway -- a
# name here and not there is exported by neither, which reads as a bug in whichever file you
# happen to be looking at. A test asserts the two agree.
Export-ModuleMember -Function @(
    'Invoke-PSMutation'
)
