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
        $c.Original | Should -Be '-eq'
        $c.Mutated  | Should -Be '-ne'
    }
    It 'flips both boolean literals' {
        $b = $script:cands | Where-Object Operator -eq 'BooleanLiteral'
        ($b | Where-Object Original -eq '$true').Mutated  | Should -Be '$false'
        ($b | Where-Object Original -eq '$false').Mutated | Should -Be '$true'
    }
    It 'mutates the numeric literal to N+1' {
        ($script:cands | Where-Object Operator -eq 'NumberLiteral').Mutated | Should -Be '2'
    }
    It 'empties a quoted string but never a bareword/command name' {
        ($script:cands | Where-Object Operator -eq 'StringLiteral').Mutated | Should -Be "''"
        ($script:cands | Where-Object Original -like '*Fixture*') | Should -BeNullOrEmpty
    }
    It 'offers negation removal down to the inner expression' {
        ($script:cands | Where-Object Operator -eq 'NegationRemoval').Mutated | Should -Match '\$flag'
    }
    It 'assigns ids as exactly 1..N (unique, sequential, starting at 1)' {
        $ids = @($script:cands.Id)
        $ids | Should -Be (1..$ids.Count)
    }
}

Describe 'Get-PSMutationCandidate - operator selection' {
    It 'excludes StringLiteral from the default set' {
        $d = Get-PSMutationCandidate -Path $script:fixture
        ($d | Where-Object Operator -eq 'StringLiteral')  | Should -BeNullOrEmpty
        ($d | Where-Object Operator -eq 'BinaryOperator') | Should -Not -BeNullOrEmpty
    }
    It 'emits nothing when no operators are enabled' {
        @(Get-PSMutationCandidate -Path $script:fixture -Operators @()).Count | Should -Be 0
    }
    It 'throws on a script with parse errors' {
        $bad = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-bad-$PID.ps1"
        'function {' | Set-Content $bad
        { Get-PSMutationCandidate -Path $bad } | Should -Throw
        Remove-Item $bad -ErrorAction SilentlyContinue
    }
}

Describe 'Loop guard' {
    It 'never emits a candidate inside a while/for condition' {
        $loop = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-loop-$PID.ps1"
        "function L { `$i = 0; while (`$i -lt 10) { `$i = `$i + 1 }; for (`$j = 0; `$j -gt 3; `$j++) { } }" | Set-Content $loop
        try {
            $c = Get-PSMutationCandidate -Path $loop -Operators $script:all
            ($c | Where-Object Original -eq '-lt') | Should -BeNullOrEmpty
            ($c | Where-Object Original -eq '-gt') | Should -BeNullOrEmpty
            ($c | Where-Object { $_.Operator -eq 'BinaryOperator' -and $_.Original -eq '+' }) | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item $loop -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-PSMutationText' {
    It 'splices exactly the operator extent, leaving the rest intact' {
        $content = [System.IO.File]::ReadAllText($script:fixture)
        $c = $script:cands | Where-Object Operator -eq 'BinaryOperator' | Select-Object -First 1
        $mutated = Set-PSMutationText -Content $content -Candidate $c
        $mutated | Should -Match '\$x -ne 1'
        $mutated.Length | Should -Be $content.Length
        $mutated.Substring(0, $c.StartOffset) | Should -Be $content.Substring(0, $c.StartOffset)
    }
    It 'produces a still-parseable script' {
        $content = [System.IO.File]::ReadAllText($script:fixture)
        $c = $script:cands | Where-Object Operator -eq 'BooleanLiteral' | Select-Object -First 1
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseInput((Set-PSMutationText -Content $content -Candidate $c), [ref]$null, [ref]$errs) | Out-Null
        $errs.Count | Should -Be 0
    }
}

Describe 'New-PSMutationCandidate' {
    It 'stamps line/offsets from the extent' {
        $c = $script:cands | Select-Object -First 1
        $c.Line | Should -BeGreaterThan 0
        $c.EndOffset | Should -BeGreaterThan $c.StartOffset
    }
}

Describe 'Get-PSMutationCandidate - unparseable input' {
    It 'refuses a file with a single syntax error' {
        # One error, not two: the guard is `Count -gt 0`, and a two-error fixture
        # passes just as happily against `-gt 1` -- under which a file with exactly
        # one syntax error would be parsed anyway and mutated from a broken AST.
        { Get-PSMutationCandidate -Path (Get-BadSyntaxFile 'one-error.ps1') } |
            Should -Throw '*parse errors*'
    }

    It 'reports the FIRST parse error message, not an empty one' {
        # The message comes from $errors[0]. Read as $errors[1], a single-error file
        # yields $null and the throw says "parse errors:" with nothing after it --
        # still an error, but one that tells you nothing about what is wrong.
        { Get-PSMutationCandidate -Path (Get-BadSyntaxFile 'one-error-msg.ps1') } |
            Should -Throw "*Missing closing '}'*"
    }

    It 'names the file it could not parse' {
        $p = Get-BadSyntaxFile 'named.ps1'
        { Get-PSMutationCandidate -Path $p } | Should -Throw '*named.ps1*'
    }
}

Describe 'Mutant ids' {
    It 'numbers candidates from 1, contiguously, within a file' {
        # -RecheckFrom matches survivors by (file, id), so the numbering is a
        # contract, not an implementation detail: a gap or a restart would make a
        # recheck select the wrong mutants.
        $ids = @($script:cands | ForEach-Object Id)
        $ids | Should -Be @(1..$ids.Count)
    }

    It 'leaves an unnumbered candidate at the 0 sentinel' {
        # Candidates are built with Id = 0 and numbered afterwards. The sentinel has
        # to be outside the real range: at 1 it would be indistinguishable from a
        # genuine first mutant, so a candidate that never got numbered would look
        # like a valid recheck target.
        $c = New-PSMutationCandidate -Extent ([pscustomobject]@{ StartLineNumber = 7; StartOffset = 1; EndOffset = 2 }) `
            -File 'f.ps1' -Original 'a' -Mutated 'b' -Operator 'BinaryOperator' -Description 'a -> b'
        $c.Id | Should -Be 0
    }
}
