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

function Get-PSMutationTestFileLength {
    <#
    .SYNOPSIS
        Each mapped test file's size, keyed by the path the config names it by.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Path,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    # HERE rather than in Report.ps1, where it started. That file is a documented SINK: it
    # serialises what it is handed and reaches into no other layer, and this needs the sandbox
    # path converter -- so putting it there created a Report -> Sandbox edge the layering gate
    # refused. It sits beside Get-PSMutationSourceHashMap instead, which does the same job for
    # source files and keys its map the same way.
    #
    # Keyed by the path RELATIVE TO THE SANDBOX, exactly as Get-PSMutationSourceHashMap keys its
    # hashes, and for the same reason: the absolute path contains the run's pid and its random
    # sandbox token, so it can never match a later run's. Keyed that way the map was written and
    # then compared against keys that differed every time -- the merge gate saw a baseline whose
    # every test file was "gone".
    #
    # A file that cannot be read is simply absent, and the merge gate reads that as "was in the
    # baseline and is gone", which is the honest answer: a test that is not there cannot be
    # holding up any mutant's status.
    $out = @{}
    foreach ($p in $Path) {
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($item) { $out[(ConvertFrom-PSMutationSandboxPath -Path $p -SandboxRoot $SandboxRoot)] = [int]$item.Length }
    }
    return $out
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

function Get-PSMutationMergeFault {
    <#
    .SYNOPSIS
        Why this recheck may not be folded back into its baseline, as text. Nothing when it may.
    #>
    # object[], not string[]: both returns use the unary comma so an empty result survives the
    # pipeline as an empty array rather than $null, and that wrapper is an object[].
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        # What the baseline recorded about each mapped test file: name -> @{ length }.
        $BaselineTests,
        [Parameter(Mandatory)] [hashtable]$CurrentTests
    )
    # A merge carries over the status of every mutant the recheck did NOT evaluate, and those
    # statuses are only as good as the tests that produced them. Adding a test cannot revive a
    # mutant the baseline killed; EDITING or DELETING one can, and a recheck never looks at it --
    # so a merged report would confidently show a mutant dead that is alive again.
    #
    # The existing compatibility guard cannot help: it watches the SOURCE, and this is a question
    # about the tests.
    $faults = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $BaselineTests) {
        $faults.Add('the baseline records nothing about its test files, so there is no way to tell whether a carried-over status still holds -- run the full set once to regenerate it')
        return , $faults.ToArray()
    }
    foreach ($name in (@($BaselineTests.PSObject.Properties.Name) | Where-Object { $_ } | Sort-Object)) {
        if (-not $CurrentTests.ContainsKey($name)) {
            $faults.Add("$name was in the baseline and is gone -- every mutant it killed is carried over unverified, and a deleted test is exactly what revives one")
            continue
        }
        # LENGTH, not hash, and the difference is the whole usable range of this feature. Hash
        # equality answers "unchanged", which is far too strict: the recheck loop IS write a test,
        # re-run, and writing a test changes the file it lives in. Refusing a merge whenever a
        # test file changed would refuse the loop this exists to serve.
        #
        # Length is a NECESSARY-not-sufficient signal in the safe direction. A file that shrank
        # lost something, and losing an assertion is what revives a mutant. A file that grew may
        # still have had an assertion weakened in the same edit -- which is why growth permits the
        # merge rather than certifying it, and why the merged report always says how many mutants
        # were carried over without being re-evaluated.
        # The recorded value IS the length. Reading `.length` off it looked natural and is a trap:
        # PowerShell gives a scalar a .Length of 1, so the comparison became "is 150 less than 1"
        # and never fired. The unit probe missed it because its fixture nested the number in an
        # object -- a shape the report never writes -- which is the fixture-does-not-match-reality
        # failure, caught only by running the thing end to end.
        $was = [int]$BaselineTests.$name
        if ([int]$CurrentTests[$name] -lt $was) {
            $faults.Add("$name is shorter than when the baseline was written ($([int]$CurrentTests[$name]) bytes against $was) -- something was removed, and a merge would carry over every mutant it used to kill")
        }
    }
    return , $faults.ToArray()
}

