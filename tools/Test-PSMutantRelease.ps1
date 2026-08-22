<#
.SYNOPSIS
    Check that ModuleVersion and CHANGELOG.md agree, and emit the release notes for that
    version so they need not be maintained twice.

.DESCRIPTION
    Three places describe a release: ModuleVersion in the manifest, the newest version
    heading in CHANGELOG.md, and PrivateData.PSData.ReleaseNotes, which is what appears on
    the PowerShell Gallery and is permanent.

    Nothing compared them, and it has already gone wrong: 0.2.2 shipped while its entry was
    still under `## [Unreleased]`, and the heading was renamed by hand afterwards. The
    documented flow bumps ModuleVersion in the PR and renames the heading at release, so
    that rename is exactly the manual step a gate should cover.

    The decisions are pure functions -- text in, section out or a throw -- so they can be
    dot-sourced and tested without touching the filesystem (see tests/Release.Tests.ps1).

.PARAMETER ManifestPath
    The module manifest. Defaults to PSMutant.psd1 beside this tools/ directory.

.PARAMETER ChangelogPath
    The changelog. Defaults to CHANGELOG.md beside this tools/ directory.

.OUTPUTS
    [string] the release-note text for the manifest's version, on success.

.EXAMPLE
    ./tools/Test-PSMutantRelease.ps1
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ManifestPath,
    [string]$ChangelogPath
)

function Get-PSMutantChangelogHeading {
    # Pure: every "## [Name]" heading with its line index, in file order.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog)
    $out = [System.Collections.Generic.List[object]]::new()
    $lines = $Changelog -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+\[([^\]]+)\]') {
            $out.Add([pscustomobject]@{ Name = $Matches[1]; Index = $i })
        }
    }
    # NO comma-wrap: every caller wraps this in @(), and `, $array` would arrive as a
    # single item -- so @() would produce a one-element array containing the array, and
    # $mine[0].Index would be an array of indexes. This repo runs both conventions (#38);
    # this one is the enumerating half.
    return $out.ToArray()
}

function Get-PSMutantChangelogBody {
    # Pure: the body under one heading, or $null when that heading is absent.
    #
    # Deliberately carries NO ordering rules. Those belong to the release check, and
    # [Unreleased] can never satisfy them -- reusing the checked version here reported every
    # changelog as having nothing stranded, which is the opposite of the truth.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog,
        [Parameter(Mandatory)] [string]$Name
    )
    $lines = $Changelog -split "`r?`n"
    $headings = @(Get-PSMutantChangelogHeading -Changelog $Changelog)
    $mine = @($headings | Where-Object { $_.Name -eq $Name })
    if ($mine.Count -eq 0) { return $null }
    $start = $mine[0].Index + 1
    $next = @($headings | Where-Object { $_.Index -gt $mine[0].Index })
    # No following heading means this section runs to the end of the file.
    $end = if ($next.Count -gt 0) { $next[0].Index - 1 } else { $lines.Count - 1 }
    if ($end -lt $start) { return '' }
    return ($lines[$start..$end] -join "`n").Trim()
}

function Get-PSMutantReleaseSection {
    <#
    .SYNOPSIS
        Pure: given a changelog and the version being released, return that section's body.
    .DESCRIPTION
        Throws, naming the fix, when the release would be inconsistent:

          * a heading for the version exists -- without it the published version is one the
            changelog says was never released
          * it is the newest VERSIONED heading -- an Unreleased heading above it is
            conventional and fine, an older version above it means the file is out of order
          * its body is not empty -- a heading with nothing under it looks deliberate on a
            Gallery page that cannot be corrected afterwards
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog,
        [Parameter(Mandatory)] [string]$Version
    )

    $headings = @(Get-PSMutantChangelogHeading -Changelog $Changelog)
    $mine = @($headings | Where-Object { $_.Name -eq $Version })
    if ($mine.Count -eq 0) {
        throw "CHANGELOG.md has no heading for $Version. The manifest says $Version is being released, so rename the Unreleased heading to that version before tagging."
    }
    if ($mine.Count -gt 1) {
        throw "CHANGELOG.md has $($mine.Count) headings for version $Version. There must be exactly one."
    }

    $versioned = @($headings | Where-Object { $_.Name -ne 'Unreleased' })
    if ($versioned[0].Name -ne $Version) {
        throw "CHANGELOG.md lists version $($versioned[0].Name) above $Version. The version being released must be the newest versioned heading."
    }

    $body = Get-PSMutantChangelogBody -Changelog $Changelog -Name $Version
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "The section for version $Version in CHANGELOG.md is empty. A version with no notes reads as deliberate, and the Gallery page cannot be corrected afterwards."
    }
    return $body
}

