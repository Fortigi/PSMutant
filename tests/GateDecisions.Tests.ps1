# Unit tests for the CI gates' pass/fail decisions (tools/GateDecisions.ps1).
#
# These exist because tools/ was the only code in the project that nothing examined -- the
# scripts asserting "100% coverage" and "Pester >= 5 works" had no tests, no coverage and no
# mutants (#27). The failure they guard against is a gate that stops being able to fail: an
# inverted comparison or a lowered default, after which the build stays green while the
# number it prints becomes fiction.
#
# Only the DECISIONS are tested. The orchestration around them -- running Pester, staging a
# package, spawning a child process -- is side effects end to end, and is exercised by
# actually running the gates in CI.

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools' -AdditionalChildPath 'GateDecisions.ps1')
}

Describe 'Get-PSMutantLintFault' {
    It 'passes a run that found nothing' {
        Should-BeNull -Actual (Get-PSMutantLintFault -FindingCount 0)
    }

    It 'fails on a single finding' {
        # One, not many: severity plays no part and no -Severity filter reaches the analyzer, so
        # anything reported at all is a rule somebody decided to keep. A gate that needed two
        # would let every lone Information-severity finding through -- which is the band that
        # was invisible to this gate before the two workflows were made to share one script.
        Get-PSMutantLintFault -FindingCount 1 | Should-BeLikeString '*lint gate failed*'
    }

    It 'says how many it found' {
        # The count reaches the message. A gate that reports a failure without a number sends
        # the reader back to run it again to find out how much work it is.
        Get-PSMutantLintFault -FindingCount 7 | Should-BeLikeString '*7 PSScriptAnalyzer finding*'
    }
}

Describe 'Get-PSMutantCoverageFailure' {
    It 'passes coverage that meets the minimum exactly' {
        # The boundary, and the case the gate exists to allow: 100 against a required 100.
        # `-lt` not `-le`, or the target would be unmeetable and the gate unmeetable with it.
        Should-BeNull -Actual (Get-PSMutantCoverageFailure -Percent 100 -Minimum 100)
    }

    It 'fails coverage a hair below the minimum' {
        # A hair, not a landslide: an off-by-one in the comparison shows up here and nowhere
        # else, because any wider gap passes under either operator.
        Get-PSMutantCoverageFailure -Percent 99.99 -Minimum 100 |
            Should-BeLikeString '*below the required*'
    }

    It 'passes coverage above the minimum' {
        Should-BeNull -Actual (Get-PSMutantCoverageFailure -Percent 100 -Minimum 90)
    }

    It 'rejects a red suite before it looks at the percentage' {
        # Lines are still executed on the way to a failure, so a broken build can measure
        # 100%. Reporting that number is worse than reporting nothing, so the test count is
        # checked first -- note the percentage here would otherwise pass.
        Get-PSMutantCoverageFailure -Percent 100 -Minimum 100 -FailedTestCount 1 |
            Should-BeLikeString '*test(s) failed*'
    }
}

Describe 'Get-PSMutantMutationFailure' {
    It 'accepts a run with both kills and survivors' {
        # The shape both gates' fixtures are built to produce.
        Should-BeNull -Actual (Get-PSMutantMutationFailure -Total 3 -Killed 1 -Survived 2)
    }

    It 'rejects a run where everything was killed' {
        # THE #16 failure. A child runspace that cannot start produces silence, and silence
        # used to be scored as a kill -- a perfect, entirely fake result. Against a fixture
        # whose covering test is deliberately weak, all-killed is broken, not excellent.
        Get-PSMutantMutationFailure -Total 3 -Killed 3 -Survived 0 |
            Should-BeLikeString '*every mutant killed*'
    }

    It 'rejects a run where nothing was killed' {
        # The opposite failure, and it must not be mistaken for the one above: the covering
        # tests never ran at all.
        Get-PSMutantMutationFailure -Total 3 -Killed 0 -Survived 3 |
            Should-BeLikeString '*killed nothing*'
    }

    It 'rejects a run that evaluated no mutants' {
        # A vacuous pass: with no mutants, "nothing survived" is trivially true, so this has
        # to be caught before the survivor check.
        Get-PSMutantMutationFailure -Total 0 -Killed 0 -Survived 0 |
            Should-BeLikeString '*no mutants*'
    }

    It 'names the subject so two gates can share one message' {
        Get-PSMutantMutationFailure -Total 0 -Killed 0 -Survived 0 -Subject 'The staged package' |
            Should-BeLikeString 'The staged package*'
    }
}

