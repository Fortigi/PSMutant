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
$script:PSMutationDefaultOperators = @('BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'NegationRemoval')

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

function Get-PSMutationBinaryCandidate {
    # -eq<->-ne, -and<->-or, +<->-, ...  (operator token located via ErrorPosition)
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
    foreach ($n in $nodes) {
        $ext = $n.ErrorPosition
        $key = $ext.Text.ToLowerInvariant()
        if (-not $script:PSMutationBinaryMap.ContainsKey($key)) { continue }
        if (Test-PSMutationInLoop -Extent $ext -Ranges $Ranges) { continue }
        $to = $script:PSMutationBinaryMap[$key]
        New-PSMutationCandidate -Extent $ext -File $File -Original $ext.Text -Mutated $to -Operator 'BinaryOperator' -Description "$($ext.Text) -> $to"
    }
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

# Operator name -> the function that emits it. Keeps Get-PSMutationCandidate flat.
$script:PSMutationOperatorMap = @{
    'BinaryOperator'  = 'Get-PSMutationBinaryCandidate'
    'BooleanLiteral'  = 'Get-PSMutationBooleanCandidate'
    'NumberLiteral'   = 'Get-PSMutationNumberCandidate'
    'StringLiteral'   = 'Get-PSMutationStringCandidate'
    'NegationRemoval' = 'Get-PSMutationNegationCandidate'
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
    if ($errors -and $errors.Count -gt 0) {
        throw "Cannot mutate '$Path' -- parse errors: $($errors[0].Message)"
    }

    $ranges = Get-PSMutationLoopRange -Ast $ast
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $Operators) {
        $fn = $script:PSMutationOperatorMap[$op]
        if ($fn) { & $fn -Ast $ast -File $Path -Ranges $ranges | ForEach-Object { $out.Add($_) } }
    }

    $i = 0
    foreach ($c in $out) { $c.Id = ++$i }
    # NO comma-wrap here: this result is piped directly (Select-PSMutationCandidate),
    # and `, $array` would enter the pipeline as ONE item, so Where-Object would run
    # once against the whole array. Emit enumerated; callers that need an array wrap @().
    return $out.ToArray()
}
