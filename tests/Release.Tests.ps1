# Unit tests for the release-consistency decision (tools/Test-PSMutantRelease.ps1).
#
# The gate exists because 0.2.2 shipped to the PowerShell Gallery while its entry was still
# under an Unreleased heading, and a Gallery page cannot be corrected afterwards. So the
# failure each test prevents is a permanent one.
#
# The script guards its entry point behind `$MyInvocation.InvocationName -ne '.'`, so
# dot-sourcing here loads the functions without running the gate against the real repo.
#
# Note the assertion style: the messages under test deliberately avoid square brackets
# around version numbers, because Should-Throw matches with -like and "[0.4.0]" in a
# wildcard is a character class -- the trap CLAUDE.md warns about, which cost two rounds
# of confusing failures while writing these.

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools' -AdditionalChildPath 'Test-PSMutantRelease.ps1')

    $script:good = @'
# Changelog

## [Unreleased]

## [0.3.0] - 2026-08-18
### Added
- the thing

## [0.2.2] - 2026-08-17
### Fixed
- the other thing
'@
}

Describe 'Get-PSMutantReleaseSection' {
    It 'returns the section body for the version being released' {
        $body = Get-PSMutantReleaseSection -Changelog $script:good -Version '0.3.0'
        $body | Should-BeLikeString '*the thing*'
        # It must stop at the next heading, or the Gallery page carries every earlier
        # release's notes as well.
        $body | Should-NotBeLikeString '*the other thing*'
        $body | Should-NotBeLikeString '*0.2.2*'
    }

    It 'accepts an Unreleased heading sitting above the released version' {
        # Keep a Changelog keeps an empty Unreleased at the top permanently. Treating that
        # as "a newer version" would make every correctly-formed changelog fail.
        # Calling it directly is the assertion: an exception fails the test on its own.
        Get-PSMutantReleaseSection -Changelog $script:good -Version '0.3.0' |
            Should-BeLikeString '*the thing*'
    }

    It 'refuses when the version has no heading, and names the fix' {
        # THE 0.2.2 case: ModuleVersion bumped, heading never renamed. The message has to
        # say what to do, because whoever hits it is mid-release.
        { Get-PSMutantReleaseSection -Changelog $script:good -Version '0.4.0' } |
            Should-Throw -ExceptionMessage '*no heading for 0.4.0*rename*'
    }

    It 'refuses when an older version is listed above the released one' {
        # Out-of-order headings mean the newest section is not the one being shipped, so the
        # notes attached to the package would belong to a different release.
        $outOfOrder = @'
## [0.2.2] - 2026-08-17
- older

## [0.3.0] - 2026-08-18
- newer
'@
        { Get-PSMutantReleaseSection -Changelog $outOfOrder -Version '0.3.0' } |
            Should-Throw -ExceptionMessage '*lists version 0.2.2 above 0.3.0*'
    }

    It 'refuses an empty section' {
        # A heading with nothing under it reads as deliberate on the Gallery page, which is
        # worse than a missing one: nobody goes looking for notes that appear to exist.
        $empty = @'
## [0.3.0] - 2026-08-18

## [0.2.2] - 2026-08-17
- something
'@
        { Get-PSMutantReleaseSection -Changelog $empty -Version '0.3.0' } |
            Should-Throw -ExceptionMessage '*is empty*'
    }

    It 'refuses two headings for the same version' {
        $dup = @'
## [0.3.0] - 2026-08-18
- first

## [0.3.0] - 2026-08-19
- second
'@
        { Get-PSMutantReleaseSection -Changelog $dup -Version '0.3.0' } |
            Should-Throw -ExceptionMessage '*2 headings for version 0.3.0*'
    }

    It 'reads a section that runs to the end of the file' {
        # The final section has no following heading to stop at, so it is the one case where
        # the end index is the end of the file. A first release has exactly this shape.
        $onlyOne = @'
## [Unreleased]

## [0.1.0] - 2026-07-03
### Added
- initial release
'@
        Get-PSMutantReleaseSection -Changelog $onlyOne -Version '0.1.0' |
            Should-BeLikeString '*initial release*'
    }
}

Describe 'Get-PSMutantChangelogBody' {
    It 'returns nothing for a heading that is not there' {
        # $null rather than an empty string, so a caller can tell "no such section" from
        # "section with no content" -- Test-PSMutantUnreleasedEmpty treats them alike, but
        # only because it has decided to.
        Should-BeNull -Actual (Get-PSMutantChangelogBody -Changelog $script:good -Name '9.9.9')
    }

    It 'carries no ordering rules, unlike the release check' {
        # The bug this prevents: the first version of Test-PSMutantUnreleasedEmpty asked the
        # release check for the Unreleased section, which can never be the newest VERSIONED
        # heading -- so it threw, the catch swallowed it, and every changelog was reported
        # as having nothing stranded. Extraction must stay free of those rules.
        Get-PSMutantChangelogBody -Changelog $script:good -Name '0.2.2' |
            Should-BeLikeString '*the other thing*'
    }
}