Describe 'Get-PSMutantUnloadedFile' {
    It 'names a shipped file the root module never dot-sources' {
        # The realistic packaging failure: Copy-Item -Recurse ships it, the explicit load
        # list does not mention it, and the package imports cleanly while missing functions.
        $psm1 = ". (Join-Path `$src 'PSMutation.Operators.ps1')"
        @(Get-PSMutantUnloadedFile -RootModuleText $psm1 -ShippedName @('PSMutation.Operators.ps1', 'PSMutation.Orphan.ps1')) |
            Should-BeCollection @('PSMutation.Orphan.ps1')
    }

    It 'returns nothing when every shipped file is loaded' {
        $psm1 = "'PSMutation.Operators.ps1', 'PSMutation.Report.ps1'"
        @(Get-PSMutantUnloadedFile -RootModuleText $psm1 -ShippedName @('PSMutation.Operators.ps1', 'PSMutation.Report.ps1')) |
            Should-BeCollection -Count 0
    }

    It 'accepts an empty shipped list without deciding anything' {
        @(Get-PSMutantUnloadedFile -RootModuleText 'anything' -ShippedName @()) |
            Should-BeCollection -Count 0
    }

    It 'treats a file name as a literal, not as a pattern' {
        # File names contain dots, which are regex wildcards. Without escaping,
        # "PSMutationXOperators.ps1" would satisfy a search for "PSMutation.Operators.ps1"
        # and an unloaded file would go unreported.
        $psm1 = "'PSMutationXOperatorsYps1'"
        @(Get-PSMutantUnloadedFile -RootModuleText $psm1 -ShippedName @('PSMutation.Operators.ps1')) |
            Should-BeCollection @('PSMutation.Operators.ps1')
    }
}

Describe 'Get-PSMutantPinValue' {
    BeforeAll {
        # Shaped like the real .github/pins.env: comments, blank lines, a value containing
        # spaces, and keys that are prefixes of one another.
        $script:pins = @(
            '# Single source of truth for the pinned dependencies.'
            ''
            'PESTER_VERSION=6.1.0'
            '  # indented comment'
            'PSSA_PATHS=./src ./tests ./tools ./PSMutant.psm1 ./PSMutant.psd1'
            'PSSA_VERSION=1.25.0'
            'PSSA_VERSION_EXTRA=should-not-be-found-as-PSSA_VERSION'
        )
    }

    It 'reads a simple value' {
        Get-PSMutantPinValue -Line $script:pins -Name 'PESTER_VERSION' | Should-Be '6.1.0'
    }

    It 'keeps the spaces in a space-separated value' {
        # PSSA_PATHS is a list. A parser that split on whitespace, or trimmed too eagerly,
        # would hand the analyzer one path or none -- and a gate that scans nothing passes.
        Get-PSMutantPinValue -Line $script:pins -Name 'PSSA_PATHS' |
            Should-Be './src ./tests ./tools ./PSMutant.psm1 ./PSMutant.psd1'
    }

    It 'matches the key in full, not as a prefix' {
        # PSSA_VERSION and PSSA_VERSION_EXTRA both start the same way. A prefix match would
        # silently pin the analyzer to whichever line came first.
        Get-PSMutantPinValue -Line $script:pins -Name 'PSSA_VERSION' | Should-Be '1.25.0'
    }

    It 'splits on the first = only, so a value may contain one' {
        Get-PSMutantPinValue -Line @('K=a=b') -Name 'K' | Should-Be 'a=b'
    }

    It 'ignores comment lines even when they mention the key' {
        Should-BeNull -Actual (Get-PSMutantPinValue -Line @('# PESTER_VERSION=9.9.9') -Name 'PESTER_VERSION')
    }

    It 'returns nothing for a key that is not there' {
        # The caller turns this into an error naming the key. It has to be distinguishable
        # from an empty value, or a missing pin reads as a deliberate blank.
        Should-BeNull -Actual (Get-PSMutantPinValue -Line $script:pins -Name 'NO_SUCH_PIN')
    }

    It 'returns nothing for an empty file' {
        Should-BeNull -Actual (Get-PSMutantPinValue -Line @() -Name 'PESTER_VERSION')
    }

    It 'ignores a line with no = at all' {
        Should-BeNull -Actual (Get-PSMutantPinValue -Line @('PESTER_VERSION') -Name 'PESTER_VERSION')
    }

    It 'trims surrounding whitespace from the value' {
        Get-PSMutantPinValue -Line @('K=  v  ') -Name 'K' | Should-Be 'v'
    }

    It 'reads the real pins.env this repo ships' {
        # The end-to-end check: the parser and the actual file agree. A format change to
        # pins.env that this parser cannot read would otherwise only show up in CI.
        $real = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '.github' -AdditionalChildPath 'pins.env'
        Get-PSMutantPinValue -Line (Get-Content $real) -Name 'PSSA_PATHS' | Should-BeLikeString '*./src*'
        Should-NotBeNull -Actual (Get-PSMutantPinValue -Line (Get-Content $real) -Name 'PSSA_VERSION')
    }
}

