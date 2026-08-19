# Unit tests for config resolution -- the "what did the user ask for, and what do we
# do when they didn't say" decisions. These lived inside Invoke-PSMutation, past the
# nested Pester run that destroys the outer run's coverage breakpoints, so they could
# not be measured there. Out here they are ordinary pure functions.
#
# Resolvers only. The baseline guard and the public result shape were tested here while
# they lived in Config.ps1; they are now covered beside the baseline they judge
# (Runner.Tests.ps1) and the report contract they belong to (Report.Tests.ps1) -- #45.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Config.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Get-PSMutationSandboxPlan' {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'repo'
        $script:sb = Join-Path $TestDrive 'sandbox'
        # Two mutate files with DIFFERENT mappings, one of them naming two test files.
        # A plan that merged the entries, or kept only the last, would still look
        # right against the single-file config every other fixture here uses.
        $script:cfg = [pscustomobject]@{
            mutate = @('src/a.ps1', 'src/b.ps1')
            tests  = [pscustomobject]@{
                'src/a.ps1' = @('tests/a.Tests.ps1')
                'src/b.ps1' = @('tests/b1.Tests.ps1', 'tests/b2.Tests.ps1')
            }
        }
        $script:plan = Get-PSMutationSandboxPlan -Cfg $script:cfg -SourceRoot $script:root -SandboxRoot $script:sb
    }

    It 'points every mutate path at the sandbox copy, never the tracked file' {
        # The headline guarantee of the tool. Hand back repo paths and the runner
        # splices mutants into tracked source, so a hard kill mid-run leaves a
        # mutated file staged in git.
        $expected = @('src/a.ps1', 'src/b.ps1') |
            ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $script:sb $_)) }
        $script:plan.Mutate | Should-BeCollection $expected
        $script:plan.Mutate | Should-NotContainCollection ([System.IO.Path]::GetFullPath((Join-Path $script:root 'src/a.ps1')))
    }

    It 'keys the per-file test map by the SANDBOXED source path' {
        # Invoke-PSMutationLoop looks the mapping up by the candidate's file, which is
        # a sandbox path. Keyed by repo path every lookup misses, every file falls
        # back to the whole suite, and a run that should take minutes takes hours --
        # while still reporting the right score, so nothing looks wrong.
        $keyA = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/a.ps1'))
        $keyB = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/b.ps1'))
        $script:plan.TestsByFile.Keys | Should-ContainCollection $keyA
        $script:plan.TestsByFile[$keyA] |
            Should-BeCollection @([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/a.Tests.ps1')))
        $script:plan.TestsByFile[$keyB] | Should-BeCollection -Count 2
    }

    It 'gathers every mapped test file into AllTests' {
        # AllTests is what the baseline runs. Drop one and the lines it covers are
        # never recorded, so with coveredLinesOnly on that source file yields no
        # candidates at all -- a vacuous 100% over code nothing mutated.
        $script:plan.AllTests | Should-BeCollection -Count 3
        $script:plan.AllTests |
            Should-ContainCollection ([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/b2.Tests.ps1')))
    }

    It 'accepts a single covering test written as a bare string' {
        # ConvertFrom-Json yields a bare string rather than a one-element array when
        # the config names exactly one test, which is the common case.
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1')
            tests  = [pscustomobject]@{ 'src/a.ps1' = 'tests/a.Tests.ps1' }
        }
        $plan = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $script:root -SandboxRoot $script:sb
        $key = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/a.ps1'))
        $plan.TestsByFile[$key] |
            Should-BeCollection @([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/a.Tests.ps1')))
        $plan.AllTests | Should-BeCollection -Count 1
    }
}

Describe 'Get-PSMutationSubtree' {
    It 'uses the subtrees the config names' {
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = @('lib', 'spec') }) |
            Should-BeCollection @('lib', 'spec')
    }
    It 'falls back to the module convention when the config is silent' {
        # A consuming repo whose layout is src/ + tests/ should not have to say so.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{}) | Should-BeCollection @('src', 'tests')
    }
    It 'wraps a single subtree as a list' {
        # JSON gives a bare string for a one-element array; the caller indexes it.
        Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = 'onlysrc' }) |
            Should-BeCollection @('onlysrc')
    }
}

