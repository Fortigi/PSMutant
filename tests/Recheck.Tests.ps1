# Unit tests for re-running only a previous run's survivors (src/PSMutation.Recheck.ps1).
# Also the covering suite for self-mutating that file - keep it self-contained and
# dot-sourced: the self-mutation sandbox copies only src/ and tests/, so a test that
# reaches for the module manifest at the repo root loads nothing, records no coverage,
# and leaves the file silently unmutated while still appearing in the config.
#
# The value of a recheck is speed; its risk is a confident wrong answer, because it
# matches mutants by an AST-walk position that only means anything for byte-identical
# source and the same operator set. Most of what is pinned here is therefore the
# REFUSALS, plus the two guarantees that stop a filtered run reading as a measurement.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Sandbox.ps1')    # ConvertFrom-PSMutationSandboxPath
    . (Join-Path $src 'PSMutation.Runner.ps1')     # Invoke-PSMutationLoop, mocked below
    . (Join-Path $src 'PSMutation.Report.ps1')     # the equivalence key, to skip declared ones
    . (Join-Path $src 'PSMutation.Output.ps1')
    . (Join-Path $src 'PSMutation.Recheck.ps1')

    function Get-FakeReport {
        param(
            [hashtable]$SourceHashes = @{ 'src/a.ps1' = 'hash-a' },
            [string[]]$Operators = @('BinaryOperator'),
            [object[]]$Survivors = @(),
            [switch]$OmitHashes
        )
        $o = [pscustomobject]@{
            generatedFrom = 'PSMutant'
            operators     = @($Operators | Sort-Object)
            sourceHashes  = [pscustomobject]$SourceHashes
            survivors     = $Survivors
        }
        if ($OmitHashes) { $o.PSObject.Properties.Remove('sourceHashes') }
        return $o
    }
}

Describe 'Test-PSMutationRecheckCompatible' {
    It 'accepts a report whose hashes and operators still match' {
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator')
        @($why).Count | Should-Be 0
    }

    It 'refuses when a mutated file changed' {
        # The whole point of the guard: same file name, different bytes, so every
        # mutant id at or after the edit refers to a different piece of code.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-DIFFERENT' } -Operators @('BinaryOperator')
        @($why).Count | Should-Be 1
        $why[0] | Should-BeLikeString '*src/a.ps1 changed*'
    }

    It 'refuses when the operator set changed' {
        # Adding an operator renumbers everything, because ids are walk positions.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator', 'BooleanLiteral')
        @($why).Count | Should-Be 1
        $why[0] | Should-BeLikeString '*operator set changed*'
    }

    It 'accepts the same operator set given in a different order' {
        # Order is a config detail, not a semantic difference. Refusing here would be
        # a false alarm, and a guard that cries wolf gets worked around.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport -Operators @('BinaryOperator', 'BooleanLiteral')) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BooleanLiteral', 'BinaryOperator')
        @($why).Count | Should-Be 0
    }

    It 'refuses when a file was added to the mutate set after the report' {
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a'; 'src/b.ps1' = 'hash-b' } -Operators @('BinaryOperator')
        @($why).Count | Should-Be 1
        $why[0] | Should-BeLikeString '*src/b.ps1 is not in the report*'
    }

    It 'refuses a report written before source hashes were recorded, and says it is old' {
        # No schemaVersion either, so "predates provenance recording" is the accurate
        # diagnosis rather than a guess -- see the paired case below.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport -OmitHashes) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator')
        @($why).Count | Should-Be 1
        $why[0] | Should-BeLikeString '*no source hashes*'
        $why[0] | Should-BeLikeString '*predates provenance recording*'
    }

    It 'names the schema when a report has one but still lacks hashes' {
        # The pairing that makes the message worth having (#34). Without a version number
        # the guard could only ever say "too old", and it said exactly that to anyone
        # chaining a recheck -- when the real reason was that recheck reports carried no
        # hashes at all (#20). A schema number tells "too old" from "not that kind".
        $r = Get-FakeReport -OmitHashes
        $r | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1
        $why = Test-PSMutationRecheckCompatible -Report $r `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator')
        $why[0] | Should-BeLikeString '*schema version 1*'
        $why[0] | Should-NotBeLikeString '*predates provenance recording*'
    }

    It 'refuses a report whose sourceHashes property is present but null' {
        # Distinct from the missing-property case above, and the two must not be
        # collapsed: a hand-edited or partially-written report keeps the key with a
        # null value, and treating that as "hashes available" would compare every
        # file against nothing and silently conclude the source is unchanged.
        $r = Get-FakeReport
        $r.sourceHashes = $null
        $why = Test-PSMutationRecheckCompatible -Report $r `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator')
        @($why).Count | Should-Be 1
        $why[0] | Should-BeLikeString '*no source hashes*'
    }

    It 'reports every reason, not just the first' {
        # Someone who fixes one cause and re-runs should not meet the next one only
        # on the following attempt.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'nope' } -Operators @('BooleanLiteral')
        @($why).Count | Should-Be 2
    }
}

