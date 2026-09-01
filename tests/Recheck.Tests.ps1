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

    It 'gives the same answer from a filtered set and from the unfiltered SUPERSET' {
        # THE invariant the recheck's dropped coverage rests on (#107, citing #59). Ids are
        # assigned over the unfiltered candidate set, before the coverage filter removes
        # anything, so an unfiltered selection is a superset whose extra members no report
        # lists as survivors -- and the intersection is therefore identical.
        #
        # Asserted over both sets rather than trusting the argument: if numbering ever stops
        # preceding filtering, a recheck would silently evaluate a different set of mutants
        # and report "N of M previous survivors now killed" over it.
        $rep = [pscustomobject]@{ survivors = @(
                [pscustomobject]@{ File = 'src/a.ps1'; Id = 3 }
                [pscustomobject]@{ File = 'src/b.ps1'; Id = 1 }
            )
        }
        # What a coverage-filtered run would have produced: the same ids, minus whatever the
        # filter removed. Id 2 is gone, and no id is renumbered.
        $filtered = @($script:cands | Where-Object { -not ($_.File -eq $script:fileA -and $_.Id -eq 2) })
        $fromSuperset = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        $fromFiltered = Select-PSMutationRecheckCandidate -Candidates $filtered -Report $rep -SandboxRoot $script:sandbox

        # Both halves. The counts alone would agree for two entirely different pairs of mutants.
        @($fromSuperset).Count | Should-Be @($fromFiltered).Count
        @($fromSuperset | ForEach-Object { "$($_.File)|$($_.Id)" }) |
            Should-BeCollection @($fromFiltered | ForEach-Object { "$($_.File)|$($_.Id)" })
        # And it selected something, so the equality is not two empty sets agreeing.
        @($fromSuperset).Count | Should-Be 2
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

    It 'shares ExitCode and FailureReason with a full run, so a generic caller can branch' {
        # The two shapes used to have NO field in common, and the absence failed in both
        # directions at once. The idiom this module's own README teaches --
        # `if ($result.ExitCode -ne 0) { throw }` -- compared $null against 0 and threw on a
        # perfectly successful recheck; `exit $result.ExitCode` became `exit $null`, which is 0,
        # and passed even with every prior survivor still alive. One failed loudly, the other
        # passed silently, from the same missing field.
        $out = Join-Path $TestDrive 'r-exit.recheck.json'
        $s = Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 5 -SourceReportPath 'reports/full.json'
        $s.ExitCode | Should-Be 0
        $s.FailureReason | Should-Be 'None'
    }

    It 'still exits 0 when everything rechecked is STILL surviving' {
        # Paired with the case above, and the more important half: a recheck applies no
        # thresholds by design. It answers "is this one dead yet" over a set somebody chose, and
        # a verdict over a chosen subset is exactly the filtered number this module exists to
        # stop people quoting. StillSurviving is the answer to read.
        $allAlive = @(
            [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 10; Description = 'x'; Status = 'Survived' }
            [pscustomobject]@{ Id = 2; File = 'src/a.ps1'; Line = 20; Description = 'y'; Status = 'Survived' }
        )
        $out = Join-Path $TestDrive 'r-alive.recheck.json'
        $s = Write-PSMutationRecheckReport -Results $allAlive -ReportPath $out `
            -PriorSurvivorCount 5 -SourceReportPath 'reports/full.json'
        $s.StillSurviving | Should-Be 2
        $s.ExitCode | Should-Be 0
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
        # Carries `mutants` as well as `survivors`, because a real report does and the merge path
        # reads it. A fixture holding only survivors bound $null into the merge and failed for a
        # reason that had nothing to do with what was being tested.
        '{ "survivors": [ { "Id": 1, "File": "src/a.ps1" }, { "Id": 2, "File": "src/a.ps1" } ],
           "mutants": [ { "Id": 1, "File": "src/a.ps1", "Function": "F", "Description": "d", "Status": "Survived", "Line": 1, "Operator": "X" },
                        { "Id": 2, "File": "src/a.ps1", "Function": "F", "Description": "e", "Status": "Survived", "Line": 2, "Operator": "X" } ] }' |
            Set-Content $script:reportFile -Encoding utf8
        $script:plan = @{ TestsByFile = @{}; AllTests = @('tests/a.Tests.ps1') }
        # Deliberately NOT mocking Test-PSMutationAnnotationHost here. Every test below that
        # reaches the render path states its own answer, because a mock in BeforeEach plus a
        # different one in the It is a bet on which wins -- and that bet paid differently on
        # the runner (pwsh 7.4) than it did locally (7.6). A test whose result depends on mock
        # precedence is not a test, it is a coin toss with good intentions.
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

    It 'merges into the baseline under -MergeIntoBaseline, and says what it carried over' {
        # The recheck's whole point is that it does NOT touch the baseline, so the one path that
        # does needs driving end to end -- the merged document is asserted on its own above, and
        # this covers the run choosing to write it and reporting what it did.
        Mock Test-PSMutationAnnotationHost { $false }
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { , @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1') }
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Function = 'F'
                    Description = 'd'; Status = 'Killed'; Line = 1; Operator = 'X'; KilledBy = @() }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 1; StillSurviving = 0 } }
        Mock Get-PSMutationMergeFault { , @() }
        Mock Save-PSMutationReportDocument { }

        Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet -MergeIntoBaseline | Out-Null

        # Written back to the BASELINE path, not the recheck path -- that is the whole difference.
        Should-Invoke Save-PSMutationReportDocument -Times 1 -ParameterFilter { $ReportPath -eq $script:reportFile }
        # The COUNT, not just the phrase. The baseline holds two mutants and one was rechecked, so
        # exactly one is carried over -- and a message that got the arithmetic backwards would
        # still contain the words.
        Should-Invoke Write-PSMutationOutput -Times 1 -ParameterFilter {
            (($Lines | ForEach-Object { $_.Text }) -join ' ') -like '*1 mutant(s) carried over unverified*'
        }
    }

    It 'refuses the merge, and writes nothing, when the tests may have changed' {
        # Refused rather than warned about: a merged report carries a score, and everything
        # downstream reads it as a measurement.
        Mock Test-PSMutationAnnotationHost { $false }
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { , @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1') }
        Mock Invoke-PSMutationLoop { , @([pscustomobject]@{ Status = 'Killed' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 1; StillSurviving = 0 } }
        Mock Get-PSMutationMergeFault { , @('tests/a.Tests.ps1 is shorter than when the baseline was written') }
        Mock Save-PSMutationReportDocument { }

        { Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
                -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
                -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet -MergeIntoBaseline } |
            Should-Throw -ExceptionMessage '*Run the full set to get a report that measured all of them*'
        Should-Invoke Save-PSMutationReportDocument -Times 0
    }

    It 'evaluates only the prior survivors and returns the recheck summary' {
        # Not a CI: this counts render calls, and the annotation path adds one.
        Mock Test-PSMutationAnnotationHost { $false }
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
        #
        # This filter is well-defined because EVERY renderer call binds -Quiet, including the
        # annotation one, which passes -Quiet:$false. Omit the switch anywhere and $Quiet here
        # becomes a scope-resolution question rather than a value, which is how a filter starts
        # selecting a different set of calls on somebody else's PowerShell.
        Should-Invoke Write-PSMutationOutput -Exactly 2 -ParameterFilter { $Quiet }
    }

    It 'annotates what is still surviving when it runs under a CI, even quietly' {
        # -Quiet exists so a CI log is not several hundred progress lines long, and CI is
        # exactly where a survivor most needs to be seen. Suppressing both leaves a failed gate
        # printing a number and nothing else. So the annotation call deliberately does NOT
        # forward -Quiet, and this is the assertion that keeps it that way: three render calls
        # under Actions against the two that -Quiet alone produces.
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1') }
        # A survivor with a real file and line, so the annotation is a THING this test can name
        # rather than a call it has to infer.
        Mock Invoke-PSMutationLoop {
            @([pscustomobject]@{ Status = 'Survived'; File = 'src/a.ps1'; Line = 7; Description = '-and -> -or' })
        }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 0; StillSurviving = 1 } }
        Mock Test-PSMutationAnnotationHost { $true }
        Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet | Out-Null
        # Filtered on what the call CARRIES, not on whether -Quiet was passed. An unbound switch
        # inside a ParameterFilter is a scope-resolution question -- $false, or the caller's own
        # $Quiet further up -- and the answer differed between the runner's PowerShell and this
        # one, so the assertion passed here and failed there. Assert the thing, not a proxy.
        # -not $Quiet is part of the claim, not decoration: the call being MADE is not the
        # point if it was made quietly, because the renderer honours the switch and nothing
        # would reach the log. Silencing this call is a one-character change that leaves every
        # other assertion here green.
        #
        # And it is well-defined to ask: every renderer call in src/ binds -Quiet, including
        # this one, which passes -Quiet:$false. Before that it was a scope-resolution question.
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter {
            @($Lines).Count -gt 0 -and @($Lines)[0].Role -eq 'Annotation' -and -not $Quiet
        }
    }

    It 'survives a CI run that has nothing to annotate' {
        # The green path. Get-PSMutationAnnotationLine yields NO lines when nothing survived,
        # and -Lines accepts an empty collection but not $null -- so without an @() wrap the
        # run that passed is the one that throws, in CI only, where it is hardest to reproduce.
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1') }
        Mock Invoke-PSMutationLoop { @([pscustomobject]@{ Status = 'Killed' }) }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 1; StillSurviving = 0 } }
        Mock Test-PSMutationAnnotationHost { $true }
        $s = Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet
        $s.NowKilled | Should-Be 1
    }

    It 'annotates nothing when it is not running under a CI' {
        # The paired half. Without it the test above passes against a run that annotates
        # unconditionally, which would put workflow-command noise in front of every developer.
        Mock Write-PSMutationOutput { }
        Mock Test-PSMutationRecheckCompatible { @() }
        Mock Select-PSMutationRecheckCandidate { @('cand-1') }
        # A survivor WITH a file, exactly like its pair above. With a row that has none, no
        # annotation is produced under either answer from the host check -- so the fixture
        # could not tell "not a CI" from "a CI with nothing to say", and the guard could be
        # forced either way without this test noticing.
        Mock Invoke-PSMutationLoop {
            @([pscustomobject]@{ Status = 'Survived'; File = 'src/a.ps1'; Line = 7; Description = '-and -> -or' })
        }
        Mock Get-PSMutationRecheckReportPath { Join-Path $TestDrive 'out.recheck.json' }
        Mock Write-PSMutationRecheckReport { [pscustomobject]@{ NowKilled = 0; StillSurviving = 1 } }
        Mock Test-PSMutationAnnotationHost { $false }
        Invoke-PSMutationRecheckRun -RecheckFrom $script:reportFile -Candidates @('a') -Plan $script:plan `
            -SourceHashes @{} -Operators @('BinaryOperator') -TimeoutSeconds 5 `
            -SandboxRoot $TestDrive -ReportPath (Join-Path $TestDrive 'out.json') -Quiet | Out-Null
        # The same filter as its pair above, so the two read as one claim about one thing.
        Should-NotInvoke Write-PSMutationOutput -ParameterFilter {
            @($Lines).Count -gt 0 -and @($Lines)[0].Role -eq 'Annotation'
        }
    }

    It 'reports progress and a summary when not quiet' {
        # Not a CI: annotations would add a render call this test does not expect.
        Mock Test-PSMutationAnnotationHost { $false }
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

Describe 'the recheck gate refuses a report about a different run' {
    BeforeAll {
        function script:Rep([hashtable]$Hashes) {
            $h = [ordered]@{}
            foreach ($k in ($Hashes.Keys | Sort-Object)) { $h[$k] = $Hashes[$k] }
            [pscustomobject]@{ schemaVersion = 1; operators = @('BinaryOperator'); sourceHashes = [pscustomobject]$h }
        }
    }

    It 'refuses a report covering a file this run does not mutate' {
        # The hole this closes. The gate walked only the CURRENT mutate set, so a file added or
        # changed was caught and a file the REPORT covers but this run does not was invisible.
        # -RecheckFrom takes the report's whole survivor list, so the run would evaluate that
        # file's survivors with no tests mapped for it and no copy in the sandbox, then report
        # "N of M previous survivors now killed" over a set it never had.
        $reasons = Test-PSMutationRecheckCompatible -Report (script:Rep @{ 'src/a.ps1' = 'h1'; 'src/b.ps1' = 'h2' }) `
            -SourceHashes @{ 'src/a.ps1' = 'h1' } -Operators @('BinaryOperator')
        ($reasons -join ' ') | Should-MatchString 'src/b.ps1 is in the report but not in this run'
    }

    It 'accepts a report describing exactly this run' {
        # The pairing. Without it, a gate that refused everything would satisfy the test above --
        # and this gate's whole job is to let a legitimate recheck through.
        $reasons = Test-PSMutationRecheckCompatible -Report (script:Rep @{ 'src/a.ps1' = 'h1' }) `
            -SourceHashes @{ 'src/a.ps1' = 'h1' } -Operators @('BinaryOperator')
        @($reasons).Count | Should-Be 0
    }

    It 'still catches the direction it always caught' {
        # Both directions now, asserted together so neither can be lost while the other passes.
        $reasons = Test-PSMutationRecheckCompatible -Report (script:Rep @{ 'src/a.ps1' = 'h1' }) `
            -SourceHashes @{ 'src/a.ps1' = 'h1'; 'src/b.ps1' = 'h2' } -Operators @('BinaryOperator')
        ($reasons -join ' ') | Should-MatchString 'src/b.ps1 is not in the report'
    }

    It 'names every file that does not belong, not just the first' {
        # A reader fixes a config, and being told about one file at a time turns one edit into
        # several runs of something that takes minutes.
        $reasons = Test-PSMutationRecheckCompatible -Report (script:Rep @{ 'src/a.ps1' = 'h1'; 'src/b.ps1' = 'h2'; 'src/c.ps1' = 'h3' }) `
            -SourceHashes @{ 'src/a.ps1' = 'h1' } -Operators @('BinaryOperator')
        ($reasons -join ' ') | Should-MatchString 'src/b.ps1'
        ($reasons -join ' ') | Should-MatchString 'src/c.ps1'
    }
}

Describe 'Get-PSMutationMergeFault' {
    BeforeAll {
        # The value is a bare integer, exactly as Write-PSMutationReport records it. An earlier
        # fixture nested it in an object, and the gate read `.length` off it -- which PowerShell
        # answers as 1 for any scalar, so the comparison became "is 150 less than 1" and never
        # fired. The fixture agreed with the code and neither agreed with the report.
        $script:priorTests = [pscustomobject]@{ 'tests/a.Tests.ps1' = 1000 }
    }

    It 'permits a merge when a test file GREW' {
        # The loop this exists for: write a test, re-run, fold the result back. Refusing whenever
        # a test file changed would refuse exactly that, which is why the signal is length rather
        # than a hash.
        (Get-PSMutationMergeFault -BaselineTests $script:priorTests -CurrentTests @{ 'tests/a.Tests.ps1' = 1200 }).Count |
            Should-Be 0
    }

    It 'permits a merge when nothing changed at all' {
        (Get-PSMutationMergeFault -BaselineTests $script:priorTests -CurrentTests @{ 'tests/a.Tests.ps1' = 1000 }).Count |
            Should-Be 0
    }

    It 'refuses when a test file SHRANK' {
        # Something was removed, and removing an assertion is what revives a mutant the baseline
        # recorded as killed -- which a recheck never looks at.
        (Get-PSMutationMergeFault -BaselineTests $script:priorTests -CurrentTests @{ 'tests/a.Tests.ps1' = 800 }) -join ' ' |
            Should-MatchString 'is shorter than when the baseline was written \(800 bytes against 1000\)'
    }

    It 'refuses when a test file is gone' {
        (Get-PSMutationMergeFault -BaselineTests $script:priorTests -CurrentTests @{}) -join ' ' |
            Should-MatchString 'was in the baseline and is gone'
    }

    It 'refuses a baseline that predates the field' {
        # An older report says nothing about its tests, so there is no way to tell whether a
        # carried-over status still holds. Silence is not consent.
        (Get-PSMutationMergeFault -BaselineTests $null -CurrentTests @{ 'tests/a.Tests.ps1' = 1000 }) -join ' ' |
            Should-MatchString 'records nothing about its test files'
    }

    It 'ignores a test file that is new since the baseline' {
        # Adding a test cannot revive a mutant the baseline killed, so a file the baseline never
        # saw is not a reason to refuse.
        (Get-PSMutationMergeFault -BaselineTests $script:priorTests `
                -CurrentTests @{ 'tests/a.Tests.ps1' = 1000; 'tests/new.Tests.ps1' = 50 }).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationMergedMutant' {
    BeforeAll {
        function script:Mu([string]$Desc, [string]$Status) {
            [pscustomobject]@{ Id = 1; File = 'a.ps1'; Function = 'F'; Description = $Desc
                Status = $Status; Line = 1; Operator = 'X'; KilledBy = @() }
        }
    }

    It 'applies the rechecked verdict and leaves everything else alone' {
        $merged = Get-PSMutationMergedMutant `
            -Baseline @((script:Mu -Desc 'd1' -Status 'Survived'), (script:Mu -Desc 'd2' -Status 'Survived'), (script:Mu -Desc 'd3' -Status 'Killed')) `
            -Rechecked @((script:Mu -Desc 'd1' -Status 'Killed'))
        (($merged | ForEach-Object { "$($_.Description)=$($_.Status)" }) -join ',') |
            Should-Be 'd1=Killed,d2=Survived,d3=Killed'
    }

    It 'keeps every baseline mutant, including ones the recheck never saw' {
        # A merge is a baseline with verdicts applied, not a recheck padded out. Dropping the
        # unrechecked rows would silently shrink the denominator and raise the score.
        $merged = Get-PSMutationMergedMutant `
            -Baseline @((script:Mu -Desc 'd1' -Status 'Survived'), (script:Mu -Desc 'd2' -Status 'Killed')) `
            -Rechecked @()
        @($merged).Count | Should-Be 2
    }
}

