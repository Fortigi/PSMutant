# The SARIF log: surviving mutants, in the format code-scanning services read.
#
# A second published format beside the report, and a projection of the same result rows rather
# than a second measurement. The report answers "what did this run do"; the SARIF log answers the
# narrower question a reviewer has on a pull request -- where is a fault my tests would not
# notice -- in the shape GitHub code scanning and Azure DevOps Advanced Security render as alerts.
#
# Pure except for Save-PSMutationSarifDocument, which is the one function that touches a file.

# What each operator does, in the words a reviewer reading an alert needs. One entry per operator
# the module knows, and tests/Sarif.Tests.ps1 closes the list against Get-PSMutationKnownOperator
# in both directions, so a new operator without a sentence here fails a test rather than shipping
# a rule whose help is empty.
$script:PSMutationOperatorSummary = @{
    BinaryOperator      = 'flips a comparison, logical or arithmetic operator: -eq to -ne, -gt to -le, -and to -or, + to -.'
    BooleanLiteral      = 'swaps $true for $false and back.'
    NumberLiteral       = 'changes a number N to N+1.'
    NegationRemoval     = 'drops a -not or a !.'
    StringLiteral       = "replaces a quoted string with ''."
    ConditionalBoundary = 'shifts a boundary: -gt to -ge, -lt to -le, and back.'
    ConditionForcing    = 'forces an if, elseif, switch or ternary condition to always true, or always false.'
    ReturnValue         = 'replaces return <expr> with return $null.'
}

function Get-PSMutationSarifRuleId {
    # The rule a mutant is reported under: one per operator, so a team that has decided one
    # operator's survivors are not worth an alert can suppress that rule without the others.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Operator)
    return "PSMutant/$Operator"
}

function Get-PSMutationSarifRule {
    # One SARIF rule per operator THIS RUN applied, in the run's order.
    #
    # Not every known operator: a rule for an operator that was never applied describes a check
    # nobody ran. The order is the run's own, which is sorted, so ruleIndex is stable across
    # two runs with the same operator set.
    #
    # `help` repeats `fullDescription` on purpose. The SARIF validator's GitHub Advanced Security
    # rules (GH2012) require it, and it is the text an alert page shows as guidance.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators)
    # @( ) around the loop, not around the variable afterwards: a loop that runs zero times
    # assigns $null, and @($null) is an array of ONE element -- the phantom entry the report
    # published as `[null]` in #158.
    $rules = @(foreach ($op in $Operators) {
        $text = ("A mutant made by the {0} operator survived. The operator {1} No test failed when the code was " +
            'changed this way, so a bug of this shape would not be caught either. Add or tighten a test that ' +
            'notices it -- or, if the change cannot alter behaviour, declare it under `equivalents` in the config ' +
            'with the reason.') -f $op, $script:PSMutationOperatorSummary[$op]
        [ordered]@{
            id               = Get-PSMutationSarifRuleId -Operator $op
            name             = $op
            shortDescription = [ordered]@{ text = "A $op mutant survived: no test noticed the change." }
            fullDescription  = [ordered]@{ text = $text }
            help             = [ordered]@{ text = $text }
            helpUri          = 'https://github.com/Fortigi/PSMutant#operators'
        }
    })
    return , $rules
}

function Get-PSMutationSarifFingerprint {
    <#
    .SYNOPSIS
        A stable identity for each surviving mutant, in the order given.
    .DESCRIPTION
        NOT the mutant id: ids are AST-walk positions and renumber whenever an earlier mutant is
        added or removed, so a fingerprint built on one would close and reopen every alert below
        an unrelated edit.

        The stablest address an equivalence declaration accepts -- `File:Function:Description` --
        so an alert and the declaration that would retire it name the mutant the same way.

        That address is not unique: two `-eq -> -ne` mutants in one function share it. Two results
        with one fingerprint are one alert to a code-scanning service, so the second would vanish.
        An ordinal goes on EVERY member of such a group (`#1`, `#2`), never only the later ones:
        suffixing just the second would silently re-key the first the day a twin is added.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results)
    $keys = @(foreach ($r in $Results) { (Get-PSMutationEquivalentKey -Result $r)[0] })
    $counts = @{}
    foreach ($k in $keys) { $counts[$k] = 1 + [int]$counts[$k] }
    $seen = @{}
    $out = @(foreach ($k in $keys) {
        $seen[$k] = 1 + [int]$seen[$k]
        $counts[$k] -gt 1 ? "$k#$($seen[$k])" : $k
    })
    return [string[]]$out
}

