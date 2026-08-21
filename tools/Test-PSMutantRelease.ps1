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

function Get-PSMutantBoundedReleaseNotes {
    <#
    .SYNOPSIS
        Pure: release notes cut to fit the gallery's ReleaseNotes limit, with a pointer to
        the rest.

    .DESCRIPTION
        The PowerShell Gallery rejects a package whose ReleaseNotes exceed 35000 characters,
        and it rejects it at the LAST step -- the irreversible one. A 0.3.0 release reached
        Publish-Module, having passed staging, the package smoke test and every gate, and
        died on `400 (A package's ReleaseNotes property may not be more than 35000
        characters long.)`.

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
        the boundary without a 35000-character fixture.

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
        [int]$Limit = 35000
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

    # Bounded HERE, at the point the notes are produced, so the publish workflow cannot be
    # handed something the gallery will reject. Doing it in the workflow instead would put
    # the decision back in a YAML snippet, where it is untested and cannot be run by hand.
    $bounded = Get-PSMutantBoundedReleaseNotes -Notes $notes -Version $version
    if ($bounded.Length -lt $notes.Length) {
        Write-Host "::warning::Release notes for $version are $($notes.Length) characters and the gallery accepts 35000. Publishing an abridged $($bounded.Length) with a link to the full CHANGELOG entry."
    }

    # Emitted so the publish workflow can put them on the staged manifest, instead of anyone
    # maintaining a second copy of the same prose by hand.
    $bounded
}
