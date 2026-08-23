<#
.SYNOPSIS
    Pure AST-based mutation operators for the PowerShell mutation runner.

.DESCRIPTION
    PowerShell has no mainstream mutation-testing tool (StrykerJS is JS-only), so we
    roll our own on the language's own parser. Everything here is PURE -- text in,
    candidate list out, no writes -- which makes it the unit-tested core of the runner
    (see tests/Operators.Tests.ps1).

    Each operator class is its OWN small function (Get-PSMutation*Candidate) so every
    unit stays well under the cognitive/cyclomatic complexity ceiling (15); the public
    Get-PSMutationCandidate just parses once and unions the enabled operators.

    A "candidate" is one injectable fault located by absolute character offset:
      Id, File, Line, StartOffset, EndOffset, Original, Mutated, Operator, Description
    Applying it is a pure splice (Set-PSMutationText). Candidates inside a loop
    *condition* are dropped so a flipped comparison can never spin an infinite loop --
    which is what lets the runner execute mutants in-process.
#>

$script:PSMutationBinaryMap = @{
    '-eq' = '-ne'; '-ne' = '-eq'; '-gt' = '-le'; '-le' = '-gt'
    '-lt' = '-ge'; '-ge' = '-lt'; '-and' = '-or'; '-or' = '-and'
    '+' = '-'; '-' = '+'; '*' = '/'; '/' = '*'
}
# Off-by-one at a boundary, which the negation swaps above cannot produce: -gt maps to
# -le there, so `-gt` vs `-ge` -- the classic fencepost -- is never tried.
$script:PSMutationBoundaryMap = @{ '-gt' = '-ge'; '-ge' = '-gt'; '-lt' = '-le'; '-le' = '-lt' }

# StringLiteral, ConditionalBoundary, ConditionForcing and ReturnValue are all OPT-IN.
# Adding one here roughly doubles a consumer's mutant count and lowers their score, so a
# repo gating on thresholds.break would go red purely from upgrading the module.
$script:PSMutationDefaultOperators = @('BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'NegationRemoval')

function Get-PSMutationKnownOperator {
    # Every operator name this module understands, sorted. A function rather than a bare
    # constant so the config validator can offer the alternatives without reading another
    # file's $script: state.
    [OutputType([string[]])]
    [CmdletBinding()]
    param()
    return [string[]]@($script:PSMutationOperatorMap.Keys | Sort-Object)
}

function Get-PSMutationOperatorList {
    # Which mutation operators to apply; unset means the default set above.
    #
    # The truthiness test is deliberate: an EMPTY operators list falls back to the
    # defaults rather than selecting none. Arguably an explicit [] should mean "none",
    # but that is a behaviour change rather than a resolver detail.
    [OutputType([string[]])]
    [CmdletBinding()]
    param($Cfg)
    if ($Cfg.operators) { return [string[]]@($Cfg.operators) }
    return [string[]]$script:PSMutationDefaultOperators
}

function Set-PSMutationText {
    # Produce the mutated source for a single candidate -- a pure offset splice.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function: returns transformed text, changes no system state.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Content,
        [Parameter(Mandatory)] $Candidate
    )
    return $Content.Substring(0, $Candidate.StartOffset) + $Candidate.Mutated + $Content.Substring($Candidate.EndOffset)
}

# How much of "<original> -> <mutated>" a description keeps. Chosen by measurement, not
# taste: over this repo's own source with every operator enabled, truncating at 120 produces
# exactly as many distinct descriptions as not truncating at all, while 80 loses a few and 60
# loses noticeably more. Long enough to discriminate, short enough to paste into a config.
$script:PSMutationDescriptionLength = 120

function New-PSMutationCandidate {
    # Build one candidate object. Central so every operator emits the same shape.
    #
    # The description is DERIVED here rather than passed in, so no operator can supply one
    # that fails to say what was mutated -- 'remove negation', 'return value -> $null',
    # "string -> ''". A description like those makes every such mutant on a line produce an
    # identical `File:Line:Description` equivalence key, so one honest declaration excludes
    # all of them silently while stale-detection stays quiet, the key still matching
    # something. Deriving centrally makes that impossible for a NEW operator too; taking it
    # as a parameter would leave it to whoever writes the call.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns an object, changes no system state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param($Extent, [string]$File, [string]$Original, [string]$Mutated, [string]$Operator)
    # Collapsed to single spaces because an extent can span lines -- a raw multi-line
    # condition would put newlines in a console line and in a config key.
    $description = "$Original -> $Mutated" -replace '\s+', ' '
    if ($description.Length -gt $script:PSMutationDescriptionLength) {
        $description = $description.Substring(0, $script:PSMutationDescriptionLength) + '...'
    }
    return [pscustomobject]@{
        # Id and Function are both filled in by Get-PSMutationCandidate, which is the only
        # place that has the whole file's context. The sentinels are deliberate: 0 is
        # outside the real id range, and '' means "file scope", which is a real answer.
        Id = 0; Function = ''; File = $File; Line = $Extent.StartLineNumber
        StartOffset = $Extent.StartOffset; EndOffset = $Extent.EndOffset
        Original = $Original; Mutated = $Mutated; Operator = $Operator; Description = $description
    }
}

