# Complexity gate: every shipped unit (function or script body) must stay at or under
# 15 cyclomatic AND 15 cognitive complexity. Cognitive is the nesting-aware SonarSource
# metric -- the better signal for "hard to reason about". Runs in the gated CI test job.

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'tools' 'Get-PSComplexity.ps1')
    $files = Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'tools') -Filter *.ps1 -Recurse
    $script:threshold = 15
    $script:units = @($files | ForEach-Object { Measure-PSComplexity -Path $_.FullName })
}

Describe 'Complexity gate' {
    It 'measured at least one unit' {
        $script:units.Count | Should -BeGreaterThan 0
    }

    It 'has no unit over cyclomatic complexity 15' {
        $over = @($script:units | Where-Object Cyclomatic -gt $script:threshold)
        $detail = ($over | ForEach-Object { "$($_.File):$($_.Unit) (CC=$($_.Cyclomatic))" }) -join ', '
        $over.Count | Should -Be 0 -Because "these units exceed cyclomatic 15: $detail"
    }

    It 'has no unit over cognitive complexity 15' {
        $over = @($script:units | Where-Object Cognitive -gt $script:threshold)
        $detail = ($over | ForEach-Object { "$($_.File):$($_.Unit) (Cog=$($_.Cognitive))" }) -join ', '
        $over.Count | Should -Be 0 -Because "these units exceed cognitive 15: $detail"
    }
}
