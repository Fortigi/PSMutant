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

    Compatibility, selection and the run itself, in one file.
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
        # Name the schema when the report has one. Without a version the message can only
        # guess from which keys are present, and it guesses wrong for a whole class of
        # report -- telling someone chaining a recheck that theirs "predates source-hash
        # recording" when the real reason is that it is not that kind of report at all.
        # No Contains() guard, unlike the sourceHashes check above. There, absent and
        # present-but-null are different cases and a test pins each; here they mean the same
        # thing -- no usable version -- and a missing property already reads as $null, so the
        # extra half is a condition nothing can ever distinguish. The mutation gate said so.
        $schema = if ($Report.schemaVersion) {
            "schema version $($Report.schemaVersion)"
        } else { 'no schema version, so it predates provenance recording' }
        $reasons.Add("the report carries no source hashes ($schema), so the mutants it lists cannot be matched to the current source -- run the full set once to regenerate it")
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
        [Parameter(Mandatory)] [string]$SandboxRoot,
        $Equivalents
    )
    # A set, not a hashtable-with-dummy-values: the value stored against each key was
    # never read (ContainsKey ignores it), so it was noise that looked like data.
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # Declared equivalents are skipped. They appear in `survivors` legitimately --
    # they survived, they were merely excluded from the denominator -- but the config
    # states in writing that no test can kill them, so re-running one is guaranteed-wasted
    # work. In the case that prompted this it was 16 of 20 mutants, and the waste grows
    # exactly as a repo gets more disciplined about declaring.
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    foreach ($s in @($Report.survivors)) {
        if (Get-PSMutationDeclaredKey -Result $s -Declared $declared) { continue }
        [void]$wanted.Add("$($s.File)|$($s.Id)")
    }
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
    #
    # Idempotent, because a recheck can seed another recheck: without this the third round
    # writes `report.recheck.recheck.json` and the fourth adds another suffix. Each round
    # overwrites the previous recheck instead. The protection that
    # matters is that the FULL report is never touched, and that is unaffected -- the
    # rounds are a scratch pad, and the report worth keeping is the one CI reads.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ReportPath)
    $dir  = Split-Path $ReportPath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ReportPath)
    $ext  = [System.IO.Path]::GetExtension($ReportPath)
    if ($name.EndsWith('.recheck')) { return (Join-Path $dir "$name$ext") }
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
        [string]$SourceReportPath,
        # Copied from the report this chained off, so the next round can validate against
        # them exactly as it would against a full report.
        [hashtable]$SourceHashes,
        [AllowEmptyCollection()] [string[]]$Operators = @(),
        [hashtable]$Provenance = @{}
    )
    # Same rule as a full report: a timeout scores with the kills.
    $killed = @($Results | Where-Object { $_.Status -eq 'Killed' -or $_.Status -eq 'TimedOut' }).Count
    $document = [pscustomobject]@{
        generatedFrom      = 'PSMutant'
        # Same block as a full report, so a consumer can read provenance the same way from
        # either shape rather than learning two conventions.
        schemaVersion      = $Provenance.schemaVersion
        producedBy         = $Provenance.producedBy
        generatedAt        = $Provenance.generatedAt
        durations          = $Provenance.durations
        mode               = 'Recheck'
        note               = 'Partial run over a previous report''s survivors. Not a mutation score; a full run is required before trusting a number, because edited or deleted tests can revive mutants this run never evaluated.'
        recheckedFrom      = $SourceReportPath
        priorSurvivors     = $PriorSurvivorCount
        rechecked          = $Results.Count
        nowKilled          = $killed
        # `survivors`, not `stillSurviving`. This is the name Select-PSMutationRecheckCandidate
        # reads, and a recheck report that names the list anything else cannot seed another
        # round: the compatibility gate ACCEPTS it, selection then finds nothing, and the run
        # reports "0 of 0 previous survivor(s) now killed" -- a confident, wrong "you are done".
        survivors          = @($Results | Where-Object Status -eq 'Survived')
        # The two things Test-PSMutationRecheckCompatible needs. Copied from the report this
        # round chained off, not recomputed: they describe the source these mutant ids were
        # numbered against, which is exactly the claim the next round has to check.
        sourceHashes       = $SourceHashes
        operators          = @($Operators | Sort-Object)
        mutants            = $Results
    }
    Save-PSMutationReportDocument -Document $document -ReportPath $ReportPath
    return [pscustomobject]@{
        Mode = 'Recheck'; PriorSurvivors = $PriorSurvivorCount
        Rechecked = $Results.Count; NowKilled = $killed
        StillSurviving = $Results.Count - $killed
    }
}

