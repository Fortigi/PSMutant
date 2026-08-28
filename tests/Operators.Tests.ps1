# Unit tests for the pure AST operator layer. A mutation tool that mis-locates an
# offset would silently corrupt source, so the splice + every operator is pinned here.
# Also the covering suite for self-mutation (psmutant.self.config.json) - keep it pure.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')

    function Get-BadSyntaxFile {
        # Exactly ONE parse error. The count matters: the guard is `Count -gt 0`, and
        # a two-error file cannot tell that apart from `-gt 1`.
        param([string]$Name)
        $p = Join-Path $TestDrive $Name
        Set-Content -Path $p -Value 'if ($a) {' -Encoding utf8
        return $p
    }

    $script:fixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-ops-$PID.ps1"
    @'
function Test-Fixture {
    param($x)
    if ($x -eq 1) { return $true }
    $flag = $false
    $name = 'hello'
    return (-not $flag)
}
'@ | Set-Content $script:fixture

    $script:all = 'BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'StringLiteral', 'NegationRemoval'
    $script:cands = Get-PSMutationCandidate -Path $script:fixture -Operators $script:all
}

AfterAll { Remove-Item $script:fixture -ErrorAction SilentlyContinue }

Describe 'Get-PSMutationCandidate - operators' {
    It 'maps the binary operator -eq to -ne' {
        $c = $script:cands | Where-Object Operator -eq 'BinaryOperator'
        $c.Original | Should-Be '-eq'
        $c.Mutated  | Should-Be '-ne'
    }
    It 'flips both boolean literals' {
        $b = $script:cands | Where-Object Operator -eq 'BooleanLiteral'
        ($b | Where-Object Original -eq '$true').Mutated  | Should-Be '$false'
        ($b | Where-Object Original -eq '$false').Mutated | Should-Be '$true'
    }
    It 'mutates the numeric literal to N+1' {
        ($script:cands | Where-Object Operator -eq 'NumberLiteral').Mutated | Should-Be '2'
    }
    It 'empties a quoted string but never a bareword/command name' {
        ($script:cands | Where-Object Operator -eq 'StringLiteral').Mutated | Should-Be "''"
        @($script:cands | Where-Object Original -like '*Fixture*').Count | Should-Be 0
    }
    It 'offers negation removal down to the inner expression' {
        ($script:cands | Where-Object Operator -eq 'NegationRemoval').Mutated | Should-MatchString '\$flag'
    }
    It 'assigns ids as exactly 1..N (unique, sequential, starting at 1)' {
        $ids = @($script:cands.Id)
        $ids | Should-BeCollection (1..$ids.Count)
    }
}

Describe 'Get-PSMutationCandidate - operator selection' {
    It 'excludes StringLiteral from the default set' {
        $d = Get-PSMutationCandidate -Path $script:fixture
        @($d | Where-Object Operator -eq 'StringLiteral').Count  | Should-Be 0
        @($d | Where-Object Operator -eq 'BinaryOperator').Count | Should-BeGreaterThan 0
    }
    It 'emits nothing when no operators are enabled' {
        @(Get-PSMutationCandidate -Path $script:fixture -Operators @()).Count | Should-Be 0
    }
    It 'throws on a script with parse errors' {
        $bad = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-bad-$PID.ps1"
        'function {' | Set-Content $bad
        { Get-PSMutationCandidate -Path $bad } | Should-Throw
        Remove-Item $bad -ErrorAction SilentlyContinue
    }
}

Describe 'Loop guard' {
    It 'never emits a candidate inside a while/for condition' {
        $loop = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-loop-$PID.ps1"
        "function L { `$i = 0; while (`$i -lt 10) { `$i = `$i + 1 }; for (`$j = 0; `$j -gt 3; `$j++) { } }" | Set-Content $loop
        try {
            $c = Get-PSMutationCandidate -Path $loop -Operators $script:all
            @($c | Where-Object Original -eq '-lt').Count | Should-Be 0
            @($c | Where-Object Original -eq '-gt').Count | Should-Be 0
            @($c | Where-Object { $_.Operator -eq 'BinaryOperator' -and $_.Original -eq '+' }).Count | Should-BeGreaterThan 0
        }
        finally { Remove-Item $loop -ErrorAction SilentlyContinue }
    }
}