function Get-PSMutationLoopRange {
    # Offset ranges of every loop CONDITION (while/do/for) -- the no-mutate zones.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $loops = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.LoopStatementAst] }, $true)
    # Comma operator so an empty result stays an [array] through the return (a bare
    # `@()` would unroll to $null and break the mandatory -Ranges binding downstream).
    return , @($loops | Where-Object { $_.Condition } | ForEach-Object {
        [pscustomobject]@{ Start = $_.Condition.Extent.StartOffset; End = $_.Condition.Extent.EndOffset }
    })
}

function Get-PSMutationFunctionRange {
    # Name and offset range of every function in the file, innermost last.
    #
    # Exists so an equivalence declaration can be addressed by the function it is in
    # rather than by a line number. A line moves whenever anything above it is edited --
    # a comment, an import, another function entirely -- and the declaration then goes
    # stale although the mutant it argues about has not changed at all.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $fns = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    # Comma operator so an empty result stays an [array] through the return, exactly as
    # Get-PSMutationLoopRange does and for the same reason.
    return , @($fns | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Start = $_.Extent.StartOffset; End = $_.Extent.EndOffset }
    })
}

function Get-PSMutationEnclosingFunction {
    # The innermost function containing an offset, or '' when there is none.
    #
    # Innermost, because a nested function is the more specific answer and the one a
    # reader would name. Empty for code at file scope -- a module's top-level statements
    # are mutable too, and they have no function to be addressed by, so those keep
    # falling back to the line number.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$Offset, [object[]]$Ranges = @())
    $best = ''
    foreach ($r in $Ranges) {
        # LAST containing range wins, and that is the innermost one: FindAll returns
        # functions in document order, and a nested function always appears after the
        # function enclosing it. Pinned by a test, because an unpinned ordering invariant
        # is exactly what a refactor breaks without failing anything.
        #
        # The obvious alternative -- track the smallest containing range -- was written
        # first and removed: containing ranges are strictly nested, so their sizes are never
        # equal, which makes `-lt` versus `-le` on that comparison a mutant nothing can ever
        # kill. Fewer comparisons, all of them reachable.
        if ($Offset -ge $r.Start -and $Offset -lt $r.End) { $best = $r.Name }
    }
    return $best
}

function Test-PSMutationInLoop {
    # True if an extent sits inside any loop-condition range. Pure.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Extent, [object[]]$Ranges = @())
    foreach ($r in $Ranges) {
        if ($Extent.StartOffset -ge $r.Start -and $Extent.EndOffset -le $r.End) { return $true }
    }
    return $false
}

function Get-PSMutationSwapCandidate {
    # Every binary-operator swap: find each binary expression, look its operator token
    # up in a map, emit the replacement. Shared body, so the two callers below cannot
    # drift.
    #
    # Written out per caller instead, the loop-condition guard, the ErrorPosition trick
    # and the lowercasing would each have to be maintained in both copies -- or fixed in
    # one and left broken in the other.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param(
        $Ast,
        [string]$File,
        [object[]]$Ranges = @(),
        [Parameter(Mandatory)] [hashtable]$Map,
        [Parameter(Mandatory)] [string]$Operator
    )
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
    foreach ($n in $nodes) {
        $ext = $n.ErrorPosition
        $key = $ext.Text.ToLowerInvariant()
        if (-not $Map.ContainsKey($key)) { continue }
        if (Test-PSMutationInLoop -Extent $ext -Ranges $Ranges) { continue }
        $to = $Map[$key]
        New-PSMutationCandidate -Extent $ext -File $File -Original $ext.Text -Mutated $to -Operator $Operator
    }
}

