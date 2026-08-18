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