function Get-PSMutationSarifResult {
    <#
    .SYNOPSIS
        The SARIF results for a run: one per surviving mutant that is not declared equivalent.
    .DESCRIPTION
        A KILLED mutant is not a finding. A declared equivalent that survived is not one either:
        the config argued it cannot change behaviour, and an alert would ask a reviewer to act on
        something already argued. The argument is not lost -- the report carries it.

        `warning`, not `error`. A survivor is a gap in the tests rather than a defect in the code,
        and the same finding is already a warning on the console and in a CI annotation; one
        fact should not carry two severities.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        $Equivalents
    )
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    $survivors = @(foreach ($r in $Results) {
            if ($r.Status -ne 'Survived') { continue }
            if ($null -ne (Get-PSMutationDeclaredKey -Result $r -Declared $declared)) { continue }
            $r
        })
    # @( ): a function returning a ONE-element [string[]] unrolls it to a bare string, and
    # indexing a string yields its first character -- so a run with a single survivor published
    # the fingerprint 's'. Found by the suite, not by reading.
    $fingerprints = @(Get-PSMutationSarifFingerprint -Results $survivors)
    $results = @(for ($i = 0; $i -lt $survivors.Count; $i++) {
        $r = $survivors[$i]
        $where = [string]::IsNullOrEmpty([string]$r.Function) ? '' : " in $($r.Function)"
        [ordered]@{
            ruleId              = Get-PSMutationSarifRuleId -Operator $r.Operator
            ruleIndex           = [array]::IndexOf($Operators, [string]$r.Operator)
            level               = 'warning'
            message             = [ordered]@{ text = "Mutant survived$($where): $($r.Description). No test failed when the code was changed this way." }
            locations           = @(
                [ordered]@{
                    physicalLocation = [ordered]@{
                        # Repo-relative with forward slashes already -- the row's File is the path
                        # the report publishes, and it is what a code-scanning service matches
                        # against the checkout.
                        artifactLocation = [ordered]@{ uri = [string]$r.File }
                        region           = [ordered]@{ startLine = [int]$r.Line }
                    }
                }
            )
            partialFingerprints = [ordered]@{ psMutantMutant = $fingerprints[$i] }
        }
    })
    return , $results
}

function Get-PSMutationSarifDocument {
    <#
    .SYNOPSIS
        A SARIF 2.1.0 log for one completed run.
    .DESCRIPTION
        Written only by a run that finished and scored. A -RecheckFrom run evaluates the previous
        survivors alone and an interrupted one stopped part-way; uploaded, either would close every
        alert it did not re-examine, because a code-scanning service reads a missing result as a
        fixed one. That is the same reason a partial REPORT carries no score.

        No `automationDetails`, deliberately. Azure DevOps's validator rules ask for one
        (GHAzDO1014), but its id IS the category, and on GitHub an id in the file takes precedence
        over the upload step's `category` input -- so a fixed id here would make two PSMutant
        uploads in one repository overwrite each other whatever the pipeline said. The pipeline
        names it: `category:` on upload-sarif, `Category:` on AdvancedSecurity-Publish.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        $Equivalents,
        [Parameter(Mandatory)] $Summary,
        [AllowEmptyString()] [string]$ModuleVersion
    )
    # A version is never empty in the file. Dot-sourced, as the suite and a sandboxed run load
    # this, no module is loaded to ask -- and `fullName` is required by Azure DevOps (GHAzDO1018).
    $version = [string]::IsNullOrEmpty($ModuleVersion) ? 'unknown' : $ModuleVersion
    return [ordered]@{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool       = [ordered]@{
                    driver = [ordered]@{
                        name           = 'PSMutant'
                        fullName       = "PSMutant $version"
                        version        = $version
                        informationUri = 'https://github.com/Fortigi/PSMutant'
                        rules          = Get-PSMutationSarifRule -Operators $Operators
                    }
                }
                # The verdict beside the findings, so a reader of the log alone can tell a run with
                # three survivors out of 400 from three out of five.
                properties = [ordered]@{
                    mutationScore = $Summary.Score
                    killed        = $Summary.Killed
                    survived      = $Summary.Survived
                    total         = $Summary.Total
                }
                results    = Get-PSMutationSarifResult -Results $Results -Operators $Operators -Equivalents $Equivalents
            }
        )
    }
}

function Save-PSMutationSarifDocument {
    <#
    .SYNOPSIS
        Write a SARIF document to disk, failing the run when it cannot be written.
    .DESCRIPTION
        The same two guards the report writer has, for the same reasons: .NET creates the
        directory because New-Item reads a bracket as a wildcard, and -LiteralPath with
        -ErrorAction Stop so an unwritable path stops the run instead of printing a path nothing
        was written to.

        -Depth 10, where the report needs 6. A SARIF result nests nine levels down -- root, runs,
        run, results, result, locations, location, physicalLocation, artifactLocation -- and
        ConvertTo-Json truncates past its depth SILENTLY, writing the .NET type name where a value
        belongs. The sibling module shipped exactly that once: every location read
        `System.Collections.Specialized.OrderedDictionary`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Document,
        [Parameter(Mandatory)] [string]$Path
    )
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $Document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -ErrorAction Stop
}

function Export-PSMutationSarif {
    <#
    .SYNOPSIS
        Write the SARIF log when the config asked for one, and return the line that says so.
    .DESCRIPTION
        The decision to write lives HERE rather than as an `if` in the orchestrator, which is
        wiring and sits close to the complexity ceiling. An empty -Path is the config saying
        "no SARIF", and returns no line.

        Returns a line rather than printing it, like every other producer: the one Write-Host is
        in PSMutation.Output.ps1, and the caller decides whether -Quiet applies.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Operators,
        $Equivalents,
        [Parameter(Mandatory)] $Summary,
        [AllowEmptyString()] [string]$ModuleVersion
    )
    if ([string]::IsNullOrEmpty($Path)) { return }
    $doc = Get-PSMutationSarifDocument -Results $Results -Operators $Operators -Equivalents $Equivalents `
        -Summary $Summary -ModuleVersion $ModuleVersion
    Save-PSMutationSarifDocument -Document $doc -Path $Path
    return New-PSMutationLine -Role 'Muted' -Text ("  SARIF: {0} ({1} finding(s))" -f $Path, @($doc.runs[0].results).Count)
}
