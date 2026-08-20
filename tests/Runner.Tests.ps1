# Unit tests for the runner's pure selection/coverage helpers. The execution functions
# (baseline, per-mutant Pester, loop) are integration-tested by the self-mutation run;
# here we pin the pure parts that decide WHICH mutants to evaluate.
#
# Get-PSMutationPesterPath and Get-PSMutationBoundedPesterScript are MOCKED here and
# tested in Pester.Tests.ps1. That is what keeps this file cheap enough to be the
# covering suite: mutating a timeout necessarily produces mutants that DISABLE it, and
# against a real child runspace each one burns the whole per-mutant deadline.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
    . (Join-Path $src 'PSMutation.Pester.ps1')     # Get-PSMutationPesterPath, mocked below
    . (Join-Path $src 'PSMutation.Runner.ps1')

    $script:fixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-runner-$PID.ps1"
    @'
function Test-Fixture {
    param($x)
    if ($x -eq 1) { return $true }
    return $false
}
'@ | Set-Content $script:fixture
}

AfterAll { Remove-Item $script:fixture -ErrorAction SilentlyContinue }

Describe 'Test-PSMutantCovered' {
    It 'is true when the candidate line was executed' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should-BeTrue
    }
    It 'is false when the line was not executed' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(99) }
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should-BeFalse
    }
    It 'is false when the file was never covered' {
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines @{} | Should-BeFalse
    }
}

Describe 'Select-PSMutationCandidate' {
    It 'returns all candidates when coverage filtering is off' {
        $c = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false -CoveredLines @{}
        $c.Count | Should-BeGreaterThan 0
    }
    It 'keeps only candidates on covered lines when filtering is on' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        $c = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered
        ($c | ForEach-Object Line | Sort-Object -Unique) | Should-Be 3
    }
}

Describe 'Write-PSMutationProgress' {
    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        $script:colours = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:lines.Add([string]$Object); $script:colours.Add([string]$ForegroundColor) }
    }

    It 'marks a survivor with . in yellow and a kill with x in grey' -ForEach @(
        @{ Status = 'Survived'; Glyph = '.'; Colour = 'Yellow'   }
        @{ Status = 'Killed';   Glyph = 'x'; Colour = 'DarkGray' }
    ) {
        # The glyph is how a long run is read at a glance; swapping them would
        # invert the meaning of every line of output while still "printing progress".
        Write-PSMutationProgress -Index 3 -Total 10 `
            -Result ([pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = $Status }) -DisplayFile 'calc.ps1'
        # -Match with an escaped pattern, NOT -BeLike: in a wildcard, "[3/10]" is a
        # character class matching one of 3 / 1 0, so the obvious assertion silently
        # tests something else entirely.
        ($script:lines -join '') | Should-MatchString ([regex]::Escape("[3/10] $Glyph "))
        $script:colours | Should-ContainCollection $Colour
    }

    It 'shows the file, line and the change being tried' {
        Write-PSMutationProgress -Index 1 -Total 2 `
            -Result ([pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = 'Killed' }) -DisplayFile 'calc.ps1'
        ($script:lines -join '') | Should-BeLikeString '*calc.ps1:42*-eq -> -ne*'
    }
}

