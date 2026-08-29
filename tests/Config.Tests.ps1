# Unit tests for config resolution -- the "what did the user ask for, and what do we do
# when they didn't say" decisions, and the validator that refuses a config asking for
# something this module does not understand.
#
# Also the covering suite for self-mutating src/PSMutation.Config.ps1 - keep it
# self-contained: the sandbox copies only src/ and tests/, so anything reaching for a file
# at the repo root proves nothing and leaves the file silently unmutated.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Operators.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Config.ps1') {
        . (Join-Path $src $f)
    }
}

Describe 'Get-PSMutationSandboxPlan' {
    BeforeAll {
        $script:planRoot = Join-Path $TestDrive 'repo'
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
        $script:plan = Get-PSMutationSandboxPlan -Cfg $script:cfg -SourceRoot $script:planRoot -SandboxRoot $script:sb
    }

    It 'points every mutate path at the sandbox copy, never the tracked file' {
        # The headline guarantee of the tool. Hand back repo paths and the runner
        # splices mutants into tracked source, so a hard kill mid-run leaves a
        # mutated file staged in git.
        $expected = @('src/a.ps1', 'src/b.ps1') |
            ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $script:sb $_)) }
        $script:plan.Mutate | Should-BeCollection $expected
        $script:plan.Mutate | Should-NotContainCollection ([System.IO.Path]::GetFullPath((Join-Path $script:planRoot 'src/a.ps1')))
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
        $plan = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $script:planRoot -SandboxRoot $script:sb
        $key = [System.IO.Path]::GetFullPath((Join-Path $script:sb 'src/a.ps1'))
        $plan.TestsByFile[$key] |
            Should-BeCollection @([System.IO.Path]::GetFullPath((Join-Path $script:sb 'tests/a.Tests.ps1')))
        $plan.AllTests | Should-BeCollection -Count 1
    }
}