function Get-PSMutantConsumerNotes {
    <#
    .SYNOPSIS
        Pure: the "### For consumers" block out of a changelog section, or $null when the
        section does not have one.

    .DESCRIPTION
        CHANGELOG.md is written for a MAINTAINER. That is deliberate and worth keeping: its
        entries carry issue numbers, the argument for a decision, and what a stated reason
        used to claim. None of that survives the trip to a gallery page. A consumer has no
        access to this repo's issue tracker, so `([#48])` renders as literal text pointing
        nowhere, and "un-exporting them did not dissolve that contract, it relocated it" is
        an argument addressed to someone who is not reading.

        0.3.0 shipped exactly that: 9646 characters of maintainer prose, opening mid-document
        at "### Changed", carrying ten unresolvable issue links. A gallery version cannot be
        edited or withdrawn, so it is permanent.

        So each version section carries a "### For consumers" block, written for the person
        deciding whether to upgrade: what changed for them, what breaks, what to do about it.
        The rest of the section stays as it is.

    .PARAMETER Section
        The body of one version's changelog section.

    .OUTPUTS
        [string] the block, without its heading, or $null when there is none.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Notes is a mass noun and names the manifest field these become. A singular "ConsumerNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Section)

    $lines = $Section -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^###\s+For consumers\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        # Any following heading of the same level or higher ends the block. Without this the
        # block would swallow the maintainer sections beneath it, which is the failure this
        # whole separation exists to prevent.
        if ($lines[$i] -match '^#{1,3}\s') { break }
        $body.Add($lines[$i])
    }
    return ($body -join "`n").Trim()
}