function Get-PSMutationBinaryCandidate {
    # -eq<->-ne, -and<->-or, +<->-, ...  (operator token located via ErrorPosition)
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationSwapCandidate -Ast $Ast -File $File -Ranges $Ranges -Map $script:PSMutationBinaryMap -Operator 'BinaryOperator'
}

function Get-PSMutationBooleanCandidate {
    # $true <-> $false
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    foreach ($n in $nodes) {
        $flip = switch ($n.VariablePath.UserPath.ToLowerInvariant()) {
            'true'  { '$false' }
            'false' { '$true' }
            default { $null }
        }
        if (-not $flip) { continue }
        if (Test-PSMutationInLoop -Extent $n.Extent -Ranges $Ranges) { continue }
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $flip -Operator 'BooleanLiteral'
    }
}

function Get-PSMutationNumberCandidate {
    # integer literal N -> N+1
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConstantExpressionAst] }, $true)
    foreach ($n in $nodes) {
        if ($n.Value -isnot [int] -and $n.Value -isnot [long]) { continue }
        if (Test-PSMutationInLoop -Extent $n.Extent -Ranges $Ranges) { continue }
        $to = [string]([long]$n.Value + 1)
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $to -Operator 'NumberLiteral'
    }
}

function Get-PSMutationStringCandidate {
    # quoted, non-empty string -> ''  (never a bareword / command name)
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
    foreach ($n in $nodes) {
        if ($n.StringConstantType -notin 'SingleQuoted', 'DoubleQuoted') { continue }
        if ([string]::IsNullOrEmpty($n.Value)) { continue }
        if (Test-PSMutationInLoop -Extent $n.Extent -Ranges $Ranges) { continue }
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated "''" -Operator 'StringLiteral'
    }
}

function Get-PSMutationNegationCandidate {
    # -not X -> X ,  !X -> X
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.UnaryExpressionAst] }, $true)
    foreach ($n in $nodes) {
        if ($n.TokenKind -notin 'Not', 'Exclaim') { continue }
        if (Test-PSMutationInLoop -Extent $n.Extent -Ranges $Ranges) { continue }
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $n.Child.Extent.Text -Operator 'NegationRemoval'
    }
}

function Get-PSMutationBoundaryCandidate {
    # -gt <-> -ge, -lt <-> -le. Shifts a boundary by one instead of negating it.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationSwapCandidate -Ast $Ast -File $File -Ranges $Ranges -Map $script:PSMutationBoundaryMap -Operator 'ConditionalBoundary'
}

function Get-PSMutationConditionCandidate {
    <#
    .SYNOPSIS
        Force an if/elseif condition to $true and to $false.
    .DESCRIPTION
        The operator that reaches decisions no EXPRESSION operator can touch. A guard
        like `if ($SyncUsers) { ... }` or `if ($Ref.Value) { return ... }` contains no
        comparison, no literal and no negation, so every other operator emits nothing and
        the file scores a vacuous 100%. Forcing the condition asks the only question that
        matters about it: does any test notice which way this decision went?

        Loop conditions are excluded by the shared no-mutate zone -- forcing `while (X)`
        to $true is an unconditional hang, not a fault worth reporting.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    foreach ($n in $nodes) {
        foreach ($clause in $n.Clauses) {
            $cond = $clause.Item1
            if (Test-PSMutationInLoop -Extent $cond.Extent -Ranges $Ranges) { continue }
            foreach ($forced in '$true', '$false') {
                # A condition that already IS the forced value would splice to identical
                # source: an unkillable mutant that can only ever inflate the survivor
                # list. Skip it rather than declare it equivalent later.
                if ($cond.Extent.Text -eq $forced) { continue }
                New-PSMutationCandidate -Extent $cond.Extent -File $File -Original $cond.Extent.Text -Mutated $forced -Operator 'ConditionForcing'
            }
        }
    }
}

function Get-PSMutationReturnCandidate {
    # `return <expr>` -> `return $null`. Catches a result nothing asserts on.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)
    foreach ($n in $nodes) {
        # A bare `return` yields nothing already, and one that returns $null is the
        # mutation -- neither can change behaviour.
        if (-not $n.Pipeline) { continue }
        if ($n.Pipeline.Extent.Text -eq '$null') { continue }
        if (Test-PSMutationInLoop -Extent $n.Pipeline.Extent -Ranges $Ranges) { continue }
        New-PSMutationCandidate -Extent $n.Pipeline.Extent -File $File -Original $n.Pipeline.Extent.Text -Mutated '$null' -Operator 'ReturnValue'
    }
}

