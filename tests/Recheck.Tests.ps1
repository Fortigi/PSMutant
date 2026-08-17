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
        @($why).Count | Should -Be 0
    }

    It 'refuses when a mutated file changed' {
        # The whole point of the guard: same file name, different bytes, so every
        # mutant id at or after the edit refers to a different piece of code.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-DIFFERENT' } -Operators @('BinaryOperator')
        @($why).Count | Should -Be 1
        $why[0] | Should -BeLike '*src/a.ps1 changed*'
    }

    It 'refuses when the operator set changed' {
        # Adding an operator renumbers everything, because ids are walk positions.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator', 'BooleanLiteral')
        @($why).Count | Should -Be 1
        $why[0] | Should -BeLike '*operator set changed*'
    }

    It 'accepts the same operator set given in a different order' {
        # Order is a config detail, not a semantic difference. Refusing here would be
        # a false alarm, and a guard that cries wolf gets worked around.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport -Operators @('BinaryOperator', 'BooleanLiteral')) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BooleanLiteral', 'BinaryOperator')
        @($why).Count | Should -Be 0
    }

    It 'refuses when a file was added to the mutate set after the report' {
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a'; 'src/b.ps1' = 'hash-b' } -Operators @('BinaryOperator')
        @($why).Count | Should -Be 1
        $why[0] | Should -BeLike '*src/b.ps1 is not in the report*'
    }

    It 'refuses a report written before source hashes were recorded' {
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport -OmitHashes) `
            -SourceHashes @{ 'src/a.ps1' = 'hash-a' } -Operators @('BinaryOperator')
        @($why).Count | Should -Be 1
        $why[0] | Should -BeLike '*predates source-hash recording*'
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
        @($why).Count | Should -Be 1
        $why[0] | Should -BeLike '*predates source-hash recording*'
    }

    It 'reports every reason, not just the first' {
        # Someone who fixes one cause and re-runs should not meet the next one only
        # on the following attempt.
        $why = Test-PSMutationRecheckCompatible -Report (Get-FakeReport) `
            -SourceHashes @{ 'src/a.ps1' = 'nope' } -Operators @('BooleanLiteral')
        @($why).Count | Should -Be 2
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
        @($out).Count | Should -Be 1
        $out[0].Line  | Should -Be 20
    }

    It 'distinguishes two mutants on the same line with the same description' {
        $rep = [pscustomobject]@{ survivors = @([pscustomobject]@{ File = 'src/a.ps1'; Id = 2 }) }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should -Be 1
        $out[0].Id    | Should -Be 2
    }

    It 'does not confuse the same id in two different files' {
        # Ids restart per file, so the key has to be (File, Id); id alone would also
        # match src/a.ps1's mutant 1.
        $rep = [pscustomobject]@{ survivors = @([pscustomobject]@{ File = 'src/b.ps1'; Id = 1 }) }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should -Be 1
        $out[0].File  | Should -Be $script:fileB
    }

    It 'returns nothing when the previous run had no survivors' {
        $rep = [pscustomobject]@{ survivors = @() }
        $out = Select-PSMutationRecheckCandidate -Candidates $script:cands -Report $rep -SandboxRoot $script:sandbox
        @($out).Count | Should -Be 0
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
        $map.Keys | Should -Be @('src/x.ps1')
        $map['src/x.ps1'] | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Get-PSMutationRecheckReportPath' {
    It 'writes beside the full report, never over it' {
        # Overwriting the baseline would destroy the survivor list the recheck was
        # derived from, and leave a truncated result in the file CI reads.
        $full = Join-Path 'reports' 'ps-mutation.json'
        $p = Get-PSMutationRecheckReportPath -ReportPath $full
        (Split-Path $p -Leaf) | Should -Be 'ps-mutation.recheck.json'
        $p | Should -Not -Be $full
    }

    It 'keeps the report in the same directory' {
        $p = Get-PSMutationRecheckReportPath -ReportPath (Join-Path -Path 'a' -ChildPath 'b' -AdditionalChildPath 'r.json')
        (Split-Path $p -Parent) | Should -Be (Join-Path 'a' 'b')
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
        $s.Mode           | Should -Be 'Recheck'
        $s.PriorSurvivors | Should -Be 5
        $s.Rechecked      | Should -Be 2
        $s.NowKilled      | Should -Be 1
        $s.StillSurviving | Should -Be 1
    }

    It 'writes no score field, because a filtered set has no score' {
        # 1 of 2 rechecked is not "50%" of the file. Emitting any percentage is how a
        # partial number ends up quoted as a real one, so the field does not exist
        # rather than existing with a caveat next to it.
        $out = Join-Path $TestDrive 'r2.recheck.json'
        Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 5 -SourceReportPath 'f.json' | Out-Null
        $json = Get-Content $out -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Name | Should -Not -Contain 'mutationScore'
        $json.mode          | Should -Be 'Recheck'
        $json.nowKilled     | Should -Be 1
        $json.priorSurvivors | Should -Be 5
        @($json.stillSurviving).Count | Should -Be 1
    }

    It 'records which report it was derived from' {
        $out = Join-Path $TestDrive 'r3.recheck.json'
        Write-PSMutationRecheckReport -Results $script:results -ReportPath $out `
            -PriorSurvivorCount 2 -SourceReportPath 'reports/origin.json' | Out-Null
        (Get-Content $out -Raw | ConvertFrom-Json).recheckedFrom | Should -Be 'reports/origin.json'
    }

    It 'reports zero killed when nothing was killed' {
        # The all-survived case is the one a caller acts on (keep writing tests), so
        # it must not collapse to the same output as the all-killed case.
        $out = Join-Path $TestDrive 'r4.recheck.json'
        $none = @([pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 1; Description = 'x'; Status = 'Survived' })
        $s = Write-PSMutationRecheckReport -Results $none -ReportPath $out -PriorSurvivorCount 1 -SourceReportPath 'f.json'
        $s.NowKilled      | Should -Be 0
        $s.StillSurviving | Should -Be 1
    }
}

Describe 'Show-PSMutationRecheckSummary' {
    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        $script:colours = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:lines.Add([string]$Object); $script:colours.Add([string]$ForegroundColor) }
        $script:results = @(
            [pscustomobject]@{ Id = 1; File = 'src/a.ps1'; Line = 10; Description = 'x'; Status = 'Killed' }
            [pscustomobject]@{ Id = 2; File = 'src/a.ps1'; Line = 20; Description = 'y'; Status = 'Survived' }
        )
    }

    It 'always prints the caveat that this is not a mutation score' {
        # This line is the whole safety argument for the feature. Without it the
        # output reads like a measurement, and "6 of 10 killed" gets quoted as a
        # score -- so it is pinned rather than left to reviewer discipline.
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 1; StillSurviving = 1 }
        Show-PSMutationRecheckSummary -Summary $s -Results $script:results -ReportPath 'r.recheck.json'
        ($script:lines -join "`n") | Should -BeLike '*Not a mutation score*'
        ($script:lines -join "`n") | Should -BeLike '*full set*'
    }

    It 'prints counts, never a percentage' {
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 1; StillSurviving = 1 }
        Show-PSMutationRecheckSummary -Summary $s -Results $script:results -ReportPath 'r.recheck.json'
        ($script:lines -join "`n") | Should -BeLike '*1 of 2 previous survivor(s) now killed*'
        ($script:lines -join "`n") | Should -Not -Match '\d+([.,]\d+)?\s*%'
    }

    It 'lists the mutants that are still surviving' {
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 1; StillSurviving = 1 }
        Show-PSMutationRecheckSummary -Summary $s -Results $script:results -ReportPath 'r.recheck.json'
        ($script:lines -join "`n") | Should -BeLike '*src/a.ps1:20*y*'
        ($script:lines -join "`n") | Should -Not -BeLike '*src/a.ps1:10*'   # killed: not still surviving
    }

    It 'goes green only when nothing is left surviving' -ForEach @(
        @{ Still = 0; Expected = 'Green'  }
        @{ Still = 1; Expected = 'Yellow' }
    ) {
        $s = [pscustomobject]@{ Mode = 'Recheck'; PriorSurvivors = 10; Rechecked = 2; NowKilled = 2 - $Still; StillSurviving = $Still }
        Show-PSMutationRecheckSummary -Summary $s -Results @() -ReportPath 'r.recheck.json'
        $script:colours | Should -Contain $Expected
    }
}

Describe 'Get-PSMutationSourceHash' {
    It 'differs when a single byte differs' {
        $a = Join-Path $TestDrive 'h1.ps1'; Set-Content -Path $a -Value '$x = 1' -NoNewline
        $b = Join-Path $TestDrive 'h2.ps1'; Set-Content -Path $b -Value '$x = 2' -NoNewline
        $ha = Get-PSMutationSourceHash -Path $a
        $ha | Should -Not -Be (Get-PSMutationSourceHash -Path $b)
        $ha | Should -Match '^[0-9a-f]{64}$'
    }

    It 'is identical for identical content in different files' {
        $a = Join-Path $TestDrive 'same1.ps1'; Set-Content -Path $a -Value '$x = 1' -NoNewline
        $b = Join-Path $TestDrive 'same2.ps1'; Set-Content -Path $b -Value '$x = 1' -NoNewline
        (Get-PSMutationSourceHash -Path $a) | Should -Be (Get-PSMutationSourceHash -Path $b)
    }
}
