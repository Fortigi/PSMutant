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
