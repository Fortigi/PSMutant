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
            Should-Throw -ExceptionMessage '*no source hashes*'
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

    It 'stamps a recheck report with the same provenance block as a full report' {
        # Both shapes carry it, so a consumer reads provenance one way rather than learning
        # two conventions (#34). Asserted on a REAL recheck report, because the block is
        # threaded through a different call path than the full report's and wiring it in one
        # place and not the other is invisible until someone reads the artifact.
        $first = Get-Content $script:chainPath -Raw | ConvertFrom-Json
        $first.schemaVersion          | Should-Be 1
        $first.producedBy.module      | Should-Be 'PSMutant'
        $first.producedBy.version     | Should-NotBeEmptyString
        $first.durations.totalSeconds | Should-BeGreaterThan 0
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

Describe 'the help a user actually gets' {
    # These read Get-Help rather than the source, because the source being correct is not
    # the same as the help resolving to it. A file-level <# #> block sitting immediately
    # before the `function` keyword is treated as that function's comment-based help and
    # SHADOWS the block inside the body -- so Get-Help served this module's internal
    # architecture notes, with no examples, while the real documentation sat unreachable a
    # few lines below. Nothing in the source looked wrong.
    BeforeAll {
        Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSMutant.psd1') -Force
        $script:help = Get-Help Invoke-PSMutation -Full
    }

    It 'describes what the command does, not what the file is' {
        # The shadowed synopsis was "Public entry point for PSMutant", which tells a user
        # nothing they can act on.
        $script:help.Synopsis | Should-BeLikeString '*mutation testing*'
        $script:help.Synopsis | Should-NotBeLikeString '*entry point*'
    }

    It 'documents every parameter it accepts' {
        # Get-Help synthesises an entry for every parameter whether or not it is written
        # up, so this compares against the real signature: a parameter with no prose is
        # indistinguishable here from one with prose, which is why the description check
        # below exists too.
        $documented = @($script:help.parameters.parameter).Name
        $actual = @((Get-Command Invoke-PSMutation).Parameters.Keys |
            Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
        $documented | Should-BeCollection $actual
    }

    It 'gives every parameter a description rather than just a name' {
        # -Quiet had none: it appeared in Get-Help because PowerShell lists parameters
        # automatically, so its absence from the written help was invisible.
        foreach ($p in @($script:help.parameters.parameter)) {
            ($p.description.Text -join '') | Should-NotBeEmptyString -Because "-$($p.name) needs prose"
        }
    }

    It 'carries examples with runnable code' {
        # The shadowed help reported one example whose title and code were both empty.
        # Counting examples is not enough -- an empty one still counts.
        $examples = @($script:help.examples.example)
        $examples.Count | Should-BeGreaterThan 3
        foreach ($e in $examples) {
            ($e.code -join '') | Should-BeLikeString '*Invoke-PSMutation*'
        }
    }

    It 'shows the recheck loop, which is the least obvious thing to discover' {
        # A recheck report seeding another recheck is the feature nobody guesses at.
        (@($script:help.examples.example).code -join "`n") | Should-BeLikeString '*.recheck.json*'
    }
}


Describe 'the published report schema' {
    # schemas/report.schema.json is shipped with the module so a consumer can validate a
    # report without reading this repo's tests. That only means anything if the reports we
    # actually emit satisfy it, which is what this Describe is for -- a schema that has
    # drifted from the writer is worse than none, because it invites a consumer to code
    # against a shape they will not receive.
    #
    # Validated as TEXT, not as a parsed object. ConvertFrom-Json recognises the ISO-8601
    # generatedAt and hands back a [datetime], so a round-tripped object no longer has the
    # string the schema describes. The file is the contract.
    BeforeAll {
        $script:schema = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/report.schema.json') -Raw
        $script:fullText = [System.IO.File]::ReadAllText((Join-Path $script:proj 'reports/e2e.json'))
        $script:recheckText = [System.IO.File]::ReadAllText((Join-Path $script:proj 'reports/e2e.recheck.json'))

        function Test-AgainstSchema { param([string]$Json)
            try { Test-Json -Json $Json -Schema $script:schema -ErrorAction Stop | Out-Null; return $true }
            catch { return $false }
        }
    }

    It 'accepts the full report a real run just wrote' {
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:fullText)
    }

    It 'accepts the recheck report a real run just wrote' {
        # Both shapes, because the recheck report travels a different call path -- wiring a
        # field into one writer and not the other is invisible until someone opens the file.
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:recheckText)
    }

    It 'refuses a recheck report that carries a mutation score' {
        # The safety property, and the reason this schema is worth shipping rather than
        # merely writing down. A recheck measures a subset, so a score in one is a partial
        # number wearing a real one's name -- the failure this whole project exists to
        # prevent. Making it unrepresentable in the format is stronger than a caveat.
        $tampered = $script:recheckText -replace '("mode"\s*:\s*"Recheck")', '$1, "mutationScore": 100'
        # Asserted first, because a -replace that silently matched nothing would leave the
        # document untouched and this test would pass while proving nothing about the schema.
        $tampered | Should-NotBe $script:recheckText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $tampered)
    }

    It 'still accepts a report carrying a field it has never seen' {
        # The additive promise, in the other direction: schemaVersion changes when a field
        # changes meaning or disappears, NEVER when one is added. So the schema must permit
        # extra properties, or every consumer validating against it breaks on the next
        # release that records one more thing.
        $widened = $script:fullText -replace '("generatedFrom"\s*:\s*"PSMutant")', '$1, "somethingAddedLater": 42'
        $widened | Should-NotBe $script:fullText
        Should-BeTrue -Actual (Test-AgainstSchema -Json $widened)
    }
}


