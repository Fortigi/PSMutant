<#
.SYNOPSIS
    Scoring, JSON report, and console summary for the PowerShell mutation runner.
    Split from the execution engine so each unit stays small and independently testable.
#>

function Get-PSMutationScore {
    # Pure: turn result rows into a score summary. No I/O.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results)
    $killed   = @($Results | Where-Object Status -eq 'Killed').Count
    $survived = @($Results | Where-Object Status -eq 'Survived').Count
    $total    = $Results.Count
    $score    = if ($total -gt 0) { [math]::Round(100.0 * $killed / $total, 1) } else { 0 }
    return [pscustomobject]@{ Score = $score; Killed = $killed; Survived = $survived; Total = $total }
}

function Get-PSMutationExitCode {
    # Report-only unless thresholds.break is set and the score is below it. Pure.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, $Thresholds)
    if ($null -ne $Thresholds.break -and $Summary.Score -lt $Thresholds.break) { return 1 }
    return 0
}

function Write-PSMutationReport {
    # Write the JSON report; return the summary.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [string]$ReportPath,
        $Thresholds
    )
    $summary = Get-PSMutationScore -Results $Results
    New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force | Out-Null
    [pscustomobject]@{
        generatedFrom = 'PSMutant'
        mutationScore = $summary.Score
        total = $summary.Total; killed = $summary.Killed; survived = $summary.Survived
        thresholds = $Thresholds
        survivors = @($Results | Where-Object Status -eq 'Survived')
        mutants = $Results
    } | ConvertTo-Json -Depth 6 | Set-Content $ReportPath
    return $summary
}

function Show-PSMutationSummary {
    # Human-readable summary + the list of survivors to go add assertions for.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        $Thresholds,
        [string]$ReportPath
    )
    $col = if ($Summary.Score -ge $Thresholds.high) { 'Green' } elseif ($Summary.Score -ge $Thresholds.low) { 'Yellow' } else { 'Red' }
    Write-Host "`n──────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ("  Mutation score: {0}%  ({1} killed / {2})" -f $Summary.Score, $Summary.Killed, $Summary.Total) -ForegroundColor $col
    if ($Summary.Survived -gt 0) {
        Write-Host "  Survivors (add assertions to kill these):" -ForegroundColor Yellow
        $Results | Where-Object Status -eq 'Survived' | ForEach-Object {
            Write-Host ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Description) -ForegroundColor Yellow
        }
    }
    Write-Host "  Report: $ReportPath" -ForegroundColor Gray
}
