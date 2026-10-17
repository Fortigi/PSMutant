# Equivalent-mutant declarations written in the code (#262): a line comment directly above the
# line holding the mutant, naming the mutation and carrying the argument.
#
# The SAME checked declaration as a config entry, and deliberately nothing more: each becomes an
# ordinary `File:Line:Description` key, so every rule a config declaration faces applies to it
# unchanged -- it must match exactly one mutant, and a mutant the suite kills makes it stale. What
# it adds is that the argument sits beside the code and moves with it, where a line-keyed config
# entry goes stale on any edit above it.

# Anywhere in the text; each hit is then checked against the tokens, so a mention inside a string
# or further into a comment is not a declaration.
$script:PSMutationInlinePattern = [regex]::new('#[ \t]*PSMutant-Equivalent[ \t]*:([^\r\n]*)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

# `<original> -> <mutated>: <reason>`. The description ends at the first ': ' AFTER the arrow, so
# an original holding a colon -- a drive, a scope, a label -- is read whole. A mutated side holding
# ': ' would be cut short, and the key it produced would then match no mutant, which the run
# refuses by name rather than guessing.
$script:PSMutationInlineBody = [regex]::new('^\s*(?<description>.+? -> .*?):\s+(?<reason>.*)$')

function Get-PSMutationTokenIndexAt {
    # The index of the token starting exactly at Offset, or -1, by a binary search over the
    # offsets -- .NET's, so there is no hand-written fencepost to get wrong. Paid once per
    # declaration; a file without one never gets here.
    [OutputType([int])]
    [CmdletBinding()]
    param(
        # Never empty: the parser always ends the list with an EndOfInput token.
        [Parameter(Mandatory)] [object[]]$Token,
        [Parameter(Mandatory)] [int]$Offset
    )
    $offsets = [int[]]@($Token.Extent.StartOffset)
    $found = [System.Array]::BinarySearch($offsets, $Offset)
    return ($found -ge 0) ? $found : -1
}

function Get-PSMutationInlineTarget {
    # The line of the code a declaration stands directly above, or why it stands above none:
    # [pscustomobject]@{ Line; Fault }, one of the two set. Directly above means through any
    # comment lines that follow it, with no blank line and no code before it on its own line.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Token,
        [Parameter(Mandatory)] [int]$Index
    )
    $kind = [System.Management.Automation.Language.TokenKind]
    if ($Index -gt 0 -and $Token[$Index - 1].Kind -ne $kind::NewLine) {
        return [pscustomobject]@{ Line = $null; Fault = 'it shares its line with code -- put it on its own line, directly above the mutated line' }
    }
    $newLines = 0
    for ($i = $Index + 1; $i -lt $Token.Count; $i++) {
        $t = $Token[$i]
        if ($t.Kind -eq $kind::NewLine) {
            $newLines++
            # Two line breaks with nothing between them: a blank line.
            if ($newLines -gt 1) { return [pscustomobject]@{ Line = $null; Fault = 'a blank line separates it from the code below' } }
            continue
        }
        $newLines = 0
        if ($t.Kind -eq $kind::Comment) { continue }
        if ($t.Kind -eq $kind::EndOfInput) { break }
        return [pscustomobject]@{ Line = $t.Extent.StartLineNumber; Fault = $null }
    }
    return [pscustomobject]@{ Line = $null; Fault = 'no code follows it' }
}

function Get-PSMutationInlineDeclaration {
    # The declarations one file makes in its code, as config keys, and the ones that cannot be.
    # Pure: the text and the tokens one parse produced.
    #
    # A declaration that cannot become a key is RETURNED, never dropped: the run refuses it,
    # because an argument that drifted away from its line -- a blank line inserted, the line moved
    # -- would otherwise sit there believing it excuses a mutant.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        # Empty for a file that could not be read. A missing mutate file is refused later, by the
        # sandbox check that owns that fault; here it simply declares nothing.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        # The file as the config's mutate list spells it, which is how a key names it.
        [Parameter(Mandatory)] [string]$File
    )
    $declared = [System.Collections.Generic.List[object]]::new()
    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($match in $script:PSMutationInlinePattern.Matches($Text)) {
        $index = Get-PSMutationTokenIndexAt -Token $Token -Offset $match.Index
        # Not the start of a token: the text is inside a string, or further into a comment about
        # something else. A token that DOES start at a `#` is a comment -- nothing else can.
        if ($index -lt 0) { continue }
        $line = $Token[$index].Extent.StartLineNumber
        $fault = Get-PSMutationInlineFault -Body $match.Groups[1].Value -Target (Get-PSMutationInlineTarget -Token $Token -Index $index)
        if ($fault) {
            $faults.Add("${File}:$line declares an equivalent mutant, but $fault")
            continue
        }
        $body = $script:PSMutationInlineBody.Match($match.Groups[1].Value)
        $target = (Get-PSMutationInlineTarget -Token $Token -Index $index).Line
        $declared.Add([pscustomobject]@{
                Key    = "${File}:${target}:$($body.Groups['description'].Value.Trim())"
                Reason = $body.Groups['reason'].Value.Trim()
                File   = $File
                Line   = $line
            })
    }
    return [pscustomobject]@{ Declared = @($declared); Faults = @($faults) }
}

function Get-PSMutationInlineFault {
    # Why one declaration cannot become a key, as text, or nothing when it can.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Body,
        [Parameter(Mandatory)] $Target
    )
    if ($Target.Fault) { return $Target.Fault }
    $parsed = $script:PSMutationInlineBody.Match($Body)
    if (-not $parsed.Success) {
        return "'$($Body.Trim())' is not '<original> -> <mutated>: <reason>' -- it has to name the mutation it excuses, because a line can hold several"
    }
    if (-not $parsed.Groups['reason'].Value.Trim()) { return 'it gives no reason -- an equivalence is an argument, or it is a mute button' }
}

function Get-PSMutationAllEquivalent {
    # The config's equivalents with every declaration the mutated files make in their code added,
    # as one object of the shape the config holds -- so everything downstream reads one set.
    #
    # Refused, all faults at once: a declaration that cannot become a key, and an inline key that
    # repeats a config key. A mutant declared in both places under DIFFERENT forms -- the config's
    # function-keyed entry and this line-keyed one -- is caught later, where each mutant's keys
    # are known (Get-PSMutationDeclarationCoverageFault).
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Cfg,
        [Parameter(Mandatory)] [string]$SourceRoot
    )
    $all = [ordered]@{}
    # No guard for a config without equivalents: its PSObject is $null there, and a loop over
    # nothing adds nothing.
    foreach ($p in $Cfg.equivalents.PSObject.Properties) { $all[$p.Name] = $p.Value }
    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Cfg.mutate)) {
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $file), [ref]$tokens, [ref]$null)
        $found = Get-PSMutationInlineDeclaration -Text $ast.Extent.Text -Token @($tokens) -File $file
        $faults.AddRange([string[]]$found.Faults)
        foreach ($d in $found.Declared) {
            if ($all.Contains($d.Key)) {
                $faults.Add("$($d.File):$($d.Line) declares $($d.Key) equivalent, and so does the config -- keep one argument")
                continue
            }
            $all[$d.Key] = $d.Reason
        }
    }
    if ($faults.Count -gt 0) {
        throw ('The equivalent-mutant declarations in the code cannot be used: ' + ($faults -join '; ') + '.')
    }
    return [pscustomobject]$all
}
