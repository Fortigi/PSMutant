<#
.SYNOPSIS
    Scoring, JSON report, console summary, and the public run-result shape for the
    PowerShell mutation runner. Everything a consumer's CI reads is decided here.
    Split from the execution engine so each unit stays small and independently testable.
#>

function Get-PSMutationEquivalentKey {
    # Every string a config may use to declare THIS mutant equivalent, stablest first.
    #
    # Not the mutant id: ids are AST-walk positions and renumber whenever an earlier mutant
    # is added or removed. Not the line number alone either, which was the original scheme
    # and the defect: editing anything ABOVE a declared mutant -- a comment, an import,
    # another function entirely -- moved the line and the declaration went stale although
    # the mutant was untouched. That happened on the first run after the feature shipped,
    # and twice more while fixing #28 (#3).
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
    # and its caller iterates it, so wrapping would hand the foreach one item that IS the
    # array -- which is exactly what it did on the first attempt (see #38).
    # Cast on the EXPRESSION, @() inside it: casting the variable leaves the analyzer
    # inferring the branch types (string here, object[] there) against the declared
    # [string[]], and dropping the @() turns a single key into a scalar the cast cannot
    # widen. Same shape as Get-PSMutationCandidate, same reason (#76).
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
    #            cannot notice because the key still matches something (#28)
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
    # quiet because the key still matches something (#28). A declaration is a claim
    # about ONE mutant, so matching several is not a smaller claim, it is an
    # ambiguous one, and the run says so rather than banking the exclusion.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        $Equivalents
    )
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    $stale    = [System.Collections.Generic.List[string]]::new()
    # A count, not a set: "matched something" and "matched exactly one" are different
    # claims, and only the second is the one a declaration makes.
    $matched  = @{}

    $killed = 0; $survived = 0; $excluded = 0
    foreach ($r in $Results) {
        $key = Get-PSMutationDeclaredKey -Result $r -Declared $declared
        $isDeclared = $null -ne $key
        if ($isDeclared) { $matched[$key] = 1 + [int]$matched[$key] }
        if ($r.Status -eq 'Killed') {
            $killed++
            if ($isDeclared) { $stale.Add("$key -- declared equivalent but the suite killed it") }
        }
        elseif ($isDeclared) { $excluded++ }
        else { $survived++ }
    }
    foreach ($k in $declared.Keys) {
        $fault = Get-PSMutationDeclarationFault -Key $k -Hits ([int]$matched[$k])
        if ($fault) { $stale.Add($fault) }
    }

    $total = $Results.Count - $excluded
    $score = if ($total -gt 0) { [math]::Round(100.0 * $killed / $total, 1) } else { 0 }
    return [pscustomobject]@{
        Score = $score; Killed = $killed; Survived = $survived; Total = $total
        DeclaredEquivalent = $excluded; StaleEquivalents = $stale.ToArray()
    }
}

function Get-PSMutationExitCode {
    # Report-only unless thresholds.break is set and the score is below it. Pure.
    #
    # A stale equivalence declaration fails the run REGARDLESS of thresholds, and
    # regardless of report-only mode: it is not a quality shortfall to be graded on
    # a curve, it is a false statement in the config that is inflating the score.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, $Thresholds)
    # Filter before counting: @($null).Count is 1, not 0, so a summary that carries
    # no stale list at all would otherwise fail every run.
    if (@($Summary.StaleEquivalents | Where-Object { $_ }).Count -gt 0) { return 1 }
    if ($null -ne $Thresholds.break -and $Summary.Score -lt $Thresholds.break) { return 1 }
    return 0
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
        $Equivalents
    )
    $summary = Get-PSMutationScore -Results $Results -Equivalents $Equivalents
    New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force | Out-Null
    [pscustomobject]@{
        generatedFrom = 'PSMutant'
        mutationScore = $summary.Score
        total = $summary.Total; killed = $summary.Killed; survived = $summary.Survived
        # Reported so the headline score can always be reconciled against the raw
        # mutant count: total EXCLUDES declared equivalents, and a reader who cannot
        # see how many were excluded cannot tell a real 100% from a declared one.
        declaredEquivalent = $summary.DeclaredEquivalent
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
    } | ConvertTo-Json -Depth 6 | Set-Content $ReportPath
    return $summary
}

function Get-PSMutationScoreColour {
    # Green at or above High, yellow at or above Low, red below it.
    #
    # A pure three-way decision taking resolved numbers, so the null that used to make every
    # score green cannot reach it -- see Get-PSMutationScoreBand for what that looked like.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Score,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low
    )
    if ($Score -ge $High) { return 'Green' }
    if ($Score -ge $Low) { return 'Yellow' }
    return 'Red'
}

function Show-PSMutationSummary {
    # Human-readable summary + the list of survivors to go add assertions for.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low,
        [string]$ReportPath,
        $Equivalents
    )
    # Resolved numbers in, not the raw config: this used to take $Thresholds and compare
    # against $Thresholds.high directly, which is null for most configs (#40).
    $col = Get-PSMutationScoreColour -Score $Summary.Score -High $High -Low $Low
    Write-Host "`n----------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Mutation score: {0}%  ({1} killed / {2})" -f $Summary.Score, $Summary.Killed, $Summary.Total) -ForegroundColor $col
    # Printed next to the score, not buried in the report: a 100% built on a dozen
    # declared equivalents is a different claim from a 100% that killed everything.
    if ($Summary.DeclaredEquivalent -gt 0) {
        Write-Host ("  {0} mutant(s) excluded as declared-equivalent (see config)" -f $Summary.DeclaredEquivalent) -ForegroundColor DarkGray
    }
    $stale = @($Summary.StaleEquivalents | Where-Object { $_ })   # @($null).Count is 1
    if ($stale.Count -gt 0) {
        Write-Host "  INVALID equivalence declarations - the config is claiming something untrue:" -ForegroundColor Red
        $stale | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    # A declared equivalent is not a survivor to go and fix: listing it here sends
    # the reader after a mutant the config already argued is unkillable, which is
    # how a good declaration gets "fixed" with a meaningless test.
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    $open = @($Results | Where-Object { $_.Status -eq 'Survived' -and -not (Get-PSMutationDeclaredKey -Result $_ -Declared $declared) })
    if ($open.Count -gt 0) {
        Write-Host "  Survivors (add assertions to kill these):" -ForegroundColor Yellow
        $open | ForEach-Object {
            Write-Host ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Description) -ForegroundColor Yellow
        }
    }
    Write-Host "  Report: $ReportPath" -ForegroundColor Gray
}

function ConvertTo-PSMutationRunResult {
    # The public shape of a completed run: what a consumer's CI reads off Invoke-PSMutation.
    #
    # Here rather than in Config.ps1, where it used to sit: it is derived entirely from a
    # summary this file produces, and this file already owns the other contract CI depends
    # on -- the report JSON. Two halves of one promise, in one place (#45).
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, [Parameter(Mandatory)] [int]$ExitCode)
    return [pscustomobject]@{
        Score    = $Summary.Score
        Killed   = $Summary.Killed
        Survived = $Summary.Survived
        Total    = $Summary.Total
        ExitCode = $ExitCode
    }
}
