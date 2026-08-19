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
