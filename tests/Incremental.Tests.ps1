# Reusing a previous run's verdicts for the files nothing has touched (#255).
#
# The covering suite for src/PSMutation.Incremental.ps1. Each fixture is a small tree under a
# GUID-named temp directory. One test runs Pester for real, to measure a suite's dependencies; the
# rest are pure or mock that.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'PSMutation.Output.ps1', 'PSMutation.Sandbox.ps1', 'PSMutation.Operators.ps1', 'PSMutation.Pester.ps1',
        'PSMutation.Killers.ps1', 'PSMutation.Runner.ps1', 'PSMutation.Report.ps1', 'PSMutation.Config.ps1', 'PSMutation.Recheck.ps1',
        'PSMutation.Incremental.ps1') {
        . (Join-Path $src $f)
    }
    $script:trees = [System.Collections.Generic.List[string]]::new()
    function script:NewTree {
        # A tree of files, path -> text, under a fresh temp directory.
        param([hashtable]$Files)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-inc-$([System.Guid]::NewGuid().ToString('N'))"
        foreach ($k in $Files.Keys) {
            $full = Join-Path $root $k
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, $Files[$k])
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $script:trees.Add($root)
        return $root
    }
    function script:Basis {
        param([string]$Pester = '6.2.0', [double]$Factor = 4)
        New-PSMutationIncrementalBasis -ModuleVersion '0.8.0' -PesterVersion $Pester -PowerShellVersion '7.5' `
            -TimeoutRule ([pscustomobject]@{ Factor = $Factor; Floor = 15 }) -RecordAllKillers $false
    }
    function script:Cand {
        param([string]$File, [int]$Id, [string]$Description = "d$Id", [int]$Line = 1, [string]$Operator = 'BinaryOperator')
        [pscustomobject]@{ File = $File; Id = $Id; Description = $Description; Line = $Line; Operator = $Operator }
    }
    function script:Row {
        param([string]$File, [int]$Id, [string]$Status = 'Killed', [string]$Description = "d$Id", [int]$Line = 1, [string]$Operator = 'BinaryOperator')
        [pscustomobject]@{ Id = $Id; Function = 'F'; File = $File; Line = $Line; Operator = $Operator; Description = $Description; Status = $Status; KilledBy = @('t') }
    }
}

AfterAll { foreach ($t in $script:trees) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'New-PSMutationIncrementalBasis' {
    It 'records the versions and the settings a verdict depends on, in a fixed order' {
        $b = Basis
        @($b.Keys) | Should-BeCollection @('psmutant', 'pester', 'powershell', 'timeoutFactor', 'timeoutFloorSeconds', 'recordAllKillers')
        $b.psmutant | Should-Be '0.8.0'
        $b.pester | Should-Be '6.2.0'
        $b.powershell | Should-Be '7.5'
        $b.timeoutFactor | Should-Be 4.0
        $b.timeoutFloorSeconds | Should-Be 15.0
        Should-BeFalse -Actual $b.recordAllKillers
    }
}

Describe 'Get-PSMutationIncrementalBasisFault' {
    It 'accepts a basis read back from the report it was written into' {
        $round = (Basis) | ConvertTo-Json | ConvertFrom-Json
        Get-PSMutationIncrementalBasisFault -Prior $round -Current (Basis) | Should-Be ''
    }

    It 'names the FIRST difference, with both values' {
        $round = (Basis -Pester '6.1.0' -Factor 2) | ConvertTo-Json | ConvertFrom-Json
        Get-PSMutationIncrementalBasisFault -Prior $round -Current (Basis) | Should-Be "its pester was '6.1.0' and is '6.2.0' now"
    }

    It 'tells two values apart that differ only in case' {
        # A version string is compared as written: '0.8.0-RC1' and '0.8.0-rc1' are two builds.
        $prior = [pscustomobject]@{ psmutant = '0.8.0-RC1' }
        $current = [ordered]@{ psmutant = '0.8.0-rc1' }
        Get-PSMutationIncrementalBasisFault -Prior $prior -Current $current | Should-Be "its psmutant was '0.8.0-RC1' and is '0.8.0-rc1' now"
    }

    It 'says a report without incremental data has none' {
        Get-PSMutationIncrementalBasisFault -Prior $null -Current (Basis) | Should-Be 'it records no incremental data'
    }
}

Describe 'Get-PSMutationIncrementalKey' {
    BeforeAll {
        $script:kt = NewTree @{ 'src/a.ps1' = 'one'; 'src/b.ps1' = 'two'; 'src/empty.ps1' = '' }
    }

    It 'is the same for the same files, in any order and with repeats' {
        $k = Get-PSMutationIncrementalKey -Path 'src/a.ps1', 'src/b.ps1' -SandboxRoot $script:kt
        $k | Should-MatchString '^[0-9a-f]{64}$'
        Get-PSMutationIncrementalKey -Path 'src/b.ps1', 'src/a.ps1', 'src/a.ps1' -SandboxRoot $script:kt | Should-Be $k
    }

    It 'is the SHA-256 of one path=hash line per file, sorted, joined by newlines' {
        # Pinned to the exact value: a report written by one PSMutant is read by the next, so the
        # recipe is a format, not a detail.
        $text = (@('src/a.ps1', 'src/b.ps1') | ForEach-Object { "$_=$(Get-PSMutationSourceHash -Path (Join-Path $script:kt $_))" }) -join "`n"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $want = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()
        $sha.Dispose()
        Get-PSMutationIncrementalKey -Path 'src/b.ps1', 'src/a.ps1' -SandboxRoot $script:kt | Should-Be $want
    }

    It 'changes when a file''s content changes' {
        $root = NewTree @{ 'src/a.ps1' = 'one'; 'src/b.ps1' = 'two' }
        $before = Get-PSMutationIncrementalKey -Path 'src/a.ps1', 'src/b.ps1' -SandboxRoot $root
        [System.IO.File]::WriteAllText((Join-Path $root 'src/b.ps1'), 'two!')
        Get-PSMutationIncrementalKey -Path 'src/a.ps1', 'src/b.ps1' -SandboxRoot $root | Should-NotBe $before
    }

    It 'names each file, so the same bytes under another name are another key' {
        $root = NewTree @{ 'src/x.ps1' = 'one' }
        Get-PSMutationIncrementalKey -Path 'src/x.ps1' -SandboxRoot $root |
            Should-NotBe (Get-PSMutationIncrementalKey -Path 'src/a.ps1' -SandboxRoot $script:kt)
    }

    It 'tells a file that is gone from one that is empty' {
        Get-PSMutationIncrementalKey -Path 'src/empty.ps1' -SandboxRoot $script:kt |
            Should-NotBe (Get-PSMutationIncrementalKey -Path 'src/empty.ps1' -SandboxRoot (NewTree @{ 'other.ps1' = '' }))
    }
}

