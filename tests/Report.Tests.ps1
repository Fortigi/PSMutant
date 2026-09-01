# Unit tests for the scoring/report layer (pure + one temp write).
# Also the covering suite for self-mutating src/PSMutation.Report.ps1 - keep it self-contained.

BeforeAll {
    # UNIQUE PER RUN, not per process. $PID was unique enough while one process ran one suite;
    # `workers` runs several mutants of the same file at once, in separate runspaces of ONE
    # process, each running THIS file -- so a pid-named fixture is a fixture two of them share,
    # and one's cleanup deletes the other's file mid-test. Measured: it killed a mutant declared
    # equivalent, which the report then shows as a stale declaration rather than as a race.
    $script:tag = [System.Guid]::NewGuid().ToString('N')
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Output.ps1')
    . (Join-Path $src 'PSMutation.Report.ps1')

    $script:mixed = @(
        [pscustomobject]@{ File = 'a.ps1'; Line = 1; Operator = 'BinaryOperator'; Description = 'x'; Status = 'Killed' }
        [pscustomobject]@{ File = 'a.ps1'; Line = 2; Operator = 'BinaryOperator'; Description = 'y'; Status = 'Killed' }
        [pscustomobject]@{ File = 'a.ps1'; Line = 3; Operator = 'BooleanLiteral'; Description = 'z'; Status = 'Survived' }
    )

    # Same shape with the middle row timed out. File-level rather than per-Describe: two
    # Describes read it, and $script: state set in one block and read in another makes a
    # FILTERED run fail on tests that are fine.
    $script:withTimeout = @(
        [pscustomobject]@{ File = 'a.ps1'; Line = 1; Operator = 'BinaryOperator'; Description = 'x'; Status = 'Killed' }
        [pscustomobject]@{ File = 'a.ps1'; Line = 2; Operator = 'BinaryOperator'; Description = 'y'; Status = 'TimedOut' }
        [pscustomobject]@{ File = 'a.ps1'; Line = 3; Operator = 'BooleanLiteral'; Description = 'z'; Status = 'Survived' }
    )
}

Describe 'Get-PSMutationScore' {
    It 'computes killed/survived/total and rounds the score' {
        $s = Get-PSMutationScore -Results $script:mixed
        $s.Killed   | Should-Be 2
        $s.Survived | Should-Be 1
        $s.Total    | Should-Be 3
        $s.Score    | Should-Be 66.7
    }
    It 'reports 0 for an empty result set (no divide-by-zero)' {
        $s = Get-PSMutationScore -Results @()
        $s.Total | Should-Be 0
        $s.Score | Should-Be 0
    }
    It 'reports 100 when everything is killed' {
        $s = Get-PSMutationScore -Results @([pscustomobject]@{ Status = 'Killed' })
        $s.Score | Should-Be 100
    }
}

Describe 'Get-PSMutationDeclaredEquivalent' {
    It 'returns an empty map when nothing is declared' {
        (Get-PSMutationDeclaredEquivalent -Equivalents $null).Count | Should-Be 0
    }

    It 'drops a declaration with a blank reason' {
        # "Equivalent" without a stated argument is just a mute button. A blank
        # reason must not silence a mutant, or the discipline is optional.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = '   '; 'a.ps1:4:w' = 'a real reason' }
        $m = Get-PSMutationDeclaredEquivalent -Equivalents $eq
        $m.Count | Should-Be 1
        $m.ContainsKey('a.ps1:4:w') | Should-BeTrue
    }
}

Describe 'Get-PSMutationScore with declared equivalents' {
    It 'excludes a declared equivalent from the denominator' {
        # 2 killed, 1 survivor declared equivalent -> 2/2, not 2/3.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = 'cannot change behaviour' }
        $s = Get-PSMutationScore -Results $script:mixed -Equivalents $eq
        $s.Total              | Should-Be 2
        $s.Survived           | Should-Be 0
        $s.DeclaredEquivalent | Should-Be 1
        $s.Score              | Should-Be 100
        @($s.StaleEquivalents).Count | Should-Be 0
    }

    It 'flags a declaration whose mutant the suite actually killed' {
        # The declaration says "no test can catch this" and a test caught it. Banking
        # the kill silently would leave a false claim in the config forever.
        $eq = [pscustomobject]@{ 'a.ps1:1:x' = 'claimed unkillable' }
        $s = Get-PSMutationScore -Results $script:mixed -Equivalents $eq
        $s.DeclaredEquivalent | Should-Be 0
        @($s.StaleEquivalents).Count | Should-Be 1
        $s.StaleEquivalents[0] | Should-BeLikeString '*the suite killed it*'
    }

    It 'flags a declaration that matches no mutant at all' {
        # The code moved and nobody revisited the claim.
        $eq = [pscustomobject]@{ 'a.ps1:999:gone' = 'stale after a refactor' }
        # @() at the ASSIGNMENT, not at the assertion: a single-element return unrolls, and
        # indexing the bare value then hands Should-BeLikeString something that is not a
        # string.
        $faults = @(Get-PSMutationDeclarationCoverageFault -Results $script:mixed -Equivalents $eq)
        $faults.Count | Should-Be 1
        $faults[0] | Should-BeLikeString '*no such mutant exists*'
    }

    It 'scores exactly as before when nothing is declared' {
        $s = Get-PSMutationScore -Results $script:mixed
        $s.Score | Should-Be 66.7
        $s.Total | Should-Be 3
        $s.DeclaredEquivalent | Should-Be 0
    }
}

Describe 'Get-PSMutationEquivalentKey' {
    It 'keys on file, function and the change, not the mutant id' {
        # Ids renumber when anything earlier in the file changes; a declaration keyed on one
        # would silently start pointing at a different mutant.
        Should-BeCollection -Expected @('a.ps1:Get-Thing:6 -> 7', 'a.ps1:3:6 -> 7') `
            -Actual (Get-PSMutationEquivalentKey -Result ([pscustomobject]@{
                    Id = 9; File = 'a.ps1'; Line = 3; Function = 'Get-Thing'; Description = '6 -> 7' }))
    }

    It 'gives a FILE-SCOPE mutant a stable name instead of only a line' {
        # #179. A mutant outside any function has no function to be named by, and used to keep
        # only the line form -- which moves whenever anything above it is edited. This repo's own
        # declaration churned 154 -> 167 -> 181 in one day from two unrelated edits, the second
        # comment-only.
        Should-BeCollection -Expected @('a.ps1:<script-body>:0 -> 1', 'a.ps1:12:0 -> 1') `
            -Actual (Get-PSMutationEquivalentKey -Result ([pscustomobject]@{
                    Id = 4; File = 'a.ps1'; Line = 12; Function = ''; Description = '0 -> 1' }))
    }

    It 'puts the stable form FIRST, because the stablest key wins' {
        # Order is load-bearing: Get-PSMutationDeclaredKey returns the first key a config
        # declares, so a config carrying both forms must resolve to the one that does not churn.
        $keys = Get-PSMutationEquivalentKey -Result ([pscustomobject]@{
                Id = 4; File = 'a.ps1'; Line = 12; Function = ''; Description = '0 -> 1' })
        @($keys)[0] | Should-Be 'a.ps1:<script-body>:0 -> 1'
    }

    It 'still accepts a line-keyed declaration, so existing configs keep working' {
        # A fix for key churn that invalidated every existing key would be a poor trade.
        Get-PSMutationDeclaredKey -Result ([pscustomobject]@{
                Id = 4; File = 'a.ps1'; Line = 12; Function = ''; Description = '0 -> 1' }) `
            -Declared @{ 'a.ps1:12:0 -> 1' = 'because' } | Should-Be 'a.ps1:12:0 -> 1'
    }

    It 'prefers the script-body key when a config declares both forms' {
        Get-PSMutationDeclaredKey -Result ([pscustomobject]@{
                Id = 4; File = 'a.ps1'; Line = 12; Function = ''; Description = '0 -> 1' }) `
            -Declared @{ 'a.ps1:12:0 -> 1' = 'old'; 'a.ps1:<script-body>:0 -> 1' = 'new' } |
            Should-Be 'a.ps1:<script-body>:0 -> 1'
    }
}

Describe 'Get-PSMutationExitCode' {
    It 'returns 0 in report-only mode (break = null)' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 10 }) -Thresholds ([pscustomobject]@{ break = $null }) | Should-Be 0
    }
    It 'returns 1 when the score is below the break threshold' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 60 }) -Thresholds ([pscustomobject]@{ break = 70 }) | Should-Be 1
    }
    It 'returns 0 when the score meets the break threshold' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 70 }) -Thresholds ([pscustomobject]@{ break = 70 }) | Should-Be 0
    }

    It 'fails on a stale equivalence declaration even in report-only mode' {
        # break = null means "do not grade me", but a stale declaration is not a
        # low score -- it is a false statement that is inflating whatever score is
        # printed, so report-only mode must not excuse it.
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 100; StaleEquivalents = @('a.ps1:1:x -- declared equivalent but the suite killed it') }) `
            -Thresholds ([pscustomobject]@{ break = $null }) | Should-Be 1
    }

    It 'fails on a stale declaration even at a perfect score above the threshold' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 100; StaleEquivalents = @('x') }) `
            -Thresholds ([pscustomobject]@{ break = 80 }) | Should-Be 1
    }

    It 'passes when the stale list is present but empty' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 100; StaleEquivalents = @() }) `
            -Thresholds ([pscustomobject]@{ break = 80 }) | Should-Be 0
    }

    It 'passes when the summary carries no stale list at all' {
        # @($null).Count is 1, not 0 -- counting an absent property without
        # filtering first fails every run that has no declarations.
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 100; StaleEquivalents = $null }) `
            -Thresholds ([pscustomobject]@{ break = 80 }) | Should-Be 0
    }
}