function Get-PSMutantBoundedReleaseNotes {
    <#
    .SYNOPSIS
        Pure: release notes cut to fit the gallery's ReleaseNotes limit, with a pointer to
        the rest.

    .DESCRIPTION
        The gallery enforces TWO different limits, and the smaller one is the one that
        applies here. A generic NuGet package may carry 35000 characters of ReleaseNotes; a
        package whose notes are EXTRACTED FROM A POWERSHELL MANIFEST may carry 10600. Only
        the first is mentioned when you exceed it:

            400 (A package's ReleaseNotes property may not be more than 35000 characters long.)
            400 (The package is invalid. The error encountered was:'A package's ReleaseNotes
                 property extracted from the PowerShell manifest may not be more than 10600
                 characters long.')

        Both were hit publishing 0.3.0, in that order -- the second only after truncating to
        26290 to satisfy the first. So the number below is 10600, and the reason it is not
        35000 is written down here because the larger number is what the first failure tells
        you, and believing it costs a second failed release.

        It rejects at the LAST step either way. The 0.3.0 publish reached Publish-Module
        having passed release consistency, staging, and the package smoke test that loads the
        artifact and runs a real mutation.

        Truncating rather than failing is deliberate. Nothing about the run is weakened by
        shorter notes: they are gallery-page prose, not a gate. Failing the release instead
        would pressure whoever writes the changelog to write less, which is the opposite of
        what this project wants -- and the changelog stays the complete record either way.

        The cut lands on a HEADING boundary, never mid-sentence, so what ships reads as a
        finished document rather than a truncated one. If no heading fits, it falls back to
        a blank-line boundary, then to a hard cut -- each fallback is one step worse for the
        reader and none of them can produce something over the limit.

    .PARAMETER Notes
        The full section body.

    .PARAMETER Version
        The version being released, used to point at the tagged changelog.

    .PARAMETER Limit
        Maximum characters. The gallery's own limit, kept as a parameter so a test can drive
        the boundary without a fixture the size of the real limit.

    .OUTPUTS
        [string] the notes to publish. Never longer than -Limit.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'ReleaseNotes is the name of the manifest field this produces. A singular "ReleaseNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Notes,
        [Parameter(Mandatory)] [string]$Version,
        [int]$Limit = 10600
    )
    if ($Notes.Length -le $Limit) { return $Notes }

    $pointer = "`n`n---`n`nThese notes are abridged. The complete entry for $Version is in " +
    "CHANGELOG.md: https://github.com/Fortigi/PSMutant/blob/v$Version/CHANGELOG.md`n"
    $room = $Limit - $pointer.Length
    $head = $Notes.Substring(0, $room)

    # Prefer a heading boundary, then a paragraph break, then give up and cut. Each candidate
    # is searched for in the text that already FITS, so every branch returns something short
    # enough -- there is no arrangement of input that lets an over-long string through.
    $cut = $head.LastIndexOf("`n## ")
    if ($cut -lt 1) { $cut = $head.LastIndexOf("`n### ") }
    if ($cut -lt 1) { $cut = $head.LastIndexOf("`n`n") }
    if ($cut -lt 1) { $cut = $head.Length }

    return $head.Substring(0, $cut).TrimEnd() + $pointer
}

function Test-PSMutantUnreleasedEmpty {
    # True when Unreleased holds nothing, or does not exist. Not a failure -- a maintainer
    # may be staging a later change -- but at release time it usually means entries that
    # belong to this version were left under the wrong heading, which is what happened
    # for 0.2.2.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Changelog)
    $body = Get-PSMutantChangelogBody -Changelog $Changelog -Name 'Unreleased'
    return [string]::IsNullOrWhiteSpace($body)
}

function Get-PSMutantRewrittenManifest {
    <#
    .SYNOPSIS
        Pure: the manifest TEXT with only its ReleaseNotes value replaced. Writes nothing.

    .DESCRIPTION
        Not Update-ModuleManifest. That does not update a manifest, it REGENERATES one from
        the data it parsed: the hand-written layout goes, a "Generated on <today>" header
        arrives that churns on every run, and every comment justifying a setting is dropped.
        This manifest's most load-bearing line is a comment -- the one saying Pester is
        deliberately absent from RequiredModules, without which someone re-adds it and
        recreates the collision that shipped a fake 100%.

        A release note is one string, so changing it touches one string.

    .PARAMETER ManifestText
        The manifest source.

    .PARAMETER Notes
        The value to place in ReleaseNotes.

    .OUTPUTS
        [string] the manifest text, with that one value replaced.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ManifestText,
        [Parameter(Mandatory)] [string]$Notes
    )
    # A literal quote inside a single-quoted PowerShell string is escaped by doubling it.
    # Without this an apostrophe closes the string and the manifest stops parsing at all --
    # discovered at publish, on the one step that cannot be undone.
    $literal = "'" + ($Notes -replace "'", "''") + "'"
    $pattern = "(?s)(ReleaseNotes\s*=\s*)'.*?'(?=\s*(
?
|\}))"
    if ($ManifestText -notmatch $pattern) {
        throw 'Manifest has no single-quoted ReleaseNotes value to replace.'
    }
    return [regex]::Replace($ManifestText, $pattern, { param($m) $m.Groups[1].Value + $literal }, 1)
}

function Get-PSMutantManifestNotesFault {
    # The manifest's ReleaseNotes against what the CHANGELOG produces, as a sentence.
    #
    # Publishing overwrites a STAGED copy, so this field never reaches the gallery -- which is
    # exactly why it drifts: it is a second copy of the same prose that nothing reads and
    # nothing checks. Someone reading the manifest, or publishing by hand, gets the stale one.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Actual,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Expected
    )
    if ($Actual -eq $Expected) { return $null }
    return ("PSMutant.psd1 ReleaseNotes do not match the '### For consumers' block in " +
        "CHANGELOG.md. The changelog is the source; run ./tools/Test-PSMutantRelease.ps1 -Apply " +
        "to regenerate the manifest field from it.")
}

