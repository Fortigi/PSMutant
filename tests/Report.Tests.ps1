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
        $s.Killed   | Should -Be 2
        $s.Survived | Should -Be 1
        $s.Total    | Should -Be 3
        $s.Score    | Should -Be 66.7
    }
    It 'reports 0 for an empty result set (no divide-by-zero)' {
        $s = Get-PSMutationScore -Results @()
        $s.Total | Should -Be 0
        $s.Score | Should -Be 0
    }
    It 'reports 100 when everything is killed' {
        $s = Get-PSMutationScore -Results @([pscustomobject]@{ Status = 'Killed' })
        $s.Score | Should -Be 100
    }
}

Describe 'Get-PSMutationExitCode' {
    It 'returns 0 in report-only mode (break = null)' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 10 }) -Thresholds ([pscustomobject]@{ break = $null }) | Should -Be 0
    }
    It 'returns 1 when the score is below the break threshold' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 60 }) -Thresholds ([pscustomobject]@{ break = 70 }) | Should -Be 1
    }
    It 'returns 0 when the score meets the break threshold' {
        Get-PSMutationExitCode -Summary ([pscustomobject]@{ Score = 70 }) -Thresholds ([pscustomobject]@{ break = 70 }) | Should -Be 0
    }
}

Describe 'Write-PSMutationReport' {
    It 'writes a JSON report with the score and survivors' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-report-$PID/report.json"
        try {
            $summary = Write-PSMutationReport -Results $script:mixed -ReportPath $out -Thresholds ([pscustomobject]@{ break = $null })
            $summary.Score | Should -Be 66.7
            Test-Path $out | Should -BeTrue
            $json = Get-Content $out -Raw | ConvertFrom-Json
            $json.mutationScore | Should -Be 66.7
            @($json.survivors).Count | Should -Be 1
            @($json.mutants).Count   | Should -Be 3
        }
        finally { Remove-Item (Split-Path $out -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
