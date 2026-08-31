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
$script:PSMutationSchemaVersion = 2

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
    # poor trade.
    #
    # Code at FILE SCOPE has no function to be addressed by, and used to keep only the line
    # form for that reason. It churned exactly as the paragraph above says it would: this
    # repo's own `$script:PSMutationWarmUses = 0` declaration was re-keyed twice in one day,
    # 154 -> 167 -> 181, by two unrelated edits, the second of which was comment-only and
    # changed no code at all (#179). A declaration re-keyed by hand invites updating the
    # number without re-reading the argument, which is how it stops being a claim anyone has
    # checked.
    #
    # So file scope gets a stable NAME instead: `<script-body>`, the same synthetic the
    # sibling uses for a unit with no enclosing function. It is not unique within a file --
    # two file-scope mutants sharing a description answer to one key -- and that is handled
    # rather than ignored: Get-PSMutationDeclarationFault already refuses a key matching more
    # than one mutant as ambiguous. Loud and wrong beats quiet and drifting.
    #
    # The synthetic lives HERE and not in the report's `function` field, which stays empty.
    # This is an addressing scheme; that field is a statement about the code, and there
    # genuinely is no function.
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
    $name = [string]::IsNullOrEmpty([string]$Result.Function) ? '<script-body>' : [string]$Result.Function
    return [string[]]@("$($Result.File):${name}:$($Result.Description)", $byLine)
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