# Entry point. Skipped when this file is dot-sourced, so tests get the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $root = Split-Path -Parent $PSScriptRoot
    if (-not $ManifestPath) { $ManifestPath = Join-Path $root 'PSMutant.psd1' }
    if (-not $ChangelogPath) { $ChangelogPath = Join-Path $root 'CHANGELOG.md' }

    $version = (Import-PowerShellDataFile $ManifestPath).ModuleVersion
    $changelog = Get-Content $ChangelogPath -Raw

    $notes = Get-PSMutantReleaseSection -Changelog $changelog -Version $version
    Write-Host "CHANGELOG.md and ModuleVersion agree on $version."

    if (-not (Test-PSMutantUnreleasedEmpty -Changelog $changelog)) {
        Write-Host "::warning::CHANGELOG.md still has entries under Unreleased while releasing $version. If those changes ship in this version, they belong under the $version heading."
    }

    # The gallery gets the CONSUMER block, never the whole section. Falling back to the full
    # section when the block is missing is not a lenient default -- it is precisely what
    # published 0.3.0's maintainer prose, complete with issue links a consumer cannot open,
    # onto a page that can never be corrected. Refusing costs one paragraph before a release;
    # the fallback costs a permanent page.
    $consumer = Get-PSMutantConsumerNotes -Section $notes
    if ($null -eq $consumer -or $consumer.Length -eq 0) {
        throw ("CHANGELOG.md has no '### For consumers' block under $version. The gallery page " +
            "is permanent and gets this text, so it cannot be the maintainer entry: that carries " +
            "issue numbers a consumer cannot resolve and arguments addressed to whoever wrote the " +
            "code. Add the block under the $version heading, describing what changed for someone " +
            "deciding whether to upgrade.")
    }

    # Bounded HERE, at the point the notes are produced, so the publish workflow cannot be
    # handed something the gallery will reject. A hand-written consumer block should be far
    # inside the limit, so this is now a backstop rather than the mechanism.
    $bounded = Get-PSMutantBoundedReleaseNotes -Notes $consumer -Version $version
    # Against the CONSUMER block, not the whole section. Comparing with the section would
    # warn on every release -- the section is always longer -- and quote a number that has
    # nothing to do with what shipped.
    if ($bounded.Length -lt $consumer.Length) {
        Write-Host "::warning::Release notes for $version are $($notes.Length) characters; the gallery accepts 10600 when they come from a PowerShell manifest. Publishing an abridged $($bounded.Length) with a link to the full CHANGELOG entry."
    }

    # The repo manifest is checked against the same string, so there is no unchecked second
    # copy of this prose anywhere. -Apply regenerates it; without the switch this only
    # reports, so CI can never rewrite the thing it is meant to be checking.
    $actual = [string](Import-PowerShellDataFile $ManifestPath).PrivateData.PSData.ReleaseNotes
    if ($Apply) {
        $text = Get-Content -LiteralPath $ManifestPath -Raw
        Get-PSMutantRewrittenManifest -ManifestText $text -Notes $bounded |
            Set-Content -LiteralPath $ManifestPath -NoNewline -Encoding utf8
        $check = [string](Import-PowerShellDataFile $ManifestPath).PrivateData.PSData.ReleaseNotes
        if ($check -ne $bounded) { throw 'ReleaseNotes did not survive the manifest update.' }
        Write-Host "Applied $($bounded.Length) chars of release notes for $version."
        return
    }
    $fault = Get-PSMutantManifestNotesFault -Actual $actual -Expected $bounded
    if ($fault) { throw $fault }

    # Emitted so the publish workflow can put them on the staged manifest, instead of anyone
    # maintaining a second copy of the same prose by hand.
    $bounded
}