function Get-PSMutationMergedMutant {
    <#
    .SYNOPSIS
        The baseline's mutants with the rechecked ones' statuses applied.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Baseline,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Rechecked
    )
    # Keyed on the mutant's stable identity rather than on Id. Ids are assigned by walk order, so
    # they mean the same thing only for identical source and operators -- which the compatibility
    # gate already required to get this far -- but keying on the same string the equivalence
    # declarations use means a merge cannot quietly pair the wrong two rows if that ever changes.
    $byKey = @{}
    foreach ($r in $Rechecked) { $byKey[@(Get-PSMutationEquivalentKey -Result $r)[0]] = $r }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $Baseline) {
        $key = @(Get-PSMutationEquivalentKey -Result $b)[0]
        if ($byKey.ContainsKey($key)) {
            # The recheck looked at this one, so its verdict is current. Everything else about the
            # row -- file, line, operator, description -- comes from the baseline, because that is
            # where it was measured and the recheck row is a projection of the same mutant.
            $fresh = $byKey[$key]
            $out.Add([pscustomobject]@{
                    Id = $b.Id; Function = $b.Function; File = $b.File; Line = $b.Line
                    Operator = $b.Operator; Description = $b.Description
                    Status = $fresh.Status; KilledBy = @($fresh.KilledBy)
                })
        }
        else { $out.Add($b) }
    }
    return , $out.ToArray()
}

