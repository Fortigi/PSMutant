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

        function script:UseBaselineConfig {
            # The fixture config plus the one key that turns the gate on. Written here rather than
            # in BeforeEach so the default tests keep proving the gate stays off without it.
            [ordered]@{
                mutate           = @('src/a.ps1')
                tests            = @{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
                operators        = @('BinaryOperator')
                thresholds       = @{ high = 85; low = 70; break = $null }
                reportPath       = 'reports/run.json'
                survivorBaseline = 'baseline.json'
            } | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8
        }

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
                # ByOperator too: the real function attaches it on every row, and a preview
                # rendering a $null map would pass here and print nothing there.
                PerFile    = @([pscustomobject]@{ File = 'src/a.ps1'; Produced = 2; Kept = 2
                        ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 2; Kept = 2 } }
                    })
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

    It 'ignores the survivor baseline entirely when the config names none' {
        # The default. Presence of the key is the switch, so an ordinary config must not acquire
        # a new way to fail -- nor a new file on disk.
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                    Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() }) }
        # Asserted on the CALL, not only on the absence of a file. Forcing the "is a baseline
        # configured" guard true leaves no file behind either -- there is nothing to write -- so a
        # file-based assertion alone passes for a run that read and evaluated a baseline it was
        # never given.
        Mock Get-PSMutationSurvivorBaselineFault { @() }
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet
        $r.FailureReason | Should-Be 'None'
        Should-BeFalse -Actual (Test-Path (Join-Path $script:root '.psmutant-survivors.json'))
        Should-Invoke Get-PSMutationSurvivorBaselineFault -Exactly 0
    }

    It 'treats a configured baseline that does not exist yet as empty, not as unreadable' {
        # The ordinary FIRST run, before -UpdateBaseline has written anything. It must report the
        # survivors as new rather than failing to read a file nobody has created.
        script:UseBaselineConfig
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                    Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() }) }
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet
        $r.FailureReason | Should-Be 'SurvivorBaseline'
    }

    It 'says why it failed even under -Quiet' {
        # -Quiet silences the progress log; a finding is not log. The faults name the mutants a
        # reader has to act on, and in CI this is the only place they appear.
        script:UseBaselineConfig
        '{ "schemaVersion": 1, "survivors": {} }' | Set-Content (Join-Path $script:root 'baseline.json') -Encoding utf8
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                    Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() }) }
        Mock Write-PSMutationOutput { }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        Should-Invoke Write-PSMutationOutput -Times 1 -ParameterFilter {
            $Quiet -eq $false -and (($Lines | ForEach-Object { $_.Text }) -join ' ') -like '*NEW survivor*'
        }
    }

    It 'writes the baseline under -UpdateBaseline, even on a run with survivors' {
        # PHPStan's stance for --generate-baseline: accepting today's mess on a codebase that is
        # already red is the whole use case, and refusing would make the first run impossible.
        script:UseBaselineConfig
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                    Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() }) }
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet -UpdateBaseline
        $r.ExitCode | Should-Be 0
        $doc = Get-Content (Join-Path $script:root 'baseline.json') -Raw | ConvertFrom-Json
        @($doc.survivors.PSObject.Properties.Name) | Should-BeCollection @('src/a.ps1:F:d')
    }

    It 'passes when every survivor is recorded, and fails when one is not' {
        # The two halves in one test because the second is only meaningful against the first:
        # a gate that failed on everything would satisfy the failing half on its own.
        script:UseBaselineConfig
        '{ "schemaVersion": 1, "survivors": { "src/a.ps1:F:d": "" } }' |
            Set-Content (Join-Path $script:root 'baseline.json') -Encoding utf8

        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                    Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() }) }
        (Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet).FailureReason |
            Should-Be 'None'

        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 2; Function = 'G'; File = 'src/a.ps1'
                    Line = 2; Operator = 'BinaryOperator'; Description = 'new'; Status = 'Survived'; KilledBy = @() }) }
        $bad = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet
        $bad.FailureReason | Should-Be 'SurvivorBaseline'
        $bad.ExitCode | Should-Be 1
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