Describe 'Get-PSMutationIncrementalSource' {
    It 'lists every script and module but the mapped tests, keeping a test helper, sorted' {
        $root = NewTree @{
            'src/b.ps1' = ''; 'src/a.psm1' = ''; 'src/m.psd1' = ''; 'src/data.json' = ''
            'tests/a.Tests.ps1' = ''; 'tests/helper.ps1' = ''
        }
        Get-PSMutationIncrementalSource -SandboxRoot $root -AllTests @((Join-Path $root 'tests/a.Tests.ps1')) |
            Should-BeCollection @('src/a.psm1', 'src/b.ps1', 'tests/helper.ps1')
    }
}

Describe 'Get-PSMutationSuiteDependency' {
    It 'names the source files the suite ran, and none it only loaded or never touched, and not its own tests' {
        # unused.ps1 is dot-sourced, which only DEFINES its function: Pester counts no command for a
        # definition, so a file nothing from runs is not a dependency. Nor is one nothing loads.
        $root = NewTree @{
            'src/a.ps1'         = 'function Get-A { Get-H }'
            'src/helper.ps1'    = 'function Get-H { 1 }'
            'src/unused.ps1'    = 'function Get-U { 2 }'
            'src/never.ps1'     = 'function Get-N { 3 }'
            'tests/a.Tests.ps1' = 'BeforeAll { . "$PSScriptRoot/../src/helper.ps1"; . "$PSScriptRoot/../src/a.ps1"; . "$PSScriptRoot/../src/unused.ps1" }; Describe ''a'' { It ''runs'' { Get-A | Should-Be 1 } }'
        }
        $suite = @((Join-Path $root 'tests/a.Tests.ps1'))
        $source = Get-PSMutationIncrementalSource -SandboxRoot $root -AllTests $suite
        Get-PSMutationSuiteDependency -Suite $suite -Source $source -SandboxRoot $root | Should-BeCollection @('src/a.ps1', 'src/helper.ps1')
    }

    It 'runs nothing when there is no source to measure' {
        Mock Invoke-Pester { throw 'must not run' }
        @(Get-PSMutationSuiteDependency -Suite @('t.Tests.ps1') -Source @() -SandboxRoot ([System.IO.Path]::GetTempPath())).Count | Should-Be 0
    }
}

