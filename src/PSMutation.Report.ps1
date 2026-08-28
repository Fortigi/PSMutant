<#
.SYNOPSIS
    Scoring, JSON report, console summary, and the public run-result shape. Everything a
    consumer's CI reads is decided here, so widening any of those shapes is a change to a
    published contract -- tests pin the exact field list of each.
#>

# The report format's version. Bump it when a field changes MEANING or disappears -- not
# when one is added, which readers survive. It exists so a consumer can branch on a number
# instead of sniffing for keys -- this module already ships two report shapes, and anything
# reconciling them has otherwise to recognise each by which keys it happens to carry.
$script:PSMutationSchemaVersion = 1

function New-PSMutationProvenance {
    # How a report was produced: which schema, which build, when, and how long it took.
    #
    # Pure, and takes every varying value as a parameter, because the two things it needs --
    # the clock and the loaded module -- are exactly what makes a function untestable. The
    # orchestrator reads them once and passes them in; this decides only the shape.
    #
    # `durations` is not decoration. Any change to the runner justified by speed is
    # otherwise evaluated by timing two runs by hand on one machine, and a suite drifting
    # toward its timeout bound -- where expiry is scored as a kill -- shows up only once it
    # crosses. The timeout is recorded beside the baseline it was derived from, which is
    # what makes the comparison mean anything.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns a hashtable, changes no system state.')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [string]$ModuleVersion,
        [datetime]$GeneratedAt = [datetime]::UtcNow,
        [double]$BaselineSeconds,
        [double]$TotalSeconds,
        [int]$PerMutantTimeoutSeconds
    )
    return @{
        schemaVersion = $script:PSMutationSchemaVersion
        producedBy    = @{ module = 'PSMutant'; version = "$ModuleVersion" }
        # Round-trippable and sortable as text, and UTC so reports from two machines can be
        # compared without knowing where either ran.
        generatedAt   = $GeneratedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        durations     = @{
            baselineSeconds        = [math]::Round($BaselineSeconds, 1)
            totalSeconds           = [math]::Round($TotalSeconds, 1)
            perMutantTimeoutSeconds = $PerMutantTimeoutSeconds
        }
    }
}

function Get-PSMutationEquivalentKey {
    # Every string a config may use to declare THIS mutant equivalent, stablest first.
    #
    # Not the mutant id: ids are AST-walk positions and renumber whenever an earlier mutant
    # is added or removed. Not the line number alone either: editing anything ABOVE a
    # declared mutant -- a comment, an import, another function entirely -- moves the line,
    # and the declaration goes stale although the mutant is untouched.
    #
    # `File:Function:Description` is stable under every edit that does not move the mutant
    # out of its function. `File:Line:Description` is still accepted, second, so existing
    # configs keep working -- a fix for key churn that invalidated every key would be a
    # poor trade. Code at file scope has no function to be addressed by, so it keeps only
    # the line form.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    # NO comma-wrap, unlike Get-PSMutationLoopRange. That one wraps because an empty @()
    # unrolls to $null and breaks a mandatory binding downstream; this never returns empty
    # and its caller iterates it, so wrapping would hand the foreach a single item that IS
    # the array.
    # Cast on the EXPRESSION, @() inside it: casting the variable leaves the analyzer
    # inferring the branch types (string here, object[] there) against the declared
    # [string[]], and dropping the @() turns a single key into a scalar the cast cannot
    # widen. Same shape as Get-PSMutationCandidate, same reason.
    $byLine = "$($Result.File):$($Result.Line):$($Result.Description)"
    if ([string]::IsNullOrEmpty([string]$Result.Function)) { return [string[]]@($byLine) }
    return [string[]]@("$($Result.File):$($Result.Function):$($Result.Description)", $byLine)
}

function Get-PSMutationDeclaredKey {
    # The declaration covering this mutant, or $null when none does.
    #
    # Stablest form wins when a config declares both, so the count that decides ambiguity
    # is never inflated by one mutant answering to two of its own keys.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [hashtable]$Declared
    )
    foreach ($k in Get-PSMutationEquivalentKey -Result $Result) {
        if ($Declared.ContainsKey($k)) { return $k }
    }
    return $null
}