Describe 'Invoke-PSMutationLoop' {
    It 'accepts an empty candidate set and returns no results' {
        # Reachable two ways: a mutate file with no covered candidates, and a
        # -RecheckFrom run whose previous survivors are all dead. Both are ordinary
        # outcomes, so neither may throw.
        $r = Invoke-PSMutationLoop -Candidates @() -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        @($r).Count | Should-Be 0
    }

    It 'uses the per-file test mapping when the candidate file has one' {
        # The paired case below covers the fallback. This is the mapping actually
        # being honoured -- get it wrong and every mutant runs the entire suite,
        # which is correct but turns a minutes-long run into an hours-long one.
        Mock Invoke-PSMutant { $script:seenTests = $CoveringTests; 'Killed' }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }
        $map = @{ $script:fixture = @('specific.Tests.ps1') }

        $r = Invoke-PSMutationLoop -Candidates @($cand) -TestsByFile $map -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        $script:seenTests | Should-BeCollection @('specific.Tests.ps1')
        $r[0].Status | Should-Be 'Killed'
    }

    It 'writes a progress line per mutant unless asked to be quiet' {
        # Every other test here passes -Quiet, so the reporting branch never ran.
        Mock Invoke-PSMutant { 'Killed' }
        Mock Write-PSMutationProgress { }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }

        Invoke-PSMutationLoop -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) | Out-Null

        Should-Invoke Write-PSMutationProgress -Exactly 1 -ParameterFilter { $Index -eq 1 -and $Total -eq 1 }
    }

    It 'stays silent when asked to be quiet' {
        Mock Invoke-PSMutant { 'Killed' }
        Mock Write-PSMutationProgress { }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }

        Invoke-PSMutationLoop -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet | Out-Null

        Should-Invoke Write-PSMutationProgress -Exactly 0
    }

    It 'falls back to the whole test set for a file with no per-file mapping' {
        # An unmapped file must still be evaluated against SOMETHING; running zero
        # tests would mark every one of its mutants Survived and quietly tank the
        # score for a config typo.
        $seen = $null
        Mock Invoke-PSMutant { $script:seenTests = $CoveringTests; 'Killed' }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }
        $r = Invoke-PSMutationLoop -Candidates @($cand) -TestsByFile @{} -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        $script:seenTests | Should-BeCollection @('all-tests.ps1')
        $r[0].Status     | Should-Be 'Killed'
        Should-BeNull -Actual $seen
    }
}

Describe 'Invoke-PSMutationBaseline' {
    # The baseline run is what decides (a) whether mutation may proceed at all and
    # (b) which lines are covered, i.e. which mutants are even worth evaluating. It
    # was only ever exercised end-to-end, so its result-shaping was unpinned. Pester
    # itself is mocked here: the point is what this function does with the result.
    It 'reports a passing suite and collapses covered lines per file' {
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Passed'
                CodeCoverage = [pscustomobject]@{
                    CommandsExecuted = @(
                        [pscustomobject]@{ File = $script:fixture; Line = 3 }
                        [pscustomobject]@{ File = $script:fixture; Line = 7 }
                        # Same line reported twice -- one command per statement means
                        # this is normal, and the line must not be counted twice.
                        [pscustomobject]@{ File = $script:fixture; Line = 3 }
                    )
                }
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture)

        $r.Passed | Should-BeTrue
        $key = [System.IO.Path]::GetFullPath($script:fixture)
        $r.CoveredLines[$key].Count     | Should-Be 2
        $r.CoveredLines[$key].Contains(3) | Should-BeTrue
        $r.CoveredLines[$key].Contains(7) | Should-BeTrue
        $r.DurationSeconds | Should-BeGreaterThanOrEqual 0
    }

    It 'asks Pester for the result object and for coverage' {
        # Both flags are invisible to a mocked test unless the configuration itself is
        # asserted, and both are load-bearing: without PassThru there is no result
        # object to read at all, and without CodeCoverage enabled every candidate looks
        # uncovered -- so coveredLinesOnly would quietly reduce the run to nothing and
        # report a perfect score over zero mutants.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) | Out-Null

        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter {
            $Configuration.Run.PassThru.Value -eq $true -and $Configuration.CodeCoverage.Enabled.Value -eq $true
        }
    }

    It 'keys covered lines by FULL path, whatever Pester reported' {
        # Candidates carry absolute paths, so a relative key here would match nothing
        # and every mutant would look uncovered -- an empty run reported as success.
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            $leaf = Split-Path $script:fixture -Leaf
            Mock Invoke-Pester {
                [pscustomobject]@{
                    Result       = 'Passed'
                    CodeCoverage = [pscustomobject]@{ CommandsExecuted = @([pscustomobject]@{ File = $leaf; Line = 1 }) }
                }
            }
            $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture)
            @($r.CoveredLines.Keys)[0] | Should-Be ([System.IO.Path]::GetFullPath($leaf))
        }
        finally { Pop-Location }
    }

    It 'reports a failing suite so the run can refuse to start' {
        # Mutating against a red suite is meaningless: every mutant "dies" for the
        # reason the suite was already failing.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Failed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture)

        $r.Passed | Should-BeFalse
        $r.CoveredLines.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationRunspaceError' {
    It 'joins every message the child wrote to its error stream' {
        $fake = [pscustomobject]@{ Streams = [pscustomobject]@{ Error = @(
                    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'first' } }
                    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'second' } }
                ) } }
        Get-PSMutationRunspaceError -Runspace $fake | Should-Be 'first; second'
    }

    It 'says so when the child died without writing an error' {
        # This text lands inside a thrown exception. An empty string there would
        # report "produced no result: " and name nothing at all.
        $fake = [pscustomobject]@{ Streams = [pscustomobject]@{ Error = @() } }
        Get-PSMutationRunspaceError -Runspace $fake | Should-Be 'the child runspace reported no error'
    }
}