Describe 'Test-PSMutantUnreleasedEmpty' {
    It 'is true when Unreleased holds nothing' {
        # The normal resting state, and it must not produce a warning.
        Test-PSMutantUnreleasedEmpty -Changelog $script:good | Should-BeTrue
    }

    It 'is false when entries were left under Unreleased' {
        # Exactly what happened for 0.2.2. Not fatal -- a maintainer may be staging a later
        # change -- but it is the signal worth surfacing at release time.
        $stranded = @'
## [Unreleased]
### Fixed
- stranded entry

## [0.3.0] - 2026-08-18
- the thing
'@
        Test-PSMutantUnreleasedEmpty -Changelog $stranded | Should-BeFalse
    }

    It 'is true when there is no Unreleased heading at all' {
        Test-PSMutantUnreleasedEmpty -Changelog "## [0.3.0] - 2026-08-18`n- thing" | Should-BeTrue
    }
}

Describe 'Get-PSMutantBoundedReleaseNotes' {
    # The gallery rejects ReleaseNotes over 35000 characters, and it rejects them at the LAST
    # step. A 0.3.0 release passed every gate, staged, smoke-tested, and then died inside
    # Publish-Module on a 400. Everything below drives the boundary with a small -Limit
    # rather than a 35000-character fixture, because the number is a parameter for exactly
    # that reason.

    It 'returns short notes untouched' {
        # The overwhelmingly common case must not be reshaped, or every release page gains a
        # pointer nobody needs.
        $notes = "## Fixed`n`nsomething small."
        Get-PSMutantBoundedReleaseNotes -Notes $notes -Version '1.2.3' -Limit 35000 | Should-Be $notes
    }

    It 'returns notes of exactly the limit untouched' {
        # The boundary, not a comfortable value: -le versus -lt is the whole difference here,
        # and a 100-character fixture against a 35000 limit could never tell them apart.
        $notes = 'x' * 200
        (Get-PSMutantBoundedReleaseNotes -Notes $notes -Version '1.2.3' -Limit 200).Length | Should-Be 200
    }

    It 'never returns more than the limit' -ForEach @(
        @{ Limit = 300 }
        @{ Limit = 500 }
        @{ Limit = 900 }
    ) {
        # The property that actually matters. Whichever branch the cut takes -- heading,
        # paragraph or hard -- none may exceed the limit, because the one over the limit is
        # the one the gallery refuses.
        $long = (1..80 | ForEach-Object { "## Section $_`n`nbody text for section $_ here.`n" }) -join "`n"
        $out = Get-PSMutantBoundedReleaseNotes -Notes $long -Version '1.2.3' -Limit $Limit
        $out.Length | Should-BeLessThanOrEqual $Limit
    }

    It 'points at the full changelog for the version it is releasing' {
        # A truncated page that does not say it is truncated is worse than a long one: the
        # reader believes they have the whole entry.
        $long = 'y' * 5000
        $out = Get-PSMutantBoundedReleaseNotes -Notes $long -Version '9.9.9' -Limit 500
        $out | Should-BeLikeString '*abridged*'
        $out | Should-BeLikeString '*blob/v9.9.9/CHANGELOG.md*'
    }

    It 'cuts on a heading boundary rather than mid-sentence' {
        # What ships should read as a finished document. A cut inside a word tells the reader
        # the tooling is broken even when the number is right.
        $long = (1..60 | ForEach-Object { "## Section $_`n`nbody text for section $_ here, long enough to matter.`n" }) -join "`n"
        $out = Get-PSMutantBoundedReleaseNotes -Notes $long -Version '1.2.3' -Limit 900
        $body = $out.Substring(0, $out.IndexOf('---'))
        $body.TrimEnd() | Should-NotBeLikeString '*here, lo'
        $body | Should-BeLikeString '*## Section 1*'
    }

    It 'still fits when there is no heading or blank line to cut on' {
        # One unbroken blob: both preferred boundaries are absent, so the hard cut has to
        # hold the guarantee on its own.
        $blob = 'z' * 4000
        $out = Get-PSMutantBoundedReleaseNotes -Notes $blob -Version '1.2.3' -Limit 400
        $out.Length | Should-BeLessThanOrEqual 400
        $out | Should-BeLikeString '*abridged*'
    }

    It 'accepts empty notes without inventing a pointer' {
        Get-PSMutantBoundedReleaseNotes -Notes '' -Version '1.2.3' -Limit 100 | Should-Be ''
    }
}