function Get-PSMutationDeclaredEquivalent {
    # Pure: normalise the config's `equivalents` object into key -> reason. A
    # declaration with a blank reason is dropped, so "equivalent" always comes with
    # a stated argument someone can disagree with.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param($Equivalents)
    $map = @{}
    if ($null -eq $Equivalents) { return $map }
    foreach ($p in $Equivalents.PSObject.Properties) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p.Value)) { $map[$p.Name] = [string]$p.Value }
    }
    return $map
}

function Get-PSMutationDeclarationFault {
    # Why an equivalence declaration is invalid, or $null when it is exactly right.
    #
    # Zero, one and many are three genuinely different answers and only one is acceptable,
    # because a declaration is an argument about ONE mutant:
    #
    #   none     the code moved and nobody revisited the claim
    #   one      the claim is well formed; whether it is TRUE is decided elsewhere, by
    #            whether the suite killed the mutant
    #   several  it would exclude mutants nobody argued about, silently, and stale-detection
    #            cannot notice because the key still matches something
    #
    # A separate unit rather than two more branches inside Get-PSMutationScore: it is a
    # decision, so it is worth testing on its own terms -- and inlining it put that function
    # over the cognitive-complexity ceiling, which is the gate noticing the same thing.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Key,
        [Parameter(Mandatory)] [int]$Hits
    )
    if ($Hits -eq 0) { return "$Key -- declared equivalent but no such mutant exists" }
    if ($Hits -gt 1) {
        return "$Key -- matches $Hits mutants, so the declaration is ambiguous: it argues about one and would exclude all of them"
    }
    return $null
}

function Get-PSMutationScore {
    # Pure: turn result rows into a score summary. No I/O.
    #
    # A mutant declared equivalent leaves the DENOMINATOR only while it actually
    # survives. If one is killed, the declaration was wrong, and rather than
    # quietly banking the kill it is surfaced as stale: a config that claims a
    # mutant cannot be caught, next to a test that caught it, is a false statement
    # about the code and the whole point of demanding a reason is that it can be
    # checked. Same for a declaration matching no mutant at all -- the code moved
    # and nobody revisited the claim.
    #
    # And the same for a declaration matching MORE than one mutant. Two mutants on a
    # line can legitimately share `File:Line:Description` -- `$prev[$j] + 1` and
    # `$curr[$j - 1] + 1` both read `1 -> 2` -- and a declaration that hits both
    # excludes a mutant nobody argued about, silently, while stale-detection stays
    # quiet because the key still matches something. A declaration is a claim
    # about ONE mutant, so matching several is not a smaller claim, it is an
    # ambiguous one, and the run says so rather than banking the exclusion.
    #
    # PER SET, and only per set. Every number here -- Score, Killed, Survived, Total,
    # DeclaredEquivalent -- is a fold over the rows handed in, and the "declared equivalent
    # but the suite killed it" fault is too: it is observed on a row that is present.
    #
    # Whether a declaration matched NO mutant, or matched several, is a question about the
    # WHOLE run and lives in Get-PSMutationDeclarationCoverageFault. Asking it here made the
    # answer wrong for any subset: scoring one file's rows accused every declaration
    # belonging to another file of being stale. Nothing did that yet, and per-file scores
    # would have been the first thing to.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        $Equivalents
    )
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    $stale = [System.Collections.Generic.List[string]]::new()

    $killed = 0; $survived = 0; $excluded = 0; $timedOut = 0
    foreach ($r in $Results) {
        $key = Get-PSMutationDeclaredKey -Result $r -Declared $declared
        $isDeclared = $null -ne $key
        # A timeout counts toward $killed so the headline score does not move, and is
        # ALSO counted on its own so a rising number is visible. Reporting only the sum
        # is what let a merely slow suite look like a thorough one.
        if ($r.Status -eq 'TimedOut') { $timedOut++ }
        if ($r.Status -eq 'Killed' -or $r.Status -eq 'TimedOut') {
            $killed++
            if ($isDeclared) { $stale.Add("$key -- declared equivalent but the suite killed it") }
        }
        elseif ($isDeclared) { $excluded++ }
        else { $survived++ }
    }
    $total = $Results.Count - $excluded
    $score = $total -gt 0 ? [math]::Round(100.0 * $killed / $total, 1) : 0
    return [pscustomobject]@{
        Score = $score; Killed = $killed; Survived = $survived; Total = $total
        TimedOut = $timedOut
        DeclaredEquivalent = $excluded; StaleEquivalents = $stale.ToArray()
    }
}

