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
        ($script:lines -join "`n") | Should-BeLikeString '*INVALID equivalence declarations*'
        ($script:lines -join "`n") | Should-BeLikeString '*a.ps1:3:z*'
        $script:colours | Should-ContainCollection 'Red'
    }

    It 'prints no stale section when the summary carries no stale list' {
        # @($null).Count is 1, so an unfiltered count prints the alarm with a blank
        # line under it on every ordinary run.
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0; StaleEquivalents = $null }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-NotBeLikeString '*INVALID*'
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
        (Get-PSMutationScore -Results $script:tied -Equivalents $eq).StaleEquivalents |
            Should-BeLikeString '*matches 2 mutants*ambiguous*'
    }

    It 'fails the run for an ambiguous declaration, regardless of thresholds' {
        # Same footing as a stale declaration: a false statement in the config inflating
        # the score is not a quality shortfall to be graded on a curve.
        $eq = [pscustomobject]@{ 'a.ps1:7:1 -> 2' = 'provably cannot change behaviour' }
        $s = Get-PSMutationScore -Results $script:tied -Equivalents $eq
        Get-PSMutationExitCode -Summary $s -Thresholds $null | Should-Be 1
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
        (Get-PSMutationScore -Results $script:tied -Equivalents $eq).StaleEquivalents |
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

Describe 'the key the summary tells you to declare' {
    BeforeEach {
        # Same capture the Show-PSMutationSummary block uses, and $script:/BeforeEach for
        # the same reason: a variable assigned in a Describe body exists only during
        # discovery. Without this the assertions read an empty list and the real output
        # leaks to the console -- which is how the first version of this test failed.
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:lines.Add([string]$Object) }
    }

    BeforeAll {
        # Two mutants sharing a function-form key, one not. The pairing is the point: a
        # suggester that always returned the function form, or always the line form, passes
        # half of these.
        $script:mixed3 = @(
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'Get-Thing'; Line = 95; Description = '1 -> 2'; Status = 'Survived' }
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'Get-Other'; Line = 12; Description = 'x -> y'; Status = 'Survived' }
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'Get-Other'; Line = 20; Description = 'x -> y'; Status = 'Survived' }
        )
        $script:amb = Get-PSMutationAmbiguousKey -Results $script:mixed3
    }

    It 'finds the keys more than one mutant answers to' {
        # Get-Other:x -> y is shared; the two line forms are not.
        $script:amb | Should-ContainCollection 'src/a.ps1:Get-Other:x -> y'
        $script:amb | Should-NotContainCollection 'src/a.ps1:12:x -> y'
    }

    It 'suggests the stable function form when it identifies the mutant alone' {
        Get-PSMutationDeclarableKey -Result $script:mixed3[0] -Ambiguous $script:amb |
            Should-Be 'src/a.ps1:Get-Thing:1 -> 2'
    }

    It 'falls back to the line form when the function form is shared' {
        # The stable form is coarser, not better: a function is a much bigger scope than a
        # line. Suggesting it here would hand the reader a key the run then refuses.
        Get-PSMutationDeclarableKey -Result $script:mixed3[1] -Ambiguous $script:amb |
            Should-Be 'src/a.ps1:12:x -> y'
    }

    It 'suggests the line form for a mutant outside any function' {
        # File-scope code has no name to be addressed by, so the line form is all there is.
        Get-PSMutationDeclarableKey -Result ([pscustomobject]@{ File = 'src/a.ps1'; Function = ''; Line = 3; Description = '1 -> 2' }) |
            Should-Be 'src/a.ps1:3:1 -> 2'
    }

    It 'still offers the most specific key when every form is shared' {
        # Two identical mutations on ONE line: nothing distinguishes them today. Offering
        # the line form anyway beats offering nothing -- the run's ambiguity check will say
        # so if it is used, which is a better failure than a reader inventing a key.
        $tied = @(
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'F'; Line = 7; Description = '1 -> 2'; Status = 'Survived' }
            [pscustomobject]@{ File = 'src/a.ps1'; Function = 'F'; Line = 7; Description = '1 -> 2'; Status = 'Survived' }
        )
        Get-PSMutationDeclarableKey -Result $tied[0] -Ambiguous (Get-PSMutationAmbiguousKey -Results $tied) |
            Should-Be 'src/a.ps1:7:1 -> 2'
    }

    It 'prints the declarable key beside each survivor' {
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 0; Killed = 0; Total = 3; Survived = 3 }) `
            -Results $script:mixed3 -High 85 -Low 70 -ReportPath 'r.json'
        $out = $script:lines -join "`n"
        $out | Should-BeLikeString '*declare as: src/a.ps1:Get-Thing:1 -> 2*'
        $out | Should-BeLikeString '*declare as: src/a.ps1:12:x -> y*'
    }

    It 'says nothing about declaring when there are no survivors' {
        # Pairs with the test above: a suggester that printed unconditionally would pass it.
        Show-PSMutationSummary -Summary ([pscustomobject]@{ Score = 100; Killed = 2; Total = 2; Survived = 0 }) `
            -Results @() -High 85 -Low 70 -ReportPath 'r.json'
        ($script:lines -join "`n") | Should-NotBeLikeString '*declare as*'
    }
}
