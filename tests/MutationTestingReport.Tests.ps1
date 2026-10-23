# Unit tests for the mutation testing report (#261): a projection of the rows, plus one write.
# Also the covering suite for self-mutating src/PSMutation.MutationTestingReport.ps1 - keep it
# self-contained.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
    . (Join-Path $src 'PSMutation.Output.ps1')
    . (Join-Path $src 'PSMutation.Report.ps1')
    . (Join-Path $src 'PSMutation.MutationTestingReport.ps1')
    $script:schemaText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'vendor/mutation-testing-elements/mutation-testing-report-schema-3.9.0.json')

    # A sandbox-shaped tree: candidates name files under it, rows name them relative to it.
    $script:root = Join-Path $TestDrive "sb-$([System.Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path (Join-Path $script:root 'src') -Force
    $script:aPath = Join-Path $script:root 'src/a.ps1'
    $script:bPath = Join-Path $script:root 'src/b.ps1'
    # CRLF on purpose in a: a position is counted after every `n, so the `r belongs to the line it ends.
    [System.IO.File]::WriteAllText($script:aPath, "function Get-A {`r`n    if (`$x -eq 1) { `$true }`r`n}`r`n")
    [System.IO.File]::WriteAllText($script:bPath, "`$y = 2 -gt 1`n")
    $script:candA = @(Get-PSMutationCandidate -Path $script:aPath -Operators @('BinaryOperator', 'NumberLiteral'))
    $script:candB = @(Get-PSMutationCandidate -Path $script:bPath -Operators @('BinaryOperator'))

    function script:Row {
        param($Candidate, $File, $Status = 'Killed', $KilledBy = @())
        [pscustomobject]@{ Id = $Candidate.Id; Function = $Candidate.Function; File = $File; Line = $Candidate.Line
            Operator = $Candidate.Operator; Description = $Candidate.Description; Status = $Status; KilledBy = $KilledBy }
    }
}

Describe 'Get-PSMutationLineStart' {
    It 'starts a line after every line feed, so a CRLF ends the line it is on' {
        Get-PSMutationLineStart -Text "a`nbc`r`nd" | Should-BeCollection @(0, 2, 6)
    }

    It 'counts a line after a trailing line feed, and one line for an empty text' {
        Get-PSMutationLineStart -Text "a`n" | Should-BeCollection @(0, 2)
        @(Get-PSMutationLineStart -Text '') | Should-BeCollection @(0)
    }

    It 'finds every line of a text with several, not only the first two' {
        @(Get-PSMutationLineStart -Text "a`nb`nc`nd").Count | Should-Be 4
    }
}

Describe 'Get-PSMutationTextPosition' {
    BeforeAll { $script:starts = Get-PSMutationLineStart -Text "ab`ncd`nef" }

    It 'counts line and column from 1, at a line start and inside a line' -ForEach @(
        @{ Offset = 0; Line = 1; Column = 1 }
        @{ Offset = 1; Line = 1; Column = 2 }
        @{ Offset = 3; Line = 2; Column = 1 }
        @{ Offset = 4; Line = 2; Column = 2 }
        @{ Offset = 7; Line = 3; Column = 2 }
        @{ Offset = 8; Line = 3; Column = 3 }
    ) {
        $p = Get-PSMutationTextPosition -LineStart $script:starts -Offset $Offset
        $p.line | Should-Be $Line
        $p.column | Should-Be $Column
        @($p.Keys) | Should-BeCollection @('line', 'column')
    }

    It 'places the line feed itself at the end of its own line' {
        $p = Get-PSMutationTextPosition -LineStart $script:starts -Offset 2
        "$($p.line):$($p.column)" | Should-Be '1:3'
    }
}

