# Unit tests for config resolution -- the "what did the user ask for, and what do we
# do when they didn't say" decisions. These lived inside Invoke-PSMutation, past the
# nested Pester run that destroys the outer run's coverage breakpoints, so they could
# not be measured there. Out here they are ordinary pure functions.
#
# Resolvers only. The baseline guard and the public result shape were tested here while
# they lived in Config.ps1; they are now covered beside the baseline they judge
# (Runner.Tests.ps1) and the report contract they belong to (Report.Tests.ps1) -- #45.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Sandbox.ps1', 'PSMutation.Config.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Get-PSMutationSandboxPlan' {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'repo'
        $script:sb = Join-Path $TestDrive 'sandbox'
        # Two mutate files with DIFFERENT mappings, one of them naming two test files.
        # A plan that merged the entries, or kept only the last, would still look
        # right against the single-file config every other fixture here uses.
        $script:cfg = [pscustomobject]@{
            mutate = @('src/a.ps1', 'src/b.ps1')
            tests  = [pscustomobject]@{
                'src/a.ps1' = @('tests/a.Tests.ps1')
                'src/b.ps1' = @('tests/b1.Tests.ps1', 'tests/b2.Tests.ps1')
            }
        }
        $script:plan = Get-PSMutationSandboxPlan -Cfg $script:cfg -SourceRoot $script:root -SandboxRoot $script:sb
    }

    It 'points every mutate path at the sandbox copy, never the tracked file' {
        # The headline guarantee of the tool. Hand back repo paths and the runner
        # splices mutants into tracked source, so a hard kill mid-run leaves a
        # mutated file staged in git.
        $expected = @('src/a.ps1', 'src/b.ps1') |
            ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $script:sb $_)) }
        $script:plan.Mutate | Should-BeCollection $expected
        $script:plan.Mutate | Should-NotContainCollection ([System.IO.Path]::GetFullPath((Join-Path $script:root 'src/a.ps1')))
    }

    It 'keys the per-file test map by the SANDBOXED source path' {
        # Invoke-PSMutationLoop looks the mapping up by the candidate's file, which is
        # a sandbox path. Keyed by repo path every lookup misses, every file falls
        # back to the whole suite, and a run that should take minutes takes hours --
        # while still reporting the right score, so nothing looks wrong.
        $keyA = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/a.ps1'))
        $keyB = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/b.ps1'))
        $script:plan.TestsByFile.Keys | Should-ContainCollection $keyA
        $script:plan.TestsByFile[$keyA] |
            Should-BeCollection @([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/a.Tests.ps1')))
        $script:plan.TestsByFile[$keyB] | Should-BeCollection -Count 2
    }

    It 'gathers every mapped test file into AllTests' {
        # AllTests is what the baseline runs. Drop one and the lines it covers are
        # never recorded, so with coveredLinesOnly on that source file yields no
        # candidates at all -- a vacuous 100% over code nothing mutated.
        $script:plan.AllTests | Should-BeCollection -Count 3
        $script:plan.AllTests |
            Should-ContainCollection ([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/b2.Tests.ps1')))
    }

    It 'accepts a single covering test written as a bare string' {
        # ConvertFrom-Json yields a bare string rather than a one-element array when
        # the config names exactly one test, which is the common case.
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1')
            tests  = [pscustomobject]@{ 'src/a.ps1' = 'tests/a.Tests.ps1' }
        }
        $plan = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $script:root -SandboxRoot $script:sb
        $key = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/a.ps1'))
        $plan.TestsByFile[$key] |
            Should-BeCollection @([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/a.Tests.ps1')))
        $plan.AllTests | Should-BeCollection -Count 1
    }
}

Describe 'Get-PSMutationSubtree' {
    It 'uses the subtrees the config names' {
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = @('lib', 'spec') }) |
            Should-BeCollection @('lib', 'spec')
    }
    It 'falls back to the module convention when the config is silent' {
        # A consuming repo whose layout is src/ + tests/ should not have to say so.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{}) | Should-BeCollection @('src', 'tests')
    }
    It 'wraps a single subtree as a list' {
        # JSON gives a bare string for a one-element array; the caller indexes it.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = 'onlysrc' }) |
            Should-BeCollection @('onlysrc')
    }
}

Describe 'Get-PSMutationTimeout' {
    It 'scales the budget with the baseline duration' {
        # 10s baseline x the default factor of 4.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 10 | Should-Be 40
    }

    It 'never drops below the floor, however fast the baseline is' {
        # THE case this floor exists for. A 0.2s suite x 4 is under a second; as an
        # int budget that is 0, every mutant is cut off on time rather than on
        # behaviour, and the run reports a perfect score against tests that never
        # finished. The floor is what stops a fast suite scoring 100% for free.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 0.2 | Should-Be 15
    }

    It 'honours a configured factor and floor' {
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFactor = 10 }) -BaselineSeconds 10 | Should-Be 100
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 60 }) -BaselineSeconds 1 | Should-Be 60
    }

    It 'takes whichever of floor and scaled-baseline is larger' {
        # Both configured, so neither default can mask a wrong comparison: the floor
        # wins for a quick baseline and the scaled value wins for a slow one.
        $cfg = [pscustomobject]@{ timeoutFactor = 2; timeoutFloorSeconds = 30 }
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 5   | Should-Be 30   # floor
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 100 | Should-Be 200  # scaled
    }

    It 'returns whole seconds' {
        # The value is handed to a job timeout that expects an int.
        $t = Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 1 }) -BaselineSeconds 2.6
        $t | Should-HaveType ([int])
        $t | Should-Be 10
    }
}