function Get-PSMutationFailureReason {
    # WHY a run failed, as a value rather than as prose: 'None', 'StaleEquivalents' or
    # 'BelowThreshold'. Pure.
    #
    # Report-only unless thresholds.break is set and the score is below it. A stale equivalence
    # declaration fails the run REGARDLESS of thresholds, and regardless of report-only mode: it
    # is not a quality shortfall to be graded on a curve, it is a false statement in the config
    # that is inflating the score.
    #
    # Stale is reported FIRST when both are true. It is the more specific answer and the more
    # actionable one -- a score computed with a false declaration in it is not a score anybody
    # should be reading, so "your score is low" would send the reader to write tests when the
    # config is what needs editing.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, $Thresholds)
    # Filter before counting: @($null).Count is 1, not 0, so a summary that carries
    # no stale list at all would otherwise fail every run.
    if (@($Summary.StaleEquivalents | Where-Object { $_ }).Count -gt 0) { return 'StaleEquivalents' }
    if ($null -ne $Thresholds.break -and $Summary.Score -lt $Thresholds.break) { return 'BelowThreshold' }
    return 'None'
}

function Get-PSMutationExitCode {
    # The verdict, derived from the reason. Pure.
    #
    # Derived rather than decided again. These two answers are the same judgement asked at
    # different resolutions, and written as two independent rule sets they would drift the first
    # time a third failure mode arrived -- one of them silently keeping the old vocabulary while
    # the other grew. The exit code is a projection of the reason, so it cannot disagree with it.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, $Thresholds)
    if ((Get-PSMutationFailureReason -Summary $Summary -Thresholds $Thresholds) -eq 'None') { return 0 }
    return 1
}

function Get-PSMutationCoverageExclusion {
    <#
    .SYNOPSIS
        What the coverage filter removed, so the score can answer for it.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile)
    # `declaredEquivalent` is already reported for exactly this reason -- a reader who cannot
    # see how many mutants were excluded cannot tell a real 100% from an excluded one. The
    # coverage filter removes far more than declarations do and said nothing at all.
    $skipped = 0
    $silent = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $PerFile) {
        $skipped += $f.Produced - $f.Kept
        # The dangerous case, and the reason this is file-level and not just a count: the file
        # is still listed in `mutate` and still hashed into the report, so nothing downstream
        # can tell it contributed nothing. A per-file score would read 0/0 and look fine.
        if ($f.Produced -gt 0 -and $f.Kept -eq 0) { $silent.Add($f.File) }
    }
    return [pscustomobject]@{ Skipped = $skipped; FilesWithNoMutants = $silent.ToArray() }
}

function Get-PSMutationExclusionLine {
    <#
    .SYNOPSIS
        The caveat a score carries when the coverage filter removed anything, or nothing.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param($Exclusion)
    # Its own function so both arms are reachable from a test: written inline, the
    # nothing-excluded arm runs on every clean run and is asserted by none.
    # $null reaches here from the direct callers in tests, which do no filtering at all --
    # for them "nothing was skipped" is the true answer, not a guess.
    if ($null -eq $Exclusion -or $Exclusion.Skipped -eq 0) { return '' }
    $line = "  $($Exclusion.Skipped) mutant(s) skipped as uncovered"
    if ($Exclusion.FilesWithNoMutants.Count -gt 0) {
        # Named, not counted. "2 files contributed none" sends the reader looking; the names
        # are what turn it into an action.
        $line += " ($($Exclusion.FilesWithNoMutants.Count) file(s) contributed none: $($Exclusion.FilesWithNoMutants -join ', '))"
    }
    return $line
}

