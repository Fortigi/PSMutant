# End-to-end: run the public Invoke-PSMutation against a tiny throwaway fixture project
# (one function + a covering test + a config) and assert the summary, the JSON report,
# and -- the headline guarantee -- that the tracked source is byte-identical afterwards.

BeforeAll {
    $module = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSMutant.psd1'
    Import-Module $module -Force

    $script:proj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-e2e-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:proj 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:proj 'tests') -Force | Out-Null

    # Get-Sign is asserted properly, so its mutants die. Test-Flag is deliberately
    # under-asserted -- the test only checks the call does not blow up -- so it
    # leaves survivors. Without at least one survivor the -RecheckFrom tests below
    # would run against an empty set and pass without exercising anything.
    $script:srcFile = Join-Path $script:proj 'src/calc.ps1'
    @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
function Test-Flag { param($x) if ($x) { return $true } else { return $false } }
'@ | Set-Content $script:srcFile -Encoding utf8

    @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos for positive' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg for non-positive' { Get-Sign -5 | Should -Be 'neg' }
}
Describe 'Test-Flag' {
    It 'returns something for a truthy input' { { Test-Flag $true } | Should -Not -Throw }
}
'@ | Set-Content (Join-Path $script:proj 'tests/calc.Tests.ps1') -Encoding utf8

    $cfg = [ordered]@{
        sandboxSubtrees  = @('src', 'tests')
        mutate           = @('src/calc.ps1')
        tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
        coveredLinesOnly = $true
        operators        = @('BinaryOperator', 'BooleanLiteral')
        thresholds       = @{ high = 85; low = 70; break = $null }
        reportPath       = 'reports/e2e.json'
    }
    $script:configFile = Join-Path $script:proj 'mutation.config.json'
    $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8

    $script:originalSrc = [System.IO.File]::ReadAllText($script:srcFile)
    $script:result = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -Quiet
}

AfterAll { Remove-Item $script:proj -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-PSMutation end-to-end' {
    It 'evaluates at least one mutant' {
        $script:result.Total | Should -BeGreaterThan 0
    }
    It 'kills mutants that the covering test catches (score > 0)' {
        $script:result.Killed | Should -BeGreaterThan 0
        $script:result.Score | Should -BeGreaterThan 0
    }
    It 'returns a consistent summary' {
        ($script:result.Killed + $script:result.Survived) | Should -Be $script:result.Total
        $script:result.ExitCode | Should -Be 0   # thresholds.break is null -> report-only
    }
    It 'writes the JSON report' {
        $report = Join-Path $script:proj 'reports/e2e.json'
        Test-Path $report | Should -BeTrue
        (Get-Content $report -Raw | ConvertFrom-Json).mutationScore | Should -Be $script:result.Score
    }
    It 'leaves the tracked source byte-identical' {
        [System.IO.File]::ReadAllText($script:srcFile) | Should -Be $script:originalSrc
    }
    It 'leaves no sandbox temp directory behind' {
        (Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter "psmut-sandbox-$PID" -ErrorAction SilentlyContinue) |
            Should -BeNullOrEmpty
    }

    It 'records source hashes and operators for a later recheck' {
        $json = Get-Content (Join-Path $script:proj 'reports/e2e.json') -Raw | ConvertFrom-Json
        $json.sourceHashes.'src/calc.ps1' | Should -Match '^[0-9a-f]{64}$'
        $json.operators | Should -Be @('BinaryOperator', 'BooleanLiteral')
    }
}