Describe 'the published config schema' {
    # schemas/config.schema.json is the definition of the config format -- the document
    # every consumer configures PSMutant against. Assert-PSMutationConfig enforces the same
    # format at run time.
    #
    # Two enforcements of one format is a standing invitation to drift, and a schema that
    # disagrees with the code is worse than no schema: it green-lights a config the module
    # will refuse, or flags one it would have accepted. So the agreement is asserted rather
    # than maintained by hand -- the keys, the threshold keys, the operator vocabulary and
    # the types all come from the code, never from a list written out again here.
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'src/PSMutation.Operators.ps1')
        . (Join-Path $root 'src/PSMutation.Config.ps1')
        $script:cfgSchemaText = Get-Content (Join-Path $root 'schemas/config.schema.json') -Raw
        $script:cfgSchema = $script:cfgSchemaText | ConvertFrom-Json
        $script:repoRoot = $root
    }

    It 'is where the validator gets its key list, rather than a second copy of it' {
        # Not a comparison of two lists -- there is only one. Get-PSMutationConfigKey reads
        # the schema, so this asserts the derivation happens at all: a hard-coded list that
        # happened to match would pass a comparison and then rot the moment a key is added.
        $fromCode = @(Get-PSMutationConfigKey | Sort-Object)
        $fromSchema = @($script:cfgSchema.properties.PSObject.Properties.Name | Sort-Object)
        ($fromCode -join ',') | Should-Be ($fromSchema -join ',')
        # And it is not empty, which a broken path would silently produce -- an empty known
        # list makes EVERY key unknown, or every key fine, depending which way it fails.
        $fromCode.Count | Should-BeGreaterThan 5
    }

    It 'is where the threshold key list comes from too' {
        $fromCode = @(Get-PSMutationConfigKey -Section 'thresholds' | Sort-Object)
        ($fromCode -join ',') | Should-Be 'break,high,low'
    }

    It 'offers exactly the operators the module implements' {
        # The drift that would hurt most: the schema blessing an operator name the module
        # then refuses, or omitting one that works. The operator map is the single source,
        # so the enum is checked against it rather than against a written list.
        $inSchema = @($script:cfgSchema.properties.operators.items.enum | Sort-Object)
        ($inSchema -join ',') | Should-Be ((Get-PSMutationKnownOperator) -join ',')
    }

    It 'requires what the validator requires and nothing more' {
        # mutate and tests are the two the validator refuses a config for lacking.
        (@($script:cfgSchema.required | Sort-Object) -join ',') | Should-Be 'mutate,tests'
    }

    It 'accepts the configs this repo actually ships' -ForEach @(
        @{ Path = 'psmutant.self.config.json' }
        @{ Path = 'examples/psmutant.config.json' }
    ) {
        # Both carry _-prefixed prose keys, so this also pins that the comment convention
        # survives additionalProperties:false.
        $json = Get-Content (Join-Path $script:repoRoot $Path) -Raw
        # Called directly rather than wrapped in a "does not throw" assertion: there is no
        # Should-NotThrow in Pester 6, because an unhandled exception fails the test by
        # itself. Assert what it actually returned.
        Should-BeTrue -Actual (Test-Json -Json $json -Schema $script:cfgSchemaText -ErrorAction Stop)
    }

    It 'refuses a misspelled key, the way the validator does' {
        # additionalProperties:false is what makes a typo visible before the run starts.
        # The message is worse than the module's -- no "did you mean" -- which is exactly
        # why the code check stays.
        $bad = '{ "mutate": ["a"], "tests": { "a": ["t"] }, "mutat": ["b"] }'
        { Test-Json -Json $bad -Schema $script:cfgSchemaText -ErrorAction Stop } | Should-Throw
    }

    It 'refuses a wrong type when applied to raw JSON, as a consumer would apply it' {
        # ONE case, not a table of them. Assert-PSMutationConfig now validates against this
        # same schema, so Config.Tests.ps1 already covers the type cases through the real
        # entry point -- which is the coverage that counts, and repeating them here would be
        # the same assertion wearing a second hat.
        #
        # What this adds is the other application: a consumer validating a config FILE, text
        # in hand, rather than the object the module re-serialises. Same schema, different
        # caller, and only one of the two is exercised anywhere else.
        $json = '{ "mutate": ["a"], "tests": { "a": ["t"] }, "timeoutFactor": "four" }'
        { Test-Json -Json $json -Schema $script:cfgSchemaText -ErrorAction Stop } | Should-Throw
    }

    It 'accepts a $schema key naming the format the config is written against' {
        # A config that cannot name its own schema cannot be checked before the run, so the
        # key has to pass both here and in Assert-PSMutationConfig. Failing either one makes
        # the shipped schema unusable in the one place it matters most.
        $json = '{ "$schema": "./schemas/config.schema.json", "mutate": ["a"], "tests": { "a": ["t"] } }'
        Should-BeTrue -Actual (Test-Json -Json $json -Schema $script:cfgSchemaText -ErrorAction Stop)
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg ($json | ConvertFrom-Json))
    }
}