function Get-PSMutationMergedBaseline {
    <#
    .SYNOPSIS
        The baseline document with this recheck's verdicts applied, and the caveat recorded in it.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Rechecked,
        $Equivalents
    )
    $merged = Get-PSMutationMergedMutant -Baseline @($Baseline.mutants) -Rechecked $Rechecked
    $doc = $Baseline
    $doc.mutants = $merged
    $doc.survivors = @($merged | Where-Object Status -eq 'Survived')
    # RE-SCORED from the merged rows. Writing the rows without re-folding the totals leaves the
    # document self-contradictory -- new verdicts under the old number -- which is worse than not
    # merging at all, because the number is what everything downstream reads.
    $score = Get-PSMutationScore -Results $merged -Equivalents $Equivalents
    # Add-Member -Force rather than assignment: setting a property a document does not already
    # carry THROWS on a PSCustomObject, so a report missing any one of these -- an older one, or a
    # hand-edited one -- would crash the merge instead of being merged. Every field is set the
    # same way so no one of them is a special case.
    foreach ($f in @{ mutationScore = $score.Score; total = $score.Total; killed = $score.Killed
            survived = $score.Survived; timedOut = $score.TimedOut
            declaredEquivalent = $score.DeclaredEquivalent }.GetEnumerator()) {
        $doc | Add-Member -NotePropertyName $f.Key -NotePropertyValue $f.Value -Force
    }
    # THE CAVEAT LIVES IN THE ARTIFACT, not only in the console. Everything downstream reads this
    # file as a measurement, and most of it was measured by an earlier run: a merged report says
    # how many of its mutants were carried over without being re-evaluated, so a reader can see
    # what fraction of the score this run actually stood behind.
    $doc | Add-Member -NotePropertyName mergedFrom -NotePropertyValue @($Rechecked).Count -Force
    $doc | Add-Member -NotePropertyName carriedOverUnverified `
        -NotePropertyValue (@($merged).Count - @($Rechecked).Count) -Force
    return $doc
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
    # THE OTHER DIRECTION, and it was missing. The loop above walks the CURRENT mutate set, so it
    # sees a file added and a file changed -- but a file the REPORT covers and this run does not is
    # invisible, because nothing asks about it. A narrower config therefore accepted a wider
    # report: measured, a config mutating a.ps1 accepted a report over a.ps1 and b.ps1 with zero
    # reasons.
    #
    # That is not a cosmetic mismatch. -RecheckFrom takes the report's whole survivor list, so the
    # run would evaluate b.ps1's survivors with no tests mapped for b.ps1 and no b.ps1 in the
    # sandbox, then report "N of M previous survivors now killed" over a set it never had. A
    # confident answer about the wrong thing is the failure this module is organised around.
    #
    # It is reachable without any concurrency at all -- a scoped local run and a full run sharing
    # the default reportPath is enough -- which is why it is checked here rather than left to the
    # advice that concurrent runs should choose distinct paths.
    foreach ($name in (@($Report.sourceHashes.PSObject.Properties.Name) | Where-Object { $_ } | Sort-Object)) {
        if (-not $SourceHashes.ContainsKey($name)) {
            $reasons.Add("$name is in the report but not in this run's mutate set -- the report describes a different run, and its survivors for that file cannot be re-evaluated here")
        }
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
    # ExitCode and FailureReason are here so the two shapes share a field a caller can branch on
    # without first knowing which mode it asked for. They used to have no field in common at all,
    # so `if ($result.ExitCode -ne 0) { throw }` -- the idiom this module's own README teaches --
    # compared $null against 0 and threw on a perfectly successful recheck, while `exit
    # $result.ExitCode` became `exit $null`, which is 0, and passed even with every prior survivor
    # still alive. One shape failed loudly and the other passed silently, from the same absence.
    #
    # Always 0, because a recheck applies no thresholds by design: it answers "is this one dead
    # yet", over a set somebody chose, and a verdict over a chosen subset is the filtered number
    # this module exists to stop people quoting. StillSurviving is the answer to read.
    return [pscustomobject]@{
        Mode = 'Recheck'; PriorSurvivors = $PriorSurvivorCount
        Rechecked = $Results.Count; NowKilled = $killed
        StillSurviving = $Results.Count - $killed
        ExitCode = 0; FailureReason = 'None'
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
    $role = $Summary.StillSurviving -eq 0 ? 'Good' : 'Warn'
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

function Select-PSMutationResumeCandidate {
    <#
    .SYNOPSIS
        The candidates a prior partial report did NOT record. Pure.
    .DESCRIPTION
        The INVERSE of Select-PSMutationRecheckCandidate, and deliberately a separate function
        rather than a switch on that one: the two keep different rows for opposite reasons -- a
        recheck wants the survivors it recorded, a resume wants everything it never reached -- and
        a parameter choosing between them would put two features behind one name.

        Matched on (File, Id), the same key a recheck uses, rather than on a COUNT. A partial
        report is a genuine prefix -- finished mutants are retired in candidate order, which is
        one of the three things that ordering buys -- so "the first N" would be correct today.
        It would also be a second definition of the same thing, and the one that breaks silently
        if the ordering ever changes. The key does not.

        Declared equivalents are NOT skipped here, unlike in a recheck. A recheck re-runs
        survivors and a declared equivalent is guaranteed-wasted work; a resume is completing a
        measurement, and a mutant nobody has evaluated has to be evaluated whatever the config
        says about it -- the declaration is checked against the RESULT, and a result it never
        produced cannot be checked at all.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $done = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($m in @($Report.mutants)) { [void]$done.Add("$($m.File)|$($m.Id)") }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Candidates) {
        $key = "$(ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot)|$($c.Id)"
        if (-not $done.Contains($key)) { $out.Add($c) }
    }
    return , $out.ToArray()
}

