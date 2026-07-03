<#
.SYNOPSIS
    Cyclomatic + cognitive complexity for PowerShell, per unit (function or the
    top-level <script-body>), via the PowerShell AST. Used by the complexity gate
    (tests/Complexity.Tests.ps1) to keep every unit under the ceiling.

.DESCRIPTION
    Cyclomatic complexity = 1 + decision points (each if/elseif/switch clause, each
    loop, each catch/trap, each ternary, each -and/-or).

    Cognitive complexity (SonarSource-style) rewards flat code and penalises NESTING:
    each flow-breaking structure adds 1 PLUS its nesting depth; extra if/else branches
    add 1 (no nesting bonus); each boolean operator in a condition adds 1. It is the
    better signal for "hard to reason about", which is why we gate on it too.

    Every decision point is attributed to its nearest enclosing function (or the
    script body). Each contribution is a row: @{ Key; Line; Cyc; Cog }; the per-type
    collectors are split into small functions so this tool clears its own gate.
#>

$script:PSComplexityStructural = @(
    'IfStatementAst', 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst',
    'DoWhileStatementAst', 'DoUntilStatementAst', 'SwitchStatementAst',
    'CatchClauseAst', 'TrapStatementAst'
)
$script:PSComplexityLoopTypes = @(
    'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst',
    'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst'
)

function Get-PSComplexityUnitKey {
    # Nearest enclosing function name@line, or '<script-body>'.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return '{0}@{1}' -f $p.Name, $p.Extent.StartLineNumber
        }
        $p = $p.Parent
    }
    return '<script-body>'
}

function Get-PSComplexityNesting {
    # Count of structural ancestors up to (not crossing) the enclosing function.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $depth = 0
    $p = $Node.Parent
    while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
        if ($p.GetType().Name -in $script:PSComplexityStructural) { $depth++ }
        $p = $p.Parent
    }
    return $depth
}

function New-PSComplexityRow {
    # Build one contribution row. Pure; no state change.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns an object, changes no system state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param($Node, [int]$Cyc, [int]$Cog)
    [pscustomobject]@{ Key = Get-PSComplexityUnitKey -Node $Node; Line = $Node.Extent.StartLineNumber; Cyc = $Cyc; Cog = $Cog }
}

function Get-PSIfRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
        # elseif/else each add 1 to cognitive (no nesting bonus); [int][bool] avoids a branch.
        $extra = ($n.Clauses.Count - 1) + [int][bool]$n.ElseClause
        New-PSComplexityRow -Node $n -Cyc $n.Clauses.Count -Cog (1 + (Get-PSComplexityNesting -Node $n) + $extra)
    }
}

function Get-PSSwitchRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)) {
        New-PSComplexityRow -Node $n -Cyc $n.Clauses.Count -Cog (1 + (Get-PSComplexityNesting -Node $n))
    }
}

function Get-PSTernaryRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) {
        New-PSComplexityRow -Node $n -Cyc 1 -Cog (1 + (Get-PSComplexityNesting -Node $n))
    }
}

function Get-PSLoopRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($tn in $script:PSComplexityLoopTypes) {
        foreach ($n in $Ast.FindAll({ param($x) $x.GetType().Name -eq $tn }.GetNewClosure(), $true)) {
            New-PSComplexityRow -Node $n -Cyc 1 -Cog (1 + (Get-PSComplexityNesting -Node $n))
        }
    }
}

function Get-PSBooleanRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        if ($n.Operator -in 'And', 'Or') { New-PSComplexityRow -Node $n -Cyc 1 -Cog 1 }
    }
}

function Get-PSComplexityUnitLine {
    # Baseline unit table: every function + the script body, so decision-free units report 1/0.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $units = @{ '<script-body>' = 1 }
    foreach ($fn in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $units['{0}@{1}' -f $fn.Name, $fn.Extent.StartLineNumber] = $fn.Extent.StartLineNumber
    }
    return $units
}

function Measure-PSComplexity {
    # One record per unit: @{ File; Unit; Line; Cyclomatic; Cognitive }.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "Parse error in ${Path}: $($errors[0].Message)" }
    $rel = Split-Path $Path -Leaf

    $rows = @(Get-PSIfRow -Ast $ast) + @(Get-PSSwitchRow -Ast $ast) + @(Get-PSTernaryRow -Ast $ast) +
            @(Get-PSLoopRow -Ast $ast) + @(Get-PSBooleanRow -Ast $ast)

    $units = Get-PSComplexityUnitLine -Ast $ast
    $cyc = @{}; $cog = @{}
    foreach ($r in $rows) {
        $cyc[$r.Key] = [int]$cyc[$r.Key] + $r.Cyc
        $cog[$r.Key] = [int]$cog[$r.Key] + $r.Cog
    }

    return $units.Keys | ForEach-Object {
        [pscustomobject]@{
            File = $rel; Unit = ($_ -replace '@\d+$', ''); Line = $units[$_]
            Cyclomatic = 1 + [int]$cyc[$_]; Cognitive = [int]$cog[$_]
        }
    }
}
