# Direct tests for the per-mutant execution: kill/survive classification, the
# isolation/restore guarantee, and -- crucially -- that a runaway (non-terminating)
# mutant is cut off by the timeout and counted Killed instead of hanging the run.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Pester.ps1',
        'PSMutation.Output.ps1', 'PSMutation.Killers.ps1', 'PSMutation.Runner.ps1') { . (Join-Path $src $f) }

    # A tiny fixture "project": a module function + a covering test that dot-sources it.
    $script:proj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-mut-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:proj -Force | Out-Null
    $script:modPath = Join-Path $script:proj 'mod.ps1'
    @'
function Get-Double { param($n) return ($n * 2) }
function Get-Count { $i = 0; while ($i -lt 3) { $i = $i + 1 }; return $i }
'@ | Set-Content $script:modPath -Encoding utf8

    $strictTest = Join-Path $script:proj 'strict.Tests.ps1'
    "BeforeAll { . '$($script:modPath -replace '\\','\\')' }; Describe 'd' { It 'doubles' { Get-Double 3 | Should -Be 6 } }" | Set-Content $strictTest -Encoding utf8
    $weakTest = Join-Path $script:proj 'weak.Tests.ps1'
    "BeforeAll { . '$($script:modPath -replace '\\','\\')' }; Describe 'd' { It 'runs' { { Get-Double 3 } | Should -Not -Throw } }" | Set-Content $weakTest -Encoding utf8
    $countTest = Join-Path $script:proj 'count.Tests.ps1'
    "BeforeAll { . '$($script:modPath -replace '\\','\\')' }; Describe 'd' { It 'counts' { Get-Count | Should -Be 3 } }" | Set-Content $countTest -Encoding utf8

    $script:strictTest = $strictTest
    $script:weakTest = $weakTest
    $script:countTest = $countTest
    $script:original = [System.IO.File]::ReadAllText($script:modPath)
    $script:cand = [pscustomobject]@{ File = $script:modPath }

    # The scheduler's start/complete pair, driven synchronously. There is deliberately no such
    # function in src/: a serial run is a pool of ONE worker through the real scheduler, and a
    # second composition there would be a second place a verdict is decided -- two places that
    # would disagree in whichever case nobody tests. Here it exists only so one mutant can be
    # examined on its own.
    function Invoke-TestMutant {
        param($Candidate, $MutatedContent, $OriginalContent, $CoveringTests, $TimeoutSeconds)
        $job = Start-PSMutantEvaluation -Candidate $Candidate -Source $Candidate -Index 0 `
            -MutatedContent $MutatedContent -OriginalContent $OriginalContent `
            -CoveringTests $CoveringTests -WorkerId 0 -SandboxRoot $script:proj
        $expired = -not $job.Async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))
        return Complete-PSMutantEvaluation -Job $job -Expired:$expired
    }
}

AfterAll { Remove-Item $script:proj -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'one mutant, evaluated' {
    It 'reports Killed when the mutation breaks a strict test' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-TestMutant -Candidate $script:cand -MutatedContent $mutated -OriginalContent $script:original -CoveringTests @($script:strictTest) -TimeoutSeconds 30 |
            Select-Object -ExpandProperty Status | Should-Be 'Killed'
    }
    It 'reports Survived when a weak test misses the mutation' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-TestMutant -Candidate $script:cand -MutatedContent $mutated -OriginalContent $script:original -CoveringTests @($script:weakTest) -TimeoutSeconds 30 |
            Select-Object -ExpandProperty Status | Should-Be 'Survived'
    }
}

