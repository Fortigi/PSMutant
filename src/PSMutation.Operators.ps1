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

# The comparisons BinaryOperator never touched (#258): pattern, membership and type tests, and
# the explicit -c/-i spellings of the ones it does -- `-ceq` was never mutated at all, because
# the map above is keyed by the bare spelling. Each is negated, as BinaryOperator negates -eq.
$script:PSMutationComparisonMap = @{
    '-ceq' = '-cne'; '-cne' = '-ceq'; '-cgt' = '-cle'; '-cle' = '-cgt'; '-clt' = '-cge'; '-cge' = '-clt'
    '-ieq' = '-ine'; '-ine' = '-ieq'; '-igt' = '-ile'; '-ile' = '-igt'; '-ilt' = '-ige'; '-ige' = '-ilt'
    '-like' = '-notlike'; '-notlike' = '-like'; '-clike' = '-cnotlike'; '-cnotlike' = '-clike'; '-ilike' = '-inotlike'; '-inotlike' = '-ilike'
    '-match' = '-notmatch'; '-notmatch' = '-match'; '-cmatch' = '-cnotmatch'; '-cnotmatch' = '-cmatch'; '-imatch' = '-inotmatch'; '-inotmatch' = '-imatch'
    '-contains' = '-notcontains'; '-notcontains' = '-contains'; '-ccontains' = '-cnotcontains'; '-cnotcontains' = '-ccontains'
    '-icontains' = '-inotcontains'; '-inotcontains' = '-icontains'
    '-in' = '-notin'; '-notin' = '-in'; '-cin' = '-cnotin'; '-cnotin' = '-cin'; '-iin' = '-inotin'; '-inotin' = '-iin'
    '-is' = '-isnot'; '-isnot' = '-is'
}
# Case sensitivity, in the direction a missing test hides: -c to the bare (insensitive) form,
# and an explicit -i to -c. Bare to -c is deliberately absent -- on a number or a $null it
# changes nothing, so it would bury the real mutants under equivalent ones.
$script:PSMutationCaseMap = @{
    '-ceq' = '-eq'; '-cne' = '-ne'; '-cgt' = '-gt'; '-cge' = '-ge'; '-clt' = '-lt'; '-cle' = '-le'
    '-ieq' = '-ceq'; '-ine' = '-cne'; '-igt' = '-cgt'; '-ige' = '-cge'; '-ilt' = '-clt'; '-ile' = '-cle'
    '-clike' = '-like'; '-cnotlike' = '-notlike'; '-cmatch' = '-match'; '-cnotmatch' = '-notmatch'
    '-ilike' = '-clike'; '-inotlike' = '-cnotlike'; '-imatch' = '-cmatch'; '-inotmatch' = '-cnotmatch'
    '-ccontains' = '-contains'; '-cnotcontains' = '-notcontains'; '-cin' = '-in'; '-cnotin' = '-notin'
    '-icontains' = '-ccontains'; '-inotcontains' = '-cnotcontains'; '-iin' = '-cin'; '-inotin' = '-cnotin'
    '-creplace' = '-replace'; '-ireplace' = '-creplace'; '-csplit' = '-split'; '-isplit' = '-csplit'
}
$script:PSMutationBitwiseMap = @{ '-band' = '-bor'; '-bor' = '-band'; '-bxor' = '-bor'; '-shl' = '-shr'; '-shr' = '-shl' }
# The string operators StringOperatorRemoval skips: the expression becomes its left operand.
# A list rather than a hashtable of flags: a flag's value is never read, so every one of them was
# a mutant nothing could kill.
$script:PSMutationStringOperator = @('-replace', '-creplace', '-ireplace', '-split', '-csplit', '-isplit', '-join')