# Operator name -> the function that emits it. Keeps Get-PSMutationCandidate flat.
$script:PSMutationOperatorMap = @{
    'BinaryOperator'  = 'Get-PSMutationBinaryCandidate'
    'BooleanLiteral'  = 'Get-PSMutationBooleanCandidate'
    'NumberLiteral'   = 'Get-PSMutationNumberCandidate'
    'StringLiteral'   = 'Get-PSMutationStringCandidate'
    'NegationRemoval' = 'Get-PSMutationNegationCandidate'
    'ConditionalBoundary' = 'Get-PSMutationBoundaryCandidate'
    'ConditionForcing' = 'Get-PSMutationConditionCandidate'
    'ReturnValue' = 'Get-PSMutationReturnCandidate'
}

function Get-PSMutationCandidate {
    <#
    .SYNOPSIS
        Parse a script and return every mutation candidate for the enabled operators.
    .PARAMETER Path
        The file to parse. One file per call: mutant ids are numbered within a file, so
        the caller iterates the mutate set rather than passing it here.

    .PARAMETER Operators
        Operator classes to emit. Defaults to the high-signal set (StringLiteral off --
        it's high-volume / low-signal; opt in explicitly). An unknown name is an error,
        not an empty result: a misspelling in a config would otherwise silently restore
        the vacuous score the opt-in operators exist to prevent.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string[]]$Operators = $script:PSMutationDefaultOperators
    )

    $content = [System.IO.File]::ReadAllText($Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errors)
    # ParseInput always assigns a ParseError[] -- empty on success -- and $null.Count
    # is 0, so the Count check alone covers every case. An extra `$errors -and` in
    # front could never change the outcome.
    if ($errors.Count -gt 0) {
        throw "Cannot mutate '$Path' -- parse errors: $($errors[0].Message)"
    }

    $ranges = Get-PSMutationLoopRange -Ast $ast
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $Operators) {
        $fn = $script:PSMutationOperatorMap[$op]
        # Throw rather than skip. Dropped silently, a repo that opts into ConditionForcing
        # and misspells it gets its old vacuous score back and concludes the operator found
        # nothing in their code. A caller asking for an operator that does not exist has a
        # broken config, not an empty result.
        if (-not $fn) {
            throw "Unknown mutation operator '$op'. Valid operators: $((Get-PSMutationKnownOperator) -join ', ')."
        }
        & $fn -Ast $ast -File $Path -Ranges $ranges | ForEach-Object { $out.Add($_) }
    }

    # Canonical order BEFORE numbering, not walk order. Taking ids from the order the
    # operator list happens to be written in means swapping two entries in a config's
    # `operators` array renumbers every mutant -- while the report records that array
    # SORTED, so the recheck compatibility gate sees no change and matches survivors by id
    # against a different set. A formatter or an alphabetising editor plugin does that
    # unprompted.
    #
    # Description is part of the key because (StartOffset, Operator) is not unique:
    # ConditionForcing emits both the $true and the $false forcing at one extent.
    # Cast on the EXPRESSION with @() inside it, and both halves matter: drop the @() and
    # an empty candidate set casts to $null instead of an empty array; move the cast to the
    # variable and the analyzer still infers System.Object[], reporting
    # PSUseOutputTypeCorrectly against the declared [pscustomobject[]].
    $ordered = [pscustomobject[]]@($out | Sort-Object -Property StartOffset, Operator, Description)

    # Numbering happens here, over the UNFILTERED set, and Select-PSMutationCandidate
    # applies the covered-lines filter afterwards. That order is load-bearing rather than
    # incidental: ids assigned over the whole set survive a coverage change, which is
    # exactly what a recheck needs, because writing the assertions that kill survivors is
    # the very thing that widens coverage. The compatibility gate deliberately does not
    # inspect coverage, and it does not have to while this holds.
    #
    # So do NOT "optimise" this by filtering first, or by moving the numbering into
    # Select-PSMutationCandidate. That reads like an obvious improvement and silently makes
    # a recheck answer confidently about the wrong mutants.
    $functions = Get-PSMutationFunctionRange -Ast $ast
    $i = 0
    foreach ($c in $ordered) {
        $c.Id = ++$i
        $c.Function = Get-PSMutationEnclosingFunction -Offset $c.StartOffset -Ranges $functions
    }
    # NO comma-wrap here. Select-PSMutationCandidate collects this with @(...), and
    # `, $array` would make that a one-element array holding the array, so every per-file
    # count it derives would read 1. Emit enumerated; callers that need an array wrap @().
    return $ordered
}
