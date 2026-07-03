# Direct tests for the per-mutant execution: kill/survive classification, the
# isolation/restore guarantee, and -- crucially -- that a runaway (non-terminating)
# mutant is cut off by the timeout and counted Killed instead of hanging the run.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Runner.ps1') { . (Join-Path $src $f) }

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
}

AfterAll { Remove-Item $script:proj -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-PSMutant classification' {
    It 'reports Killed when the mutation breaks a strict test' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-PSMutant -Candidate $script:cand -MutatedContent $mutated -CoveringTests @($script:strictTest) -TimeoutSeconds 30 |
            Should -Be 'Killed'
    }
    It 'reports Survived when a weak test misses the mutation' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-PSMutant -Candidate $script:cand -MutatedContent $mutated -CoveringTests @($script:weakTest) -TimeoutSeconds 30 |
            Should -Be 'Survived'
    }
}

Describe 'Invoke-PSMutant isolation' {
    It 'restores the original file after evaluating a mutant' {
        $mutated = $script:original -replace '\$n \* 2', '$n + 2'
        Invoke-PSMutant -Candidate $script:cand -MutatedContent $mutated -CoveringTests @($script:strictTest) -TimeoutSeconds 30 | Out-Null
        [System.IO.File]::ReadAllText($script:modPath) | Should -Be $script:original
    }
    It 'restores the original file even when the mutant times out' {
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        Invoke-PSMutant -Candidate $script:cand -MutatedContent $infinite -CoveringTests @($script:countTest) -TimeoutSeconds 3 | Out-Null
        [System.IO.File]::ReadAllText($script:modPath) | Should -Be $script:original
    }
}

Describe 'Timeout safety (the loop-body hang the loop guard cannot catch)' {
    It 'cuts off a non-terminating mutant and reports Killed without hanging' {
        # Mutating the loop BODY increment defeats the guarded `while ($i -lt 3)` loop.
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = Invoke-PSMutant -Candidate $script:cand -MutatedContent $infinite -CoveringTests @($script:countTest) -TimeoutSeconds 3
        $sw.Stop()
        $status | Should -Be 'Killed'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20   # bounded, not hung
    }
}

Describe 'Invoke-PSBoundedPester' {
    It 'returns Passed for a passing suite' {
        Invoke-PSBoundedPester -CoveringTests @($script:strictTest) -TimeoutSeconds 30 | Should -Be 'Passed'
    }
    It 'returns TimedOut for a non-terminating suite' {
        $infinite = $script:original -replace '\$i = \$i \+ 1', '$i = $i - 1'
        [System.IO.File]::WriteAllText($script:modPath, $infinite)
        try {
            Invoke-PSBoundedPester -CoveringTests @($script:countTest) -TimeoutSeconds 3 | Should -Be 'TimedOut'
        }
        finally { [System.IO.File]::WriteAllText($script:modPath, $script:original) }
    }
}
