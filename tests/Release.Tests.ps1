# Unit tests for the release-consistency decision (tools/Test-PSMutantRelease.ps1).
#
# The gate exists because 0.2.2 shipped to the PowerShell Gallery while its entry was still
# under an Unreleased heading, and a Gallery page cannot be corrected afterwards. So the
# failure each test prevents is a permanent one.
#
# The decisions themselves now live in tools/GateDecisions.ps1 with every other tested gate
# decision; this file dot-sources the SCRIPT rather than that file, which loads both and so
# also proves the script's own wiring still reaches them.
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
    # The gallery enforces TWO limits: 35000 for a generic NuGet package, and 10600 when the
    # notes are extracted from a PowerShell manifest. Publishing 0.3.0 hit both in turn --
    # the second only after truncating to satisfy the first -- so the default is the smaller
    # one. Everything below drives the boundary with a small -Limit rather than a fixture the
    # size of the real limit, because the number is a parameter for exactly that reason.

    It 'defaults to the manifest-extracted limit, not the larger NuGet one' {
        # Pinned because the two numbers are easy to confuse and the larger one is what the
        # first failure reports. A default of 35000 here publishes green and fails at the
        # gallery, which is the exact sequence that produced two dead releases.
        $blob = 'q' * 12000
        $out = Get-PSMutantBoundedReleaseNotes -Notes $blob -Version '1.2.3'
        $out.Length | Should-BeLessThanOrEqual 10600
    }

    It 'returns short notes untouched' {
        # The overwhelmingly common case must not be reshaped, or every release page gains a
        # pointer nobody needs.
        $notes = "## Fixed`n`nsomething small."
        Get-PSMutantBoundedReleaseNotes -Notes $notes -Version '1.2.3' | Should-Be $notes
    }

    It 'returns notes of exactly the limit untouched' {
        # The boundary, not a comfortable value: -le versus -lt is the whole difference here,
        # and a 100-character fixture against the real limit could never tell them apart.
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


Describe 'Get-PSMutantConsumerNotes' {
    # CHANGELOG.md is written for a maintainer: issue numbers, the argument behind a
    # decision, what a stated reason used to claim. A gallery page is permanent and gets
    # whatever this returns, and its reader has no access to the issue tracker. 0.3.0
    # shipped 9646 characters of maintainer prose with ten unresolvable issue links, so
    # these pin the separation rather than the formatting.

    It 'returns the block without its heading' {
        $section = @"
### For consumers

Upgrade freely. Nothing breaks.

### Changed
- maintainer detail with ([#48]) in it
"@
        $out = Get-PSMutantConsumerNotes -Section $section
        $out | Should-Be 'Upgrade freely. Nothing breaks.'
    }

    It 'stops at the next heading rather than swallowing the maintainer sections' {
        # The whole point of the separation. A block that ran to the end of the section
        # would publish exactly what it exists to keep back, and would look like it worked.
        $section = @"
### For consumers

The consumer part.

### Fixed
- something with ([#83]) that a consumer cannot resolve
"@
        $out = Get-PSMutantConsumerNotes -Section $section
        $out | Should-NotBeLikeString '*#83*'
        $out | Should-Be 'The consumer part.'
    }

    It 'stops at a heading of any level up to three' -ForEach @(
        @{ Heading = '# Top' }
        @{ Heading = '## Version' }
        @{ Heading = '### Fixed' }
    ) {
        $section = "### For consumers`n`nkeep this`n`n$Heading`n- drop this"
        (Get-PSMutantConsumerNotes -Section $section) | Should-Be 'keep this'
    }

    It 'returns null when the section has no block' {
        # Null, not empty string: the caller REFUSES on this, and refusing is what stops the
        # maintainer entry reaching a page that cannot be corrected.
        Should-BeNull -Actual (Get-PSMutantConsumerNotes -Section "### Fixed`n- a thing")
    }

    It 'returns null for an empty section' {
        Should-BeNull -Actual (Get-PSMutantConsumerNotes -Section '')
    }

    It 'does not match a heading that merely starts with the same words' {
        # "### For consumers upgrading from 0.2" is a different heading, and treating it as
        # the block would publish a section nobody wrote for that purpose.
        Should-BeNull -Actual (Get-PSMutantConsumerNotes -Section "### For consumers upgrading`n`ntext")
    }

    It 'keeps blank lines and list structure inside the block' {
        $section = "### For consumers`n`n- one`n`n- two`n`n### Changed`n- x"
        (Get-PSMutantConsumerNotes -Section $section) | Should-Be "- one`n`n- two"
    }
}

Describe 'the real CHANGELOG, as the gallery will see it' {
    # Guards the artifact rather than the function. These are the two properties that made
    # 0.3.0's published page bad, and neither is visible from the code alone.
    BeforeAll {
        $script:changelog = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md') -Raw
        $script:version = (Import-PowerShellDataFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSMutant.psd1')).ModuleVersion
        $script:section = Get-PSMutantChangelogBody -Changelog $script:changelog -Name $script:version
        $script:consumer = Get-PSMutantConsumerNotes -Section $script:section
    }

    It 'has a consumer block for the version in the manifest' {
        Should-NotBeNull -Actual $script:consumer
    }

    It 'gives each release section at most one heading of a kind' {
        # A merge or a rebase readily produces two '### For consumers' blocks under one release,
        # because git resolves the two insertions independently and neither side is a textual
        # conflict. The result is a document that reads as two separate changelogs stapled
        # together, and Get-PSMutantConsumerNotes takes the FIRST block -- so the second one's
        # entries are silently absent from what the gallery publishes.
        #
        # Happened three times while writing one feature, every time recovered by hand. Asserted
        # over every release section, not just the current one, since a bad rebase lands wherever
        # the conflict was.
        $sections = [regex]::Matches($script:changelog, '(?ms)^## \[(?<name>[^\]]+)\][^\n]*\n(?<body>.*?)(?=^## \[|\z)')
        @($sections).Count | Should-BeGreaterThan 0 -Because 'the fixture must find sections, or this asserts nothing'
        foreach ($sec in $sections) {
            $headings = @([regex]::Matches($sec.Groups['body'].Value, '(?m)^### (.+)$') |
                    ForEach-Object { $_.Groups[1].Value.Trim() })
            $dupes = @($headings | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
            $dupes -join ', ' | Should-Be '' -Because "release $($sec.Groups['name'].Value) repeats a heading"
        }
    }

    It 'carries no issue references a consumer cannot resolve' {
        # The specific defect on the 0.3.0 page: ten [#nn] links, undefined in the notes, so
        # they render as literal text pointing nowhere.
        ([regex]::Matches($script:consumer, '\[#\d+\]')).Count | Should-Be 0
        ([regex]::Matches($script:consumer, '\(#\d+\)')).Count | Should-Be 0
    }

    It 'fits the gallery limit without being truncated' {
        # A hand-written consumer block should be far inside the limit. If this fails the
        # block is being used as a second changelog, which is not what it is for.
        $script:consumer.Length | Should-BeLessThanOrEqual 10600
    }
}

Describe 'Get-PSMutantRewrittenManifest' {
    BeforeAll {
        $script:Manifest = @'
@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '9.9.9'
    # NO RequiredModules entry for Pester, deliberately.
    PrivateData = @{
        PSData = @{
            ProjectUri   = 'https://example/repo'
            ReleaseNotes = 'old notes'
        }
    }
}
'@
    }

    It 'replaces the notes and leaves everything else alone' {
        # The whole reason this exists instead of Update-ModuleManifest, which regenerates the
        # file: the comment about RequiredModules is the most load-bearing line in the real
        # manifest, and regenerating drops it.
        $out = Get-PSMutantRewrittenManifest -ManifestText $script:Manifest -Notes 'new notes'
        $out | Should-BeLikeString "*ReleaseNotes = 'new notes'*"
        $out | Should-BeLikeString '*NO RequiredModules entry for Pester, deliberately.*'
        $out | Should-BeLikeString "*ModuleVersion     = '9.9.9'*"
        $out | Should-NotBeLikeString '*old notes*'
    }

    It 'doubles a quote so the manifest still parses' {
        # An apostrophe would otherwise close the string and leave a manifest that cannot be
        # read at all -- found at publish, on the step that cannot be undone.
        $out = Get-PSMutantRewrittenManifest -ManifestText $script:Manifest -Notes "it's fixed"
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "psd-$([System.Guid]::NewGuid().ToString('N')).psd1"
        try {
            Set-Content -LiteralPath $f -Value $out -Encoding utf8
            (Import-PowerShellDataFile -LiteralPath $f).PrivateData.PSData.ReleaseNotes |
                Should-Be "it's fixed"
        }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps a multi-line block intact, which is the shape that ships' {
        # The published notes are the CHANGELOG block, newlines and markdown included.
        $notes = "First line.`nSecond line."
        $out = Get-PSMutantRewrittenManifest -ManifestText $script:Manifest -Notes $notes
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "psd-$([System.Guid]::NewGuid().ToString('N')).psd1"
        try {
            Set-Content -LiteralPath $f -Value $out -Encoding utf8
            (Import-PowerShellDataFile -LiteralPath $f).PrivateData.PSData.ReleaseNotes |
                Should-Be $notes
        }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a manifest with no ReleaseNotes rather than silently doing nothing' {
        # Returning the text unchanged would make -Apply a no-op while the verify step failed
        # forever, with no way to reconcile them.
        { Get-PSMutantRewrittenManifest -ManifestText '@{ ModuleVersion = ''1.0.0'' }' -Notes 'x' } |
            Should-Throw
    }
}

Describe 'Get-PSMutantManifestNotesFault' {
    It 'says nothing when the manifest already matches' {
        Get-PSMutantManifestNotesFault -Actual 'same' -Expected 'same' | Should-BeNull
    }
    It 'ignores line-ending style, which git rewrites on checkout' {
        # The same commit reads LF on a Linux runner and CRLF on a Windows one, because
        # core.autocrlf rewrites newlines inside the stored string. Comparing exactly made
        # this gate pass in CI and fail on a maintainer's machine -- a gate reporting on the
        # checkout rather than on the content.
        Get-PSMutantManifestNotesFault -Actual "one`r`ntwo" -Expected "one`ntwo" | Should-BeNull
    }
    It 'still catches a real difference that is not just newlines' {
        # Paired with the case above: normalising must not turn the check into a no-op.
        Get-PSMutantManifestNotesFault -Actual "one`r`ntwo" -Expected "one`nthree" |
            Should-BeLikeString '*-Apply*'
    }
    It 'names the fix when they differ' {
        # Paired with the case above: a fault function that always returns a string would
        # fail every release, and one that never does would catch none.
        Get-PSMutantManifestNotesFault -Actual 'stale' -Expected 'fresh' |
            Should-BeLikeString '*-Apply*'
    }
}

Describe 'Get-PSMutantRewrittenManifest' {
    # This function had NO tests, which is how #171 shipped: a pattern that reads correctly
    # against a manifest whose ReleaseNotes hold no apostrophe, and corrupts the file the
    # moment they do. The corruption only appears on the SECOND -Apply, because it is the
    # value written by the first that arms it.
    BeforeAll {
        $script:Shell = @"
@{
    ModuleVersion = '0.4.0'
    PrivateData = @{
        PSData = @{
            ReleaseNotes = 'PLACEHOLDER'
            Tags = @('mutation')
        }
    }
}
"@
        function Test-ManifestSyntax {
            param([string]$Text)
            $e = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$e)
            return @($e).Count -eq 0
        }
        function Get-NotesFromManifest {
            param([string]$Text)
            $f = Join-Path $TestDrive "m-$([guid]::NewGuid().ToString('N')).psd1"
            Set-Content -Path $f -Value $Text -Encoding utf8
            return [string](Import-PowerShellDataFile $f).PrivateData.PSData.ReleaseNotes
        }
    }

    # Each of the three below rewrites the manifest TWICE, and that is the whole point rather
    # than thoroughness. A single rewrite over a pristine manifest passes with the broken
    # pattern too, because the old value holds no doubled quote to trip it -- verified by
    # reverting the fix, where a one-shot version of these tests stayed green. It is the value
    # the FIRST write leaves behind that arms the second.

    It 'survives a re-apply when the notes put a quoted word before a brace' {
        # `{ 'one' }` escapes to `{ ''one'' }`, and the second quote of that pair followed by
        # ` }` satisfied the old `(?=\s*(\r?\n|\}))`. The match ended INSIDE the stored value,
        # the new one was spliced in there, and the tail survived as bare tokens.
        $notes = "forcing 1 { 'one' } is the case"
        $once = Get-PSMutantRewrittenManifest -ManifestText $script:Shell -Notes $notes
        $twice = Get-PSMutantRewrittenManifest -ManifestText $once -Notes $notes
        Test-ManifestSyntax -Text $twice | Should-BeTrue
        Get-NotesFromManifest -Text $twice | Should-Be $notes
    }

    It 'survives a re-apply when the notes end a LINE with a quoted word' {
        # The other half of the same trigger, and the likelier one in ordinary prose: a phrase
        # like `'strict'` closing a line escapes to `''strict''` followed by a newline, which
        # satisfied the other arm of that lookahead.
        $notes = "the mode is called 'strict'`nand the next line follows"
        $once = Get-PSMutantRewrittenManifest -ManifestText $script:Shell -Notes $notes
        $twice = Get-PSMutantRewrittenManifest -ManifestText $once -Notes $notes
        Test-ManifestSyntax -Text $twice | Should-BeTrue
        Get-NotesFromManifest -Text $twice | Should-Be $notes
    }

    It 'is idempotent, not merely parseable, on a re-apply' {
        # Parsing is the floor, not the bar. A pattern could recover a valid manifest while
        # still having replaced the wrong span, so pin that the second write is a no-op.
        $notes = "forcing 1 { 'one' } is the case"
        $once = Get-PSMutantRewrittenManifest -ManifestText $script:Shell -Notes $notes
        Get-PSMutantRewrittenManifest -ManifestText $once -Notes $notes | Should-Be $once
    }

    It 'replaces only the ReleaseNotes value and leaves the rest of the manifest alone' {
        $out = Get-PSMutantRewrittenManifest -ManifestText $script:Shell -Notes 'plain'
        $out | Should-BeLikeString "*ModuleVersion = '0.4.0'*"
        $out | Should-BeLikeString "*Tags = @('mutation')*"
    }

    It 'throws when there is no single-quoted ReleaseNotes value to replace' {
        { Get-PSMutantRewrittenManifest -ManifestText '@{ ModuleVersion = "1.0" }' -Notes 'x' } |
            Should-Throw -ExceptionMessage '*no single-quoted ReleaseNotes value*'
    }
}

Describe 'Get-PSMutantStaleVersionFault' {
    It 'says nothing when the version has not shipped' -ForEach @(
        @{ Unreleased = $true }
        @{ Unreleased = $false }
    ) {
        # A version not yet on the gallery is a release being prepared, whatever is under
        # Unreleased. Both cases, because a rule that fired on one of them would be a rule
        # about Unreleased wearing a gallery check's name.
        Should-BeNull -Actual (Get-PSMutantStaleVersionFault -ModuleVersion '9.9.9' `
                -IsPublished $false -HasUnreleasedContent $Unreleased)
    }

    It 'says nothing when a published version has no unreleased work above it' {
        # The resting state between releases, and by far the most common one. A gate that
        # failed here would fail on every ordinary day and be muted within a week.
        Should-BeNull -Actual (Get-PSMutantStaleVersionFault -ModuleVersion '0.4.0' `
                -IsPublished $true -HasUnreleasedContent $false)
    }

    It 'reports the pair: shipped AND carrying unreleased work' {
        # The real 0.3.1: main carried two merged bug fixes at a version already on the
        # gallery, and every other gate passed, because they all ask whether the manifest,
        # the newest heading and ReleaseNotes agree with EACH OTHER.
        $fault = Get-PSMutantStaleVersionFault -ModuleVersion '0.3.1' `
            -IsPublished $true -HasUnreleasedContent $true
        $fault | Should-MatchString 'already on the gallery'
        # The consequence, not just the condition: the message has to say why it matters, or
        # the obvious fix looks like deleting the Unreleased heading.
        $fault | Should-MatchString 'different code'
        $fault | Should-MatchString '0.3.1'
    }
}
