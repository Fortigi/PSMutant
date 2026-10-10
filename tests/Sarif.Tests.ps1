# Unit tests for the SARIF log (pure projection + one write).
# Also the covering suite for self-mutating src/PSMutation.Sarif.ps1 - keep it self-contained.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')
    . (Join-Path $src 'PSMutation.Output.ps1')
    . (Join-Path $src 'PSMutation.Report.ps1')
    . (Join-Path $src 'PSMutation.Sarif.ps1')

    function script:Row {
        param($Line, $Status = 'Survived', $Function = 'Get-Thing', $Description = '-eq -> -ne',
            $Operator = 'BinaryOperator', $File = 'src/a.ps1')
        [pscustomobject]@{ Id = $Line; Function = $Function; File = $File; Line = $Line
            Operator = $Operator; Description = $Description; Status = $Status; KilledBy = @() }
    }
    $script:summary = [pscustomobject]@{ Score = 75.0; Killed = 3; Survived = 1; Total = 4 }
}

Describe 'the operator vocabulary the rules are written in' {
    It 'has a sentence for every operator the module knows, and none it does not' {
        # Closed in BOTH directions. An operator added without a sentence ships a rule whose help
        # reads "The operator  No test failed"; a sentence for a removed operator describes a check
        # nobody can run.
        @($script:PSMutationOperatorSummary.Keys | Sort-Object) | Should-BeCollection @(Get-PSMutationKnownOperator)
        foreach ($k in $script:PSMutationOperatorSummary.Keys) {
            $script:PSMutationOperatorSummary[$k] | Should-NotBeEmptyString
        }
    }
}

