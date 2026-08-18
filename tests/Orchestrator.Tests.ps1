# Unit tests for the parts of Invoke-PSMutation.ps1 that can be driven directly.
#
# WHY THIS FILE EXISTS, given EndToEnd.Tests.ps1 already runs the whole thing: a full
# run starts a NESTED Pester (the baseline suite), and that clobbers the outer run's
# coverage breakpoints. The result is that lines which demonstrably execute -- the
# startup banner among them -- come back reported as never run. So the end-to-end
# suite proves the behaviour but cannot measure it, and anything reachable without
# starting a nested run is pinned here instead, where the measurement is honest.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Runner.ps1',
                   'PSMutation.Report.ps1', 'PSMutation.Recheck.ps1', 'Invoke-PSMutation.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Assert-PSMutationPester' {
    It 'refuses to start when no Pester 5 or newer is installed' {
        # Without this the run fails much later, inside the baseline, with a Pester
        # syntax error rather than a message naming the actual problem.
        Mock Get-Module { @() }
        { Assert-PSMutationPester } | Should -Throw '*Pester 5+ is required*'
    }

    It 'accepts and imports a modern Pester' {
        Mock Get-Module { [pscustomobject]@{ Version = [version]'5.8.0' } }
        Mock Import-Module { }
        { Assert-PSMutationPester } | Should -Not -Throw
        Should -Invoke Import-Module -Exactly 1
    }

    It 'rejects a Pester older than 5 even though it is installed' {
        # The check is a VERSION comparison, not a presence check -- Pester 4 is
        # installed on plenty of machines and its config API does not exist.
        Mock Get-Module { [pscustomobject]@{ Version = [version]'4.10.1' } }
        { Assert-PSMutationPester } | Should -Throw '*Pester 5+ is required*'
    }
}

Describe 'Invoke-PSMutationRecheckRun' {
    BeforeEach {
        $script:reportFile = Join-Path $TestDrive 'prior.json'
        '{ "survivors": [ { "Id": 1, "File": "src/a.ps1" }, { "Id": 2, "File": "src/a.ps1" } ] }' |
            Set-Content $script:reportFile -Encoding utf8
        $script:plan = @{ TestsByFile = @{}; AllTests = @('tests/a.Tests.ps1') }
    }

    It 'refuses, naming the reason, when the report no longer matches the source' {
        # Mutant ids are AST-walk positions: if the source moved, id 7 in the report
        # is a different mutant now, and a recheck would answer confidently about the
        # wrong one. Refusing is the whole point of the guard.
        Mock Test-PSMutationRecheckCompatible { @('source changed for src/a.ps1') }

        { Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @() -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet } |
            Should -Throw '*Cannot recheck*source changed for src/a.ps1*regenerate*'
    }

    It 'evaluates only the prior survivors and returns the recheck summary' {
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1', 'cand-2') }
        Mock Invoke-PSMutationLoop { @([pscustomobject]@{ Status = 'Killed' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 1; StillSurviving = 1 } }
        Mock Show-PSMutationRecheckSummary { }

        $s = Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a', 'b', 'c') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet

        $s.NowKilled | Should -Be 1
        # The narrowed set is what makes a recheck cheap; passing all candidates
        # through would just be a full run wearing a recheck's label.
        Should -Invoke Invoke-PSMutationLoop -Exactly 1 -ParameterFilter { @($Candidates).Count -eq 2 }
        # The prior survivor COUNT comes from the report, not from the loop results.
        Should -Invoke Write-PSMutationRecheckReport -Exactly 1 -ParameterFilter { $PriorSurvivorCount -eq 2 }
        Should -Invoke Show-PSMutationRecheckSummary -Exactly 0
    }

    It 'reports progress and a summary when not quiet' {
        $script:said = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:said.Add([string]$Object) }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1', 'cand-2') }
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Status = 'Survived' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 0 } }
        Mock Show-PSMutationRecheckSummary { }

        Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') | Out-Null

        ($script:said -join "`n") | Should -Match 'Rechecking 2 previous survivor'
        Should -Invoke Show-PSMutationRecheckSummary -Exactly 1
    }
}
