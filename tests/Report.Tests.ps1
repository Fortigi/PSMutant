# Unit tests for the scoring/report layer (pure + one temp write).
# Also the covering suite for self-mutating src/PSMutation.Report.ps1 - keep it self-contained.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Report.ps1')

    $script:mixed = @(
        [pscustomobject]@{ File = 'a.ps1'; Line = 1; Operator = 'BinaryOperator'; Description = 'x'; Status = 'Killed' }
        [pscustomobject]@{ File = 'a.ps1'; Line = 2; Operator = 'BinaryOperator'; Description = 'y'; Status = 'Killed' }
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
        $s = Get-PSMutationScore -Results $script:mixed -Equivalents $eq
        @($s.StaleEquivalents).Count | Should-Be 1
        $s.StaleEquivalents[0] | Should-BeLikeString '*no such mutant exists*'
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

Describe 'Show-PSMutationSummary' {
    BeforeEach {
        # $script: and set in BeforeEach, not the Describe body: a variable assigned
        # in a Describe body only exists during discovery, so at run time it is $null
        # -- and `84 -ge $null` is TRUE, which silently paints every score green.
        $script:lines = [System.Collections.Generic.List[string]]::new()
        $script:colours = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:lines.Add([string]$Object); $script:colours.Add([string]$ForegroundColor) }
    }

    It 'prints the score and every survivor with its file, line and change' {
        # The survivor list IS the tool's output -- a caller works from these lines,
        # so dropping the line number or the change text makes the run useless even
        # though the score still looks right. Asserted on the killed/total text
        # rather than the percentage, which renders as 66,7 under a comma locale.
        Show-PSMutationSummary -Summary (Get-PSMutationScore -Results $script:mixed) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-BeLikeString '*2 killed / 3*'
        ($script:lines -join "`n") | Should-BeLikeString '*a.ps1:3*z*'
        ($script:lines -join "`n") | Should-BeLikeString '*r.json*'
    }

    It 'does not print a survivor section when nothing survived' {
        Show-PSMutationSummary -Summary (Get-PSMutationScore -Results @([pscustomobject]@{ Status = 'Killed' })) `
            -Results @([pscustomobject]@{ Status = 'Killed' }) -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-NotBeLikeString '*Survivors*'
    }

    It 'says how many mutants were excluded as declared-equivalent' -ForEach @(
        @{ Count = 1 }   # the discriminating case: `-gt 0` and `-gt 1` agree at 0 and 3
        @{ Count = 3 }
    ) {
        # A 100% built on a dozen declarations is a different claim from a 100% that
        # killed everything, and the reader must not have to open the config to
        # tell them apart. ONE exclusion is the case that separates "any" from
        # "more than one" -- at exactly one declaration, `-gt 1` prints nothing.
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; DeclaredEquivalent = $Count }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-BeLikeString "*$Count mutant(s) excluded as declared-equivalent*"
    }

    It 'does not list a declared equivalent among the survivors to go and fix' {
        # It is excluded from the score, so listing it as work sends the reader
        # after a mutant the config already argued is unkillable.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = 'cannot change behaviour' }
        Show-PSMutationSummary -Summary (Get-PSMutationScore -Results $script:mixed -Equivalents $eq) `
            -Results $script:mixed -High 85 -Low 70 -ReportPath 'r.json' -Equivalents $eq
        ($script:lines -join "`n") | Should-NotBeLikeString '*a.ps1:3*'
        ($script:lines -join "`n") | Should-NotBeLikeString '*Survivors*'
    }

    It 'still lists an undeclared survivor alongside a declared one' {
        # The filter must remove only what was declared; dropping the whole section
        # would hide real work behind one declaration.
        $eq = [pscustomobject]@{ 'a.ps1:3:z' = 'cannot change behaviour' }
        $results = $script:mixed + [pscustomobject]@{ File = 'a.ps1'; Line = 9; Operator = 'BinaryOperator'; Description = 'q'; Status = 'Survived' }
        Show-PSMutationSummary -Summary (Get-PSMutationScore -Results $results -Equivalents $eq) `
            -Results $results -High 85 -Low 70 -ReportPath 'r.json' -Equivalents $eq
        ($script:lines -join "`n") | Should-BeLikeString '*a.ps1:9*q*'
        ($script:lines -join "`n") | Should-NotBeLikeString '*a.ps1:3*'
    }

    It 'stays silent about exclusions when there are none' {
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; DeclaredEquivalent = 0 }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-NotBeLikeString '*declared-equivalent*'
    }

    It 'prints stale declarations loudly, with the offending key' {
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0
                                          StaleEquivalents = @('a.ps1:3:z -- declared equivalent but the suite killed it') }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-BeLikeString '*STALE equivalence declarations*'
        ($script:lines -join "`n") | Should-BeLikeString '*a.ps1:3:z*'
        $script:colours | Should-ContainCollection 'Red'
    }

    It 'prints no stale section when the summary carries no stale list' {
        # @($null).Count is 1, so an unfiltered count prints the alarm with a blank
        # line under it on every ordinary run.
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; StaleEquivalents = $null }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-NotBeLikeString '*STALE*'
    }

    It 'colours the score green at the high threshold, yellow between, red below low' -ForEach @(
        @{ Score = 85; Expected = 'Green'  }   # exactly high: the boundary, not 86
        @{ Score = 84; Expected = 'Yellow' }   # one below high
        @{ Score = 70; Expected = 'Yellow' }   # exactly low
        @{ Score = 69; Expected = 'Red'    }   # one below low
    ) {
        # Boundary values, not comfortable ones: 90/50 would pass just as happily
        # against `-gt` as against `-ge`, and would never notice the bands sliding.
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = $Score; Killed = 1; Total = 2; Survived = 0 }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        $script:colours | Should-ContainCollection $Expected
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

