# The CI parity gate's decisions.
#
# This file exists because of the shape of the thing it guards: every rule in ParityDecisions.ps1
# is a claim about text that is nearly always compliant, so a rule that stopped being able to fire
# would look exactly like a repository that passes. Each rule therefore gets a compliant fixture
# AND one that breaks precisely that rule -- the pairing this repo already requires of every
# "this is filtered" assertion, for the same reason.

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools/ParityDecisions.ps1')

    # A workflow that satisfies every rule. Single-quoted so ${{ matrix.os }} and $env: survive: in
    # a double-quoted here-string PowerShell reads ${ as the start of a variable name, and the
    # fixture would stop resembling the file it stands in for.
    function script:GoodCi {
        $t = @'
name: CI
concurrency:
  group: ci-ref
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Load pinned versions
        run: |
          if (-not $pins[$k]) { throw ".github/pins.env is missing a value for $k" }
      - name: Install pinned modules
        run: |
          Install-Module Pester -RequiredVersion $env:PESTER_VERSION -Force -Scope CurrentUser
      - name: Tests
        run: |
          $cfg = New-PesterConfiguration
          $cfg.Should.DisableV5 = $true
'@
        return @($t -split "`r?`n")
    }

    function script:GoodPublish {
        $t = @'
name: Publish
concurrency:
  group: publish
  cancel-in-progress: false
permissions:
  contents: read
jobs:
  publish:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
'@
        return @($t -split "`r?`n")
    }

    # One line changed, everything else compliant: a fixture that breaks two rules cannot tell you
    # which one fired. Contains, not -like -- an anchor here holds `os: [ubuntu-latest, ...]`, and
    # in a wildcard those brackets are a character class matching a single character, so the anchor
    # would silently match nothing and the test would assert against an unmodified file.
    function script:Broken {
        param([string[]]$Line, [string]$Find, [string]$Replace)
        $hit = $false
        $out = foreach ($l in $Line) {
            if (-not $hit -and $l.Contains($Find)) { $hit = $true; $l.Replace($Find, $Replace) } else { $l }
        }
        if (-not $hit) { throw "fixture anchor '$Find' not found -- the test would assert against an unchanged file" }
        return @($out)
    }

    function script:CiFact { param([string[]]$Line) Get-PSMutantWorkflowFact -Name 'ci.yml' -Line $Line }
    function script:PubFact { param([string[]]$Line) Get-PSMutantWorkflowFact -Name 'publish.yml' -Line $Line }

    function script:Faults {
        param([string[]]$Ci, [string[]]$Pub)
        $c = if ($Ci) { $Ci } else { GoodCi }
        $p = if ($Pub) { $Pub } else { GoodPublish }
        return @(Get-PSMutantParityFault -Fact @((CiFact $c), (PubFact $p)))
    }
}

Describe 'Get-PSMutantWorkflowCode' {
    It 'drops a trailing comment' {
        (Get-PSMutantWorkflowCode -Line @('  timeout-minutes: 30 # generous')) -join '' |
            Should-Be '  timeout-minutes: 30'
    }

    It 'drops a whole-line comment' {
        (Get-PSMutantWorkflowCode -Line @('   # Invoke-ScriptAnalyzer is NOT called here')).Trim() |
            Should-Be ''
    }

    It 'keeps a hash that opens no comment' {
        # The kept half. Without it a stripper that deleted every line from the first hash would
        # satisfy the two cases above, and every rule would then read a truncated workflow.
        (Get-PSMutantWorkflowCode -Line @("if (`$t.StartsWith('#')) { continue }")) -join '' |
            Should-BeLikeString '*continue*'
    }
}

Describe 'Get-PSMutantWorkflowFact' {
    It 'counts one job per runs-on' {
        (CiFact (GoodCi)).JobCount | Should-Be 1
    }

    It 'reads the matrix from the os list, not from every mention of a runner' {
        # `if: matrix.os == 'ubuntu-latest'` names a platform without adding a leg. Counting
        # mentions would read a Linux-only workflow with one conditional step as a matrix over two.
        $f = CiFact (Broken -Line (GoodCi) -Find 'os: [ubuntu-latest, windows-latest]' -Replace 'os: [ubuntu-latest]')
        $f.MatrixOs -join ',' | Should-Be 'ubuntu-latest'
    }

    It 'judges a uses: line before comments are stripped' {
        # The version comment is part of what that rule REQUIRES, so reading the stripped text
        # would report every correctly pinned action as unpinned.
        (CiFact (GoodCi)).UnpinnedUses.Count | Should-Be 0
    }
}

Describe 'the guards every workflow owes' {
    It 'accepts a compliant workflow' {
        @(Get-PSMutantWorkflowGuardFault -Fact (CiFact (GoodCi))).Count | Should-Be 0
    }

    It 'catches a job with no timeout' {
        @(Get-PSMutantWorkflowGuardFault -Fact (CiFact (Broken -Line (GoodCi) -Find 'timeout-minutes: 30' -Replace 'x: 30'))) -join ' ' |
            Should-BeLikeString '*timeout-minutes*'
    }

    It 'catches a missing concurrency group' {
        @(Get-PSMutantWorkflowGuardFault -Fact (CiFact (Broken -Line (GoodCi) -Find 'concurrency:' -Replace 'x:'))) -join ' ' |
            Should-BeLikeString '*concurrency group*'
    }

    It 'catches a missing permissions block' {
        @(Get-PSMutantWorkflowGuardFault -Fact (CiFact (Broken -Line (GoodCi) -Find 'permissions:' -Replace 'x:'))) -join ' ' |
            Should-BeLikeString '*permissions block*'
    }

    It 'reports a file with no job once, and stops' {
        # Every other rule passes over a file this gate cannot read, so the one fault has to be the
        # shape failure rather than a silent clean bill.
        $f = @(Get-PSMutantWorkflowGuardFault -Fact (CiFact @('name: nothing')))
        $f.Count | Should-Be 1
        $f[0] | Should-BeLikeString '*declares no job*'
    }
}

