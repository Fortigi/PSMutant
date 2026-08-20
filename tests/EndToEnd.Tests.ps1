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
        $script:result.Total | Should-BeGreaterThan 0
    }
    It 'kills mutants that the covering test catches (score > 0)' {
        $script:result.Killed | Should-BeGreaterThan 0
        $script:result.Score | Should-BeGreaterThan 0
    }
    It 'returns a consistent summary' {
        ($script:result.Killed + $script:result.Survived) | Should-Be $script:result.Total
        $script:result.ExitCode | Should-Be 0   # thresholds.break is null -> report-only
    }
    It 'writes the JSON report' {
        $report = Join-Path $script:proj 'reports/e2e.json'
        Test-Path $report | Should-BeTrue
        (Get-Content $report -Raw | ConvertFrom-Json).mutationScore | Should-Be $script:result.Score
    }
    It 'leaves the tracked source byte-identical' {
        [System.IO.File]::ReadAllText($script:srcFile) | Should-Be $script:originalSrc
    }
    It 'leaves no sandbox temp directory behind' {
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter "psmut-sandbox-$PID" -ErrorAction SilentlyContinue).Count |
            Should-Be 0
    }

    It 'records source hashes and operators for a later recheck' {
        $json = Get-Content (Join-Path $script:proj 'reports/e2e.json') -Raw | ConvertFrom-Json
        $json.sourceHashes.'src/calc.ps1' | Should-MatchString '^[0-9a-f]{64}$'
        $json.operators | Should-BeCollection @('BinaryOperator', 'BooleanLiteral')
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
        $script:priorSurvivors    | Should-BeGreaterThan 0
        $script:recheck.Mode      | Should-Be 'Recheck'
        $script:recheck.Rechecked | Should-Be $script:priorSurvivors
        $script:recheck.Rechecked | Should-BeLessThan $script:result.Total
    }

    It 'reports counts and no score' {
        # A filtered run has no denominator worth quoting, so the object must not
        # carry one -- otherwise it gets read as the file's score.
        ($script:recheck.NowKilled + $script:recheck.StillSurviving) | Should-Be $script:recheck.Rechecked
        $script:recheck.PSObject.Properties.Name | Should-NotContainCollection 'Score'
    }

    It 'writes its own report and leaves the full one untouched' {
        # A partial run overwriting the baseline would destroy the survivor list it
        # was derived from, and hand CI a truncated number.
        Test-Path (Join-Path $script:proj 'reports/e2e.recheck.json') | Should-BeTrue
        [System.IO.File]::ReadAllText($script:fullReport) | Should-Be $script:fullBytes
    }

    It 'refuses when the source changed since the report' {
        # Ids are AST-walk positions. Editing the file makes them point at other
        # mutants, so the honest answer is to refuse, not to recheck something else.
        $backup = [System.IO.File]::ReadAllText($script:srcFile)
        try {
            Add-Content -Path $script:srcFile -Value 'function Get-Extra { param($n) if ($n -gt 1) { 1 } else { 2 } }'
            { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $script:fullReport -Quiet } |
                Should-Throw -ExceptionMessage '*changed since the report*'
        }
        finally { [System.IO.File]::WriteAllText($script:srcFile, $backup) }
    }

    It 'refuses when the operator set changed since the report' {
        $cfg = Get-Content $script:configFile -Raw | ConvertFrom-Json
        $cfg.operators = @('BinaryOperator')          # narrower than the report's two
        $alt = Join-Path $script:proj 'mutation.altops.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $alt -Encoding utf8
        { Invoke-PSMutation -ConfigFile $alt -SourceRoot $script:proj -RecheckFrom $script:fullReport -Quiet } |
            Should-Throw -ExceptionMessage '*operator set changed*'
    }

    It 'refuses a report that predates source-hash recording' {
        # Old reports carry no hashes, so nothing can be verified. Rechecking them
        # "optimistically" is exactly the confident-wrong-answer case.
        $legacy = Get-Content $script:fullReport -Raw | ConvertFrom-Json
        $legacy.PSObject.Properties.Remove('sourceHashes')
        $legacyPath = Join-Path $script:proj 'reports/legacy.json'
        $legacy | ConvertTo-Json -Depth 6 | Set-Content $legacyPath -Encoding utf8
        { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $legacyPath -Quiet } |
            Should-Throw -ExceptionMessage '*predates source-hash recording*'
    }
}