Describe 'Invoke-PSMutation -ListOnly' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:configFile = Join-Path $script:root 'psmutant.json'

        function script:WriteListConfig {
            param([bool]$Covered)
            $c = [ordered]@{
                mutate     = @('src/a.ps1')
                tests      = @{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
                operators  = @('BinaryOperator')
                thresholds = @{ high = 85; low = 70; break = $null }
                reportPath = 'reports/run.json'
            }
            # Written EXPLICITLY in both directions. coveredLinesOnly defaults to TRUE, so
            # omitting the key is the covered case, not the uncovered one -- a fixture that
            # left it out would prove the cheap path against a config that does not take it.
            $c['coveredLinesOnly'] = $Covered
            $c | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8
        }
        WriteListConfig -Covered $false

        Mock Assert-PSMutationPester { }
        Mock Clear-PSMutationStaleSandbox { }
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
        Mock Select-PSMutationCandidate {
            [pscustomobject]@{
                Candidates = @('cand-1', 'cand-2')
                PerFile    = @(
                    [pscustomobject]@{ File = (Join-Path $script:root 'sandbox/src/a.ps1'); Produced = 2; Kept = 2
                        ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 2; Kept = 2 } }
                    }
                    [pscustomobject]@{ File = (Join-Path $script:root 'sandbox/src/empty.ps1'); Produced = 0; Kept = 0
                        ByOperator = [ordered]@{}
                    }
                )
            }
        }
        Mock Invoke-PSMutationLoop { , @() }
    }

    It 'evaluates nothing and returns the list shape' {
        # The whole promise of the mode. A preview that started the loop would be a slower run,
        # not a preview.
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet
        $r.Mode | Should-Be 'List'
        $r.ExitCode | Should-Be 0
        Should-Invoke Invoke-PSMutationLoop -Exactly 0
    }

    It 'writes no report' {
        # A preview measures nothing, so it must not overwrite the artifact a real run left --
        # the convention -RecheckFrom already established.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet | Out-Null
        Test-Path (Join-Path $script:root 'reports/run.json') | Should-BeFalse
    }

    It 'does not run the baseline suite when there is no coverage filter to satisfy' {
        # The cost claim in the help. With coveredLinesOnly off nothing downstream reads a
        # duration or a covered line, so a suite run would buy nothing.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet | Out-Null
        Should-Invoke Invoke-PSMutationBaseline -Exactly 0
    }

    It 'DOES run it when the config filters on coverage' {
        # The filter is part of what would actually be mutated. Skipping it would answer a
        # different question than the run does -- confidently, and low.
        WriteListConfig -Covered $true
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet
        Should-Invoke Invoke-PSMutationBaseline -Exactly 1
        $r.BaselineMeasured | Should-BeTrue
    }

    It 'says so when the counts are an upper bound rather than a filtered set' {
        WriteListConfig -Covered $true
        (Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet).BaselineMeasured | Should-BeTrue
        WriteListConfig -Covered $false
        (Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet).BaselineMeasured | Should-BeFalse
    }

    It 'names the file that produced no candidate, with a repo-relative path' {
        # Both halves. The set is the point of the mode; the path is what makes it usable --
        # the rows come out of a temp sandbox whose name changes every run.
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet
        $r.FilesWithNoCandidate | Should-Be 'src/empty.ps1'
    }

    It 'removes the sandbox' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet | Out-Null
        Should-Invoke Remove-PSMutationSandbox -Exactly 1
    }

    It 'never claims a green baseline it did not measure' {
        # The guard on the "Baseline green in 0.0s (per-mutant timeout 15s)" line. Forced true it
        # prints for a preview that ran no suite -- a statement about a measurement nobody took,
        # in the one mode that takes none, with a duration and a budget to make it convincing.
        Mock Write-PSMutationOutput { }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly | Out-Null
        Should-Invoke Write-PSMutationOutput -Exactly 0 -ParameterFilter { $Lines.Text -match 'Baseline green' }
        # And the preview's own lines DID reach the renderer, so the assertion above is not
        # passing because nothing was rendered at all.
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -match 'mutant set preview' }
    }

    It 'reports the green baseline on a run that DID measure' {
        # The true arm, so the guard is pinned in both directions rather than only against a
        # false claim -- a condition forced to $false would otherwise silence a real run.
        Mock Write-PSMutationOutput { }
        Mock Invoke-PSMutationLoop { , @() }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root | Out-Null
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -match 'Baseline green' }
    }

    It 'refuses a switch that acts on verdicts, before building anything' -ForEach @(
        @{ Extra = @{ UpdateBaseline = $true }; Named = 'UpdateBaseline' }
        @{ Extra = @{ MergeIntoBaseline = $true }; Named = 'MergeIntoBaseline' }
        @{ Extra = @{ RecheckFrom = './prior.json' }; Named = 'RecheckFrom' }
    ) {
        # BEFORE the sandbox: the answer needs nothing a tree copy could tell us, and a
        # refusal that first copies a repository is a slower way to say no.
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ListOnly -Quiet @Extra } |
            Should-Throw -ExceptionMessage "*$Named*"
        Should-Invoke New-PSMutationSandbox -Exactly 0
    }
}