Describe 'Select-PSMutationRecheckCandidate' {
    BeforeAll {
        $script:sandbox = Join-Path $TestDrive 'sb'
        New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'src') -Force | Out-Null
        $script:fileA = Join-Path $script:sandbox 'src/a.ps1'
        $script:fileB = Join-Path $script:sandbox 'src/b.ps1'
        # Two mutants on ONE line with the SAME description: `$a -and $b -and $c`
        # yields exactly this, and it is why the match key cannot be file+line+text.
        $script:cands = @(
            [pscustomobject]@{ Id = 1; File = $script:fileA; Line = 10; Description = 'x' }
            [pscustomobject]@{ Id = 2; File = $script:fileA; Line = 10; Description = 'x' }
            [pscustomobject]@{ Id = 3; File = $script:fileA; Line = 20; Description = 'y' }
            [pscustomobject]@{ Id = 1; File = $script:fileB; Line = 10; Description = 'x' }
        )
    }

    It 'keeps only the mutants the report recorded as survivors' {
        $rep = [pscustomobject]@{ survivors = @([pscustomobject]@{ File = 'src/a.ps1'; Id = 3 }) }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should-Be 1
        $out[0].Line  | Should-Be 20
    }

    It 'distinguishes two mutants on the same line with the same description' {
        $rep = [pscustomobject]@{ survivors = @([pscustomobject]@{ File = 'src/a.ps1'; Id = 2 }) }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should-Be 1
        $out[0].Id    | Should-Be 2
    }

    It 'does not confuse the same id in two different files' {
        # Ids restart per file, so the key has to be (File, Id); id alone would also
        # match src/a.ps1's mutant 1.
        $rep = [pscustomobject]@{ survivors = @([pscustomobject]@{ File = 'src/b.ps1'; Id = 1 }) }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should-Be 1
        $out[0].File  | Should-Be $script:fileB
    }

    It 'returns nothing when the previous run had no survivors' {
        $rep = [pscustomobject]@{ survivors = @() }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationSourceHashMap' {
    It 'keys the map by repo-relative path, not the sandbox location' {
        # The report is compared against a future run in a DIFFERENT temp sandbox, so
        # an absolute key would never match twice.
        $sb = Join-Path $TestDrive 'sb2'
        New-Item -ItemType Directory -Path (Join-Path $sb 'src') -Force | Out-Null
        $f = Join-Path $sb 'src/x.ps1'
        Set-Content -Path $f -Value '$a = 1' -NoNewline
        $map = Get-PSMutationSourceHashMap -MutateFiles @($f) -SandboxRoot $sb
        $map.Keys | Should-BeCollection @('src/x.ps1')
        $map['src/x.ps1'] | Should-MatchString '^[0-9a-f]{64}$'
    }
}

Describe 'Get-PSMutationRecheckReportPath' {
    It 'writes beside the full report, never over it' {
        # Overwriting the baseline would destroy the survivor list the recheck was
        # derived from, and leave a truncated result in the file CI reads.
        $full = Join-Path 'reports' 'ps-mutation.json'
        $p = Get-PSMutationRecheckReportPath -ReportPath $full
        (Split-Path $p -Leaf) | Should-Be 'ps-mutation.recheck.json'
        $p | Should-NotBe $full
    }

    It 'keeps the report in the same directory' {
        $p = Get-PSMutationRecheckReportPath -ReportPath (Join-Path -Path 'a' -ChildPath 'b' -AdditionalChildPath 'r.json')
        (Split-Path $p -Parent) | Should-Be (Join-Path 'a' 'b')
    }
}