Describe 'Get-PSMutationSubtree' {
    BeforeAll {
        # Set HERE rather than at file level. A top-level $script: assignment runs during
        # DISCOVERY and never reaches the run phase, so this Describe was silently reading
        # whatever a sibling's BeforeAll had left in $script:tempRoot -- a fake repo under
        # TestDrive, not the temp path it names. It passed only because these assertions
        # check the FILE NAME and never the root, and it failed the moment the block was
        # run on its own.
        $script:tempRoot = [System.IO.Path]::GetTempPath()
    }
    It 'uses the subtrees the config names' {
        Get-PSMutationSubtree -SourceRoot $script:tempRoot -Cfg ([pscustomobject]@{ sandboxSubtrees = @('lib', 'spec') }) |
            Should-BeCollection @('lib', 'spec')
    }
    It 'falls back to the module convention when the config is silent' {
        # A consuming repo whose layout is src/ + tests/ should not have to say so.
        Get-PSMutationSubtree -SourceRoot $script:tempRoot -Cfg ([pscustomobject]@{}) | Should-BeCollection @('src', 'tests')
    }
    It 'wraps a single subtree as a list' {
        # JSON gives a bare string for a one-element array; the caller indexes it.
        Get-PSMutationSubtree -SourceRoot $script:tempRoot -Cfg ([pscustomobject]@{ sandboxSubtrees = 'onlysrc' }) |
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

    It 'refuses a budget the unmutated suite could not itself meet' {
        # The floor above prevents this for a DEFAULT config. Nothing prevented it for a
        # configured one: floor and factor both small resolve to 0, every mutant expires on
        # the clock, an expiry is scored as a kill, and the run reports 100% over tests that
        # never finished. Both configs below are taken from a run that did exactly that.
        $cfg = [pscustomobject]@{ timeoutFactor = 0.5; timeoutFloorSeconds = 0.5 }
        { Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 0.6 } |
            Should-Throw -ExceptionMessage '*resolves to 0s*below the 0.6s*'
    }

    It 'names both keys and the consequence when it refuses' {
        # The reader has to know which of the two numbers to change, and why a budget that
        # looks merely small is actually fatal.
        $cfg = [pscustomobject]@{ timeoutFactor = 0.001; timeoutFloorSeconds = 0.5 }
        { Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 0.6 } |
            Should-Throw -ExceptionMessage "*scored as a kill*'timeoutFloorSeconds' (currently 0.5)*'timeoutFactor' (currently 0.001)*"
    }

    It 'allows a budget exactly equal to the baseline' {
        # The boundary, and the whole difference between -lt and -le. A mutant given exactly
        # as long as the unmutated suite took is tight but not fatal; one given less is.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFactor = 1; timeoutFloorSeconds = 1 }) `
            -BaselineSeconds 30 | Should-Be 30
    }

    It 'allows a one-second budget when the baseline is faster than a second' {
        # The lower arm of the same guard, and the case that fixes its constant in place.
        # With a sub-second baseline the minimum is 1, not the baseline -- so a budget of
        # exactly 1 is allowed. Raise that minimum to 2 and this config starts being refused
        # for no reason, which is a mutant nothing else here can catch.
        Get-PSMutationTimeout -Cfg ([pscustomobject]@{ timeoutFactor = 1; timeoutFloorSeconds = 1 }) `
            -BaselineSeconds 0.5 | Should-Be 1
    }

    It 'reports the baseline to one decimal place' {
        # 0.66 rounds to 0.7 at one decimal and stays 0.66 at two, so this pins the
        # precision rather than merely the presence of a number. A message quoting
        # 0.66000000001s would be technically true and useless to read.
        $cfg = [pscustomobject]@{ timeoutFactor = 0.1; timeoutFloorSeconds = 0.1 }
        { Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 0.66 } |
            Should-Throw -ExceptionMessage '*below the 0.7s*'
    }

    It 'still gives at least one second when the baseline is faster than a second' {
        # A sub-second baseline must not license a 0s budget just because it is larger than
        # the baseline: 0 is never a budget, whatever the arithmetic says.
        $cfg = [pscustomobject]@{ timeoutFactor = 0.1; timeoutFloorSeconds = 0.1 }
        { Get-PSMutationTimeout -Cfg $cfg -BaselineSeconds 0.2 } | Should-Throw
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
    BeforeAll {
        # Set HERE rather than at file level. A top-level $script: assignment runs during
        # DISCOVERY and never reaches the run phase, so this Describe was silently reading
        # whatever a sibling's BeforeAll had left in $script:tempRoot -- a fake repo under
        # TestDrive, not the temp path it names. It passed only because these assertions
        # check the FILE NAME and never the root, and it failed the moment the block was
        # run on its own.
        $script:tempRoot = [System.IO.Path]::GetTempPath()
    }
    # Turns the README config table into a checkable claim. It has drifted twice: the table
    # said coveredLinesOnly defaulted to true when the code had no resolver at all, and
    # sandboxSubtrees to ["tools","test","setup"], a value the code never had.
    It 'defaults coveredLinesOnly to true' {
        Should-BeTrue -Actual (Get-PSMutationCoveredLinesOnly -Cfg ('{}' | ConvertFrom-Json))
    }

    It 'defaults sandboxSubtrees to src and tests' {
        Get-PSMutationSubtree -SourceRoot $script:tempRoot -Cfg ('{}' | ConvertFrom-Json) | Should-BeCollection @('src', 'tests')
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


Describe 'the schema the validator reads' {
    # Moving the config format into a data file buys one source of truth and costs a new
    # failure mode: the file can be absent. These pin that it fails LOUDLY, because a
    # validator that quietly skips when its schema is missing passes every config -- and the
    # configs it would have caught are the ones that report a number nobody measured.
    It 'looks for the schema beside src/, where the package puts it' {
        (Get-PSMutationConfigSchemaPath) | Should-BeLikeString '*schemas*config.schema.json'
    }

    It 'reads the schema once and remembers it' {
        # Not a performance assertion. The cache is the only thing standing between one file
        # read and one per config key checked, and a mutant that disables it is invisible in
        # every other test -- identical answers, quietly re-reading the file each time.
        $script:PSMutationConfigSchema = $null
        Mock Get-Content { '{ "type": "object" }' }
        Get-PSMutationConfigSchema | Out-Null
        Get-PSMutationConfigSchema | Out-Null
        Should-Invoke Get-Content -Exactly 1
    }

    It 'throws, naming the path, when the schema is not there' {
        $script:PSMutationConfigSchema = $null
        Mock Test-Path { $false } -ParameterFilter { "$Path" -like '*config.schema.json' }
        { Get-PSMutationConfigSchema } | Should-Throw -ExceptionMessage '*config schema is missing*config.schema.json*'
    }

    AfterEach {
        # The cache is module state, so a test that emptied it must not leave it empty for
        # the next one -- which would pass anyway, and hide that this one had any effect.
        $script:PSMutationConfigSchema = $null
    }
}

Describe 'a config value of the wrong type' {
    # Both of PowerShell's coercions fail OPEN, so a wrong type does not error -- it
    # produces a confident wrong answer in whichever direction flatters the run. These pin
    # the refusal for the kinds where that is true, and pin the ACCEPTANCE of the correct
    # value beside each, because a validator that refused everything would pass a
    # refusal-only test just as happily.
    BeforeAll {
        $script:ok = '{ "mutate": ["src/a.ps1"], "tests": { "src/a.ps1": ["tests/a.Tests.ps1"] } }'
        function Get-TestCfg { param([string]$Extra)
            $body = if ($Extra) { $script:ok -replace '}$', ", $Extra }" } else { $script:ok }
            return $body | ConvertFrom-Json
        }
    }

    It 'refuses a string where a number belongs, naming the key and what it found' {
        # The headline case. Get-PSMutationTimeout computes max(floor, baseline * factor);
        # with a non-numeric factor the multiplication yields NOTHING, so the per-mutant
        # deadline is empty -- and a timeout expiry is scored as a KILL. The run reports a
        # number it never measured, which is the failure this project exists to prevent.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"timeoutFactor": "four"') } |
            Should-Throw -ExceptionMessage "*schema*should be `"number, null`"*'/timeoutFactor'*"
    }

    It 'accepts a real number for the same key' {
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg (Get-TestCfg '"timeoutFactor": 2.5'))
    }

    It 'refuses a non-empty string where a boolean belongs' {
        # [bool]'yes please' is $true, so this silently means "mutate uncovered lines too"
        # -- the opposite of what someone typing "yes please" was reaching for is not even
        # the risk; the risk is that they get an answer and never learn it was not theirs.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"coveredLinesOnly": "yes please"') } |
            Should-Throw -ExceptionMessage "*schema*should be `"boolean, null`"*'/coveredLinesOnly'*"
    }

    It 'refuses 1 and 0 where a boolean belongs' -ForEach @(
        @{ Literal = '1' }
        @{ Literal = '0' }
    ) {
        # Both, because they are the two a JSON writer coming from another language reaches
        # for, and they coerce in opposite directions.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg "`"coveredLinesOnly`": $Literal") } |
            Should-Throw -ExceptionMessage "*schema*should be `"boolean, null`"*'/coveredLinesOnly'*"
    }

    It 'accepts a real boolean for the same key' -ForEach @(
        @{ Literal = 'true' }
        @{ Literal = 'false' }
    ) {
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg (Get-TestCfg "`"coveredLinesOnly`": $Literal"))
    }

    It 'refuses a string where the tests map belongs' {
        # A [string] has properties, so `"tests": "src/a.ps1"` passes the non-empty check
        # and then maps its Length as though it were a file.
        { Assert-PSMutationConfig -Cfg ('{ "mutate": ["a"], "tests": "src/a.ps1" }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*schema*should be `"object, null`"*'/tests'*"
    }

    It 'refuses a string inside thresholds' {
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"thresholds": { "break": "100" }') } |
            Should-Throw -ExceptionMessage "*schema*'/thresholds/break'*"
    }

    It 'still allows a threshold to be absent, which means report-only' {
        # Absence is meaningful here and must not be confused with a wrong type: an unset
        # thresholds.break is the documented way to ask for a report without a gate.
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg (Get-TestCfg '"thresholds": { "high": 85 }'))
    }

    It 'still allows an explicit null, for the same reason' {
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg (Get-TestCfg '"timeoutFactor": null'))
    }

    It 'still allows a single file written without a list' {
        # Every reader wraps with @(), so a one-file `"mutate": "src/a.ps1"` has always
        # worked. Type checking must not break configs that were never ambiguous.
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg ('{ "mutate": "src/a.ps1", "tests": { "src/a.ps1": ["t.ps1"] } }' | ConvertFrom-Json))
    }

    It 'refuses an object where a list belongs, which no wrapping rescues' {
        { Assert-PSMutationConfig -Cfg ('{ "mutate": { "a": 1 }, "tests": { "a": ["t"] } }' | ConvertFrom-Json) } |
            Should-Throw -ExceptionMessage "*schema*'/mutate'*"
    }

    It 'ignores the type of an _-prefixed key' {
        # JSON has no comments, so the shipped configs use _-prefixed keys for prose. They
        # are exempt from the unknown-key check and must be exempt from this one too.
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg (Get-TestCfg '"_comment": 42'))
    }

    It 'refuses a boolean where a number belongs, and says so' {
        # $true is not an [int] in PowerShell, so the numeric test would reject this on its
        # own -- but only by accident of type identity. The guard is explicit because a
        # later widening of that test ("accept anything that casts to a number") would
        # otherwise let `true` through as 1 and silently halve or double the timeout.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"timeoutFactor": true') } |
            Should-Throw -ExceptionMessage "*schema*should be `"number, null`"*'/timeoutFactor'*"
    }

    It 'refuses a list where a scalar belongs, and says so' {
        # Named as a list rather than as System.Object[], because the reader is looking for
        # square brackets in a file, not for a .NET type name.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"coveredLinesOnly": [true, false]') } |
            Should-Throw -ExceptionMessage "*schema*should be `"boolean, null`"*'/coveredLinesOnly'*"
    }

    It 'still checks the operators after a thresholds block that is fine' {
        # The two checks are separate loops, and the second only runs if the first falls
        # through. A first loop that returned on its opening property -- valid or not --
        # would swallow this operator, and a dropped operator is exactly how a file scores a
        # vacuous 100%: nothing mutates it, so nothing can survive.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"thresholds": { "high": 85 }, "operators": ["Nonsense"]') } |
            Should-Throw -ExceptionMessage "*Unknown operators key 'Nonsense'*"
    }

    It 'checks every operator in the list, not just the first' {
        # A valid name in front of an invalid one, because a loop that stops after the first
        # entry answers correctly for a single-operator config and silently drops the rest.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"operators": ["BinaryOperator", "Nonsense"]') } |
            Should-Throw -ExceptionMessage "*Unknown operators key 'Nonsense'*"
    }

    It 'reports a misspelled key as a misspelling, not as a wrong type' {
        # Order matters: an unknown key has no expected kind to be measured against, so
        # checking types first would answer a question the reader did not ask.
        { Assert-PSMutationConfig -Cfg (Get-TestCfg '"timeoutFacter": "four"') } |
            Should-Throw -ExceptionMessage '*timeoutFacter*timeoutFactor*'
    }
}