function Get-PSMutationResumeFault {
    <#
    .SYNOPSIS
        Why a resume may not proceed, as text. Nothing when it may.
    .DESCRIPTION
        Three questions, sequenced, and the order is the message's quality.

        1. **Is it a partial report at all?** A full report has nothing left to resume and a
           recheck report describes a different kind of run. Asked first because every answer
           below assumes the document is the shape this reads.
        2. **Was it numbered against this source?** Mutant ids are AST-walk positions, so a
           changed file or a changed operator set makes the recorded ids point at other mutants.
           That is exactly the question `-RecheckFrom` asks, and it is asked with the same
           function -- a second implementation would be a second answer.
        3. **Could the carried-over verdicts have gone stale?** THIS is the one the issue behind
           the feature did not name. A resume carries over every verdict in the report, and those
           are only as good as the tests that produced them: adding a test cannot revive a mutant
           the earlier run killed, but editing or deleting one can, and a resume never re-looks.
           `Get-PSMutationMergeFault` already decides this, on test-file length, for
           `-MergeIntoBaseline` -- a resume is a merge in disguise and asks it unchanged.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        [Parameter(Mandatory)] [hashtable]$CurrentTests
    )
    if ($Report.mode -ne 'Partial') {
        return ("that report is '$($Report.mode)', not 'Partial'. -ResumeFrom continues a run that " +
            'was INTERRUPTED; a completed report has nothing left to evaluate and a recheck report ' +
            'describes a different kind of run.')
    }
    $why = Test-PSMutationRecheckCompatible -Report $Report -SourceHashes $SourceHashes -Operators $Operators
    if ($why.Count -gt 0) { return ($why -join '; ') + '. Run the full set to start over.' }
    $stale = Get-PSMutationMergeFault -BaselineTests $Report.testFiles -CurrentTests $CurrentTests
    if ($stale.Count -gt 0) {
        return ($stale -join '; ') + '. A resume carries those verdicts over without re-running them.'
    }
    return ''
}