Describe 'Write-PSMutationReport' {
    It 'says a run was RESUMED, and how much of the score it did not measure itself' {
        # The caveat lives in the ARTIFACT, not only in the console. Everything downstream reads
        # this file as a measurement and part of it was measured by an earlier run -- a resumed
        # report is COMPLETE, so unlike a recheck it may carry a real score, but a reader must
        # still be able to see what fraction of it this run stood behind.
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-resumed-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
                -Resumed -CarriedOverUnverified 2 | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.resumed | Should-BeTrue
            $json.carriedOverUnverified | Should-Be 2
            # Still a real score, which is the whole difference from a recheck report.
            $json.mutationScore | Should-Be 66.7
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'carries NEITHER field on an ordinary run, so presence is what tells them apart' {
        # The paired half. Written unconditionally the fields would say "resumed: false" on every
        # report ever produced, and a consumer could no longer tell a resumed run from one that
        # simply predates the feature.
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-notresumed-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.PSObject.Properties.Name | Should-NotContainCollection 'resumed'
            $json.PSObject.Properties.Name | Should-NotContainCollection 'carriedOverUnverified'
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records a resume that carried over NOTHING, which a sentinel could not express' {
        # An interruption before the first mutant finished is a real case, and the reason the
        # signal is a switch plus a count rather than a count with a magic value: zero carried
        # over is not the same as "not a resume".
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-resumed0-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null -Resumed | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.resumed | Should-BeTrue
            $json.carriedOverUnverified | Should-Be 0
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a JSON report with the score and survivors' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-report-$PID-$($script:tag)/report.json"
        try {
            $summary = Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds ([pscustomobject]@{ break = $null })
            $summary.Score | Should-Be 66.7
            Test-Path $out | Should-BeTrue
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.mutationScore | Should-Be 66.7
            @($json.survivors).Count | Should-Be 1
            @($json.mutants).Count   | Should-Be 3
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records the source hashes and operator set a later recheck depends on' {
        # -RecheckFrom matches mutants by AST-walk id, which is only meaningful for
        # identical source and operators. If these two fields stop being written, a
        # recheck cannot tell that the code moved and would recheck the wrong mutants.
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-report2-$PID-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
                -SourceHashes @{ 'a.ps1' = 'abc123' } -Operators @('BooleanLiteral', 'BinaryOperator') | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.sourceHashes.'a.ps1' | Should-Be 'abc123'
            # Sorted on write so a config listing them in another order still matches.
            $json.operators | Should-BeCollection @('BinaryOperator', 'BooleanLiteral')
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-PSMutationSummaryLine' {
    # No Mock Write-Host anywhere below. The function returns what the run should SAY, so
    # the assertions are against roles and text rather than against a cmdlet's arguments.
    # That is the point of the seam: rewording a line no longer breaks a test, and the role
    # a line carries is checked instead of the colour some renderer picked for it.

    It 'names the score and every survivor with its file, line and change' {
        # The survivor list IS the tool's output -- a caller works from these lines, so
        # dropping the line number or the change text makes the run useless even though the
        # score still looks right. Asserted on the killed/total text rather than the
        # percentage, which renders as 66,7 under a comma locale.
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $script:mixed) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-BeLikeString '*2 killed / 3*'
        ($lines.Text -join "`n") | Should-BeLikeString '*a.ps1:3*z*'
        ($lines.Text -join "`n") | Should-BeLikeString '*r.json*'
    }

    It 'folds the weak-file breakdown into the summary it hands back' {
        # The WIRING, not the formatter -- Get-PSMutationWeakFileLine is asserted on its own
        # above. What this covers is that the summary actually includes those lines: the two
        # were connected by an AddRange that no test reached, so the breakdown could have been
        # computed and dropped on the floor with every other assertion still passing.
        $perFile = @(
            [pscustomobject]@{ file = 'src/strong.ps1'; score = 100; killed = 90; total = 90 }
            [pscustomobject]@{ file = 'src/weak.ps1'; score = 39.6; killed = 19; total = 48 }
        )
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $script:mixed) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json' -PerFile $perFile
        ($lines.Text -join "`n") | Should-BeLikeString '*1 of 2 file(s) score below 85*'
        ($lines.Text -join "`n") | Should-BeLikeString '*src/weak.ps1*'
    }

    It 'leaves the summary unchanged when no file is weak' {
        # The pairing this repo requires of every "X appears" assertion: without it, a breakdown
        # that printed unconditionally would satisfy the test above just as well.
        $perFile = @(
            [pscustomobject]@{ file = 'src/a.ps1'; score = 100; killed = 9; total = 9 }
            [pscustomobject]@{ file = 'src/b.ps1'; score = 90; killed = 9; total = 10 }
        )
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $script:mixed) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json' -PerFile $perFile
        ($lines.Text -join "`n") | Should-NotBeLikeString '*score below*'
    }

    It 'carries the survivor row as data, not only as text' {
        # What makes this a seam rather than a rename. A renderer emitting CI annotations
        # needs the file and line as values; if the only copy is inside the formatted
        # string, every such renderer has to parse the text back apart.
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $script:mixed) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json'
        $survivor = @($lines | Where-Object { $_.Data -and $_.Data.Status -eq 'Survived' })
        $survivor.Count | Should-Be 1
        $survivor[0].Data.Line | Should-Be 3
    }

    It 'says nothing about survivors when nothing survived' {
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results @([pscustomobject]@{ Status = 'Killed' })) `
            -Results @([pscustomobject]@{ Status = 'Killed' }) -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*Survivors*'
    }

    It 'says how many mutants were excluded as declared-equivalent' -ForEach @(
        @{ Count = 1 }   # the discriminating case: `-gt 0` and `-gt 1` agree at 0 and 3
        @{ Count = 3 }
    ) {
        # A 100% built on a dozen declarations is a different claim from a 100% that killed
        # everything, and the reader must not have to open the config to tell them apart.
        # ONE exclusion is the case that separates "any" from "more than one" -- at exactly
        # one declaration, `-gt 1` says nothing.
        $lines = Get-PSMutationSummaryLine -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; DeclaredEquivalent = $Count }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-BeLikeString "*$Count mutant(s) excluded as declared-equivalent*"
    }

    It 'does not list a declared equivalent among the survivors to go and fix' {
        # It is excluded from the score, so listing it as work sends the reader after a
        # mutant the config already argued is unkillable.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = 'cannot change behaviour' }
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $script:mixed -Equivalents $eq) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json' -Equivalents $eq
        ($lines.Text -join "`n") | Should-NotBeLikeString '*a.ps1:3*'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*Survivors*'
    }

    It 'still lists an undeclared survivor alongside a declared one' {
        # The filter must remove only what was declared; dropping the whole section would
        # hide real work behind one declaration.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = 'cannot change behaviour' }
        $results = $script:mixed + [pscustomobject]@{ File = 'a.ps1'; Line = 9; Operator = 'BinaryOperator'; Description = 'q'; Status = 'Survived' }
        $lines = Get-PSMutationSummaryLine -Summary (Get-PSMutationScore -Results $results -Equivalents $eq) `
            -Results $results -High 85 -Low 70 -ReportPath 'r.json' -Equivalents $eq
        ($lines.Text -join "`n") | Should-BeLikeString '*a.ps1:9*q*'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*a.ps1:3*'
    }

    It 'stays silent about exclusions when there are none' {
        $lines = Get-PSMutationSummaryLine -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; DeclaredEquivalent = 0 }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*declared-equivalent*'
    }

    It 'reports stale declarations as Bad, with the offending key' {
        $lines = Get-PSMutationSummaryLine -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0
                StaleEquivalents = @('a.ps1:3:z -- declared equivalent but the suite killed it')
            }) -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-BeLikeString '*INVALID equivalence declarations*'
        ($lines.Text -join "`n") | Should-BeLikeString '*a.ps1:3:z*'
        $lines.Role | Should-ContainCollection 'Bad'
    }

    It 'reports no stale section when the summary carries no stale list' {
        # @($null).Count is 1, so an unfiltered count raises the alarm with a blank line
        # under it on every ordinary run.
        $lines = Get-PSMutationSummaryLine -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; StaleEquivalents = $null }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($lines.Text -join "`n") | Should-NotBeLikeString '*INVALID*'
    }

    It 'gives the score line the role its band earns' -ForEach @(
        @{ Score = 85; Expected = 'Good' }   # exactly high: the boundary, not 86
        @{ Score = 84; Expected = 'Warn' }   # one below high
        @{ Score = 70; Expected = 'Warn' }   # exactly low
        @{ Score = 69; Expected = 'Bad' }    # one below low
    ) {
        # Boundary values, not comfortable ones: 90/50 would pass just as happily against
        # `-gt` as against `-ge`, and would never notice the bands sliding. Which console
        # colour each role becomes is asserted in Output.Tests.ps1, not here.
        $lines = Get-PSMutationSummaryLine -Summary ([pscustomobject]@{ Score = $Score; Killed = 1; Total = 2; Survived = 0 }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        $lines.Role | Should-ContainCollection $Expected
    }
}

Describe 'Get-PSMutationFailureReason' {
    # The verdict and the reason are one judgement asked at two resolutions, so the exit code is
    # DERIVED from this rather than deciding the same two rules again. Each case below checks
    # both at the same inputs, which is what makes that derivation observable.

    It 'is None for a clean run, and exit code 0' {
        $s = [pscustomobject]@{ Score = 100; StaleEquivalents = @() }
        $t = [pscustomobject]@{ break = 100 }
        Get-PSMutationFailureReason -Summary $s -Thresholds $t | Should-Be 'None'
        Get-PSMutationExitCode -Summary $s -Thresholds $t | Should-Be 0
    }

    It 'is BelowThreshold when the score is under break' {
        $s = [pscustomobject]@{ Score = 99.8; StaleEquivalents = @() }
        $t = [pscustomobject]@{ break = 100 }
        Get-PSMutationFailureReason -Summary $s -Thresholds $t | Should-Be 'BelowThreshold'
        Get-PSMutationExitCode -Summary $s -Thresholds $t | Should-Be 1
    }

    It 'is None with no break threshold at all, however low the score' {
        # Report-only is a real configuration, and a run nobody asked to gate must not fail.
        $s = [pscustomobject]@{ Score = 0; StaleEquivalents = @() }
        Get-PSMutationFailureReason -Summary $s -Thresholds ([pscustomobject]@{ high = 90 }) |
            Should-Be 'None'
    }

    It 'is StaleEquivalents even in report-only mode' {
        # A stale declaration is not a quality shortfall to be graded on a curve; it is a false
        # statement in the config that is inflating the score, so it fails regardless.
        $s = [pscustomobject]@{ Score = 100; StaleEquivalents = @('src/a.ps1:F:1 -> 2') }
        Get-PSMutationFailureReason -Summary $s -Thresholds $null | Should-Be 'StaleEquivalents'
        Get-PSMutationExitCode -Summary $s -Thresholds $null | Should-Be 1
    }

    It 'reports STALE first when the run is both stale and under threshold' {
        # The discriminating case: both rules fire. Stale is the more specific and the more
        # actionable -- a score computed with a false declaration in it is not one anybody should
        # act on, so "below threshold" would send the reader to write tests when the config is
        # what needs editing.
        $s = [pscustomobject]@{ Score = 50; StaleEquivalents = @('src/a.ps1:F:1 -> 2') }
        Get-PSMutationFailureReason -Summary $s -Thresholds ([pscustomobject]@{ break = 100 }) |
            Should-Be 'StaleEquivalents'
    }

    It 'is not fooled by a summary carrying no stale list at all' {
        # @($null).Count is 1, not 0. Without the filter every run fails.
        $s = [pscustomobject]@{ Score = 100 }
        Get-PSMutationFailureReason -Summary $s -Thresholds ([pscustomobject]@{ break = 100 }) |
            Should-Be 'None'
    }
}

