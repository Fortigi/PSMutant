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
