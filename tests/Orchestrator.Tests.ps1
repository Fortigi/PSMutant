# Unit tests for Invoke-PSMutation.ps1, which is now one function: the entry point's
# wiring, driven directly rather than through a real run.
#
# The Pester guard and the recheck orchestrator used to be tested here because they used
# to LIVE here. They moved to the files that own their subject (#45), and their tests
# went with them -- Pester.Tests.ps1 and Recheck.Tests.ps1.
#
# WHY THIS FILE EXISTS, given EndToEnd.Tests.ps1 already runs the whole thing: the
# self-mutation sandbox copies only src/ and tests/, so a covering suite that reaches
# for PSMutant.psd1 at the repo root -- as the end-to-end suite does -- finds nothing
# there and silently proves nothing. Anything that has to KILL a mutant in this file
# must therefore be reachable from a self-contained, dot-sourced test, which is this.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Pester.ps1',
        'PSMutation.Config.ps1', 'PSMutation.Output.ps1', 'PSMutation.Runner.ps1', 'PSMutation.Report.ps1',
        'PSMutation.Recheck.ps1', 'Invoke-PSMutation.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Invoke-PSMutation' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:configFile = Join-Path $script:root 'psmutant.json'
        [ordered]@{
            mutate     = @('src/a.ps1')
            tests      = @{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
            operators  = @('BinaryOperator')
            thresholds = @{ high = 85; low = 70; break = $null }
            reportPath = 'reports/run.json'
        } | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8

        # Everything touching a real Pester run, the clock or the sandbox is mocked.
        # What is left executing is the orchestration this file is responsible for.
        Mock Assert-PSMutationPester { }
        Mock Clear-PSMutationStaleSandbox { }
        Mock New-PSMutationSandbox { Join-Path $script:root 'sandbox' }
        Mock Remove-PSMutationSandbox { }
        Mock Invoke-PSMutationBaseline { @{ Passed = $true; DurationSeconds = 2.0; CoveredLines = @{} } }
        Mock Get-PSMutationSourceHashMap { @{ 'src/a.ps1' = 'hash' } }
        Mock Select-PSMutationCandidate { , @('cand-1', 'cand-2') }
        Mock Invoke-PSMutationLoop {
            , @(
                [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'; Description = 'eq to ne'; Status = 'Killed' }
                [pscustomobject]@{ Id = 2; File = 'src/a.ps1'; Line = 2; Operator = 'BinaryOperator'; Description = 'gt to le'; Status = 'Survived' }
            )
        }
    }

    It 'scores the run and returns the public result shape' {
        # One killed of two on purpose: a summary that dropped a bucket, or swapped
        # killed for survived, would still pass at either extreme.
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet
        $r.Total    | Should-Be 2
        $r.Killed   | Should-Be 1
        $r.Survived | Should-Be 1
        $r.Score    | Should-Be 50
        $r.ExitCode | Should-Be 0
    }

    It 'writes the report where the config asked for it' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Test-Path (Join-Path $script:root 'reports/run.json') | Should-BeTrue
    }

    It 'removes the sandbox even when the run blows up half way through' {
        # A sandbox is a full subtree copy in temp. Leaking one per failed run is how a
        # developer temp directory fills up, and the startup sweep only reclaims
        # sandboxes whose owning process has already exited.
        Mock Invoke-PSMutationLoop { throw 'mutation exploded' }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw
        Should-Invoke Remove-PSMutationSandbox -Exactly 1
    }

    It 'checks Pester and sweeps stale sandboxes before it starts' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Should-Invoke Assert-PSMutationPester -Exactly 1
        Should-Invoke Clear-PSMutationStaleSandbox -Exactly 1
    }

    It 'hands -RecheckFrom to the recheck path and never writes the full report' {
        # A partial run overwriting the baseline would destroy the survivor list it was
        # derived from and hand CI a truncated number.
        Mock Invoke-PSMutationRecheckRun { [pscustomobject]@{ Mode = 'Recheck'; Rechecked = 2 } }

        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -RecheckFrom 'prior.json' -Quiet

        $r.Mode | Should-Be 'Recheck'
        Should-Invoke Invoke-PSMutationRecheckRun -Exactly 1
        Should-Invoke Invoke-PSMutationLoop -Exactly 0
        Test-Path (Join-Path $script:root 'reports/run.json') | Should-BeFalse
    }

    It 'prints the banner, the baseline, the mutant count and the summary unless quiet' {
        # Four separate -not Quiet guards. Drop any one and a human sees a run that
        # looks like it did nothing. Every other test here passes -Quiet, so without
        # this the whole console layer ships unexercised.
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root } 6>&1 | Out-String
        $out | Should-BeLikeString '*PSMutant*'
        $out | Should-BeLikeString '*Baseline green*'
        $out | Should-BeLikeString '*Mutants to evaluate: 2*'
        $out | Should-BeLikeString '*Mutation score*'
    }

    It 'prints nothing at all with -Quiet' {
        # Every one of the four guards is named, not just the banner and the summary:
        # a guard that stopped honouring -Quiet would otherwise ship unnoticed.
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } 6>&1 | Out-String
        $out | Should-NotBeLikeString '*PSMutant*'
        $out | Should-NotBeLikeString '*Baseline green*'
        $out | Should-NotBeLikeString '*Mutants to evaluate*'
        $out | Should-NotBeLikeString '*Mutation score*'
    }

    It 'defaults SourceRoot to the current directory' {
        Push-Location $script:root
        try {
            (Invoke-PSMutation -ConfigFile $script:configFile -Quiet).Total | Should-Be 2
        }
        finally { Pop-Location }
    }

    It 'refuses to mutate against a red baseline' {
        # Every mutant would "die" for the reason the suite was already failing, and the
        # run would report a perfect score that means nothing.
        Mock Invoke-PSMutationBaseline { @{ Passed = $false; DurationSeconds = 1.0; CoveredLines = @{} } }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } |
            Should-Throw -ExceptionMessage '*Baseline suite is not green*'
    }

    It 'passes the resolved operator list and timeout down to the mutation loop' {
        # The orchestrator is wiring, so what can break here is a crossed wire: the
        # right values computed and then handed to the wrong parameter.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        # A 2.0s baseline times the default factor of 4 is under the 15s floor.
        Should-Invoke Invoke-PSMutationLoop -Exactly 1 -ParameterFilter { $TimeoutSeconds -eq 15 }
        Should-Invoke Select-PSMutationCandidate -Exactly 1 -ParameterFilter {
            @($Operators).Count -eq 1 -and $Operators -contains 'BinaryOperator'
        }
    }
}