# Only the four below are on by default; every other operator is OPT-IN.
# Adding one here roughly doubles a consumer's mutant count and lowers their score, so a
# repo gating on thresholds.break would go red purely from upgrading the module.
$script:PSMutationDefaultOperators = @('BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'NegationRemoval')

$script:PSMutationIndexFor = $null
$script:PSMutationIndex = $null

function Confirm-PSMutationAstIndex {
    # Walk the given tree ONCE and bucket every node by type, including its base types, so an
    #  query is a dictionary hit. Keyed on the exact Ast object handed in -- not its root --
    # because FindAll searches the subtree it is called on, and an operator handed a subtree must
    # not see nodes outside it.
    param([Parameter(Mandatory)] $Ast)
    if ($script:PSMutationIndexFor -eq $Ast) { return }
    $idx = @{}
    # No `param()` on the predicate: it ignores the node, and a declared-but-unused parameter is
    # a PSReviewUnusedParameter finding this repo does not exclude.
    foreach ($n in $Ast.FindAll({ $true }, $true)) {
        $ty = $n.GetType()
        while ($ty -and $ty -ne [object]) {
            $bucket = $idx[$ty]
            if ($null -eq $bucket) { $bucket = [System.Collections.Generic.List[object]]::new(); $idx[$ty] = $bucket }
            $bucket.Add($n)
            $ty = $ty.BaseType
        }
    }
    # Assigned together and last: a half-built index under the new key would be served as complete.
    $script:PSMutationIndex = $idx
    $script:PSMutationIndexFor = $Ast
}

function Get-PSMutationNodeByKind {
    param([Parameter(Mandatory)] $Ast, [Parameter(Mandatory)] [type]$Type)
    Confirm-PSMutationAstIndex -Ast $Ast
    $hit = $script:PSMutationIndex[$Type]
    if ($null -eq $hit) { return @() }
    return $hit
}

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

function Test-PSMutationParsable {
    # True when a mutated file still parses (#252). Asked before the mutant is written, because a
    # mutant that does not parse fails its tests for a reason that has nothing to do with them,
    # and would be scored a kill. Every operator works on the syntax tree, so this is a guard for
    # an operator defect rather than a filter for the consumer's code -- measured: none of the
    # 1809 candidates this module's own source yields fails it, at 2.6 ms a parse.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Content)
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$null, [ref]$errors)
    return $errors.Count -eq 0
}

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
    $loops = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.LoopStatementAst]))
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
    $fns = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.FunctionDefinitionAst]))
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

function Get-PSMutationIgnoredCallRange {
    # Offset ranges of the arguments of every call to an ignored command (#263): from the end of
    # the command name to the end of the call. A mutant starting inside one is skipped.
    #
    # By the name the call is written with, ignoring case and a module qualifier --
    # `Microsoft.PowerShell.Utility\Write-Verbose` is Write-Verbose. A call whose name is not
    # written out (`& $command`) names nothing and is never ignored.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Command
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $names = [System.Collections.Generic.HashSet[string]]::new([string[]]$Command, [System.StringComparer]::OrdinalIgnoreCase)
    $calls = @(Get-PSMutationNodeByKind -Ast $ast -Type ([System.Management.Automation.Language.CommandAst]))
    # Comma operator so an empty result stays an array, as Get-PSMutationLoopRange does.
    return , @(foreach ($call in $calls) {
            $name = [string]$call.GetCommandName()
            if ($names.Contains($name.Substring($name.LastIndexOf('\') + 1))) {
                [pscustomobject]@{ Start = $call.CommandElements[0].Extent.EndOffset; End = $call.Extent.EndOffset }
            }
        })
}

function Test-PSMutationInIgnoredCall {
    # True if a candidate starts inside any ignored call's arguments. Pure.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Ranges
    )
    foreach ($r in $Ranges) {
        if ($Candidate.StartOffset -ge $r.Start -and $Candidate.StartOffset -lt $r.End) { return $true }
    }
    return $false
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
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.BinaryExpressionAst]))
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
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.VariableExpressionAst]))
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
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.ConstantExpressionAst]))
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
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.StringConstantExpressionAst]))
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
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.UnaryExpressionAst]))
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

function Get-PSMutationComparisonCandidate {
    # -like <-> -notlike, -match, -contains, -in, -is, and the -c/-i spellings of -eq to -le.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationSwapCandidate -Ast $Ast -File $File -Ranges $Ranges -Map $script:PSMutationComparisonMap -Operator 'ComparisonOperator'
}

function Get-PSMutationCaseCandidate {
    # -ceq -> -eq, -ieq -> -ceq, and likewise for every operator with a case-sensitive spelling.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationSwapCandidate -Ast $Ast -File $File -Ranges $Ranges -Map $script:PSMutationCaseMap -Operator 'CaseSensitivity'
}

function Get-PSMutationBitwiseCandidate {
    # -band <-> -bor, -bxor -> -bor, -shl <-> -shr.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationSwapCandidate -Ast $Ast -File $File -Ranges $Ranges -Map $script:PSMutationBitwiseMap -Operator 'BitwiseOperator'
}