Describe 'the recheck loop narrows' {
    # THE test for #20, and the reason it is end-to-end rather than a unit: the failure it
    # guards is a recheck report the gate ACCEPTS and selection then finds nothing in. That
    # prints "0 of 0 previous survivor(s) now killed" -- a confident "you are done" -- while
    # every unit in isolation looks correct.
    BeforeAll {
        $script:chainTests = Join-Path $script:proj 'tests/calc.Tests.ps1'
        $script:chainBackup = [System.IO.File]::ReadAllText($script:chainTests)

        # An ADDED assertion, which is the only change a recheck is sound for. It kills the
        # $true -> $false mutant in Test-Flag, which the deliberately under-asserted fixture
        # leaves alive. Without a round that actually kills something, "the next round runs
        # fewer" is untestable.
        Add-Content -Path $script:chainTests -Value @'
Describe 'Test-Flag (added mid-loop)' {
    It 'is true for a truthy input' { Test-Flag $true | Should -Be $true }
}
'@
        $script:chainFirst = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj `
            -RecheckFrom (Join-Path $script:proj 'reports/e2e.json') -Quiet
        $script:chainPath = Join-Path $script:proj 'reports/e2e.recheck.json'
        $script:chainSecond = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj `
            -RecheckFrom $script:chainPath -Quiet
    }

    AfterAll { [System.IO.File]::WriteAllText($script:chainTests, $script:chainBackup) }

    It 'kills something in the first round, or the rest of this block proves nothing' {
        $script:chainFirst.NowKilled | Should-BeGreaterThan 0
    }

    It 'lets a recheck report seed another recheck' {
        $script:chainSecond.Mode | Should-Be 'Recheck'
    }

    It 'evaluates only what the previous round left alive' {
        # The narrowing property: five survivors, kill two, next round runs three. Without
        # it the second round re-runs what the first already killed, and the waste compounds
        # exactly as you approach done.
        $script:chainSecond.Rechecked | Should-Be $script:chainFirst.StillSurviving
        $script:chainSecond.Rechecked | Should-BeLessThan $script:chainFirst.Rechecked
    }

    It 'carries the provenance a further round needs to validate against' {
        # The gate checks sourceHashes and operators. A recheck report that dropped them
        # could never seed anything, which is what made the loop one step long.
        $first = Get-Content $script:chainPath -Raw | ConvertFrom-Json
        $first.sourceHashes | Should-NotBeNull
        @($first.operators).Count | Should-BeGreaterThan 0
    }

    It 'overwrites its own report rather than growing a suffix each round' {
        # Chaining used to imply report.recheck.recheck.json, then another. The full report
        # is the one that must never be clobbered, and that is asserted above.
        Test-Path (Join-Path $script:proj 'reports/e2e.recheck.recheck.json') | Should-BeFalse
    }

    It 'still refuses a chained report when the source has changed' {
        # The guarantee has to survive chaining: a second-round report is validated exactly
        # as a first-round one, against the hashes it carried forward.
        $backup = [System.IO.File]::ReadAllText($script:srcFile)
        try {
            Add-Content -Path $script:srcFile -Value 'function Get-Later { param($n) if ($n -gt 3) { 4 } else { 5 } }'
            { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -RecheckFrom $script:chainPath -Quiet } |
                Should-Throw -ExceptionMessage '*changed since the report*'
        }
        finally { [System.IO.File]::WriteAllText($script:srcFile, $backup) }
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
        $r.Total | Should-BeGreaterThan 0
        # The default set excludes StringLiteral; if that changed, a mutate run on a
        # string-heavy file would silently start scoring something else.
        (Get-Content (Join-Path $script:proj 'reports/defaults.json') -Raw | ConvertFrom-Json).operators |
            Should-NotContainCollection 'StringLiteral'
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
                Should-Throw -ExceptionMessage '*Baseline suite is not green*'
        }
        finally { Remove-Item $bad -Force -ErrorAction SilentlyContinue }
    }

    It 'prints its progress and summary when not run with -Quiet' {
        # -Quiet is what every other test here uses, so without this the entire
        # console layer -- per-mutant progress and the closing summary -- ships
        # unexercised, and it is the only output a human actually sees.
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj } 6>&1 |
            Out-String
        $out | Should-BeLikeString '*PSMutant*'
        $out | Should-BeLikeString '*Baseline green*'
        $out | Should-BeLikeString '*Mutants to evaluate*'
        $out | Should-BeLikeString '*Mutation score*'
    }

    It 'prints the recheck summary when not run with -Quiet' {
        $out = & { Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj `
                    -RecheckFrom (Join-Path $script:proj 'reports/e2e.json') } 6>&1 | Out-String
        $out | Should-BeLikeString '*Rechecking*previous survivor*'
        $out | Should-BeLikeString '*Not a mutation score*'
    }

    It 'defaults SourceRoot to the current directory' {
        Push-Location $script:proj
        try {
            $r = Invoke-PSMutation -ConfigFile $script:configFile -Quiet
            $r.Total | Should-BeGreaterThan 0
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
        (Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet).Total | Should-BeGreaterThan 0
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
        (Invoke-PSMutation -ConfigFile $p -SourceRoot $script:proj -Quiet).Total | Should-BeGreaterThan 0
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
            $r.Score    | Should-BeLessThan 50
            $r.ExitCode | Should-Be 1
        }
        finally { Remove-Item $lax -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the config files this repo ships' {
    # Lives here, not in Config.Tests.ps1: this reads files from the repo ROOT, and the
    # self-mutation sandbox copies only src/ and tests/. A covering suite that reaches
    # outside them fails in the sandbox and takes the whole baseline red -- which is
    # exactly what happened when this check was written there first.
    BeforeAll {
        # Dot-sourced, not taken from the imported module: the validator is internal and
        # FunctionsToExport does not list it.
        $srcDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
        . (Join-Path -Path $srcDir -ChildPath 'PSMutation.Operators.ps1')
        . (Join-Path -Path $srcDir -ChildPath 'PSMutation.Config.ps1')
    }

    It 'validates <Name>' -ForEach @(
        @{ Name = 'psmutant.self.config.json' }
        @{ Name = 'examples/psmutant.config.json' }
    ) {
        # A shipped config that the validator rejects would be a broken example and a
        # broken gate on the same day #24 landed.
        $path = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath $Name
        Assert-PSMutationConfig -Cfg (Get-Content $path -Raw | ConvertFrom-Json)
    }
}

Describe 'the manifest does not choose a Pester' {
    BeforeAll {
        $script:manifestPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSMutant.psd1'
    }

    It 'declares no Pester dependency in RequiredModules' {
        # ModuleVersion in RequiredModules is a MINIMUM, and PowerShell satisfies it by
        # importing the NEWEST installed version -- at import time, before
        # Assert-PSMutationPester or Get-PSMutationPesterPath can have a say. Pester is a
        # run-time dependency here, and the guard is the single place that enforces it.
        $required = @((Import-PowerShellDataFile $script:manifestPath).RequiredModules)
        @($required | Where-Object { $_ }) | Should-BeCollection -Count 0
    }

    It 'still names the requirement in its description, so removing it did not hide it' {
        # Pairs with the assertion above. Dropping the declaration is only correct if the
        # dependency stays discoverable -- otherwise this trades a wrong import for a
        # silent one.
        (Import-PowerShellDataFile $script:manifestPath).Description |
            Should-BeLikeString '*Pester 5.0.0 or later*'
    }

    It 'loads no Pester at all when imported into a clean session' {
        # THE behavioural proof, and the reason this runs in a child process: Pester is
        # running this suite, so in-process the module always looks innocent. Before the
        # fix a clean session went from no Pester to 6.1.0 purely by importing PSMutant.
        $loaded = pwsh -NoProfile -Command "
            Import-Module '$script:manifestPath' -Force
            @(Get-Module Pester).Count"
        [int]($loaded | Select-Object -Last 1) | Should-Be 0
    }
}

Describe 'the module public surface' {
    BeforeAll {
        $script:root = Split-Path -Parent $PSScriptRoot
        $script:manifest = Join-Path -Path $script:root -ChildPath 'PSMutant.psd1'
    }

    It 'exports exactly one function' {
        # Get-PSMutationCandidate and Set-PSMutationText used to be exported, and between
        # them trafficked a nine-field object nothing declared, tested or versioned (#48).
        # Neither appeared in the README. This is the assertion that makes re-exporting
        # something a decision rather than a reflex.
        (Import-PowerShellDataFile $script:manifest).FunctionsToExport |
            Should-BeCollection @('Invoke-PSMutation')
    }

    It 'exports nothing the manifest does not declare' {
        # The manifest filters Export-ModuleMember, so a name in one and not the other is
        # exported by neither -- which reads as a bug in whichever file you happen to open.
        # Checked against a real import rather than by parsing psm1.
        Import-Module $script:manifest -Force
        try {
            (Get-Command -Module PSMutant).Name |
                Should-BeCollection (Import-PowerShellDataFile $script:manifest).FunctionsToExport
        }
        finally { Remove-Module PSMutant -Force -ErrorAction SilentlyContinue }
    }
}