Describe 'Read-PSMutationIncrementalPrior' {
    BeforeAll {
        function script:WriteReport {
            param($Doc)
            $root = NewTree @{}
            $p = Join-Path $root 'r.json'
            $Doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p
            return $p
        }
    }

    It 'gives nothing, and says why, without a report' {
        $r = Read-PSMutationIncrementalPrior -ReportPath (Join-Path (NewTree @{}) 'none.json') -Basis (Basis)
        $r.Reason | Should-Be 'there is no previous report there'
        $r.Files.Count | Should-Be 0
        $r.Rows.Count | Should-Be 0
    }

    It 'gives nothing from a report that is not a full run''s' {
        $p = WriteReport @{ mode = 'Partial'; mutants = @() }
        (Read-PSMutationIncrementalPrior -ReportPath $p -Basis (Basis)).Reason | Should-Be "that report is a 'Partial' run, not a full one"
    }

    It 'gives nothing from a report decided under another basis' {
        $p = WriteReport @{ incremental = @{ basis = (Basis -Pester '5.7.1'); files = @{} }; mutants = @() }
        (Read-PSMutationIncrementalPrior -ReportPath $p -Basis (Basis)).Reason | Should-Be "its pester was '5.7.1' and is '6.2.0' now"
    }

    It 'gives each file''s record and each row by file and id' {
        $p = WriteReport @{
            incremental = @{ basis = (Basis); files = @{ 'src/a.ps1' = @{ key = 'k'; dependsOn = @('src/h.ps1') } } }
            mutants     = @((Row 'src/a.ps1' 1), (Row 'src/a.ps1' 2 'Survived'))
        }
        $r = Read-PSMutationIncrementalPrior -ReportPath $p -Basis (Basis)
        $r.Reason | Should-Be ''
        $r.Files['src/a.ps1'].key | Should-Be 'k'
        @($r.Files['src/a.ps1'].dependsOn) | Should-BeCollection @('src/h.ps1')
        $r.Rows['src/a.ps1|2'].Status | Should-Be 'Survived'
        $r.Rows.Count | Should-Be 2
    }
}

