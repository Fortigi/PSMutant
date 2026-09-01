# End-to-end: run the public Invoke-PSMutation against a tiny throwaway fixture project
# (one function + a covering test + a config) and assert the summary, the JSON report,
# and -- the headline guarantee -- that the tracked source is byte-identical afterwards.

BeforeAll {
    # This file starts REAL mutation runs, and a run under a CI annotates. Its fixtures are
    # throwaway files in a temp directory, so those annotations point at paths that do not
    # exist in this repository -- GitHub resolves them against the checkout and decorates the
    # pull request with warnings a reviewer cannot open, sitting beside the real ones the gate
    # produces. Seventeen of them, before this.
    #
    # Cleared for the file and RESTORED afterwards, never left as $null: $env: is process
    # state, this suite runs inside CI where the variable is genuinely set, and a file that
    # resets it silently decides what every later file sees.
    #
    # The annotation path itself is tested by MOCKING Test-PSMutationAnnotationHost, which is
    # hermetic and does not care which file ran first.
    $script:priorActions = $env:GITHUB_ACTIONS
    $env:GITHUB_ACTIONS = $null

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

AfterAll {
    Remove-Item $script:proj -Recurse -Force -ErrorAction SilentlyContinue
    $env:GITHUB_ACTIONS = $script:priorActions
}

Describe 'Invoke-PSMutation end-to-end' {
    It 'evaluates exactly the mutants this fixture determines' {
        # EXACT, not "more than zero". The fixture is fully determined -- two functions, two
        # operators, coveredLinesOnly on -- and produces the same three mutants on every run and
        # on both platforms; the compatibility guard prints the identical figures from an
        # identical fixture on every CI run.
        #
        # As inequalities these could not tell 3 mutants from 30 or from 1, which is the failure
        # class this suite is the last line of defence against: a run producing plausible-looking
        # but wrong counts. Losing the coverage filter, or double-counting a file, moves these
        # numbers and moved nothing before.
        $script:result.Total | Should-Be 3
        $script:result.Killed | Should-Be 1
        $script:result.Survived | Should-Be 2
        $script:result.Score | Should-Be 33.3
    }

    It 'produces exactly the mutant rows the fixture determines' {
        # The counts above can be right while the SET is wrong -- three mutants of the wrong
        # operator, or on the wrong lines, sum to three just as well. This pins what they are.
        $report = Get-Content (Join-Path $script:proj 'reports/e2e.json') -Raw | ConvertFrom-Json
        $rows = @($report.mutants | Sort-Object id | ForEach-Object {
                "{0}:{1}:{2}:{3}:{4}" -f $_.id, $_.line, $_.operator, $_.description, $_.status
            })
        $rows | Should-BeCollection @(
            '1:1:BinaryOperator:-gt -> -le:Killed'
            '2:2:BooleanLiteral:$true -> $false:Survived'
            '3:2:BooleanLiteral:$false -> $true:Survived'
        )
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

Describe 'Invoke-PSMutation -ListOnly end-to-end' {
    BeforeAll {
        # A real run of the real thing: real parse, real operators, real sandbox, real coverage.
        # The Orchestrator suite mocks Select-PSMutationCandidate, so this is the only place the
        # preview and the run are shown to agree about a set neither of them was handed.
        $script:preview = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -ListOnly -Quiet
    }

    It 'previews exactly the set the full run evaluated' {
        # THE contract of the mode. A preview that could disagree with the run is worse than no
        # preview: it would send someone to change a config against a number the run never uses.
        $script:preview.Total | Should-Be $script:result.Total
    }

    It 'measured coverage, because this config filters on it' {
        $script:preview.BaselineMeasured | Should-BeTrue
        # EXACT, like the counts the full run is pinned on. Produced is the PRE-filter number
        # and here it equals Total, because this fixture's tests execute every mutable line --
        # measured, not assumed. Asserted as a figure rather than as `-ge Total`, which would
        # hold for a Produced left at zero on a file nobody parsed.
        $script:preview.Produced | Should-Be 3
        # The distinction the two counts exist for is pinned where it is reachable: Runner's
        # suite drives a selection whose coverage filter genuinely removes candidates.
    }

    It 'wrote no report' {
        # Ran AFTER the full-run Describe, so the file exists and holds a real score. A preview
        # that wrote here would replace a measurement with counts over a set nobody evaluated.
        $doc = Get-Content (Join-Path $script:proj 'reports/e2e.json') -Raw | ConvertFrom-Json
        $doc.mutationScore | Should-Be 33.3
    }

    It 'reports no vacuous file for a fixture that has none' {
        # The negative, so the sets are known to be computed rather than merely present. Both,
        # because either alone certifies whatever the other does.
        $script:preview.FilesWithNoCandidate.Count | Should-Be 0
        $script:preview.FilesEmptiedByCoverage.Count | Should-Be 0
    }

    It 'names a mutate file no operator matched' {
        # The reason the mode exists. This file is real PowerShell, is listed in mutate, is
        # hashed into the report and contributes 0 of 0 -- so it scores a vacuous 100% that a
        # blended number cannot show. Two files in a real repository were in this state.
        $proj2 = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-vac-$([System.Guid]::NewGuid().ToString('N'))"
        try {
            New-Item -ItemType Directory -Path (Join-Path $proj2 'src') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $proj2 'tests') -Force | Out-Null
            Copy-Item $script:srcFile (Join-Path $proj2 'src/calc.ps1')
            Copy-Item (Join-Path $script:proj 'tests/calc.Tests.ps1') (Join-Path $proj2 'tests/calc.Tests.ps1')
            # No operator in the config's list has anything to match here.
            'function Get-Greeting { return ''hello'' }' | Set-Content (Join-Path $proj2 'src/quiet.ps1') -Encoding utf8
            $cfg2 = [ordered]@{
                sandboxSubtrees  = @('src', 'tests')
                mutate           = @('src/calc.ps1', 'src/quiet.ps1')
                tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1'); 'src/quiet.ps1' = @('tests/calc.Tests.ps1') }
                coveredLinesOnly = $true
                operators        = @('BinaryOperator', 'BooleanLiteral')
                thresholds       = @{ high = 85; low = 70; break = $null }
                reportPath       = 'reports/vac.json'
            }
            $cfgFile2 = Join-Path $proj2 'mutation.config.json'
            $cfg2 | ConvertTo-Json -Depth 6 | Set-Content $cfgFile2 -Encoding utf8

            $p = Invoke-PSMutation -ConfigFile $cfgFile2 -SourceRoot $proj2 -ListOnly -Quiet
            # The repo-relative path the config names, not the temp sandbox path the rows carry.
            $p.FilesWithNoCandidate | Should-Be 'src/quiet.ps1'
            # And a full run discloses the same file, in the report, which is where a reader
            # looks. The preview only made it visible sooner.
            Invoke-PSMutation -ConfigFile $cfgFile2 -SourceRoot $proj2 -Quiet | Out-Null
            $doc = Get-Content (Join-Path $proj2 'reports/vac.json') -Raw | ConvertFrom-Json
            $doc.filesWithNoCandidate | Should-Be 'src/quiet.ps1'
        }
        finally { Remove-Item $proj2 -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-PSMutation -ChangedFile end-to-end' {
    BeforeAll {
        # Its own two-file project, because the scope has to be a real subset of something.
        $script:cf = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-cf-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:cf 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:cf 'tests') -Force | Out-Null
        "function Get-Sign { param(`$n) if (`$n -gt 0) { return 'pos' } else { return 'neg' } }" |
            Set-Content (Join-Path $script:cf 'src/a.ps1') -Encoding utf8
        "function Get-Flag { param(`$n) if (`$n -gt 1) { return `$true } else { return `$false } }" |
            Set-Content (Join-Path $script:cf 'src/b.ps1') -Encoding utf8
        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'a.ps1') }
Describe 'a' { It 'pos' { Get-Sign 5 | Should -Be 'pos' }; It 'neg' { Get-Sign -5 | Should -Be 'neg' } }
'@ | Set-Content (Join-Path $script:cf 'tests/a.Tests.ps1') -Encoding utf8
        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'b.ps1') }
Describe 'b' { It 'runs' { { Get-Flag 2 } | Should -Not -Throw } }
'@ | Set-Content (Join-Path $script:cf 'tests/b.Tests.ps1') -Encoding utf8
        $script:cfConfig = Join-Path $script:cf 'c.json'
        [ordered]@{
            sandboxSubtrees  = @('src', 'tests')
            mutate           = @('src/a.ps1', 'src/b.ps1')
            tests            = @{ 'src/a.ps1' = @('tests/a.Tests.ps1'); 'src/b.ps1' = @('tests/b.Tests.ps1') }
            coveredLinesOnly = $true
            operators        = @('BinaryOperator')
            thresholds       = @{ high = 85; low = 70; break = 50 }
            reportPath       = 'reports/r.json'
        } | ConvertTo-Json -Depth 6 | Set-Content $script:cfConfig -Encoding utf8

        $script:cfFull = Invoke-PSMutation -ConfigFile $script:cfConfig -SourceRoot $script:cf -Quiet
        $script:cfScoped = Invoke-PSMutation -ConfigFile $script:cfConfig -SourceRoot $script:cf `
            -ChangedFile @('src/a.ps1', 'tests/a.Tests.ps1', 'README.md') -Quiet
    }

    AfterAll { Remove-Item $script:cf -Recurse -Force -ErrorAction SilentlyContinue }

    It 'evaluates a strict subset of what the full run did' {
        # Both numbers. "Fewer" alone would hold for a scoped run that mutated nothing, which is
        # a different outcome with a different meaning.
        $script:cfFull.Total | Should-Be 2
        $script:cfScoped.Total | Should-Be 1
    }

    It 'says it was scoped, and names the scope' {
        $script:cfScoped.Mode | Should-Be 'Changed'
        # The files as GIVEN, including the ones that are not in mutate: this is what the caller
        # asked about, and it is what makes the score readable.
        $script:cfScoped.ChangedFiles | Should-BeCollection @('src/a.ps1', 'tests/a.Tests.ps1', 'README.md')
    }

    It 'leaves ChangedFiles null on a whole-tree run' {
        # $null, not @(). Only absent may be read as a measurement of everything in mutate.
        $script:cfFull.Mode | Should-Be 'Full'
        $null -eq $script:cfFull.ChangedFiles | Should-BeTrue
    }

    It 'writes its own report and leaves the project one untouched' {
        $scoped = Get-Content (Join-Path $script:cf 'reports/r.changed.json') -Raw | ConvertFrom-Json
        $scoped.mode | Should-Be 'Changed'
        $scoped.changedFiles | Should-BeCollection @('src/a.ps1', 'tests/a.Tests.ps1', 'README.md')
        $scoped.total | Should-Be 1
        # The full report still reports the full run. A scoped number landing here is the thing
        # this convention exists to prevent.
        (Get-Content (Join-Path $script:cf 'reports/r.json') -Raw | ConvertFrom-Json).total | Should-Be 2
    }

    It 'writes a scoped report the published schema accepts' {
        # And the schema requires changedFiles beside the score, so a reader cannot see the
        # number without seeing what it covered.
        $schema = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/v2/report.schema.json') -Raw
        $text = [System.IO.File]::ReadAllText((Join-Path $script:cf 'reports/r.changed.json'))
        function Test-ScopedSchema { param([string]$Json)
            try { Test-Json -Json $Json -Schema $schema -ErrorAction Stop | Out-Null; return $true }
            catch { return $false }
        }
        Should-BeTrue -Actual (Test-ScopedSchema -Json $text)

        $doc = $text | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('changedFiles')
        Should-BeFalse -Actual (Test-ScopedSchema -Json ($doc | ConvertTo-Json -Depth 12)) `
            -Because 'a score over part of a tree that does not say which part is the number this module exists to stop people quoting'
    }

    It 'PASSES a pull request that touched no mutable file, despite a break threshold' {
        # An empty run scores 0, and this config breaks below 50. Without an explicit arm, a
        # documentation-only change fails the build for having nothing to say.
        $docs = Invoke-PSMutation -ConfigFile $script:cfConfig -SourceRoot $script:cf `
            -ChangedFile @('README.md') -Quiet
        $docs.ExitCode | Should-Be 0
        $docs.FailureReason | Should-Be 'None'
        $docs.Total | Should-Be 0
    }

    It 'REFUSES an empty list, which is a broken diff rather than an empty pull request' {
        { Invoke-PSMutation -ConfigFile $script:cfConfig -SourceRoot $script:cf -ChangedFile @() -Quiet } |
            Should-Throw -ExceptionMessage '*empty list*'
    }

    It 'does not call an out-of-scope declaration stale' {
        # THE hazard that would make this mode unusable. A declaration is stale when it matches no
        # mutant -- and every declaration about a file outside the scope matches none, because the
        # run never looked at that file. Reported as stale it fails the gate at any score, for
        # declarations that are perfectly correct.
        $cfg = Get-Content $script:cfConfig -Raw | ConvertFrom-Json
        $full = Get-Content (Join-Path $script:cf 'reports/r.json') -Raw | ConvertFrom-Json
        # A REAL declaration, taken from a mutant the full run actually produced in b.ps1, so the
        # claim is true and the only question is whether the scoped run judges it.
        $bMutant = @($full.mutants | Where-Object { $_.File -like '*b.ps1' })[0]
        # The fixture must produce a mutant in b.ps1, or the declaration below is about nothing
        # and the assertion proves nothing.
        Should-NotBeNull -Actual $bMutant
        $key = "src/b.ps1:$($bMutant.Function):$($bMutant.Description)"
        $cfg | Add-Member -NotePropertyName equivalents -NotePropertyValue ([pscustomobject]@{ $key = 'declared for this test' })
        $withDecl = Join-Path $script:cf 'c2.json'
        $cfg | ConvertTo-Json -Depth 8 | Set-Content $withDecl -Encoding utf8

        $r = Invoke-PSMutation -ConfigFile $withDecl -SourceRoot $script:cf -ChangedFile @('src/a.ps1') -Quiet
        $r.StaleEquivalents | Should-BeCollection @()
        $r.FailureReason | Should-Be 'None'
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
        $first.schemaVersion          | Should-Be 2
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
            Should-BeLikeString '*Pester 5.2.0 or later*'
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

    It 'points only at help topics that actually ship' {
        # The help said "see about_PSMutant / the README" and there is no about_PSMutant: no
        # en-US directory, no *.help.txt anywhere. A consumer installing from the gallery and
        # running Get-Help Invoke-PSMutation -Full was sent to a topic that does not resolve.
        #
        # Checked against the FILES rather than against a list of known-good names, so writing a
        # real topic satisfies this by existing rather than by being added here too. The module
        # root is where PowerShell looks: <module>/<culture>/about_<name>.help.txt.
        $root = Split-Path -Parent $PSScriptRoot
        $text = @($script:help.parameters.parameter.description.Text) +
                @($script:help.description.Text) + @($script:help.Synopsis)
        $named = @([regex]::Matches(($text -join "`n"), 'about_[A-Za-z0-9_]+') |
                ForEach-Object { $_.Value } | Sort-Object -Unique)
        foreach ($topic in $named) {
            $shipped = @(Get-ChildItem -Path $root -Recurse -Filter "$topic.help.txt" -ErrorAction SilentlyContinue)
            $shipped.Count | Should-BeGreaterThan 0 -Because "the help points at $topic, which no *.help.txt provides"
        }
    }

    It 'would notice a topic that does not exist' {
        # The paired half, and it is not optional here: the assertion above iterates a list that
        # is EMPTY today, so it passes over zero topics and would pass just as well if the regex
        # matched nothing at all. This runs the same rule against a name known to be absent.
        $root = Split-Path -Parent $PSScriptRoot
        @(Get-ChildItem -Path $root -Recurse -Filter 'about_NoSuchTopic.help.txt' -ErrorAction SilentlyContinue).Count |
            Should-Be 0
        # And against one known to be present, so the search itself is proven to find things.
        @(Get-ChildItem -Path $root -Recurse -Filter 'PSMutant.psd1' -ErrorAction SilentlyContinue).Count |
            Should-BeGreaterThan 0
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
    # schemas/v2/report.schema.json is shipped with the module so a consumer can validate a
    # report without reading this repo's tests. That only means anything if the reports we
    # actually emit satisfy it, which is what this Describe is for -- a schema that has
    # drifted from the writer is worse than none, because it invites a consumer to code
    # against a shape they will not receive.
    #
    # Validated as TEXT, not as a parsed object. ConvertFrom-Json recognises the ISO-8601
    # generatedAt and hands back a [datetime], so a round-tripped object no longer has the
    # string the schema describes. The file is the contract.
    BeforeAll {
        $script:schema = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/v2/report.schema.json') -Raw
        $script:fullText = [System.IO.File]::ReadAllText((Join-Path $script:proj 'reports/e2e.json'))
        $script:recheckText = [System.IO.File]::ReadAllText((Join-Path $script:proj 'reports/e2e.recheck.json'))

        # A REAL partial report, from a run stopped by its own wall-clock budget. Its own fixture
        # rather than a value another Describe left behind: this suite is run in both directions
        # -- tools/Test-PSMutantOrderIndependence.ps1 reverses it -- so a block that depends on
        # another having run first is green one way and red the other.
        #
        # Deterministic rather than lucky: the covering suite sleeps 1500ms and the budget is 1s,
        # so the check after the FIRST mutant always fires and the report always records one.
        $script:pProj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-partial-e2e-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:pProj 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:pProj 'tests') -Force | Out-Null
        'function Get-Sign { param($n) if ($n -gt 0) { return 1 } else { return 2 } }' |
            Set-Content (Join-Path $script:pProj 'src/p.ps1') -Encoding utf8
        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'p.ps1'); Start-Sleep -Milliseconds 1500 }
