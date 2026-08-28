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
    # protecting you. A consumer's pin on a gating module sat at 0.1.0 across two majors --
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

Describe 'the compatibility legs are judged on reach, not freshness' {
    # "Is there a newer version" is the WRONG QUESTION here, and asking it was a real mistake:
    # the first version of the watcher reported 5.8.0 as stale against 6.1.0. Taking that advice
    # would have made the compatibility guard run under the same Pester as the suite, proving
    # nothing about the range the manifest promises while looking more up to date.
    #
    # The pin became a LIST in #161, and the invariant moved with it: not "differs from the
    # estate pin" -- the newest leg legitimately IS the estate version -- but "still reaches
    # below it, and covers the declared floor".

    It 'accepts the list this repo actually ships' {
        Should-BeNull -Actual (Get-PSMutantCompatPinFault -EstateVersion '6.1.0' `
                -CompatVersion @('5.2.2', '5.3.3', '5.8.0', '6.1.0') -FloorVersion '5.2.0')
    }

    It 'refuses a list with no leg older than the estate pin' {
        # The list creeping up until every leg matches the suite's own Pester. It would pass
        # every other gate and prove nothing.
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion @('6.1.0') -FloorVersion '5.2.0' |
            Should-MatchString 'proves nothing'
    }

    It 'refuses a list that does not cover the declared floor' {
        # #161 itself: the number consumers are given was never executed. A leg has to cover the
        # floor's MINOR -- the exact patch is free to advance under the newest-patch rule.
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion @('5.8.0') -FloorVersion '5.2.0' |
            Should-MatchString 'no leg on Pester 5.2'
    }

    It 'accepts a leg on the floor MINOR with a different patch' {
        # The other half of that pair, so the test above pins "covers the minor" rather than
        # "equals the floor exactly" -- which would freeze the one leg the rule says should move.
        Should-BeNull -Actual (Get-PSMutantCompatPinFault -EstateVersion '6.1.0' `
                -CompatVersion @('5.2.9', '6.1.0') -FloorVersion '5.2.0')
    }

    It 'refuses a duplicated leg' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion @('5.2.2', '5.2.2') -FloorVersion '5.2.0' |
            Should-MatchString 'twice'
    }

    It 'refuses an empty list' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion @() -FloorVersion '5.2.0' |
            Should-MatchString 'must both be set'
    }

    It 'refuses a missing floor rather than skipping the floor check' {
        Get-PSMutantCompatPinFault -EstateVersion '6.1.0' -CompatVersion @('5.2.2') -FloorVersion '' |
            Should-MatchString 'floor is not set'
    }
}

Describe 'Get-PSMutantPesterFloor' {
    # The floor is READ from the guard that enforces it, not repeated. #161 is what happens when
    # the manifest, the README and the code each carry their own copy and nothing compares them.

    It 'reads the version the guard actually enforces' {
        Get-PSMutantPesterFloor -Line @(
            "    if (`$loaded.Version -lt [version]'5.2.0') { throw `$x }") | Should-Be '5.2.0'
    }

    It 'follows the guard when it moves, rather than pinning a number here' {
        Get-PSMutantPesterFloor -Line @(
            "    if (`$loaded.Version -lt [version]'7.9.1') { throw `$x }") | Should-Be '7.9.1'
    }

    It 'returns null when no guard is present, so the caller refuses rather than guesses' {
        Should-BeNull -Actual (Get-PSMutantPesterFloor -Line @('# nothing here', '$x = 1'))
    }
}

