# Unit tests for the scoped-config narrowing decisions (tools/ScopedConfig.ps1).
#
# The failure this guards is a scoped run that looks fast and green while measuring less
# than the reader believes. Every case below is somewhere that being silently wrong is
# indistinguishable from working: a file quietly dropped from scope, a declaration carried
# into a run where it matches nothing, a config that validates but mutates the wrong set.

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools' -AdditionalChildPath 'ScopedConfig.ps1')
    # Operators.ps1 as well as Config.ps1: the validator checks operator names against
    # Get-PSMutationKnownOperator, so sourcing the validator alone gives a fixture that
    # fails on the vocabulary rather than on anything this file is testing.
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src' -AdditionalChildPath 'PSMutation.Config.ps1')
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src' -AdditionalChildPath 'PSMutation.Operators.ps1')

    # Built from JSON rather than a hashtable literal, because that is what the code is
    # handed at runtime: ConvertFrom-Json returns PSCustomObjects whose members are reached
    # through PSObject, and a hashtable fixture would pass against code that cannot read a
    # real config.
    $script:base = @'
{
  "mutate": ["src/Alpha.ps1", "src/Beta.ps1", "src/Gamma.ps1"],
  "tests": {
    "src/Alpha.ps1": ["tests/Alpha.Tests.ps1"],
    "src/Beta.ps1":  ["tests/Beta.Tests.ps1"],
    "src/Gamma.ps1": ["tests/Gamma.Tests.ps1"]
  },
  "coveredLinesOnly": true,
  "operators": ["BinaryOperator", "ConditionForcing"],
  "equivalents": {
    "src/Alpha.ps1:Get-Thing:6 -> 7": "reason for alpha",
    "src/Beta.ps1:Get-Other:1 -> 2": "reason for beta"
  },
  "thresholds": { "high": 85, "low": 70, "break": 100 },
  "sandboxSubtrees": ["src", "tests"],
  "reportPath": "reports/real.json"
}
'@ | ConvertFrom-Json
}

Describe 'Get-PSMutantScopedFile' {
    It 'puts a changed source file in scope and leaves the untouched ones out' {
        # Paired deliberately: a fixture where everything is in scope would pass against a
        # function that ignores its input entirely.
        $scoped = @(Get-PSMutantScopedFile -MutateFiles @($script:base.mutate) -TestMap $script:base.tests `
                -ChangedFiles @('src/Beta.ps1'))
        ($scoped -join ',') | Should-Be 'src/Beta.ps1'
    }

    It 'puts the covered source in scope when only its TEST changed' {
        # The reverse lookup. Writing the assertion that kills a survivor is precisely the
        # edit whose effect you want to measure, so scoping by source alone would skip the
        # run worth doing. Paired with a test file for a source that must stay out.
        $scoped = @(Get-PSMutantScopedFile -MutateFiles @($script:base.mutate) -TestMap $script:base.tests `
                -ChangedFiles @('tests/Gamma.Tests.ps1'))
        ($scoped -join ',') | Should-Be 'src/Gamma.ps1'
    }

    It 'ignores changed files that are neither mutated source nor a mapped suite' {
        $scoped = @(Get-PSMutantScopedFile -MutateFiles @($script:base.mutate) -TestMap $script:base.tests `
                -ChangedFiles @('README.md', 'src/NotMutated.ps1', 'src/Alpha.ps1'))
        ($scoped -join ',') | Should-Be 'src/Alpha.ps1'
    }

    It 'returns files in the config order, not the order the change listed them' {
        # Joined and compared as a string: Should-BeCollection ignores order and has no
        # strict switch, so it passes against the exact defect this asserts against.
        $scoped = @(Get-PSMutantScopedFile -MutateFiles @($script:base.mutate) -TestMap $script:base.tests `
                -ChangedFiles @('src/Gamma.ps1', 'src/Alpha.ps1'))
        ($scoped -join ',') | Should-Be 'src/Alpha.ps1,src/Gamma.ps1'
    }
}

Describe 'Get-PSMutantScopedConfig' {
    It 'returns null when nothing in the change is mutatable' {
        # Not an empty-mutate config: that is refused by Assert-PSMutationConfig, so the
        # caller would report a validation error for the ordinary case of editing a README.
        Should-BeNull -Actual (Get-PSMutantScopedConfig -BaseConfig $script:base `
                -ChangedFiles @('README.md') -ReportPath 'reports/scoped.json')
    }

    It 'keeps declarations for files in scope and drops the rest' {
        # Both halves in one call. Carrying the beta declaration into an alpha-only run
        # makes it match no mutant, which fails the run -- for a reason that has nothing to
        # do with the change being tested.
        $cfg = Get-PSMutantScopedConfig -BaseConfig $script:base -ChangedFiles @('src/Alpha.ps1') `
            -ReportPath 'reports/scoped.json'
        ($cfg.equivalents.Keys -join ',') | Should-Be 'src/Alpha.ps1:Get-Thing:6 -> 7'
    }

    It 'omits the equivalents key entirely when no declaration is in scope' {
        $cfg = Get-PSMutantScopedConfig -BaseConfig $script:base -ChangedFiles @('src/Gamma.ps1') `
            -ReportPath 'reports/scoped.json'
        Should-BeFalse -Actual $cfg.Contains('equivalents')
    }

    It 'copies the operator set and thresholds verbatim rather than re-deciding them' {
        # A scoped run that used different operators or a different coverage rule would
        # disagree with the full run for a reason invisible to whoever reads the score.
        $cfg = Get-PSMutantScopedConfig -BaseConfig $script:base -ChangedFiles @('src/Alpha.ps1') `
            -ReportPath 'reports/scoped.json'
        ($cfg.operators -join ',') | Should-Be 'BinaryOperator,ConditionForcing'
        $cfg.thresholds.break | Should-Be 100
        $cfg.coveredLinesOnly | Should-BeTrue
    }

    It 'refuses to write where the real report goes' {
        # Sharing the path means a partial run silently replaces the artifact CI reads, and
        # the file carries no sign of which kind of run produced it.
        { Get-PSMutantScopedConfig -BaseConfig $script:base -ChangedFiles @('src/Alpha.ps1') `
                -ReportPath 'reports/real.json' } | Should-Throw -ExceptionMessage '*must not write*'
    }

    It 'produces a config the real validator accepts' {
        # The integration that matters. Every assertion above can hold while the result is
        # rejected the moment it is used -- an unknown key, a missing required one, or the
        # _comment warning tripping the unknown-key check that exists to catch typos.
        $cfg = Get-PSMutantScopedConfig -BaseConfig $script:base -ChangedFiles @('src/Alpha.ps1') `
            -ReportPath 'reports/scoped.json'
        $roundTripped = $cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        Should-BeNull -Actual (Assert-PSMutationConfig -Cfg $roundTripped)
    }
}