Describe 'a config path answers for itself before anything uses it' {
    BeforeAll {
        # Set HERE rather than at file level. A top-level $script: assignment runs during
        # DISCOVERY and never reaches the run phase, so this Describe was silently reading
        # whatever a sibling's BeforeAll had left in $script:tempRoot -- a fake repo under
        # TestDrive, not the temp path it names. It passed only because these assertions
        # check the FILE NAME and never the root, and it failed the moment the block was
        # run on its own.
        $script:tempRoot = [System.IO.Path]::GetTempPath()
    }
    # Every other config value got a resolver; paths did not, so each failed in its own place
    # and its own way -- and none of the messages named the key that caused it.

    It 'refuses an empty path, naming the key' -ForEach @(
        @{ Value = '' }
        @{ Value = '   ' }
    ) {
        Get-PSMutationPathFault -Value $Value -Key 'reportPath' | Should-MatchString "reportPath"
    }

    It 'refuses a null path, naming the key' {
        # Outside the -ForEach on purpose. A $null in a Pester case hashtable does not bind
        # the variable, so `@{ Value = $null }` runs the body with $Value unset -- which tests
        # the empty-string arm a second time and leaves the null arm unexercised. The
        # self-mutation gate found it: `-or` flipped to `-and` and nothing failed.
        Get-PSMutationPathFault -Value $null -Key 'reportPath' | Should-MatchString "reportPath"
    }

    It 'refuses a path that is not a string' {
        Get-PSMutationPathFault -Value 42 -Key 'reportPath' | Should-MatchString 'must be a string'
    }

    It 'refuses a wildcard metacharacter, naming it' -ForEach @(
        @{ Path = 'sr[c]' }
        @{ Path = 'reports/m*.json' }
        @{ Path = 'a?b.ps1' }
    ) {
        # `[a]` is a character class that matches nothing, so Pester finds no files and the
        # run dies far away with a message naming neither the key nor the cause.
        Get-PSMutationPathFault -Value $Path -Key 'mutate' | Should-MatchString 'wildcard'
    }

    It 'accepts an ordinary path' {
        # The kept case. Without it a resolver that refused EVERY path would pass all of the
        # above, and no config would run at all.
        Should-BeNull -Actual (Get-PSMutationPathFault -Value 'src/Calc.ps1' -Key 'mutate')
    }

    It 'sees a path that escapes its root' {
        Should-BeTrue -Actual (Test-PSMutationPathOutsideRoot -Path '../outside' -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'anchor'))
    }

    It 'sees an escape in a path that resolves to exactly the parent' {
        # EXACTLY '..', not '../something'. The check is three clauses joined by -or, and
        # '../outside' satisfies the StartsWith clause on its own -- so it passes even when
        # the clauses are joined wrongly, and only a path whose relative form IS '..' can
        # tell the difference. A config naming the directory above the root lands here.
        Should-BeTrue -Actual (Test-PSMutationPathOutsideRoot -Path '..' -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'anchor'))
    }

    It 'does not see an escape in an absolute path that is inside the root' {
        # The kept half of the absolute pair. Without it, a resolver that called EVERY rooted
        # path an escape would pass the case below -- and refuse a config that names its files
        # by full path, which is a legal thing to write.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'anchor'
        Should-BeFalse -Actual (Test-PSMutationPathOutsideRoot -Path (Join-Path $root 'src/a.ps1') -Root $root)
    }

    It 'sees an escape in an absolute path that leaves the root behind entirely' {
        # The first clause on its own: an absolute path elsewhere is not under the root at
        # all, so relative-ising it returns something ROOTED rather than a '..' chain.
        # This failed on Linux and passed on Windows before the fix: the check joined an
        # already-rooted path onto the root, so /tmp/elsewhere/x.ps1 became
        # /tmp/anchor/tmp/elsewhere/x.ps1 and relativised to something INSIDE. An absolute
        # path in a config is legal, so that was a real hole, not a fixture artefact.
        $elsewhere = Join-Path ([System.IO.Path]::GetTempPath()) 'somewhere-else/x.ps1'
        Should-BeTrue -Actual (Test-PSMutationPathOutsideRoot -Path $elsewhere -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'anchor'))
    }

    It 'does not see an escape in a path that resolves back inside' {
        # `src/../src` is `src`. Matching on '..' as a string would reject a config that was
        # never ambiguous, which is why this asks for the resolved position instead.
        Should-BeFalse -Actual (Test-PSMutationPathOutsideRoot -Path 'src/../src' -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'anchor'))
    }

    It 'refuses a sandboxSubtree that escapes the source root' {
        { Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = @('src', '../outside') }) -SourceRoot $script:tempRoot } |
            Should-Throw -ExceptionMessage '*resolves outside the source root*'
    }

    It 'applies the documented default when reportPath is absent' {
        # Documented optional and, until this resolver, mandatory in practice: Join-Path with
        # $null returns the root itself, so the run failed at the very end trying to write a
        # report over a directory.
        (Get-PSMutationReportPath -Cfg ([pscustomobject]@{}) -SourceRoot $script:tempRoot) |
            Should-MatchString ([regex]::Escape('ps-mutation.json'))
    }

    It 'uses the configured reportPath when it is given' {
        # Paired with the case above: a resolver that ALWAYS returned the default would pass
        # that one and silently ignore every consumer's setting.
        (Get-PSMutationReportPath -Cfg ([pscustomobject]@{ reportPath = 'out/mine.json' }) -SourceRoot $script:tempRoot) |
            Should-MatchString ([regex]::Escape('mine.json'))
    }

    It 'honours an ABSOLUTE reportPath instead of rebasing it under the source root' {
        # PowerShell's Join-Path concatenates rather than letting a rooted right-hand side win, so
        # '/var/artifacts/r.json' used to resolve to '<SourceRoot>/var/artifacts/r.json' -- the
        # report written somewhere the caller did not ask for, with no error, and INSIDE the tree
        # the sandbox exists to keep clean. Observed for real: a run built a directory chain under
        # the repo being mutated.
        #
        # Built with GetTempPath rather than a literal '/var/...' so the assertion is about
        # rootedness rather than about Unix, and still means something on Windows where an absolute
        # path starts with a drive letter.
        $absolute = Join-Path ([System.IO.Path]::GetTempPath()) 'psmut-abs-report.json'
        (Get-PSMutationReportPath -Cfg ([pscustomobject]@{ reportPath = $absolute }) -SourceRoot $script:tempRoot) |
            Should-Be ([System.IO.Path]::GetFullPath($absolute))
    }

    It 'still resolves a RELATIVE reportPath against the source root' {
        # The other half, and the one that fails if the guard is written the wrong way round. A
        # test for the absolute case alone would pass just as well if every path were now taken
        # literally, which would break every existing config.
        $resolved = Get-PSMutationReportPath -Cfg ([pscustomobject]@{ reportPath = 'out/mine.json' }) -SourceRoot $script:tempRoot
        $resolved | Should-Be ([System.IO.Path]::GetFullPath((Join-Path $script:tempRoot 'out/mine.json')))
        $resolved | Should-MatchString ([regex]::Escape($script:tempRoot))
    }

    It 'still resolves a path that climbs ABOVE the source root' {
        # Documented as reasonable -- a shared artifacts directory beside the repo -- and it was
        # never the broken case. Pinned so the fix for the rooted form cannot quietly take it away.
        $resolved = Get-PSMutationReportPath -Cfg ([pscustomobject]@{ reportPath = '../shared/r.json' }) -SourceRoot $script:tempRoot
        $resolved | Should-Be ([System.IO.Path]::GetFullPath((Join-Path $script:tempRoot '../shared/r.json')))
        $resolved | Should-NotMatchString ([regex]::Escape([System.IO.Path]::Combine($script:tempRoot, 'shared')))
    }

    It 'throws through the reportPath resolver, not just the primitive' {
        # Through the resolver, because a fault function can be correct in both arms while
        # the caller ignores what it returns -- the caller is one line that deletes clean.
        { Get-PSMutationReportPath -Cfg ([pscustomobject]@{ reportPath = 'out/m[1].json' }) -SourceRoot $script:tempRoot } |
            Should-Throw -ExceptionMessage '*wildcards*'
    }

    It 'throws through the subtree resolver for a bracketed subtree' {
        { Get-PSMutationSubtree -Cfg ([pscustomobject]@{ sandboxSubtrees = @('sr[c]') }) -SourceRoot $script:tempRoot } |
            Should-Throw -ExceptionMessage '*wildcards*'
    }

    It 'names the paths that did not survive into the sandbox, and what decides that' {
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-absent-$([guid]::NewGuid())/Public/Get-Grade.ps1"
        $why = Get-PSMutationMissingSandboxPath -Paths @($gone) -Subtrees @('src', 'tests')
        $why | Should-MatchString ([regex]::Escape('Get-Grade.ps1'))
        # The cause, not just the symptom: sandboxSubtrees is what decides, and a repo laid
        # out any other way copies nothing the config points at.
        $why | Should-MatchString 'sandboxSubtrees'
    }

    It 'says nothing when every path is present' {
        Should-BeNull -Actual (Get-PSMutationMissingSandboxPath -Paths @($PSCommandPath) -Subtrees @('src'))
    }
}

