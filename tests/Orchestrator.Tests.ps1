# Unit tests for Invoke-PSMutation.ps1 -- the entry point's guards, its wiring, and the
# recheck branch -- driven directly rather than through a real run.
#
# WHY THIS FILE EXISTS, given EndToEnd.Tests.ps1 already runs the whole thing: the
# self-mutation sandbox copies only src/ and tests/, so a covering suite that reaches
# for PSMutant.psd1 at the repo root -- as the end-to-end suite does -- finds nothing
# there and silently proves nothing. Anything that has to KILL a mutant in this file
# must therefore be reachable from a self-contained, dot-sourced test, which is this.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Config.ps1',
        'PSMutation.Runner.ps1', 'PSMutation.Report.ps1', 'PSMutation.Recheck.ps1',
        'Invoke-PSMutation.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Assert-PSMutationPester' {
    BeforeEach {
        # Pester 6 dropped mock fall-through, so BOTH shapes of the Get-Module call this
        # function makes -- loaded modules, and -ListAvailable -- need their own mock, or
        # the unmatched one throws instead of answering.
        $script:loaded = @()
        $script:available = @()
        Mock Get-Module { $script:loaded } -ParameterFilter { -not $ListAvailable }
        Mock Get-Module { $script:available } -ParameterFilter { $ListAvailable }
        Mock Import-Module { }
    }

    It 'accepts the Pester already loaded rather than importing a second one' {
        # THE regression. Import-Module -MinimumVersion is not the no-op it looks like
        # when a satisfying Pester is already loaded: it re-resolves the name to the
        # NEWEST version installed, and on a machine holding two that collides with the
        # Pester.dll already in the process. Every end-to-end test failed this way,
        # before a single mutant ran.
        $script:loaded = @([pscustomobject]@{ Version = [version]'5.8.0' })
        $script:available = @([pscustomobject]@{ Version = [version]'6.1.0' })

        { Assert-PSMutationPester } | Should -Not -Throw
        Should -Invoke Import-Module -Exactly 0
    }

    It 'imports Pester when the session has none loaded yet' {
        $script:available = @([pscustomobject]@{ Version = [version]'5.8.0' })
        { Assert-PSMutationPester } | Should -Not -Throw
        Should -Invoke Import-Module -Exactly 1
    }

    It 'refuses when nothing installed is new enough' {
        # Pester 4 has no code-coverage API and a different Should surface, so without
        # this the run dies much later, inside the baseline, with an unrelated error.
        $script:available = @([pscustomobject]@{ Version = [version]'4.10.1' })
        { Assert-PSMutationPester } | Should -Throw '*Pester 5+ is required*'
    }

    It 'refuses when the LOADED Pester is too old, even though a newer one is installed' {
        # The tempting repair -- import the newer one -- is itself the bug: the old
        # assembly is already in the process, so the import fails rather than upgrades.
        # Refusing names the real problem while the session can still be restarted.
        $script:loaded = @([pscustomobject]@{ Version = [version]'4.10.1' })
        $script:available = @([pscustomobject]@{ Version = [version]'6.1.0' })
        { Assert-PSMutationPester } | Should -Throw '*Pester 5+ is required*'
        Should -Invoke Import-Module -Exactly 0
    }

    It 'judges by the newest module loaded when the session holds more than one' {
        # Pester 3 ships with Windows and can sit in a session next to a modern one.
        # Judging by the wrong element refuses a session perfectly able to run.
        $script:loaded = @(
            [pscustomobject]@{ Version = [version]'3.4.0' }
            [pscustomobject]@{ Version = [version]'5.8.0' }
        )
        { Assert-PSMutationPester } | Should -Not -Throw
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
        $r.Total    | Should -Be 2
        $r.Killed   | Should -Be 1
        $r.Survived | Should -Be 1
        $r.Score    | Should -Be 50
        $r.ExitCode | Should -Be 0
    }

    It 'writes the report where the config asked for it' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Test-Path (Join-Path $script:root 'reports/run.json') | Should -BeTrue
    }

    It 'removes the sandbox even when the run blows up half way through' {
        # A sandbox is a full subtree copy in temp. Leaking one per failed run is how a
        # developer temp directory fills up, and the startup sweep only reclaims
        # sandboxes whose owning process has already exited.
        Mock Invoke-PSMutationLoop { throw 'mutation exploded' }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should -Throw
        Should -Invoke Remove-PSMutationSandbox -Exactly 1
    }

    It 'checks Pester and sweeps stale sandboxes before it starts' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Should -Invoke Assert-PSMutationPester -Exactly 1
        Should -Invoke Clear-PSMutationStaleSandbox -Exactly 1
    }

    It 'hands -RecheckFrom to the recheck path and never writes the full report' {
        # A partial run overwriting the baseline would destroy the survivor list it was
        # derived from and hand CI a truncated number.
        Mock Invoke-PSMutationRecheckRun { [pscustomobject]@{ Mode = 'Recheck'; Rechecked = 2 } }

        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -RecheckFrom 'prior.json' -Quiet

        $r.Mode | Should -Be 'Recheck'
        Should -Invoke Invoke-PSMutationRecheckRun -Exactly 1
        Should -Invoke Invoke-PSMutationLoop -Exactly 0
        Test-Path (Join-Path $script:root 'reports/run.json') | Should -BeFalse
    }

    It 'prints the banner, the baseline, the mutant count and the summary unless quiet' {
        # Four separate -not Quiet guards. Drop any one and a human sees a run that
        # looks like it did nothing. Every other test here passes -Quiet, so without
        # this the whole console layer ships unexercised.
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root } 6>&1 | Out-String
        $out | Should -BeLike '*PSMutant*'
        $out | Should -BeLike '*Baseline green*'
        $out | Should -BeLike '*Mutants to evaluate: 2*'
        $out | Should -BeLike '*Mutation score*'
    }

    It 'prints nothing at all with -Quiet' {
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } 6>&1 | Out-String
        $out | Should -Not -BeLike '*PSMutant*'
        $out | Should -Not -BeLike '*Mutation score*'
    }

    It 'defaults SourceRoot to the current directory' {
        Push-Location $script:root
        try {
            (Invoke-PSMutation -ConfigFile $script:configFile -Quiet).Total | Should -Be 2
        }
        finally { Pop-Location }
    }

    It 'refuses to mutate against a red baseline' {
        # Every mutant would "die" for the reason the suite was already failing, and the
        # run would report a perfect score that means nothing.
        Mock Invoke-PSMutationBaseline { @{ Passed = $false; DurationSeconds = 1.0; CoveredLines = @{} } }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } |
            Should -Throw '*Baseline suite is not green*'
    }

    It 'passes the resolved operator list and timeout down to the mutation loop' {
        # The orchestrator is wiring, so what can break here is a crossed wire: the
        # right values computed and then handed to the wrong parameter.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        # A 2.0s baseline times the default factor of 4 is under the 15s floor.
        Should -Invoke Invoke-PSMutationLoop -Exactly 1 -ParameterFilter { $TimeoutSeconds -eq 15 }
        Should -Invoke Select-PSMutationCandidate -Exactly 1 -ParameterFilter {
            @($Operators).Count -eq 1 -and $Operators -contains 'BinaryOperator'
        }
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