Describe 'ConvertTo-PSMutationRunResult' {
    It 'exposes the score, the counts and the exit code' {
        # This object is the module's public contract -- CI reads .Score and .ExitCode.
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }

        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1 -FailureReason 'BelowThreshold'

        $r.Score    | Should-Be 64.3
        $r.Killed   | Should-Be 164
        $r.Survived | Should-Be 91
        $r.Total    | Should-Be 255
        $r.ExitCode | Should-Be 1
    }

    It 'keeps killed and survived distinct' {
        # Numbers chosen so a swapped pair cannot pass: equal counts would hide it.
        $s = [pscustomobject]@{ Score = 50; Killed = 3; Survived = 7; Total = 10 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0 -FailureReason 'None'
        $r.Killed   | Should-Be 3
        $r.Survived | Should-Be 7
    }

    It 'carries the reason and the stale list, not just the verdict' {
        # The whole point. Exit code 1 means either a stale declaration or a low score, and a
        # caller that cannot tell them apart has to guess -- which is how a workflow came to
        # print "score is below the break threshold" over a run that scored 100%.
        $s = [pscustomobject]@{
            Score              = 100; Killed = 2; Survived = 0; Total = 2
            DeclaredEquivalent = 1; StaleEquivalents = @('src/a.ps1:Get-Thing:1 -> 2')
        }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1 -FailureReason 'StaleEquivalents'
        $r.FailureReason | Should-Be 'StaleEquivalents'
        $r.StaleEquivalents | Should-BeCollection @('src/a.ps1:Get-Thing:1 -> 2')
        $r.DeclaredEquivalent | Should-Be 1
        # And the score is still 100, which is exactly why the reason has to travel beside it.
        $r.Score | Should-Be 100
    }

    It 'reports an EMPTY stale list rather than nothing when there is none' {
        # Absent and empty are different answers. A consumer iterating this should not have to
        # tell "nothing was stale" from "this build stopped reporting it".
        $s = [pscustomobject]@{ Score = 100; Killed = 2; Survived = 0; Total = 2 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0 -FailureReason 'None'
        @($r.StaleEquivalents).Count | Should-Be 0
        $r.DeclaredEquivalent | Should-Be 0
    }

    It 'says which mode produced it' {
        # The two shapes shared no field at all, so a caller that did not choose the mode could
        # not tell which one it was holding.
        $s = [pscustomobject]@{ Score = 100; Killed = 1; Survived = 0; Total = 1 }
        (ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0 -FailureReason 'None').Mode |
            Should-Be 'Full'
    }
}


Describe 'Get-PSMutationScoreRole' {
    It 'scores <Score> against 85/70 as <Expected>' -ForEach @(
        @{ Score = 100; High = 85; Low = 70; Expected = 'Good' }
        @{ Score = 85;  High = 85; Low = 70; Expected = 'Good' }   # exactly high: -ge, not -gt
        @{ Score = 84;  High = 85; Low = 70; Expected = 'Warn' }   # one below high
        @{ Score = 70;  High = 85; Low = 70; Expected = 'Warn' }   # exactly low
        @{ Score = 69;  High = 85; Low = 70; Expected = 'Bad' }   # one below low
        @{ Score = 0;   High = 85; Low = 70; Expected = 'Bad' }   # a zero must never read Good
    ) {
        # Boundary values, not comfortable ones: 90/50 would pass just as happily against
        # `-gt` as against `-ge`, and would never notice the bands sliding by one.
        Get-PSMutationScoreRole -Score $Score -High $High -Low $Low | Should-Be $Expected
    }

    It 'reads Good at zero even against bands of zero' {
        # Guards the degenerate config rather than assuming nobody writes it: with both
        # bands at 0 every score is at or above high, so zero reads Good -- which is correct
        # and is the user's explicit choice, not the silent null-comparison that made
        # every score Good regardless of what the config said.
        Get-PSMutationScoreRole -Score 0 -High 0 -Low 0 | Should-Be 'Good'
    }

    It 'prefers Good over Warn when the bands overlap' {
        # High below Low is a nonsense config, but it must still be decided rather than
        # crash: the first branch wins, so the result is Good.
        Get-PSMutationScoreRole -Score 50 -High 40 -Low 60 | Should-Be 'Good'
    }
}

Describe 'the contract a consumer actually depends on' {
    # Un-exporting Get-PSMutationCandidate and Set-PSMutationText removed the undeclared
    # nine-field candidate object from the public surface (#48). It did not remove the
    # contract -- it moved it. What a consumer can still see is exactly two things: the
    # object Invoke-PSMutation returns, and the report JSON. These pin both, so a change to
    # either is a decision someone makes rather than a side effect of an internal rename.

    It 'returns exactly the documented run-result fields' {
        # CI reads .Score and .ExitCode off this. An extra field is a promise nobody meant to
        # make; a missing one breaks a pipeline that has no way to see it coming.
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }
        (ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1 -FailureReason 'BelowThreshold').PSObject.Properties.Name |
            Should-BeCollection @('Mode', 'Score', 'Killed', 'Survived', 'Total', 'ExitCode',
                'FailureReason', 'StaleEquivalents', 'DeclaredEquivalent', 'ChangedFiles')
    }

    It 'says Full and carries a null scope when the run was not scoped' {
        # The pair a caller branches on. $null rather than @(), because absent and empty are
        # different answers and only absent may be read as "every file in mutate".
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0 -FailureReason 'None'
        $r.Mode | Should-Be 'Full'
        $null -eq $r.ChangedFiles | Should-BeTrue
    }

    It 'says Changed and names the scope when the run was scoped' {
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0 -FailureReason 'None' `
            -ChangedFiles @('src/a.ps1')
        $r.Mode | Should-Be 'Changed'
        $r.ChangedFiles | Should-Be 'src/a.ps1'
    }

    It 'writes exactly the documented top-level report fields' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-contract-$PID-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            (Get-Content $out -Raw | ConvertFrom-Json).PSObject.Properties.Name |
                Should-BeCollection @(
                    'generatedFrom', 'schemaVersion', 'producedBy', 'generatedAt', 'durations',
                    'mutationScore', 'total', 'killed', 'survived', 'timedOut',
                    'declaredEquivalent', 'filesMutated', 'killersComplete', 'testFiles', 'perFile', 'skippedAsUncovered', 'filesWithNoMutants',
                    'filesWithNoCandidate', 'filesWithoutTestMapping',
                    'staleEquivalents', 'thresholds', 'operators',
                    'sourceHashes', 'survivors', 'mutants')
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

}

Describe 'a report that cannot be written must fail the run' {
    # The write used to be non-terminating, so a bad reportPath printed "Report: <path>" for
    # a file nothing had written and the run returned Score=100, ExitCode=0. Both cases below
    # are ordinary config mistakes, not exotic ones.

    It 'throws when the report directory cannot be created' {
        # A FILE sits where the parent directory has to go, so creating it is impossible.
        # Portable: this fails the same way on Windows and Linux, unlike a permissions or
        # path-length fixture.
        #
        # Honest about what this pins: it passes against the PRE-FIX code too, because that
        # particular failure was already terminating. It holds the contract -- a write that
        # cannot happen stops the run -- but the test that actually discriminates this fix is
        # the bracket one below. -ErrorAction Stop covers the causes that are not portably
        # reproducible: a locked file, a read-only directory, a path over the length limit.
        $blocker = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-block-$([guid]::NewGuid())"
        Set-Content -LiteralPath $blocker -Value 'not a directory'
        try {
            $doomed = Join-Path $blocker 'sub/report.json'
            { Write-PSMutationReport -Results $script:mixed -ReportPath $doomed -Thresholds $null } |
                Should-Throw
        }
        finally { Remove-Item -LiteralPath $blocker -Force }
    }

    It 'writes a report whose path contains a bracket' {
        # The kept half of the pair. Without it the test above passes against a writer that
        # refuses EVERY path, which is not the fix. A bracket is a wildcard to Set-Content
        # without -LiteralPath, so this path used to fail while looking perfectly ordinary.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-rep[1]-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'report.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            Should-BeTrue -Actual (Test-Path -LiteralPath $out)
            # Read it back literally: a report that exists but holds nothing readable would
            # otherwise pass the existence check.
            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $doc.total | Should-Be 3
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'a timeout scores with the kills but is counted apart from them' {
    # "The suite proved this fault is caught" and "the suite hung and we assumed so" are
    # different claims. Folded together, a suite that is merely slow inflates the score and
    # nothing shows it happening.

    It 'counts a timed-out mutant toward killed, so the headline score does not move' {
        $s = Get-PSMutationScore -Results $script:withTimeout
        $s.Killed | Should-Be 2
        $s.Survived | Should-Be 1
        $s.Score | Should-Be 66.7
    }

    It 'also counts it on its own, so a rising number is visible' {
        (Get-PSMutationScore -Results $script:withTimeout).TimedOut | Should-Be 1
        # The discriminating half: a run with no timeouts must report zero, not absent.
        (Get-PSMutationScore -Results $script:mixed).TimedOut | Should-Be 0
    }

    It 'records timedOut in the report document' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-to-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:withTimeout -ReportPath $out -Thresholds $null | Out-Null
            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $doc.timedOut | Should-Be 1
            # killed INCLUDES the timeout, so a consumer reconciling killed + survived
            # against total still balances.
            $doc.killed | Should-Be 2
            $doc.total | Should-Be 3
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-PSMutationTimeoutNote' {
    It 'says nothing when no mutant timed out' {
        Get-PSMutationTimeoutNote -TimedOut 0 | Should-Be ''
    }

    It 'qualifies the score when mutants died on the clock' {
        # Paired with the case above: a note that always fires and one that never fires both
        # pass a single-outcome fixture.
        Get-PSMutationTimeoutNote -TimedOut 3 | Should-MatchString ([regex]::Escape('3 killed on the clock'))
    }

    It 'reaches the summary line' {
        $summary = Get-PSMutationScore -Results $script:withTimeout
        $lines = Get-PSMutationSummaryLine -Summary $summary -Results $script:withTimeout -High 85 -Low 70
        ($lines.Text -join "`n") | Should-MatchString ([regex]::Escape('1 killed on the clock'))
    }
}

Describe 'a score answers for what the coverage filter removed' {
    # The filter drops uncovered candidates per file, silently, and it is the DEFAULT path.
    # A file added to `mutate` before its tests exist, or one a refactor stopped exercising,
    # contributes nothing and the score goes UP. Nothing in the console, the run result or
    # the report said so; the only trace was that sourceHashes listed more files than
    # mutants did, a reconciliation the reader had to do by hand.

    It 'counts every candidate the filter removed' {
        $perFile = @(
            [pscustomobject]@{ File = 'src/Calc.ps1';    Produced = 2; Kept = 2 }
            [pscustomobject]@{ File = 'src/Billing.ps1'; Produced = 5; Kept = 0 }
            [pscustomobject]@{ File = 'src/Payroll.ps1'; Produced = 3; Kept = 1 }
        )
        (Get-PSMutationCoverageExclusion -PerFile $perFile).Skipped | Should-Be 7
    }

    It 'names the files that produced candidates and contributed none' {
        $perFile = @(
            [pscustomobject]@{ File = 'src/Calc.ps1';    Produced = 2; Kept = 2 }
            [pscustomobject]@{ File = 'src/Billing.ps1'; Produced = 5; Kept = 0 }
            [pscustomobject]@{ File = 'src/Payroll.ps1'; Produced = 3; Kept = 1 }
        )
        # Billing only. Payroll kept one, so it is visible in the score already; Calc kept
        # everything. A fixture where every file is excluded would pass against code that
        # names all of them.
        (Get-PSMutationCoverageExclusion -PerFile $perFile).FilesWithNoMutants |
            Should-Be 'src/Billing.ps1'
    }

    It 'does not name a file that produced nothing to begin with' {
        # A file with no mutable construct is the vacuous-100% problem, not this one, and
        # calling it "excluded by coverage" would send the reader to write a test that
        # cannot help.
        $perFile = @([pscustomobject]@{ File = 'src/Empty.ps1'; Produced = 0; Kept = 0 })
        $x = Get-PSMutationCoverageExclusion -PerFile $perFile
        $x.Skipped | Should-Be 0
        $x.FilesWithNoMutants.Count | Should-Be 0
    }

    It 'says nothing when the filter removed nothing' {
        $none = [pscustomobject]@{ Skipped = 0; FilesWithNoMutants = @() }
        Get-PSMutationExclusionLine -Exclusion $none | Should-Be ''
    }

    It 'qualifies the score, naming the files, when it removed something' {
        $some = [pscustomobject]@{ Skipped = 8; FilesWithNoMutants = @('src/Billing.ps1', 'src/Payroll.ps1') }
        $line = Get-PSMutationExclusionLine -Exclusion $some
        $line | Should-MatchString ([regex]::Escape('8 mutant(s) skipped as uncovered'))
        # The names, not just the count: a number sends the reader looking, a name is
        # something they can act on.
        $line | Should-MatchString ([regex]::Escape('src/Billing.ps1, src/Payroll.ps1'))
    }

    It 'reaches the summary line, next to the score' {
        # Through the real entry point, not the predicate. Get-PSMutationExclusionLine can be
        # correct in both arms while the caller ignores its answer -- the caller is a line
        # that can be deleted with every other test still green, which is how the sweep in
        # Clear-PSMutationStaleSandbox once went missing.
        $summary = Get-PSMutationScore -Results $script:mixed
        $excl = [pscustomobject]@{ Skipped = 8; FilesWithNoMutants = @('src/Billing.ps1') }
        $lines = Get-PSMutationSummaryLine -Summary $summary -Results $script:mixed -High 85 -Low 70 -Exclusion $excl
        ($lines.Text -join "`n") | Should-MatchString ([regex]::Escape('8 mutant(s) skipped as uncovered'))
    }

    It 'says nothing on the summary line when nothing was excluded' {
        # The kept half. Without it the test above passes against a renderer that emits the
        # caveat unconditionally, which would put "0 mutant(s) skipped" on every clean run.
        $summary = Get-PSMutationScore -Results $script:mixed
        $none = [pscustomobject]@{ Skipped = 0; FilesWithNoMutants = @() }
        $lines = Get-PSMutationSummaryLine -Summary $summary -Results $script:mixed -High 85 -Low 70 -Exclusion $none
        ($lines.Text -join "`n") | Should-NotMatchString 'skipped as uncovered'
    }

    It 'reports a count with no file list when every file kept something' {
        # The untested arm. Both existing cases have files to name or nothing to say at all,
        # so a renderer that ALWAYS appended the parenthetical, or one that appended it for
        # zero files, passed both. This is the shape where mutants were skipped across files
        # that each still contributed.
        $spread = [pscustomobject]@{ Skipped = 4; FilesWithNoMutants = @() }
        $line = Get-PSMutationExclusionLine -Exclusion $spread
        $line | Should-MatchString ([regex]::Escape('4 mutant(s) skipped as uncovered'))
        $line | Should-NotMatchString 'contributed none'
    }

    It 'counts nothing skipped when every file kept everything' {
        # Pins the accumulator's starting point. Seeded at anything but zero, a run where the
        # filter removed nothing would still report mutants skipped.
        $perFile = @([pscustomobject]@{ File = 'src/Calc.ps1'; Produced = 3; Kept = 3 })
        (Get-PSMutationCoverageExclusion -PerFile $perFile).Skipped | Should-Be 0
    }

    It 'adds no line at all to the summary when nothing was excluded' {
        # Not "adds no matching text" -- adds no LINE. Forcing the guard true appends an
        # EMPTY line, which a text assertion cannot see: the run then prints a blank row
        # under every score and every existing test still passes.
        $summary = Get-PSMutationScore -Results $script:mixed
        $none = [pscustomobject]@{ Skipped = 0; FilesWithNoMutants = @() }
        $with = @(Get-PSMutationSummaryLine -Summary $summary -Results $script:mixed -High 85 -Low 70 -Exclusion ([pscustomobject]@{ Skipped = 2; FilesWithNoMutants = @() }))
        $without = @(Get-PSMutationSummaryLine -Summary $summary -Results $script:mixed -High 85 -Low 70 -Exclusion $none)
        ($with.Count - $without.Count) | Should-Be 1
    }

    It 'names a file that produced exactly one candidate and kept none' {
        # ONE, deliberately. The existing fixtures produce 5 and 0, and both sit the same
        # side of a shifted boundary -- `Produced -gt 1` behaves identically for them. A file
        # with a single mutable construct that no test reaches is the smallest real instance
        # of this bug and the only fixture that can see the boundary move.
        $perFile = @([pscustomobject]@{ File = 'src/Thin.ps1'; Produced = 1; Kept = 0 })
        $x = Get-PSMutationCoverageExclusion -PerFile $perFile
        $x.Skipped | Should-Be 1
        $x.FilesWithNoMutants | Should-Be 'src/Thin.ps1'
    }

    It 'names a single silent file without pluralising the claim away' {
        # Exactly one file, for the same reason: with two, `Count -gt 0` and `Count -gt 1`
        # agree, so the boundary is invisible and the parenthetical could be dropped for the
        # single-file case with every other test still green.
        $one = [pscustomobject]@{ Skipped = 3; FilesWithNoMutants = @('src/Billing.ps1') }
        $line = Get-PSMutationExclusionLine -Exclusion $one
        $line | Should-MatchString ([regex]::Escape('1 file(s) contributed none: src/Billing.ps1'))
    }

    It 'records the mutate files that fell back to the whole suite' {
        # Through the writer, because a CI job reads the report and not the console -- and the
        # console line is suppressed by -Quiet, which is exactly how CI runs it.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-unmapped-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
                -UnmappedFiles @('src/Billing.ps1') | Out-Null
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).filesWithoutTestMapping |
                Should-Be 'src/Billing.ps1'
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes an EMPTY array, never [null], when every file has a test mapping' {
        # The default path, and the one that shipped wrong for two releases (#158). The test
        # beside this one covers the non-empty case and passed throughout, which is exactly how
        # it survived: `@($null)` is an array of ONE element whose value is $null, so the field
        # read `[null]` on every ordinary run.
        #
        # Asserted against the raw JSON TEXT rather than a parsed object, because
        # ConvertFrom-Json turns both [] and [null] into something a -Count check cannot tell
        # apart -- `@($null).Count` is 1, but so is the count of a one-element array of a real
        # file, and a null-vs-empty distinction is precisely what is being pinned.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-nomapping-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            $raw = [System.IO.File]::ReadAllText($out)
            # .Contains, not Should-BeLikeString: `[]` in a -like pattern is a CHARACTER CLASS,
            # so the obvious spelling is not a wildcard error away from working -- it is a
            # pattern that cannot match. This file's header warns about exactly that trap for
            # version numbers; it bites identically here.
            $raw.Contains('"filesWithoutTestMapping": []') | Should-BeTrue
            $raw.Contains('"filesWithoutTestMapping": null') | Should-BeFalse
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes an empty array for the sibling list fields too' {
        # The two beside it escaped by accident -- their sources happen to be initialised
        # collections today -- and an accident is not a property. Same normaliser, so this is
        # what stops one of them acquiring the bug the day its source changes.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-siblings-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            $raw = [System.IO.File]::ReadAllText($out)
            $raw.Contains('"filesWithNoMutants": []') | Should-BeTrue
            $raw.Contains('"staleEquivalents": []') | Should-BeTrue
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records both numbers in the report document' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-excl-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            $excl = [pscustomobject]@{ Skipped = 8; FilesWithNoMutants = @('src/Billing.ps1') }
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null -Exclusion $excl | Out-Null
            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $doc.skippedAsUncovered | Should-Be 8
            $doc.filesWithNoMutants | Should-Be 'src/Billing.ps1'
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'an equivalence declaration must identify exactly one mutant' {
    BeforeAll {
        # Two mutants that legitimately share File:Line:Description. This is not contrived:
        # `[math]::Min($prev[$j] + 1, $curr[$j - 1] + 1)` puts two `1 -> 2` mutants on one
        # line, and this repo's own source has nine such ties.
        $script:tied = @(
            [pscustomobject]@{ File = 'a.ps1'; Line = 7; Operator = 'NumberLiteral'; Description = '1 -> 2'; Status = 'Survived' }
            [pscustomobject]@{ File = 'a.ps1'; Line = 7; Operator = 'NumberLiteral'; Description = '1 -> 2'; Status = 'Survived' }
        )
    }

    It 'rejects a declaration that matches more than one mutant' {
        # THE #28 defect. One honest declaration used to exclude every mutant sharing its
        # key, silently -- and stale-detection could not see it, because the key still
        # matched something. A declaration argues about one mutant; matching several is not
        # a smaller claim, it is an ambiguous one.
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'provably cannot change behaviour' }
        Get-PSMutationDeclarationCoverageFault -Results $script:tied -Equivalents $eq |
            Should-BeLikeString '*matches 2 mutants*ambiguous*'
    }

    It 'fails the run for an ambiguous declaration, regardless of thresholds' {
        # Same footing as a stale declaration: a false statement in the config inflating
        # the score is not a quality shortfall to be graded on a curve.
        # Through Write-PSMutationReport rather than the fold: the coverage check is whole-run
        # now, and this asserts the seam still MERGES it into the summary the exit code reads.
        # Calling the fold alone would pass a summary that no longer carries the fault.
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'provably cannot change behaviour' }
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "psm-amb-$([System.Guid]::NewGuid().ToString('N')).json"
        try {
            $s = Write-PSMutationReport -Results $script:tied -ReportPath $path -Thresholds $null -Equivalents $eq
            Get-PSMutationExitCode -Summary $s -Thresholds $null | Should-Be 1
        }
        finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    }

    It 'does not accuse a declaration whose mutant is in another group' {
        # The reason the whole-run check was lifted out. Scoring a SUBSET -- one file's rows,
        # which is what per-file scores would do -- used to report every declaration
        # belonging to a different file as stale. The fold is per-set now, so it cannot.
        $groupB = @([pscustomobject]@{ File = 'b.ps1'; Line = 3; Operator = 'NumberLiteral'; Description = 'x -> y'; Status = 'Killed' })
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'belongs to the other file' }
        @((Get-PSMutationScore -Results $groupB -Equivalents $eq).StaleEquivalents | Where-Object { $_ }).Count |
            Should-Be 0
    }

    It 'still accuses it when the whole run is asked' {
        # Paired with the case above: a fold that simply stopped reporting would satisfy it.
        # Over every row, the declaration matches nothing and must still be caught.
        $groupB = @([pscustomobject]@{ File = 'b.ps1'; Line = 3; Operator = 'NumberLiteral'; Description = 'x -> y'; Status = 'Killed' })
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'belongs to the other file' }
        Get-PSMutationDeclarationCoverageFault -Results $groupB -Equivalents $eq |
            Should-BeLikeString '*no such mutant exists*'
    }

    It 'accepts a declaration that matches exactly one mutant' {
        # The kept case, paired with the rejected one above. Without this a check that
        # rejected EVERY declaration would pass both tests before it.
        $one = @([pscustomobject]@{ File = 'a.ps1'; Line = 7; Operator = 'NumberLiteral'; Description = '1 -> 2'; Status = 'Survived' })
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'provably cannot change behaviour' }
        $s = Get-PSMutationScore -Results $one -Equivalents $eq
        @($s.StaleEquivalents | Where-Object { $_ }) | Should-BeCollection -Count 0
        $s.DeclaredEquivalent | Should-Be 1
    }

    It 'still reports a declaration that matches nothing' {
        # The third arm. Zero, one and many are genuinely different answers, and only one
        # of them is acceptable.
        $eq = [pscustomobject]@{ 'a.ps1:99:nope -> nope' = 'stale claim' }
        Get-PSMutationDeclarationCoverageFault -Results $script:tied -Equivalents $eq |
            Should-BeLikeString '*no such mutant exists*'
    }
}

