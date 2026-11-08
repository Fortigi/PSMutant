# PSMutant - mutation testing for PowerShell.
# Dot-source the implementation files (small, single-responsibility) and export the
# public surface. The LIST is load-bearing -- a file missing from it is never loaded -- but
# the ORDER within it is not: every cross-file reference happens inside a function body, so
# it resolves at call time once every file is dot-sourced. Loading them in exact reverse order
# behaves identically.
#
# Keep the order anyway. It is a topological order of the real dependency graph, so reading the
# list top to bottom is the cheapest description of the architecture anyone gets. The order is
# a readable convention; tests/Layering.Tests.ps1 is what enforces the direction it expresses.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @(
        # Foundations: what a mutant is, where it runs, and what a run was asked to do.
        'PSMutation.Operators.ps1'
        'PSMutation.Sandbox.ps1'
        'PSMutation.Pester.ps1'
        'PSMutation.Config.ps1'
        'PSMutation.Glob.ps1'
        'PSMutation.Inline.ps1'
        # What a run says: the one place that emits, and the published formats.
        'PSMutation.Output.ps1'
        'PSMutation.Report.ps1'
        'PSMutation.Sarif.ps1'
        'PSMutation.MutationTestingReport.ps1'
        # The run: the modes over a previous report, the runner, and the entry point.
        'PSMutation.Recheck.ps1'
        'PSMutation.Incremental.ps1'
        'PSMutation.Killers.ps1'
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
