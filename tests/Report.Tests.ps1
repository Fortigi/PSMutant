# Unit tests for the scoring/report layer (pure + one temp write).
# Also the covering suite for self-mutating src/PSMutation.Report.ps1 - keep it self-contained.

BeforeAll {
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
    It 'keys on file, line and the change, not the mutant id' {
        # Ids renumber when anything earlier in the file changes; a declaration
        # keyed on one would silently start pointing at a different mutant.
        Get-PSMutationEquivalentKey -Result ([pscustomobject]@{ Id = 9; File = 'a.ps1'; Line = 3; Description = '6 -> 7' }) |
            Should-Be 'a.ps1:3:6 -> 7'
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
    It 'writes a JSON report with the score and survivors' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-report-$PID/report.json"
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
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-report2-$PID/report.json"
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

Describe 'ConvertTo-PSMutationRunResult' {
    It 'exposes the score, the counts and the exit code' {
        # This object is the module's public contract -- CI reads .Score and .ExitCode.
        $s = [pscustomobject]@{ Score = 64.3; Killed = 164; Survived = 91; Total = 255 }

        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1

        $r.Score    | Should-Be 64.3
        $r.Killed   | Should-Be 164
        $r.Survived | Should-Be 91
        $r.Total    | Should-Be 255
        $r.ExitCode | Should-Be 1
    }

    It 'keeps killed and survived distinct' {
        # Numbers chosen so a swapped pair cannot pass: equal counts would hide it.
        $s = [pscustomobject]@{ Score = 50; Killed = 3; Survived = 7; Total = 10 }
        $r = ConvertTo-PSMutationRunResult -Summary $s -ExitCode 0
        $r.Killed   | Should-Be 3
        $r.Survived | Should-Be 7
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
        (ConvertTo-PSMutationRunResult -Summary $s -ExitCode 1).PSObject.Properties.Name |
            Should-BeCollection @('Score', 'Killed', 'Survived', 'Total', 'ExitCode')
    }

    It 'writes exactly the documented top-level report fields' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-contract-$PID/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            (Get-Content $out -Raw | ConvertFrom-Json).PSObject.Properties.Name |
                Should-BeCollection @(
                    'generatedFrom', 'schemaVersion', 'producedBy', 'generatedAt', 'durations',
                    'mutationScore', 'total', 'killed', 'survived', 'timedOut',
                    'declaredEquivalent', 'skippedAsUncovered', 'filesWithNoMutants',
                    'filesWithoutTestMapping',
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

    It 'offers only the line form for a mutant at file scope' {
        Get-PSMutationEquivalentKey -Result $script:atTop | Should-BeCollection @('a.ps1:3:1 -> 2')
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
        $script:prov.schemaVersion | Should-Be 1
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
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-prov-$PID/report.json"
        try {
            $prov = New-PSMutationProvenance -ModuleVersion '9.9.9' -BaselineSeconds 1 -TotalSeconds 2 -PerMutantTimeoutSeconds 15
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null -Provenance $prov | Out-Null
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.schemaVersion            | Should-Be 1
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
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-noprov-$PID/report.json"
        try {
            Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds $null | Out-Null
            (Get-Content $out -Raw | ConvertFrom-Json).mutationScore | Should-Be 66.7
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