Describe 'Get-PSMutationTimeout' {
    It 'scales the budget with the baseline duration' {
        # 10s baseline x the default factor of 4.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 10 | Should-Be 40
    }

    It 'never drops below the floor, however fast the baseline is' {
        # THE case this floor exists for. A 0.2s suite x 4 is under a second; as an
        # int budget that is 0, every mutant is cut off on time rather than on
        # behaviour, and the run reports a perfect score against tests that never
        # finished. The floor is what stops a fast suite scoring 100% for free.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{}) -BaselineSeconds 0.2 | Should-Be 15
    }

    It 'honours a configured factor and floor' {
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFactor = 10 }) -BaselineSeconds 10 | Should-Be 100
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 60 }) -BaselineSeconds 1 | Should-Be 60
    }

    It 'takes whichever of floor and scaled-baseline is larger' {
        # Both configured, so neither default can mask a wrong comparison: the floor
        # wins for a quick baseline and the scaled value wins for a slow one.
        $cfg = [pscustomobject]@{ timeoutFactor = 2; timeoutFloorSeconds = 30 }
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 5   | Should-Be 30   # floor
        Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 100 | Should-Be 200  # scaled
    }

    It 'returns whole seconds' {
        # The value is handed to a job timeout that expects an int.
        $t = Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFloorSeconds = 1 }) -BaselineSeconds 2.6
        $t | Should-HaveType ([int])
        $t | Should-Be 10
    }
}

Describe 'Get-PSMutationEditDistance' {
    # A table rather than one case per It: every arithmetic constant in the DP is a mutant,
    # and only a spread of exact distances tells a correct +1 from a +2.
    It 'measures <From> against <To> as <Expected>' -ForEach @(
        @{ From = 'mutate'; To = 'mutate';  Expected = 0 }   # identical
        @{ From = '';       To = 'abc';     Expected = 3 }   # pure insertion, and the empty-left path
        @{ From = 'abc';    To = '';        Expected = 3 }   # pure deletion, and the empty-right path
        @{ From = '';       To = '';        Expected = 0 }
        @{ From = 'mutat';  To = 'mutate';  Expected = 1 }   # the dropped letter from #24
        @{ From = 'brake';  To = 'break';   Expected = 2 }   # the transposition from #24
        @{ From = 'break';  To = 'brake';   Expected = 2 }   # symmetric, so neither side is privileged
        @{ From = 'kitten'; To = 'sitting'; Expected = 3 }   # the textbook case
    ) {
        Get-PSMutationEditDistance -From $From -To $To | Should-Be $Expected
    }
}

Describe 'Get-PSMutationNearestName' {
    It 'suggests the key a transposition came from' {
        # `brake` for `break` is THE motivating typo: it makes the break gate unable to
        # fail, and the two differ by a transposition, which costs two edits.
        Get-PSMutationNearestName -Name 'brake' -Candidates @('high', 'low', 'break') | Should-Be 'break'
    }

    It 'suggests the key a dropped letter came from' {
        Get-PSMutationNearestName -Name 'mutat' -Candidates @('mutate', 'tests') | Should-Be 'mutate'
    }

    It 'suggests nothing when nothing is close' {
        # A wrong guess is worse than none: it sends the reader off to change a key that
        # was never the problem. Three edits is already a different word.
        Should-BeNull -Actual (Get-PSMutationNearestName -Name 'zzzzzz' -Candidates @('mutate', 'tests'))
    }

    It 'prefers the closer of two plausible candidates' {
        # Discriminates "returns the first thing within range" from "returns the nearest".
        Get-PSMutationNearestName -Name 'tent' -Candidates @('tests', 'test') | Should-Be 'test'
    }

    It 'ignores case when matching' {
        Get-PSMutationNearestName -Name 'Mutate' -Candidates @('mutate', 'tests') | Should-Be 'mutate'
    }

    It 'suggests nothing at exactly the cutoff, so "near" stays near' {
        # kitten/sitting is three edits. Three is the first distance that must NOT produce
        # a suggestion, and it is the only input that tells `-lt 3` from `-le 3` or from a
        # cutoff of 4 -- every closer pair passes under all three.
        Should-BeNull -Actual (Get-PSMutationNearestName -Name 'kitten' -Candidates @('sitting'))
    }

    It 'suggests nothing when there are no candidates at all' {
        Should-BeNull -Actual (Get-PSMutationNearestName -Name 'mutate' -Candidates @())
    }
}

Describe 'Get-PSMutationUnknownKeyMessage' {
    It 'accepts a key that is known' {
        Should-BeNull -Actual (Get-PSMutationUnknownKeyMessage -Name 'mutate' -Known @('mutate', 'tests') -Where 'config')
    }

    It 'accepts an underscore-prefixed key as a comment' {
        # JSON has no comments. Both examples/psmutant.config.json and this repo's own
        # config use _comment / _operators / _timeout, so rejecting them would make the
        # validator reject the configs it ships with.
        Should-BeNull -Actual (Get-PSMutationUnknownKeyMessage -Name '_comment' -Known @('mutate') -Where 'config')
    }

    It 'rejects an unknown key, naming it, the suggestion and the valid set' {
        $why = Get-PSMutationUnknownKeyMessage -Name 'brake' -Known @('high', 'low', 'break') -Where 'thresholds'
        $why | Should-BeLikeString "*thresholds key 'brake'*"
        $why | Should-BeLikeString "*Did you mean 'break'?*"
        # The valid set matters as much as the suggestion: it is what makes the message
        # actionable when there is no near match to offer.
        $why | Should-BeLikeString '*break, high, low*'
    }

    It 'omits the suggestion when nothing is near, rather than guessing' {
        $why = Get-PSMutationUnknownKeyMessage -Name 'zzzzzz' -Known @('mutate') -Where 'config'
        $why | Should-BeLikeString "*config key 'zzzzzz'*"
        $why | Should-NotBeLikeString '*Did you mean*'
    }
}

