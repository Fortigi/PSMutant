<#
.SYNOPSIS
    Re-evaluating only the mutants that survived a previous run.

.DESCRIPTION
    The write-tests-kill-survivors loop is the slow part of using this tool: every
    iteration re-runs the whole mutant set, and the mutants you already killed cost
    exactly as much as the ones you are working on. A recheck runs ONLY the mutants
    a previous report recorded as survivors.

    This is a development-loop convenience, and it is deliberately not a
    measurement:

      * It cannot produce a mutation score. Killing 6 of 10 previous survivors is
        not "60%" of anything -- the denominator is a filtered set.
      * It is sound only for test changes that are purely ADDITIVE. Editing or
        deleting an existing test can bring a previously-killed mutant back to
        life, and a recheck never looks at those, so it would report success while
        the real score fell. Run the full set before trusting a number or moving a
        threshold.

    Both facts are enforced rather than documented-and-hoped: the recheck writes to
    its own report path so it can never overwrite the full baseline, its console
    summary reports counts instead of a score, and thresholds are not applied.

    MATCHING. A mutant is identified by (File, Id). Id comes from the order the AST
    walk emits candidates, so it is stable for a given file content and operator
    set -- and meaningless if either changed. Rather than silently matching the
    wrong mutants, a recheck refuses to run when the recorded source hash or
    operator set no longer matches. That is why the report carries both.

    This file holds the WHOLE feature, pure parts and orchestration alike. It used to
    hold only the pure half, with Invoke-PSMutationRecheckRun sitting in the entry
    point -- a split by purity rather than by feature, which nothing documented and
    which is why two test files each owned half of one behaviour (#45).
#>

function Get-PSMutationSourceHash {
    # SHA256 of a file's bytes, lowercase hex. Used to prove the source a report
    # was produced from is byte-identical to the source in front of us now.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-PSMutationSourceHashMap {
    # displayPath -> hash, for every file in the mutate set.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $map = @{}
    foreach ($f in $MutateFiles) {
        $map[(ConvertFrom-PSMutationSandboxPath -Path $f -SandboxRoot $SandboxRoot)] = Get-PSMutationSourceHash -Path $f
    }
    return $map
}

function Test-PSMutationRecheckCompatible {
    # Pure. Compare a prior report against the current source hashes + operator set
    # and return the reasons a recheck would be unsound (empty = compatible).
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators
    )
    $reasons = [System.Collections.Generic.List[string]]::new()

    if (-not $Report.PSObject.Properties.Name.Contains('sourceHashes') -or $null -eq $Report.sourceHashes) {
        $reasons.Add('the report predates source-hash recording, so the mutants it lists cannot be matched to the current source -- run the full set once to regenerate it')
        return , $reasons.ToArray()
    }

    $priorOps = @($Report.operators)
    if (($priorOps -join ',') -ne (($Operators | Sort-Object) -join ',')) {
        $reasons.Add("the operator set changed ('$($priorOps -join ', ')' -> '$(($Operators | Sort-Object) -join ', ')'), which renumbers every mutant")
    }

    foreach ($name in ($SourceHashes.Keys | Sort-Object)) {
        $prior = $Report.sourceHashes.$name
        if (-not $prior) { $reasons.Add("$name is not in the report (it was added to the mutate set since)") }
        elseif ($prior -ne $SourceHashes[$name]) { $reasons.Add("$name changed since the report was written") }
    }
    return , $reasons.ToArray()
}

function Select-PSMutationRecheckCandidate {
    # Pure. Keep only the candidates a prior report recorded as Survived, matched on
    # (File, Id). Candidates are sandbox-absolute; report files are display paths.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    # A set, not a hashtable-with-dummy-values: the value stored against each key was
    # never read (ContainsKey ignores it), so it was noise that looked like data.
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($s in @($Report.survivors)) { [void]$wanted.Add("$($s.File)|$($s.Id)") }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Candidates) {
        $key = "$(ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot)|$($c.Id)"
        if ($wanted.Contains($key)) { $out.Add($c) }
    }
    return , $out.ToArray()
}

function Get-PSMutationRecheckReportPath {
    # Sibling of the full report, never the same file -- a partial run must not be
    # able to overwrite the baseline it was derived from.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ReportPath)
    $dir  = Split-Path $ReportPath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ReportPath)
    $ext  = [System.IO.Path]::GetExtension($ReportPath)
    return (Join-Path $dir "$name.recheck$ext")
}

