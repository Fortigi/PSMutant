# Which tests a mutant tries first (#254).
#
# The covering suite for self-mutating src/PSMutation.Killers.ps1 -- pure and cheap. The runner's
# use of it, with real worker runspaces, is in tests/Runner.Tests.ps1 and tests/Mutant.Tests.ps1.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PSMutation.Killers.ps1')
    function script:Learn {
        param($Memory, [string]$File = 'a.ps1', [string]$Function = 'F', [string[]]$Name, [string[]]$Suite = @('t.Tests.ps1'))
        Add-PSMutationKiller -Memory $Memory -File $File -Function $Function -Name $Name -Suite $Suite
    }
    function script:Prove { param($Memory, [string[]]$Name) foreach ($n in $Name) { [void]$Memory.Proven.Add($n) } }
}

Describe 'New-PSMutationKillerMemory' {
    It 'starts empty' {
        $m = New-PSMutationKillerMemory
        $m.ByFunction.Count | Should-Be 0
        $m.ByFile.Count | Should-Be 0
        $m.Proven.Count | Should-Be 0
        $m.Seconds.Count | Should-Be 0
        $m.Queued.Count | Should-Be 0
        $m.Pending.Count | Should-Be 0
    }

    It 'compares names exactly, case included' {
        # Pester's filter is a -like match, which ignores case, but two tests differing only in case
        # are two tests; proving one must not prove the other.
        $m = New-PSMutationKillerMemory
        [void]$m.Proven.Add('D.it')
        Should-BeFalse -Actual $m.Proven.Contains('D.IT')
        [void]$m.Queued.Add('D.it')
        Should-BeTrue -Actual $m.Queued.Add('D.IT')
    }
}

Describe 'Add-PSMutationKiller' {
    It 'records a killer under its function and its file, and queues it for proof with its suite' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.one' -Suite @('x.Tests.ps1', 'y.Tests.ps1')
        @($m.ByFunction["a.ps1`nF"]) | Should-BeCollection @('D.one')
        @($m.ByFile['a.ps1']) | Should-BeCollection @('D.one')
        $m.Pending.Count | Should-Be 1
        $m.Pending[0].Name | Should-Be 'D.one'
        @($m.Pending[0].Suite) | Should-BeCollection @('x.Tests.ps1', 'y.Tests.ps1')
    }

    It 'queues a name ONCE, however often it kills, but still records every kill' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.one'
        Learn $m -Name 'D.one'
        Learn $m -Function 'G' -Name 'D.one'
        $m.Pending.Count | Should-Be 1
        @($m.ByFile['a.ps1']).Count | Should-Be 3
        @($m.ByFunction["a.ps1`nF"]).Count | Should-Be 2
    }

    It 'records nothing for a mutant with no killer' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name @()
        $m.ByFunction.Count | Should-Be 0
        $m.ByFile.Count | Should-Be 0
    }

    It 'keeps functions and files apart' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.one'
        Learn $m -File 'b.ps1' -Function 'F' -Name 'D.two'
        @($m.ByFunction["a.ps1`nF"]) | Should-BeCollection @('D.one')
        @($m.ByFunction["b.ps1`nF"]) | Should-BeCollection @('D.two')
    }
}

Describe 'Get-PSMutationFirstTest' {
    It 'is nothing before anything was learned' {
        @(Get-PSMutationFirstTest -Memory (New-PSMutationKillerMemory) -File 'a.ps1' -Function 'F').Count | Should-Be 0
    }

    It 'offers only PROVEN names' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.one', 'D.two'
        Prove $m 'D.two'
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F') | Should-BeCollection @('D.two')
    }

    It 'offers the function''s latest killers first, then the file''s, each once' {
        $m = New-PSMutationKillerMemory
        Learn $m -Function 'G' -Name 'D.g'
        Learn $m -Name 'D.old'
        Learn $m -Name 'D.new'
        Learn $m -Name 'D.old'
        Prove $m 'D.g', 'D.old', 'D.new'
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F' -Limit 5) | Should-BeCollection @('D.old', 'D.new', 'D.g')
    }

    It 'stops at the limit, three by default' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.1', 'D.2', 'D.3', 'D.4'
        Prove $m 'D.1', 'D.2', 'D.3', 'D.4'
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F') | Should-BeCollection @('D.4', 'D.3', 'D.2')
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F' -Limit 4) | Should-BeCollection @('D.4', 'D.3', 'D.2', 'D.1')
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F' -Limit 1) | Should-BeCollection @('D.4')
    }

    It 'reaches into the file when the function has fewer than the limit, and not into another file' {
        $m = New-PSMutationKillerMemory
        Learn $m -Function 'G' -Name 'D.g'
        Learn $m -File 'b.ps1' -Name 'D.b'
        Prove $m 'D.g', 'D.b'
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function 'F') | Should-BeCollection @('D.g')
    }

    It 'answers for script-level code, whose function is empty' {
        $m = New-PSMutationKillerMemory
        Learn $m -Function '' -Name 'D.top'
        Prove $m 'D.top'
        @(Get-PSMutationFirstTest -Memory $m -File 'a.ps1' -Function '') | Should-BeCollection @('D.top')
    }
}