Describe 'Get-PSMutationMergedBaseline' {
    BeforeAll {
        function script:Doc {
            [pscustomobject]@{
                schemaVersion = 1; mutationScore = 33.3; total = 3; killed = 1; survived = 2
                timedOut = 0; declaredEquivalent = 0
                mutants = @(
                    [pscustomobject]@{ Id = 1; File = 'a.ps1'; Function = 'F'; Description = 'd1'; Status = 'Survived'; Line = 1; Operator = 'X'; KilledBy = @() }
                    [pscustomobject]@{ Id = 2; File = 'a.ps1'; Function = 'F'; Description = 'd2'; Status = 'Survived'; Line = 2; Operator = 'X'; KilledBy = @() }
                    [pscustomobject]@{ Id = 3; File = 'a.ps1'; Function = 'F'; Description = 'd3'; Status = 'Killed'; Line = 3; Operator = 'X'; KilledBy = @() })
                survivors = @()
            }
        }
        $script:killedOne = @([pscustomobject]@{ Id = 1; File = 'a.ps1'; Function = 'F'
                Description = 'd1'; Status = 'Killed'; Line = 1; Operator = 'X'; KilledBy = @('t') })
    }

    It 'RE-SCORES from the merged rows' {
        # Writing new verdicts under the old number leaves the document self-contradictory, which
        # is worse than not merging: the score is what everything downstream reads.
        $doc = Get-PSMutationMergedBaseline -Baseline (script:Doc) -Rechecked $script:killedOne
        $doc.mutationScore | Should-Be 66.7
        $doc.killed | Should-Be 2
        $doc.survived | Should-Be 1
    }

    It 'rebuilds the survivor list from the merged rows' {
        # The list a later -RecheckFrom reads. Left stale it would seed the next round with a
        # mutant this one just killed.
        $doc = Get-PSMutationMergedBaseline -Baseline (script:Doc) -Rechecked $script:killedOne
        @($doc.survivors | ForEach-Object { $_.Description }) | Should-BeCollection @('d2')
    }

    It 'records the caveat IN the artifact, not only on the console' {
        # Most of a merged report was measured by an earlier run. A reader has to be able to see
        # what fraction of the score this run actually stood behind, from the file itself.
        $doc = Get-PSMutationMergedBaseline -Baseline (script:Doc) -Rechecked $script:killedOne
        $doc.mergedFrom | Should-Be 1
        $doc.carriedOverUnverified | Should-Be 2
    }

    It 'honours the equivalence declarations when re-scoring' {
        # The score is a fold over the rows and excuses declared mutants; re-scoring without them
        # would report a different number from the run that produced the baseline.
        $eq = [pscustomobject]@{ 'a.ps1:F:d2' = 'cannot be killed' }
        $doc = Get-PSMutationMergedBaseline -Baseline (script:Doc) -Rechecked $script:killedOne -Equivalents $eq
        $doc.declaredEquivalent | Should-Be 1
        $doc.mutationScore | Should-Be 100
    }
}