function Test-PSMutationInterpolatedJoin {
    # True for a -join that is the whole of a `$(...)` inside a double-quoted string. Removed
    # there, it changes only the separator -- the string interpolates the array with a space --
    # and only for two items or more: measured on this module's own source, 22 of its 52 -join
    # mutants survived, nearly all of them punctuation in an error message. A -join that builds a
    # value, assigned, returned or compared, is still mutated.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    if ($Node.Operator -ne [System.Management.Automation.Language.TokenKind]::Join) { return $false }
    $p = $Node.Parent
    while ($p -is [System.Management.Automation.Language.CommandExpressionAst] -or
        $p -is [System.Management.Automation.Language.PipelineAst] -or
        $p -is [System.Management.Automation.Language.StatementBlockAst]) { $p = $p.Parent }
    return $p -is [System.Management.Automation.Language.SubExpressionAst] -and
        $p.Parent -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
}

function Get-PSMutationStringOperatorCandidate {
    # `$a -replace 'x', 'y'` -> `$a`, and the same for -split and -join: the transformation
    # skipped. Only the binary form -- unary `-split $a` has no operand to fall back to that is
    # not the expression itself. The splice never re-associates: these operators are
    # left-associative and bind looser than anything that can sit on their left, so the left
    # operand's text stands where the whole expression stood.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.BinaryExpressionAst]))
    foreach ($n in $nodes) {
        if ($n.ErrorPosition.Text -notin $script:PSMutationStringOperator) { continue }
        if (Test-PSMutationInterpolatedJoin -Node $n) { continue }
        if (Test-PSMutationInLoop -Extent $n.Extent -Ranges $Ranges) { continue }
        New-PSMutationCandidate -Extent $n.Extent -File $File -Original $n.Extent.Text -Mutated $n.Left.Extent.Text -Operator 'StringOperatorRemoval'
    }
}

function New-PSMutationForcedCandidate {
    # Emit the $true and $false forcings of one decision extent. Shared by the three
    # constructs below so the loop guard, the already-forced guard and the operator name
    # cannot drift between them.
    #
    # -Forced takes the two spellings rather than assuming '$true'/'$false': a switch clause
    # is a script block, so forcing it means '{ $true }', and comparing the extent against a
    # bare '$true' there would never match and would emit an unkillable identical-source
    # mutant.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns candidate objects, changes no system state.')]
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Extent,
        [Parameter(Mandatory)] [string]$File,
        [object[]]$Ranges = @(),
        [Parameter(Mandatory)] [string[]]$Forced
    )
    if (Test-PSMutationInLoop -Extent $Extent -Ranges $Ranges) { return }
    foreach ($to in $Forced) {
        # A condition that already IS the forced value would splice to identical source: an
        # unkillable mutant that can only ever inflate the survivor list. Skip it rather than
        # declare it equivalent later. Whitespace-collapsed, because '{ $true }' and '{$true}'
        # are the same decision written two ways and only one of them would match a literal.
        if (($Extent.Text -replace '\s+', ' ').Trim() -eq $to) { continue }
        New-PSMutationCandidate -Extent $Extent -File $File -Original $Extent.Text -Mutated $to -Operator 'ConditionForcing'
    }
}

function Get-PSMutationIfConditionCandidate {
    # if / elseif: force each clause condition.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.IfStatementAst]))
    foreach ($n in $nodes) {
        foreach ($clause in $n.Clauses) {
            New-PSMutationForcedCandidate -Extent $clause.Item1.Extent -File $File -Ranges $Ranges -Forced '$true', '$false'
        }
    }
}

function Get-PSMutationTernaryConditionCandidate {
    # `$c ? $a : $b`: force the condition, exactly as for an if.
    #
    # A ternary compiles to no IfStatementAst at all, so the operator was blind to it while a
    # reader sees an obvious branch -- and every expression operator is blind too when the
    # condition is a bare variable.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.TernaryExpressionAst]))
    foreach ($n in $nodes) {
        New-PSMutationForcedCandidate -Extent $n.Condition.Extent -File $File -Ranges $Ranges -Forced '$true', '$false'
    }
}