Describe 'how a workflow gets its tools' {
    It 'accepts a compliant workflow' {
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (GoodCi))).Count | Should-Be 0
    }

    It 'catches an action pinned to a tag' {
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) `
                        -Find 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' -Replace 'actions/checkout@v7'))) -join ' ' |
            Should-BeLikeString '*40-character SHA*'
    }

    It 'catches a SHA pinned with no version comment' {
        # The comment is the only thing saying WHICH version a SHA is, and a pin nobody can read is
        # a pin nobody updates.
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) -Find ' # v7.0.1' -Replace ''))) -join ' ' |
            Should-BeLikeString '*trailing comment*'
    }

    It 'catches an install that never asserts the pins arrived' {
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) -Find 'throw ".github/pins.env' -Replace 'Write-Host "'))) -join ' ' |
            Should-BeLikeString '*pins.env*'
    }

    It 'leaves a workflow that installs nothing alone' {
        # The paired half: the publish fixture loads no pins and installs no module, and must not be
        # failed for it. A rule that fired on every workflow would satisfy the case above without
        # proving the condition works at all.
        @(Get-PSMutantWorkflowToolingFault -Fact (PubFact (GoodPublish))).Count | Should-Be 0
    }

    It 'catches a version written out instead of read from the pins file' {
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) `
                        -Find '-RequiredVersion $env:PESTER_VERSION' -Replace '-RequiredVersion 6.1.0'))) -join ' ' |
            Should-BeLikeString '*names a version literally*'
    }

    It 'catches a lint gate spelled out inline' {
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) `
                        -Find 'Install-Module Pester' -Replace 'Invoke-ScriptAnalyzer -Path ./src #'))) -join ' ' |
            Should-BeLikeString '*committed script*'
    }

    It 'catches a Pester configuration that does not disable the classic syntax' {
        # The rule that found another repository's real gap: its publish gate ran the suite with
        # classic Should syntax still legal, while its merge gate forbade it.
        @(Get-PSMutantWorkflowToolingFault -Fact (CiFact (Broken -Line (GoodCi) -Find '$cfg.Should.DisableV5 = $true' -Replace '$cfg.Run.Path = 1'))) -join ' ' |
            Should-BeLikeString '*DisableV5*'
    }
}

Describe 'the rules that depend on which workflow it is' {
    It 'accepts a compliant pair' {
        (Faults).Count | Should-Be 0
    }

    It 'refuses to pass over an empty set' {
        # An empty set satisfies every per-workflow rule, which is the vacuous green this gate
        # exists to prevent elsewhere.
        @(Get-PSMutantParityFault -Fact @()) -join ' ' | Should-BeLikeString '*compared nothing*'
    }

    It 'catches a publish that cancels itself' {
        (Faults -Pub (Broken -Line (GoodPublish) -Find 'cancel-in-progress: false' -Replace 'cancel-in-progress: true')) -join ' ' |
            Should-BeLikeString '*cannot be withdrawn*'
    }

    It 'catches a publish whose cancel flag is an expression rather than the literal false' {
        # An expression is right for CI and wrong here, and it is the value a copy-paste from
        # ci.yml brings with it.
        (Faults -Pub (Broken -Line (GoodPublish) -Find 'cancel-in-progress: false' -Replace 'cancel-in-progress: ${{ true }}')) -join ' ' |
            Should-BeLikeString '*must be the literal false*'
    }

    It 'catches a single-platform matrix' {
        (Faults -Ci (Broken -Line (GoodCi) -Find 'os: [ubuntu-latest, windows-latest]' -Replace 'os: [ubuntu-latest]')) -join ' ' |
            Should-BeLikeString '*windows-latest*'
    }

    It 'catches fail-fast left on' {
        (Faults -Ci (Broken -Line (GoodCi) -Find 'fail-fast: false' -Replace 'fail-fast: true')) -join ' ' |
            Should-BeLikeString '*fail-fast*'
    }

    It 'catches a missing publish workflow' {
        @(Get-PSMutantParityFault -Fact @((CiFact (GoodCi)))) -join ' ' |
            Should-BeLikeString '*No publish.yml*'
    }

    It 'catches a missing ci workflow' {
        @(Get-PSMutantParityFault -Fact @((PubFact (GoodPublish)))) -join ' ' |
            Should-BeLikeString '*No ci.yml*'
    }
}

Describe 'this repository, right now' {
    It 'holds every capability the shared rule set names' {
        # The gate itself, against the real files. The synthetic cases above prove the rules can
        # fire; this proves they are satisfied here, and it is the assertion that fails when
        # somebody edits a workflow rather than this file.
        $dir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '.github/workflows'
        $facts = foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.yml -File) {
            Get-PSMutantWorkflowFact -Name $f.Name -Line @(Get-Content -LiteralPath $f.FullName)
        }
        @(Get-PSMutantParityFault -Fact @($facts)) -join "`n" | Should-Be ''
    }
}
