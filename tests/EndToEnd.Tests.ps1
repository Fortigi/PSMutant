# End-to-end: run the public Invoke-PSMutation against a tiny throwaway fixture project
# (one function + a covering test + a config) and assert the summary, the JSON report,
# and -- the headline guarantee -- that the tracked source is byte-identical afterwards.

BeforeAll {
    $module = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSMutant.psd1'
    Import-Module $module -Force

    $script:proj = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-e2e-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:proj 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:proj 'tests') -Force | Out-Null

    $script:srcFile = Join-Path $script:proj 'src/calc.ps1'
    'function Get-Sign { param($n) if ($n -gt 0) { return ''pos'' } else { return ''neg'' } }' | Set-Content $script:srcFile -Encoding utf8

    @'
BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is pos for positive' { Get-Sign 5 | Should -Be 'pos' }
    It 'is neg for non-positive' { Get-Sign -5 | Should -Be 'neg' }
}
'@ | Set-Content (Join-Path $script:proj 'tests/calc.Tests.ps1') -Encoding utf8

    $cfg = [ordered]@{
        sandboxSubtrees  = @('src', 'tests')
        mutate           = @('src/calc.ps1')
        tests            = @{ 'src/calc.ps1' = @('tests/calc.Tests.ps1') }
        coveredLinesOnly = $true
        operators        = @('BinaryOperator', 'BooleanLiteral')
        thresholds       = @{ high = 85; low = 70; break = $null }
        reportPath       = 'reports/e2e.json'
    }
    $script:configFile = Join-Path $script:proj 'mutation.config.json'
    $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:configFile -Encoding utf8

    $script:originalSrc = [System.IO.File]::ReadAllText($script:srcFile)
    $script:result = Invoke-PSMutation -ConfigFile $script:configFile -SourceRoot $script:proj -Quiet
}

AfterAll { Remove-Item $script:proj -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-PSMutation end-to-end' {
    It 'evaluates at least one mutant' {
        $script:result.Total | Should -BeGreaterThan 0
    }
    It 'kills mutants that the covering test catches (score > 0)' {
        $script:result.Killed | Should -BeGreaterThan 0
        $script:result.Score | Should -BeGreaterThan 0
    }
    It 'returns a consistent summary' {
        ($script:result.Killed + $script:result.Survived) | Should -Be $script:result.Total
        $script:result.ExitCode | Should -Be 0   # thresholds.break is null -> report-only
    }
    It 'writes the JSON report' {
        $report = Join-Path $script:proj 'reports/e2e.json'
        Test-Path $report | Should -BeTrue
        (Get-Content $report -Raw | ConvertFrom-Json).mutationScore | Should -Be $script:result.Score
    }
    It 'leaves the tracked source byte-identical' {
        [System.IO.File]::ReadAllText($script:srcFile) | Should -Be $script:originalSrc
    }
    It 'leaves no sandbox temp directory behind' {
        (Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter "psmut-sandbox-$PID" -ErrorAction SilentlyContinue) |
            Should -BeNullOrEmpty
    }
}