Describe 'Get-PSMutationMutationTestingStatus' {
    BeforeAll {
        $script:declared = @{ 'src/a.ps1:Get-A:-eq -> -ne' = 'both sides are always equal here' }
        function script:StatusRow {
            param($Status, $KilledBy = @(), $Description = '-eq -> -ne')
            [pscustomobject]@{ Id = 1; Function = 'Get-A'; File = 'src/a.ps1'; Line = 2; Operator = 'BinaryOperator'
                Description = $Description; Status = $Status; KilledBy = $KilledBy }
        }
    }

    It 'names the tests that killed a mutant, every one of them' {
        $s = Get-PSMutationMutationTestingStatus -Result (StatusRow 'Killed' @('t1', 't2')) -Declared @{}
        $s.status | Should-Be 'Killed'
        $s.statusReason | Should-Be 'Killed by t1; t2'
    }

    It 'gives no reason when no test is named' {
        $s = Get-PSMutationMutationTestingStatus -Result (StatusRow 'Killed' @('')) -Declared @{}
        @($s.Keys) | Should-BeCollection @('status')
    }

    It 'writes TimedOut as the format''s Timeout, and passes the others through' -ForEach @(
        @{ Status = 'TimedOut'; Expected = 'Timeout' }
        @{ Status = 'Survived'; Expected = 'Survived' }
        @{ Status = 'CompileError'; Expected = 'CompileError' }
        @{ Status = 'RuntimeError'; Expected = 'RuntimeError' }
    ) {
        (Get-PSMutationMutationTestingStatus -Result (StatusRow $Status) -Declared @{}).status | Should-Be $Expected
    }

    It 'writes a declared survivor as Ignored, with the declaration''s argument' {
        $s = Get-PSMutationMutationTestingStatus -Result (StatusRow 'Survived') -Declared $script:declared
        $s.status | Should-Be 'Ignored'
        $s.statusReason | Should-Be 'Declared equivalent: both sides are always equal here'
    }

    It 'leaves an undeclared survivor Survived, and a killed mutant Killed even where a declaration matches' {
        (Get-PSMutationMutationTestingStatus -Result (StatusRow 'Survived' -Description '-gt -> -le') -Declared $script:declared).status |
            Should-Be 'Survived'
        (Get-PSMutationMutationTestingStatus -Result (StatusRow 'Killed') -Declared $script:declared).status | Should-Be 'Killed'
    }
}

Describe 'Get-PSMutationMutationTestingFile' {
    BeforeAll {
        $script:rows = @(
            (Row $script:candB[0] 'src/b.ps1' 'Survived')
            (Row $script:candA[0] 'src/a.ps1' 'Killed' @('t1'))
            (Row $script:candA[1] 'src/a.ps1' 'TimedOut')
        )
        $script:files = Get-PSMutationMutationTestingFile -Results $script:rows -Candidates (@($script:candA) + @($script:candB)) `
            -SandboxRoot $script:root -Declared @{}
    }

    It 'keys each file by the path the report uses, in the order the rows came' {
        @($script:files.Keys) -join ',' | Should-Be 'src/b.ps1,src/a.ps1'
    }

    It 'carries each file''s text exactly, and its mutants in row order' {
        $script:files['src/a.ps1'].source | Should-Be ([System.IO.File]::ReadAllText($script:aPath))
        $script:files['src/a.ps1'].language | Should-Be 'powershell'
        @($script:files['src/a.ps1'].mutants | ForEach-Object { $_.id }) | Should-BeCollection @("src/a.ps1#$($script:candA[0].Id)", "src/a.ps1#$($script:candA[1].Id)")
        @($script:files['src/b.ps1'].mutants).Count | Should-Be 1
    }

    It 'places every mutant on the text it replaces, CRLF file and LF file alike' {
        foreach ($f in $script:files.Keys) {
            $lines = $script:files[$f].source -split "`n"
            foreach ($m in $script:files[$f].mutants) {
                $l = $m.location
                $l.start.line | Should-Be $l.end.line
                $cut = $lines[$l.start.line - 1].Substring($l.start.column - 1, $l.end.column - $l.start.column)
                $orig = ($script:candA + $script:candB | Where-Object { "$f#$($_.Id)" -eq $m.id -and $_.Mutated -eq $m.replacement })[0].Original
                $cut | Should-Be $orig
            }
        }
    }

    It 'writes the operator, the description, the replacement and the verdict' {
        $m = $script:files['src/a.ps1'].mutants[0]
        $m.mutatorName | Should-Be $script:candA[0].Operator
        $m.description | Should-Be $script:candA[0].Description
        $m.replacement | Should-Be $script:candA[0].Mutated
        $m.status | Should-Be 'Killed'
        $m.statusReason | Should-Be 'Killed by t1'
        $script:files['src/a.ps1'].mutants[1].status | Should-Be 'Timeout'
    }

    It 'leaves out a row it cannot place rather than drawing it at line 1' {
        $orphan = [pscustomobject]@{ Id = 99; Function = ''; File = 'src/a.ps1'; Line = 1; Operator = 'BinaryOperator'
            Description = 'x'; Status = 'Killed'; KilledBy = @() }
        $f = Get-PSMutationMutationTestingFile -Results @($orphan, (Row $script:candA[0] 'src/a.ps1')) -Candidates $script:candA `
            -SandboxRoot $script:root -Declared @{}
        @($f['src/a.ps1'].mutants).Count | Should-Be 1
        $only = Get-PSMutationMutationTestingFile -Results @($orphan) -Candidates $script:candA -SandboxRoot $script:root -Declared @{}
        @($only.Keys).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationMutationTestingDocument' {
    BeforeAll {
        $script:rows = @((Row $script:candA[0] 'src/a.ps1' 'Survived'), (Row $script:candB[0] 'src/b.ps1' 'Killed' @('t')))
        $eq = [pscustomobject]@{ "src/a.ps1:Get-A:$($script:candA[0].Description)" = 'argued here' }
        $script:doc = Get-PSMutationMutationTestingDocument -Results $script:rows -Candidates (@($script:candA) + @($script:candB)) `
            -SandboxRoot $script:root -Equivalents $eq -High 87.5 -Low 70 -ModuleVersion '1.2.3'
    }

    It 'is valid against the format''s own schema' {
        Test-Json -Json ($script:doc | ConvertTo-Json -Depth 8) -Schema $script:schemaText | Should-BeTrue
    }

    It 'is valid with no mutants at all' {
        $empty = Get-PSMutationMutationTestingDocument -Results @() -Candidates @() -SandboxRoot $script:root -High 80 -Low 60
        Test-Json -Json ($empty | ConvertTo-Json -Depth 8) -Schema $script:schemaText | Should-BeTrue
    }

    It 'writes whole-number thresholds, rounding a fraction down' {
        $script:doc.thresholds.high | Should-Be 87
        $script:doc.thresholds.low | Should-Be 70
    }

    It 'names this tool and its version, or unknown when none is given' {
        $script:doc.framework.name | Should-Be 'PSMutant'
        $script:doc.framework.version | Should-Be '1.2.3'
        $script:doc.schemaVersion | Should-Be '2'
        (Get-PSMutationMutationTestingDocument -Results @() -Candidates @() -SandboxRoot $script:root -High 80 -Low 60 -ModuleVersion '').framework.version |
            Should-Be 'unknown'
    }

    It 'applies the declarations it is given' {
        $script:doc.files['src/a.ps1'].mutants[0].status | Should-Be 'Ignored'
        $script:doc.files['src/b.ps1'].mutants[0].status | Should-Be 'Killed'
    }
}