Describe 'Invoke-PSMutation -RecheckFrom end-to-end' {
    BeforeAll {
        $script:fullReport = Join-Path $script:proj 'reports/e2e.json'
        $script:priorSurvivors = @((Get-Content $script:fullReport -Raw | ConvertFrom-Json).survivors).Count
        $script:fullBytes = [System.IO.File]::ReadAllText($script:fullReport)
        $script:recheck = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $script:fullReport -Quiet
    }

    It 'evaluates only the mutants the full run left surviving' {
        # The point of the feature: fewer mutants than the full run, and exactly the
        # ones that were still alive. The survivor count must be non-zero, or this
        # assertion would hold vacuously against an empty set.
        $script:priorSurvivors    | Should -BeGreaterThan 0
        $script:recheck.Mode      | Should -Be 'Recheck'
        $script:recheck.Rechecked | Should -Be $script:priorSurvivors
        $script:recheck.Rechecked | Should -BeLessThan $script:result.Total
    }

    It 'reports counts and no score' {
        # A filtered run has no denominator worth quoting, so the object must not
        # carry one -- otherwise it gets read as the file's score.
        ($script:recheck.NowKilled + $script:recheck.StillSurviving) | Should -Be $script:recheck.Rechecked
        $script:recheck.PSObject.Properties.Name | Should -Not -Contain 'Score'
    }

    It 'writes its own report and leaves the full one untouched' {
        # A partial run overwriting the baseline would destroy the survivor list it
        # was derived from, and hand CI a truncated number.
        Test-Path (Join-Path $script:proj 'reports/e2e.recheck.json') | Should -BeTrue
        [System.IO.File]::ReadAllText($script:fullReport) | Should -Be $script:fullBytes
    }

    It 'refuses when the source changed since the report' {
        # Ids are AST-walk positions. Editing the file makes them point at other
        # mutants, so the honest answer is to refuse, not to recheck something else.
        $backup = [System.IO.File]::ReadAllText($script:srcFile)
        try {
            Add-Content -Path $script:srcFile -Value 'function Get-Extra { param($n) if ($n -gt 1) { 1 } else { 2 } }'
            { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $script:fullReport -Quiet } |
                Should -Throw '*changed since the report*'
        }
        finally { [System.IO.File]::WriteAllText($script:srcFile, $backup) }
    }

    It 'refuses when the operator set changed since the report' {
        $cfg = Get-Content $script:configFile -Raw | ConvertFrom-Json
        $cfg.operators = @('BinaryOperator')          # narrower than the report's two
        $alt = Join-Path $script:proj 'mutation.altops.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $alt -Encoding utf8
        { Invoke-PSMutation -ConfigFile $alt -SourceRoot $script:proj -RecheckFrom $script:fullReport -Quiet } |
            Should -Throw '*operator set changed*'
    }

    It 'refuses a report that predates source-hash recording' {
        # Old reports carry no hashes, so nothing can be verified. Rechecking them
        # "optimistically" is exactly the confident-wrong-answer case.
        $legacy = Get-Content $script:fullReport -Raw | ConvertFrom-Json
        $legacy.PSObject.Properties.Remove('sourceHashes')
        $legacyPath = Join-Path $script:proj 'reports/legacy.json'
        $legacy | ConvertTo-Json -Depth 6 | Set-Content $legacyPath -Encoding utf8
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $legacyPath -Quiet } |
            Should -Throw '*predates source-hash recording*'
    }
}

Describe 'Assert-PSMutationPester' {
    BeforeAll {
        # Dot-sourced rather than reached through the module, so Get-Module can be
        # mocked in this scope without stubbing out the module's own loading.
        . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src' -AdditionalChildPath 'Invoke-PSMutation.ps1')
    }

    It 'refuses to run without Pester 5' {
        # Pester 4 has no code coverage API and a different Should surface, so the
        # run would fail deep inside the baseline with an unrelated error.
        Mock Get-Module { @() } -ParameterFilter { $ListAvailable }
        { Assert-PSMutationPester } | Should -Throw '*Pester 5+ is required*'
    }

    It 'accepts a Pester 5 installation' {
        Mock Get-Module { @([pscustomobject]@{ Name = 'Pester'; Version = [version]'5.8.0' }) } -ParameterFilter { $ListAvailable }
        Mock Import-Module { }
        { Assert-PSMutationPester } | Should -Not -Throw
    }
}

