# Direct tests for the per-mutant execution: kill/survive classification, the
# isolation/restore guarantee, and -- crucially -- that a runaway (non-terminating)
# mutant is cut off by the timeout and counted Killed instead of hanging the run.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Pester.ps1',
        'PSMutation.Runner.ps1') { . (Join-Path $src $f) }

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
            -CoveringTests $CoveringTests -WorkerId 0
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
                -CoveringTests @($script:strictTest) -WorkerId 0 } | Should-Throw
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
            -CoveringTests @($script:strictTest) -WorkerId 0
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