Describe 'Get-PSMutationProofBatch' {
    It 'is nothing when no name waits' {
        Should-BeNull -Actual (Get-PSMutationProofBatch -Memory (New-PSMutationKillerMemory))
    }

    It 'takes every waiting name that shares the first one''s suite, and leaves the rest waiting' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.1' -Suite @('x.Tests.ps1')
        Learn $m -Name 'D.2' -Suite @('y.Tests.ps1')
        Learn $m -Name 'D.3' -Suite @('x.Tests.ps1')
        $b = Get-PSMutationProofBatch -Memory $m
        @($b.Suite) | Should-BeCollection @('x.Tests.ps1')
        @($b.Name) | Should-BeCollection @('D.1', 'D.3')
        $m.Pending.Count | Should-Be 1
        $m.Pending[0].Name | Should-Be 'D.2'
        # And the next batch is the rest.
        @((Get-PSMutationProofBatch -Memory $m).Name) | Should-BeCollection @('D.2')
        $m.Pending.Count | Should-Be 0
    }

    It 'tells a suite of two files from one of its files' {
        $m = New-PSMutationKillerMemory
        Learn $m -Name 'D.1' -Suite @('x.Tests.ps1', 'y.Tests.ps1')
        Learn $m -Name 'D.2' -Suite @('x.Tests.ps1')
        @((Get-PSMutationProofBatch -Memory $m).Name) | Should-BeCollection @('D.1')
    }
}

Describe 'Complete-PSMutationProof' {
    It 'proves a name that passed and did not fail, and no other' {
        # 'D.bad' is a -ForEach test with one case passing and one failing.
        $m = New-PSMutationKillerMemory
        Complete-PSMutationProof -Memory $m -Name 'D.ok', 'D.bad', 'D.gone' -PassedPath @('D.ok', 'D.bad', 'D.other') -FailedPath @('D.bad') -Seconds 2.5
        @($m.Proven | Sort-Object) | Should-BeCollection @('D.ok')
        # And keeps the proof's time against the name it proved, and only that one.
        @($m.Seconds.Keys) | Should-BeCollection @('D.ok')
        $m.Seconds['D.ok'] | Should-Be 2.5
    }

    It 'matches names exactly' {
        $m = New-PSMutationKillerMemory
        Complete-PSMutationProof -Memory $m -Name 'D.ok' -PassedPath @('D.OK') -FailedPath @() -Seconds 1
        $m.Proven.Count | Should-Be 0
        Complete-PSMutationProof -Memory $m -Name 'D.ok' -PassedPath @('D.ok') -FailedPath @('D.OK') -Seconds 1
        @($m.Proven) | Should-BeCollection @('D.ok')
    }
}

Describe 'Get-PSMutationFirstPassTimeout' {
    BeforeAll {
        $script:fpMemory = New-PSMutationKillerMemory
        $script:fpMemory.Seconds['D.fast'] = 0.5
        $script:fpMemory.Seconds['D.slow'] = 3.2
        $script:fpRule = [pscustomobject]@{ Factor = 4; Floor = 15 }
    }

    It 'sizes from the SLOWEST name: its proof time times the factor, rounded up' {
        # 3.2 x 4 = 12.8 -> 13 with a floor of 1. Not times the workers (#310): a proof ran while the
        # other workers ran their mutants, so its time already holds the load.
        $rule = [pscustomobject]@{ Factor = 4; Floor = 1 }
        Get-PSMutationFirstPassTimeout -Memory $script:fpMemory -Name 'D.fast', 'D.slow' -Rule $rule -Cap 600 |
            Should-Be 13
        (Get-Command Get-PSMutationFirstPassTimeout).Parameters.ContainsKey('Workers') | Should-BeFalse
    }

    It 'never goes under the floor' {
        Get-PSMutationFirstPassTimeout -Memory $script:fpMemory -Name 'D.fast' -Rule $script:fpRule -Cap 600 | Should-Be 15
    }

    It 'never goes over the whole run''s own deadline' {
        Get-PSMutationFirstPassTimeout -Memory $script:fpMemory -Name 'D.slow' -Rule ([pscustomobject]@{ Factor = 40; Floor = 15 }) -Cap 20 |
            Should-Be 20
    }
}