function Get-PSMutationDefaultToken {
    <#
    .SYNOPSIS
        Every `default` KEYWORD token in the file the given tree came from.
    .DESCRIPTION
        The tokens are re-derived here rather than threaded down from the parse in
        Get-PSMutationCandidate, and that is a deliberate trade rather than an oversight.

        Threading them means a -Tokens parameter on all ELEVEN operator functions, because they
        are dispatched uniformly by name. Nine of them would never read it, which PSScriptAnalyzer
        reports as nine PSReviewUnusedParameter findings -- correctly. A dead parameter on every
        operator to serve one is the wrong shape, and excluding the rule to hide it would mute a
        check that is doing its job.

        The cost of not threading is one extra parse, paid ONLY on a file that contains a switch
        with a default clause -- ten of 235 files in the consumer this was measured against.
        Interleaved, it does not move the analysis time.

        The root is walked to because an operator is handed the tree it should search, and only a
        ROOT extent's offsets are file offsets. Tokenising a subtree's text would produce offsets
        relative to that fragment, which would splice at the wrong place in the file -- silently,
        since the result still parses.
    #>
    [OutputType([System.Collections.Generic.List[object]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $root = $Ast
    while ($root.Parent) { $root = $root.Parent }
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($root.Extent.Text, [ref]$tokens, [ref]$null)
    $out = [System.Collections.Generic.List[object]]::new()
    # A plain foreach rather than `| Where-Object {}`, for the reason the metric collectors avoid
    # it: the pipeline invokes a PowerShell scriptblock once per token.
    foreach ($tok in $tokens) {
        if ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::Default) { $out.Add($tok) }
    }
    return $out
}

function Get-PSMutationDefaultKeywordExtent {
    <#
    .SYNOPSIS
        The extent of a switch's `default` KEYWORD, given the file's Default tokens.
    .DESCRIPTION
        `default` is the one switch decision that is not on the AST. SwitchStatementAst exposes
        `Default` as the StatementBlockAst BODY, so there is no condition node to force -- which is
        why the clause went unreached, and why it was twice written off as needing statement
        removal, an operator this module does not have. It does not: the keyword is an ordinary
        token, and forcing it is the same offset splice every other candidate uses.

        The rule is simply the LAST Default token that ends at or before this switch's default
        BODY begins. Tokens arrive in document order, so the last one to satisfy that is the
        nearest one above the body, which is this switch's own keyword.

        That nearness is what makes it correct without any further test. A nested switch's default
        sits inside a clause body or inside a default body, so it is always FURTHER from this
        body than this keyword is; and an earlier sibling switch's default is further still.

        An earlier version bounded the search from below as well, opening the window after the
        last clause's body -- or after the switch condition when there were no clauses. That is
        three more decisions to get right, and self-mutation showed why it was the wrong shape:
        several of them could not be falsified at all. `Clauses.Count -gt 0` forced to $true
        yields `Clauses[-1]` on an empty collection, which is $null, which coerces to offset 0 --
        the same answer the correct branch gives. A rule that needs no lower bound has no such
        arm to test.

        `-le` rather than `-lt` because a keyword may END where the body BEGINS: `default{ 1 }`
        is legal PowerShell and closes that gap to zero.
    #>
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Switch,
        [Parameter(Mandatory)] [object[]]$Tokens
    )
    $to = $Switch.Default.Extent.StartOffset
    $found = $null
    foreach ($tok in $Tokens) {
        if ($tok.Extent.EndOffset -le $to) { $found = $tok.Extent }
    }
    return $found
}

function Get-PSMutationSwitchConditionCandidate {
    <#
    .SYNOPSIS
        Force every switch clause to always match and to never match.
    .DESCRIPTION
        A clause condition is its own extent, so forcing it is the same offset splice every other
        operator does -- for a VALUE clause as much as for a script-block one. `1 { 'one' }` becomes
        `{ $true } { 'one' }`, which always matches and therefore shadows every later clause, or
        `{ $false } { 'one' }`, which never matches and makes the clause dead:

            switch ($x) { 1 { 'one' } 'a' { 'letter' } default { 'none' } }
              baseline           x=1 one    x='a' letter      x=99 none
              1 -> { $true }     x=1 one    x='a' one letter  x=99 one     <- shadows, and falls through
              1 -> { $false }    x=1 none   x='a' letter      x=99 none

        The shadowing case is the fault worth catching: a `switch` is the idiomatic PowerShell
        multi-way decision, and a clause that swallows the ones below it is a real bug that no
        expression operator can reach. Measured on a consumer repository of 238 files: 59 value
        clauses against 3 script-block ones, so this is where nearly all of a switch's decisions
        live.

        Forced to a SCRIPT BLOCK, never to a bare `$true`. PowerShell matches a clause with
        `$_ -eq <clause>`, so splicing a bare `$true` over `1` does not mean "always match" -- it
        stops matching `x = 1` and starts matching `x = $true`, which is a value substitution with
        murky semantics. Wrapping it in a script block makes the clause a CONDITION, which is what
        forcing means everywhere else in this operator. NumberLiteral and StringLiteral already
        perturb the literal values on their own terms.

        BOTH directions, as for an if and a ternary and for the same reason: a test that only ever
        exercises the matching branch is killed by forcing the clause dead and never notices it
        being forced live.

        The `default` clause is still not reached. It sits outside `Clauses` on the AST and has no
        condition to force; removing it entirely is statement removal, an operator this module does
        not have. That remains open on #172.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.SwitchStatementAst]))
    foreach ($n in $nodes) {
        foreach ($clause in $n.Clauses) {
            New-PSMutationForcedCandidate -Extent $clause.Item1.Extent -File $File -Ranges $Ranges -Forced '{ $true }', '{ $false }'
        }
        if (-not $n.Default) { continue }
        # Fetched per switch-with-a-default rather than memoised per file. A memo is one more
        # decision, and self-mutation showed it was one nothing could kill: re-fetching returns
        # the same tokens, so its two arms differ only in speed. Files holding more than one
        # switch WITH a default are rare enough that the honest spelling wins.
        $keyword = Get-PSMutationDefaultKeywordExtent -Switch $n -Tokens (Get-PSMutationDefaultToken -Ast $Ast)
        # No `if ($keyword)`: a switch whose Default is set always has the keyword above it, so
        # the guard's false arm is unreachable and its mutant unkillable. If that invariant ever
        # breaks, a null extent fails loudly here rather than dropping the candidate in silence.
        New-PSMutationForcedCandidate -Extent $keyword -File $File -Ranges $Ranges -Forced '{ $true }', '{ $false }'
    }
}

function Get-PSMutationConditionCandidate {
    <#
    .SYNOPSIS
        Force every decision this module can reach to always and never take its branch.
    .DESCRIPTION
        The operator that reaches decisions no EXPRESSION operator can touch. A guard like
        `if ($SyncUsers) { ... }` or `if ($Ref.Value) { return ... }` contains no comparison, no
        literal and no negation, so every other operator emits nothing and the file scores a
        vacuous 100%. Forcing the condition asks the only question that matters about it: does any
        test notice which way this decision went?

        Three constructs, one operator name. It used to be `if`/`elseif` alone, which meant a
        `switch` -- the idiomatic PowerShell multi-way decision, and precisely the shape where a
        wrong branch is a real bug -- and a ternary were invisible to every operator. A consumer
        whose code leans on either would see ConditionForcing report almost nothing and reasonably
        conclude their code was well covered.

        Loop conditions are excluded by the shared no-mutate zone -- forcing `while (X)` to $true
        is an unconditional hang, not a fault worth reporting.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    Get-PSMutationIfConditionCandidate -Ast $Ast -File $File -Ranges $Ranges
    Get-PSMutationTernaryConditionCandidate -Ast $Ast -File $File -Ranges $Ranges
    Get-PSMutationSwitchConditionCandidate -Ast $Ast -File $File -Ranges $Ranges
}

function Get-PSMutationReturnCandidate {
    # `return <expr>` -> `return $null`. Catches a result nothing asserts on.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param($Ast, [string]$File, [object[]]$Ranges = @())
    $nodes = @(Get-PSMutationNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.ReturnStatementAst]))
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
    'ComparisonOperator' = 'Get-PSMutationComparisonCandidate'
    'CaseSensitivity' = 'Get-PSMutationCaseCandidate'
    'BitwiseOperator' = 'Get-PSMutationBitwiseCandidate'
    'StringOperatorRemoval' = 'Get-PSMutationStringOperatorCandidate'
}

