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
    # Off by default so the gate runs offline. CI passes it: the question it answers -- has this
    # version already shipped? -- cannot be answered from the working tree at all.
    [switch]$CheckGallery,
    [string]$ManifestPath,
    [string]$ChangelogPath
)

# Entry point. Skipped when this file is dot-sourced, so tests get the functions only.
# The decisions live in GateDecisions.ps1 with every other tested gate decision, rather than in
# this script. Dot-sourced at file scope so the functions are available whether this script is
# RUN or itself dot-sourced -- tests/Release.Tests.ps1 does the latter to reach them.
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')

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
        Write-Host "::warning::Release notes for $version are $($consumer.Length) characters; the gallery accepts 10600 when they come from a PowerShell manifest. Publishing an abridged $($bounded.Length) with a link to the full CHANGELOG entry."
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

    if ($CheckGallery) {
        # REACHABILITY FIRST, and separately. Find-Module returns nothing both when a version was
        # never published and when the gallery cannot be reached, and treating those alike is how
        # a gate stops being able to fail: every offline run would report "not published" and
        # pass, most loudly on the CI box where nobody is watching.
        $any = @(Find-Module PSMutant -ErrorAction SilentlyContinue)
        if ($any.Count -eq 0) {
            throw ('Release gate cannot reach the PowerShell Gallery, so it cannot tell whether ' +
                "$version has already shipped. Refusing rather than assuming it has not.")
        }
        $published = @(Find-Module PSMutant -RequiredVersion $version -ErrorAction SilentlyContinue).Count -gt 0
        $stale = Get-PSMutantStaleVersionFault -ModuleVersion $version -IsPublished $published `
            -HasUnreleasedContent (-not (Test-PSMutantUnreleasedEmpty -Changelog $changelog))
        if ($stale) { throw $stale }
    }

    # Emitted so the publish workflow can put them on the staged manifest, instead of anyone
    # maintaining a second copy of the same prose by hand.
    $bounded
}