Describe 'the mutate list answers for itself' {
    BeforeAll {
        # Set HERE rather than at file level. A top-level $script: assignment runs during
        # DISCOVERY and never reaches the run phase, so this Describe was silently reading
        # whatever a sibling's BeforeAll had left in $script:tempRoot -- a fake repo under
        # TestDrive, not the temp path it names. It passed only because these assertions
        # check the FILE NAME and never the root, and it failed the moment the block was
        # run on its own.
        $script:tempRoot = [System.IO.Path]::GetTempPath()
    }
    # Two config mistakes with no symptom. One doubles every published count and the run; the
    # other silently runs the entire suite for every mutant of the file it affects.

    It 'refuses the same file listed twice, naming it' {
        $why = Get-PSMutationDuplicateMutateFault -Resolved @('/r/src/a.ps1', '/r/src/b.ps1', '/r/src/a.ps1')
        $why | Should-MatchString ([regex]::Escape('a.ps1'))
        # The consequence, not just the fact: (File, Id) is what -RecheckFrom matches on.
        $why | Should-MatchString 'RecheckFrom'
    }

    It 'refuses two spellings that resolve to one file' {
        # The reason this asks the RESOLVED list rather than the config strings. A validator
        # comparing raw text would pass this, and the run would still be doubled.
        $same = [System.IO.Path]::GetFullPath('/r/src/a.ps1')
        Should-NotBeNull -Actual (Get-PSMutationDuplicateMutateFault -Resolved @($same, $same))
    }

    It 'says nothing when every file appears once' {
        # The kept half: a check that fired on any list would refuse every valid config.
        Should-BeNull -Actual (Get-PSMutationDuplicateMutateFault -Resolved @('/r/src/a.ps1', '/r/src/b.ps1'))
    }

    It 'throws through the plan, not just the predicate' {
        # The predicate can be right in both arms while the caller ignores what it returns --
        # and the caller is one line that deletes clean with every other test still green.
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1', 'src/a.ps1')
            tests  = [pscustomobject]@{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
        }
        { Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $script:tempRoot -SandboxRoot (Join-Path $script:tempRoot 'sb') } |
            Should-Throw -ExceptionMessage '*more than once*'
    }

    It 'builds a plan when every mutate file appears once' {
        # Paired: a plan that threw on any list would refuse every valid config, and the test
        # above would still pass.
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1', 'src/b.ps1')
            tests  = [pscustomobject]@{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
        }
        $plan = Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot $script:tempRoot -SandboxRoot (Join-Path $script:tempRoot 'sb')
        $plan.Mutate.Count | Should-Be 2
    }

    It 'names a mutate file with no tests entry' {
        $unmapped = Get-PSMutationUnmappedMutateFile -MutateFiles @('/r/src/a.ps1', '/r/src/b.ps1') `
            -TestsByFile @{ '/r/src/a.ps1' = @('/r/tests/a.Tests.ps1') }
        $unmapped | Should-Be '/r/src/b.ps1'
    }

    It 'names nothing when every mutate file is mapped' {
        # Paired: a check that named every file would put a warning on every correct config,
        # which is the fastest way to make people stop reading warnings.
        $unmapped = Get-PSMutationUnmappedMutateFile -MutateFiles @('/r/src/a.ps1') `
            -TestsByFile @{ '/r/src/a.ps1' = @('/r/tests/a.Tests.ps1') }
        $unmapped.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationOrphanTestsFault' {
    # A key in `tests` IS a mutate file. One that matches nothing was accepted, and did three
    # wrong things quietly: its test files joined the baseline's set, its entry covered no
    # mutant, and whichever file it was meant to name fell back to the whole suite per mutant.
    # None of that fails -- it just makes the run slower while the score stays believable.

    It 'says nothing when every key names a mutate file' {
        Get-PSMutationOrphanTestsFault -Raw @('src/a.ps1') -Resolved @('/sb/src/a.ps1') `
            -Mutate @('/sb/src/a.ps1') | Should-BeNull
    }

    It 'says nothing about an empty tests map' {
        # Paired with the case above rather than left out: a config with no `tests` at all is
        # legal, and a check that treated "no keys" as "no keys matched" would refuse it.
        Get-PSMutationOrphanTestsFault -Raw @() -Resolved @() -Mutate @('/sb/src/a.ps1') |
            Should-BeNull
    }

    It 'names a key that matches no mutate file' {
        Get-PSMutationOrphanTestsFault -Raw @('src/typo.ps1') -Resolved @('/sb/src/typo.ps1') `
            -Mutate @('/sb/src/a.ps1') | Should-BeLikeString '*src/typo.ps1*'
    }

    It 'names the key AS WRITTEN, not the path it resolved to' {
        # The reader has to go and edit the config, and the resolved path is a temp directory
        # that appears nowhere in it.
        $fault = Get-PSMutationOrphanTestsFault -Raw @('src/typo.ps1') `
            -Resolved @('/tmp/psmut-sandbox-1/src/typo.ps1') -Mutate @('/sb/src/a.ps1')
        $fault | Should-BeLikeString '*src/typo.ps1*'
        $fault | Should-NotBeLikeString '*psmut-sandbox-1*'
    }

    It 'matches case-insensitively' {
        # A config that fails on one platform and not the other is worse than one that fails on
        # both: Windows would accept SRC/A.ps1 against src/a.ps1 and Linux would refuse it.
        Get-PSMutationOrphanTestsFault -Raw @('SRC/A.ps1') -Resolved @('/sb/SRC/A.ps1') `
            -Mutate @('/sb/src/a.ps1') | Should-BeNull
    }

    It 'reports every orphan, not just the first' {
        # Fixing a config should cost one round trip rather than one per key.
        Get-PSMutationOrphanTestsFault -Raw @('src/x.ps1', 'src/y.ps1') `
            -Resolved @('/sb/src/x.ps1', '/sb/src/y.ps1') -Mutate @('/sb/src/a.ps1') |
            Should-BeLikeString '*src/x.ps1, src/y.ps1*'
    }

    It 'tells a _-prefixed key where comments actually go' {
        # Those ARE comments one level up -- JSON has none of its own and every config here
        # relies on them -- so somebody who has just written `_comment` beside `mutate` has no
        # reason to expect the rule to change inside `tests`.
        Get-PSMutationOrphanTestsFault -Raw @('_note') -Resolved @('/sb/_note') `
            -Mutate @('/sb/src/a.ps1') | Should-BeLikeString '*TOP level*'
    }

    It 'does NOT offer that advice when no key is a comment' {
        # The paired half. Without it the sentence could be unconditional and every ordinary
        # typo would be told about comment placement, which is not what went wrong.
        Get-PSMutationOrphanTestsFault -Raw @('src/typo.ps1') -Resolved @('/sb/src/typo.ps1') `
            -Mutate @('/sb/src/a.ps1') | Should-NotBeLikeString '*TOP level*'
    }
}

Describe 'the sandbox plan refuses a tests key that covers nothing' {
    # Through the real entry point, with a kept case beside the refused one. A fixture that only
    # ever fails proves nothing about the plan a good config still produces.
    It 'builds a plan when every key names a mutate file' {
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1')
            tests  = [pscustomobject]@{ 'src/a.ps1' = @('tests/a.Tests.ps1') }
        }
        (Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot (Join-Path $TestDrive 'r2') `
                -SandboxRoot (Join-Path $TestDrive 's2')).AllTests | Should-BeCollection -Count 1
    }

    It 'throws before the baseline when a key names nothing, naming the key' {
        # Before the baseline on purpose: afterwards the run has already paid for the extra test
        # files the orphan contributed, and the only symptom is a suite that took too long.
        $cfg = [pscustomobject]@{
            mutate = @('src/a.ps1')
            tests  = [pscustomobject]@{
                'src/a.ps1'   = @('tests/a.Tests.ps1')
                '_why-a-note' = 'prose, which would be looked for as a file'
            }
        }
        { Get-PSMutationSandboxPlan -Cfg $cfg -SourceRoot (Join-Path $TestDrive 'r3') `
                -SandboxRoot (Join-Path $TestDrive 's3') } |
            Should-Throw -ExceptionMessage '*_why-a-note*TOP level*'
    }
}

Describe 'Get-PSMutationRecordEveryKiller' {
    It 'defaults to false, so no consumer pays for data it did not ask for' {
        # The expensive direction is the one that must be opt-in. Recording every killer forfeits
        # Pester's early stop: measured over this repo's Operators.ps1, 118 mutants all killed,
        # 50s becomes 73s for the same 118 verdicts.
        Should-BeFalse -Actual (Get-PSMutationRecordEveryKiller -Cfg ([pscustomobject]@{}))
    }

    It 'honours the config either way' -ForEach @(
        @{ Value = $true; Expected = $true }
        @{ Value = $false; Expected = $false }
    ) {
        # Both arms, because a resolver that ignored the key would satisfy the default test
        # above and silently never turn the feature on.
        (Get-PSMutationRecordEveryKiller -Cfg ([pscustomobject]@{ recordAllKillers = $Value })) |
            Should-Be $Expected
    }
}

Describe 'Get-PSMutationSurvivorBaselinePath' {
    BeforeAll { $script:sbRoot = [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar) }

    It 'returns nothing when the config names no baseline, so the gate stays off' {
        # The presence of the key IS the switch. There is no separate enable flag, because two
        # settings that can disagree are two somebody has to reconcile -- and the disagreement is
        # silent in the direction that matters: a path with the feature off enforces nothing.
        Should-BeNull -Actual (Get-PSMutationSurvivorBaselinePath -Cfg ([pscustomobject]@{}) -SourceRoot $script:sbRoot)
    }

    It 'resolves a relative path against the source root' {
        # So the same config works from any working directory, exactly as reportPath does.
        (Get-PSMutationSurvivorBaselinePath -Cfg ([pscustomobject]@{ survivorBaseline = '.psmutant-survivors.json' }) `
                -SourceRoot $script:sbRoot) |
            Should-Be (Join-Path $script:sbRoot '.psmutant-survivors.json')
    }

    It 'honours an ABSOLUTE path instead of rebasing it under the source root' {
        # PowerShell's Join-Path concatenates rather than letting a rooted right-hand side win, so
        # an absolute path would otherwise be silently rewritten to sit inside the tree being
        # mutated -- the same trap reportPath documents.
        $abs = Join-Path $script:sbRoot 'shared-baseline.json'
        (Get-PSMutationSurvivorBaselinePath -Cfg ([pscustomobject]@{ survivorBaseline = $abs }) -SourceRoot '/elsewhere') |
            Should-Be $abs
    }

    It 'treats an empty or whitespace value as "no baseline", not as a path' {
        # Whitespace is how a key gets half-deleted. Reading it as a path would resolve to the
        # source root itself and then try to write a baseline over a directory.
        foreach ($v in '', '   ') {
            Should-BeNull -Actual (Get-PSMutationSurvivorBaselinePath -Cfg ([pscustomobject]@{ survivorBaseline = $v }) `
                    -SourceRoot $script:sbRoot)
        }
    }

    It 'routes a bad path through the shared rule rather than growing its own opinion' {
        # Every other config path is checked by Get-PSMutationPathFault; a second opinion here
        # would be a second place for the two to disagree about what a path may be.
        # A wildcard metacharacter, which the shared rule refuses because PowerShell's path
        # cmdlets would glob it rather than treat it as a name -- naming neither the key nor the
        # cause when it then matches nothing.
        { Get-PSMutationSurvivorBaselinePath -Cfg ([pscustomobject]@{ survivorBaseline = 'base[1].json' }) `
                -SourceRoot $script:sbRoot } | Should-Throw -ExceptionMessage '*survivorBaseline*'
    }
}