function Get-PSMutationRecheckSummaryLine {
    # Counts, not a score, and the caveat every time -- a recheck that reads like a
    # measurement is exactly how a filtered number ends up quoted as a real one. Pure;
    # Write-PSMutationOutput emits.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [string]$ReportPath
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    $role = if ($Summary.StillSurviving -eq 0) { 'Good' } else { 'Warn' }
    $lines.Add((New-PSMutationLine -Role 'Rule' -Text "`n----------------------------------------------"))
    $lines.Add((New-PSMutationLine -Role $role `
                -Text ("  Recheck: {0} of {1} previous survivor(s) now killed" -f $Summary.NowKilled, $Summary.Rechecked)))
    if ($Summary.StillSurviving -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Warn' -Text '  Still surviving:'))
        $Results | Where-Object Status -eq 'Survived' | ForEach-Object {
            $lines.Add((New-PSMutationLine -Role 'Warn' -Data $_ `
                        -Text ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Description)))
        }
    }
    # Muted, not Rule. Both print DarkGray, but these are the caveats that stop a partial
    # number being quoted as a real one -- a renderer that drops separators must keep them.
    $lines.Add((New-PSMutationLine -Role 'Muted' -Text '  Not a mutation score - this run skipped every mutant that was already killed.'))
    $lines.Add((New-PSMutationLine -Role 'Muted' -Text '  Run the full set before trusting a number: edited tests can revive mutants this run never saw.'))
    $lines.Add((New-PSMutationLine -Role 'Detail' -Text "  Report: $ReportPath"))
    return [object[]]$lines.ToArray()
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
        # Needed to skip declared equivalents when choosing what to re-run.
        $Equivalents,
        # A scriptblock, not a value: it is evaluated after the loop so the elapsed time it
        # records is the whole run rather than the moment the run started.
        [scriptblock]$Provenance = { @{} },
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
    $targets = Select-PSMutationRecheckCandidate -Candidates $Candidates -Report $prior -SandboxRoot $SandboxRoot -Equivalents $Equivalents
    Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Detail' `
            -Text "  Rechecking $($targets.Count) previous survivor(s)`n")

    $results = Invoke-PSMutationLoop -Candidates $targets -TestsByFile $Plan.TestsByFile -AllTests $Plan.AllTests `
        -TimeoutSeconds $TimeoutSeconds -SandboxRoot $SandboxRoot -Quiet:$Quiet
    $recheckPath = Get-PSMutationRecheckReportPath -ReportPath $ReportPath
    # The prior report's own hashes and operator set travel with the new one, so the next
    # round can validate against them. Recomputing here would describe the CURRENT source
    # rather than the source these ids were numbered against, which is the opposite of what
    # the gate needs to check.
    $summary = Write-PSMutationRecheckReport -Results $results -ReportPath $recheckPath `
        -PriorSurvivorCount @($prior.survivors).Count -SourceReportPath $RecheckFrom `
        -SourceHashes $SourceHashes -Operators $Operators -Provenance (& $Provenance)
    $recheckLines = Get-PSMutationRecheckSummaryLine -Summary $summary `
        -Results $results -ReportPath $recheckPath
    Write-PSMutationOutput -Quiet:$Quiet -Lines $recheckLines
    # Same reasoning as the full run: the switch silences the log, not the findings. A recheck
    # that still leaves survivors is the one result somebody has to act on.
    if (Test-PSMutationAnnotationHost) {
        # @() because a run with NOTHING to annotate yields no lines at all, and -Lines
        # accepts an empty collection but not $null. Without it a clean run under Actions
        # throws on binding -- so the green path would be the one that crashed.
        # -Quiet:$false rather than omitting the switch. Not decoration: an omitted switch
        # is UNBOUND on the call, and a Should-Invoke filter that mentions $Quiet then has
        # to resolve it -- $false, or the caller's own $Quiet further up the scope chain --
        # and the two answers are not the same on every PowerShell. Binding it explicitly
        # makes every renderer call carry the parameter, so no filter anywhere can be
        # ambiguous about which calls it selected.
        #
        # It also says the thing out loud at the call site: annotations are deliberately
        # NOT suppressed, because -Quiet silences the log and a finding is not log.
        Write-PSMutationOutput -Quiet:$false -Lines @(Get-PSMutationAnnotationLine -Lines $recheckLines)
    }
    return $summary
}