function Get-PSMutationResumeState {
    <#
    .SYNOPSIS
        What a run continuing an interrupted one has to know: which candidates are left, which
        rows it inherits, and what to say about it.
    .DESCRIPTION
        Returns the same shape whether or not this IS a resume, so the caller needs no branch --
        an ordinary run gets its candidates back unchanged, no prior rows and no notice. That is
        not tidiness: `Invoke-PSMutationRun` was already at 13 of a ceiling of 15, and a feature
        that spends two of the remaining branches on asking whether it is switched on has nothing
        left for the feature.

        It THROWS rather than returning a fault, for the reason -RecheckFrom does: a resume that
        cannot be trusted is a fault in what the caller asked for, not a verdict about the code,
        and returning a false score would be the confident-number-over-a-subset failure this
        module exists to prevent.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # Empty means this is not a resume. A [string] rather than a switch plus a path, because
        # the two can never disagree that way.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ResumeFrom,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators
    )
    if (-not $ResumeFrom) {
        return [pscustomobject]@{ IsResume = $false; Candidates = $Candidates; PriorRows = @(); Lines = @() }
    }
    $prior = Get-Content $ResumeFrom -Raw | ConvertFrom-Json
    $fault = Get-PSMutationResumeFault -Report $prior -SourceHashes $SourceHashes -Operators $Operators `
        -CurrentTests (Get-PSMutationTestFileLength -Path $Plan.AllTests -SandboxRoot $SandboxRoot)
    if ($fault) { throw "Cannot resume from '$ResumeFrom': $fault" }
    $remaining = Select-PSMutationResumeCandidate -Candidates $Candidates -Report $prior -SandboxRoot $SandboxRoot
    $carried = @($prior.mutants)
    return [pscustomobject]@{
        IsResume   = $true
        Candidates = $remaining
        PriorRows  = $carried
        # Said BEFORE the loop, because that is when it can still be acted on, and because a
        # resumed run is otherwise indistinguishable from a short one that measured everything.
        Lines      = @(New-PSMutationLine -Role 'Muted' -Text (
                "  RESUMED from {0}: {1} mutant(s) carried over from that run, {2} left to evaluate. Up to one worker-count's worth may be re-run, because a mutant can finish without being recorded." -f `
                (Split-Path $ResumeFrom -Leaf), $carried.Count, @($remaining).Count))
    }
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
        # The pool's extra sandboxes, passed straight through. A recheck evaluates its mutants
        # through the same loop as a full run, so it gets the same parallelism from the same
        # config key rather than a second answer about how many workers this run has.
        [AllowEmptyCollection()] [string[]]$WorkerSandbox = @(),
        [Parameter(Mandatory)] [string]$ReportPath,
        # Needed to skip declared equivalents when choosing what to re-run.
        $Equivalents,
        # A scriptblock, not a value: it is evaluated after the loop so the elapsed time it
        # records is the whole run rather than the moment the run started.
        [scriptblock]$Provenance = { @{} },
        [switch]$Quiet,
        # Fold this recheck's verdicts back into the baseline it came from. Opt-in, and it
        # refuses rather than merging when the tests behind the carried-over statuses may have
        # changed -- see Get-PSMutationMergeFault.
        [switch]$MergeIntoBaseline
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

    # A recheck's own accumulator. It is not read on interruption -- a recheck already writes a
    # counts-only report and re-running it is cheap -- but the loop takes the list rather than
    # owning one, so there is nowhere else for the rows to go.
    $rows = [System.Collections.Generic.List[object]]::new()
    $results = Invoke-PSMutationLoop -Candidates $targets -Sink $rows -TestsByFile $Plan.TestsByFile -AllTests $Plan.AllTests `
        -TimeoutSeconds $TimeoutSeconds -SandboxRoot $SandboxRoot -WorkerSandbox $WorkerSandbox -Quiet:$Quiet
    $recheckPath = Get-PSMutationRecheckReportPath -ReportPath $ReportPath
    # The prior report's own hashes and operator set travel with the new one, so the next
    # round can validate against them. Recomputing here would describe the CURRENT source
    # rather than the source these ids were numbered against, which is the opposite of what
    # the gate needs to check.
    $summary = Write-PSMutationRecheckReport -Results $results -ReportPath $recheckPath `
        -PriorSurvivorCount @($prior.survivors).Count -SourceReportPath $RecheckFrom `
        -SourceHashes $SourceHashes -Operators $Operators -Provenance (& $Provenance)
    if ($MergeIntoBaseline) {
        # Refused, not warned about. A merged report is a FULL report -- it carries a score, and
        # everything downstream reads it as a measurement. Emitting one whose carried-over
        # statuses may be stale would undo the honesty the recheck design was built around, which
        # is why -RecheckFrom writes to a separate file in the first place.
        # ASSIGNED, not wrapped in @( ). The callee returns `, $array` so an empty result stays an
        # empty array rather than $null -- and @( ) around that yields a ONE-element array holding
        # the array, so .Count is 1 for no faults at all and the merge is refused with a blank
        # reason. Same trap as the per-file scores, in a third place.
        $mergeFaults = Get-PSMutationMergeFault -BaselineTests $prior.testFiles `
            -CurrentTests (Get-PSMutationTestFileLength -Path $Plan.AllTests -SandboxRoot $SandboxRoot)
        if ($mergeFaults.Count -gt 0) {
            throw ("Refusing to merge this recheck into $RecheckFrom." + [Environment]::NewLine +
                (($mergeFaults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine) +
                [Environment]::NewLine + 'A merge carries over the status of every mutant this run did ' +
                'not evaluate. Run the full set to get a report that measured all of them.')
        }
        Save-PSMutationReportDocument -ReportPath $RecheckFrom -Document (
            Get-PSMutationMergedBaseline -Baseline $prior -Rechecked $results -Equivalents $Equivalents)
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                -Text ("  Merged {0} rechecked verdict(s) into {1}; {2} mutant(s) carried over unverified." -f `
                        @($results).Count, $RecheckFrom, (@($prior.mutants).Count - @($results).Count)))
    }
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