Describe 'Write-PSMutationRecheckReport' {
    BeforeAll {
        $script:results = @(
            [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 10; Description = 'x'; Status = 'Killed' }
            [pscustomobject]@{ Id = 2; File = 'src/a.ps1'; Line = 20; Description = 'y'; Status = 'Survived' }
        )
    }

    It 'counts what was killed and what still survives' {
        $out = Join-Path $TestDrive 'r.recheck.json'
        $s = Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 5 -SourceReportPath 'reports/full.json'
        $s.Mode           | Should-Be 'Recheck'
        $s.PriorSurvivors | Should-Be 5
        $s.Rechecked      | Should-Be 2
        $s.NowKilled      | Should-Be 1
        $s.StillSurviving | Should-Be 1
    }

    It 'writes no score field, because a filtered set has no score' {
        # 1 of 2 rechecked is not "50%" of the file. Emitting any percentage is how a
        # partial number ends up quoted as a real one, so the field does not exist
        # rather than existing with a caveat next to it.
        $out = Join-Path $TestDrive 'r2.recheck.json'
        Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 5 -SourceReportPath 'f.json' | Out-Null
        $json = Get-Content $out -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Name | Should-NotContainCollection 'mutationScore'
        $json.mode          | Should-Be 'Recheck'
        $json.nowKilled     | Should-Be 1
        $json.priorSurvivors | Should-Be 5
        @($json.stillSurviving).Count | Should-Be 1
    }

    It 'records which report it was derived from' {
        $out = Join-Path $TestDrive 'r3.recheck.json'
        Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 2 -SourceReportPath 'reports/origin.json' | Out-Null
        (Get-Content $out -Raw | ConvertFrom-Json).recheckedFrom | Should-Be 'reports/origin.json'
    }

    It 'reports zero killed when nothing was killed' {
        # The all-survived case is the one a caller acts on (keep writing tests), so
        # it must not collapse to the same output as the all-killed case.
        $out = Join-Path $TestDrive 'r4.recheck.json'
        $none = @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Description = 'x'; Status = 'Survived' })
        $s = Write-PSMutationRecheckReport -Results $none -ReportPath $out -PriorSurvivorCount 1 -SourceReportPath 'f.json'
        $s.NowKilled      | Should-Be 0
        $s.StillSurviving | Should-Be 1
    }
}

Describe 'Get-PSMutationRecheckSummaryLine' {
    BeforeEach {
        $script:results = @(
            [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 10; Description = 'x'; Status = 'Killed' }
            [pscustomobject]@{ Id = 2; File = 'src/a.ps1'; Line = 20; Description = 'y'; Status = 'Survived' }
        )
        $script:summary = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 1; StillSurviving = 1 }
    }

    It 'always says that this is not a mutation score' {
        # This line is the whole safety argument for the feature. Without it the output
        # reads like a measurement, and "6 of 10 killed" gets quoted as a score -- so it is
        # pinned rather than left to reviewer discipline.
        $lines = Get-PSMutationRecheckSummaryLine -Summary $script:summary -Results $script:results -ReportPath 'r.recheck.json'
        ($lines.Text -join "`n") | Should-BeLikeString '*Not a mutation score*'
        ($lines.Text -join "`n") | Should-BeLikeString '*full set*'
    }

    It 'gives the caveats a role a non-console renderer keeps' {
        # Muted, not Rule. Both are DarkGray on a console, so a console-only assertion
        # cannot tell them apart -- but a renderer that drops separators would silently
        # drop the caveat above with them, which is the one line that must never go.
        $lines = Get-PSMutationRecheckSummaryLine -Summary $script:summary -Results $script:results -ReportPath 'r.recheck.json'
        $caveat = @($lines | Where-Object { $_.Text -like '*Not a mutation score*' })
        $caveat[0].Role | Should-Be 'Muted'
    }

    It 'reports counts, never a percentage' {
        $lines = Get-PSMutationRecheckSummaryLine -Summary $script:summary -Results $script:results -ReportPath 'r.recheck.json'
        ($lines.Text -join "`n") | Should-BeLikeString '*1 of 2 previous survivor(s) now killed*'
        ($lines.Text -join "`n") | Should-NotMatchString '\d+([.,]\d+)?\s*%'
    }

    It 'lists the mutants that are still surviving' {
        $lines = Get-PSMutationRecheckSummaryLine -Summary $script:summary -Results $script:results -ReportPath 'r.recheck.json'
        ($lines.Text -join "`n") | Should-BeLikeString '*src/a.ps1:20*y*'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*src/a.ps1:10*'   # killed: not still surviving
    }

    It 'marks the headline Good only when nothing is left surviving' -ForEach @(
        @{ Still = 0; Expected = 'Good' }
        @{ Still = 1; Expected = 'Warn' }
    ) {
        # The role of the HEADLINE line specifically. Asserting over the whole role list
        # cannot discriminate: the still-surviving block is Warn as well, so a headline
        # wrongly marked Good still leaves a Warn in the list and passes.
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 2 - $Still; StillSurviving = $Still }
        $lines = Get-PSMutationRecheckSummaryLine -Summary $s -Results @() -ReportPath 'r.recheck.json'
        $headline = @($lines | Where-Object { $_.Text -like '*now killed*' })
        $headline.Count | Should-Be 1
        $headline[0].Role | Should-Be $Expected
    }

    It 'omits the still-surviving block entirely when nothing survives' {
        # -gt 0, not -ge 0: an empty "Still surviving:" header after a clean recheck reads
        # as though something were still alive.
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 2; StillSurviving = 0 }
        $lines = Get-PSMutationRecheckSummaryLine -Summary $s -Results @() -ReportPath 'r.recheck.json'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*Still surviving*'
    }
}