Describe 'Get-Sign' {
    It 'is 1 for positive' { Get-Sign 5 | Should -Be 1 }
    It 'is 2 otherwise' { Get-Sign -5 | Should -Be 2 }
}
'@ | Set-Content (Join-Path $script:pProj 'tests/p.Tests.ps1') -Encoding utf8
        [ordered]@{
            mutate            = @('src/p.ps1')
            tests             = @{ 'src/p.ps1' = @('tests/p.Tests.ps1') }
            operators         = @('BinaryOperator', 'NumberLiteral', 'ConditionalBoundary')
            runTimeoutSeconds = 1
            reportPath        = 'reports/partial.json'
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:pProj 'p.config.json') -Encoding utf8
        try { Invoke-PSMutation -ConfigFile (Join-Path $script:pProj 'p.config.json') -SourceRoot $script:pProj -Quiet | Out-Null }
        catch { Write-Verbose "expected: $($_.Exception.Message)" }
        $script:partialText = [System.IO.File]::ReadAllText((Join-Path $script:pProj 'reports/partial.json'))

        function Test-AgainstSchema { param([string]$Json)
            try { Test-Json -Json $Json -Schema $script:schema -ErrorAction Stop | Out-Null; return $true }
            catch { return $false }
        }
    }

    AfterAll { Remove-Item $script:pProj -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts the full report a real run just wrote' {
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:fullText)
    }

    It 'accepts the PARTIAL report a real interrupted run just wrote' {
        # The third shape, and the one a resume reads. All three travel different call paths, and
        # wiring a field into one writer and not the others is invisible until somebody opens the
        # file.
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:partialText)
    }

    It 'accepts the recheck report a real run just wrote' {
        # Both shapes, because the recheck report travels a different call path -- wiring a
        # field into one writer and not the other is invisible until someone opens the file.
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:recheckText)
    }

    It 'refuses a PARTIAL report that records nothing about its test files' {
        # A partial report exists to be read back, and -ResumeFrom carries over every verdict in
        # it -- which is only sound while no mapped test file has shrunk. Without this field a
        # resume is refused at run time, so the document is one nobody can ever use. The schema
        # makes that shape unrepresentable rather than leaving it to the writer.
        #
        # REQUIRED rather than optional, and that is only affordable because schemas/v2 has never
        # shipped: v0.4.0 carried v1 alone. "Becomes required" moves schemaVersion when documents
        # exist that would stop validating; none do.
        $bad = $script:partialText -replace '(?m)^[ \t]*"testFiles":.*\r?$', ''
        $bad | Should-NotBe $script:partialText -Because 'the fixture must actually differ, or this asserts nothing'
        Should-BeFalse -Actual (Test-AgainstSchema -Json $bad)
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:partialText)
    }

    It 'refuses a count of carried-over mutants with nothing saying the run was resumed' {
        # A document nobody can read: carriedOverUnverified says how much of the score this run
        # did not measure, and without `resumed` a reader cannot tell that from an ordinary
        # report with a stray field. Costs no previously-valid report, because neither field
        # existed before -- which is why it is a widening rather than a schemaVersion move.
        #
        # Asserted as INVALID rather than on the message, and that is a fact about Test-Json
        # rather than a weaker test. Measured: the whole message for this document is
        # 'Required properties ["mode"] are not present' -- the first UNSATISFIED `if` among the
        # branches above, which every full report leaves unsatisfied and which has nothing to do
        # with the fault. It is the "reports the arm it did NOT take" trap already recorded here,
        # one layer deeper: with several conditional branches it reports the first one, not the
        # one that actually rejected. The pairing below is what keeps this from being vacuous.
        $bad = $script:fullText -replace '"generatedFrom"', '"carriedOverUnverified": 3, "generatedFrom"'
        $bad | Should-NotBe $script:fullText -Because 'the fixture must actually differ, or this asserts nothing'
        Should-BeFalse -Actual (Test-AgainstSchema -Json $bad)
    }

    It 'accepts the pair together, so the rule above is not simply refusing the field' {
        # The pairing this repo requires of every refusal. Without it the rule would pass just as
        # well if carriedOverUnverified were forbidden outright, which would reject every resumed
        # report the module writes.
        $good = $script:fullText -replace '"generatedFrom"', '"resumed": true, "carriedOverUnverified": 3, "generatedFrom"'
        Should-BeTrue -Actual (Test-AgainstSchema -Json $good)
    }

    It 'refuses a scored report that omits filesWithNoCandidate' {
        # The reason version 2 exists. A file no operator matched contributes 0 of 0 and is
        # invisible in a blended score, so a document carrying mutationScore must say whether
        # there were any -- and "the writer always sets it" is the assurance every other
        # disclosure here declined to rely on.
        #
        # Built by REMOVING the field from a report that is otherwise valid, so the required
        # rule is the only thing left that can refuse it.
        $doc = $script:fullText | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('filesWithNoCandidate')
        Should-BeFalse -Actual (Test-AgainstSchema -Json ($doc | ConvertTo-Json -Depth 12)) `
            -Because 'a score that cannot say whether a file contributed nothing is a score with a hole in it'
    }

    It 'refuses a scored report that omits filesMutated' {
        # Left optional in v1 for one reason only -- requiring it would have failed every report
        # 0.4.0 produced, and the version could not move for an added field. The version has
        # moved, so the deferral is spent: 100% across eight files and 100% across nine are the
        # same number, and only one of them covers the ninth.
        $doc = $script:fullText | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('filesMutated')
        Should-BeFalse -Actual (Test-AgainstSchema -Json ($doc | ConvertTo-Json -Depth 12))
    }

    It 'refuses a version 1 document, naming the version rather than the field' {
        # schemaVersion is minimum 2 here, not a const. A v1 report then fails on the version --
        # the true reason -- instead of on a field it was never supposed to carry, while a later
        # version still validates as long as it keeps these fields.
        $doc = $script:fullText | ConvertFrom-Json
        $doc.schemaVersion = 1
        Should-BeFalse -Actual (Test-AgainstSchema -Json ($doc | ConvertTo-Json -Depth 12))

        $doc.schemaVersion = 3
        Should-BeTrue -Actual (Test-AgainstSchema -Json ($doc | ConvertTo-Json -Depth 12)) `
            -Because 'a reader validating against v2 must keep working when a later version records more'
    }

    It 'still ships the v1 schema, which is the only thing that can validate an archived report' {
        # Nothing writes v1 any more. An archived report still says schemaVersion 1, and a
        # consumer who upgraded has only the schemas shipped beside the new module.
        $v1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/v1/report.schema.json'
        Test-Path $v1 | Should-BeTrue
        # Parsed, and asserted to still describe version 1 -- present-and-unreadable is the
        # failure a Test-Path alone cannot see, and a v1 file quietly edited to v2's floor
        # would validate nothing it exists for.
        (Get-Content $v1 -Raw | ConvertFrom-Json).properties.schemaVersion.minimum | Should-Be 1
    }

    It 'refuses a PARTIAL report carrying a score' {
        # Same promise as a recheck -- counts, never a score -- so the schema forbids the number
        # rather than trusting a writer never to add it.
        #
        # The accepting half used to live here, built by editing the recheck report into the
        # shape of a partial one. It now sits above against the document a real interrupted run
        # wrote, which is strictly better and is what caught this: the hand-built fixture had no
        # testFiles, and once that became required the doctored document stopped being a valid
        # partial report -- while a real one still was.
        #
        # The score fixture is built from the FULL report rather than from the partial one, and
        # that is what makes the assertion mean anything. A partial document simply lacks the
        # full-run disclosures, so a score added to it is already refused for missing those --
        # measured: delete the Partial rule entirely and the naive version of this test still
        # passes. Starting from a document that IS otherwise a valid full report leaves the
        # Partial rule as the only thing that can refuse it.
        $scored = $script:fullText | ConvertFrom-Json
        $scored | Add-Member -NotePropertyName mode -NotePropertyValue 'Partial'
        $scored | Add-Member -NotePropertyName evaluated -NotePropertyValue 2
        $scored | Add-Member -NotePropertyName planned -NotePropertyValue 7
        Should-BeFalse -Actual (Test-AgainstSchema -Json ($scored | ConvertTo-Json -Depth 12)) `
            -Because 'a percentage over whichever mutants happened to run first is not a score'
    }

    It 'names the field that is actually missing, not the one that would change the shape' {
        # The discriminator is keyed on mutationScore rather than on the presence of `mode`,
        # and this is why. Keyed the other way, a full report missing any one disclosure failed
        # the else-arm while the implementation reported the if-arm's requirement -- so the
        # message read 'Required properties ["mode"] are not present', naming the one field
        # whose presence would turn the document into a recheck. Following it made things
        # worse, and it cost real time here.
        # The line is blanked rather than removed, and the pattern carries NO line ending.
        # Spelled with a \r?\n it matched on Linux and nothing on Windows, where the report is
        # CRLF -- so the fixture came back identical to the original, and the assertion below is
        # the only reason that surfaced as a failure instead of as a vacuous pass.
        $bad = $script:fullText -replace '(?m)^[ \t]*"skippedAsUncovered":[ \t]*\d+,[ \t]*\r?$', ''
        $bad | Should-NotBe $script:fullText -Because 'the fixture must actually differ, or this asserts nothing'
        $message = ''
        try { Test-Json -Json $bad -Schema $script:schema -ErrorAction Stop | Out-Null }
        catch { $message = $_.Exception.Message }
        $message | Should-MatchString 'skippedAsUncovered'
        $message | Should-NotMatchString 'mode'
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

    It 'refuses a report whose filesWithoutTestMapping holds a null' {
        # The #158 shape, made unrepresentable rather than merely fixed. `@($null)` is an array
        # of ONE element whose value is $null, and the report published exactly that on the
        # DEFAULT path for two releases. Nothing caught it because the field was not in this
        # schema at all, and additionalProperties is true by design -- so an unknown field with
        # a wrong value validated cleanly. Declaring `items` is what turns it into a violation.
        $tampered = $script:fullText -replace '("filesWithoutTestMapping"\s*:\s*)\[\s*\]', '$1[ null ]'
        # Asserted first: a -replace that matched nothing would leave the document untouched and
        # this test would pass while proving nothing, which is the trap the test above names too.
        $tampered | Should-NotBe $script:fullText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $tampered)
    }

    It 'refuses a full report that omits what the score excluded' {
        # skippedAsUncovered, filesWithNoMutants and filesWithoutTestMapping are REQUIRED on a
        # full run for the same reason declaredEquivalent is: a number cannot be read without
        # what was left out of it. They were absent from this schema until #158.
        $stripped = $script:fullText -replace '\s*"skippedAsUncovered"\s*:\s*\d+,', ''
        $stripped | Should-NotBe $script:fullText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $stripped)
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
    # schemas/v1/config.schema.json is the definition of the config format -- the document
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
        $script:cfgSchemaText = Get-Content (Join-Path $root 'schemas/v1/config.schema.json') -Raw
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
        $json = '{ "$schema": "./schemas/v1/config.schema.json", "mutate": ["a"], "tests": { "a": ["t"] } }'
        Should-BeTrue -Actual (Test-Json -Json $json -Schema $script:cfgSchemaText -ErrorAction Stop)
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg ($json | ConvertFrom-Json))
    }
}

Describe 'a consumer-shaped repository, which is not this one' {
    # Every other fixture here has PSMutant's own shape: a flat src/ + tests/ where the test
    # dot-sources the source file. Two consumer shapes were never exercised, and they are the two
    # where the sandbox's path handling actually gets tested.

    BeforeAll {
        $script:nested = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-nested-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:nested 'src/Domain') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:nested 'tests/Domain') -Force | Out-Null
        @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
'@ | Set-Content (Join-Path $script:nested 'src/Domain/Calc.ps1') -Encoding utf8
        @'
BeforeAll { . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src' 'Domain' 'Calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg' { Get-Sign -5 | Should -Be 'neg' }
}
'@ | Set-Content (Join-Path $script:nested 'tests/Domain/Calc.Tests.ps1') -Encoding utf8
        $cfg = [ordered]@{
            sandboxSubtrees  = @('src', 'tests')
            mutate           = @('src/Domain/Calc.ps1')
            tests            = @{ 'src/Domain/Calc.ps1' = @('tests/Domain/Calc.Tests.ps1') }
            coveredLinesOnly = $true
            operators        = @('BinaryOperator')
            thresholds       = @{ high = 85; low = 70 }
            reportPath       = 'reports/nested.json'
        }
        $cf = Join-Path $script:nested 'c.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $cf -Encoding utf8
        $script:nestedResult = Invoke-PSMutation -ConfigFile $cf -SourceRoot $script:nested -Quiet
        $script:nestedReport = Get-Content (Join-Path $script:nested 'reports/nested.json') -Raw | ConvertFrom-Json
    }

    AfterAll { Remove-Item $script:nested -Recurse -Force -ErrorAction SilentlyContinue }

    It 'mutates a NESTED source tree' {
        # src/Domain/Calc.ps1 rather than src/calc.ps1. This is where the sandbox path mapping is
        # actually exercised: a flat layout maps a single path segment and cannot tell a correct
        # relative mapping from one that happens to work.
        $script:nestedResult.Total | Should-Be 1
        $script:nestedResult.Killed | Should-Be 1
    }

    It 'reports the nested path relative, with forward slashes, on every platform' {
        # The display path is what a consumer matches against -- in a report, in a CI annotation,
        # in an equivalence declaration. A backslash here is a key a Linux run can never match,
        # and this is the assertion a flat fixture cannot make at all because it has no separator
        # in the relative part.
        @($script:nestedReport.mutants)[0].file | Should-Be 'src/Domain/Calc.ps1'
        @($script:nestedReport.sourceHashes.PSObject.Properties.Name) | Should-BeCollection @('src/Domain/Calc.ps1')
    }
}

Describe 'a module-shaped consumer whose manifest is outside sandboxSubtrees' {
    # The documented trap: only sandboxSubtrees are copied, so a test that imports a manifest at
    # the repo root finds nothing in the sandbox. It is recorded in this repo as folklore -- in
    # tests/Recheck.Tests.ps1's header and in CLAUDE.md -- and nothing asserted the behaviour.
    #
    # What the assertion turned out to be is NOT what issue #35 assumed. It expected a silent,
    # vacuous score; measured, Assert-PSMutationBaselineGreen already refuses the run and NAMES
    # the failing test. So this pins a guard that is already right rather than asking for the new
    # feature the issue proposed -- which is the better outcome, and only checkable by running it.

    BeforeAll {
        $script:modProj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-mod-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:modProj 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:modProj 'tests') -Force | Out-Null
        # Manifest and root module at the REPO ROOT -- outside the copied subtrees.
        "@{ RootModule = 'Their.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = @('Get-Sign') }" |
            Set-Content (Join-Path $script:modProj 'Their.psd1') -Encoding utf8
        @'
. (Join-Path $PSScriptRoot 'src' 'calc.ps1')
Export-ModuleMember -Function Get-Sign
'@ | Set-Content (Join-Path $script:modProj 'Their.psm1') -Encoding utf8
        @'
function Get-Sign { param($n) if ($n -gt 0) { return 'pos' } else { return 'neg' } }
'@ | Set-Content (Join-Path $script:modProj 'src/calc.ps1') -Encoding utf8
        @'
BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Their.psd1') -Force }
Describe 'Get-Sign' { It 'is pos' { Get-Sign 5 | Should -Be 'pos' } }
'@ | Set-Content (Join-Path $script:modProj 'tests/calc.Tests.ps1') -Encoding utf8
        $cfg = [ordered]@{
            sandboxSubtrees  = @('src', 'tests')
            mutate           = @('src/calc.ps1')
            tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
            coveredLinesOnly = $true
            operators        = @('BinaryOperator')
            thresholds       = @{ high = 85; low = 70 }
            reportPath       = 'reports/mod.json'
        }
        $script:modConfig = Join-Path $script:modProj 'c.json'
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:modConfig -Encoding utf8
    }

    AfterAll { Remove-Item $script:modProj -Recurse -Force -ErrorAction SilentlyContinue }

    It 'REFUSES the run rather than scoring it' {
        # The failure this shape must never produce is a score. Every mutant would "die" for the
        # reason the suite was already broken, and the consumer would read a perfect number over
        # tests that never ran.
        { Invoke-PSMutation -ConfigFile $script:modConfig -SourceRoot $script:modProj -Quiet } |
            Should-Throw -ExceptionMessage '*Baseline suite is not green*'
    }

    It 'names the test that failed, so the cause is findable' {
        # A bare "not green" sends the reader to reproduce a failure that by definition is not
        # happening on the machine they are standing on -- their suite passes outside the sandbox.
        # The named test plus its message is what points at the missing manifest.
        $message = $null
        try { Invoke-PSMutation -ConfigFile $script:modConfig -SourceRoot $script:modProj -Quiet }
        catch { $message = $_.Exception.Message }
        $message | Should-BeLikeString '*Get-Sign.is pos*'
        # The test NAME and a non-empty reason -- not Pester's exact wording, which is not ours to
        # guarantee and differs between machines. The first draft asserted the literal
        # "'Get-Sign' is not recognized" and went red on both CI legs, where the message came back
        # "Failed: Get-Sign.is pos -- ." That empty reason was a real defect, now fixed in
        # Invoke-PSMutationBaseline; this asserts the property rather than the prose.
        $message | Should-NotBeLikeString '*is pos -- .*'
    }

    It 'writes no report for a run it refused' {
        # A report from a refused run is an artefact claiming a measurement nobody made.
        Test-Path (Join-Path $script:modProj 'reports/mod.json') | Should-BeFalse
    }
}

Describe 'a parallel run answers exactly what a serial one does' {
    # The requirement #1 states outright: results must be deterministic regardless of scheduling.
    # It is asserted end to end rather than by reasoning about the scheduler, because the ways
    # this could go wrong are all about the ENVIRONMENT -- two workers sharing a file, a worker
    # running the primary sandbox's tests, a row naming the temp directory that happened to run
    # it -- and none of those are visible from inside the loop.
    #
    # Its own fixture, larger than the one above and with a deliberate spread of durations: a
    # killed mutant stops at the first failing test and a survivor runs the whole suite, so
    # workers finish OUT OF ORDER, which is the case an in-order report has to survive.
    BeforeAll {
        $script:pproj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-par-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:pproj 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:pproj 'tests') -Force | Out-Null
        @'
function Get-Band {
    param($n)
    if ($n -gt 100) { return 'high' }
    if ($n -gt 10) { return 'mid' }
    return 'low'
}
function Get-Step {
    param($n)
    if ($n -eq 0) { return 0 }
    return ($n * 2) + 1
}
'@ | Set-Content (Join-Path $script:pproj 'src/band.ps1') -Encoding utf8

        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'band.ps1') }
Describe 'Get-Band' {
    It 'is high above a hundred' { Get-Band 500 | Should -Be 'high' }
    It 'is mid above ten' { Get-Band 50 | Should -Be 'mid' }
    It 'is low otherwise' { Get-Band 1 | Should -Be 'low' }
}
Describe 'Get-Step' {
    It 'is zero at zero' { Get-Step 0 | Should -Be 0 }
    It 'doubles and adds one' { Get-Step 4 | Should -Be 9 }
}
'@ | Set-Content (Join-Path $script:pproj 'tests/band.Tests.ps1') -Encoding utf8

        function WriteParallelConfig {
            param([string]$Name, $Workers)
            $cfg = [ordered]@{
                sandboxSubtrees = @('src', 'tests')
                mutate          = @('src/band.ps1')
                tests           = @{ 'src/band.ps1' = @('tests/band.Tests.ps1') }
                operators       = @('BinaryOperator', 'NumberLiteral', 'ConditionalBoundary')
                reportPath      = "reports/$Name.json"
            }
            if ($null -ne $Workers) { $cfg.workers = $Workers }
            $path = Join-Path $script:pproj "$Name.config.json"
            $cfg | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding utf8
            return $path
        }

        $script:serialResult = Invoke-PSMutation -ConfigFile (WriteParallelConfig -Name 'serial' -Workers $null) `
            -SourceRoot $script:pproj -Quiet
        $script:parallelResult = Invoke-PSMutation -ConfigFile (WriteParallelConfig -Name 'parallel' -Workers 4) `
            -SourceRoot $script:pproj -Quiet
        $script:serialReport = Get-Content (Join-Path $script:pproj 'reports/serial.json') -Raw | ConvertFrom-Json
        $script:parallelReport = Get-Content (Join-Path $script:pproj 'reports/parallel.json') -Raw | ConvertFrom-Json
    }

    AfterAll { Remove-Item $script:pproj -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reaches the same score over the same mutants' {
        $script:parallelResult.Total | Should-Be $script:serialResult.Total
        $script:parallelResult.Killed | Should-Be $script:serialResult.Killed
        $script:parallelResult.Survived | Should-Be $script:serialResult.Survived
        $script:parallelResult.Score | Should-Be $script:serialResult.Score
        # Not vacuous: a fixture that produced no mutants would satisfy every equality above.
        $script:serialResult.Total | Should-BeGreaterThan 5
    }

    It 'writes the mutant rows in the SAME ORDER, with the same verdicts' {
        # The in-order retirement, end to end. Workers finish out of order, so a report that
        # recorded completion order would differ between two runs of one config -- and a consumer
        # diffing reports would see churn that means nothing.
        $serial = @($script:serialReport.mutants | ForEach-Object { "$($_.id)|$($_.file)|$($_.line)|$($_.description)|$($_.status)" })
        $parallel = @($script:parallelReport.mutants | ForEach-Object { "$($_.id)|$($_.file)|$($_.line)|$($_.description)|$($_.status)" })
        $parallel | Should-BeCollection $serial
    }

    It 'names no worker sandbox anywhere in the report' {
        # Which worker ran a mutant is scheduling. A row carrying a per-worker temp path would be
        # a field that changes with the machine, and the identity every equivalence declaration
        # and every baseline entry is keyed on would move with it.
        $raw = Get-Content (Join-Path $script:pproj 'reports/parallel.json') -Raw
        $raw | Should-NotMatchString 'psmut-sandbox-'
    }

    It 'leaves the tracked source byte-identical, from every worker' {
        # The headline guarantee, restated for a pool: N sandboxes are N more chances to write
        # somewhere real.
        Get-Content (Join-Path $script:pproj 'src/band.ps1') -Raw |
            Should-MatchString ([regex]::Escape('if ($n -gt 100) { return ''high'' }'))
    }

    It 'removes every worker sandbox it made' {
        # One leaked temp tree per worker per run, otherwise -- and the stale sweep only reclaims
        # a sandbox whose owning process is gone, so a long-lived host would keep all of them.
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter "psmut-sandbox-$PID-*" `
                -ErrorAction SilentlyContinue).Count | Should-Be 0
    }
}