Describe 'Select-PSMutationReusedRow' {
    BeforeAll {
        $script:rows = @{ 'src/a.ps1|1' = (Row 'src/a.ps1' 1); 'src/a.ps1|2' = (Row 'src/a.ps1' 2 'Survived') }
    }

    It 'gives each candidate''s previous row, marked Reused, and leaves the previous row alone' {
        $out = Select-PSMutationReusedRow -Candidates @((Cand 'x' 1), (Cand 'x' 2)) -File 'src/a.ps1' -Rows $script:rows
        @($out | ForEach-Object { $_.Status }) | Should-BeCollection @('Killed', 'Survived')
        @($out | ForEach-Object { $_.Reused }) | Should-BeCollection @($true, $true)
        $script:rows['src/a.ps1|1'].PSObject.Properties['Reused'] | Should-BeNull
    }

    It 'gives nothing when any candidate has no previous row, or one describing another mutant' -ForEach @(
        @{ Why = 'no row'; C = @{ Id = 3 } }
        @{ Why = 'another description'; C = @{ Id = 1; Description = 'other' } }
        @{ Why = 'a description differing in case'; C = @{ Id = 1; Description = 'D1' } }
        @{ Why = 'another line'; C = @{ Id = 1; Line = 2 } }
        @{ Why = 'another operator'; C = @{ Id = 1; Operator = 'NumberLiteral' } }
        @{ Why = 'an operator differing in case'; C = @{ Id = 1; Operator = 'binaryoperator' } }
    ) {
        $odd = Cand 'x' @C
        Should-BeNull -Actual (Select-PSMutationReusedRow -Candidates @((Cand 'x' 2), $odd) -File 'src/a.ps1' -Rows $script:rows)
    }

    It 'gives an empty set, not nothing, for a file with no candidates' {
        $out = Select-PSMutationReusedRow -Candidates @() -File 'src/a.ps1' -Rows $script:rows
        Should-NotBeNull -Actual $out
        $out.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationCoveringSuitePath' {
    It 'keeps each of several mapped test files a path of its own, absolute and relative' {
        # Two files: one alone reads the same whether or not the list was joined into one string.
        $root = NewTree @{ 'src/a.ps1' = 'a'; 'tests/a.Tests.ps1' = 't'; 'tests/a2.Tests.ps1' = 't2' }
        $a = Join-Path $root 'src/a.ps1'; $t1 = Join-Path $root 'tests/a.Tests.ps1'; $t2 = Join-Path $root 'tests/a2.Tests.ps1'
        $s = Get-PSMutationCoveringSuitePath -File $a -Plan @{ TestsByFile = @{ $a = @($t1, $t2) }; AllTests = @($t1, $t2) } -SandboxRoot $root
        @($s.Suite) | Should-BeCollection @($t1, $t2)
        @($s.Relative) | Should-BeCollection @('tests/a.Tests.ps1', 'tests/a2.Tests.ps1')
    }

    It 'falls back to the whole suite for an unmapped file' {
        $root = NewTree @{ 'src/b.ps1' = 'b'; 'tests/x.Tests.ps1' = 'x'; 'tests/y.Tests.ps1' = 'y' }
        $b = Join-Path $root 'src/b.ps1'; $x = Join-Path $root 'tests/x.Tests.ps1'; $y = Join-Path $root 'tests/y.Tests.ps1'
        @((Get-PSMutationCoveringSuitePath -File $b -Plan @{ TestsByFile = @{}; AllTests = @($x, $y) } -SandboxRoot $root).Relative) |
            Should-BeCollection @('tests/x.Tests.ps1', 'tests/y.Tests.ps1')
    }
}

Describe 'Get-PSMutationIncrementalEntry' {
    It 'measures a two-file suite as two paths, and keys it the same way twice' {
        # The key must not depend on the run: before the fix it held the sandbox's random name.
        $root = NewTree @{ 'src/a.ps1' = 'a'; 'tests/a.Tests.ps1' = 't'; 'tests/a2.Tests.ps1' = 't2' }
        $a = Join-Path $root 'src/a.ps1'; $t1 = Join-Path $root 'tests/a.Tests.ps1'; $t2 = Join-Path $root 'tests/a2.Tests.ps1'
        $script:measured = $null
        Mock Get-PSMutationSuiteDependency { $script:measured = @($Suite); [string[]]@() }
        $plan = @{ Mutate = @($a); TestsByFile = @{ $a = @($t1, $t2) }; AllTests = @($t1, $t2) }
        $e = Get-PSMutationIncrementalEntry -File $a -Plan $plan -SandboxRoot $root -Source @('src/a.ps1') -Measured @{}
        @($script:measured) | Should-BeCollection @($t1, $t2)
        $e.key | Should-Be (Get-PSMutationIncrementalKey -Path 'src/a.ps1', 'tests/a.Tests.ps1', 'tests/a2.Tests.ps1' -SandboxRoot $root)
    }

    It 'drops the file itself from its dependencies, but not a file whose name differs only in case' {
        # Two files on a case-sensitive file system, and each changes the key on its own. Only the
        # mutate file is written: the filter reads names, and Windows could not hold both.
        $root = NewTree @{ 'src/a.ps1' = 'a'; 'tests/a.Tests.ps1' = 't' }
        $a = Join-Path $root 'src/a.ps1'; $t = Join-Path $root 'tests/a.Tests.ps1'
        Mock Get-PSMutationSuiteDependency { [string[]]@('src/A.ps1', 'src/a.ps1') }
        $e = Get-PSMutationIncrementalEntry -File $a -Plan @{ Mutate = @($a); TestsByFile = @{ $a = @($t) }; AllTests = @($t) } `
            -SandboxRoot $root -Source @('src/a.ps1', 'src/A.ps1') -Measured @{}
        @($e.dependsOn) | Should-BeCollection @('src/A.ps1')
    }
}

Describe 'Get-PSMutationIncrementalState' {
    BeforeAll {
        function script:StateTree {
            # a.ps1 and b.ps1 share one suite; c.ps1 has its own. helper.ps1 is what the shared
            # suite runs besides its two files.
            $root = NewTree @{
                'src/a.ps1' = 'a'; 'src/b.ps1' = 'b'; 'src/c.ps1' = 'c'; 'src/helper.ps1' = 'h'
                'tests/ab.Tests.ps1' = 'ab'; 'tests/c.Tests.ps1' = 'c'
            }
            $a = Join-Path $root 'src/a.ps1'; $b = Join-Path $root 'src/b.ps1'; $c = Join-Path $root 'src/c.ps1'
            $ab = Join-Path $root 'tests/ab.Tests.ps1'; $ct = Join-Path $root 'tests/c.Tests.ps1'
            return [pscustomobject]@{
                Root  = $root
                Plan  = @{ Mutate = @($a, $b, $c); TestsByFile = @{ $a = @($ab); $b = @($ab); $c = @($ct) }; AllTests = @($ab, $ct) }
                Cands = @((Cand $a 1), (Cand $a 2), (Cand $b 1), (Cand $c 1))
            }
        }
        function script:Recorded {
            # The report a previous run over this tree would have written: every file keyed as it
            # is now, every candidate with a row.
            param($Tree, [string]$ReportPath)
            $files = @{}
            foreach ($f in 'a', 'b') {
                $files["src/$f.ps1"] = @{ dependsOn = @('src/helper.ps1')
                    key = (Get-PSMutationIncrementalKey -Path "src/$f.ps1", 'tests/ab.Tests.ps1', 'src/helper.ps1' -SandboxRoot $Tree.Root) }
            }
            $files['src/c.ps1'] = @{ dependsOn = @(); key = (Get-PSMutationIncrementalKey -Path 'src/c.ps1', 'tests/c.Tests.ps1' -SandboxRoot $Tree.Root) }
            @{
                incremental = @{ basis = (Basis); files = $files }
                mutants     = @((Row 'src/a.ps1' 1), (Row 'src/a.ps1' 2 'Survived'), (Row 'src/b.ps1' 1), (Row 'src/c.ps1' 1))
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath
        }
        function script:State {
            param($Tree, [string]$ReportPath, [bool]$On = $true)
            Get-PSMutationIncrementalState -Incremental $On -Candidates $Tree.Cands -Plan $Tree.Plan -SandboxRoot $Tree.Root `
                -ReportPath $ReportPath -Basis (Basis)
        }
    }

    It 'hands an ordinary run its candidates back, reuses nothing, records nothing and says nothing' {
        Mock Get-PSMutationSuiteDependency { throw 'must not measure' }
        $t = StateTree
        $s = State $t (Join-Path $t.Root 'r.json') -On $false
        @($s.Candidates).Count | Should-Be 4
        @($s.Reused).Count | Should-Be 0
        Should-BeNull -Actual $s.Record
        @($s.Lines).Count | Should-Be 0
    }

    It 'reuses every file nothing touched, measures nothing, and records what it reused' {
        Mock Get-PSMutationSuiteDependency { throw 'must not measure' }
        $t = StateTree
        $r = Join-Path $t.Root 'r.json'
        Recorded $t $r
        $s = State $t $r
        @($s.Candidates).Count | Should-Be 0
        @($s.Reused | ForEach-Object { "$($_.File)|$($_.Id)|$($_.Status)" }) | Should-BeCollection @('src/a.ps1|1|Killed', 'src/a.ps1|2|Survived', 'src/b.ps1|1|Killed', 'src/c.ps1|1|Killed')
        $prior = Get-Content $r -Raw | ConvertFrom-Json
        $s.Record.files['src/a.ps1'].key | Should-Be $prior.incremental.files.'src/a.ps1'.key
        @($s.Record.files['src/a.ps1'].dependsOn) | Should-BeCollection @('src/helper.ps1')
        $s.Record.basis.pester | Should-Be '6.2.0'
        $s.Lines[0].Text | Should-Be '  INCREMENTAL from r.json: 4 verdict(s) reused from 3 unchanged file(s), not re-run; 0 mutant(s) to evaluate.'
    }

    It 're-runs every file a changed dependency reaches, measuring a shared suite ONCE, and keys it anew' {
        $script:measured = @()
        Mock Get-PSMutationSuiteDependency { $script:measured += , @($Suite); [string[]]@('src/a.ps1', 'src/b.ps1', 'src/helper.ps1') }
        $t = StateTree
        $r = Join-Path $t.Root 'r.json'
        Recorded $t $r
        [System.IO.File]::WriteAllText((Join-Path $t.Root 'src/helper.ps1'), 'h, changed')
        $s = State $t $r
        @($s.Candidates | ForEach-Object { "$(Split-Path $_.File -Leaf)|$($_.Id)" }) | Should-BeCollection @('a.ps1|1', 'a.ps1|2', 'b.ps1|1')
        @($s.Reused | ForEach-Object { $_.File }) | Should-BeCollection @('src/c.ps1')
        $script:measured.Count | Should-Be 1
        # A file is not its own dependency: its key names it once, as the file.
        @($s.Record.files['src/a.ps1'].dependsOn) | Should-BeCollection @('src/b.ps1', 'src/helper.ps1')
        $s.Record.files['src/a.ps1'].key | Should-Be (Get-PSMutationIncrementalKey -Path 'src/a.ps1', 'tests/ab.Tests.ps1', 'src/b.ps1', 'src/helper.ps1' -SandboxRoot $t.Root)
        $s.Lines[0].Text | Should-Be '  INCREMENTAL from r.json: 1 verdict(s) reused from 1 unchanged file(s), not re-run; 3 mutant(s) to evaluate.'
    }

    It 're-runs a file whose key matches but whose candidates no longer match its rows' {
        Mock Get-PSMutationSuiteDependency { [string[]]@() }
        $t = StateTree
        $r = Join-Path $t.Root 'r.json'
        Recorded $t $r
        $t.Cands[3].Description = 'another mutant now'
        $s = State $t $r
        @($s.Candidates | ForEach-Object { Split-Path $_.File -Leaf }) | Should-BeCollection @('c.ps1')
        @($s.Reused).Count | Should-Be 3
    }

    It 'evaluates and records everything when there is nothing to reuse, and says why' {
        Mock Get-PSMutationSuiteDependency { [string[]]@() }
        $t = StateTree
        $s = State $t (Join-Path $t.Root 'none.json')
        @($s.Candidates).Count | Should-Be 4
        @($s.Record.files.Keys) | Should-BeCollection @('src/a.ps1', 'src/b.ps1', 'src/c.ps1')
        $s.Lines[0].Text | Should-Be '  INCREMENTAL: nothing reused from none.json, because there is no previous report there. Evaluating all 4 mutant(s), and recording what the next run needs.'
    }
}

Describe 'Join-PSMutationIncrementalRow' {
    It 'gives this run''s rows unchanged when nothing was reused' {
        $rows = @((Row 'src/a.ps1' 2), (Row 'src/a.ps1' 1))
        $out = Join-PSMutationIncrementalRow -Candidates @() -Reused @() -Results $rows -SandboxRoot '/s'
        [object]::ReferenceEquals($out[0], $rows[0]) | Should-BeTrue
        $out.Count | Should-Be 2
    }

    It 'puts reused and evaluated rows back in candidate order' {
        $root = [System.IO.Path]::GetTempPath()
        $cands = @((Cand (Join-Path $root 'src/a.ps1') 1), (Cand (Join-Path $root 'src/b.ps1') 1), (Cand (Join-Path $root 'src/a.ps1') 2))
        $out = Join-PSMutationIncrementalRow -Candidates $cands -Reused @((Row 'src/b.ps1' 1)) `
            -Results @((Row 'src/a.ps1' 2), (Row 'src/a.ps1' 1)) -SandboxRoot $root
        @($out | ForEach-Object { "$($_.File)|$($_.Id)" }) | Should-BeCollection @('src/a.ps1|1', 'src/b.ps1|1', 'src/a.ps1|2')
    }
}