Describe 'Get-PSMutationDeclarationFault' {
    It 'accepts a declaration matching exactly one mutant' {
        # The only acceptable answer. Whether the claim is TRUE is decided elsewhere, by
        # whether the suite killed that mutant; this decides only whether it is well formed.
        Should-BeNull -Actual (Get-PSMutationDeclarationFault -Key 'a.ps1:7:1 -> 2' -Hits 1)
    }

    It 'rejects a declaration matching nothing' {
        Get-PSMutationDeclarationFault -Key 'a.ps1:7:1 -> 2' -Hits 0 |
            Should-BeLikeString '*no such mutant exists*'
    }

    It 'rejects a declaration matching two, naming the count' {
        # Two is the boundary that matters: at 1 it is valid, at 2 it silently covers a
        # mutant nobody argued about. The count is in the message because the reader has to
        # go and find the others.
        Get-PSMutationDeclarationFault -Key 'a.ps1:7:1 -> 2' -Hits 2 |
            Should-BeLikeString '*matches 2 mutants*ambiguous*'
    }

    It 'names the key in every complaint' {
        # Without the key the message sends the reader to grep a config by hand.
        foreach ($hits in 0, 2) {
            Get-PSMutationDeclarationFault -Key 'zz.ps1:1:x -> y' -Hits $hits |
                Should-BeLikeString '*zz.ps1:1:x -> y*'
        }
    }
}