Describe 'the shipped pins.env is itself a claim, so it is asserted here' {
    # The gate proves whatever PESTER_COMPAT_VERSIONS names, so the LIST IS the compatibility
    # claim. A leg silently dropped narrows the promise without narrowing what the README says,
    # and the run stays green -- the shape this project refuses everywhere else.
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:pinLines = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/pins.env')
    }

    It 'declares every key the workflows require' {
        # The workflows assert this at run time; asserting it here means a missing pin fails in
        # the suite rather than five minutes into a job.
        foreach ($k in 'PESTER_VERSION', 'PESTER_COMPAT_VERSIONS', 'PSSA_VERSION',
            'PSCOMPLEXITY_VERSION', 'CONVERTTOSARIF_VERSION', 'PSSA_PATHS') {
            Get-PSMutantPinValue -Line $script:pinLines -Name $k |
                Should-NotBeNull -Because "pins.env must define $k"
        }
    }

    It 'lists a leg for every supported Pester minor, from the floor upward' {
        # Minors, not exact patches: a patch may be superseded and the pin bumped, but a whole
        # minor disappearing means a range nobody tests any more. No exact-version assertion
        # here for the same reason -- every leg is the newest patch of its minor, including the
        # floor's, so pinning one exactly would freeze the single leg the rule says should move.
        $versions = @((Get-PSMutantPinValue -Line $script:pinLines -Name 'PESTER_COMPAT_VERSIONS') -split ' ' |
                Where-Object { $_ })
        $minors = @($versions | ForEach-Object { $v = [version]$_; "$($v.Major).$($v.Minor)" })
        foreach ($m in '5.2', '5.3', '5.4', '5.5', '5.6', '5.7', '5.8', '5.9', '6.0', '6.1') {
            $minors | Should-ContainCollection $m -Because "no leg covers Pester $m"
        }
    }

    It 'starts the legs at the floor the module actually enforces' {
        # The two must agree, and #161 is what happens when they do not: the promise said 5.0.0,
        # the code needed 5.2.0, and nothing compared them. Read from the guard rather than
        # repeated, so this fails when either side moves alone.
        $floor = [version](Get-PSMutantPesterFloor -Line (
                Get-Content -LiteralPath (Join-Path $script:repoRoot 'src/PSMutation.Pester.ps1')))
        $versions = @((Get-PSMutantPinValue -Line $script:pinLines -Name 'PESTER_COMPAT_VERSIONS') -split ' ' |
                Where-Object { $_ })
        $lowest = @($versions | ForEach-Object { [version]$_ } | Sort-Object)[0]
        "$($lowest.Major).$($lowest.Minor)" | Should-Be "$($floor.Major).$($floor.Minor)"
    }

    It 'is free of a fault by its own rule' {
        # The rule is unit-tested above against fixtures; this runs it over what actually ships,
        # which is the part a fixture cannot certify.
        $floor = Get-PSMutantPesterFloor -Line (
            Get-Content -LiteralPath (Join-Path $script:repoRoot 'src/PSMutation.Pester.ps1'))
        Should-BeNull -Actual (Get-PSMutantCompatPinFault `
                -EstateVersion (Get-PSMutantPinValue -Line $script:pinLines -Name 'PESTER_VERSION') `
                -CompatVersion @((Get-PSMutantPinValue -Line $script:pinLines -Name 'PESTER_COMPAT_VERSIONS') -split ' ' |
                    Where-Object { $_ }) `
                -FloorVersion $floor)
    }
}

Describe 'the declared PowerShell floor and the legs that execute it' {
    # #157 in one rule. The manifest declared 7.2 and nothing ever ran on it; a floor nothing
    # executes is a claim, not a guarantee. This is what makes the two move together.

    It 'accepts the configuration this repo actually ships' {
        Should-BeNull -Actual (Get-PSMutantHostFloorFault -Declared '7.2' `
                -Leg @('7.2.24', '7.3.12', '7.4.19', '7.5.10'))
    }

    It 'refuses a floor no leg covers' {
        # Lowering the floor without adding its leg recreates the exact defect being closed.
        Get-PSMutantHostFloorFault -Declared '7.0' -Leg @('7.2.24', '7.4.19') |
            Should-MatchString 'no leg on PowerShell 7.0'
    }

    It 'refuses a leg BELOW the declared floor' {
        # The other direction, and it is not symmetric: such a leg either proves something nobody
        # promised, or goes red for a version consumers were told not to use.
        Get-PSMutantHostFloorFault -Declared '7.2' -Leg @('7.0.13', '7.2.24') |
            Should-MatchString 'BELOW the declared floor'
    }

    It 'covers the floor by MINOR, so the patch stays free to advance' {
        # Paired with the refusal above so this pins "the minor is covered" rather than "the patch
        # equals the floor" -- which would freeze the one leg the newest-patch rule says moves.
        Should-BeNull -Actual (Get-PSMutantHostFloorFault -Declared '7.2' -Leg @('7.2.99', '7.4.19'))
    }

    It 'refuses an empty leg list rather than passing over zero hosts' {
        Get-PSMutantHostFloorFault -Declared '7.2' -Leg @() | Should-MatchString 'zero hosts'
    }

    It 'refuses a manifest with no declared floor' {
        Get-PSMutantHostFloorFault -Declared '' -Leg @('7.2.24') | Should-MatchString 'no PowerShellVersion'
    }

    It 'holds for the manifest and pins that actually ship' {
        # The rule is unit-tested above against fixtures; this runs it over what ships, which is
        # the part a fixture cannot certify.
        $root = Split-Path -Parent $PSScriptRoot
        $declared = (Import-PowerShellDataFile (Join-Path $root 'PSMutant.psd1')).PowerShellVersion
        $legs = @((Get-PSMutantPinValue -Line (Get-Content (Join-Path $root '.github/pins.env')) `
                    -Name 'PS_COMPAT_VERSIONS') -split ' ' | Where-Object { $_ })
        Should-BeNull -Actual (Get-PSMutantHostFloorFault -Declared $declared -Leg $legs)
    }

    It 'pins a Pester for those legs, because this module cannot run without one' {
        # PSMutant DRIVES Pester, so a PowerShell leg cannot avoid choosing a version -- and
        # resolving by name takes the newest. Measured: Pester 6.1.0 fails on PowerShell 7.2 with
        # "Unable to find type [PesterConfiguration]" and works on 7.4, while its own manifest
        # claims PowerShellVersion 5.1. Unpinned, the floor leg would fail for a reason that is
        # not about this module. A gate over a module that does NOT drive Pester needs no such
        # pin; this one does, because driving Pester is what it is for.
        $root = Split-Path -Parent $PSScriptRoot
        $pinned = Get-PSMutantPinValue -Line (Get-Content (Join-Path $root '.github/pins.env')) -Name 'PS_COMPAT_PESTER'
        $pinned | Should-NotBeNull -Because 'PS_COMPAT_PESTER must name the Pester the PowerShell legs run under'
        [version]$pinned | Should-BeLessThan ([version]'6.0.0')
    }
}
