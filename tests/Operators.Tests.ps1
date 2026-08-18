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
            -File 'f.ps1' -Original 'a' -Mutated 'b' -Operator 'BinaryOperator' -Description 'a -> b'
        $c.Id | Should-Be 0
    }
}