function Save-PSMutationReportDocument {
    <#
    .SYNOPSIS
        Serialise a report document to disk, failing the run when it cannot be written.
    #>
    param(
        [Parameter(Mandatory)] [object]$Document,
        [Parameter(Mandatory)] [string]$ReportPath
    )
    # Both statements below are NON-TERMINATING by default, and that is the whole point of
    # this function. A reportPath that is absolute, holds a wildcard bracket, is read-only or
    # is locked used to print "Report: <path>" for a file nothing had written, and exit 0 --
    # a green run with no artifact, in the one durable thing a consumer's CI reads.
    #
    # .NET rather than New-Item for the directory: New-Item has no -LiteralPath, so a bracket
    # in the path is a wildcard to it, and it reports failure without stopping the run.
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $ReportPath)) | Out-Null
    # -LiteralPath so a bracket is a character rather than a character class, and
    # -ErrorAction Stop so the run dies at the real error instead of carrying on to report a
    # score for output that does not exist.
    $Document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -ErrorAction Stop
}

function Write-PSMutationReport {
    # Write the JSON report; return the summary.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [string]$ReportPath,
        $Thresholds,
        [hashtable]$SourceHashes,
        [string[]]$Operators,
        $Equivalents,
        # One block rather than four more parameters: this signature is already long.
        [hashtable]$Provenance = @{},
        # What the coverage filter removed. A score that cannot say what it excluded is the
        # same failure as one that cannot say what it declared equivalent.
        $Exclusion = $null,
        # Mutate files with no tests entry. Not a correctness problem -- the whole suite is
        # never less thorough -- but a cost paid per mutant, and invisible until now.
        [AllowEmptyCollection()] [string[]]$UnmappedFiles = @()
    )
    # The only place holding EVERY row, so the only place that can ask whether a
    # declaration matched nothing. The per-set fold no longer answers it.
    $summary = Get-PSMutationScore -Results $Results -Equivalents $Equivalents
    # Concatenated unconditionally: guarding on a non-empty $coverage adds a branch whose
    # false arm is indistinguishable from its true arm, since appending nothing changes
    # nothing. Both of that guard's mutants survived.
    $coverage = Get-PSMutationDeclarationCoverageFault -Results $Results -Equivalents $Equivalents
    $summary.StaleEquivalents = [string[]]@(@($summary.StaleEquivalents) + @($coverage) | Where-Object { $_ })
    $document = [pscustomobject]@{
        generatedFrom = 'PSMutant'
        # Provenance first, so a reader opening the JSON sees what produced it before what
        # it says. Additive: nothing that read this report before reads any less of it.
        schemaVersion = $Provenance.schemaVersion
        producedBy    = $Provenance.producedBy
        generatedAt   = $Provenance.generatedAt
        durations     = $Provenance.durations
        mutationScore = $summary.Score
        total = $summary.Total; killed = $summary.Killed; survived = $summary.Survived
        # Additive, and included in `killed` rather than beside it: a consumer that never
        # read this field still reconciles killed + survived against total.
        timedOut = $summary.TimedOut
        # Reported so the headline score can always be reconciled against the raw
        # mutant count: total EXCLUDES declared equivalents, and a reader who cannot
        # see how many were excluded cannot tell a real 100% from a declared one.
        declaredEquivalent = $summary.DeclaredEquivalent
        # Beside declaredEquivalent because it answers the same question: how much of what
        # the config asked for is NOT behind this number. This one removes far more.
        skippedAsUncovered = [int]$Exclusion.Skipped
        filesWithNoMutants = @($Exclusion.FilesWithNoMutants)
        # Recorded beside the other disclosures: a run that took twice as long for a reason
        # nobody chose should say so somewhere a CI job can read afterwards.
        filesWithoutTestMapping = @($UnmappedFiles)
        staleEquivalents = @($summary.StaleEquivalents)
        thresholds = $Thresholds
        # Recorded so a later -RecheckFrom can prove the mutant numbering in this
        # report still refers to the same code. Mutant Ids come from AST walk order,
        # so they only mean anything for identical source and an identical operator
        # set; without these two fields a recheck could match the wrong mutants and
        # report a confident, wrong answer.
        operators = @($Operators | Sort-Object)
        sourceHashes = $SourceHashes
        survivors = @($Results | Where-Object Status -eq 'Survived')
        mutants = $Results
    }
    Save-PSMutationReportDocument -Document $document -ReportPath $ReportPath
    return $summary
}