Describe 'Get-PSMutationSarifRule' {
    It 'declares one rule per operator the run applied, in the run''s order, under a PSMutant id' {
        $rules = Get-PSMutationSarifRule -Operators @('BinaryOperator', 'ReturnValue')
        @($rules).Count | Should-Be 2
        $rules[0].id | Should-Be 'PSMutant/BinaryOperator'
        $rules[1].id | Should-Be 'PSMutant/ReturnValue'
        $rules[1].name | Should-Be 'ReturnValue'
    }

    It 'gives every rule help text that names what the operator does' {
        # GH2012 requires `help`. Checked against the vocabulary so the sentence that arrives is
        # the right operator's, not merely a non-empty one.
        $rule = (Get-PSMutationSarifRule -Operators @('NumberLiteral'))[0]
        $rule.help.text | Should-BeLikeString "*NumberLiteral*$($script:PSMutationOperatorSummary['NumberLiteral'])*"
        $rule.help.text | Should-Be $rule.fullDescription.text
        $rule.shortDescription.text | Should-BeLikeString '*NumberLiteral*survived*'
    }

    It 'returns an empty array, not a phantom element, for no operators' {
        # A loop that runs zero times assigns $null, and @($null) is one element -- the #158
        # shape. The comma keeps an empty result an array through the return.
        $rules = Get-PSMutationSarifRule -Operators @()
        Should-HaveType -Actual $rules -Expected ([object[]])
        @($rules).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationSarifFingerprint' {
    It 'addresses a mutant by file, function and description, never by id or line' {
        # The same key an equivalence declaration uses first. Two rows that differ ONLY in id and
        # line get the same identity, which is the stability the alert needs.
        Get-PSMutationSarifFingerprint -Results @((Row 5)) | Should-Be 'src/a.ps1:Get-Thing:-eq -> -ne'
        Get-PSMutationSarifFingerprint -Results @((Row 50)) | Should-Be 'src/a.ps1:Get-Thing:-eq -> -ne'
    }

    It 'leaves a unique address unnumbered' {
        $fp = Get-PSMutationSarifFingerprint -Results @((Row 1), (Row 2 -Description '-gt -> -le'))
        $fp | Should-BeCollection @('src/a.ps1:Get-Thing:-eq -> -ne', 'src/a.ps1:Get-Thing:-gt -> -le')
    }

    It 'numbers EVERY member of a shared address, in order, and only those' {
        # Two results with one fingerprint are one alert, so the second would vanish. Suffixing
        # only the later twin would re-key the first the day a twin appears.
        $fp = Get-PSMutationSarifFingerprint -Results @((Row 1), (Row 2 -Description '-gt -> -le'), (Row 3), (Row 4))
        $fp | Should-BeCollection @(
            'src/a.ps1:Get-Thing:-eq -> -ne#1'
            'src/a.ps1:Get-Thing:-gt -> -le'
            'src/a.ps1:Get-Thing:-eq -> -ne#2'
            'src/a.ps1:Get-Thing:-eq -> -ne#3'
        )
    }

    It 'numbers a PAIR, the smallest group that collides' {
        # The boundary of "shared". Three twins pass under a rule that only numbers groups larger
        # than two, and a pair is the common case: one comparison flipped twice in a function.
        Get-PSMutationSarifFingerprint -Results @((Row 1), (Row 2)) |
            Should-BeCollection @('src/a.ps1:Get-Thing:-eq -> -ne#1', 'src/a.ps1:Get-Thing:-eq -> -ne#2')
    }

    It 'uses the synthetic name for code at file scope, as a declaration does' {
        Get-PSMutationSarifFingerprint -Results @((Row 1 -Function '')) | Should-Be 'src/a.ps1:<script-body>:-eq -> -ne'
    }
}

Describe 'Get-PSMutationSarifResult' {
    It 'reports survivors and nothing else' {
        # Killed and timed-out mutants are not findings. Both kinds are in the fixture so a filter
        # that let either through, or dropped the survivor, changes the count.
        $r = Get-PSMutationSarifResult -Operators @('BinaryOperator') -Results @(
            (Row 1 -Status 'Killed'), (Row 2), (Row 3 -Status 'TimedOut'))
        @($r).Count | Should-Be 1
        $r[0].locations[0].physicalLocation.region.startLine | Should-Be 2
    }

    It 'leaves out a survivor the config declared equivalent, and keeps an undeclared one' {
        # Already argued, so not a finding. The undeclared twin in another function proves the
        # filter is the declaration and not, say, the description.
        $eq = [pscustomobject]@{ 'src/a.ps1:Get-Thing:-eq -> -ne' = 'cannot change behaviour' }
        $r = Get-PSMutationSarifResult -Operators @('BinaryOperator') -Equivalents $eq -Results @(
            (Row 1), (Row 2 -Function 'Other'))
        @($r).Count | Should-Be 1
        $r[0].message.text | Should-BeLikeString '*in Other*'
    }

    It 'shapes one result fully: rule, level, message, location and fingerprint' {
        $r = (Get-PSMutationSarifResult -Operators @('BooleanLiteral', 'BinaryOperator') -Results @((Row 7)))[0]
        $r.ruleId | Should-Be 'PSMutant/BinaryOperator'
        # The index of the rule in the RUN's list -- here the second.
        $r.ruleIndex | Should-Be 1
        # A test gap, not a defect: the same severity as the console and CI annotation.
        $r.level | Should-Be 'warning'
        $r.message.text | Should-Be 'Mutant survived in Get-Thing: -eq -> -ne. No test failed when the code was changed this way.'
        $r.locations[0].physicalLocation.artifactLocation.uri | Should-Be 'src/a.ps1'
        $r.locations[0].physicalLocation.region.startLine | Should-Be 7
        $r.partialFingerprints.psMutantMutant | Should-Be 'src/a.ps1:Get-Thing:-eq -> -ne'
    }

    It 'says no function for code at file scope rather than an empty "in"' {
        $r = (Get-PSMutationSarifResult -Operators @('BinaryOperator') -Results @((Row 7 -Function '')))[0]
        $r.message.text | Should-Be 'Mutant survived: -eq -> -ne. No test failed when the code was changed this way.'
    }

    It 'pairs each result with its own fingerprint, in order' {
        # Two survivors whose fingerprints differ; an off-by-one in the pairing hands the first
        # result the second one's identity.
        $r = Get-PSMutationSarifResult -Operators @('BinaryOperator') -Results @(
            (Row 1), (Row 2 -Description '-gt -> -le'))
        @($r).Count | Should-Be 2
        $r[0].partialFingerprints.psMutantMutant | Should-Be 'src/a.ps1:Get-Thing:-eq -> -ne'
        $r[1].partialFingerprints.psMutantMutant | Should-Be 'src/a.ps1:Get-Thing:-gt -> -le'
        $r[1].locations[0].physicalLocation.region.startLine | Should-Be 2
    }

    It 'returns an empty array when nothing survived, so the log closes old alerts' {
        $r = Get-PSMutationSarifResult -Operators @('BinaryOperator') -Results @((Row 1 -Status 'Killed'))
        Should-HaveType -Actual $r -Expected ([object[]])
        @($r).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationSarifDocument' {
    BeforeAll {
        $script:doc = Get-PSMutationSarifDocument -Results @((Row 1), (Row 2 -Status 'Killed')) `
            -Operators @('BinaryOperator') -Summary $script:summary -ModuleVersion '1.2.3'
    }

    It 'is a SARIF 2.1.0 log naming this tool and its version' {
        $script:doc.version | Should-Be '2.1.0'
        $driver = $script:doc.runs[0].tool.driver
        $driver.name | Should-Be 'PSMutant'
        # GHAzDO1018: Azure DevOps refuses a driver without fullName.
        $driver.fullName | Should-Be 'PSMutant 1.2.3'
        $driver.version | Should-Be '1.2.3'
        @($driver.rules).Count | Should-Be 1
    }

    It 'never writes an empty version, which is what a dot-sourced load would have' {
        $d = Get-PSMutationSarifDocument -Results @() -Operators @('BinaryOperator') -Summary $script:summary -ModuleVersion ''
        $d.runs[0].tool.driver.version | Should-Be 'unknown'
        $d.runs[0].tool.driver.fullName | Should-Be 'PSMutant unknown'
    }

    It 'carries the run''s verdict beside the findings' {
        $p = $script:doc.runs[0].properties
        $p.mutationScore | Should-Be 75.0
        $p.killed | Should-Be 3
        $p.survived | Should-Be 1
        $p.total | Should-Be 4
    }

    It 'carries the survivors as results' {
        @($script:doc.runs[0].results).Count | Should-Be 1
    }

    It 'writes no automationDetails, leaving the category to the pipeline' {
        # On GitHub an id in the file overrides the upload step's category, so two uploads in one
        # repository would overwrite each other. Pinned so adding it is argued, not drifted into.
        @($script:doc.runs[0].Keys) -contains 'automationDetails' | Should-BeFalse
    }
}

Describe 'Save-PSMutationSarifDocument' {
    It 'writes the deepest value as a value, not a .NET type name' {
        # ConvertTo-Json truncates past its depth SILENTLY. The location uri is the deepest leaf
        # in the log; read back as text so a truncated object shows up as its type name.
        $path = Join-Path $TestDrive "deep/$([guid]::NewGuid().ToString('N')).sarif"
        Save-PSMutationSarifDocument -Path $path -Document (Get-PSMutationSarifDocument -Results @((Row 3)) `
                -Operators @('BinaryOperator') -Summary $script:summary -ModuleVersion '1.0.0')
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should-NotBeLikeString '*System.Collections*'
        ($text | ConvertFrom-Json).runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri |
            Should-Be 'src/a.ps1'
    }

    It 'takes a bracket in the path literally' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $dir 'run[1].sarif'
        Save-PSMutationSarifDocument -Path $path -Document ([ordered]@{ version = '2.1.0' })
        Should-BeTrue -Actual (Test-Path -LiteralPath $path)
    }
}

Describe 'Export-PSMutationSarif' {
    It 'writes nothing and says nothing when no path is configured' {
        $out = Export-PSMutationSarif -Path '' -Results @((Row 1)) -Operators @('BinaryOperator') -Summary $script:summary
        Should-BeNull -Actual $out
    }

    It 'writes the log and returns one line naming the path and the finding count' {
        $path = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).sarif"
        $line = Export-PSMutationSarif -Path $path -Results @((Row 1), (Row 2 -Description '-gt -> -le'), (Row 3 -Status 'Killed')) `
            -Operators @('BinaryOperator') -Summary $script:summary -ModuleVersion '1.0.0'
        Should-BeTrue -Actual (Test-Path -LiteralPath $path)
        $line.Role | Should-Be 'Muted'
        $line.Text | Should-Be "  SARIF: $path (2 finding(s))"
        @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).runs[0].results).Count | Should-Be 2
    }
}