Describe 'Get-PSMutationSourceHash' {
    It 'differs when a single byte differs' {
        $a = Join-Path $TestDrive 'h1.ps1'; Set-Content -Path $a -Value '$x = 1' -NoNewline
        $b = Join-Path $TestDrive 'h2.ps1'; Set-Content -Path $b -Value '$x = 2' -NoNewline
        $ha = Get-PSMutationSourceHash -Path $a
        $ha | Should-NotBe (Get-PSMutationSourceHash -Path $b)
        $ha | Should-MatchString '^[0-9a-f]{64}$'
    }

    It 'is identical for identical content in different files' {
        $a = Join-Path $TestDrive 'same1.ps1'; Set-Content -Path $a -Value '$x = 1' -NoNewline
        $b = Join-Path $TestDrive 'same2.ps1'; Set-Content -Path $b -Value '$x = 1' -NoNewline
        (Get-PSMutationSourceHash -Path $a) | Should-Be (Get-PSMutationSourceHash -Path $b)
    }
}

Describe 'Invoke-PSMutationRecheckRun' {
    BeforeEach {
        $script:reportFile = Join-Path $TestDrive 'prior.json'
        '{ "survivors": [ { "Id": 1, "File": "src/a.ps1" }, { "Id": 2, "File": "src/a.ps1" } ] }' |
            Set-Content $script:reportFile -Encoding utf8
        $script:plan = @{ TestsByFile = @{}; AllTests = @('tests/a.Tests.ps1') }
    }

    It 'refuses, naming the reason, when the report no longer matches the source' {
        # Mutant ids are AST-walk positions: if the source moved, id 7 in the report
        # is a different mutant now, and a recheck would answer confidently about the
        # wrong one. Refusing is the whole point of the guard.
        Mock Test-PSMutationRecheckCompatible { @('source changed for src/a.ps1') }

        { Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @() -Plan $script:plan `
                -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
                -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet } |
            Should-Throw -ExceptionMessage '*Cannot recheck*source changed for src/a.ps1*regenerate*'
    }

    It 'evaluates only the prior survivors and returns the recheck summary' {
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1', 'cand-2') }
        Mock Invoke-PSMutationLoop { @([pscustomobject]@{ Status = 'Killed' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 1; StillSurviving = 1 } }

        $s = Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a', 'b', 'c') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet

        $s.NowKilled | Should-Be 1
        # The narrowed set is what makes a recheck cheap; passing all candidates
        # through would just be a full run wearing a recheck's label.
        Should-Invoke Invoke-PSMutationLoop -Exactly 1 -ParameterFilter { @($Candidates).Count -eq 2 }
        # The prior survivor COUNT comes from the report, not from the loop results.
        Should-Invoke Write-PSMutationRecheckReport -Exactly 1 -ParameterFilter { $PriorSurvivorCount -eq 2 }
        # -Quiet reaches BOTH emitters -- the progress line and the closing summary -- and
        # is forwarded rather than used to skip the call, since the renderer is what
        # honours it. An unforwarded switch prints for real.
        Should-Invoke Write-PSMutationOutput -Exactly 2 -ParameterFilter { $Quiet }
    }

    It 'reports progress and a summary when not quiet' {
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1', 'cand-2') }
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Status = 'Survived' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 0 } }

        Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') | Out-Null

        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -match 'Rechecking 2 previous survivor' }
        # The closing summary is the second call, and it carries the caveat that stops a
        # partial number being read as a score.
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -like '*Not a mutation score*' }
    }
}

Describe 'a recheck skips what the config already argued cannot be killed' {
    BeforeAll {
        # A declared equivalent appears in `survivors` legitimately -- it survived, it was
        # merely excluded from the denominator -- so the recheck used to re-run it.
        $script:eqReport = [pscustomobject]@{
            survivors = @(
                [pscustomobject]@{ File = 'src/a.ps1'; Id = 1; Function = 'Get-Thing'; Line = 7; Description = '6 -> 7' }
                [pscustomobject]@{ File = 'src/a.ps1'; Id = 2; Function = 'Get-Thing'; Line = 9; Description = '1 -> 2' }
            )
        }
        $script:eqCandidates = @(
            [pscustomobject]@{ File = (Join-Path $TestDrive 'src/a.ps1'); Id = 1 }
            [pscustomobject]@{ File = (Join-Path $TestDrive 'src/a.ps1'); Id = 2 }
        )
    }

    It 'drops a declared equivalent and keeps the genuine survivor' {
        # THE #14 defect, and the pairing is the point: a filter that dropped everything
        # would satisfy "the equivalent is gone" on its own. In the case that prompted the
        # issue this was 16 of 20 mutants -- work re-run to confirm what the config asserts
        # in writing -- and it grows as a repo declares more.
        $eq = [pscustomobject]@{ 'src/a.ps1:Get-Thing:6 -> 7' = 'provably identical output' }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:eqCandidates -Report $script:eqReport `
            -SandboxRoot $TestDrive -Equivalents $eq
        @($out).Count | Should-Be 1
        @($out)[0].Id | Should-Be 2
    }

    It 'keeps both when nothing is declared' {
        # The unfiltered case, so the assertion above cannot pass by the filter being broken.
        $out = Select-PSMutationRecheckCandidate -Candidates $script:eqCandidates -Report $script:eqReport `
            -SandboxRoot $TestDrive -Equivalents $null
        @($out).Count | Should-Be 2
    }

    It 'honours a declaration written in the line form too' {
        # Both key forms are accepted everywhere else; a recheck that only understood one
        # would re-run mutants the scoring path excludes.
        $eq = [pscustomobject]@{ 'src/a.ps1:9:1 -> 2' = 'provably identical output' }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:eqCandidates -Report $script:eqReport `
            -SandboxRoot $TestDrive -Equivalents $eq
        @($out).Count | Should-Be 1
        @($out)[0].Id | Should-Be 1
    }
}

Describe 'the recheck report path does not grow a suffix per round' {
    It 'appends .recheck to a full report' {
        Get-PSMutationRecheckReportPath -ReportPath 'reports/run.json' |
            Should-BeLikeString '*run.recheck.json'
    }

    It 'leaves an already-recheck path alone' {
        # Chaining used to imply run.recheck.recheck.json, then another, then another (#20).
        # Each round overwrites the previous scratch report instead; the FULL report is the
        # one that must never be clobbered, and this function never returns it.
        Get-PSMutationRecheckReportPath -ReportPath 'reports/run.recheck.json' |
            Should-BeLikeString '*run.recheck.json'
        Get-PSMutationRecheckReportPath -ReportPath 'reports/run.recheck.json' |
            Should-NotBeLikeString '*recheck.recheck*'
    }

    It 'never returns the path it was given for a full report' {
        # The guarantee the whole design rests on: a partial run cannot overwrite the
        # baseline CI reads.
        Get-PSMutationRecheckReportPath -ReportPath 'reports/run.json' | Should-NotBeLikeString 'reports/run.json'
    }
}