Describe 'Get-PSMutationScoreColour' {
    It 'colours <Score> against 85/70 as <Expected>' -ForEach @(
        @{ Score = 100; High = 85; Low = 70; Expected = 'Green'  }
        @{ Score = 85;  High = 85; Low = 70; Expected = 'Green'  }   # exactly high: -ge, not -gt
        @{ Score = 84;  High = 85; Low = 70; Expected = 'Yellow' }   # one below high
        @{ Score = 70;  High = 85; Low = 70; Expected = 'Yellow' }   # exactly low
        @{ Score = 69;  High = 85; Low = 70; Expected = 'Red'    }   # one below low
        @{ Score = 0;   High = 85; Low = 70; Expected = 'Red'    }   # the #40 headline
    ) {
        # Boundary values, not comfortable ones: 90/50 would pass just as happily against
        # `-gt` as against `-ge`, and would never notice the bands sliding by one.
        Get-PSMutationScoreColour -Score $Score -High $High -Low $Low | Should-Be $Expected
    }

    It 'reads red at zero even against bands of zero' {
        # Guards the degenerate config rather than assuming nobody writes it: with both
        # bands at 0 every score is at or above high, so zero is green -- which is correct
        # and is the user's explicit choice, not the silent null-comparison that made
        # every score green regardless of what the config said.
        Get-PSMutationScoreColour -Score 0 -High 0 -Low 0 | Should-Be 'Green'
    }

    It 'prefers green over yellow when the bands overlap' {
        # High below Low is a nonsense config, but it must still be decided rather than
        # crash: the first branch wins, so the result is Green.
        Get-PSMutationScoreColour -Score 50 -High 40 -Low 60 | Should-Be 'Green'
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
                    'generatedFrom', 'mutationScore', 'total', 'killed', 'survived',
                    'declaredEquivalent', 'staleEquivalents', 'thresholds', 'operators',
                    'sourceHashes', 'survivors', 'mutants')
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }

}