Describe 'Get-PSMutantTestRunFault' {
    It 'says nothing about a run where every container passed' {
        Get-PSMutantTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Passed') -ContainerName @('a', 'b') |
            Should-BeNull
    }

    It 'catches a file that never ran, which FailedCount cannot see' {
        # The whole point. A test file with a parse error contributes zero tests AND zero
        # failures, so every gate asking only about the failure count reports green over a
        # suite that is missing an entire file.
        Get-PSMutantTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Failed') -ContainerName @('ok.Tests.ps1', 'broken.Tests.ps1') |
            Should-BeLikeString '*broken.Tests.ps1*'
    }

    It 'reports failing tests FIRST when there are both' {
        # A genuinely failing test marks its container 'Failed' as well, so both conditions
        # hold. "3 tests failed" points the reader somewhere better than "a file did not run".
        Get-PSMutantTestRunFault -FailedCount 3 -ContainerResult @('Failed') -ContainerName @('a.Tests.ps1') |
            Should-BeLikeString '*3 test(s) failed*'
    }

    It 'allows a deliberately skipped container' {
        # Paired with the catch above: treating every non-Passed result as a fault would
        # fail the build on a legitimate -Skip, and the fix for that would be to delete the
        # check entirely.
        Get-PSMutantTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Skipped') -ContainerName @('a', 'b') |
            Should-BeNull
    }

    It 'names every unrun file rather than only the first' {
        Get-PSMutantTestRunFault -FailedCount 0 -ContainerResult @('Failed', 'Failed') -ContainerName @('x.Tests.ps1', 'y.Tests.ps1') |
            Should-BeLikeString '*x.Tests.ps1, y.Tests.ps1*'
    }
}

Describe 'Get-PSMutantProcessStateFault' {
    It 'says nothing about a run that put everything back' {
        Get-PSMutantProcessStateFault -Before @{ 'env:PATH' = '/usr/bin'; 'env:HOME' = '/home/x' } `
            -After @{ 'env:PATH' = '/usr/bin'; 'env:HOME' = '/home/x' } | Should-BeNull
    }

    It 'says nothing when there was nothing to compare' {
        # Paired with the case above rather than left out: an empty environment must read as
        # clean, not as every variable having been removed.
        Get-PSMutantProcessStateFault -Before @{} -After @{} | Should-BeNull
    }

    It 'names a variable the run added' {
        Get-PSMutantProcessStateFault -Before @{} -After @{ 'env:PSMUT_LEAK' = '1' } |
            Should-BeLikeString '*added: env:PSMUT_LEAK*'
    }

    It 'names a variable the run removed' {
        # This repo's actual failure: Output.Tests.ps1 cleared GITHUB_ACTIONS in an AfterEach and
        # never put it back, so every file after it ran in a different environment.
        Get-PSMutantProcessStateFault -Before @{ 'env:GITHUB_ACTIONS' = 'true' } -After @{} |
            Should-BeLikeString '*removed: env:GITHUB_ACTIONS*'
    }

    It 'names a variable the run changed' {
        Get-PSMutantProcessStateFault -Before @{ 'env:TERM' = 'xterm' } -After @{ 'env:TERM' = 'dumb' } |
            Should-BeLikeString '*changed: env:TERM*'
    }

    It 'treats a change of CASE as a change' {
        # The comparison is -cne, not -ne. A case-insensitive compare calls 'true' and 'True'
        # equal, and a variable read case-sensitively downstream is then reported as untouched.
        # The one input that tells the two operators apart.
        Get-PSMutantProcessStateFault -Before @{ 'env:CI' = 'true' } -After @{ 'env:CI' = 'TRUE' } |
            Should-BeLikeString '*changed: env:CI*'
    }

    It 'withholds the values' {
        # Not tidiness. An environment variable holds tokens as often as it holds flags, and this
        # message is printed into a build log anyone can read. The key says which variable; the
        # value would say what it was.
        $fault = Get-PSMutantProcessStateFault -Before @{ 'env:TOKEN' = 'ghp_secret' } `
            -After @{ 'env:TOKEN' = 'ghp_other' }
        $fault | Should-BeLikeString '*env:TOKEN*'
        $fault | Should-NotBeLikeString '*ghp_secret*'
        $fault | Should-NotBeLikeString '*ghp_other*'
    }

    It 'reports all three kinds at once, and every key in each' {
        # One fault per run, so a message that stopped at the first kind would send the reader
        # back for another round per variable.
        $fault = Get-PSMutantProcessStateFault `
            -Before @{ 'env:GONE_A' = '1'; 'env:GONE_B' = '1'; 'env:SAME' = 'x'; 'env:MOVED' = 'x' } `
            -After @{ 'env:SAME' = 'x'; 'env:MOVED' = 'y'; 'env:NEW' = '1' }
        $fault | Should-BeLikeString '*added: env:NEW*'
        $fault | Should-BeLikeString '*removed: env:GONE_A, env:GONE_B*'
        $fault | Should-BeLikeString '*changed: env:MOVED*'
        $fault | Should-NotBeLikeString '*env:SAME*'
    }
}