Describe 'Skipped constructs' {
    # Every collector has a "not this one" branch, and none of them were exercised:
    # an operator outside the map, a bareword, an empty string, and the loop guard on
    # the boolean/string/negation collectors (only the binary one was covered).
    # Each case below pairs the skipped construct with an IDENTICAL one that is not
    # skipped, so the assertion says "this is filtered" rather than merely "nothing
    # came back".
    BeforeAll {
        $script:skipFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-skips-$PID.ps1"
        @'
function Skip-Cases {
    $done = $false
    $mode = 'go'
    while ($true -and -not $done -and $mode -ne 'stop') { $done = $true }
    if ($mode -like 'g*') { Write-Output 'outside' }
    if ($mode -eq 'go') { $empty = '' }
    return (-not $done)
}
'@ | Set-Content $script:skipFixture -Encoding utf8
        $script:skipCands = Get-PSMutationCandidate -Path $script:skipFixture -Operators $script:all
    }
    AfterAll { Remove-Item $script:skipFixture -ErrorAction SilentlyContinue }

    It 'ignores a binary operator it has no mutation for' {
        # -like has no opposite in the map; -eq, on the same kind of node, does.
        @($script:skipCands | Where-Object Original -eq '-like').Count | Should-Be 0
        @($script:skipCands | Where-Object Original -eq '-eq').Count   | Should-BeGreaterThan 0
    }

    It 'never empties a bareword, only a quoted string' {
        # Write-Output is a StringConstantExpressionAst too; emptying it would delete
        # the command itself rather than mutate a value.
        @($script:skipCands | Where-Object Original -like '*Write-Output*').Count | Should-Be 0
        @($script:skipCands | Where-Object Original -eq "'outside'").Count        | Should-BeGreaterThan 0
    }

    It 'ignores an already-empty string' {
        # '' -> '' is not a mutation; it would be born surviving.
        $strings = @($script:skipCands | Where-Object Operator -eq 'StringLiteral')
        @($strings | Where-Object Original -eq "''").Count | Should-Be 0
        $strings.Count | Should-BeGreaterThan 0
    }

    It 'applies the loop guard to booleans, strings and negations, not just operators' {
        # Everything in the while CONDITION is skipped -- mutating a loop condition
        # tends to hang the run rather than fail a test. The loop BODY is fair game,
        # which is what makes each pair below discriminate.
        $inCondition = @($script:skipCands | Where-Object Original -eq "'stop'")
        @($inCondition).Count | Should-Be 0                                  # string in condition
        @($script:skipCands | Where-Object Original -eq '-not $done').Count          | Should-BeGreaterThan 0  # negation outside
        @($script:skipCands | Where-Object Operator -eq 'BooleanLiteral').Count | Should-BeGreaterThan 0    # $true in the body
        # ...and the negation that sits inside the condition is not among them.
        @($script:skipCands | Where-Object { $_.Operator -eq 'NegationRemoval' }).Count | Should-Be 1
    }
}

Describe 'Set-PSMutationText' {
    It 'splices exactly the operator extent, leaving the rest intact' {
        $content = [System.IO.File]::ReadAllText($script:fixture)
        $c = $script:cands | Where-Object Operator -eq 'BinaryOperator' | Select-Object -First 1
        $mutated = Set-PSMutationText -Content $content -Candidate $c
        $mutated | Should-MatchString '\$x -ne 1'
        $mutated.Length | Should-Be $content.Length
        $mutated.Substring(0, $c.StartOffset) | Should-Be $content.Substring(0, $c.StartOffset)
    }
    It 'produces a still-parseable script' {
        $content = [System.IO.File]::ReadAllText($script:fixture)
        $c = $script:cands | Where-Object Operator -eq 'BooleanLiteral' | Select-Object -First 1
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseInput((Set-PSMutationText -Content $content -Candidate $c), [ref]$null, [ref]$errs) | Out-Null
        $errs.Count | Should-Be 0
    }
}

Describe 'New-PSMutationCandidate' {
    It 'stamps line/offsets from the extent' {
        $c = $script:cands | Select-Object -First 1
        $c.Line | Should-BeGreaterThan 0
        $c.EndOffset | Should-BeGreaterThan $c.StartOffset
    }
}

Describe 'Get-PSMutationCandidate - unparseable input' {
    It 'refuses a file with a single syntax error' {
        # One error, not two: the guard is `Count -gt 0`, and a two-error fixture
        # passes just as happily against `-gt 1` -- under which a file with exactly
        # one syntax error would be parsed anyway and mutated from a broken AST.
        { Get-PSMutationCandidate -Path (Get-BadSyntaxFile 'one-error.ps1') } |
            Should-Throw -ExceptionMessage '*parse errors*'
    }

    It 'reports the FIRST parse error message, not an empty one' {
        # The message comes from $errors[0]. Read as $errors[1], a single-error file
        # yields $null and the throw says "parse errors:" with nothing after it --
        # still an error, but one that tells you nothing about what is wrong.
        { Get-PSMutationCandidate -Path (Get-BadSyntaxFile 'one-error-msg.ps1') } |
            Should-Throw -ExceptionMessage "*Missing closing '}'*"
    }

    It 'names the file it could not parse' {
        $p = Get-BadSyntaxFile 'named.ps1'
        { Get-PSMutationCandidate -Path $p } | Should-Throw -ExceptionMessage '*named.ps1*'
    }
}

