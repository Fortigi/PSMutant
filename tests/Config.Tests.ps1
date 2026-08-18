# Unit tests for config resolution -- the "what did the user ask for, and what do we
# do when they didn't say" decisions. These lived inside Invoke-PSMutation, past the
# nested Pester run that destroys the outer run's coverage breakpoints, so they could
# not be measured there. Out here they are ordinary pure functions.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Config.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Get-PSMutationSubtree' {
    It 'uses the subtrees the config names' {
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = @('lib', 'spec') }) |
            Should -Be @('lib', 'spec')
    }
    It 'falls back to the module convention when the config is silent' {
        # A consuming repo whose layout is src/ + tests/ should not have to say so.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{}) | Should -Be @('src', 'tests')
    }
    It 'wraps a single subtree as a list' {
        # JSON gives a bare string for a one-element array; the caller indexes it.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = 'onlysrc' }) |
            Should -Be @('onlysrc')
    }
}

Describe 'Get-PSMutationOperatorList' {
    It 'uses the operators the config names' {
        Get-PSMutationOperatorList -Cfg ([pscustomobject]@{ operators = @('BinaryOperator') }) |
            Should -Be @('BinaryOperator')
    }
    It 'falls back to the default set when the config is silent' {
        $ops = Get-PSMutationOperatorList -Cfg ([pscustomobject]@{})
        $ops | Should -Contain 'BinaryOperator'
        $ops | Should -Contain 'BooleanLiteral'
        $ops | Should -Contain 'NumberLiteral'
        $ops | Should -Contain 'NegationRemoval'
        # StringLiteral is NOT on by default: emptying every string in a repo produces
        # a flood of survivors that say nothing about behaviour.
        $ops | Should -Not -Contain 'StringLiteral'
    }
}

Describe 'Get-PSMutationTimeout' {
    It 'scales the budget with the baseline duration' {
        # 10s baseline x the default factor of 4.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 10 | Should -Be 40
    }

    It 'never drops below the floor, however fast the baseline is' {
        # THE case this floor exists for. A 0.2s suite x 4 is under a second; as an
        # int budget that is 0, every mutant is cut off on time rather than on
        # behaviour, and the run reports a perfect score against tests that never
        # finished. The floor is what stops a fast suite scoring 100% for free.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 0.2 | Should -Be 15
    }

    It 'honours a configured factor and floor' {
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFactor = 10 }) -BaselineSeconds 10 | Should -Be 100
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 60 }) -BaselineSeconds 1 | Should -Be 60
    }

    It 'takes whichever of floor and scaled-baseline is larger' {
        # Both configured, so neither default can mask a wrong comparison: the floor
        # wins for a quick baseline and the scaled value wins for a slow one.
        $cfg = [pscustomobject]@{ timeoutFactor = 2; timeoutFloorSeconds = 30 }
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 5   | Should -Be 30   # floor
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 100 | Should -Be 200  # scaled
    }

    It 'returns whole seconds' {
        # The value is handed to a job timeout that expects an int.
        $t = Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 1 }) -BaselineSeconds 2.6
        $t | Should -BeOfType [int]
        $t | Should -Be 10
    }
}

Describe 'Assert-PSMutationBaselineGreen' {
    It 'refuses to mutate against a red suite' {
        # The most misleading result this tool could produce: against a failing
        # suite every mutant "dies" for the reason the suite was already red, and
        # the run reports a perfect score.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $false }) } |
            Should -Throw '*Baseline suite is not green*'
    }
    It 'lets a green baseline through' {
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $true }) } |
            Should -Not -Throw
    }
}

Describe 'ConvertTo-PSMutationRunResult' {
    It 'exposes the score, the counts and the exit code' {
        # This object is the module's public contract -- CI reads .Score and .ExitCode.
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }

        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1

        $r.Score    | Should -Be 64.3
        $r.Killed   | Should -Be 164
        $r.Survived | Should -Be 91
        $r.Total    | Should -Be 255
        $r.ExitCode | Should -Be 1
    }

    It 'keeps killed and survived distinct' {
        # Numbers chosen so a swapped pair cannot pass: equal counts would hide it.
        $s = [pscustomobject]@{ Score = 50; Killed = 3; Survived = 7; Total = 10 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0
        $r.Killed   | Should -Be 3
        $r.Survived | Should -Be 7
    }
}