Describe 'Invoke-PSMutation pipeline binding' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        foreach ($n in 'one', 'two') {
            $cfg = Join-Path $script:root "$n.json"
            [ordered]@{
                mutate     = @('src/a.ps1')
                tests      = @{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
                operators  = @('BinaryOperator')
                thresholds = @{ high = 85; low = 70; break = $null }
                reportPath = "reports/$n.json"
            } | ConvertTo-Json -Depth 6 | Set-Content $cfg -Encoding utf8
        }

        Mock Assert-PSMutationPester { }
        Mock Clear-PSMutationStaleSandbox { }
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
        Mock Select-PSMutationCandidate {
            [pscustomobject]@{
                Candidates = @('cand-1')
                PerFile    = @([pscustomobject]@{ File = 'src/a.ps1'; Produced = 1; Kept = 1
                        ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 1; Kept = 1 } }
                    })
            }
        }
        Mock Invoke-PSMutationLoop {
            , @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'
                    Description = 'd'; Status = 'Killed'
                })
        }
    }

    It 'runs once per config piped by VALUE, and returns one result each' {
        # The monorepo case the issue names. Two objects out, not one -- a `process` block that
        # was written as `end` would run only the last config and return a single result.
        $r = @((Join-Path $script:root 'one.json'), (Join-Path $script:root 'two.json')) |
            Invoke-PSMutation -SourceRoot $script:root -Quiet
        @($r).Count | Should-Be 2
        # And each wrote its OWN report, which is what makes them independent runs rather than
        # one run reported twice.
        Test-Path (Join-Path $script:root 'reports/one.json') | Should-BeTrue
        Test-Path (Join-Path $script:root 'reports/two.json') | Should-BeTrue
    }

    It 'binds ConfigFile and SourceRoot from an object by PROPERTY NAME' {
        # The ordinary shape once anything upstream is building or filtering objects. Binding by
        # coercion would reach ConfigFile through ToString() and leave SourceRoot defaulted.
        $r = [pscustomobject]@{ ConfigFile = (Join-Path $script:root 'one.json'); SourceRoot = $script:root } |
            Invoke-PSMutation -Quiet
        @($r).Count | Should-Be 1
        $r.Total | Should-Be 1
    }

    It 'binds SourceRoot from FullName, so a directory object means "mutate this"' {
        $r = Get-Item $script:root | Invoke-PSMutation -ConfigFile (Join-Path $script:root 'one.json') -Quiet
        @($r).Count | Should-Be 1
    }

    It 'refuses a FILE as SourceRoot before building anything' {
        # Piping files binds -ConfigFile by value AND -SourceRoot from the same object's
        # FullName, so this is the shape a caller reaches by accident. Refused at the source
        # rather than several steps later by the sandbox check, whose message names a temp
        # directory the reader has never seen.
        { Invoke-PSMutation -ConfigFile (Join-Path $script:root 'one.json') `
                -SourceRoot (Join-Path $script:root 'one.json') -Quiet } |
            Should-Throw -ExceptionMessage '*is a file, not a directory*'
        Should-Invoke New-PSMutationSandbox -Exactly 0
    }
}

Describe 'Invoke-PSMutation -ChangedFile' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:configFile = Join-Path $script:root 'psmutant.json'
        [ordered]@{
            mutate           = @('src/a.ps1', 'src/b.ps1')
            tests            = @{ 'src/a.ps1' = @('tests/a.Tests.ps1'); 'src/b.ps1' = @('tests/b.Tests.ps1') }
            operators        = @('BinaryOperator')
            coveredLinesOnly = $true
            thresholds       = @{ high = 85; low = 70; break = 50 }
            reportPath       = 'reports/run.json'
        } | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8

        Mock Assert-PSMutationPester { }
        Mock Clear-PSMutationStaleSandbox { }
        Mock New-PSMutationSandbox {
            $sb = Join-Path $script:root 'sandbox'
            foreach ($rel in 'src/a.ps1', 'src/b.ps1', 'tests/a.Tests.ps1', 'tests/b.Tests.ps1') {
                $dest = Join-Path $sb $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Set-Content -LiteralPath $dest -Value '# copied by the sandbox'
            }
            $sb
        }
        Mock Remove-PSMutationSandbox { }
        Mock Invoke-PSMutationBaseline { @{ Passed = $true; DurationSeconds = 2.0; CoveredLines = @{} } }
        Mock Get-PSMutationSourceHashMap { @{ 'src/a.ps1' = 'hash' } }
        # Returns one candidate per mutate file it is GIVEN, so the scoped set is visible in the
        # counts rather than only in a Should-Invoke filter.
        Mock Select-PSMutationCandidate {
            $rows = foreach ($f in $MutateFiles) {
                [pscustomobject]@{ File = $f; Produced = 1; Kept = 1
                    ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 1; Kept = 1 } }
                }
            }
            [pscustomobject]@{
                Candidates = @($MutateFiles | ForEach-Object { "cand-$_" })
                PerFile    = @($rows)
            }
        }
        Mock Invoke-PSMutationLoop {
            , @($Candidates | ForEach-Object {
                    [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'
                        Description = 'd'; Status = 'Killed'
                    }
                })
        }
    }

    It 'mutates only the changed file, not the whole mutate list' {
        # The count is the observable half of the scoping. Unscoped this fixture yields two.
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') -Quiet
        $r.Total | Should-Be 1
        $r.Mode | Should-Be 'Changed'
    }

    It 'mutates everything when -ChangedFile is omitted' {
        # The other arm, so the scoping cannot pass by the fixture only ever producing one.
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet
        $r.Total | Should-Be 2
        $r.Mode | Should-Be 'Full'
        $null -eq $r.ChangedFiles | Should-BeTrue
    }

    It 'writes to the scoped report path and leaves the project one alone' {
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') -Quiet | Out-Null
        Test-Path (Join-Path $script:root 'reports/run.changed.json') | Should-BeTrue
        Test-Path (Join-Path $script:root 'reports/run.json') | Should-BeFalse
    }

    It 'refuses an empty list, and does not refuse an omitted one' {
        # The pair. $null and @() are indistinguishable once bound to [string[]], so the question
        # is asked of $PSBoundParameters -- and forcing that guard either way has to be visible.
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -ChangedFile @() -Quiet } |
            Should-Throw -ExceptionMessage '*empty list*'
        # No Should-NotThrow in this assertion family, so the outcome is captured as a value.
        try { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null; $ran = $true }
        catch { $ran = $false }
        $ran | Should-BeTrue
    }

    It 'says on the console that the run was scoped' {
        # A passing gate is otherwise silent about having measured part of the tree, and a number
        # over part of a tree that nobody knows is partial is the one to worry about.
        Mock Write-PSMutationOutput { }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') | Out-Null
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -match 'SCOPED run' }
    }

    It 'says nothing about scope on a whole-tree run' {
        Mock Write-PSMutationOutput { }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root | Out-Null
        Should-Invoke Write-PSMutationOutput -Exactly 0 -ParameterFilter { $Lines.Text -match 'SCOPED run' }
    }

    It 'passes a pull request that touched no mutable file, and says so' {
        # 0 of 0 under break=50. Both halves: the verdict, and the line that explains it.
        Mock Write-PSMutationOutput { }
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('README.md')
        $r.ExitCode | Should-Be 0
        $r.Total | Should-Be 0
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -match 'nothing to mutate' }
    }

    It 'DOES instrument coverage when the scope matched something' {
        # The other side of the HasMutateFile decision. A count compared against 1 instead of 0
        # turns a single-file pull request -- the ordinary case -- into an uninstrumented run,
        # which then filters on coverage it never measured and evaluates nothing.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') -Quiet | Out-Null
        Should-Invoke Invoke-PSMutationBaseline -Exactly 1 -ParameterFilter { $Coverage }
    }

    It 'still fails a scoped run whose score is below the threshold' {
        # The empty-scope pass must not leak into an ordinary scoped run. `-or` in place of `-and`
        # makes every scoped run look empty, so a pull request with surviving mutants passes.
        Mock Invoke-PSMutationLoop {
            , @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'
                    Description = 'd'; Status = 'Survived'
                })
        }
        $r = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') -Quiet
        $r.Score | Should-Be 0
        $r.ExitCode | Should-Be 1
        $r.FailureReason | Should-Be 'BelowThreshold'
    }

    It 'does not claim there was nothing to mutate when there was' {
        # The notice's false arm. Forced true it tells a reviewer their pull request touched no
        # mutable file, over a run that just evaluated one.
        Mock Write-PSMutationOutput { }
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('src/a.ps1') | Out-Null
        Should-Invoke Write-PSMutationOutput -Exactly 0 -ParameterFilter { $Lines.Text -match 'nothing to mutate' }
    }

    It 'does not instrument coverage when the scope matched nothing' {
        # Nothing to instrument, and Pester would be handed an empty coverage target.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
            -ChangedFile @('README.md') -Quiet | Out-Null
        Should-Invoke Invoke-PSMutationBaseline -Exactly 1 -ParameterFilter { -not $Coverage }
    }

    It 'still runs the baseline for a docs-only run, so a red suite fails it' {
        # The green gate is not scoped. A run that mutated nothing must still refuse to report on
        # a broken suite -- the guard belongs on the tracer, not on the baseline.
        Mock Assert-PSMutationBaselineGreen { throw 'baseline red' }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root `
                -ChangedFile @('README.md') -Quiet } | Should-Throw
    }
}

