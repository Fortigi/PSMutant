# Unit tests for the runner's pure selection/coverage helpers. The execution functions
# (baseline, per-mutant Pester, loop) are integration-tested by the self-mutation run;
# here we pin the pure parts that decide WHICH mutants to evaluate.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
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
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should -BeTrue
    }
    It 'is false when the line was not executed' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(99) }
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should -BeFalse
    }
    It 'is false when the file was never covered' {
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines @{} | Should -BeFalse
    }
}

Describe 'Select-PSMutationCandidate' {
    It 'returns all candidates when coverage filtering is off' {
        $c = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false -CoveredLines @{}
        $c.Count | Should -BeGreaterThan 0
    }
    It 'keeps only candidates on covered lines when filtering is on' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        $c = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered
        ($c | ForEach-Object Line | Sort-Object -Unique) | Should -Be 3
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
        ($script:lines -join '') | Should -Match ([regex]::Escape("[3/10] $Glyph "))
        $script:colours | Should -Contain $Colour
    }

    It 'shows the file, line and the change being tried' {
        Write-PSMutationProgress -Index 1 -Total 2 `
            -Result ([pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = 'Killed' }) -DisplayFile 'calc.ps1'
        ($script:lines -join '') | Should -BeLike '*calc.ps1:42*-eq -> -ne*'
    }
}

Describe 'Invoke-PSMutationLoop' {
    It 'accepts an empty candidate set and returns no results' {
        # Reachable two ways: a mutate file with no covered candidates, and a
        # -RecheckFrom run whose previous survivors are all dead. Both are ordinary
        # outcomes, so neither may throw.
        $r = Invoke-PSMutationLoop -Candidates @() -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        @($r).Count | Should -Be 0
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

        $script:seenTests | Should -Be @('specific.Tests.ps1')
        $r[0].Status | Should -Be 'Killed'
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

        Should -Invoke Write-PSMutationProgress -Exactly 1 -ParameterFilter { $Index -eq 1 -and $Total -eq 1 }
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

        Should -Invoke Write-PSMutationProgress -Exactly 0
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
        $script:seenTests | Should -Be @('all-tests.ps1')
        $r[0].Status     | Should -Be 'Killed'
        $seen            | Should -BeNullOrEmpty
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

        $r.Passed | Should -BeTrue
        $key = [System.IO.Path]::GetFullPath($script:fixture)
        $r.CoveredLines[$key].Count     | Should -Be 2
        $r.CoveredLines[$key].Contains(3) | Should -BeTrue
        $r.CoveredLines[$key].Contains(7) | Should -BeTrue
        $r.DurationSeconds | Should -BeGreaterOrEqual 0
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
            @($r.CoveredLines.Keys)[0] | Should -Be ([System.IO.Path]::GetFullPath($leaf))
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

        $r.Passed | Should -BeFalse
        $r.CoveredLines.Count | Should -Be 0
    }
}