Describe 'Save-PSMutationMutationTestingDocument' {
    It 'writes the deepest value as a value, not a .NET type name, creating the directory' {
        $doc = Get-PSMutationMutationTestingDocument -Results @((Row $script:candB[0] 'src/b.ps1')) -Candidates $script:candB `
            -SandboxRoot $script:root -High 80 -Low 60
        $path = Join-Path $TestDrive "out-$([System.Guid]::NewGuid().ToString('N'))/r.json"
        Save-PSMutationMutationTestingDocument -Document $doc -Path $path
        $back = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        [int]$back.files.'src/b.ps1'.mutants[0].location.start.column | Should-Be 8
        Test-Json -Json (Get-Content -Raw -LiteralPath $path) -Schema $script:schemaText | Should-BeTrue
    }

    It 'fails when the file cannot be written' {
        $dir = Join-Path $TestDrive "dir-$([System.Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $dir
        { Save-PSMutationMutationTestingDocument -Document ([ordered]@{ a = 1 }) -Path $dir } | Should-Throw
    }
}

Describe 'Export-PSMutationMutationTestingReport' {
    It 'writes nothing and says nothing when no path is configured' {
        $r = Export-PSMutationMutationTestingReport -Path '' -Results @((Row $script:candB[0] 'src/b.ps1')) -Candidates $script:candB `
            -SandboxRoot $script:root -High 80 -Low 60
        @($r).Count | Should-Be 0
    }

    It 'writes the report and says where, with the number of mutants in it' {
        $path = Join-Path $TestDrive "exp-$([System.Guid]::NewGuid().ToString('N')).json"
        $rows = @((Row $script:candA[0] 'src/a.ps1'), (Row $script:candA[1] 'src/a.ps1'), (Row $script:candB[0] 'src/b.ps1'))
        $line = Export-PSMutationMutationTestingReport -Path $path -Results $rows -Candidates (@($script:candA) + @($script:candB)) `
            -SandboxRoot $script:root -High 80 -Low 60 -ModuleVersion '9.9.9'
        $line.Text | Should-Be "  Mutation testing report: $path (3 mutant(s))"
        $line.Role | Should-Be 'Muted'
        (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).framework.version | Should-Be '9.9.9'
    }
}