Describe 'Get-PSMutationRunContext' {
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

        Mock Assert-PSMutationPester { }
        Mock Clear-PSMutationStaleSandbox { }
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
        Mock Select-PSMutationCandidate {
            [pscustomobject]@{
                Candidates = @('cand-1', 'cand-2')
                PerFile    = @([pscustomobject]@{ File = (Join-Path $script:root 'sandbox/src/a.ps1'); Produced = 2; Kept = 2
                        ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 2; Kept = 2 } }
                    })
            }
        }
        Mock Invoke-PSMutationLoop {
            , @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Killed' })
        }
    }

    It 'removes the sandbox when the PRELUDE throws, not only when the loop does' {
        # The prelude is created outside the try and runs inside it, which is the only reason a
        # red baseline does not leak a full tree copy. Reversed -- sandbox inside the try -- the
        # two failures that happen BEFORE the loop are exactly the ones that leak.
        Mock Assert-PSMutationBaselineGreen { throw 'baseline red' }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw
        Should-Invoke Remove-PSMutationSandbox -Exactly 1
    }

    It 'records the baseline duration in the report provenance' {
        # The guard on a scoping trap that fails SILENTLY. A PowerShell scriptblock resolves an
        # unbound variable in the scope that INVOKES it, walking the call stack -- not the scope
        # that created it. Built inside the context and invoked after it returned, every value
        # in here would be $null and the report would still be written.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        $doc = Get-Content (Join-Path $script:root 'reports/run.json') -Raw | ConvertFrom-Json
        $doc.durations.baselineSeconds | Should-Be 2.0
        $doc.durations.perMutantTimeoutSeconds | Should-Be 15
    }

    It 'reports the run duration, which can only be read after the loop' {
        # totalSeconds is the one value the context cannot bind: read early it records how long
        # the run took to START. The clock object travels; the reading happens at the call site.
        Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet | Out-Null
        $doc = Get-Content (Join-Path $script:root 'reports/run.json') -Raw | ConvertFrom-Json
        $doc.durations.totalSeconds | Should-BeGreaterThanOrEqual 0
    }

    It 'checks the config paths reached the sandbox before running anything' {
        # Before the baseline, because after it the answer is a false statement about the tests
        # rather than a true one about the config.
        Mock New-PSMutationSandbox { Join-Path $script:root 'empty-sandbox' }
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:root -Quiet } | Should-Throw
        Should-Invoke Invoke-PSMutationBaseline -Exactly 0
    }
}