Describe 'Invoke-PSMutant' {
    # Invoke-PSMutant is also exercised for real in tests/Mutant.Tests.ps1, against a
    # live child runspace. These mocked versions exist so this file alone can be the
    # self-mutation covering suite for Runner.ps1: mutating a timeout mechanism produces
    # mutants that DISABLE the timeout, and against a real runspace each of those runs
    # until the outer per-mutant deadline -- minutes apiece, for the same verdict.
    BeforeEach {
        $script:target = Join-Path $TestDrive 'mutable.ps1'
        $script:before = "function Get-Thing { return 1 }`n"
        [System.IO.File]::WriteAllText($script:target, $script:before)
        $script:candidate = [pscustomobject]@{ File = $script:target }
    }

    It 'reports Survived only when the suite still fully passes' {
        Mock Invoke-PSBoundedPester { 'Passed' }
        Invoke-PSMutant -Candidate $script:candidate -MutatedContent 'mutated' `
            -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 5 | Should-Be 'Survived'
    }

    It 'reports Killed for any outcome that is not a clean pass' -ForEach @(
        @{ Outcome = 'Failed' }
        @{ Outcome = 'TimedOut' }
        @{ Outcome = 'Inconclusive' }
    ) {
        # Anything but Passed is a kill, which is why an outcome that means "we could
        # not tell" must never reach here -- see Invoke-PSBoundedPester.
        Mock Invoke-PSBoundedPester { $Outcome }
        Invoke-PSMutant -Candidate $script:candidate -MutatedContent 'mutated' `
            -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 5 | Should-Be 'Killed'
    }

    It 'writes the mutant into the file and restores it afterwards' {
        # The restore is what lets the next mutant start from clean source. Miss it and
        # every later mutant is evaluated against an accumulating pile of earlier ones.
        Mock Invoke-PSBoundedPester { $script:during = [System.IO.File]::ReadAllText($script:target); 'Passed' }

        Invoke-PSMutant -Candidate $script:candidate -MutatedContent 'MUTATED' `
            -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 5 | Out-Null

        $script:during | Should-Be 'MUTATED'
        [System.IO.File]::ReadAllText($script:target) | Should-Be $script:before
    }

    It 'restores the file even when the covering run throws' {
        # A child that cannot be evaluated now throws rather than scoring a kill, so the
        # restore has to survive that path too -- otherwise one broken mutant leaves the
        # sandbox corrupted for every mutant after it.
        Mock Invoke-PSBoundedPester { throw 'child exploded' }
        { Invoke-PSMutant -Candidate $script:candidate -MutatedContent 'MUTATED' `
                -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 5 } | Should-Throw
        [System.IO.File]::ReadAllText($script:target) | Should-Be $script:before
    }
}