function Invoke-PSMutationSurvivorBaseline {
    <#
    .SYNOPSIS
        Apply the accepted-survivor baseline, or write it. Returns the faults, if any.
    .DESCRIPTION
        Extracted from the orchestrator, which the module's own complexity gate then failed at
        cognitive 19 against a ceiling of 15 -- the read, the two-way branch and the fault loop
        nested inside a function that was already doing the whole run.

        Here rather than in Invoke-PSMutation.ps1 because this reads and writes a DOCUMENT, which
        is what this file owns; the orchestrator keeps the one line that decides whether to call it.
    #>
    # object[], not string[]: both returns use the unary comma so an empty result survives the
    # pipeline as an empty array rather than $null, and that wrapper is an object[] holding a
    # string[]. Declaring the inner type is what PSUseOutputTypeCorrectly objects to, correctly.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BaselinePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        $Equivalents,
        [switch]$Update,
        [switch]$Quiet
    )
    if ($Update) {
        # WRITES WHATEVER THE RUN MEASURED, including on a failing run. Accepting today's mess on
        # a codebase that is already red is the whole use case, and refusing would make the first
        # run impossible -- PHPStan's --generate-baseline takes the same stance. It cannot launder
        # a regression, because the next run compares against what was recorded.
        Save-PSMutationReportDocument -Document (Get-PSMutationUpdatedSurvivorBaseline -Results $Results) `
            -ReportPath $BaselinePath
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                -Text ("  Recorded {0} accepted survivor(s) to {1}." -f `
                    @($Results | Where-Object Status -eq 'Survived').Count, $BaselinePath))
        # Unary comma: without it an empty collection unrolls to $null on the way out, and the
        # caller feeds this straight into a parameter that refuses one.
        return , [string[]]@()
    }
    # An EMPTY object when the file is not there yet, never $null: $null is the decision
    # function's signal for "no baseline configured at all", and a config that NAMES a baseline it
    # has not created must not silently enforce nothing. Missing means every survivor is new,
    # which is what sends somebody to run -UpdateBaseline.
    #
    # -ErrorAction Stop, so a baseline that exists but cannot be READ fails the run rather than
    # being treated as absent -- an unreadable baseline enforcing nothing is the same defect.
    $prior = (Test-Path -LiteralPath $BaselinePath) ?
        ((Get-Content -LiteralPath $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json).survivors) :
        ([pscustomobject]@{})
    $faults = @(Get-PSMutationSurvivorBaselineFault -Results $Results -Baseline $prior `
            -MutateFiles $MutateFiles -Equivalents $Equivalents)
    foreach ($f in $faults) {
        # NOT passed -Quiet: that switch silences the progress log, and a finding is not log. In
        # CI this is the only place the mutants a reader must act on ever appear.
        Write-PSMutationOutput -Quiet:$false -Lines (New-PSMutationLine -Role 'Bad' -Text "  $f")
    }
    return , [string[]]$faults
}

function Get-PSMutationSurvivorBaselineFault {
    <#
    .SYNOPSIS
        Every way a run disagrees with a committed list of accepted survivors.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        # The baseline document's `survivors` map: key -> anything. Only the keys are read.
        $Baseline,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        # The equivalence declarations, so an entry that is BOTH can be refused.
        $Equivalents
    )
    # A SET, NOT A RATIO, and that is the whole design decision. A per-file SCORE cannot be
    # ratcheted honestly because its denominator moves with the source: measured against a file
    # baselined at 90%, deleting ten well-tested lines reads as a regression to 88.9% though
    # nothing got worse, and adding ten well-tested lines reads as an improvement that must be
    # re-recorded. Three of four ordinary edits failed, one of them usefully.
    #
    # Baselining the surviving MUTANTS instead behaves the way PHPStan's and Psalm's baselines do,
    # and for the same reason -- they list specific findings rather than a percentage. Deleting
    # code removes entries; adding under-tested code adds one. One true positive, no false ones.
    #
    # This is DEBT, not equivalence. `equivalents` means "this mutant cannot be killed" and
    # carries a written argument; an entry here means "this mutant is not killed YET". Conflating
    # them is what forces people to lie in `equivalents`, which corrupts the one list whose
    # entries are supposed to be checkable claims.
    $faults = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Baseline) { return $faults.ToArray() }

    # Where-Object, because member enumeration over an object with NO properties yields $null and
    # @($null) is a one-element array holding it. Unfiltered, an EMPTY baseline -- the state a
    # project reaches once the debt is paid off -- produced a phantom entry whose file is the empty
    # string, which is never in the mutate list, so a clean run reported a scope-shrink fault.
    $accepted = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($Baseline.PSObject.Properties.Name | Where-Object { $_ }))
    $mutating = [System.Collections.Generic.HashSet[string]]::new([string[]]@($MutateFiles))

    # Keyed by the SAME builder equivalence declarations use, so an entry survives a line moving.
    # Get-PSMutationEquivalentKey returns the function-keyed form first and the line-keyed form
    # second; only the first is written here, because a baseline is committed once and reviewed
    # rarely, and a key that churns on every edit above it is a key nobody can trust.
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Results) {
        if ($r.Status -ne 'Survived') { continue }
        $key = @(Get-PSMutationEquivalentKey -Result $r)[0]
        [void]$seen.Add($key)
        if (-not $accepted.Contains($key)) {
            $faults.Add("NEW survivor not in the baseline: $key. Kill it, or record it as accepted debt with -UpdateBaseline.")
        }
    }
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    foreach ($key in $accepted) {
        # No split LIMIT: taking element [0] makes the limit inert, so a literal there is a
        # number no test can distinguish -- self-mutation reported it as a survivor.
        $file = ($key -split ':')[0]
        # BOTH AT ONCE PERMITS NOTHING. An equivalence already excuses the mutant outright, so a
        # baseline entry beside it records debt that is not owed -- and the two would then disagree
        # the day somebody deletes one. Adopted from the paired module, whose baseline refuses the
        # same overlap for the same reason.
        if ($declared.Contains($key)) {
            $faults.Add("$key is both declared equivalent and accepted in the baseline. The declaration already excuses it, so the baseline entry permits nothing -- delete one.")
            continue
        }
        # SCOPE SHRINK. Without this, the cheapest way to green a failing gate is to drop the weak
        # file from `mutate`: its survivors stop being reported and nothing notices the code
        # stopped being measured at all.
        if (-not $mutating.Contains($file)) {
            $faults.Add("$key is accepted in the baseline but $file is no longer in mutate. Dropping a file hides its survivors rather than fixing them.")
            continue
        }
        # FIXED, and still recorded. Discrete and meaningful, unlike the same rule over a score:
        # this fires exactly when somebody kills a mutant, and leaving the entry would let that
        # mutant start surviving again later with nothing failing. PHPStan reports an unmatched
        # baseline entry for the same reason.
        if (-not $seen.Contains($key)) {
            $faults.Add("$key is accepted in the baseline but no longer survives. Re-run with -UpdateBaseline so it cannot quietly come back.")
        }
    }
    return $faults.ToArray()
}

function Get-PSMutationUpdatedSurvivorBaseline {
    <#
    .SYNOPSIS
        The baseline this run would record: exactly the mutants that survived it.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results)
    # GENERATED, with no per-entry prose, and that is the difference from `equivalents`. An
    # equivalence is an argument a person makes and the gate checks; debt is a fact a run
    # observed. Demanding a sentence per entry would make the file impossible to generate and
    # would turn every accepted survivor into a claim nobody actually wrote.
    $map = [ordered]@{}
    foreach ($r in ($Results | Where-Object Status -eq 'Survived' |
                Sort-Object -Property @{ Expression = 'File' }, @{ Expression = 'Function' }, @{ Expression = 'Description' })) {
        $map[@(Get-PSMutationEquivalentKey -Result $r)[0]] = ''
    }
    return [pscustomobject]@{
        schemaVersion = 1
        survivors = [pscustomobject]$map
    }
}

function Get-PSMutationPerFileScore {
    <#
    .SYNOPSIS
        The same score, folded per source file instead of over the whole run.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        $Equivalents
    )
    # A blend hides the thing you most want to know. One strong file carries a weak one, and the
    # gate passes on an average nobody would accept per file -- observed on a consumer at ~89%
    # blended while individual files ranged from 39.6% to 100%.
    #
    # Grouping, not new arithmetic: Get-PSMutationScore is a fold over the rows it is handed and
    # says so, deliberately, because asking a whole-run question inside it would make the answer
    # wrong for any subset. Calling it per group is what that design was for.
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($Results | Group-Object -Property File)) {
        $s = Get-PSMutationScore -Results @($group.Group) -Equivalents $Equivalents
        $out.Add([pscustomobject]@{
                file = $group.Name
                score = $s.Score
                killed = $s.Killed
                survived = $s.Survived
                total = $s.Total
                timedOut = $s.TimedOut
                declaredEquivalent = $s.DeclaredEquivalent
            })
    }
    # WEAKEST FIRST, then by name. The point of the breakdown is the file that needs attention,
    # so it should not be somewhere in the middle of an alphabetical list; the name is the
    # tie-break so the order is deterministic and a diff of two reports is readable.
    return , @($out | Sort-Object -Property @{ Expression = 'score' }, @{ Expression = 'file' })
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
    param([Parameter(Mandatory)] $Summary, $Thresholds, [AllowEmptyCollection()] [string[]]$BaselineFault = @(),
        # True when a -ChangedFile run intersected `mutate` and found nothing in it.
        [bool]$EmptyScope = $false)
    # Filter before counting: @($null).Count is 1, not 0, so a summary that carries
    # no stale list at all would otherwise fail every run.
    # FIRST, because every rule below it is about a measurement, and this run made none. A pull
    # request that touched only documentation or tests changed no file in `mutate`, and an empty
    # run scores 0 -- so without this it fails a break threshold for having nothing to say.
    #
    # It is NOT the same as a run whose scoped files produced no mutants. There the files were in
    # `mutate` and the run has a real finding: changed code with nothing behind it. Only the case
    # where no changed file was mutable at all is a pass, and the empty -ChangedFile list that
    # signals a broken diff is refused long before this.
    if ($EmptyScope) { return 'None' }
    if (@($Summary.StaleEquivalents | Where-Object { $_ }).Count -gt 0) { return 'StaleEquivalents' }
    # BEFORE the threshold, deliberately. A baseline fault says this run disagrees with a list the
    # project committed to; a threshold says the blended number is under a configured one. Both can
    # be true at once, and the first is the more specific fact -- reporting 'BelowThreshold' for a
    # run that grew a new survivor sends the reader to argue about the number instead of reading
    # the mutant it grew.
    if (@($BaselineFault | Where-Object { $_ }).Count -gt 0) { return 'SurvivorBaseline' }
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
    param([Parameter(Mandatory)] $Summary, $Thresholds, [AllowEmptyCollection()] [string[]]$BaselineFault = @(),
        # True when a -ChangedFile run intersected `mutate` and found nothing in it.
        [bool]$EmptyScope = $false)
    if ((Get-PSMutationFailureReason -Summary $Summary -Thresholds $Thresholds -BaselineFault $BaselineFault `
                -EmptyScope $EmptyScope) -eq 'None') { return 0 }
    return 1
}