function Get-PSMutationDeclarationCoverageFault {
    # WHOLE RUN: every declaration that matched no mutant, or matched more than one.
    #
    # Separate from Get-PSMutationScore because it is the one question in scoring that a
    # subset cannot answer. A declaration missing from a group of rows is not stale -- its
    # mutant is simply in another group -- so the check is only correct over every row the
    # run produced. Kept together with the fold in one pass, per-file scores would emit a
    # false stale-equivalence accusation for every declaration belonging to another file,
    # and that rule is the strongest correctness signal this tool has: it fires regardless
    # of thresholds, so a false positive there is worse than a wrong number.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        $Equivalents
    )
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    # A count, not a set: "matched something" and "matched exactly one" are different
    # claims, and only the second is the one a declaration makes.
    $matched = @{}
    foreach ($r in $Results) {
        $key = Get-PSMutationDeclaredKey -Result $r -Declared $declared
        if ($null -ne $key) { $matched[$key] = 1 + [int]$matched[$key] }
    }

    # Filtered once at the end rather than guarded per key. `if ($fault)` looks like it
    # earns its place and does not: the caller drops falsy entries anyway, so adding a $null
    # here is unobservable and the guard's mutant survives. One filter, no branch.
    $faults = foreach ($k in $declared.Keys) {
        Get-PSMutationDeclarationFault -Key $k -Hits ([int]$matched[$k])
    }
    # No comma-wrap: the caller concatenates this with another array.
    return [string[]]@($faults | Where-Object { $_ })
}

function Get-PSMutationScoreRole {
    # Good at or above High, Warn at or above Low, Bad below it.
    #
    # A ROLE, not a colour: which console colour that becomes is the renderer's business.
    # Returning a colour here puts console vocabulary in a file whose job is arithmetic.
    #
    # Resolved numbers only, never a raw config value: `$score -ge $null` is $true, so an
    # unresolved band reports every score as Good rather than failing.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Score,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low
    )
    if ($Score -ge $High) { return 'Good' }
    if ($Score -ge $Low) { return 'Warn' }
    return 'Bad'
}

function Get-PSMutationTimeoutNote {
    <#
    .SYNOPSIS
        The qualifier a score carries when mutants died on the clock, or nothing.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$TimedOut)
    # Its own function so BOTH arms are reachable from a test. Written inline in the format
    # string, the no-timeout arm is executed by every run and asserted by none, and the arm
    # that matters -- the one that qualifies a score -- would never be exercised at all.
    if ($TimedOut -eq 0) { return '' }
    return "   [$TimedOut killed on the clock, not by a failing test]"
}