Describe 'Invoke-PSBoundedPester' {
    BeforeEach { Mock Get-PSMutationPesterPath { 'unused - the child script is mocked too' } }

    It 'hands back the verdict the child produced' {
        Mock Get-PSMutationBoundedPesterScript { 'param($tests, $pester) "Passed"' }
        Invoke-PSBoundedPester -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 10 | Should-Be 'Passed'
    }

    It 'fails loudly when the child returns no verdict, and says what the child said' {
        # A child that returned nothing proved nothing, but Invoke-PSMutant reads
        # anything-but-Passed as a kill -- so silence used to score as a caught fault.
        # That is how the Pester version collision produced a fake 100%.
        #
        # Both halves of the message are asserted deliberately. Matching only the
        # literal prefix is not discriminating: if the concatenation breaks, the
        # resulting conversion error QUOTES the prefix, so a prefix-only pattern still
        # matches and the diagnosis is silently lost.
        Mock Get-PSMutationBoundedPesterScript { 'param($tests, $pester) Write-Error "child said no"' }
        { Invoke-PSBoundedPester -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 10 } |
            Should-Throw -ExceptionMessage '*produced no result*child said no*'
    }

    It 'takes the LAST thing the child emitted as the verdict' {
        # A covering test file can write its own output before Pester's result -- a
        # stray Write-Output, a warning surfacing as an object. Only the final value is
        # the verdict; carrying any of the noise with it stops the string ever matching
        # 'Passed', which silently turns every survivor into a kill.
        Mock Get-PSMutationBoundedPesterScript { 'param($tests, $pester) "noise from a test file"; "Passed"' }
        Invoke-PSBoundedPester -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 10 | Should-Be 'Passed'
    }

    It 'cuts off a child that overruns and reports TimedOut' {
        # The real non-terminating case is proven in tests/Mutant.Tests.ps1. Here the
        # child merely sleeps, so the deadline is reached in seconds rather than by
        # spinning a mutated loop -- same branch, a fraction of the wall clock.
        Mock Get-PSMutationBoundedPesterScript { 'param($tests, $pester) Start-Sleep -Seconds 30' }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = Invoke-PSBoundedPester -CoveringTests @('t.Tests.ps1') -TimeoutSeconds 2
        $sw.Stop()

        $outcome | Should-Be 'TimedOut'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20   # cut off, not waited out
    }
}

Describe 'Assert-PSMutationBaselineGreen' {
    It 'refuses to mutate against a red suite' {
        # The most misleading result this tool could produce: against a failing
        # suite every mutant "dies" for the reason the suite was already red, and
        # the run reports a perfect score.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $false }) } |
            Should-Throw -ExceptionMessage '*Baseline suite is not green*'
    }
    It 'lets a green baseline through' {
        # A guard that lets the run continue emits nothing at all. Calling it directly
        # covers the refusal case too: an exception here fails the test on its own,
        # which is why v6 offers no "does not throw" assertion to wrap it in.
        Should-BeNull -Actual (Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $true }))
    }
}

Describe 'ids are assigned before the coverage filter, not after' {
    It 'keeps a candidate id the same whether or not covered-lines filtering ran' {
        # The invariant #59 named: numbering happens in Get-PSMutationCandidate over the
        # UNFILTERED set, and Select-PSMutationCandidate filters afterwards. It is what lets
        # a recheck match survivors by id across a coverage change -- and coverage changing
        # is precisely what happens when you write the assertions that kill survivors, so
        # the compatibility gate can stay narrow and not inspect coverage at all.
        #
        # This test fails the moment someone "optimises" by filtering first, or by moving
        # the numbering into Select-PSMutationCandidate. That refactor looks obviously
        # correct and silently makes a recheck answer about the wrong mutants.
        # Assigned directly, NOT wrapped in @(). Select-PSMutationCandidate comma-wraps its
        # return to preserve a single-element array, so @(...) hands back one item that IS
        # the array and every count below reads 1 (see the convention note in #38).
        $all = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false
        $all.Count | Should-BeGreaterThan 1

        # Admit only the lines of the LAST candidate, so any renumbering shows up as id 1.
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $last = $all[-1]
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@($last.Line) }
        $filtered = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered

        $filtered.Count | Should-BeLessThan $all.Count
        # The surviving candidate keeps the id it had in the full set. Renumbering after
        # filtering would make this 1.
        $filtered[-1].Id | Should-Be $last.Id
    }
}

Describe 'the mutant row the report publishes' {
    It 'carries exactly the fields the report contract names' {
        # Built here, not by Write-PSMutationReport, which serialises whatever it is handed
        # -- so this is the only place the shape is really decided.
        #
        # It is a PROJECTION of the internal candidate: StartOffset, EndOffset, Original and
        # Mutated are deliberately absent. Widening it to project the whole candidate would
        # re-publish the undeclared nine-field object #48 just withdrew, through the report
        # instead of through an export.
        Mock Invoke-PSMutant { 'Killed' }
        $cand = [pscustomobject]@{
            Id = 7; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = '-eq -> -ne'; StartOffset = 0; EndOffset = 1; Mutated = ' '
            Original = '-eq'
        }
        $r = Invoke-PSMutationLoop -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        @($r)[0].PSObject.Properties.Name |
            Should-BeCollection @('Id', 'File', 'Line', 'Operator', 'Description', 'Status')
    }
}
