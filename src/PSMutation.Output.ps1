# The console seam: what a run says, separated from the act of saying it.
#
# Everything above this file DECIDES output by returning lines. This file EMITS them, and
# it holds the module's only Write-Host call -- a rule tests/Layering.Tests.ps1 asserts, so
# a second one anywhere in src/ fails rather than quietly bypassing the seam.
#
# A line carries a ROLE, not a colour. The console renderer maps role to colour; a renderer
# for CI annotations or markdown maps the same roles to its own vocabulary, and gets the
# structured Data a survivor line carries rather than having to parse the text back out.

# Which STREAM each role goes to. Everything this module said used to go to the host, so
# -Verbose produced no extra information at all on a run measured in minutes -- the usual first
# move when something behaves oddly told you nothing.
#
# A role rather than a per-call decision, so the routing is one table a reader can check rather
# than a judgement repeated at every emitter. `Warn` deliberately stays on the host: it is also the
# score band for a middling result, and routing it to Write-Warning would turn an ordinary score
# into a warning on every run that is not green.
$script:PSMutationRoleStream = @{ Trace = 'Verbose' }

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
    # Goes to the VERBOSE stream, not the host. What a consumer wants from -Verbose on a run this
    # long is the resolutions: which sandbox, which files, which suite, which Pester -- facts that
    # are narration when a run works and the first question when it does not. Colour is recorded
    # for a renderer that chooses to show it anyway; the stream is what decides where it lands.
    Trace  = 'DarkGray'
    # Deliberately empty, and the only role with no colour. A CI workflow command is parsed
    # from the START of a line, so an ANSI escape written ahead of the '::' stops it being a
    # command and turns it into a line of noise nobody sees -- the exact failure the whole
    # annotation path exists to avoid, and invisible from a console where it looks fine.
    Annotation = ''
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

function Test-PSMutationAnnotationHost {
    # Whether the host running us renders CI annotations. GitHub Actions sets GITHUB_ACTIONS
    # to 'true' for every step.
    #
    # A positive test rather than "not a console": a developer piping output to a file is not
    # a CI, and emitting workflow commands there would put '::warning' noise in front of a
    # human for no reason.
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    return $env:GITHUB_ACTIONS -eq 'true'
}

function Get-PSMutationAnnotationLine {
    # Survivor lines rendered as GitHub workflow commands, so a finding lands on the diff the
    # reviewer is already looking at instead of in job-log scrollback.
    #
    # Built from -Data, never from Text. The mutant row carries the file and the line as
    # VALUES; recovering them by parsing a formatted string back apart is the coupling the Data
    # field exists to remove, and it would break the first time the console format is tuned.
    #
    # Only lines that carry a row become annotations. Headings, rules and the score line have
    # no file to point at, and an annotation without a location renders against the workflow
    # file itself -- pointing the reviewer at YAML that has nothing to do with the finding.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Lines)
    foreach ($line in $Lines) {
        if (-not $line.Data) { continue }
        if (-not $line.Data.File) { continue }
        # Commas and colons in the description would otherwise end the property list early;
        # GitHub reads the message only after the '::'. Newlines are the other terminator, and
        # a description is already whitespace-collapsed when the candidate is built.
        $message = "Mutant survived: $($line.Data.Description)"
        New-PSMutationLine -Role 'Annotation' -Data $line.Data `
            -Text ("::warning file={0},line={1}::{2}" -f $line.Data.File, $line.Data.Line, $message)
    }
}

function Get-PSMutationProgressPercent {
    <#
    .SYNOPSIS
        The percentage to report for one step of a run, clamped to what Write-Progress accepts.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$Index, [Parameter(Mandatory)] [int]$Total)
    # A pure function rather than an expression inside the reporter, because Write-Progress writes
    # to a stream PowerShell cannot redirect -- so nothing could observe the arithmetic and every
    # mutant of it survived a test that could only assert "did not throw".
    #
    # PercentComplete demands 0..100 and THROWS rather than clamping, so both ends matter: a total
    # of zero is a legitimate run whose files contributed no candidates, and an index past the
    # total is reachable because the counter and the candidate list are two different numbers.
    if ($Total -le 0) { return 0 }
    return [math]::Min(100, [int](100.0 * $Index / $Total))
}

function Write-PSMutationProgress {
    <#
    .SYNOPSIS
        Report loop progress on the stream built for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [int]$Total,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Activity
    )
    # BESIDE the per-mutant host lines, not instead of them: those lines are the record of what
    # each mutant did and a caller may be capturing them. This is the other thing they were doing
    # -- answering "is it still running" on a run measured in minutes -- and that belongs on the
    # stream built for it.
    #
    # Write-Progress cannot be captured, redirected, or swallowed by a caller collecting output,
    # and a non-interactive host renders nothing at all -- so it needs no -Quiet arm. That is most
    # of what -Quiet exists to solve, and this is the half of it that does not have to be silenced.
    #
    # NO zero-total guard here: Get-PSMutationProgressPercent already answers 0 for one, so a
    # guard would only suppress a harmless "0 of 0" -- a branch whose two arms differ by nothing
    # anybody can observe, which self-mutation duly reported as five survivors on one line.
    Write-Progress -Activity $Activity -Status "$Index of $Total" `
        -PercentComplete (Get-PSMutationProgressPercent -Index $Index -Total $Total)
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
    foreach ($line in $Lines) {
        # Splatted so there is still exactly ONE Write-Host in src/, which Layering.Tests.ps1
        # asserts by count: an if/else with a call in each arm reads fine and quietly makes it
        # two, which is the guard working rather than a nuisance.
        #
        # A role with no colour is written plain, and -ForegroundColor '' is not the same
        # thing -- it throws -- so the empty case has to omit the parameter, not pass an empty
        # value through.
        # Routed by role. The Write-Host call stays SINGULAR -- Layering.Tests.ps1 asserts the
        # count -- because the verbose arm returns before reaching it rather than duplicating it.
        if ($script:PSMutationRoleStream[$line.Role] -eq 'Verbose') {
            # BEFORE the -Quiet guard, deliberately. The two switches answer different questions:
            # -Quiet silences the console log, and -Verbose asks for detail on a stream the
            # console is not showing anyway. A consumer collecting a run's trace while keeping CI
            # output short wants exactly that combination, and the verbose stream is already
            # gated by the caller's own -Verbose.
            Write-Verbose $line.Text
            continue
        }
        # Everything else is console narration, which -Quiet exists to silence. Checked HERE
        # rather than at the top so it cannot silence a stream it was never about.
        if ($Quiet) { continue }
        $colour = Get-PSMutationRoleColour -Role $line.Role
        $write = @{ Object = $line.Text }
        if ($colour) { $write.ForegroundColor = $colour }
        Write-Host @write
    }
}