function Get-PSMutationSummaryLine {
    # What a completed run should say: the score, what qualified it, and the survivors to
    # go add assertions for. Pure -- it decides, Write-PSMutationOutput emits.
    #
    # No comma-wrap: this never returns fewer than three lines and its caller binds the
    # result to an [object[]] parameter, so there is no single-item case to protect.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low,
        [string]$ReportPath,
        $Equivalents,
        $Exclusion
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    $lines.Add((New-PSMutationLine -Role 'Rule' -Text "`n----------------------------------------------"))
    # Resolved numbers in, not the raw config. Comparing against $Thresholds.high directly
    # compares against $null for every config without colour bands, and `$score -ge $null`
    # is $true -- so every score reads as Good, 0% included.
    $lines.Add((New-PSMutationLine -Role (Get-PSMutationScoreRole -Score $Summary.Score -High $High -Low $Low) `
                -Text ("  Mutation score: {0}%  ({1} killed / {2}){3}" -f $Summary.Score, $Summary.Killed, $Summary.Total,
                    (Get-PSMutationTimeoutNote -TimedOut $Summary.TimedOut))))
    # Beside the score for the same reason the declared-equivalent line is: the coverage
    # filter can empty a whole mutate file, and then a green 100% answers for a smaller set
    # than the config asked for. This one removes far more mutants than declarations do.
    $skipLine = Get-PSMutationExclusionLine -Exclusion $Exclusion
    if ($skipLine) { $lines.Add((New-PSMutationLine -Role 'Muted' -Text $skipLine)) }
    # Said next to the score, not buried in the report: a 100% built on a dozen declared
    # equivalents is a different claim from a 100% that killed everything.
    if ($Summary.DeclaredEquivalent -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Muted' `
                    -Text ("  {0} mutant(s) excluded as declared-equivalent (see config)" -f $Summary.DeclaredEquivalent)))
    }
    $stale = @($Summary.StaleEquivalents | Where-Object { $_ })   # @($null).Count is 1
    if ($stale.Count -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Bad' -Text '  INVALID equivalence declarations - the config is claiming something untrue:'))
        $stale | ForEach-Object { $lines.Add((New-PSMutationLine -Role 'Bad' -Text "    $_")) }
    }
    # A declared equivalent is not a survivor to go and fix: listing it here sends
    # the reader after a mutant the config already argued is unkillable, which is
    # how a good declaration gets "fixed" with a meaningless test.
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    $open = @($Results | Where-Object { $_.Status -eq 'Survived' -and -not (Get-PSMutationDeclaredKey -Result $_ -Declared $declared) })
    if ($open.Count -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Warn' -Text '  Survivors (add assertions to kill these):'))
        # -Data carries the mutant row itself. A renderer emitting CI annotations needs the
        # file and line as values, and recovering them by parsing the text back out is the
        # coupling this seam exists to remove.
        $open | ForEach-Object {
            $lines.Add((New-PSMutationLine -Role 'Warn' -Data $_ `
                        -Text ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Description)))
        }
    }
    $lines.Add((New-PSMutationLine -Role 'Detail' -Text "  Report: $ReportPath"))
    return [object[]]$lines.ToArray()
}

function ConvertTo-PSMutationRunResult {
    # The public shape of a completed run: what a consumer's CI reads off Invoke-PSMutation.
    # A published contract -- a test pins the exact field list, so widening it is a
    # decision rather than a side effect of a rename.
    #
    # It carries the REASON, not just the verdict. ExitCode 1 means either a stale equivalence
    # declaration or a score below the break threshold, and a caller that cannot tell them apart
    # has to guess -- which is how a workflow came to print "score is below the break threshold"
    # over a run scoring 100%, a false statement about the run and the only thing a destroyed
    # runner leaves behind.
    #
    # The equivalents travel with it for the same reason. The stale list is the whole content of
    # that failure, and it otherwise exists only in a JSON file nothing uploads and in a summary
    # line -Quiet suppresses -- which is to say, in CI, nowhere.
    #
    # Mode is on BOTH shapes so a caller that did not choose the mode can still tell which one it
    # received. The two used to share no field at all.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [int]$ExitCode,
        [Parameter(Mandatory)] [string]$FailureReason
    )
    return [pscustomobject]@{
        Mode               = 'Full'
        Score              = $Summary.Score
        Killed             = $Summary.Killed
        Survived           = $Summary.Survived
        Total              = $Summary.Total
        ExitCode           = $ExitCode
        FailureReason      = $FailureReason
        # Always an array, never $null: a consumer iterating this should not have to tell
        # "nothing was stale" from "this build of the module stopped reporting it".
        StaleEquivalents   = [string[]]@($Summary.StaleEquivalents | Where-Object { $_ })
        DeclaredEquivalent = [int]$Summary.DeclaredEquivalent
    }
}