function Get-PSMutationCoverageExclusion {
    <#
    .SYNOPSIS
        What is NOT behind the score: what coverage removed, and what never existed.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile)
    # `declaredEquivalent` is already reported for exactly this reason -- a reader who cannot
    # see how many mutants were excluded cannot tell a real 100% from an excluded one. The
    # coverage filter removes far more than declarations do and said nothing at all.
    $skipped = 0
    foreach ($f in $PerFile) { $skipped += $f.Produced - $f.Kept }
    # FilesWithNoMutants is file-level and not just a count for the dangerous case: the file is
    # still listed in `mutate` and still hashed into the report, so nothing downstream can tell
    # it contributed nothing. A per-file score would read 0/0 and look fine.
    #
    # Shared with the -ListOnly preview rather than spelled again here. This predicate had three
    # copies at one point, which is two more than can be kept in step.
    return [pscustomobject]@{
        Skipped              = $skipped
        FilesWithNoMutants   = Get-PSMutationFileEmptiedByCoverage -PerFile $PerFile
        # The OTHER vacuous 100%, and it used to be reported by nobody. This field's sibling is
        # named for what coverage removed; a file no operator matched was removed by nothing and
        # so appeared in neither -- while the schema's description of the sibling claimed to
        # cover it. Two sets, because the fixes differ: one is a test to write, the other is a
        # file that does not belong in `mutate` or holds nothing this module can mutate.
        FilesWithNoCandidate = Get-PSMutationFileWithNoCandidate -PerFile $PerFile
    }
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
    if ($null -eq $Exclusion) { return '' }
    # Reported even when NOTHING was skipped, because it does not depend on the filter at all:
    # a file no operator matched contributes 0 of 0 whether or not coveredLinesOnly is set, and
    # a caveat that only prints alongside a coverage skip would stay silent on exactly the
    # config that filters nothing.
    if ($Exclusion.Skipped -eq 0) {
        return ($Exclusion.FilesWithNoCandidate.Count -gt 0) ? (Get-PSMutationNoCandidateNote -Exclusion $Exclusion) : ''
    }
    $line = "  $($Exclusion.Skipped) mutant(s) skipped as uncovered"
    if ($Exclusion.FilesWithNoMutants.Count -gt 0) {
        # Named, not counted. "2 files contributed none" sends the reader looking; the names
        # are what turn it into an action.
        $line += " ($($Exclusion.FilesWithNoMutants.Count) file(s) contributed none: $($Exclusion.FilesWithNoMutants -join ', '))"
    }
    if ($Exclusion.FilesWithNoCandidate.Count -gt 0) { $line += "`n" + (Get-PSMutationNoCandidateNote -Exclusion $Exclusion) }
    return $line
}