Describe 'Mutant ids' {
    It 'numbers candidates from 1, contiguously, within a file' {
        # -RecheckFrom matches survivors by (file, id), so the numbering is a
        # contract, not an implementation detail: a gap or a restart would make a
        # recheck select the wrong mutants.
        $ids = @($script:cands | ForEach-Object Id)
        $ids | Should-BeCollection @(1..$ids.Count)
    }

    It 'leaves an unnumbered candidate at the 0 sentinel' {
        # Candidates are built with Id = 0 and numbered afterwards. The sentinel has
        # to be outside the real range: at 1 it would be indistinguishable from a
        # genuine first mutant, so a candidate that never got numbered would look
        # like a valid recheck target.
        $c = New-PSMutationCandidate -Extent ([pscustomobject]@{ StartLineNumber = 7; StartOffset = 1; EndOffset = 2 }) `
            -File 'f.ps1' -Original 'a' -Mutated 'b' -Operator 'BinaryOperator'
        $c.Id | Should-Be 0
    }
}

Describe 'Structural operators (opt-in)' {
    BeforeAll {
        # Decisions that live in STRUCTURE rather than in an expression: a bare variable
        # guard, a reference-fallback chain, a boundary comparison, a returned value.
        $script:structFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-struct-$PID.ps1"
        @'
function Test-Structural {
    param($Ref, $Sync, $i)
    $step = -$i
    if ($Sync) { Write-Output 'sync' }
    if ($Ref.Value) { return $Ref.Value }
    elseif ($Ref.Name) { return 'named' }
    if ($true) { Write-Output 'always' }
    if ($Ref.Kind -eq 'user') { return $null }
    while ($i -lt 3) { $i = $i + $step }
    if ($i -gt 2) { return $i }
    return
}
'@ | Set-Content $script:structFixture -Encoding utf8

        # A whole file whose only decision is a bare guard -- the shape that scores a
        # vacuous 100% today, taken from the two files named in the issue.
        $script:bareFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-bare-$PID.ps1"
        @'
function Invoke-Phase {
    param($SyncUsers)
    if ($SyncUsers) { Write-Output 'ran' }
}
'@ | Set-Content $script:bareFixture -Encoding utf8

        # The two constructs the operator used to be blind to, alongside the shapes it must
        # still decline. `switch` is the idiomatic PowerShell multi-way decision and a ternary
        # compiles to no if-node at all, so a consumer leaning on either saw ConditionForcing
        # report almost nothing.
        $script:decisionFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-decision-$PID.ps1"
        @'
function Get-Kind {
    param($x, $mode)
    $kind = switch ($x) {
        1              { 'one' }
        { $_ -gt 5 }   { 'big' }
        { $mode }      { 'moded' }
        default        { 'none' }
    }
    $label = $x ? 'set' : 'unset'
    while ($x ? $true : $false) { break }
    return "$kind/$label"
}
'@ | Set-Content $script:decisionFixture -Encoding utf8
    }

    AfterAll {
        Remove-Item $script:structFixture, $script:bareFixture, $script:decisionFixture -ErrorAction SilentlyContinue
    }

    Context 'ConditionForcing' {
        BeforeAll {
            $script:forced = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('ConditionForcing'))
        }

        It 'reaches a decision the whole default set cannot touch' {
            # THE reason this operator exists. A phase guard is a real decision -- does
            # this phase run for this config? -- but it holds no comparison, no literal
            # and no negation, so every default operator emits nothing and the file
            # scores 100% while nothing has been tested at all.
            @(Get-PSMutationCandidate -Path $script:bareFixture).Count | Should-Be 0
            @(Get-PSMutationCandidate -Path $script:bareFixture -Operators @('ConditionForcing')).Count | Should-Be 2
        }

        It 'forces each condition BOTH ways' {
            # One direction alone is not enough: a test that only ever exercises the
            # true branch is killed by forcing $false and never notices forcing $true.
            $sync = @($script:forced | Where-Object Original -eq '$Sync')
            $sync.Mutated | Should-BeCollection @('$true', '$false')
        }

        It 'forces an elseif clause, not just the leading if' {
            # Clauses after the first are where a fallback CHAIN lives, and precedence
            # between them is exactly the risk in a chain of reference lookups.
            @($script:forced | Where-Object Original -eq '$Ref.Name').Count | Should-Be 2
        }

        It 'forces a TERNARY condition, which compiles to no if-node at all' {
            # A reader sees an obvious branch; the AST has no IfStatementAst, so the operator
            # was blind to it -- and every expression operator is blind too when the condition
            # is a bare variable, which is the usual shape.
            $tern = @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object { $_.Line -eq 9 })
            @($tern).Count | Should-Be 2
            ($tern.Mutated | Sort-Object) | Should-BeCollection @('$false', '$true')
        }

        It 'forces a SCRIPT-BLOCK switch clause, both ways' {
            # A script-block clause is evaluated as a condition, so forcing it behaves exactly
            # like an if: { $true } always matches and shadows every later clause, { $false }
            # never matches.
            $sb = @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object Original -eq '{ $_ -gt 5 }')
            @($sb).Count | Should-Be 2
            ($sb.Mutated | Sort-Object) | Should-BeCollection @('{ $false }', '{ $true }')
        }

        It 'forces a VALUE switch clause to always match and to never match' {
            # This replaces a test that asserted the opposite, and the reversal is the fix.
            #
            # The earlier reading was that forcing a value clause could not force a decision --
            # true of splicing a bare `$true` over `1`, which merely changes what the clause is
            # compared against. Wrapping it in a SCRIPT BLOCK makes it a condition, and that is an
            # ordinary offset splice like every other operator, not the syntax rewrite the issue
            # and I both assumed it needed.
            $vals = @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object Original -eq '1')
            @($vals).Count | Should-Be 2
            ($vals.Mutated | Sort-Object) | Should-BeCollection @('{ $false }', '{ $true }')
        }

        It 'forces a value clause to a SCRIPT BLOCK, never to a bare $true' {
            # The distinction the whole change turns on. PowerShell matches a clause with
            # `$_ -eq <clause>`, so a bare `$true` spliced over `1` stops matching x=1 and starts
            # matching x=$true -- a value substitution with murky semantics. The script-block form
            # always matches, which is what forcing means everywhere else in this operator.
            @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object { $_.Mutated -eq '$true' -and $_.Original -eq '1' }) | Should-BeCollection @()
        }

        It 'declines the DEFAULT clause, which has no condition to force' {
            # It is not in Clauses at all -- SwitchStatementAst carries it separately -- so this
            # pins that the walk does not reach for it. Removing the whole clause would be the
            # analogous mutation, and that is statement removal rather than condition forcing.
            @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object Original -like '*default*') | Should-BeCollection @()
        }

        It 'leaves a ternary in a LOOP CONDITION alone' {
            # The shared no-mutate zone, which the two new constructs have to respect exactly as
            # the if does: forcing `while ($x ? $true : $false)` to $true is an unconditional
            # hang, not a fault worth reporting. Line 10 is the while; line 9 is the assignment
            # above it, and the test above proves that one IS forced -- so this is a pair, not a
            # bare absence that would pass if the operator emitted nothing at all.
            @(Get-PSMutationCandidate -Path $script:decisionFixture -Operators @('ConditionForcing') |
                    Where-Object { $_.Line -eq 10 }) | Should-BeCollection @()
        }

        It 'skips a condition that is already the value it would be forced to' {
            # `if ($true)` forced to $true splices identical source: an unkillable
            # mutant that can only inflate the survivor list.
            $already = @($script:forced | Where-Object Original -eq '$true')
            @($already | Where-Object Mutated -eq '$true').Count  | Should-Be 0
            @($already | Where-Object Mutated -eq '$false').Count | Should-Be 1
        }

        It 'never forces a loop condition' {
            # Forcing `while (X)` to $true is an unconditional hang, not a fault worth
            # reporting -- the same reason the other operators skip loop conditions.
            @($script:forced | Where-Object Original -like '*$i -lt 3*').Count | Should-Be 0
            # ...while an `if` on the same variable IS mutated, so this says "filtered"
            # rather than merely "nothing came back".
            @($script:forced | Where-Object Original -eq '$i -gt 2').Count | Should-Be 2
        }
    }

    Context 'ConditionalBoundary' {
        BeforeAll {
            $script:bounds = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('ConditionalBoundary'))
        }

        It 'shifts the boundary by one instead of negating it' {
            # The distinction that makes this operator worth having: BinaryOperator
            # already turns -gt into -le, which flips the branch outright. Only -ge
            # produces the off-by-one that a boundary test is meant to catch.
            ($script:bounds | Where-Object Original -eq '-gt').Mutated | Should-Be '-ge'
            $binary = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('BinaryOperator'))
            ($binary | Where-Object Original -eq '-gt').Mutated | Should-Be '-le'
        }

        It 'leaves operators that have no boundary alone' {
            # -eq has no adjacent boundary; mutating it here would duplicate what
            # BinaryOperator already does.
            @($script:bounds | Where-Object Original -eq '-eq').Count | Should-Be 0
        }

        It 'never mutates inside a loop condition' {
            @($script:bounds | Where-Object Original -eq '-lt').Count | Should-Be 0
        }
    }

    Context 'ReturnValue' {
        BeforeAll {
            $script:returns = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('ReturnValue'))
        }

        It 'replaces a returned value with $null' {
            # Catches a result nothing asserts on -- the function still runs, still has
            # its side effects, and only the answer is wrong.
            ($script:returns | Where-Object Original -eq "'named'").Mutated | Should-Be '$null'
        }

        It 'ignores a bare return' {
            # `return` already yields nothing, so there is no value to replace.
            @($script:returns | Where-Object Original -eq 'return').Count | Should-Be 0
            $script:returns.Count | Should-BeGreaterThan 0
        }
    }

    Context 'guards' {
        It 'never offers negation removal for a unary that is not a negation' {
            # Unary minus is a UnaryExpressionAst too; "removing" it would silently
            # flip the sign of a value rather than drop a negation.
            $neg = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('NegationRemoval'))
            @($neg | Where-Object Original -like '*-$i*').Count | Should-Be 0
        }

        It 'never replaces a return that is already $null' {
            # `return $null` -> `return $null` is not a mutation; it would be born
            # surviving and could only ever inflate the survivor list.
            @($script:returns | Where-Object Original -eq '$null').Count | Should-Be 0
            $script:returns.Count | Should-BeGreaterThan 0
        }

        It 'refuses an operator name it does not know, naming the alternatives' {
            # THE inversion of #24. This test used to assert the opposite -- that an
            # unknown name was ignored so a typo could not take the run down -- and that
            # was the bug: a repo opting into ConditionForcing and misspelling it got its
            # old vacuous score back, with the typo written into the report's `operators`
            # array as though it had been applied. Asking for an operator that does not
            # exist is a broken config, not an empty result.
            { Get-PSMutationCandidate -Path $script:structFixture -Operators @('NoSuchOperator') } |
                Should-Throw -ExceptionMessage "*Unknown mutation operator 'NoSuchOperator'*ConditionForcing*"
        }

        It 'still emits for a valid operator, so the refusal above is not blanket' {
            # Pairs the rejected name with an accepted one. Without this, a change that
            # made EVERY operator throw would keep the test above green.
            @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('ReturnValue')).Count |
                Should-BeGreaterThan 0
        }
    }

    Context 'opt-in wiring' {
        It 'keeps all three out of the default operator set' {
            # Adding one to the default set roughly doubles a consumer's mutant count
            # and lowers their score, so a repo gating on thresholds.break would go red
            # purely from upgrading the module.
            $default = @(Get-PSMutationCandidate -Path $script:structFixture)
            @($default | Where-Object Operator -in 'ConditionForcing', 'ConditionalBoundary', 'ReturnValue').Count |
                Should-Be 0
        }

        It 'emits each one when the config asks for it by name' {
            $named = @(Get-PSMutationCandidate -Path $script:structFixture -Operators @('ConditionForcing', 'ConditionalBoundary', 'ReturnValue'))
            @($named | Where-Object Operator -eq 'ConditionForcing').Count     | Should-BeGreaterThan 0
            @($named | Where-Object Operator -eq 'ConditionalBoundary').Count  | Should-BeGreaterThan 0
            @($named | Where-Object Operator -eq 'ReturnValue').Count          | Should-BeGreaterThan 0
        }
    }
}

Describe 'Test-PSMutationInLoop' {
    # The no-mutate zone's own predicate. It was only ever exercised THROUGH the
    # operators, so its boundaries were never pinned -- and an off-by-one here either
    # lets a loop-condition mutant through (which hangs a run) or silently drops a
    # legitimate one.
    BeforeAll {
        $script:range = @([pscustomobject]@{ Start = 10; End = 20 })
        function Get-FakeExtent {
            param([int]$Start, [int]$End)
            return [pscustomobject]@{ StartOffset = $Start; EndOffset = $End }
        }
    }

    It 'counts an extent starting exactly at the range start as inside' {
        # -ge, not -gt: the first character of a loop condition is part of it.
        Test-PSMutationInLoop -Extent (Get-FakeExtent 10 15) -Ranges $script:range | Should-BeTrue
    }

    It 'counts an extent ending exactly at the range end as inside' {
        # -le, not -lt: so is the last character.
        Test-PSMutationInLoop -Extent (Get-FakeExtent 15 20) -Ranges $script:range | Should-BeTrue
    }

    It 'excludes an extent starting one character before the range' {
        Test-PSMutationInLoop -Extent (Get-FakeExtent 9 15) -Ranges $script:range | Should-BeFalse
    }

    It 'excludes an extent ending one character after the range' {
        Test-PSMutationInLoop -Extent (Get-FakeExtent 15 21) -Ranges $script:range | Should-BeFalse
    }

    It 'returns an actual $false, not merely something falsy' {
        # Every caller consumes this as `if (...) { continue }`, where $null and $false
        # are indistinguishable -- so only a strict assertion pins the contract.
        Test-PSMutationInLoop -Extent (Get-FakeExtent 99 100) -Ranges @() | Should-BeFalse
    }
}

Describe 'Loop-condition guard across every operator' {
    # A `$( )` subexpression lets an `if` -- and even a `return` -- sit inside a loop
    # CONDITION, so the guard on those operators is reachable rather than defensive.
    # Each construct below appears once inside the condition and once in the body, so
    # every assertion says "this one was filtered" rather than "nothing came back".
    BeforeAll {
        $script:loopFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-loopguard-$PID.ps1"
        @'
function Test-LoopGuard {
    param($a, $i)
    while ($(if ($a) { return 7 } else { $true }) -and $i -lt 3) { $i = $i + 1; $stop = $false }
    if ($i -gt 0) { Write-Output 'positive' }
    return $i
}
'@ | Set-Content $script:loopFixture -Encoding utf8
        $script:guard = @(Get-PSMutationCandidate -Path $script:loopFixture -Operators @(
                'BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'NegationRemoval',
                'ConditionalBoundary', 'ConditionForcing', 'ReturnValue'))
    }
    AfterAll { Remove-Item $script:loopFixture -ErrorAction SilentlyContinue }

    It 'skips a boolean literal in the condition but keeps one in the body' {
        @($script:guard | Where-Object { $_.Operator -eq 'BooleanLiteral' -and $_.Original -eq '$true' }).Count | Should-Be 0
        @($script:guard | Where-Object { $_.Operator -eq 'BooleanLiteral' -and $_.Original -eq '$false' }).Count | Should-Be 1
    }

    It 'skips numeric literals in the condition but keeps one in the body' {
        @($script:guard | Where-Object { $_.Operator -eq 'NumberLiteral' -and $_.Original -in '7', '3' }).Count | Should-Be 0
        @($script:guard | Where-Object { $_.Operator -eq 'NumberLiteral' -and $_.Original -eq '1' }).Count | Should-Be 1
    }

    It 'skips an if-condition nested in the loop condition but keeps one outside' {
        @($script:guard | Where-Object { $_.Operator -eq 'ConditionForcing' -and $_.Original -eq '$a' }).Count | Should-Be 0
        @($script:guard | Where-Object { $_.Operator -eq 'ConditionForcing' -and $_.Original -eq '$i -gt 0' }).Count | Should-Be 2
    }

    It 'skips a return nested in the loop condition but keeps one outside' {
        @($script:guard | Where-Object { $_.Operator -eq 'ReturnValue' -and $_.Original -eq '7' }).Count | Should-Be 0
        @($script:guard | Where-Object { $_.Operator -eq 'ReturnValue' -and $_.Original -eq '$i' }).Count | Should-Be 1
    }

    It 'skips a boundary comparison in the condition but keeps one outside' {
        @($script:guard | Where-Object { $_.Operator -eq 'ConditionalBoundary' -and $_.Original -eq '-lt' }).Count | Should-Be 0
        @($script:guard | Where-Object { $_.Operator -eq 'ConditionalBoundary' -and $_.Original -eq '-gt' }).Count | Should-Be 1
    }
}

Describe 'Get-PSMutationOperatorList' {
    It 'uses the operators the config names' {
        Get-PSMutationOperatorList -Cfg ([pscustomobject]@{ operators = @('BinaryOperator') }) |
            Should-BeCollection @('BinaryOperator')
    }
    It 'falls back to the default set when the config is silent' {
        $ops = Get-PSMutationOperatorList -Cfg ([pscustomobject]@{})
        $ops | Should-ContainCollection 'BinaryOperator'
        $ops | Should-ContainCollection 'BooleanLiteral'
        $ops | Should-ContainCollection 'NumberLiteral'
        $ops | Should-ContainCollection 'NegationRemoval'
        # StringLiteral is NOT on by default: emptying every string in a repo produces
        # a flood of survivors that say nothing about behaviour.
        $ops | Should-NotContainCollection 'StringLiteral'
    }
}

Describe 'Get-PSMutationKnownOperator' {
    It 'names every operator the dispatcher can run' {
        # The config validator quotes this list back at a user who misspelled an operator,
        # so a name missing here reads as "not a valid operator" for something that is.
        # Asserting the exact set also fails loudly when an operator is added without a
        # thought for whether it belongs in the default set.
        Get-PSMutationKnownOperator | Should-BeCollection @(
            'BinaryOperator', 'BooleanLiteral', 'ConditionalBoundary', 'ConditionForcing',
            'NegationRemoval', 'NumberLiteral', 'ReturnValue', 'StringLiteral')
    }

    It 'lists them sorted, so the error message reads predictably' {
        # Should-BeCollection above ignores order, so it cannot make this claim. Joined and
        # compared as a string, which is the only way to assert a sequence here.
        (Get-PSMutationKnownOperator) -join ',' | Should-Be (((Get-PSMutationKnownOperator) | Sort-Object) -join ',')
    }
}

Describe 'mutant ids do not depend on the order operators were listed in' {
    BeforeAll {
        # Two operators that interleave in the source, so walk order and source order
        # genuinely differ -- a fixture where one operator's candidates all preceded the
        # other's would pass no matter how ids were assigned.
        $script:orderFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-order-$PID.ps1"
        @'
function Test-Thing {
    param($a, $b)
    if ($a -eq 1) { return $true }
    if (-not $b) { return $false }
    return $a + 2
}
'@ | Set-Content $script:orderFixture
    }

    AfterAll { Remove-Item $script:orderFixture -ErrorAction SilentlyContinue }

    It 'assigns the same id to the same mutant whichever order the operators are listed in' {
        # THE #29 defect. Ids came from walk order, so swapping two entries in a config's
        # `operators` array renumbered everything -- while Write-PSMutationReport records
        # that array SORTED, so Test-PSMutationRecheckCompatible saw no change and a
        # recheck matched survivors by id against a different set of mutants.
        $forward = Get-PSMutationCandidate -Path $script:orderFixture -Operators @('BinaryOperator', 'BooleanLiteral')
        $reverse = Get-PSMutationCandidate -Path $script:orderFixture -Operators @('BooleanLiteral', 'BinaryOperator')

        $key = { param($c) '{0}|{1}|{2}' -f $c.Id, $c.StartOffset, $c.Description }
        @($reverse | ForEach-Object { & $key $_ }) |
            Should-BeCollection @($forward | ForEach-Object { & $key $_ })
    }

    It 'numbers in source order, so an id means a position in the file' {
        # Pins WHICH canonical order, not merely that one exists. Without this, sorting by
        # something arbitrary but stable would satisfy the test above and still make ids
        # unreadable.
        #
        # Joined to a string deliberately: Should-BeCollection compares collections WITHOUT
        # regard to order, so `51,124,67,101` and `51,67,101,124` pass against it. Written
        # that way this test passed against the very defect it exists to catch -- checked by
        # running it against the pre-fix source.
        $c = @(Get-PSMutationCandidate -Path $script:orderFixture -Operators @('BinaryOperator', 'BooleanLiteral'))
        $byId = @($c | Sort-Object Id | ForEach-Object { $_.StartOffset }) -join ','
        $ascending = @($c | ForEach-Object { $_.StartOffset } | Sort-Object) -join ','
        $byId | Should-Be $ascending
    }

    It 'separates two mutants that share an offset and an operator' {
        # ConditionForcing emits both the $true and the $false forcing at ONE extent, so
        # (StartOffset, Operator) is not a unique key. If the sort were keyed only on those,
        # the tie would fall back to walk order and #29 would survive for this operator.
        $forward = Get-PSMutationCandidate -Path $script:orderFixture -Operators @('ConditionForcing', 'ReturnValue')
        $reverse = Get-PSMutationCandidate -Path $script:orderFixture -Operators @('ReturnValue', 'ConditionForcing')

        @($forward | Where-Object { $_.Operator -eq 'ConditionForcing' }).Count | Should-BeGreaterThan 1
        @($reverse | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Description }) |
            Should-BeCollection @($forward | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Description })
    }
}

Describe 'every description names what was mutated' {
    BeforeAll {
        $script:descFixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-desc-$PID.ps1"
        @'
function Test-Desc {
    param($done, $ref)
    if (-not $done) { return $ref }
    if ($ref.Value) { return 'text' }
    return $done
}
'@ | Set-Content $script:descFixture
    }

    AfterAll { Remove-Item $script:descFixture -ErrorAction SilentlyContinue }

    It 'derives <Operator> descriptions from the source, not a fixed phrase' -ForEach @(
        @{ Operator = 'NegationRemoval'; Expect = '-not $done -> $done' }
        @{ Operator = 'ReturnValue';     Expect = '$ref -> $null' }
        @{ Operator = 'ConditionForcing'; Expect = '$ref.Value -> $false' }
        @{ Operator = 'StringLiteral';   Expect = "'text' -> ''" }
    ) {
        # These four used to emit a fixed phrase -- 'remove negation', 'return value -> $null',
        # "condition -> $false", "string -> ''" -- identical for every such mutant on a line.
        # Since the equivalence key is File:Line:Description, one declaration then excluded all
        # of them silently (#28). The description now says which construct was changed.
        @(Get-PSMutationCandidate -Path $script:descFixture -Operators @($Operator)).Description |
            Should-ContainCollection $Expect
    }

    It 'collapses whitespace so a multi-line construct stays one line' {
        # An extent can span lines. A raw multi-line condition would put newlines into a
        # console line and into a config key, where neither survives being pasted back.
        $multi = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-desc-multi-$PID.ps1"
        try {
            @'
function Test-Multi {
    param($a, $b)
    if ($a -and
        $b) { return 1 }
}
'@ | Set-Content $multi
            $d = @(Get-PSMutationCandidate -Path $multi -Operators @('ConditionForcing')).Description
            $d | Should-ContainCollection '$a -and $b -> $true'
            ($d -join '') | Should-NotBeLikeString "*`n*"
        }
        finally { Remove-Item $multi -ErrorAction SilentlyContinue }
    }

    It 'keeps a description of exactly the limit intact' -ForEach @(
        # `<original> -> $null` is original + 4 + 5 characters, so a 111-character variable
        # name lands the description on exactly 120 -- the boundary itself.
        @{ NameLength = 111; Truncated = $false }
        @{ NameLength = 112; Truncated = $true }
    ) {
        # The boundary, not a comfortable value. A limit of 121, or `-ge` instead of `-gt`,
        # both survive any test that only checks "long things get shortened" -- which is
        # what the first version of this test did, and the self-mutation gate said so.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-desc-len-$NameLength-$PID.ps1"
        try {
            $name = '$' + ('a' * ($NameLength - 1))
            "function Test-Len { return $name }" | Set-Content $f
            $d = @(Get-PSMutationCandidate -Path $f -Operators @('ReturnValue')).Description
            $full = "$name -> `$null"
            if ($Truncated) {
                # Asserting the exact text pins where the cut starts as well as where it
                # ends: Substring(1, ...) would drop the leading $ and still be 120 long.
                @($d)[0] | Should-Be ($full.Substring(0, 120) + '...')
            }
            else {
                @($d)[0] | Should-Be $full
                @($d)[0].Length | Should-Be 120
            }
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

Describe 'an equivalence declaration survives an unrelated edit' {
    BeforeAll {
        $script:stableSrc = @'
function Get-Thing {
    param($n)
    return $n + 1
}
'@
    }

    It 'keeps the function-form key when a line is inserted above the mutant' {
        # THE #3 defect, reproduced. A declaration keyed on the line number goes stale
        # whenever anything ABOVE it is edited -- a comment, an import, another function --
        # although the mutant it argues about has not changed. It happened on the first run
        # after the feature shipped, and twice more while fixing #28.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-stable-$PID.ps1"
        try {
            $script:stableSrc | Set-Content $f
            $before = @(Get-PSMutationCandidate -Path $f -Operators @('NumberLiteral'))[0]

            # An edit that changes nothing about the mutant: a comment, above it.
            "# an unrelated comment`n" + $script:stableSrc | Set-Content $f
            $after = @(Get-PSMutationCandidate -Path $f -Operators @('NumberLiteral'))[0]

            # The line moved -- that is the whole premise of the test.
            ($after.Line -eq $before.Line) | Should-BeFalse
            # The function-form key did not.
            $after.Function | Should-Be $before.Function
            $after.Description | Should-Be $before.Description
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-PSMutationEnclosingFunction' {
    BeforeAll {
        $script:nested = @'
function Outer {
    function Inner { return 1 }
    return 2
}
$topLevel = 3
'@
        $script:nestedFile = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-nested-$PID.ps1"
        $script:nested | Set-Content $script:nestedFile
    }

    AfterAll { Remove-Item $script:nestedFile -ErrorAction SilentlyContinue }

    It 'names the innermost function, not the outermost' {
        # A nested function is the more specific answer and the one a reader would name.
        # Returning the outer one would make two different mutants share a key.
        $c = @(Get-PSMutationCandidate -Path $script:nestedFile -Operators @('NumberLiteral'))
        ($c | Where-Object Description -eq '1 -> 2').Function | Should-Be 'Inner'
        ($c | Where-Object Description -eq '2 -> 3').Function | Should-Be 'Outer'
    }

    It 'returns empty for code at file scope' {
        # Module top-level statements are mutable too and have no function to be addressed
        # by, so they keep falling back to the line number rather than getting a wrong name.
        $c = @(Get-PSMutationCandidate -Path $script:nestedFile -Operators @('NumberLiteral'))
        ($c | Where-Object Description -eq '3 -> 4').Function | Should-BeEmptyString
    }

    It 'returns empty when there are no functions at all' {
        Get-PSMutationEnclosingFunction -Offset 5 -Ranges @() | Should-BeEmptyString
    }

    It 'treats <Case> as <Expected>' -ForEach @(
        # The range is half-open: Start is inside, End is not. Boundary values, because a
        # comfortable offset in the middle passes against -gt as happily as -ge.
        @{ Case = 'the first character of a function'; Offset = 10; Expected = 'F' }
        @{ Case = 'one before the function';           Offset = 9;  Expected = '' }
        @{ Case = 'the last character of a function';  Offset = 19; Expected = 'F' }
        @{ Case = 'the end offset itself';             Offset = 20; Expected = '' }
    ) {
        $ranges = @([pscustomobject]@{ Name = 'F'; Start = 10; End = 20 })
        Get-PSMutationEnclosingFunction -Offset $Offset -Ranges $ranges | Should-Be $Expected
    }

    It 'requires the offset to be inside BOTH bounds, not either' {
        # Guards the -and. With -or, an offset past the end still satisfies "at or after
        # start" and every mutant in the file would be attributed to the last function.
        $ranges = @([pscustomobject]@{ Name = 'F'; Start = 10; End = 20 })
        Get-PSMutationEnclosingFunction -Offset 99 -Ranges $ranges | Should-BeEmptyString
    }

    It 'takes the last containing range, which document order makes the innermost' {
        # The ordering invariant the implementation leans on, pinned rather than assumed:
        # FindAll returns functions in document order and a nested function always follows
        # the one enclosing it, so "last containing" and "innermost" are the same range.
        $ranges = @(
            [pscustomobject]@{ Name = 'Outer'; Start = 0;  End = 100 }
            [pscustomobject]@{ Name = 'Inner'; Start = 20; End = 40 }
        )
        Get-PSMutationEnclosingFunction -Offset 30 -Ranges $ranges | Should-Be 'Inner'
        # Outside the nested one, the enclosing function is still the answer.
        Get-PSMutationEnclosingFunction -Offset 50 -Ranges $ranges | Should-Be 'Outer'
    }
}