function Write-PSMutationRecheckReport {
    # Write the recheck JSON. Deliberately carries NO mutationScore field: the set
    # is filtered, so any percentage computed over it would be read as a file score.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [int]$PriorSurvivorCount,
        [string]$SourceReportPath
    )
    $killed = @($Results | Where-Object Status -eq 'Killed').Count
    New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force | Out-Null
    [pscustomobject]@{
        generatedFrom      = 'PSMutant'
        mode               = 'Recheck'
        note               = 'Partial run over a previous report''s survivors. Not a mutation score; a full run is required before trusting a number, because edited or deleted tests can revive mutants this run never evaluated.'
        recheckedFrom      = $SourceReportPath
        priorSurvivors     = $PriorSurvivorCount
        rechecked          = $Results.Count
        nowKilled          = $killed
        stillSurviving     = @($Results | Where-Object Status -eq 'Survived')
        mutants            = $Results
    } | ConvertTo-Json -Depth 6 | Set-Content $ReportPath
    return [pscustomobject]@{
        Mode = 'Recheck'; PriorSurvivors = $PriorSurvivorCount
        Rechecked = $Results.Count; NowKilled = $killed
        StillSurviving = $Results.Count - $killed
    }
}

function Show-PSMutationRecheckSummary {
    # Counts, not a score, and the caveat every time -- a recheck that reads like a
    # measurement is exactly how a filtered number ends up quoted as a real one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [string]$ReportPath
    )
    $col = if ($Summary.StillSurviving -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "`n----------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Recheck: {0} of {1} previous survivor(s) now killed" -f $Summary.NowKilled, $Summary.Rechecked) -ForegroundColor $col
    if ($Summary.StillSurviving -gt 0) {
        Write-Host "  Still surviving:" -ForegroundColor Yellow
        $Results | Where-Object Status -eq 'Survived' | ForEach-Object {
            Write-Host ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Description) -ForegroundColor Yellow
        }
    }
    Write-Host "  Not a mutation score - this run skipped every mutant that was already killed." -ForegroundColor DarkGray
    Write-Host "  Run the full set before trusting a number: edited tests can revive mutants this run never saw." -ForegroundColor DarkGray
    Write-Host "  Report: $ReportPath" -ForegroundColor Gray
}

function Invoke-PSMutationRecheckRun {
    # The whole -RecheckFrom path. Impure -- it reads the prior report and drives the
    # loop -- so tests mock Invoke-PSMutationLoop rather than evaluating real mutants,
    # which is what keeps this file's covering suite cheap enough to self-mutate.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RecheckFrom,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [string]$ReportPath,
        [switch]$Quiet
    )
    $prior = Get-Content $RecheckFrom -Raw | ConvertFrom-Json
    # Refuse rather than guess. Mutant ids are AST-walk positions: if the source or
    # the operator set moved, the ids in the report point at different mutants now,
    # and a recheck would answer confidently about the wrong ones.
    $why = Test-PSMutationRecheckCompatible -Report $prior -SourceHashes $SourceHashes -Operators $Operators
    if ($why.Count -gt 0) {
        throw ("Cannot recheck against '$RecheckFrom': " + ($why -join '; ') + '. Run the full set to regenerate the report.')
    }
    $targets = Select-PSMutationRecheckCandidate -Candidates $Candidates -Report $prior -SandboxRoot $SandboxRoot
    if (-not $Quiet) { Write-Host "  Rechecking $($targets.Count) previous survivor(s)`n" -ForegroundColor Gray }

    $results = Invoke-PSMutationLoop -Candidates $targets -TestsByFile $Plan.TestsByFile -AllTests $Plan.AllTests `
        -TimeoutSeconds $TimeoutSeconds -SandboxRoot $SandboxRoot -Quiet:$Quiet
    $recheckPath = Get-PSMutationRecheckReportPath -ReportPath $ReportPath
    $summary = Write-PSMutationRecheckReport -Results $results -ReportPath $recheckPath `
        -PriorSurvivorCount @($prior.survivors).Count -SourceReportPath $RecheckFrom
    if (-not $Quiet) { Show-PSMutationRecheckSummary -Summary $summary -Results $results -ReportPath $recheckPath }
    return $summary
}