Describe 'Get-PSMutationTestFileLength' {
    It 'records a file that exists and omits one that does not' {
        # Both arms. A present file must be measured, and a missing one must be ABSENT rather
        # than zero -- the merge gate reads absence as "was in the baseline and is gone", which is
        # the honest answer, while a zero would read as a file that shrank to nothing.
        $dir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $real = Join-Path $dir 'tests/there.Tests.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $real) -Force | Out-Null
        Set-Content -LiteralPath $real -Value 'x' -NoNewline

        $map = Get-PSMutationTestFileLength -Path @($real, (Join-Path $dir 'tests/gone.Tests.ps1')) -SandboxRoot $dir
        $map.Keys | Should-BeCollection @('tests/there.Tests.ps1')
        $map['tests/there.Tests.ps1'] | Should-Be 1
    }

    It 'keys relative to the sandbox, so two runs can be compared' {
        # The absolute path carries the run's pid and its random sandbox token, so a map keyed
        # that way can never match a later run's -- measured, the merge gate saw a baseline whose
        # every test file was "gone".
        $dir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'tests') -Force | Out-Null
        $f = Join-Path $dir 'tests/a.Tests.ps1'
        Set-Content -LiteralPath $f -Value 'xy' -NoNewline
        (Get-PSMutationTestFileLength -Path @($f) -SandboxRoot $dir).Keys |
            Should-BeCollection @('tests/a.Tests.ps1')
    }
}

