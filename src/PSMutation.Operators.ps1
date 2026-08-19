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
    # Every operator name this module understands, sorted. Exposed as a function so the
    # config validator can name the alternatives without reaching into this file's state
    # -- the vocabulary lives here, and only here.
    [OutputType([string[]])]
    [CmdletBinding()]
    param()
    return [string[]]@($script:PSMutationOperatorMap.Keys | Sort-Object)
}

function Get-PSMutationOperatorList {
    # Which mutation operators to apply; unset means the default set above.
    #
    # Note the truthiness test is deliberate and matches the behaviour this replaced:
    # an EMPTY operators list falls back to the defaults rather than selecting none.
    # Arguably an explicit [] should mean "none", but that is a behaviour change, not
    # a refactor, so it is left alone here.
    #
    # Config resolution normally lives in PSMutation.Config.ps1, and this is the one
    # exception: Get-PSMutationCandidate is EXPORTED with $script:PSMutationDefaultOperators
    # as its -Operators default, so that constant cannot move without breaking the public
    # promise -- and a constant read from another file leaves neither file readable on its
    # own (#38). The resolver comes to the default rather than the other way round.
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

function New-PSMutationCandidate {
    # Build one candidate object. Central so every operator emits the same shape.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns an object, changes no system state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param($Extent, [string]$File, [string]$Original, [string]$Mutated, [string]$Operator, [string]$Description)
    return [pscustomobject]@{
        Id = 0; File = $File; Line = $Extent.StartLineNumber
        StartOffset = $Extent.StartOffset; EndOffset = $Extent.EndOffset
        Original = $Original; Mutated = $Mutated; Operator = $Operator; Description = $Description
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
    # They were the same twelve lines twice, differing only in map and operator name
    # (#38) -- which meant the loop-condition guard, the ErrorPosition trick and the
    # lowercasing all had to be maintained in both, or silently fixed in one.
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
        New-PSMutationCandidate -Extent $ext -File $File -Original $ext.Text -Mutated $to -Operator $Operator -Description "$($ext.Text) -> $to"
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
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $flip -Operator 'BooleanLiteral' -Description "$($n.Extent.Text) -> $flip"
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
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $to -Operator 'NumberLiteral' -Description "$($n.Value) -> $to"
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
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated "''" -Operator 'StringLiteral' -Description "string -> ''"
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
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $n.Child.Extent.Text -Operator 'NegationRemoval' -Description 'remove negation'
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
                New-PSMutationCandidate -Extent $cond.Extent -File $File -Original $cond.Extent.Text -Mutated $forced -Operator 'ConditionForcing' -Description "condition -> $forced"
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
        New-PSMutationCandidate -Extent $n.Pipeline.Extent -File $File -Original $n.Pipeline.Extent.Text -Mutated '$null' -Operator 'ReturnValue' -Description 'return value -> $null'
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
    .PARAMETER Operators
        Operator classes to emit. Defaults to the high-signal set (StringLiteral off --
        it's high-volume / low-signal; opt in explicitly).
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
        # Throw rather than skip. An unknown name used to be silently dropped, so a repo
        # that opted into ConditionForcing and misspelled it got its old vacuous score
        # back and concluded the operator found nothing in their code (#24). A caller
        # asking for an operator that does not exist has a broken config, not an empty
        # result.
        if (-not $fn) {
            throw "Unknown mutation operator '$op'. Valid operators: $((Get-PSMutationKnownOperator) -join ', ')."
        }
        & $fn -Ast $ast -File $Path -Ranges $ranges | ForEach-Object { $out.Add($_) }
    }

    $i = 0
    foreach ($c in $out) { $c.Id = ++$i }
    # NO comma-wrap here: this result is piped directly (Select-PSMutationCandidate),
    # and `, $array` would enter the pipeline as ONE item, so Where-Object would run
    # once against the whole array. Emit enumerated; callers that need an array wrap @().
    return $out.ToArray()
}