function Get-PSMutationNoCandidateNote {
    <#
    .SYNOPSIS
        The caveat naming the mutate files no operator matched, which score a vacuous 100%.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Exclusion)
    # Named, not counted, for the reason its sibling gives: a count sends the reader looking,
    # the names are what turn it into an action.
    return ("  {0} file(s) in mutate produced NO candidate, so each scores a vacuous 100%: {1}" -f `
            $Exclusion.FilesWithNoCandidate.Count, ($Exclusion.FilesWithNoCandidate -join ', '))
}

function Get-PSMutationFileWithNoCandidate {
    <#
    .SYNOPSIS
        The mutate files no operator matched at all, which score a vacuous 100%.
    .DESCRIPTION
        Deliberately NOT the same set as Get-PSMutationCoverageExclusion's FilesWithNoMutants,
        which is `produced but none kept` -- coverage removed them, and the fix is a test. This
        is `produced nothing`, and no test can change it: either the file holds nothing this
        module knows how to mutate, or it is the wrong file in `mutate`.

        Both look identical in a score -- the file is still listed, still hashed into the report,
        and contributes 0 of 0 -- which is why they are named apart rather than counted together.
    #>
    # BOTH types, and the second is the price of the comma-wrap: `, $x` is statically an
    # Object[] wrapper that PowerShell unrolls on return, so PSUseOutputTypeCorrectly
    # contradicts a bare [string[]]. Declaring only [object[]] would satisfy the analyzer
    # and stop documenting what a caller actually receives.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile)
    # COMMA-WRAPPED. A function returning an empty array unrolls it to $null, and both callers
    # publish this: the result object promises an array so a consumer can iterate it without
    # first telling "none" from "the module stopped reporting it". `.Count -eq 0` cannot catch
    # the difference -- $null.Count is 0 too -- which is why it shipped.
    $files = [string[]]@($PerFile | Where-Object { $_.Produced -eq 0 } | ForEach-Object { $_.File })
    return , $files
}

function Get-PSMutationFileEmptiedByCoverage {
    <#
    .SYNOPSIS
        The mutate files that produced candidates and kept none, because coverage removed them.
    .DESCRIPTION
        The sibling of Get-PSMutationFileWithNoCandidate and the other half of the vacuous 100%.
        Three callers -- the exclusion collector, the preview lines and the preview result -- and
        one answer between them. It WAS spelled out three times: copies drift, and a copy nothing
        asserts survives its own mutant.
    #>
    # BOTH types, and the second is the price of the comma-wrap: `, $x` is statically an
    # Object[] wrapper that PowerShell unrolls on return, so PSUseOutputTypeCorrectly
    # contradicts a bare [string[]]. Declaring only [object[]] would satisfy the analyzer
    # and stop documenting what a caller actually receives.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile)
    # COMMA-WRAPPED. A function returning an empty array unrolls it to $null, and both callers
    # publish this: the result object promises an array so a consumer can iterate it without
    # first telling "none" from "the module stopped reporting it". `.Count -eq 0` cannot catch
    # the difference -- $null.Count is 0 too -- which is why it shipped.
    $files = [string[]]@($PerFile | Where-Object { $_.Produced -gt 0 -and $_.Kept -eq 0 } | ForEach-Object { $_.File })
    return , $files
}

function Get-PSMutationMutantListRow {
    <#
    .SYNOPSIS
        One file's block in the preview: its own count, then a row per operator that matched it.
    .PARAMETER ShowCovered
        Whether to show the post-filter count. Decided ONCE by the caller: computed here it
        would be the same two-term condition evaluated on every row of every file, and the two
        terms mean different things -- "the config filters" and "we measured what it filters on".
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [bool]$ShowCovered
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    # The count leads, because the file name is the long part of the line and a reader scanning
    # for a zero should not have to read past it. A zero is a Warn so a renderer that has no
    # prose to read can still find it.
    $role = $Row.Kept -eq 0 ? 'Warn' : 'Detail'
    $tail = $ShowCovered ? (" -> {0} covered" -f $Row.Kept) : ''
    $lines.Add((New-PSMutationLine -Role $role -Text ("  {0,5} {1}{2}" -f $Row.Produced, $Row.File, $tail)))
    foreach ($op in $Row.ByOperator.Keys) {
        $opRow = $Row.ByOperator[$op]
        $opTail = $ShowCovered ? (" -> {0}" -f $opRow.Kept) : ''
        $lines.Add((New-PSMutationLine -Role 'Muted' -Text ("  {0,5}     {1}{2}" -f $opRow.Produced, $op, $opTail)))
    }
    return , $lines.ToArray()
}

function Get-PSMutationMutantListLine {
    <#
    .SYNOPSIS
        The -ListOnly rendering: what this config would mutate, per file and per operator.
    .DESCRIPTION
        A projection of the selection, exactly as the summary is a projection of the results --
        so a preview and a run cannot disagree about the set, because the set is the same object.

    .PARAMETER PerFile
        Select-PSMutationCandidate's per-file tally, with repo-relative paths: File, Produced,
        Kept, ByOperator.

    .PARAMETER CoveredLinesOnly
        Whether the config filters candidates to covered lines.

    .PARAMETER BaselineMeasured
        Whether coverage was actually measured for this preview. False means Kept is the
        unfiltered count and says so, rather than reading as a filtered one.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile,
        [Parameter(Mandatory)] [bool]$CoveredLinesOnly,
        [Parameter(Mandatory)] [bool]$BaselineMeasured
    )
    $showCovered = $CoveredLinesOnly -and $BaselineMeasured
    $lines = [System.Collections.Generic.List[object]]::new()
    $lines.Add((New-PSMutationLine -Role 'Banner' -Text "`nPSMutant - mutant set preview. No mutant is evaluated and no score is produced.`n"))
    foreach ($f in $PerFile) { $lines.AddRange((Get-PSMutationMutantListRow -Row $f -ShowCovered $showCovered)) }
    $lines.Add((New-PSMutationLine -Role 'Rule' -Text ''))
    $total = ($PerFile | Measure-Object -Property Kept -Sum).Sum
    $lines.Add((New-PSMutationLine -Role 'Detail' -Text ("  {0} mutant(s) over {1} file(s) would be evaluated." -f [int]$total, @($PerFile).Count)))
    # Said only when it is true, and it is the reason the number above may be the wrong one to
    # act on: a preview that skipped coverage is an UPPER bound on what a run would evaluate.
    if ($CoveredLinesOnly -and -not $BaselineMeasured) {
        $lines.Add((New-PSMutationLine -Role 'Muted' -Text '  coveredLinesOnly is set but coverage was not measured, so these are pre-filter counts.'))
    }
    # The same two sets a full run now discloses, from the same two functions. A preview that
    # computed them its own way would be a second answer to the question the mode exists for.
    $barren = Get-PSMutationFileWithNoCandidate -PerFile $PerFile
    if ($barren.Count -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Warn' -Text ("  {0} file(s) produced NO candidate, so each scores a vacuous 100%: {1}" -f `
                        $barren.Count, ($barren -join ', '))))
    }
    $emptied = Get-PSMutationFileEmptiedByCoverage -PerFile $PerFile
    if ($emptied.Count -gt 0) {
        $lines.Add((New-PSMutationLine -Role 'Warn' -Text ("  {0} file(s) had every candidate removed by the coverage filter, so the mapped suite reaches none of their lines: {1}" -f `
                        $emptied.Count, ($emptied -join ', '))))
    }
    return , $lines.ToArray()
}

function ConvertTo-PSMutationListResult {
    <#
    .SYNOPSIS
        The public shape of a -ListOnly preview: the same Mode/ExitCode/FailureReason as a run.
    .DESCRIPTION
        ExitCode is ALWAYS 0 and FailureReason always 'None'. A preview evaluates nothing, so it
        has no verdict to give and must not manufacture one -- the same reason a recheck applies
        no thresholds. What it reports instead is the two vacuous-100% sets, named, so a caller
        scripting over this can fail its own build on them.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile,
        [Parameter(Mandatory)] [bool]$BaselineMeasured
    )
    return [pscustomobject]@{
        Mode                   = 'List'
        Files                  = @($PerFile).Count
        Produced               = [int](($PerFile | Measure-Object -Property Produced -Sum).Sum)
        Total                  = [int](($PerFile | Measure-Object -Property Kept -Sum).Sum)
        # Always arrays, never $null, for the reason ConvertTo-PSMutationRunResult gives about
        # StaleEquivalents: a caller iterating this must not have to tell "none" from "the
        # module stopped reporting it".
        FilesWithNoCandidate   = Get-PSMutationFileWithNoCandidate -PerFile $PerFile
        FilesEmptiedByCoverage = Get-PSMutationFileEmptiedByCoverage -PerFile $PerFile
        # Whether Total is a filtered count or an upper bound. Carried rather than inferred,
        # because a caller cannot re-derive it from the numbers.
        BaselineMeasured       = $BaselineMeasured
        ExitCode               = 0
        FailureReason          = 'None'
    }
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

function ConvertTo-PSMutationList {
    <#
    .SYNOPSIS
        A value as a JSON array, with the phantom element `@($null)` produces removed.
    .DESCRIPTION
        `@($null)` is an array of ONE element whose value is $null -- not an empty array. So the
        idiomatic wrap that guarantees "this serialises as a JSON array" quietly manufactures an
        entry when handed nothing, and the report published `"filesWithoutTestMapping": [null]`
        on the DEFAULT path for two releases (#158). A consumer iterating the field to list the
        files that fell back to the whole suite got one entry that is not a file.

        The $null arrives by an ordinary route rather than a strange one: a PowerShell function
        returning an empty collection unrolls it to nothing, so
        `$x = Get-PSMutationUnmappedMutateFile ...` binds $null however carefully that function
        types its output.

        Used for every array the report writes, not only the field that was wrong. The sibling
        fields escaped by accident -- their sources happen to be initialised collections today --
        and an accident is not a property.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] $Value)
    # Only $null is dropped. An empty string is a value a caller may legitimately hold, and
    # silently discarding it would be a second, quieter version of this same bug.
    #
    # `return ,@(...)`, and the comma is load-bearing. Without it this function walks into the
    # very bug it exists to fix, one level up: returning an empty collection unrolls it to
    # nothing, the caller binds $null, and the field serialises as `null` -- which is not even
    # the array the schema now requires. Written first without the comma, and the report came
    # back with `"filesWithoutTestMapping": null`. The unary comma wraps the result so the
    # pipeline's one level of unrolling yields the array itself.
    return , @($Value | Where-Object { $null -ne $_ })
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
        [AllowEmptyCollection()] [string[]]$UnmappedFiles = @(),
        # The files the config asked to mutate, reported as a COUNT beside the score. A score
        # has no denominator otherwise: 100% over eight files and 100% over nine are the same
        # number, and only one of them covers the ninth.
        #
        # This is the list the CALLER supplied, never a directory listing. Nothing in this
        # module walks a source tree, so a run cannot know about a file the config never
        # named -- and reporting a fraction like "8 of 9" would require exactly that
        # knowledge. What a report can honestly say is how many files it was pointed at.
        [AllowEmptyCollection()] [string[]]$MutateFiles = @(),
        # Whether each row's KilledBy names every killing test, or a truncated set. Stated at run
        # level rather than inferred from a row: the truncated form is not reliably one name --
        # measured, 20 of 118 killed mutants still carried several -- so a row's length says
        # nothing about how many tests really kill it.
        [bool]$KillersComplete = $false,
        # The mapped test files, so the report can name the ones that killed nothing. Only
        # meaningful alongside a complete killer list, which is why the schema forbids the
        # derived list without it.
        [AllowEmptyCollection()] [string[]]$MappedTests = @(),
        # What each mapped test file looked like when this report was written, so a later merge
        # can tell an added test from a deleted one. Length rather than a hash: see
        # Get-PSMutationMergeFault for why "unchanged" is the wrong question.
        [hashtable]$TestFileLength = @{},
        # The files a -ChangedFile run was scoped to, or $null for a whole-tree run. NULL rather
        # than an empty array, and the schema keeps the union: absent and empty are different
        # answers, and only null may be read as a measurement of everything in `mutate`. The
        # sibling module's report carries the same distinction in the same shape.
        [string[]]$ChangedFiles = $null,
        # The subset of `mutate` this run covered, as the config spells them; $null on a
        # whole-tree run. Read only to scope equivalence declarations.
        [string[]]$InScopeFile = $null
    )
    # The only place holding EVERY row, so the only place that can ask whether a
    # declaration matched nothing. The per-set fold no longer answers it.
    $summary = Get-PSMutationScore -Results $Results -Equivalents $Equivalents
    # Concatenated unconditionally: guarding on a non-empty $coverage adds a branch whose
    # false arm is indistinguishable from its true arm, since appending nothing changes
    # nothing. Both of that guard's mutants survived.
    $coverage = Get-PSMutationDeclarationCoverageFault -Results $Results -Equivalents $Equivalents `
        -InScopeFile $InScopeFile
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
        # Beside skippedAsUncovered and declaredEquivalent, for the same reason: a number
        # cannot be read without knowing what it was computed over.
        filesMutated = @($MutateFiles | Where-Object { $_ }).Count
        # The disclosure that makes every KilledBy list readable. Always written, so a consumer
        # never has to guess which shape it is holding.
        killersComplete = $KillersComplete
        # Recorded for -MergeIntoBaseline, which carries over the status of every mutant a recheck
        # did not evaluate. Those statuses are only as good as the tests that produced them, and
        # nothing else in this document says anything about the tests.
        testFiles = [pscustomobject]$TestFileLength
        # Beside the blended score, not instead of it. The blend is what the thresholds gate on;
        # this is what says whether the blend is hiding anything.
        # ASSIGNED, not wrapped in @( ). The function returns `, @(...)` so an empty run yields an
        # empty array rather than $null -- and wrapping that in @( ) gives a one-element array
        # holding the array, which serialises as [[...]]. Measured: @($r).Count is 1 for a
        # two-file run, and $r.Count is 2.
        perFile = Get-PSMutationPerFileScore -Results $Results -Equivalents $Equivalents
        skippedAsUncovered = [int]$Exclusion.Skipped
        filesWithNoMutants = ConvertTo-PSMutationList -Value $Exclusion.FilesWithNoMutants
        filesWithNoCandidate = ConvertTo-PSMutationList -Value $Exclusion.FilesWithNoCandidate
        # Recorded beside the other disclosures: a run that took twice as long for a reason
        # nobody chose should say so somewhere a CI job can read afterwards.
        filesWithoutTestMapping = ConvertTo-PSMutationList -Value $UnmappedFiles
        staleEquivalents = ConvertTo-PSMutationList -Value $summary.StaleEquivalents
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
    # ADDED ONLY WHEN THE KILLER LISTS ARE COMPLETE, and the schema refuses it otherwise. Under
    # the default early stop a test that would have killed but was skipped is indistinguishable
    # from one that cannot kill at all, so this list would name working tests as dead weight --
    # and what a reader does with it is delete them. Absent is the honest answer there.
    if ($KillersComplete) {
        $killers = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($Results | ForEach-Object { $_.KilledBy } | Where-Object { $_ }))
        # Compared on the mapped list rather than on the killers, so a test that ran and killed
        # nothing is named and one that was never mapped is not: the second is a config question,
        # not a test-quality one.
        $document | Add-Member -NotePropertyName testsWithoutKills -NotePropertyValue (
            ConvertTo-PSMutationList -Value @($MappedTests | Where-Object { -not $killers.Contains($_) }))
    }
    # ADDED ONLY ON A SCOPED RUN, the same way. Written unconditionally they would put
    # "mode": null on every full report, which the schema's enum refuses -- absent is how a full
    # run says it measured everything, and null is not a third answer.
    #
    # The two go on TOGETHER: the schema requires changedFiles whenever mode is Changed, because
    # a percentage over part of a tree that does not say which part is exactly the number this
    # module exists to stop people quoting.
    if ($ChangedFiles) {
        $document | Add-Member -NotePropertyName mode -NotePropertyValue 'Changed'
        $document | Add-Member -NotePropertyName changedFiles -NotePropertyValue (
            ConvertTo-PSMutationList -Value $ChangedFiles)
    }
    Save-PSMutationReportDocument -Document $document -ReportPath $ReportPath
    return $summary
}

function Write-PSMutationPartialReport {
    <#
    .SYNOPSIS
        Write what an INTERRUPTED run got through, marked so it cannot be read as a measurement.
    .DESCRIPTION
        A run accumulated its rows in memory and wrote the report only after the last mutant, so
        Ctrl-C, a CI cancellation or a killed agent discarded the whole run. On a large repo a run
        is long enough that this is an ordinary event, not an exceptional one -- and a cancelled
        job then produces nothing at all, not even a partial picture.

        The shape follows the recheck report rather than the full one, because it makes the same
        promise: counts, never a score. `evaluated` of `planned` is PROGRESS. A ratio over the
        mutants that happened to run first is not a measurement of anything -- the loop evaluates
        in candidate order, so an interrupted run has seen whichever files sort earliest, and
        quoting that as a percentage would be precisely the confident-number-over-a-subset failure
        this module exists to prevent. The schema enforces it: `mutationScore` is forbidden here.
    .OUTPUTS
        The path written, so the caller can name it in the message it is already about to print.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [int]$Planned,
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        [Parameter(Mandatory)] [hashtable]$SourceHashes,
        [hashtable]$Provenance = @{}
    )
    $document = [pscustomobject]@{
        generatedFrom = 'PSMutant'
        # The same provenance block as both other shapes, so a consumer reads it one way from
        # any report rather than learning a third convention.
        schemaVersion = $Provenance.schemaVersion
        producedBy    = $Provenance.producedBy
        generatedAt   = $Provenance.generatedAt
        durations     = $Provenance.durations
        mode          = 'Partial'
        note          = 'Interrupted before every mutant was evaluated. Not a mutation score: the mutants below are whichever ran first, not a sample of anything, so no percentage over them means what a score means. Re-run to completion for a number.'
        evaluated     = $Results.Count
        planned       = $Planned
        # Present for the same reason the recheck report carries it: this is the list any
        # follow-up reads, and a report that names it anything else cannot seed one.
        survivors     = @($Results | Where-Object Status -eq 'Survived')
        # Carried so a later run can prove this partial was numbered against the same source.
        sourceHashes  = $SourceHashes
        operators     = @($Operators | Sort-Object)
        mutants       = $Results
    }
    Save-PSMutationReportDocument -Document $document -ReportPath $ReportPath
    return $ReportPath
}

function Get-PSMutationDeclarationFile {
    # The file an equivalence declaration is about, from its key. Pure.
    #
    # Keys are `file:function:description` or `file:line:description`, written in the config in
    # the same spelling as `mutate`, so the file is everything before the first colon.
    #
    # Only used to decide whether a declaration is IN SCOPE for a run, which is why a key it
    # cannot parse yields the whole string: that then matches no scoped file and is left to the
    # ordinary staleness check, rather than being silently excused by a parse failure.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Key)
    $i = $Key.IndexOf(':')
    return $i -lt 0 ? $Key : $Key.Substring(0, $i)
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
        $Equivalents,
        # The files this run actually mutated, as the config spells them, or $null for a run over
        # everything in `mutate`.
        [string[]]$InScopeFile = $null
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
    # THE SAME HAZARD THE COMMENT ABOVE DESCRIBES, one level up. A -ChangedFile run narrowed to
    # two files would report every declaration about the other seven as "no such mutant exists"
    # and fail the gate, for declarations that are correct and were simply never examined. That
    # is the false stale-equivalence accusation this function exists to avoid, and it would make
    # a per-PR gate unusable by any repository that declares an equivalent.
    #
    # $null, not an empty list: a whole-tree run judges every declaration, and an empty scope is
    # refused before a run starts. The two are different answers.
    $scope = $null -eq $InScopeFile ? $null :
        [System.Collections.Generic.HashSet[string]]::new([string[]]@($InScopeFile),
            [System.StringComparer]::OrdinalIgnoreCase)
    $faults = foreach ($k in $declared.Keys) {
        if ($scope -and -not $scope.Contains((Get-PSMutationDeclarationFile -Key $k))) { continue }
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

function Get-PSMutationWeakFileLine {
    <#
    .SYNOPSIS
        The console lines for files scoring below the good band, if any.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PerFile,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    # ONE file mutated means the blend IS that file, so a breakdown would restate the score under
    # a heading that implies it found something.
    if (@($PerFile).Count -lt 2) { return , $lines.ToArray() }
    $weak = @($PerFile | Where-Object { $_.score -lt $High })
    if ($weak.Count -eq 0) { return , $lines.ToArray() }
    $lines.Add((New-PSMutationLine -Role 'Muted' `
                -Text ("  {0} of {1} file(s) score below {2}%:" -f $weak.Count, @($PerFile).Count, $High)))
    foreach ($f in $weak) {
        # Coloured by the same bands as the headline, so a file in the red reads as red even when
        # the blend it sits inside is green -- which is the whole point of showing it.
        $lines.Add((New-PSMutationLine -Role (Get-PSMutationScoreRole -Score $f.score -High $High -Low $Low) `
                    -Text ("    {0,6}%  {1}  ({2} killed / {3})" -f $f.score, $f.file, $f.killed, $f.total)))
    }
    return , $lines.ToArray()
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
        $Exclusion,
        [AllowEmptyCollection()] [object[]]$PerFile = @()
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
    # The files the blend is hiding. Only those BELOW the good band, and only when more than one
    # file was mutated: a blended score is an average, so a strong file carries a weak one and the
    # gate passes on a number nobody would accept per file. Listing every file instead would put
    # the one that needs attention somewhere in a wall of 100%s.
    # ASSIGNED first, not wrapped in @( ). The callee returns `, $array` so an empty result stays
    # an empty array rather than $null; wrapping THAT in @( ) yields a one-element array holding
    # the array, and AddRange then adds the array itself as a line. The same trap the perFile
    # field hit one function away, in the opposite direction.
    # No emptiness guard: AddRange over an empty collection is already a no-op, so an `if` here
    # would be a branch whose two arms do the same thing -- self-mutation reported all three of
    # its mutants as survivors before it was removed.
    $weakLines = Get-PSMutationWeakFileLine -PerFile $PerFile -High $High -Low $Low
    $lines.AddRange([object[]]$weakLines)
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
        [Parameter(Mandatory)] [string]$FailureReason,
        [string[]]$ChangedFiles = $null
    )
    return [pscustomobject]@{
        # 'Changed' when the run was scoped, so a caller that did not choose the mode can still
        # tell a project number from one over part of the tree. The report says the same thing in
        # its own `mode`, and the two are derived from the one value.
        Mode               = $ChangedFiles ? 'Changed' : 'Full'
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
        # $null on a whole-tree run, never @(). Absent and empty are different answers, and only
        # absent may be read as a measurement of everything in `mutate`.
        ChangedFiles       = $ChangedFiles
    }
}