Describe 'a mutant that ends its tests'' discovery (#251)' {
    It 'is a RuntimeError, not a survivor, and the next mutant on the worker still runs' {
        # The tests take their cases from the code AT DISCOVERY. An `exit` reached in a function
        # ends the script that called it -- here the test file, before any test is found -- and
        # Pester calls a run of nothing Passed. (An `exit` at the top of a dot-sourced file ends
        # only that file, so it cannot do this.)
        $code = Join-Path $script:proj 'cases.ps1'
        $original = 'function Get-Case { if ($false) { exit 3 }; 1, 2 }'
        Set-Content $code $original -Encoding utf8
        $disc = Join-Path $script:proj 'cases.Tests.ps1'
        @"
BeforeDiscovery { . '$code'; `$cases = Get-Case }
Describe 'd' { It 'is positive' -ForEach `$cases { `$_ | Should -BeGreaterThan 0 } }
"@ | Set-Content $disc -Encoding utf8
        $cand = [pscustomobject]@{ File = $code }
        Invoke-TestMutant -Candidate $cand -MutatedContent ($original -replace '\$false', '$true') -OriginalContent $original `
            -CoveringTests @($disc) -TimeoutSeconds 30 | Select-Object -ExpandProperty Status | Should-Be 'RuntimeError'
        Invoke-TestMutant -Candidate $cand -MutatedContent ($original -replace '1, 2', '1, -2') -OriginalContent $original `
            -CoveringTests @($disc) -TimeoutSeconds 30 | Select-Object -ExpandProperty Status | Should-Be 'Killed'
    }
}

Describe 'a test that passes only after another is never tried first (#254)' {
    It 'keeps a survivor a survivor, where trusting that test alone would have killed it' {
        # 'needs' reads what 'sets' left behind, so it fails whenever it runs alone. It kills the
        # first mutant in a whole run, is learned, and fails its proof -- so the second mutant, which
        # no test can notice, still runs the whole file and survives. Trusted unproven, 'needs' run
        # alone would have failed on it and scored a kill nothing earned.
        $code = Join-Path $script:proj 'order.ps1'
        $original = "function Get-Twice { param(`$n) return (`$n * 2) }`nfunction Get-Unused { return (1 + 1) }`n"
        Set-Content $code $original -Encoding utf8 -NoNewline
        $test = Join-Path $script:proj 'order.Tests.ps1'
        @"
BeforeAll { . '$code' }
Describe 'd' {
    It 'sets' { `$script:seen = Get-Twice 3 }
    It 'needs' { `$script:seen | Should -Be 6 }
}
"@ | Set-Content $test -Encoding utf8
        $cands = @(
            [pscustomobject]@{ Id = 1; Function = 'Get-Twice'; File = $code; Line = 1; Operator = 'BinaryOperator'; Description = '* -> +'
                StartOffset = $original.IndexOf('*'); EndOffset = $original.IndexOf('*') + 1; Mutated = '+' }
            [pscustomobject]@{ Id = 2; Function = 'Get-Unused'; File = $code; Line = 2; Operator = 'BinaryOperator'; Description = '+ -> -'
                StartOffset = $original.IndexOf('1 + 1') + 2; EndOffset = $original.IndexOf('1 + 1') + 3; Mutated = '-' }
        )
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates $cands `
            -TestsByFile @{ $code = @($test) } -AllTests @($test) -TimeoutSeconds 30 -SandboxRoot $script:proj -Quiet
        @($r | ForEach-Object Status) | Should-BeCollection @('Killed', 'Survived')
        @($r[0].KilledBy) | Should-BeCollection @('needs')
        [System.IO.File]::ReadAllText($code) | Should-Be $original
    }
}

Describe 'one mutant, isolated' {
    It 'restores the original file after evaluating a mutant' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-TestMutant -Candidate $script:cand -MutatedContent $mutated -OriginalContent $script:original -CoveringTests @($script:strictTest) -TimeoutSeconds 30 | Out-Null
        [System.IO.File]::ReadAllText($script:modPath) | Should-Be $script:original
    }
    It 'restores the original file even when the mutant times out' {
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        Invoke-TestMutant -Candidate $script:cand -MutatedContent $infinite -OriginalContent $script:original -CoveringTests @($script:countTest) -TimeoutSeconds 3 | Out-Null
        [System.IO.File]::ReadAllText($script:modPath) | Should-Be $script:original
    }
    It 'never writes the mutant at all when the worker cannot be started' {
        # The reason the shell is obtained BEFORE the file is written. The old shape wrote first
        # and leaned on a `finally` to undo it; this needs no undo, which is the stronger promise
        # -- there is no window in which the mutant is on disk and nothing is scheduled to remove
        # it.
        Close-PSMutationWarmRunspacePool
        Mock Get-PSMutationPesterPath { Join-Path $script:proj 'not-a-real-pester.psd1' }
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        { Start-PSMutantEvaluation -Candidate $script:cand -Source $script:cand -Index 0 `
                -MutatedContent $mutated -OriginalContent $script:original `
                -CoveringTests @($script:strictTest) -WorkerId 0 -SandboxRoot $TestDrive } | Should-Throw
        [System.IO.File]::ReadAllText($script:modPath) | Should-Be $script:original
    }
}

Describe 'Timeout safety (the loop-body hang the loop guard cannot catch)' {
    It 'cuts off a non-terminating mutant and reports TimedOut without hanging' {
        # Mutating the loop BODY increment defeats the guarded `while ($i -lt 3)` loop.
        # This is the ONE place the timeout path is proven against a real runspace rather
        # than a mocked outcome, so it is also where the verdict has to be the honest one:
        # the suite never finished, so it never showed this fault being caught. TimedOut
        # still scores with the kills; it is reported apart from them.
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = (Invoke-TestMutant -Candidate $script:cand -MutatedContent $infinite -OriginalContent $script:original -CoveringTests @($script:countTest) -TimeoutSeconds 3).Status
        $sw.Stop()
        $status | Should-Be 'TimedOut'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20   # bounded, not hung
    }
}

Describe 'the child a worker runs' {
    It 'returns Passed for a passing suite' {
        $job = Start-PSMutantEvaluation -Candidate $script:cand -Source $script:cand -Index 0 `
            -MutatedContent $script:original -OriginalContent $script:original `
            -CoveringTests @($script:strictTest) -WorkerId 0 -SandboxRoot $TestDrive
        $null = $job.Async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds(30))
        (Receive-PSMutationJob -Job $job).Result | Should-Be 'Passed'
    }

    It 'imports the Pester it is handed, not whatever the runspace resolves' {
        # A fresh runspace resolves "Pester" by NAME and gets the newest installed,
        # which need not be the version this process loaded; assemblies are per-process
        # so the mismatch is fatal. Pointing the pin at a module that does not exist
        # proves the runspace really uses the handed-over path -- if it resolved the name
        # itself instead, the run would sail past this and report Passed.
        #
        # The close FIRST is load-bearing now that the runspace is reused: a warm one left
        # by an earlier test already has Pester in it, so the mock would never be consulted
        # and the test would pass without proving anything.
        Close-PSMutationWarmRunspacePool
        Mock Get-PSMutationPesterPath { Join-Path $script:proj 'not-a-real-pester.psd1' }

        { Invoke-TestMutant -Candidate $script:cand -MutatedContent $script:original `
                -OriginalContent $script:original -CoveringTests @($script:strictTest) -TimeoutSeconds 30 } |
            Should-Throw -ExceptionMessage '*not-a-real-pester*'
    }

    It 'fails loudly when the child returns no verdict at all' {
        # What this replaced: a dead child returned $null, the verdict reader took
        # anything-but-Passed as a kill, and a machine with two Pesters scored every
        # mutant Killed -- a silent, entirely fake 100%. A mutant nobody could evaluate
        # has to stop the run, not quietly count as caught.
        Mock Get-PSMutationWarmPesterScript { 'param($tests)' }

        { Invoke-TestMutant -Candidate $script:cand -MutatedContent $script:original `
                -OriginalContent $script:original -CoveringTests @($script:strictTest) -TimeoutSeconds 30 } |
            Should-Throw -ExceptionMessage '*produced no result*'
    }

    It 'reports TimedOut for a non-terminating suite' {
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        (Invoke-TestMutant -Candidate $script:cand -MutatedContent $infinite -OriginalContent $script:original `
                -CoveringTests @($script:countTest) -TimeoutSeconds 3).Status | Should-Be 'TimedOut'
    }
}

Describe 'a suite that IMPORTS the code under test, in a reused runspace (#249)' {
    # `Import-Module` without -Force returns a module already loaded. The worker's runspace serves
    # many mutants, so before the child unloaded the sandbox's modules, the second mutant here was
    # judged against the FIRST mutant's code -- the original, which the test passes -- and
    # survived a change the test plainly catches.
    BeforeAll {
        $script:psm = Join-Path $script:proj "triple-$([System.Guid]::NewGuid().ToString('N')).psm1"
        $script:psmOriginal = 'function Get-Triple { param($n) return ($n * 3) }'
        Set-Content -LiteralPath $script:psm -Value $script:psmOriginal -Encoding utf8
        $script:importTest = Join-Path $script:proj "import-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        "BeforeAll { Import-Module '$($script:psm -replace "'", "''")' }; Describe 'i' { It 'triples' { Get-Triple 2 | Should -Be 6 } }" |
            Set-Content -LiteralPath $script:importTest -Encoding utf8
        $script:psmCand = [pscustomobject]@{ File = $script:psm }
    }
    AfterAll { Close-PSMutationWarmRunspacePool }

    It 'judges the second mutant on a warm worker by ITS OWN code' {
        Close-PSMutationWarmRunspacePool
        $first = Invoke-TestMutant -Candidate $script:psmCand -MutatedContent $script:psmOriginal `
            -OriginalContent $script:psmOriginal -CoveringTests @($script:importTest) -TimeoutSeconds 60
        $first.Status | Should-Be 'Survived'
        $second = Invoke-TestMutant -Candidate $script:psmCand -MutatedContent ($script:psmOriginal -replace '\* 3', '* 4') `
            -OriginalContent $script:psmOriginal -CoveringTests @($script:importTest) -TimeoutSeconds 60
        # The same warm runspace both times -- otherwise this proves nothing about reuse.
        $script:PSMutationWarmUses[0] | Should-Be 2
        $second.Status | Should-Be 'Killed'
    }
}