Describe 'a pin is watched, not just written down' {
    # A pin is a decision that was correct on the day it was made. Nothing watched them, and
    # the failure is asymmetric: a stale pin never breaks the build, it just quietly stops
    # protecting you. The sibling repo's pin on THIS module sat at 0.1.0 across two majors --
    # one of which fixed a bug that scored every mutant killed -- and its CI stayed green.

    It 'reports a pin the gallery has moved past' {
        Get-PSMutantStalePinFault -Name 'Pester' -Pinned '5.0.0' -Latest '6.1.0' |
            Should-MatchString ([regex]::Escape('6.1.0 is available'))
    }

    It 'says nothing when the pin is the newest release' {
        # First kept case: a checker that faulted on every pin would pass the test above and
        # file an issue every week about nothing.
        Should-BeNull -Actual (Get-PSMutantStalePinFault -Name 'Pester' -Pinned '6.1.0' -Latest '6.1.0')
    }

    It 'says nothing when the pin is ahead of the gallery' {
        # Compared as versions, not strings: as text, 6.1.0 sorts after 10.0.0. A prerelease
        # or a yanked version leaves a pin ahead, and calling that stale would send someone to
        # downgrade.
        Should-BeNull -Actual (Get-PSMutantStalePinFault -Name 'Pester' -Pinned '10.0.0' -Latest '6.1.0')
    }

    It 'reports an unreachable gallery as unknown, not as current' {
        # The case that decides whether this is worth having. Find-Module returns nothing both
        # when a module is current and when the gallery cannot be reached, so treating them
        # alike would make every run report all-clear -- a watcher that has silently stopped
        # being able to fail, which is the very shape it was built to catch.
        Get-PSMutantStalePinFault -Name 'Pester' -Pinned '6.1.0' -Latest '' |
            Should-MatchString 'freshness is unknown'
    }
}

Describe 'the compatibility pin is judged on difference, not freshness' {
    # "Is there a newer version" is the WRONG QUESTION here, and asking it was a real mistake:
    # the first version of the watcher reported 5.8.0 as stale against 6.1.0. Taking that
    # advice would have made the compatibility guard run under the same Pester as the suite --
    # proving nothing about the manifest's >= 5.0.0 promise, while looking more up to date.

    It 'refuses a compat pin equal to the estate pin' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion '6.1.0' |
            Should-MatchString 'prove nothing'
    }

    It 'refuses a compat pin NEWER than the estate pin' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion '7.0.0' |
            Should-MatchString ([regex]::Escape('is newer than'))
    }

    It 'accepts a compat pin that is deliberately older' {
        # The kept case, and the configuration this repo actually ships: 5.8.0 against 6.1.0.
        Should-BeNull -Actual (Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion '5.8.0')
    }

    It 'refuses either pin being absent' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion '' |
            Should-MatchString 'must both be set'
    }
}
