# Unit tests for the pure AST operator layer. A mutation tool that mis-locates an
# offset would silently corrupt source, so the splice + every operator is pinned here.
# Also the covering suite for self-mutation (psmutant.self.config.json) — keep it pure.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')

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

Describe 'Get-PSMutationCandidate — operators' {
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

Describe 'Get-PSMutationCandidate — operator selection' {
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