Describe 'Get-PSMutationEquivalentKey and Get-PSMutationDeclaredKey' {
    BeforeAll {
        $script:inFn = [pscustomobject]@{ File = 'a.ps1'; Function = 'Get-Thing'; Line = 7; Description = '1 -> 2' }
        $script:atTop = [pscustomobject]@{ File = 'a.ps1'; Function = ''; Line = 3; Description = '1 -> 2' }
    }

    It 'offers the function form first and the line form second' {
        # Order matters: Get-PSMutationDeclaredKey returns the first match, so a config
        # declaring both forms of one mutant counts once rather than reading as ambiguous.
        Get-PSMutationEquivalentKey -Result $script:inFn |
            Should-BeCollection @('a.ps1:Get-Thing:1 -> 2', 'a.ps1:7:1 -> 2')
    }

    It 'names a mutant at file scope with the script-body synthetic, not only a line' {
        # NO angle brackets in the test NAME, deliberately. Pester expands <...> in a title as a
        # -ForEach data placeholder, so `<script-body>` is read as `$script-body` and the test
        # fails to compile with "Unexpected token '-body'". The assertion below carries the real
        # spelling; the title cannot.
        # Reversed by #179. It used to offer the line form alone, on the reasoning that code
        # outside a function has no name -- true, and the consequence was that the one such
        # declaration in this repo churned 154 -> 167 -> 181 in a single day, the last move from
        # an edit that changed no code at all. A synthetic name it can keep is worth more than
        # an honest absence that drifts.
        Should-BeCollection -Expected @('a.ps1:<script-body>:1 -> 2', 'a.ps1:3:1 -> 2') `
            -Actual (Get-PSMutationEquivalentKey -Result $script:atTop)
    }

    It 'accepts a declaration written the old way' {
        # The compatibility promise: fixing key churn by invalidating every key would be a
        # poor trade, so existing configs keep working.
        Get-PSMutationDeclaredKey -Result $script:inFn -Declared @{ 'a.ps1:7:1 -> 2' = 'why' } |
            Should-Be 'a.ps1:7:1 -> 2'
    }

    It 'accepts a declaration written the stable way' {
        Get-PSMutationDeclaredKey -Result $script:inFn -Declared @{ 'a.ps1:Get-Thing:1 -> 2' = 'why' } |
            Should-Be 'a.ps1:Get-Thing:1 -> 2'
    }

    It 'prefers the stable form when a config declares both' {
        # Otherwise one mutant answering to two of its own keys would inflate the match
        # count and read as an ambiguous declaration (#28).
        Get-PSMutationDeclaredKey -Result $script:inFn -Declared @{
            'a.ps1:7:1 -> 2' = 'why'; 'a.ps1:Get-Thing:1 -> 2' = 'why' } |
            Should-Be 'a.ps1:Get-Thing:1 -> 2'
    }

    It 'returns nothing when no declaration covers the mutant' {
        Should-BeNull -Actual (Get-PSMutationDeclaredKey -Result $script:inFn -Declared @{ 'other:1:x -> y' = 'why' })
    }
}

Describe 'New-PSMutationProvenance' {
    BeforeAll {
        $script:prov = New-PSMutationProvenance -ModuleVersion '1.2.3' `
            -GeneratedAt ([datetime]::new(2026, 8, 20, 14, 5, 9, [DateTimeKind]::Utc)) `
            -BaselineSeconds 12.44 -TotalSeconds 354.06 -PerMutantTimeoutSeconds 50
    }

    It 'stamps the schema version so a reader can branch on a number' {
        # The point of the field: #20 had to reconcile two report shapes by hand, and #4
        # will have to tell a merged report from a plain one. Sniffing for keys is what a
        # version number exists to replace.
        $script:prov.schemaVersion | Should-Be 2
    }

    It 'attributes the report to a module build' {
        $script:prov.producedBy.module  | Should-Be 'PSMutant'
        $script:prov.producedBy.version | Should-Be '1.2.3'
    }

    It 'writes the timestamp as sortable UTC' {
        # Round-trippable as text and comparable between machines without knowing where
        # either ran -- a local-time stamp is neither.
        $script:prov.generatedAt | Should-Be '2026-08-20T14:05:09Z'
    }

    It 'converts a local timestamp to UTC rather than recording the wall clock' {
        # The discriminating case: a naive implementation formats whatever it was handed.
        $local = [datetime]::new(2026, 8, 20, 14, 5, 9, [DateTimeKind]::Utc).ToLocalTime()
        (New-PSMutationProvenance -GeneratedAt $local).generatedAt | Should-Be '2026-08-20T14:05:09Z'
    }

    It 'records the durations #1 and #7 need to be judged by' {
        # #1 is a large change to the runner justified entirely by speed, and today the only
        # way to evaluate it is timing two runs by hand. #7 is invisible as a trend without
        # the timeout recorded next to the baseline it was derived from.
        $script:prov.durations.baselineSeconds         | Should-Be 12.4
        $script:prov.durations.totalSeconds            | Should-Be 354.1
        $script:prov.durations.perMutantTimeoutSeconds | Should-Be 50
    }

    It 'rounds seconds to one decimal but leaves the timeout whole' {
        # Sub-decisecond precision is noise in a wall-clock measurement, and a whole-second
        # timeout printed as 50.0 reads as though it were a measurement too.
        $p = New-PSMutationProvenance -BaselineSeconds 1.2345 -TotalSeconds 9.8765 -PerMutantTimeoutSeconds 15
        $p.durations.baselineSeconds         | Should-Be 1.2
        $p.durations.totalSeconds            | Should-Be 9.9
        $p.durations.perMutantTimeoutSeconds | Should-Be 15
    }
}

Describe 'the provenance a report carries' {
    It 'writes the block into a full report' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-prov-$PID-$($script:tag)/report.json"
        try {
            $prov = New-PSMutationProvenance -ModuleVersion '9.9.9' -BaselineSeconds 1 -TotalSeconds 2 -PerMutantTimeoutSeconds 15
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null -Provenance $prov | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.schemaVersion            | Should-Be 2
            $json.producedBy.version       | Should-Be '9.9.9'
            $json.durations.totalSeconds   | Should-Be 2
            # Asserted against the FILE, not the parsed object: ConvertFrom-Json recognises
            # an ISO-8601 string and hands back a [datetime], so a PowerShell reader never
            # sees the text. The file is the contract -- other languages read a string --
            # so that is what has to be pinned.
            [System.IO.File]::ReadAllText($out) | Should-MatchString '"generatedAt": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still writes a report when no provenance is supplied' {
        # The parameter is optional so a caller that has not been updated -- or a test --
        # gets a report rather than an error. The fields are simply absent.
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-noprov-$PID-$($script:tag)/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            (Get-Content $out -Raw | ConvertFrom-Json).mutationScore | Should-Be 66.7
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}


Describe 'ConvertTo-PSMutationList' {
    # The normaliser behind #158. One place, so the three report list fields cannot drift.
    It 'turns $null into an empty array rather than a one-element array of $null' {
        $got = ConvertTo-PSMutationList -Value $null
        @($got).Count | Should-Be 0
    }

    It 'keeps every real element, in order' {
        # Paired with the test above deliberately: a normaliser that returned @() for
        # everything would pass that one on its own.
        # -Actual rather than a pipe: the function returns `,@(...)` so that an EMPTY result
        # survives the pipeline, and piping that into a collection assertion presents it as one
        # item. Pester says so in its own hint.
        Should-BeCollection -Expected @('b', 'a') -Actual (ConvertTo-PSMutationList -Value @('b', 'a'))
    }

    It 'keeps an EMPTY STRING, which is a value a caller may hold' {
        # Only $null is a phantom. Dropping '' would be a second, quieter version of the same
        # bug -- a caller's real entry silently vanishing from a published list.
        @(ConvertTo-PSMutationList -Value @('')).Count | Should-Be 1
    }

    It 'drops a $null sitting among real elements' {
        Should-BeCollection -Expected @('a', 'b') -Actual (ConvertTo-PSMutationList -Value @('a', $null, 'b'))
    }
}


Describe 'the score reports the denominator it was computed over' {
    # A score with no file count cannot be read: 100% across eight files and 100% across nine
    # are the same number, and only one of them covers the ninth. This repo is the live case --
    # one src/ file is deliberately outside the mutate list (#22), and until now nothing in the
    # output said so.
    It 'counts the files the config asked to mutate' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-fm-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
                -MutateFiles @('src/A.ps1', 'src/B.ps1', 'src/C.ps1') | Out-Null
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).filesMutated | Should-Be 3
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports zero rather than omitting the field when nothing was named' {
        # Absent and zero are different answers, and the schema requires the field on a full
        # run, so the empty case must still produce a number.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-fm0-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            $raw = [System.IO.File]::ReadAllText($out)
            $raw.Contains('"filesMutated": 0') | Should-BeTrue
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not count an empty entry as a file' {
        # Paired with the count above so this pins the filter rather than passing on any
        # number: three entries in, one of them empty, two counted.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-fme-$([guid]::NewGuid())"
        try {
            $out = Join-Path $dir 'r.json'
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
                -MutateFiles @('src/A.ps1', '', 'src/B.ps1') | Out-Null
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).filesMutated | Should-Be 2
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Write-PSMutationPartialReport' {
    BeforeAll {
        $script:pRoot = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-partial-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:pRoot -Force | Out-Null
        $script:pProv = New-PSMutationProvenance -ModuleVersion '1.2.3' `
            -BaselineSeconds 1 -TotalSeconds 2 -PerMutantTimeoutSeconds 30
        function script:WritePartial {
            param($Results = @(), [int]$Planned = 7)
            $path = Join-Path $script:pRoot "p-$([System.Guid]::NewGuid().ToString('N')).json"
            $null = Write-PSMutationPartialReport -Results $Results -Planned $Planned -ReportPath $path `
                -Operators @('BinaryOperator') -SourceHashes @{ 'a.ps1' = 'h' } `
                -TestFileLength @{ 'tests/a.Tests.ps1' = 42 } -Provenance $script:pProv
            return (Get-Content $path -Raw | ConvertFrom-Json)
        }
    }
    AfterAll { Remove-Item $script:pRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records what each mapped test file measured, so a resume can be refused when one shrank' {
        # A partial report exists to be READ BACK. -ResumeFrom carries over every verdict in it,
        # and those are only as good as the tests that produced them: adding a test cannot revive
        # a mutant this run killed, editing or deleting one can, and a resume never re-looks.
        # Without this field Get-PSMutationMergeFault refuses every resume -- correctly, since it
        # cannot tell, and uselessly, since that is every partial report there is.
        (script:WritePartial).testFiles.'tests/a.Tests.ps1' | Should-Be 42
    }

    It 'marks the document Partial so nothing reads it as a measurement' {
        (script:WritePartial).mode | Should-Be 'Partial'
    }

    It 'reports evaluated AND planned, because one without the other is not progress' {
        # A bare count cannot be read: 140 mutants is most of a 150-mutant run and a fraction
        # of a 3000-mutant one. The denominator is what makes the number mean anything, and it
        # is deliberately not divided out here -- see the next test.
        $doc = script:WritePartial -Results @([pscustomobject]@{ Id = 'm1'; Status = 'Killed' }) -Planned 303
        $doc.evaluated | Should-Be 1
        $doc.planned   | Should-Be 303
    }

    It 'never writes a score, however tempting the arithmetic' {
        # The whole reason for a separate mode. The loop evaluates in candidate order, so an
        # interrupted run has seen whichever files sort earliest -- not a sample of anything.
        $doc = script:WritePartial -Results @(
            [pscustomobject]@{ Id = 'm1'; Status = 'Killed' }
            [pscustomobject]@{ Id = 'm2'; Status = 'Survived' })
        $doc.PSObject.Properties.Name | Should-NotContainCollection 'mutationScore'
        $doc.PSObject.Properties.Name | Should-NotContainCollection 'thresholds'
        $doc.PSObject.Properties.Name | Should-NotContainCollection 'killed'
    }

    It 'names the survivors it did find, so a follow-up has something to read' {
        # Same field name as both other shapes. A report that calls this list anything else
        # cannot seed a -RecheckFrom round: the compatibility gate accepts it, selection then
        # finds nothing, and the run reports a confident "you are done".
        $doc = script:WritePartial -Results @(
            [pscustomobject]@{ Id = 'm1'; Status = 'Killed' }
            [pscustomobject]@{ Id = 'm2'; Status = 'Survived' })
        @($doc.survivors).Count | Should-Be 1
        $doc.survivors[0].Id | Should-Be 'm2'
    }

    It 'carries the provenance block the other two shapes carry' {
        # So a consumer reads provenance one way from any report rather than learning a third
        # convention. Wiring a field into two writers and not the third is invisible until
        # somebody opens the file.
        $doc = script:WritePartial
        $doc.generatedFrom          | Should-Be 'PSMutant'
        $doc.schemaVersion          | Should-Be 2
        $doc.producedBy.module      | Should-Be 'PSMutant'
        $doc.durations.totalSeconds | Should-Be 2
    }

    It 'records the hashes and operators this partial was numbered against' {
        # What a later run needs to prove the ids still mean the same mutants.
        $doc = script:WritePartial
        $doc.sourceHashes.'a.ps1' | Should-Be 'h'
        @($doc.operators)         | Should-ContainCollection 'BinaryOperator'
    }

    It 'returns the path it wrote, so the caller can name it' {
        # The caller is printing the only notice anybody gets that a file exists, in the middle
        # of a run being torn down. A writer that returns nothing makes that message say
        # "wrote a partial report to " and stop.
        $path = Join-Path $script:pRoot "ret-$([System.Guid]::NewGuid().ToString('N')).json"
        $returned = Write-PSMutationPartialReport -Results @() -Planned 3 -ReportPath $path `
            -Operators @('BinaryOperator') -SourceHashes @{ 'a.ps1' = 'h' } `
            -TestFileLength @{ 'tests/a.Tests.ps1' = 42 } -Provenance $script:pProv
        $returned | Should-Be $path
    }

    It 'writes a document for a run interrupted before ANY mutant finished' {
        # The earliest possible interruption, and the one a naive implementation drops: zero
        # rows is still the answer to "what did it get through", and a caller that cancels
        # immediately should find a file saying so rather than nothing.
        $doc = script:WritePartial -Results @() -Planned 303
        $doc.evaluated | Should-Be 0
        $doc.planned   | Should-Be 303
        @($doc.mutants).Count | Should-Be 0
    }
}