Describe 'Select-PSMutationResumeCandidate' {
    BeforeAll {
        $script:rRoot = [System.IO.Path]::GetTempPath()
        function script:ResumeCand([int]$Id, [string]$Leaf = 'a.ps1') {
            [pscustomobject]@{ Id = $Id; File = (Join-Path $script:rRoot $Leaf) }
        }
        function script:ResumeReport([object[]]$Rows) {
            [pscustomobject]@{ mode = 'Partial'; mutants = $Rows }
        }
    }

    It 'keeps exactly what the prior report did not record' {
        # The INVERSE of the recheck selector. A resume finishes a measurement, so what it wants
        # is everything the interrupted run never reached.
        $report = script:ResumeReport @(
            [pscustomobject]@{ File = 'a.ps1'; Id = 1 }
            [pscustomobject]@{ File = 'a.ps1'; Id = 2 })
        $left = Select-PSMutationResumeCandidate -SandboxRoot $script:rRoot `
            -Candidates @((script:ResumeCand 1), (script:ResumeCand 2), (script:ResumeCand 3)) -Report $report
        @($left | ForEach-Object { $_.Id }) | Should-BeCollection @(3)
    }

    It 'matches on FILE as well as id, so two files do not share a numbering' {
        # Ids are per-file AST-walk positions, so id 1 exists in every file. Keyed on the id
        # alone, recording a.ps1:1 would silently retire b.ps1:1 as well -- a mutant nobody
        # evaluated, carried into the score with whatever status its namesake had.
        $report = script:ResumeReport @([pscustomobject]@{ File = 'a.ps1'; Id = 1 })
        $left = Select-PSMutationResumeCandidate -SandboxRoot $script:rRoot `
            -Candidates @((script:ResumeCand 1 'a.ps1'), (script:ResumeCand 1 'b.ps1')) -Report $report
        @($left | ForEach-Object { ConvertFrom-PSMutationSandboxPath -Path $_.File -SandboxRoot $script:rRoot }) |
            Should-BeCollection @('b.ps1')
    }

    It 'keeps everything when the interrupted run recorded nothing' {
        # The earliest possible interruption: stopped before the first mutant finished. A resume
        # from it is an ordinary run, and must not be an empty one.
        $left = Select-PSMutationResumeCandidate -SandboxRoot $script:rRoot `
            -Candidates @((script:ResumeCand 1), (script:ResumeCand 2)) -Report (script:ResumeReport @())
        @($left).Count | Should-Be 2
    }

    It 'returns an ARRAY when everything was already recorded, not $null' {
        # The comma-wrap. A resume from a report that got all the way to the last mutant leaves
        # nothing to run, and an unwrapped empty result unrolls to $null -- which the loop's
        # mandatory -Candidates would then refuse, turning a legitimate outcome into a crash.
        $report = script:ResumeReport @([pscustomobject]@{ File = 'a.ps1'; Id = 1 })
        $left = Select-PSMutationResumeCandidate -SandboxRoot $script:rRoot `
            -Candidates @((script:ResumeCand 1)) -Report $report
        @($left).Count | Should-Be 0
        $left -is [array] | Should-BeTrue
    }

    It 'does NOT skip declared equivalents, unlike a recheck' {
        # The two selectors differ here on purpose. A recheck re-runs survivors, and re-running
        # one the config argues cannot be killed is guaranteed-wasted work. A resume is completing
        # a measurement: a declaration is a claim checked against a RESULT, and a mutant nobody
        # evaluated has no result to check it against. This selector takes no -Equivalents at all,
        # which is what makes that impossible to get wrong.
        (Get-Command Select-PSMutationResumeCandidate).Parameters.Keys | Should-NotContainCollection 'Equivalents'
    }
}

