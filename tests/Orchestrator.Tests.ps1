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
    # This file starts REAL mutation runs, and a run under a CI annotates. Its fixtures are
    # throwaway files in a temp directory, so those annotations point at paths that do not
    # exist in this repository -- GitHub resolves them against the checkout and decorates the
    # pull request with warnings a reviewer cannot open, sitting beside the real ones the gate
    # produces. Seventeen of them, before this.
    #
    # Cleared for the file and RESTORED afterwards, never left as $null: $env: is process
    # state, this suite runs inside CI where the variable is genuinely set, and a file that
    # resets it silently decides what every later file sees.
    #
    # The annotation path itself is tested by MOCKING Test-PSMutationAnnotationHost, which is
    # hermetic and does not care which file ran first.
    $script:priorActions = $env:GITHUB_ACTIONS
    $env:GITHUB_ACTIONS = $null

    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Pester.ps1',
        'PSMutation.Config.ps1', 'PSMutation.Output.ps1', 'PSMutation.Runner.ps1', 'PSMutation.Report.ps1',
        'PSMutation.Recheck.ps1', 'Invoke-PSMutation.ps1') {
        . (Join-Path $src $f)
    }
}


AfterAll { $env:GITHUB_ACTIONS = $script:priorActions }

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
        # Creates the files it claims to have copied. A mocked sandbox that returns a path
        # and leaves it empty is lying about what a sandbox is, and the orchestrator now
        # checks -- before the baseline -- that the config's paths actually arrived. Mocking
        # that check away instead would leave its application untested, which is the gap
        # where a predicate is covered and its caller can be deleted with the suite green.
        Mock New-PSMutationSandbox {
            $sb = Join-Path $script:root 'sandbox'
            foreach ($rel in 'src/a.ps1', 'tests/a.Tests.ps1') {
                $dest = Join-Path $sb $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Set-Content -LiteralPath $dest -Value '# copied by the sandbox'
            }
            $sb
        }
        Mock Remove-PSMutationSandbox { }
        Mock Invoke-PSMutationBaseline { @{ Passed = $true; DurationSeconds = 2.0; CoveredLines = @{} } }
        Mock Get-PSMutationSourceHashMap { @{ 'src/a.ps1' = 'hash' } }
        # Returns candidates AND the per-file tally the coverage filter produced. A bare
        # array here binds $null to -PerFile downstream, which is the shape the real function
        # no longer has.
        Mock Select-PSMutationCandidate {
            [pscustomobject]@{
                Candidates = @('cand-1', 'cand-2')
                PerFile    = @([pscustomobject]@{ File = 'src/a.ps1'; Produced = 2; Kept = 2 })
            }
        }
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

    It 'writes a PARTIAL report when the run is interrupted, rather than nothing' {
        # A run is long enough that losing one to Ctrl-C or a cancelled CI job is an ordinary
        # event, and everything used to be discarded: the rows lived in a list inside the loop
        # and the report was written only after the last mutant. A cancelled job produced no
        # picture at all.
        Mock Invoke-PSMutationLoop {
            # Rows reach the caller through the SINK, not the return value -- which is the whole
            # mechanism. A loop that throws returns nothing, so anything it had already
            # evaluated is only recoverable because the accumulator belongs to the caller.
            $Sink.Add([pscustomobject]@{ Id = 'm1'; Status = 'Killed'; File = 'a.ps1' })
            $Sink.Add([pscustomobject]@{ Id = 'm2'; Status = 'Survived'; File = 'a.ps1' })
            throw 'interrupted'
        }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw

        $path = Join-Path $script:root 'reports/run.json'
        Test-Path $path | Should-BeTrue -Because 'an interrupted run must still say what it got through'
        $doc = Get-Content $path -Raw | ConvertFrom-Json
        $doc.mode | Should-Be 'Partial'
        $doc.evaluated | Should-Be 2
        $doc.mutants.Count | Should-Be 2
    }

    It 'never puts a SCORE on an interrupted run' {
        # The point of the separate mode. `evaluated` of `planned` is progress: the loop
        # evaluates in candidate order, so an interrupted run has seen whichever files sort
        # earliest, and a percentage over those is not a measurement of anything. Asserted
        # here as well as in the schema because the schema only refuses a document somebody
        # thought to validate.
        Mock Invoke-PSMutationLoop {
            $Sink.Add([pscustomobject]@{ Id = 'm1'; Status = 'Killed'; File = 'a.ps1' })
            throw 'interrupted'
        }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw

        $doc = Get-Content (Join-Path $script:root 'reports/run.json') -Raw | ConvertFrom-Json
        $doc.PSObject.Properties.Name | Should-NotContainCollection 'mutationScore'
        $doc.PSObject.Properties.Name | Should-NotContainCollection 'thresholds'
    }

    It 'writes the ORDINARY report when a run legitimately evaluates nothing' {
        # The case a naive "did we get any rows" check would misread. A config whose files
        # contribute no covered candidates completes normally and must produce a full report
        # with a score, not a partial one -- so the flag is "did the loop return", never "is
        # the sink empty".
        # The comma is load-bearing and the real function has it for the same reason: a
        # PowerShell function returning an empty collection unrolls it to NOTHING, so a mock
        # written `@()` hands back $null and tests a shape the loop cannot produce. That is
        # #158 in miniature.
        Mock Invoke-PSMutationLoop { , @() }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null

        $doc = Get-Content (Join-Path $script:root 'reports/run.json') -Raw | ConvertFrom-Json
        Should-BeNull -Actual $doc.mode -Because 'a completed run is a full report however few mutants it had'
        $doc.PSObject.Properties.Name | Should-ContainCollection 'mutationScore'
    }

    It 'does not even REACH the partial writer when the run completes' {
        # Asserted on the call, not on the file, and the difference is why this test exists.
        # The full report is written straight after the loop and OVERWRITES whatever the
        # interrupted path left, so a partial written by mistake on the success path is
        # invisible on disk -- measured: forcing the completion flag false leaves every
        # file-based assertion above passing.
        Mock Write-PSMutationPartialReport { 'unused' }
        Mock Invoke-PSMutationLoop { , @() }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Should-Invoke Write-PSMutationPartialReport -Exactly 0
    }

    It 'says it was interrupted even under -Quiet' {
        # -Quiet exists so a CI log is not filled with progress lines. This is not progress:
        # it is the only notice that a file was written somewhere, in the one situation where
        # nobody is watching a return value because the run is being torn down. Silenced, the
        # partial report is a file nobody is told about.
        Mock Invoke-PSMutationLoop { $Sink.Add([pscustomobject]@{ Id = 'm1'; Status = 'Killed' }); throw 'interrupted' }
        Mock Write-PSMutationOutput { }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw
        # Both halves in one filter, because either alone passes for the wrong reason: the text
        # alone is satisfied by a call that -Quiet then swallows, and the flag alone is satisfied
        # by any of the several other unsilenced writes this run makes.
        Should-Invoke Write-PSMutationOutput -Times 1 -ParameterFilter {
            $Quiet -eq $false -and (($Lines | ForEach-Object { $_.Text }) -join ' ') -like '*PARTIAL report*'
        }
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

    It 'annotates a survivor onto the diff under a CI, even with -Quiet' {
        # The whole point of the feature, and the reason it does not forward -Quiet. CI runs
        # quiet so the log is not several hundred progress lines; suppressing the findings too
        # leaves a failed gate printing a score and nothing else, which is a backstop that
        # cannot say what failed.
        #
        # The file and line come from the mutant row, so this also proves the annotation is
        # built from Data rather than from the console text.
        Mock Test-PSMutationAnnotationHost { $true }
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } 6>&1 | Out-String
        $out | Should-BeLikeString '*::warning file=src/a.ps1,line=2::*'
        # And only the survivor. The killed mutant has a file and a line too, so a renderer
        # that annotated every row would pass the assertion above and bury the one finding.
        $out | Should-NotBeLikeString '*line=1*'
    }

    It 'annotates nothing when it is not running under a CI' {
        # The paired half. Without it the test above passes against a run that annotates
        # unconditionally, putting workflow-command noise in front of every developer.
        Mock Test-PSMutationAnnotationHost { $false }
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root } 6>&1 | Out-String
        $out | Should-NotBeLikeString '*::warning*'
    }

    It 'prints nothing at all with -Quiet' {
        # CI-neutral: this asserts silence, and under a real CI the annotation path speaks by
        # design. Mocked rather than cleared from $env:, which is shared with every other file.
        Mock Test-PSMutationAnnotationHost { $false }
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

    It 'refuses a config path that never reached the sandbox, BEFORE running the baseline' {
        # An empty sandbox: the subtrees copied nothing the config points at, which is what a
        # consumer-shaped layout does when sandboxSubtrees still names this module's own.
        # Pester then cannot resolve the coverage paths, the baseline comes back not-green,
        # and the run used to say "Baseline suite is not green - fix the tests before
        # mutating." The suite is green. That message sends the reader to debug the wrong
        # files, and it is the config that is wrong.
        Mock New-PSMutationSandbox { Join-Path $script:root 'emptysandbox' }
        # A baseline that WOULD pass, so a failure here cannot be blamed on the suite: this
        # asserts the check runs first, not merely that something threw.
        Mock Invoke-PSMutationBaseline { @{ Passed = $true; DurationSeconds = 2.0; CoveredLines = @{} } }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } |
            Should-Throw -ExceptionMessage '*sandboxSubtrees*'
        # And it never got as far as the baseline.
        Should-NotInvoke Invoke-PSMutationBaseline
    }

    It 'says which mutate files will run the whole suite, before the loop starts' {
        # Through the real entry point, and BEFORE the loop, because the cost it names is paid
        # on every mutant that follows -- afterwards it is an explanation, not a warning.
        Mock Get-PSMutationSandboxPlan {
            $sb = Join-Path $script:root 'sandbox'
            @{
                Mutate      = @((Join-Path $sb 'src/a.ps1'))
                TestsByFile = @{}      # no entry for a.ps1 -- the fallback fires
                AllTests    = @((Join-Path $sb 'tests/a.Tests.ps1'))
            }
        }
        $out = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root 6>&1
        ($out -join "`n") | Should-MatchString 'no tests entry'
    }

    It 'says nothing about the fallback when every mutate file is mapped' {
        # The kept half. Without it, a line printed unconditionally would pass the test above
        # and put a warning on every correct config.
        $out = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root 6>&1
        ($out -join "`n") | Should-NotMatchString 'no tests entry'
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