Describe 'the report discloses whether its killer lists are complete' {
    BeforeAll {
        $script:kbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-kb-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:kbRoot -Force | Out-Null
        $script:kbProv = New-PSMutationProvenance -ModuleVersion '1.2.3' `
            -BaselineSeconds 1 -TotalSeconds 2 -PerMutantTimeoutSeconds 30
        function script:WriteKb {
            param([bool]$Complete, $Rows, [string[]]$Mapped = @('a.Tests.ps1', 'b.Tests.ps1'))
            $path = Join-Path $script:kbRoot "r-$([System.Guid]::NewGuid().ToString('N')).json"
            $null = Write-PSMutationReport -Results $Rows -Thresholds @{ high = 85; low = 70 } `
                -Provenance $script:kbProv -SourceHashes @{ 'a.ps1' = 'h' } -Operators @('BinaryOperator') `
                -ReportPath $path -KillersComplete $Complete -MappedTests $Mapped
            return (Get-Content $path -Raw | ConvertFrom-Json)
        }
        $script:kbRows = @(
            [pscustomobject]@{ Id = 1; Function = 'f'; File = 'a.ps1'; Line = 1; Operator = 'BinaryOperator'
                Description = 'd'; Status = 'Killed'; KilledBy = @('a.Tests.ps1') }
            [pscustomobject]@{ Id = 2; Function = 'f'; File = 'a.ps1'; Line = 2; Operator = 'BinaryOperator'
                Description = 'd'; Status = 'Survived'; KilledBy = @() }
        )
    }
    AfterAll { Remove-Item $script:kbRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'always says which shape the killer lists are' -ForEach @(
        @{ Complete = $true }
        @{ Complete = $false }
    ) {
        # Written on every run, not only the complete one. A consumer that had to infer it from
        # the presence of another field would be guessing at exactly the point where guessing
        # turns a truncated list into a claim about test quality.
        (script:WriteKb -Complete $Complete -Rows $script:kbRows).killersComplete | Should-Be $Complete
    }

    It 'names the tests that killed nothing ONLY when the lists are complete' {
        # The whole reason the disclosure exists. Under the default early stop a test that would
        # have killed but was skipped is indistinguishable from one that cannot kill at all, and
        # what a reader does with this list is delete things.
        $complete = script:WriteKb -Complete $true -Rows $script:kbRows
        $complete.PSObject.Properties.Name | Should-ContainCollection 'testsWithoutKills'
        @($complete.testsWithoutKills) | Should-BeCollection @('b.Tests.ps1')

        $partial = script:WriteKb -Complete $false -Rows $script:kbRows
        $partial.PSObject.Properties.Name | Should-NotContainCollection 'testsWithoutKills'
    }

    It 'counts a mapped test as killing nothing rather than omitting it' {
        # a.Tests.ps1 killed; b.Tests.ps1 did not. The list is derived from the MAPPED set, so a
        # test that ran and killed nothing is named -- deriving it from the killers instead would
        # produce an empty list and read as "every test pulls its weight".
        $doc = script:WriteKb -Complete $true -Rows $script:kbRows -Mapped @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1')
        @($doc.testsWithoutKills) | Should-BeCollection @('b.Tests.ps1', 'c.Tests.ps1')
    }
}

Describe 'Get-PSMutationPerFileScore' {
    BeforeAll {
        function script:Row([string]$File, [string]$Status, [int]$Id) {
            [pscustomobject]@{ Id = $Id; Function = 'f'; File = $File; Line = $Id
                Operator = 'BinaryOperator'; Description = "d$Id"; Status = $Status; KilledBy = @() }
        }
        # strong.ps1 is perfect; weak.ps1 is half. Blended that is 75%, which is the number a
        # single score would report and the reason this function exists.
        $script:mixed = @(
            (script:Row -File 'strong.ps1' -Status 'Killed' -Id 1), (script:Row -File 'strong.ps1' -Status 'Killed' -Id 2)
            (script:Row -File 'weak.ps1' -Status 'Killed' -Id 3), (script:Row -File 'weak.ps1' -Status 'Survived' -Id 4)
        )
    }

    It 'scores each file on its own rows, not on the blend' {
        $byFile = @{}
        foreach ($f in (Get-PSMutationPerFileScore -Results $script:mixed)) { $byFile[$f.file] = $f }
        $byFile['strong.ps1'].score | Should-Be 100
        $byFile['weak.ps1'].score | Should-Be 50
        # And the blend really is the number that hides it, so the fixture discriminates.
        (Get-PSMutationScore -Results $script:mixed).Score | Should-Be 75
    }

    It 'puts the WEAKEST file first' {
        # The order is the feature. A file needing attention at the bottom of an alphabetical
        # list is a file nobody reads about -- and 'strong' sorts before 'weak' alphabetically,
        # so this fixture tells the two orderings apart.
        $ordered = Get-PSMutationPerFileScore -Results $script:mixed
        $ordered[0].file | Should-Be 'weak.ps1'
    }

    It 'carries the counts the score was computed over' {
        # A percentage with no denominator cannot be read: 50% of two mutants and 50% of two
        # hundred are different facts about a file.
        $all = Get-PSMutationPerFileScore -Results $script:mixed
        $weak = @($all | Where-Object file -eq 'weak.ps1')[0]
        $weak.killed | Should-Be 1
        $weak.survived | Should-Be 1
        $weak.total | Should-Be 2
    }

    It 'honours a declared equivalent for the file it belongs to' {
        # The reason Get-PSMutationScore was written as a per-SET fold: a declaration belongs to
        # one file, and a per-file call must not count it against another. Here the declaration
        # excuses weak.ps1's survivor, taking it to 100% while strong.ps1 is untouched.
        $eq = [pscustomobject]@{ 'weak.ps1:f:d4' = 'excused for the test' }
        $byFile = @{}
        foreach ($f in (Get-PSMutationPerFileScore -Results $script:mixed -Equivalents $eq)) { $byFile[$f.file] = $f }
        $byFile['weak.ps1'].declaredEquivalent | Should-Be 1
        $byFile['weak.ps1'].score | Should-Be 100
        $byFile['strong.ps1'].declaredEquivalent | Should-Be 0
    }

    It 'returns an empty collection for a run with no rows' {
        # A run whose files contribute no covered candidates is legitimate, and must produce an
        # empty list rather than $null -- the report serialises this straight into JSON, where
        # null and [] are different answers.
        $empty = Get-PSMutationPerFileScore -Results @()
        Should-BeFalse -Actual ($null -eq $empty) -Because 'null and [] are different in JSON'
        $empty.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationWeakFileLine' {
    BeforeAll {
        $script:pf = @(
            [pscustomobject]@{ file = 'src/strong.ps1'; score = 100; killed = 90; total = 90 }
            [pscustomobject]@{ file = 'src/weak.ps1'; score = 39.6; killed = 19; total = 48 }
            [pscustomobject]@{ file = 'src/middling.ps1'; score = 78; killed = 39; total = 50 }
        )
    }

    It 'names only the files below the good band' {
        $lines = Get-PSMutationWeakFileLine -PerFile $script:pf -High 85 -Low 70
        $text = ($lines | ForEach-Object { $_.Text }) -join ' '
        $text | Should-MatchString 'weak.ps1'
        $text | Should-MatchString 'middling.ps1'
        # The strong file is the noise this filter exists to remove: listing every file puts the
        # one needing attention somewhere inside a wall of 100%s.
        $text | Should-NotMatchString 'strong.ps1'
    }

    It 'colours a weak file by its OWN score, not the run''s' {
        # The whole point. A file in the red must read as red even when the blend it sits inside
        # is green -- reusing the headline's role would paint it with the average that hides it.
        $lines = Get-PSMutationWeakFileLine -PerFile $script:pf -High 85 -Low 70
        @($lines | Where-Object { $_.Text -match 'weak\.ps1' })[0].Role | Should-Be 'Bad'
        @($lines | Where-Object { $_.Text -match 'middling\.ps1' })[0].Role | Should-Be 'Warn'
    }

    It 'treats a file exactly AT the band as good, not weak' {
        # The boundary, and the direction matters: `high` is the score at which a file is
        # considered good, so a file sitting exactly on it must not be listed as needing
        # attention. Without this case the comparison can be relaxed to -le and nothing notices,
        # because no other fixture scores exactly the threshold.
        $atBand = @(
            [pscustomobject]@{ file = 'src/exactly.ps1'; score = 85; killed = 85; total = 100 }
            [pscustomobject]@{ file = 'src/under.ps1'; score = 84.9; killed = 849; total = 1000 }
        )
        $lines = Get-PSMutationWeakFileLine -PerFile $atBand -High 85 -Low 70
        $text = ($lines | ForEach-Object { $_.Text }) -join ' '
        $text | Should-NotMatchString 'exactly\.ps1'
        # The neighbour a hair below IS listed, so this cannot pass by printing nothing at all.
        $text | Should-MatchString 'under\.ps1'
    }

    It 'says nothing when every file is at or above the band' {
        $lines = Get-PSMutationWeakFileLine -PerFile @($script:pf[0], $script:pf[0]) -High 85 -Low 70
        $lines.Count | Should-Be 0
    }

    It 'says nothing when only ONE file was mutated' {
        # With one file the blend IS that file, so a breakdown would restate the headline under a
        # heading implying it found something. Asserted with a file that WOULD otherwise qualify,
        # so this cannot pass for the reason the test above passes.
        $lines = Get-PSMutationWeakFileLine -PerFile @($script:pf[1]) -High 85 -Low 70
        $lines.Count | Should-Be 0
    }

    It 'returns an empty collection rather than $null' {
        # The caller does AddRange on it. A $null there is a binding failure at the end of a run
        # that otherwise succeeded, which is the worst possible moment for one.
        $lines = Get-PSMutationWeakFileLine -PerFile @() -High 85 -Low 70
        Should-BeFalse -Actual ($null -eq $lines)
        $lines.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationSurvivorBaselineFault' {
    BeforeAll {
        function script:Sv([string]$File, [string]$Fn, [string]$Desc, [string]$Status) {
            [pscustomobject]@{ File = $File; Function = $Fn; Description = $Desc; Status = $Status; Line = 1 }
        }
        $script:key = 'src/a.ps1:Get-Thing:-gt -> -le'
        $script:base = ('{ "' + $script:key + '": "" }') | ConvertFrom-Json
        $script:mutate = @('src/a.ps1')
    }

    It 'says nothing when no baseline is configured' {
        # The default. The gate is off unless the config names a path, so an ordinary run must not
        # acquire a new way to fail.
        $f = Get-PSMutationSurvivorBaselineFault -Results @(script:Sv -File 'src/a.ps1' -Fn 'X' -Desc 'd' -Status 'Survived') `
            -Baseline $null -MutateFiles $script:mutate
        @($f).Count | Should-Be 0
    }

    It 'accepts a survivor that is recorded' {
        $f = Get-PSMutationSurvivorBaselineFault `
            -Results @(script:Sv -File 'src/a.ps1' -Fn 'Get-Thing' -Desc '-gt -> -le' -Status 'Survived') `
            -Baseline $script:base -MutateFiles $script:mutate
        @($f).Count | Should-Be 0
    }

    It 'reports a survivor that is NOT recorded' {
        # The core rule. Adding under-tested code adds a survivor, and that is the one thing this
        # gate exists to fail on.
        $f = Get-PSMutationSurvivorBaselineFault -Results @(
            (script:Sv -File 'src/a.ps1' -Fn 'Get-Thing' -Desc '-gt -> -le' -Status 'Survived')
            (script:Sv -File 'src/a.ps1' -Fn 'New-Thing' -Desc '+ -> -' -Status 'Survived')
        ) -Baseline $script:base -MutateFiles $script:mutate
        ($f -join ' ') | Should-MatchString 'NEW survivor not in the baseline: src/a.ps1:New-Thing'
    }

    It 'reports a recorded survivor that has been FIXED' {
        # Otherwise the ratchet has slack: the entry stays, and the mutant can start surviving
        # again later with nothing failing. Discrete and meaningful -- it fires exactly when
        # somebody kills a mutant, unlike the same rule over a score.
        $f = Get-PSMutationSurvivorBaselineFault `
            -Results @(script:Sv -File 'src/a.ps1' -Fn 'Get-Thing' -Desc '-gt -> -le' -Status 'Killed') `
            -Baseline $script:base -MutateFiles $script:mutate
        ($f -join ' ') | Should-MatchString 'no longer survives'
    }

    It 'reports a recorded survivor whose file has left the mutate list' {
        # THE GAMING VECTOR. Dropping the weak file hides its survivors rather than fixing them,
        # and the blended score goes up while less of the project is measured.
        $f = Get-PSMutationSurvivorBaselineFault -Results @() -Baseline $script:base -MutateFiles @('src/other.ps1')
        ($f -join ' ') | Should-MatchString 'no longer in mutate'
    }

    It 'refuses an entry that is ALSO declared equivalent' {
        # Both at once permits nothing: the declaration already excuses the mutant outright, so
        # the baseline entry records debt that is not owed -- and the two would disagree the day
        # somebody deletes one.
        $eq = [pscustomobject]@{ $script:key = 'cannot be killed' }
        $f = Get-PSMutationSurvivorBaselineFault `
            -Results @(script:Sv -File 'src/a.ps1' -Fn 'Get-Thing' -Desc '-gt -> -le' -Status 'Survived') `
            -Baseline $script:base -MutateFiles $script:mutate -Equivalents $eq
        ($f -join ' ') | Should-MatchString 'both declared equivalent and accepted'
    }

    It 'ignores killed mutants that were never recorded' {
        # The ordinary case: most mutants die and belong nowhere in this file. A rule that
        # reported them would make the baseline a list of everything.
        $f = Get-PSMutationSurvivorBaselineFault -Results @(
            (script:Sv -File 'src/a.ps1' -Fn 'Get-Thing' -Desc '-gt -> -le' -Status 'Survived')
            (script:Sv -File 'src/a.ps1' -Fn 'Other' -Desc 'x' -Status 'Killed')
        ) -Baseline $script:base -MutateFiles $script:mutate
        @($f).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationUpdatedSurvivorBaseline' {
    It 'records exactly the survivors, keyed stably and sorted' {
        $b = Get-PSMutationUpdatedSurvivorBaseline -Results @(
            [pscustomobject]@{ File = 'src/z.ps1'; Function = 'Z'; Description = 'd'; Status = 'Survived'; Line = 9 }
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'A'; Description = 'd'; Status = 'Survived'; Line = 1 }
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'K'; Description = 'd'; Status = 'Killed'; Line = 2 }
        )
        # ONE, while a report says two. The baseline is a different document with its own
        # format, and it did not change here -- sharing the report's constant would have
        # re-versioned a file nothing about which moved.
        $b.schemaVersion | Should-Be 1
        @($b.survivors.PSObject.Properties.Name) | Should-BeCollection @('src/a.ps1:A:d', 'src/z.ps1:Z:d')
    }

    It 'keys by FUNCTION, not by line, so an entry survives a line moving' {
        # A baseline is committed once and reviewed rarely. A line-keyed entry churns whenever
        # anything above it is edited, and an entry nobody can trust is one nobody reads.
        $b = Get-PSMutationUpdatedSurvivorBaseline -Results @(
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'A'; Description = 'd'; Status = 'Survived'; Line = 400 })
        @($b.survivors.PSObject.Properties.Name) | Should-BeCollection @('src/a.ps1:A:d')
    }

    It 'writes an empty map for a run with nothing surviving' {
        # The state a project reaches when the debt is paid off. It must be representable, or
        # -UpdateBaseline would refuse the one run everybody wants.
        $b = Get-PSMutationUpdatedSurvivorBaseline -Results @(
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'A'; Description = 'd'; Status = 'Killed'; Line = 1 })
        # @( ) around the PROPERTIES, not around their Names. Member enumeration over an empty
        # collection yields $null, so @(....Properties.Name).Count is 1 where there are none; and
        # the collection exposes no .Count of its own, which comes back $null. Measured all three.
        @($b.survivors.PSObject.Properties).Count | Should-Be 0
        # And it must serialise as {} rather than null -- this is the state a project reaches when
        # the debt is paid off, and a null there would read as "no baseline" on the next run.
        ($b | ConvertTo-Json -Compress) | Should-MatchString '"survivors":\{\}'
    }
}