Describe 'Get-PSMutationResumeFault' {
    BeforeAll {
        $script:okHashes = @{ 'a.ps1' = 'h1' }
        $script:okTests = @{ 'tests/a.Tests.ps1' = 100 }
        function script:PartialFor([hashtable]$Over = @{}) {
            $d = @{ mode = 'Partial'; sourceHashes = [pscustomobject]@{ 'a.ps1' = 'h1' }
                operators = @('BinaryOperator'); testFiles = [pscustomobject]@{ 'tests/a.Tests.ps1' = 100 } }
            foreach ($k in $Over.Keys) { $d[$k] = $Over[$k] }
            return [pscustomobject]$d
        }
        function script:ResumeFaultFor($Report) {
            Get-PSMutationResumeFault -Report $Report -SourceHashes $script:okHashes `
                -Operators @('BinaryOperator') -CurrentTests $script:okTests
        }
    }

    It 'says nothing when the report is a partial one describing this source' {
        script:ResumeFaultFor (script:PartialFor) | Should-Be ''
    }

    It 'refuses a report that is not PARTIAL, and says which it is' -ForEach @(
        @{ Mode = 'Recheck' }
        @{ Mode = 'Changed' }
        @{ Mode = $null }
    ) {
        # A full report has nothing left to evaluate and a recheck report describes a different
        # kind of run. Asked FIRST because every check below assumes the document is this shape.
        # $null covers the ordinary full report, which carries no mode at all.
        script:ResumeFaultFor (script:PartialFor @{ mode = $Mode }) |
            Should-MatchString 'not .Partial.'
    }

    It 'refuses when the source moved under the recorded ids' {
        # Mutant ids are AST-walk positions. Asked with the same function -RecheckFrom uses: a
        # second implementation would be a second answer to one question.
        script:ResumeFaultFor (script:PartialFor @{ sourceHashes = [pscustomobject]@{ 'a.ps1' = 'DIFFERENT' } }) |
            Should-MatchString 'a.ps1 changed since the report was written'
    }

    It 'refuses when the operator set changed' {
        script:ResumeFaultFor (script:PartialFor @{ operators = @('BooleanLiteral') }) |
            Should-MatchString 'operator set changed'
    }

    It 'refuses when a mapped test file SHRANK, because that is what revives a mutant' {
        # The check the issue behind this feature did not name. A resume carries over every
        # verdict in the report, and adding a test cannot revive a mutant the earlier run killed
        # -- editing or deleting one can, and a resume never re-looks. Same decision
        # -MergeIntoBaseline uses, asked unchanged.
        Get-PSMutationResumeFault -Report (script:PartialFor) -SourceHashes $script:okHashes `
            -Operators @('BinaryOperator') -CurrentTests @{ 'tests/a.Tests.ps1' = 40 } |
            Should-MatchString 'carries those verdicts over without re-running them'
    }

    It 'ALLOWS a test file that grew, or the loop this serves would be refused' {
        # Growth permits rather than certifies -- see Get-PSMutationMergeFault. Paired with the
        # shrink case above so neither can pass by the guard being inert.
        Get-PSMutationResumeFault -Report (script:PartialFor) -SourceHashes $script:okHashes `
            -Operators @('BinaryOperator') -CurrentTests @{ 'tests/a.Tests.ps1' = 400 } | Should-Be ''
    }

    It 'asks about the SOURCE before it asks about the tests' {
        # Order is the message's quality. A report numbered against different source cannot have
        # its verdicts carried over at all, so complaining about a test file first would send the
        # reader to look at the wrong thing.
        Get-PSMutationResumeFault -Report (script:PartialFor @{ operators = @('BooleanLiteral') }) `
            -SourceHashes $script:okHashes -Operators @('BinaryOperator') `
            -CurrentTests @{ 'tests/a.Tests.ps1' = 40 } | Should-MatchString 'operator set changed'
    }
}

Describe 'Get-PSMutationResumeState' {
    BeforeAll {
        $script:sRoot = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-resume-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:sRoot -Force | Out-Null
        $script:sPlan = @{ AllTests = @() }
        $script:sCands = @(
            [pscustomobject]@{ Id = 1; File = (Join-Path $script:sRoot 'a.ps1') }
            [pscustomobject]@{ Id = 2; File = (Join-Path $script:sRoot 'a.ps1') })
        function script:WriteResumeReport($Document) {
            $p = Join-Path $script:sRoot "r-$([System.Guid]::NewGuid().ToString('N')).json"
            $Document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding utf8
            return $p
        }
        function script:StateFor([string]$Path) {
            Get-PSMutationResumeState -ResumeFrom $Path -Candidates $script:sCands -Plan $script:sPlan `
                -SandboxRoot $script:sRoot -SourceHashes @{} -Operators @('BinaryOperator')
        }
    }
    AfterAll { Remove-Item $script:sRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'hands an ORDINARY run its candidates back untouched' {
        # The whole reason this returns the same shape either way: Invoke-PSMutationRun was
        # already at 13 of a ceiling of 15, and a feature that spends two of the branches it has
        # left on asking whether it is switched on has none for the feature.
        $s = script:StateFor ''
        $s.IsResume | Should-BeFalse
        @($s.Candidates).Count | Should-Be 2
        @($s.PriorRows).Count | Should-Be 0
        @($s.Lines).Count | Should-Be 0
    }

    It 'narrows the candidates and carries the recorded rows' {
        $path = script:WriteResumeReport ([pscustomobject]@{
                mode = 'Partial'; operators = @('BinaryOperator')
                sourceHashes = [pscustomobject]@{}; testFiles = [pscustomobject]@{}
                mutants = @([pscustomobject]@{ File = 'a.ps1'; Id = 1; Status = 'Killed' })
            })
        $s = script:StateFor $path
        $s.IsResume | Should-BeTrue
        @($s.Candidates | ForEach-Object { $_.Id }) | Should-BeCollection @(2)
        @($s.PriorRows).Count | Should-Be 1
    }

    It 'says what it is doing, because a resumed run is otherwise indistinguishable from a short one' {
        $path = script:WriteResumeReport ([pscustomobject]@{
                mode = 'Partial'; operators = @('BinaryOperator')
                sourceHashes = [pscustomobject]@{}; testFiles = [pscustomobject]@{}
                mutants = @([pscustomobject]@{ File = 'a.ps1'; Id = 1; Status = 'Killed' })
            })
        $line = @((script:StateFor $path).Lines)[0]
        $line.Text | Should-MatchString 'RESUMED from'
        $line.Text | Should-MatchString '1 mutant\(s\) carried over'
        $line.Text | Should-MatchString '1 left to evaluate'
    }

    It 'THROWS rather than returning a fault, and names the report' {
        # The same choice -RecheckFrom makes: a resume that cannot be trusted is a fault in what
        # the caller asked for, not a verdict about the code. Returning a score built on it would
        # be the confident-number-over-a-subset failure this module exists to prevent.
        $path = script:WriteResumeReport ([pscustomobject]@{ mode = 'Recheck'; mutants = @() })
        { script:StateFor $path } | Should-Throw -ExceptionMessage '*Cannot resume from*not ''Partial''*'
    }
}
