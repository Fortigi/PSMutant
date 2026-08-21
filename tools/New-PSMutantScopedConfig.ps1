<#
.SYNOPSIS
    Write a mutation config scoped to the files the current change touched, for the
    edit-run-edit loop. NOT a gate.

.DESCRIPTION
    The self-mutation gate is several hundred mutants and a handful of minutes, nearly all
    of it re-proving files nobody edited. This narrows the real config to the files in the
    current change so a local run costs seconds, and prints what it left out so the smaller
    number is never mistaken for the project's.

    A changed test file pulls in the source it covers, because writing the assertion that
    kills a survivor is exactly the edit whose effect you want to see.

    The generated file is untracked by design and carries its own warning. Nothing here
    replaces `Invoke-PSMutation -ConfigFile ./psmutant.self.config.json`, which is the only
    run whose score describes the project.

.PARAMETER Since
    The ref to diff against. Everything changed between its merge-base with HEAD and the
    working tree counts, so committed and uncommitted edits are both in scope.

.PARAMETER ConfigFile
    The real config to narrow.

.PARAMETER OutFile
    Where to write the scoped config. Untracked; see .gitignore.

.PARAMETER Run
    Run the scoped config immediately instead of only writing it.

.EXAMPLE
    ./tools/New-PSMutantScopedConfig.ps1 -Run

    Narrow to whatever this branch changed against main, and run it.

.EXAMPLE
    ./tools/New-PSMutantScopedConfig.ps1 -Since HEAD

    Narrow to uncommitted work only -- the tightest loop, for while you are still editing.
#>
[CmdletBinding()]
param(
    [string]$Since = 'main',
    [string]$ConfigFile = './psmutant.self.config.json',
    [string]$OutFile = './psmutant.scoped.config.json',
    [switch]$Run
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'ScopedConfig.ps1')

$base = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Diff against the MERGE-BASE, not the ref itself. Diffing against `main` directly reports
# every file main has moved on since the branch started, which scopes in work this change
# never touched -- slower, and it invites the reader to think those files were verified.
$mergeBase = (git merge-base $Since HEAD 2>$null)
if ([string]::IsNullOrWhiteSpace($mergeBase)) { $mergeBase = $Since }

$changed = @(git diff --name-only $mergeBase) + @(git ls-files --others --exclude-standard)
$changed = @($changed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

$reportPath = 'reports/ps-mutation-scoped.json'
$scoped = Get-PSMutantScopedConfig -BaseConfig $base -ChangedFiles $changed -ReportPath $reportPath

if ($null -eq $scoped) {
    Write-Host "Nothing mutatable in this change -- $($changed.Count) changed file(s), none of them a mutated source file or a mapped test suite." -ForegroundColor Yellow
    Write-Host "  Run the full gate to get a number: Invoke-PSMutation -ConfigFile $ConfigFile" -ForegroundColor Gray
    return
}

$scoped | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding utf8

$skipped = @(@($base.mutate) | Where-Object { $_ -notin $scoped.mutate })
Write-Host "`nScoped config written to $OutFile" -ForegroundColor Cyan
Write-Host "  In scope: $($scoped.mutate -join ', ')" -ForegroundColor Green
# The skipped list is printed, not summarised as a count. "5 files not mutated" is a number
# nobody checks; the names are what let you notice the one you actually changed is missing
# because it is spelled differently in the config.
if ($skipped.Count -gt 0) {
    Write-Host "  NOT mutated: $($skipped -join ', ')" -ForegroundColor DarkGray
}
Write-Host "  This is NOT the gate. Its score describes the files above, not this project." -ForegroundColor Yellow

if ($Run) {
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSMutant.psd1') -Force
    Invoke-PSMutation -ConfigFile $OutFile
}