Describe 'a survivor-baseline fault decides the run' {
    BeforeAll { $script:cleanSummary = [pscustomobject]@{ Score = 100; StaleEquivalents = @() } }

    It 'reports SurvivorBaseline, and does so BEFORE the threshold' {
        # Both can be true at once, and the baseline fault is the more specific one: reporting
        # 'BelowThreshold' for a run that grew a new survivor sends the reader to argue about the
        # number instead of reading the mutant it grew. The summary here is deliberately BELOW
        # the break threshold, so the ordering is what the assertion tests.
        $low = [pscustomobject]@{ Score = 10; StaleEquivalents = @() }
        Get-PSMutationFailureReason -Summary $low -Thresholds @{ break = 90 } -BaselineFault @('new survivor') |
            Should-Be 'SurvivorBaseline'
    }

    It 'leaves an ordinary run alone' {
        # The pairing: without it, a decision that always returned SurvivorBaseline would satisfy
        # the test above.
        Get-PSMutationFailureReason -Summary $script:cleanSummary -Thresholds @{ break = 90 } |
            Should-Be 'None'
        Get-PSMutationFailureReason -Summary $script:cleanSummary -Thresholds @{ break = 90 } -BaselineFault @() |
            Should-Be 'None'
    }

    It 'turns a baseline fault into a non-zero exit code' {
        # The exit code is what a CI job reads. A reason nobody can act on is a reason nobody sees.
        Get-PSMutationExitCode -Summary $script:cleanSummary -Thresholds @{ break = 90 } -BaselineFault @('x') |
            Should-Be 1
        Get-PSMutationExitCode -Summary $script:cleanSummary -Thresholds @{ break = 90 } |
            Should-Be 0
    }
}

Describe 'Invoke-PSMutationSurvivorBaseline' {
    BeforeEach {
        $script:bDir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:bDir -Force | Out-Null
        $script:bPath = Join-Path $script:bDir 'baseline.json'
        $script:oneSurvivor = @([pscustomobject]@{ Id = 1; Function = 'F'; File = 'src/a.ps1'
                Line = 1; Operator = 'BinaryOperator'; Description = 'd'; Status = 'Survived'; KilledBy = @() })
    }

    It 'writes the baseline and reports no fault under -Update' {
        # The adoption run. It writes even though this run has an unaccepted survivor, which is
        # the whole point -- refusing would make the first run impossible.
        $f = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
            -MutateFiles @('src/a.ps1') -Update -Quiet
        @($f).Count | Should-Be 0
        $doc = Get-Content $script:bPath -Raw | ConvertFrom-Json
        @($doc.survivors.PSObject.Properties.Name) | Should-BeCollection @('src/a.ps1:F:d')
    }

    It 'returns an empty collection, never $null, on the update path' {
        # The caller feeds this straight into Get-PSMutationFailureReason, whose parameter refuses
        # $null. A run that wrote its baseline would otherwise fail at the very last step.
        $f = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results @() `
            -MutateFiles @('src/a.ps1') -Update -Quiet
        Should-BeFalse -Actual ($null -eq $f)
    }

    It 'treats a MISSING baseline as empty, so every survivor is new' {
        # Not as "no baseline configured". A config that names a baseline it has not created must
        # not silently enforce nothing -- that is a gate that cannot fire wearing the shape of a
        # passing run.
        $f = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
            -MutateFiles @('src/a.ps1') -Quiet
        ($f -join ' ') | Should-MatchString 'NEW survivor not in the baseline'
    }

    It 'reports nothing when the recorded baseline matches the run' {
        '{ "schemaVersion": 1, "survivors": { "src/a.ps1:F:d": "" } }' |
            Set-Content -LiteralPath $script:bPath -Encoding utf8
        $f = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
            -MutateFiles @('src/a.ps1') -Quiet
        @($f).Count | Should-Be 0
    }

    It 'refuses a baseline that exists but cannot be parsed' {
        # An unreadable baseline treated as absent is a gate enforcing nothing while looking green.
        # A MISSING file is different, and is the ordinary first run -- covered above.
        'not json at all' | Set-Content -LiteralPath $script:bPath -Encoding utf8
        { Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
                -MutateFiles @('src/a.ps1') -Quiet } | Should-Throw
    }

    It 'prints each fault UNSILENCED, even under -Quiet' {
        # -Quiet silences the progress log; a finding is not log. In CI these lines are the only
        # place the mutants a reader must act on ever appear.
        Mock Write-PSMutationOutput { }
        $null = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
            -MutateFiles @('src/a.ps1') -Quiet
        Should-Invoke Write-PSMutationOutput -Times 1 -ParameterFilter {
            $Quiet -eq $false -and (($Lines | ForEach-Object { $_.Text }) -join ' ') -like '*NEW survivor*'
        }
    }

    It 'returns the faults as data, not only as printed text' {
        # The caller turns them into a failure reason and an exit code. A version that only printed
        # would leave a CI job green while the console said otherwise.
        $f = Invoke-PSMutationSurvivorBaseline -BaselinePath $script:bPath -Results $script:oneSurvivor `
            -MutateFiles @('src/a.ps1') -Quiet
        @($f).Count | Should-Be 1
        $f[0] | Should-MatchString 'src/a.ps1:F:d'
    }
}

Describe 'the two vacuous-100% sets' {
    BeforeAll {
        $script:vac = @(
            [pscustomobject]@{ File = 'src/ok.ps1'; Produced = 10; Kept = 8; ByOperator = [ordered]@{} }
            [pscustomobject]@{ File = 'src/uncovered.ps1'; Produced = 6; Kept = 0; ByOperator = [ordered]@{} }
            [pscustomobject]@{ File = 'src/nothing.ps1'; Produced = 0; Kept = 0; ByOperator = [ordered]@{} }
        )
    }

    It 'separates a file coverage emptied from one that produced nothing' {
        # Both contribute 0 of 0 and both look identical in a score. They are named apart
        # because the fixes differ: one is a test to write, the other is a file that does not
        # belong in `mutate` or holds nothing this module can mutate.
        Get-PSMutationFileEmptiedByCoverage -PerFile $script:vac | Should-Be 'src/uncovered.ps1'
        Get-PSMutationFileWithNoCandidate -PerFile $script:vac | Should-Be 'src/nothing.ps1'
    }

    It 'reports both on the exclusion object' {
        $ex = Get-PSMutationCoverageExclusion -PerFile $script:vac
        $ex.Skipped | Should-Be 8
        $ex.FilesWithNoMutants | Should-Be 'src/uncovered.ps1'
        $ex.FilesWithNoCandidate | Should-Be 'src/nothing.ps1'
    }

    It 'returns empty ARRAYS rather than $null when neither applies' {
        # A caller iterating these must not have to tell "none" from "the module stopped
        # reporting it".
        #
        # Asserted with -is [array], NOT with .Count. A function returning an empty array unrolls
        # it to $null, and $null.Count is 0 -- so the obvious `.Count | Should-Be 0` passes for
        # both answers and cannot fail. That assertion is exactly how this shipped broken.
        $ex = Get-PSMutationCoverageExclusion -PerFile @([pscustomobject]@{ File = 'a'; Produced = 3; Kept = 3 })
        $ex.FilesWithNoMutants -is [array] | Should-BeTrue
        $ex.FilesWithNoCandidate -is [array] | Should-BeTrue
        $ex.FilesWithNoMutants.Count | Should-Be 0
        $ex.FilesWithNoCandidate.Count | Should-Be 0
    }

    It 'hands back an ARRAY from each collector directly' {
        # The two functions themselves, not only what the exclusion object does with them: the
        # preview result publishes these, and a caller was promised something it can iterate.
        $clean = @([pscustomobject]@{ File = 'a'; Produced = 3; Kept = 3 })
        (Get-PSMutationFileWithNoCandidate -PerFile $clean) -is [array] | Should-BeTrue
        (Get-PSMutationFileEmptiedByCoverage -PerFile $clean) -is [array] | Should-BeTrue
    }
}

Describe 'Get-PSMutationExclusionLine with a no-candidate file' {
    It 'reports a no-candidate file even when the coverage filter skipped NOTHING' {
        # The arm that used to be unreachable. A file no operator matched contributes 0 of 0
        # whether or not coveredLinesOnly is set, so a caveat that only printed alongside a
        # coverage skip stayed silent on exactly the config that filters nothing.
        $ex = Get-PSMutationCoverageExclusion -PerFile @(
            [pscustomobject]@{ File = 'src/nothing.ps1'; Produced = 0; Kept = 0 })
        Get-PSMutationExclusionLine -Exclusion $ex | Should-MatchString 'src/nothing\.ps1'
    }

    It 'still says nothing when there is nothing to say' {
        $ex = Get-PSMutationCoverageExclusion -PerFile @(
            [pscustomobject]@{ File = 'src/ok.ps1'; Produced = 3; Kept = 3 })
        Get-PSMutationExclusionLine -Exclusion $ex | Should-Be ''
    }

    It 'reports BOTH when the filter skipped some and a file produced none' {
        $ex = Get-PSMutationCoverageExclusion -PerFile @(
            [pscustomobject]@{ File = 'src/partly.ps1'; Produced = 6; Kept = 2 }
            [pscustomobject]@{ File = 'src/nothing.ps1'; Produced = 0; Kept = 0 })
        $line = Get-PSMutationExclusionLine -Exclusion $ex
        $line | Should-MatchString '4 mutant\(s\) skipped as uncovered'
        $line | Should-MatchString 'src/nothing\.ps1'
    }
}