function Get-PSMutationCandidate {
    <#
    .SYNOPSIS
        Parse a script and return every mutation candidate for the enabled operators.
    .PARAMETER Path
        The file to parse. One file per call: mutant ids are numbered within a file, so
        the caller iterates the mutate set rather than passing it here.

    .PARAMETER Operators
        Operator classes to emit. Defaults to the four expression operators: BinaryOperator,
        BooleanLiteral, NumberLiteral, NegationRemoval.

        EIGHT more are opt-in, not one. ConditionalBoundary reaches off-by-one errors,
        ConditionForcing reaches a bare guard with no comparison in it, ReturnValue reaches a
        result nothing asserts on, and StringLiteral is high-volume and low-signal. The first
        three are what stop structural code scoring a vacuous 100%; each roughly doubles the
        mutant count, which is why none of them is on by default. ComparisonOperator,
        CaseSensitivity, BitwiseOperator and StringOperatorRemoval (#258) reach the operators
        BinaryOperator never touched -- -like, -match, -contains, -in, -is, every -c/-i
        spelling, -band, -replace, -split, -join -- and are opt-in for the same reason: on by
        default, they would lower the score of a repo that changed nothing but its PSMutant.

        An unknown name is an error, not an empty result: a misspelling in a config would
        otherwise be dropped and then written into the report as though it had run, handing back
        exactly the vacuous score the opt-in operators exist to prevent.
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