Describe 'Invoke-PSMutation - config defaults and failure modes' {
    It 'falls back to the default operators and timeouts when the config omits them' {
        $cfg = [ordered]@{
            sandboxSubtrees = @('src', 'tests')
            mutate          = @('src/calc.ps1')
            tests           = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
            reportPath      = 'reports/defaults.json'
        }
        $p = Join-Path $script:proj 'mutation.defaults.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
        $r = Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet
        $r.Total | Should -BeGreaterThan 0
        # The default set excludes StringLiteral; if that changed, a mutate run on a
        # string-heavy file would silently start scoring something else.
        (Get-Content (Join-Path $script:proj 'reports/defaults.json') -Raw | ConvertFrom-Json).operators |
            Should -Not -Contain 'StringLiteral'
    }

    It 'refuses to mutate when the baseline suite is already failing' {
        # Mutation scores are meaningless against a red suite: every mutant would be
        # "killed" by the pre-existing failure.
        $bad = Join-Path $script:proj 'tests/failing.Tests.ps1'
        @'
Describe 'already broken' { It 'fails' { $true | Should -BeFalse } }
'@ | Set-Content $bad -Encoding utf8
        try {
            $cfg = [ordered]@{
                sandboxSubtrees = @('src', 'tests')
                mutate          = @('src/calc.ps1')
                tests           = @{ 'src/calc.ps1' = @('tests/failing.Tests.ps1') }
                reportPath      = 'reports/red.json'
            }
            $p = Join-Path $script:proj 'mutation.red.json'
            $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
            { Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet } |
                Should -Throw '*Baseline suite is not green*'
        }
        finally { Remove-Item $bad -Force -ErrorAction SilentlyContinue }
    }

    It 'prints its progress and summary when not run with -Quiet' {
        # -Quiet is what every other test here uses, so without this the entire
        # console layer -- per-mutant progress and the closing summary -- ships
        # unexercised, and it is the only output a human actually sees.
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj } 6>&1 |
            Out-String
        $out | Should -BeLike '*PSMutant*'
        $out | Should -BeLike '*Baseline green*'
        $out | Should -BeLike '*Mutants to evaluate*'
        $out | Should -BeLike '*Mutation score*'
    }

    It 'prints the recheck summary when not run with -Quiet' {
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj `
                    -RecheckFrom (Join-Path $script:proj 'reports/e2e.json') } 6>&1 | Out-String
        $out | Should -BeLike '*Rechecking*previous survivor*'
        $out | Should -BeLike '*Not a mutation score*'
    }

    It 'defaults SourceRoot to the current directory' {
        Push-Location $script:proj
        try {
            $r = Invoke-PSMutation -ConfigFile $script:configFile -Quiet
            $r.Total | Should -BeGreaterThan 0
        }
        finally { Pop-Location }
    }

    It 'honours an explicit timeoutFactor and timeoutFloorSeconds' {
        $cfg = [ordered]@{
            sandboxSubtrees     = @('src', 'tests')
            mutate              = @('src/calc.ps1')
            tests               = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
            operators           = @('BinaryOperator')
            timeoutFactor       = 6
            timeoutFloorSeconds = 30
            reportPath          = 'reports/timeouts.json'
        }
        $p = Join-Path $script:proj 'mutation.timeouts.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
        (Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet).Total | Should -BeGreaterThan 0
    }

    It 'uses the default sandbox subtrees when the config omits them' {
        # The documented default is src + tests. A project laid out that way must
        # work with no sandboxSubtrees key at all, or the default is decoration.
        $cfg = [ordered]@{
            mutate     = @('src/calc.ps1')
            tests      = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
            operators  = @('BinaryOperator')
            reportPath = 'reports/defaultsubtrees.json'
        }
        $p = Join-Path $script:proj 'mutation.subtrees.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
        (Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet).Total | Should -BeGreaterThan 0
    }

    It 'fails the run when the score is below thresholds.break' {
        # A test that asserts nothing about the function leaves every mutant alive,
        # which is the case the gate exists for.
        $lax = Join-Path $script:proj 'tests/lax.Tests.ps1'
        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign (asserts nothing useful)' {
    It 'returns something' { Get-Sign 5 | Should -Not -BeNullOrEmpty }
}
'@ | Set-Content $lax -Encoding utf8
        try {
            $cfg = [ordered]@{
                sandboxSubtrees = @('src', 'tests')
                mutate          = @('src/calc.ps1')
                tests           = @{ 'src/calc.ps1' = @('tests/lax.Tests.ps1') }
                operators       = @('BinaryOperator')
                thresholds      = @{ high = 85; low = 70; break = 50 }
                reportPath      = 'reports/break.json'
            }
            $p = Join-Path $script:proj 'mutation.break.json'
            $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
            $r = Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet
            $r.Score    | Should -BeLessThan 50
            $r.ExitCode | Should -Be 1
        }
        finally { Remove-Item $lax -Force -ErrorAction SilentlyContinue }
    }
}