Describe 'a resumed run answers exactly what an uninterrupted one does' {
    # The promise -ResumeFrom makes. Its own fixture, because this suite is run in both
    # directions and a block that depends on another having run first is green one way and red
    # the other -- and because the interruption has to be deterministic: the covering suite
    # sleeps 900ms and the budget is 1s, so the run always stops partway rather than sometimes.
    BeforeAll {
        $script:rProj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-resume-e2e-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:rProj 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:rProj 'tests') -Force | Out-Null
        @'
function Get-Band {
    param($n)
    if ($n -gt 100) { return 'high' }
    if ($n -gt 10) { return 'mid' }
    return 'low'
}
'@ | Set-Content (Join-Path $script:rProj 'src/band.ps1') -Encoding utf8
        @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'band.ps1'); Start-Sleep -Milliseconds 900 }
Describe 'Get-Band' {
    It 'is high above a hundred' { Get-Band 500 | Should -Be 'high' }
    It 'is mid above ten' { Get-Band 50 | Should -Be 'mid' }
    It 'is low otherwise' { Get-Band 1 | Should -Be 'low' }
}
'@ | Set-Content (Join-Path $script:rProj 'tests/band.Tests.ps1') -Encoding utf8

        function script:WriteResumeConfig {
            param([string]$Name, $RunTimeout)
            $cfg = [ordered]@{
                mutate     = @('src/band.ps1')
                tests      = @{ 'src/band.ps1' = @('tests/band.Tests.ps1') }
                operators  = @('BinaryOperator', 'NumberLiteral', 'ConditionalBoundary')
                reportPath = "reports/$Name.json"
            }
            if ($null -ne $RunTimeout) { $cfg.runTimeoutSeconds = $RunTimeout }
            $p = Join-Path $script:rProj "$Name.config.json"
            $cfg | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding utf8
            return $p
        }

        # 1. A run stopped by its own wall-clock budget, leaving a partial report.
        try { Invoke-PSMutation -ConfigFile (script:WriteResumeConfig -Name 'stop' -RunTimeout 1) -SourceRoot $script:rProj -Quiet | Out-Null }
        catch { Write-Verbose "expected: $($_.Exception.Message)" }
        $script:partial = Get-Content (Join-Path $script:rProj 'reports/stop.json') -Raw | ConvertFrom-Json
        Copy-Item (Join-Path $script:rProj 'reports/stop.json') (Join-Path $script:rProj 'carried.json')

        # 2. The same config, resumed from it.
        $script:resumeResult = Invoke-PSMutation -ConfigFile (script:WriteResumeConfig -Name 'resumed' -RunTimeout $null) `
            -SourceRoot $script:rProj -ResumeFrom (Join-Path $script:rProj 'carried.json') -Quiet
        $script:resumed = Get-Content (Join-Path $script:rProj 'reports/resumed.json') -Raw | ConvertFrom-Json

        # 3. And a clean run of the same config, for comparison.
        $script:freshResult = Invoke-PSMutation -ConfigFile (script:WriteResumeConfig -Name 'fresh' -RunTimeout $null) `
            -SourceRoot $script:rProj -Quiet
        $script:fresh = Get-Content (Join-Path $script:rProj 'reports/fresh.json') -Raw | ConvertFrom-Json
    }

    AfterAll { Remove-Item $script:rProj -Recurse -Force -ErrorAction SilentlyContinue }

    It 'stopped partway, which is what makes the rest of this mean anything' {
        # Guarded, not assumed. A fixture that finished would make every assertion below pass
        # against a resume that carried nothing and did all the work itself.
        $script:partial.mode | Should-Be 'Partial'
        $script:partial.evaluated | Should-BeGreaterThan 0
        $script:partial.evaluated | Should-BeLessThan $script:partial.planned
    }

    It 'produces the same rows, in the same order, as a run that was never interrupted' {
        # The whole promise. Same mutants, same verdicts, same order -- the order because
        # finished mutants are retired in candidate order, which is what makes a partial report
        # a genuine prefix rather than whichever mutants happened to land first.
        $a = @($script:resumed.mutants | ForEach-Object { "$($_.Id)|$($_.File)|$($_.Line)|$($_.Description)|$($_.Status)" })
        $b = @($script:fresh.mutants | ForEach-Object { "$($_.Id)|$($_.File)|$($_.Line)|$($_.Description)|$($_.Status)" })
        $a | Should-BeCollection $b
    }

    It 'reaches the same score, and it is a REAL one' {
        # The difference from a recheck, which may not carry a score at all: a resumed run is
        # complete, so every mutant has a verdict and the percentage is over all of them.
        $script:resumeResult.Score | Should-Be $script:freshResult.Score
        $script:resumeResult.Total | Should-Be $script:freshResult.Total
        $script:resumed.mutationScore | Should-Be $script:fresh.mutationScore
    }

    It 'says how much of that score it did not measure itself' {
        # Everything downstream reads this file as a measurement and part of it was measured by
        # an earlier run. A reader has to be able to see which part.
        $script:resumed.resumed | Should-BeTrue
        $script:resumed.carriedOverUnverified | Should-Be $script:partial.evaluated
    }

    It 'leaves an ordinary run saying neither, so presence is the discriminator' {
        $script:fresh.PSObject.Properties.Name | Should-NotContainCollection 'resumed'
        $script:fresh.PSObject.Properties.Name | Should-NotContainCollection 'carriedOverUnverified'
    }

    It 'refuses to resume once the source has moved under the recorded ids' {
        # Mutant ids are AST-walk positions, so an edit renumbers them and the carried-over rows
        # would describe other mutants. Same guard -RecheckFrom uses, asked with the same
        # function.
        $src = Join-Path $script:rProj 'src/band.ps1'
        $before = [System.IO.File]::ReadAllText($src)
        try {
            [System.IO.File]::WriteAllText($src, "function Get-Extra { 1 }`n" + $before)
            { Invoke-PSMutation -ConfigFile (script:WriteResumeConfig -Name 'moved' -RunTimeout $null) `
                    -SourceRoot $script:rProj -ResumeFrom (Join-Path $script:rProj 'carried.json') -Quiet } |
                Should-Throw -ExceptionMessage '*Cannot resume from*changed since the report was written*'
        }
        finally { [System.IO.File]::WriteAllText($src, $before) }
    }

    It 'refuses to resume from a report that is not a partial one' {
        # A completed report has nothing left to evaluate. Pointed at the full report this same
        # fixture just wrote, so the refusal is against a real document rather than a stub.
        { Invoke-PSMutation -ConfigFile (script:WriteResumeConfig -Name 'notpartial' -RunTimeout $null) `
                -SourceRoot $script:rProj -ResumeFrom (Join-Path $script:rProj 'reports/fresh.json') -Quiet } |
            Should-Throw -ExceptionMessage "*not 'Partial'*"
    }
}
