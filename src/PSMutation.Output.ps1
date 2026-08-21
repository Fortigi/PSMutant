# The console seam: what a run says, separated from the act of saying it.
#
# Everything above this file DECIDES output by returning lines. This file EMITS them, and
# it holds the module's only Write-Host call -- a rule tests/Layering.Tests.ps1 asserts, so
# a second one anywhere in src/ fails rather than quietly bypassing the seam.
#
# A line carries a ROLE, not a colour. The console renderer maps role to colour; a renderer
# for CI annotations or markdown maps the same roles to its own vocabulary, and gets the
# structured Data a survivor line carries rather than having to parse the text back out.

$script:PSMutationRoleColour = [ordered]@{
    Banner = 'Cyan'
    Good   = 'Green'
    Warn   = 'Yellow'
    Bad    = 'Red'
    Detail = 'Gray'
    Muted  = 'DarkGray'
    # Distinct from Muted although both print DarkGray. A rule is a separator, so a
    # renderer that is not a console -- an annotation stream, a markdown table -- drops it
    # while still wanting the caveats Muted carries.
    Rule   = 'DarkGray'
}

function Get-PSMutationKnownRole {
    # Every role a line may carry, sorted. A function rather than a bare constant so a
    # caller can name the alternatives without reading this file's $script: state.
    [OutputType([string[]])]
    [CmdletBinding()]
    param()
    return [string[]]@($script:PSMutationRoleColour.Keys | Sort-Object)
}

function New-PSMutationLine {
    <#
    .SYNOPSIS
        One line of run output: a role, the text, and optionally the record it describes.

    .DESCRIPTION
        The only place a line is shaped, so a new caller cannot invent a field or a role.

        An unknown role THROWS rather than falling back to a default colour. A silently
        uncoloured line looks like a styling slip; the failure it actually signals is a
        renderer that will not know what to do with the line at all -- and that surfaces
        as missing output, in whichever renderer was added last.

    .PARAMETER Role
        What kind of line this is. See Get-PSMutationKnownRole.

    .PARAMETER Text
        The console rendering. A non-console renderer may ignore it in favour of Data.

    .PARAMETER Data
        The record behind the line, when there is one -- a survivor's mutant row, so an
        annotation renderer has the file, line and description without parsing Text.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure factory: returns an object, changes no system state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Role,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        $Data
    )
    if (-not $script:PSMutationRoleColour.Contains($Role)) {
        throw "Unknown output role '$Role'. Valid roles: $((Get-PSMutationKnownRole) -join ', ')."
    }
    return [pscustomobject]@{ Role = $Role; Text = $Text; Data = $Data }
}

function Get-PSMutationRoleColour {
    # The console colour for a role. Pure, so the mapping is testable on its own. Computed
    # inline as an argument to Write-Host instead, a colour decision has no seam to assert
    # against: a comparison that makes every score green is invisible until someone reads
    # the output and notices 0% is not red.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Role)
    if (-not $script:PSMutationRoleColour.Contains($Role)) {
        throw "Unknown output role '$Role'. Valid roles: $((Get-PSMutationKnownRole) -join ', ')."
    }
    return [string]$script:PSMutationRoleColour[$Role]
}

function Write-PSMutationOutput {
    <#
    .SYNOPSIS
        Render lines to the console. The module's only Write-Host site, and the only place
        -Quiet is honoured.

    .DESCRIPTION
        -Quiet lives HERE rather than at each call site. Guarding at the caller means every
        new emitter has to remember, and a caller that forgets prints in quiet mode while
        the tests -- which assert on the strings the current callers emit -- stay green for
        output that did not exist when they were written.

    .PARAMETER Lines
        Lines from New-PSMutationLine. An empty collection is valid and emits nothing.

    .PARAMETER Quiet
        Suppress the output entirely.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The single console renderer. Colour-coded progress is this CLI tool intended output, and confining Write-Host to one function is what lets the rule stay enforced everywhere else.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Lines,
        [switch]$Quiet
    )
    if ($Quiet) { return }
    foreach ($line in $Lines) {
        Write-Host $line.Text -ForegroundColor (Get-PSMutationRoleColour -Role $line.Role)
    }
}