Describe 'Get-PSMutationMutantListLine' {
    BeforeAll {
        $script:listRows = @(
            [pscustomobject]@{ File = 'src/ok.ps1'; Produced = 10; Kept = 8
                ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 7; Kept = 6 }; BooleanLiteral = @{ Produced = 3; Kept = 2 } }
            }
            [pscustomobject]@{ File = 'src/nothing.ps1'; Produced = 0; Kept = 0; ByOperator = [ordered]@{} }
        )
    }

    It 'names every file and every operator that matched it' {
        $text = (Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $true -BaselineMeasured $true |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-MatchString 'src/ok\.ps1'
        $text | Should-MatchString 'src/nothing\.ps1'
        $text | Should-MatchString 'BinaryOperator'
        $text | Should-MatchString 'BooleanLiteral'
    }

    It 'totals what a run WOULD evaluate, which is the kept count' {
        # Not the produced count. The number a reader acts on is the one the loop would pay for.
        $text = (Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $true -BaselineMeasured $true |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-MatchString '8 mutant\(s\) over 2 file\(s\)'
    }

    It 'names a file that produced NO candidate as a vacuous 100%' {
        $text = (Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $true -BaselineMeasured $true |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-MatchString 'vacuous 100%'
    }

    It 'names a file the coverage filter emptied, separately' {
        $rows = @([pscustomobject]@{ File = 'src/uncovered.ps1'; Produced = 6; Kept = 0
                ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 6; Kept = 0 } }
            })
        $text = (Get-PSMutationMutantListLine -PerFile $rows -CoveredLinesOnly $true -BaselineMeasured $true |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-MatchString 'removed by the coverage filter'
        $text | Should-MatchString 'src/uncovered\.ps1'
        # And NOT the other caveat: the file produced six, so nothing about it is vacuous in
        # the sense the sibling line means.
        $text | Should-NotMatchString 'vacuous 100%'
    }

    It 'warns a reader when the counts are PRE-filter' {
        # coveredLinesOnly set but no coverage measured: the counts are an upper bound on what
        # a run would evaluate, and a preview that let them read as filtered would be the
        # confident wrong number this module exists to stop.
        $text = (Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $true -BaselineMeasured $false |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-MatchString 'coverage was not measured'
    }

    It 'says nothing about coverage when the config does not filter on it' {
        # Not merely absent from the caveat: the per-file rows must not show a "-> n covered"
        # column for a filter that is off, or a reader sees a filter that did not run.
        $text = (Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $false -BaselineMeasured $false |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-NotMatchString 'coverage was not measured'
        $text | Should-NotMatchString 'covered'
    }

    It 'flags a zero-candidate file with a role a renderer can see' {
        # The count is the thing to scan for, so the line carries it in the role rather than
        # only in the prose -- an annotation renderer has no prose to read.
        $lines = Get-PSMutationMutantListLine -PerFile $script:listRows -CoveredLinesOnly $false -BaselineMeasured $false
        $zero = @($lines | Where-Object { $_.Text -match 'src/nothing\.ps1' })
        $zero[0].Role | Should-Be 'Warn'
    }
}

Describe 'ConvertTo-PSMutationListResult' {
    BeforeAll {
        $script:resRows = @(
            [pscustomobject]@{ File = 'src/ok.ps1'; Produced = 10; Kept = 8; ByOperator = [ordered]@{} }
            [pscustomobject]@{ File = 'src/uncovered.ps1'; Produced = 6; Kept = 0; ByOperator = [ordered]@{} }
            [pscustomobject]@{ File = 'src/nothing.ps1'; Produced = 0; Kept = 0; ByOperator = [ordered]@{} }
        )
    }

    It 'shares Mode, ExitCode and FailureReason with the other run shapes' {
        # So a caller that did not choose the mode can still branch on the result.
        $r = ConvertTo-PSMutationListResult -PerFile $script:resRows -BaselineMeasured $true
        $r.Mode | Should-Be 'List'
        $r.ExitCode | Should-Be 0
        $r.FailureReason | Should-Be 'None'
    }

    It 'never manufactures a verdict, whatever it found' {
        # It evaluated nothing. A preview that failed the build would be a verdict over a set
        # nobody measured -- the same reason a recheck applies no thresholds. The two sets are
        # handed over by name so a caller can fail its OWN build on them.
        $r = ConvertTo-PSMutationListResult -PerFile $script:resRows -BaselineMeasured $true
        $r.ExitCode | Should-Be 0
        $r.FilesWithNoCandidate | Should-Be 'src/nothing.ps1'
        $r.FilesEmptiedByCoverage | Should-Be 'src/uncovered.ps1'
    }

    It 'counts produced and would-be-evaluated separately' {
        $r = ConvertTo-PSMutationListResult -PerFile $script:resRows -BaselineMeasured $true
        $r.Files | Should-Be 3
        $r.Produced | Should-Be 16
        $r.Total | Should-Be 8
    }

    It 'carries whether Total is filtered or an upper bound' {
        # A caller cannot re-derive this from the numbers.
        (ConvertTo-PSMutationListResult -PerFile $script:resRows -BaselineMeasured $false).BaselineMeasured | Should-BeFalse
        (ConvertTo-PSMutationListResult -PerFile $script:resRows -BaselineMeasured $true).BaselineMeasured | Should-BeTrue
    }

    It 'returns zeroes and empty arrays for an empty mutate set' {
        $r = ConvertTo-PSMutationListResult -PerFile @() -BaselineMeasured $true
        $r.Files | Should-Be 0
        $r.Total | Should-Be 0
        # -is [array], not .Count: see the collector test above for why .Count cannot fail here.
        $r.FilesWithNoCandidate -is [array] | Should-BeTrue
        $r.FilesEmptiedByCoverage -is [array] | Should-BeTrue
    }
}

Describe 'Get-PSMutationExclusionLine boundaries' {
    It 'says nothing for a $null exclusion' {
        # $null reaches here from callers that do no filtering at all. For them "nothing was
        # skipped" is the true answer, and the empty string is what says it -- not $null, which
        # a caller appending to a summary would render as a blank line it did not ask for.
        Get-PSMutationExclusionLine -Exclusion $null | Should-Be ''
    }

    It 'does NOT append the no-candidate note when every file produced something' {
        # The false arm of the second caveat, on the path where the FIRST one fired. Without it
        # the guard can be forced true -- appending a note naming zero files -- and forced to
        # -ge, which fires on the same zero. Both survived until this existed.
        $ex = Get-PSMutationCoverageExclusion -PerFile @(
            [pscustomobject]@{ File = 'src/partly.ps1'; Produced = 6; Kept = 2 })
        $line = Get-PSMutationExclusionLine -Exclusion $ex
        $line | Should-MatchString '4 mutant\(s\) skipped as uncovered'
        $line | Should-NotMatchString 'vacuous 100%'
    }
}

Describe 'Get-PSMutationMutantListRow' {
    BeforeAll {
        $script:row = [pscustomobject]@{ File = 'src/ok.ps1'; Produced = 10; Kept = 8
            ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 7; Kept = 6 } }
        }
    }

    It 'shows the covered count on both the file row and its operator rows' {
        # EXACT text on both. The two tails are separate expressions a few lines apart, so an
        # assertion on one certifies nothing about the other -- and each survived its own mutant
        # while the other was asserted.
        $t = @(Get-PSMutationMutantListRow -Row $script:row -ShowCovered $true | ForEach-Object { $_.Text })
        $t[0] | Should-Be '     10 src/ok.ps1 -> 8 covered'
        $t[1] | Should-Be '      7     BinaryOperator -> 6'
    }

    It 'omits it on both when coverage was not measured' {
        $t = @(Get-PSMutationMutantListRow -Row $script:row -ShowCovered $false | ForEach-Object { $_.Text })
        $t[0] | Should-Be '     10 src/ok.ps1'
        $t[1] | Should-Be '      7     BinaryOperator'
    }

    It 'marks a file with candidates as Detail, not Warn' {
        # The other arm of the role decision. Only the zero row was asserted, so forcing the
        # condition true -- every file a warning -- passed.
        (Get-PSMutationMutantListRow -Row $script:row -ShowCovered $false)[0].Role | Should-Be 'Detail'
    }

    It 'marks a file the filter emptied as Warn' {
        $zero = [pscustomobject]@{ File = 'src/none.ps1'; Produced = 4; Kept = 0; ByOperator = [ordered]@{} }
        (Get-PSMutationMutantListRow -Row $zero -ShowCovered $true)[0].Role | Should-Be 'Warn'
    }
}

Describe 'Get-PSMutationMutantListLine, the covered column' {
    BeforeAll {
        $script:one = @([pscustomobject]@{ File = 'src/ok.ps1'; Produced = 10; Kept = 8
                ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 10; Kept = 8 } }
            })
    }

    It 'shows the covered column only when the config filters AND coverage was measured' -ForEach @(
        @{ Covered = $true; Measured = $true; Shown = $true }
        @{ Covered = $true; Measured = $false; Shown = $false }
        # The row that tells -and from -or. Measured without a filter to apply is a real state --
        # a full run of a config with coveredLinesOnly off -- and there is nothing to show for it.
        @{ Covered = $false; Measured = $true; Shown = $false }
        @{ Covered = $false; Measured = $false; Shown = $false }
    ) {
        $text = (Get-PSMutationMutantListLine -PerFile $script:one -CoveredLinesOnly $Covered -BaselineMeasured $Measured |
                ForEach-Object { $_.Text }) -join "`n"
        # The COLUMN, not the word: the pre-filter caveat says "coveredLinesOnly is set but
        # coverage was not measured", so a bare 'covered' matches the very row that must not
        # show a column.
        if ($Shown) { $text | Should-MatchString '8 covered' } else { $text | Should-NotMatchString '-> 8 covered' }
    }

    It 'names no emptied file when the filter emptied none' {
        # The false arm of the last caveat. Forced true it names zero files; forced to -ge it
        # fires on the same zero. Neither had a test.
        $text = (Get-PSMutationMutantListLine -PerFile $script:one -CoveredLinesOnly $true -BaselineMeasured $true |
                ForEach-Object { $_.Text }) -join "`n"
        $text | Should-NotMatchString 'removed by the coverage filter'
    }
}

Describe 'Get-PSMutationFailureReason with an empty scope' {
    BeforeAll {
        # 0 of 0 under a break threshold: the shape a documentation-only pull request produces.
        $script:emptySummary = [pscustomobject]@{ Score = 0; Total = 0; Killed = 0; StaleEquivalents = @() }
        $script:break50 = [pscustomobject]@{ break = 50 }
    }

    It 'fails a zero score by default, because that is an ordinary shortfall' {
        # The row that makes the next one mean something: without -EmptyScope this DOES fail.
        Get-PSMutationFailureReason -Summary $script:emptySummary -Thresholds $script:break50 |
            Should-Be 'BelowThreshold'
    }

    It 'passes when the scope matched no mutable file' {
        # A pull request that touched only documentation changed nothing this module can measure.
        # An empty run scores 0, so without this arm the gate fails it for having nothing to say.
        Get-PSMutationFailureReason -Summary $script:emptySummary -Thresholds $script:break50 `
            -EmptyScope $true | Should-Be 'None'
    }

    It 'gives exit code 0 for the same run, so the two cannot disagree' {
        Get-PSMutationExitCode -Summary $script:emptySummary -Thresholds $script:break50 -EmptyScope $true |
            Should-Be 0
        Get-PSMutationExitCode -Summary $script:emptySummary -Thresholds $script:break50 |
            Should-Be 1
    }

    It 'outranks even a stale declaration, because nothing was examined' {
        # FIRST in the order deliberately: every rule below it is about a measurement, and a run
        # that mutated nothing made none. A scoped run would otherwise report every declaration
        # in the project as stale.
        $s = [pscustomobject]@{ Score = 0; Total = 0; StaleEquivalents = @('src/x.ps1:F:d -- no such mutant') }
        Get-PSMutationFailureReason -Summary $s -Thresholds $script:break50 | Should-Be 'StaleEquivalents'
        Get-PSMutationFailureReason -Summary $s -Thresholds $script:break50 -EmptyScope $true | Should-Be 'None'
    }
}

Describe 'Get-PSMutationDeclarationCoverageFault scoping' {
    BeforeAll {
        $script:decls = [pscustomobject]@{
            'src/a.ps1:Get-A:x -> y' = 'declared'
            'src/b.ps1:Get-B:p -> q' = 'declared'
        }
        # Only a.ps1's declaration matched a mutant; b.ps1's matched nothing because the run
        # never looked at b.ps1.
        $script:aOnly = @([pscustomobject]@{ File = 'src/a.ps1'; Function = 'Get-A'
                Description = 'x -> y'; Line = 1; Status = 'Survived'
            })
    }

    It 'calls an unmatched declaration stale on a whole-tree run' {
        # The rule this function exists for, and the row that makes the next one mean something.
        $f = Get-PSMutationDeclarationCoverageFault -Results $script:aOnly -Equivalents $script:decls
        @($f).Count | Should-Be 1
        @($f)[0] | Should-MatchString 'src/b\.ps1'
    }

    It 'does NOT call it stale when its file was out of scope' {
        # THE hazard that would make -ChangedFile unusable: a declaration about a file the run
        # never examined matches nothing, and reported as stale it fails the gate at any score.
        $f = Get-PSMutationDeclarationCoverageFault -Results $script:aOnly -Equivalents $script:decls `
            -InScopeFile @('src/a.ps1')
        @($f).Count | Should-Be 0
    }

    It 'still judges a declaration whose file IS in scope' {
        # The other half. Scoping must narrow which declarations are judged, never stop judging.
        $f = Get-PSMutationDeclarationCoverageFault -Results @() -Equivalents $script:decls `
            -InScopeFile @('src/a.ps1')
        @($f).Count | Should-Be 1
        @($f)[0] | Should-MatchString 'src/a\.ps1'
    }
}

Describe 'Get-PSMutationDeclarationFile' {
    It 'takes everything before the first colon' -ForEach @(
        @{ Key = 'src/a.ps1:Get-A:x -> y'; File = 'src/a.ps1' }
        @{ Key = 'src/a.ps1:55:6 -> 7'; File = 'src/a.ps1' }
    ) {
        Get-PSMutationDeclarationFile -Key $Key | Should-Be $File
    }

    It 'yields an empty file when the key STARTS with a colon' {
        # The boundary the index test turns on. `-le 0` or `-lt 1` would return the whole key
        # here, which then matches no scoped file -- a declaration silently excused rather than
        # judged. Malformed, but it must fail the ordinary way.
        Get-PSMutationDeclarationFile -Key ':Get-A:x -> y' | Should-Be ''
    }

    It 'yields the whole string when there is no colon' {
        # An unparseable key then matches no scoped file and falls to the ordinary staleness
        # check, rather than being silently excused by a parse failure.
        Get-PSMutationDeclarationFile -Key 'nonsense' | Should-Be 'nonsense'
    }
}

Describe 'Write-PSMutationReport and the scope it was measured over' {
    BeforeAll {
        $script:scopeDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-scope-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:scopeDir -Force | Out-Null
    }
    AfterAll { Remove-Item $script:scopeDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes neither mode nor changedFiles on a whole-tree run' {
        # ABSENT, not null. The schema's mode is an enum, so "mode": null on every full report
        # would make each one invalid -- and absent is how a full run says it measured everything.
        $out = Join-Path $script:scopeDir 'full.json'
        Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
        $names = (Get-Content $out -Raw | ConvertFrom-Json).PSObject.Properties.Name
        $names -contains 'mode' | Should-BeFalse
        $names -contains 'changedFiles' | Should-BeFalse
    }

    It 'writes both, together, on a scoped run' {
        # Together on purpose: the schema requires changedFiles whenever mode is Changed, because
        # a percentage over part of a tree that does not say which part is the number this module
        # exists to stop people quoting.
        $out = Join-Path $script:scopeDir 'scoped.json'
        Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null `
            -ChangedFiles @('src/a.ps1') | Out-Null
        $doc = Get-Content $out -Raw | ConvertFrom-Json
        $doc.mode | Should-Be 'Changed'
        $doc.changedFiles | Should-Be 'src/a.ps1'
    }
}