Describe 'Assert-PSMutationConfig' {
    BeforeAll {
        # The smallest config that must pass. Tests below take this and break one thing,
        # so anything that fails is attributable to the change rather than the fixture.
        $script:valid = '{ "mutate": ["src/a.ps1"], "tests": { "src/a.ps1": ["tests/a.Tests.ps1"] } }'
    }

    It 'accepts a minimal valid config' {
        Assert-PSMutationConfig -Cfg ($script:valid | ConvertFrom-Json)
    }

    It 'accepts every key the README documents' {
        # Pairs with the rejection tests below: without a config exercising the whole key
        # set, a validator that rejected a legitimate key would still look correct.
        $all = '{ "mutate": ["a"], "tests": { "a": ["t"] }, "operators": ["BinaryOperator"],
                  "coveredLinesOnly": true, "sandboxSubtrees": ["src"], "timeoutFactor": 4,
                  "timeoutFloorSeconds": 15, "equivalents": {}, "reportPath": "r.json",
                  "thresholds": { "high": 85, "low": 70, "break": 100 } }'
        Assert-PSMutationConfig -Cfg ($all | ConvertFrom-Json)
    }

    It 'refuses thresholds.brake, which otherwise makes the gate unable to fail' {
        # The sharpest case in #24. Get-PSMutationExitCode reads $Thresholds.break, so
        # `brake` returns exit 0 for a run with survivors -- a gate that can never fail,
        # and nothing said so.
        { Assert-PSMutationConfig -Cfg ('{ "mutate": ["a"], "tests": { "a": ["t"] }, "thresholds": { "brake": 100 } }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*thresholds key 'brake'*Did you mean 'break'?*"
    }

    It 'refuses a misspelled top-level key, which otherwise fails somewhere unrelated' {
        # `mutat` used to surface as "Access to the path '...psmut-sandbox-16372' is
        # denied", which mentions neither the config nor the key.
        { Assert-PSMutationConfig -Cfg ('{ "mutat": ["a"], "tests": { "a": ["t"] } }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*config key 'mutat'*Did you mean 'mutate'?*"
    }

    It 'refuses a misspelled operator, which otherwise restores the vacuous score' {
        # The case that defeats #5: opt into ConditionForcing, misspell it, and the old
        # score comes back while the report records an operator that never ran.
        { Assert-PSMutationConfig -Cfg ('{ "mutate": ["a"], "tests": { "a": ["t"] }, "operators": ["ConditionForceing"] }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*operators key 'ConditionForceing'*Did you mean 'ConditionForcing'?*"
    }

    It 'refuses a config with no mutate list' {
        { Assert-PSMutationConfig -Cfg ('{ "tests": { "a": ["t"] } }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*'mutate'*"
    }

    It 'refuses a mutate list that is present but empty' {
        # Distinct from the missing case: an empty list parses fine and produces a run
        # that evaluates nothing and scores a vacuous 100%.
        { Assert-PSMutationConfig -Cfg ('{ "mutate": [], "tests": { "a": ["t"] } }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*'mutate'*"
    }

    It 'refuses a config with no tests map' {
        { Assert-PSMutationConfig -Cfg ('{ "mutate": ["a"] }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*'tests'*"
    }

    It 'refuses a tests map that is present but empty' {
        { Assert-PSMutationConfig -Cfg ('{ "mutate": ["a"], "tests": {} }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*'tests'*"
    }

    It 'accepts a config carrying underscore comment keys, as the shipped ones do' {
        # Kept inline rather than reading psmutant.self.config.json from the repo root:
        # the self-mutation sandbox copies only src/ and tests/, so a covering suite that
        # reaches outside them turns the baseline red. The real files are validated in
        # EndToEnd.Tests.ps1, which already imports the manifest and is deliberately not
        # a covering suite.
        $commented = '{ "_comment": "why", "_operators": "note", "mutate": ["a"],
                        "tests": { "a": ["t"] }, "_equivalentsComment": "note" }'
        Assert-PSMutationConfig -Cfg ($commented | ConvertFrom-Json)
    }
}

Describe 'Get-PSMutationCoveredLinesOnly' {
    It 'defaults to true when the config omits it' {
        # The #25 defect. There was no resolver at all: the orchestrator cast the raw
        # value inline and [bool]$null is $false, so omitting the key silently opted into
        # mutating uncovered lines -- whose mutants are guaranteed survivors -- against a
        # README that has always promised true.
        Should-BeTrue -Actual (Get-PSMutationCoveredLinesOnly -Cfg ('{ "mutate": ["a"] }' | ConvertFrom-Json))
    }

    It 'honours an explicit false' {
        # Pairs with the default above: a resolver hardcoded to $true would pass that
        # test and fail this one.
        Should-BeFalse -Actual (Get-PSMutationCoveredLinesOnly -Cfg ('{ "coveredLinesOnly": false }' | ConvertFrom-Json))
    }

    It 'honours an explicit true' {
        Should-BeTrue -Actual (Get-PSMutationCoveredLinesOnly -Cfg ('{ "coveredLinesOnly": true }' | ConvertFrom-Json))
    }
}

Describe 'the defaults the README documents' {
    # Turns the README config table into a checkable claim. It has drifted twice: the table
    # said coveredLinesOnly defaulted to true when the code had no resolver at all, and
    # sandboxSubtrees to ["tools","test","setup"], a value the code never had.
    It 'defaults coveredLinesOnly to true' {
        Should-BeTrue -Actual (Get-PSMutationCoveredLinesOnly -Cfg ('{}' | ConvertFrom-Json))
    }

    It 'defaults sandboxSubtrees to src and tests' {
        Get-PSMutationSubtree -Cfg ('{}' | ConvertFrom-Json) | Should-BeCollection @('src', 'tests')
    }

    It 'defaults timeoutFactor to 4 and timeoutFloorSeconds to 15' {
        # Read off one call each: the floor wins for a fast baseline, the factor for a slow one.
        Get-PSMutationTimeout -Cfg ('{}' | ConvertFrom-Json) -BaselineSeconds 0.5 | Should-Be 15
        Get-PSMutationTimeout -Cfg ('{}' | ConvertFrom-Json) -BaselineSeconds 100 | Should-Be 400
    }

    It 'defaults the colour bands to high 85 and low 70' {
        $band = Get-PSMutationScoreBand -Cfg ('{}' | ConvertFrom-Json)
        $band.High | Should-Be 85
        $band.Low | Should-Be 70
    }

    It 'defaults operators to the four expression operators' {
        Get-PSMutationOperatorList -Cfg ('{}' | ConvertFrom-Json) |
            Should-BeCollection @('BinaryOperator', 'BooleanLiteral', 'NumberLiteral', 'NegationRemoval')
    }
}

Describe 'Get-PSMutationScoreBand' {
    It 'defaults to 85 / 70 when the config has no thresholds at all' {
        # THE #40 case. These used to be read straight into the comparison, and any number
        # `-ge $null` is $true in PowerShell, so every score printed green -- including
        # `Mutation score: 0%` in a run that exits 0.
        $band = Get-PSMutationScoreBand -Cfg ('{ "mutate": ["a"] }' | ConvertFrom-Json)
        $band.High | Should-Be 85
        $band.Low | Should-Be 70
    }

    It 'defaults both when thresholds carries only break' {
        # The realistic shape, and the one a new adopter writes first: gating configured,
        # colours not. A resolver keyed on "is thresholds present" would pass the test
        # above and fail here.
        $band = Get-PSMutationScoreBand -Cfg ('{ "thresholds": { "break": 80 } }' | ConvertFrom-Json)
        $band.High | Should-Be 85
        $band.Low | Should-Be 70
    }

    It 'honours bands the config does set' {
        $band = Get-PSMutationScoreBand -Cfg ('{ "thresholds": { "high": 95, "low": 60 } }' | ConvertFrom-Json)
        $band.High | Should-Be 95
        $band.Low | Should-Be 60
    }

    It 'honours a band of zero rather than treating it as unset' {
        # Zero is falsy, so a truthiness test -- which is what every other resolver here
        # uses -- would silently substitute 85/70 for a deliberate "never colour this red".
        $band = Get-PSMutationScoreBand -Cfg ('{ "thresholds": { "high": 0, "low": 0 } }' | ConvertFrom-Json)
        $band.High | Should-Be 0
        $band.Low | Should-Be 0
    }

    It 'resolves each band independently' {
        # Pairs a set value with an unset one in a single config: a resolver that decided
        # both from one key would still pass every test above.
        $band = Get-PSMutationScoreBand -Cfg ('{ "thresholds": { "low": 40 } }' | ConvertFrom-Json)
        $band.High | Should-Be 85
        $band.Low | Should-Be 40
    }
}
