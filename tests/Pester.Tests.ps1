# Unit tests for src/PSMutation.Pester.ps1 -- the module's boundary with Pester.
#
# These used to be split across Orchestrator.Tests.ps1 and Runner.Tests.ps1, matching the
# two copies of the resolution they cover (#38). They are together now because they test
# one question -- WHICH Pester -- and the failure they guard is the two answers
# disagreeing: validate one version, hand the child another, and every mutant dies on an
# assembly collision while the run reports a silent, entirely fake 100% (#16).

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src' -AdditionalChildPath 'PSMutation.Pester.ps1')
}

Describe 'Get-PSMutationLoadedPester' {
    It 'picks the newest when the session holds more than one Pester' {
        # The single definition of "which Pester", so this is where highest-wins is
        # pinned. Two Pester 5.x releases CAN coexist in one process -- the dll guard
        # only rejects a LOWER loaded version -- and the newer is the one whose assembly
        # is actually serving calls, so anything else answers about a Pester that is not
        # running the tests.
        Mock Get-Module {
            @(
                [pscustomobject]@{ Version = [version]'5.8.0'; Path = 'p580' }
                [pscustomobject]@{ Version = [version]'6.1.0'; Path = 'p610' }
            )
        }
        (Get-PSMutationLoadedPester).Path | Should-Be 'p610'
    }

    It 'returns nothing when no Pester is loaded' {
        # Both callers branch on this, and they branch in opposite directions -- one
        # imports, one throws -- so an empty answer has to be distinguishable rather
        # than an error.
        Mock Get-Module { }
        Should-BeNull -Actual (Get-PSMutationLoadedPester)
    }
}

Describe 'Assert-PSMutationPester' {
    BeforeEach {
        # Pester 6 dropped mock fall-through, so BOTH shapes of the Get-Module call this
        # function makes -- loaded modules, and -ListAvailable -- need their own mock, or
        # the unmatched one throws instead of answering.
        $script:loaded = @()
        $script:available = @()
        Mock Get-Module { $script:loaded } -ParameterFilter { -not $ListAvailable }
        Mock Get-Module { $script:available } -ParameterFilter { $ListAvailable }
        Mock Import-Module { }
    }

    It 'accepts the Pester already loaded rather than importing a second one' {
        # THE regression. Import-Module -MinimumVersion is not the no-op it looks like
        # when a satisfying Pester is already loaded: it re-resolves the name to the
        # NEWEST version installed, and on a machine holding two that collides with the
        # Pester.dll already in the process. Every end-to-end test failed this way,
        # before a single mutant ran.
        $script:loaded = @([pscustomobject]@{ Version = [version]'5.8.0' })
        $script:available = @([pscustomobject]@{ Version = [version]'6.1.0' })

        Assert-PSMutationPester
        Should-NotInvoke Import-Module
    }

    It 'imports Pester when the session has none loaded yet' {
        $script:available = @([pscustomobject]@{ Version = [version]'5.8.0' })
        Assert-PSMutationPester
        Should-Invoke Import-Module -Times 1 -Exactly
    }

    It 'refuses when nothing installed is new enough' {
        # Pester 4 has no code-coverage API and a different Should surface, so without
        # this the run dies much later, inside the baseline, with an unrelated error.
        $script:available = @([pscustomobject]@{ Version = [version]'4.10.1' })
        { Assert-PSMutationPester } | Should-Throw -ExceptionMessage '*Pester 5.2.0 or later is required*'
    }

    It 'refuses when the LOADED Pester is too old, even though a newer one is installed' {
        # The tempting repair -- import the newer one -- is itself the bug: the old
        # assembly is already in the process, so the import fails rather than upgrades.
        # Refusing names the real problem while the session can still be restarted.
        $script:loaded = @([pscustomobject]@{ Version = [version]'4.10.1' })
        $script:available = @([pscustomobject]@{ Version = [version]'6.1.0' })
        { Assert-PSMutationPester } | Should-Throw -ExceptionMessage '*Pester 5.2.0 or later is required*'
        Should-NotInvoke Import-Module
    }

    It 'accepts a loaded Pester of exactly the minimum version' {
        # -lt, not -le. 5.2.0 is the documented floor, so the boundary value itself has to pass
        # -- rejecting it would refuse the very version the manifest asks for.
        #
        # The floor moved from 5.0.0 in #161, and it moved because it was measured rather than
        # declared: New-PesterConfiguration arrives in 5.2.0 and this module cannot work without
        # it, so the two versions below the new floor never worked at all.
        $script:loaded = @([pscustomobject]@{ Version = [version]'5.2.0' })
        Assert-PSMutationPester
        Should-NotInvoke Import-Module
    }

    It 'refuses the version that used to be the documented floor' {
        # The other half, and the point of #161: 5.1.0 satisfied the old promise and does not
        # work. It now fails with a message naming the requirement, rather than an assembly
        # version error that never mentions this module.
        $script:loaded = @([pscustomobject]@{ Version = [version]'5.1.0' })
        { Assert-PSMutationPester } | Should-Throw -ExceptionMessage '*Pester 5.2.0 or later is required*'
    }

    It 'judges by the newest module loaded when the session holds more than one' {
        # Pester 3 ships with Windows and can sit in a session next to a modern one.
        # Judging by the wrong element refuses a session perfectly able to run.
        $script:loaded = @(
            [pscustomobject]@{ Version = [version]'3.4.0' }
            [pscustomobject]@{ Version = [version]'5.8.0' }
        )
        Assert-PSMutationPester
        Should-NotInvoke Import-Module
    }
}

Describe 'Get-PSMutationPesterPath' {
    It 'returns the path of the newest Pester loaded in this process' {
        # Two Pester 5.x releases CAN sit in one process -- the dll guard only rejects a
        # LOWER loaded version -- and the newer is the one actually serving calls.
        # Handing the child the older path reintroduces the collision it exists to stop.
        Mock Get-Module {
            @(
                [pscustomobject]@{ Version = [version]'5.8.0'; Path = 'C:\p\5.8.0\Pester.psd1' }
                [pscustomobject]@{ Version = [version]'6.1.0'; Path = 'C:\p\6.1.0\Pester.psd1' }
            )
        }
        Get-PSMutationPesterPath | Should-Be 'C:\p\6.1.0\Pester.psd1'
    }

    It 'refuses when no Pester is loaded at all' {
        # With no path to hand over, the child would resolve the name itself and pick
        # whatever is newest on disk -- exactly the behaviour being prevented.
        Mock Get-Module { }
        { Get-PSMutationPesterPath } | Should-Throw -ExceptionMessage '*not loaded*'
    }
}

Describe 'Get-PSMutationBoundedPesterScript' {
    It 'imports the pinned Pester by path and stops the child if that fails' {
        # Both halves are load-bearing and easy to "simplify" away. Importing by NAME
        # lets the runspace resolve Pester itself and pick the newest installed, which
        # is the collision the pin exists to stop; without -ErrorAction Stop a failed
        # import leaves the child running on to produce nothing, which used to read as
        # a killed mutant.
        $script = Get-PSMutationBoundedPesterScript
        $script | Should-BeLikeString '*Import-Module $pester*'
        $script | Should-BeLikeString '*-ErrorAction Stop*'
        $script | Should-NotBeLikeString '*Import-Module Pester*'
    }
}

Describe 'Get-PSMutationRunspaceError' {
    It 'joins every message the child wrote to its error stream' {
        $fake = [pscustomobject]@{ Streams = [pscustomobject]@{ Error = @(
                    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'first' } }
                    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'second' } }
                ) } }
        Get-PSMutationRunspaceError -Runspace $fake | Should-Be 'first; second'
    }

    It 'says so when the child died without writing an error' {
        # This text lands inside a thrown exception. An empty string there would
        # report "produced no result: " and name nothing at all.
        $fake = [pscustomobject]@{ Streams = [pscustomobject]@{ Error = @() } }
        Get-PSMutationRunspaceError -Runspace $fake | Should-Be 'the child runspace reported no error'
    }
}

# Moved here from tests/Runner.Tests.ps1 with the function itself. Get-PSMutationRunspaceError
# reads a child RUNSPACE's error stream, which is this file's stated domain, and leaving it in
# Runner made PSMutation.Pester.ps1 call upward into PSMutation.Runner.ps1 -- a cycle
# tests/Layering.Tests.ps1 caught on the first run. A test left behind in the other file would
# still COVER the function while being unable to kill any of its mutants, because
# psmutant.self.config.json maps each source file to one covering suite.

Describe 'the warm mutant runspace pool' {
    AfterEach { Close-PSMutationWarmRunspacePool }

    It 'hands back the same shell until its lifetime is spent' {
        # The whole point of the change: creating a runspace and importing Pester into it cost
        # about 396 ms on every mutant, 27% of a measured 801s run over this repo's sibling.
        Close-PSMutationWarmRunspacePool
        $first = Get-PSMutationWarmShell -WorkerId 0
        $second = Get-PSMutationWarmShell -WorkerId 0
        [object]::ReferenceEquals($first, $second) | Should-BeTrue
    }

    It 'gives each worker its OWN shell' {
        # The isolation parallel evaluation rests on. One [PowerShell] instance cannot run two
        # pipelines: a second BeginInvoke on a busy one throws, so a shared shell would not be a
        # subtly wrong answer but a run that dies depending on scheduling.
        Close-PSMutationWarmRunspacePool
        $a = Get-PSMutationWarmShell -WorkerId 0
        $b = Get-PSMutationWarmShell -WorkerId 1
        [object]::ReferenceEquals($a, $b) | Should-BeFalse
    }

    It 'keeps a use count per worker rather than one for the pool' {
        # A shared counter would retire every worker's runspace on the total across all of them,
        # so an eight-worker run would rebuild eight times as often as it was told to -- and the
        # only symptom is a run that is quietly slower.
        Close-PSMutationWarmRunspacePool
        $null = Get-PSMutationWarmShell -WorkerId 0
        $null = Get-PSMutationWarmShell -WorkerId 0
        $null = Get-PSMutationWarmShell -WorkerId 1
        $script:PSMutationWarmUses[0] | Should-Be 2
        $script:PSMutationWarmUses[1] | Should-Be 1
    }

    It 'retires ONE worker without touching the others' {
        # What a timeout does: Stop() leaves that worker's runspace unusable and it is discarded.
        # Discarding the pool instead would make every other worker pay a cold start for one
        # mutant's overrun.
        Close-PSMutationWarmRunspacePool
        $keep = Get-PSMutationWarmShell -WorkerId 0
        $null = Get-PSMutationWarmShell -WorkerId 1
        Close-PSMutationWarmRunspace -WorkerId 1
        $script:PSMutationWarmShell.ContainsKey(1) | Should-BeFalse
        [object]::ReferenceEquals($keep, (Get-PSMutationWarmShell -WorkerId 0)) | Should-BeTrue
    }

    It 'closes every worker when the run ends' {
        # The run's exit path. A long-lived host would otherwise keep a Pester-loaded runspace
        # per worker per completed run, which is now a multiple rather than one.
        Close-PSMutationWarmRunspacePool
        $null = Get-PSMutationWarmShell -WorkerId 0
        $null = Get-PSMutationWarmShell -WorkerId 1
        $null = Get-PSMutationWarmShell -WorkerId 2
        Close-PSMutationWarmRunspacePool
        $script:PSMutationWarmShell.Count | Should-Be 0
        $script:PSMutationWarmRunspace.Count | Should-Be 0
        $script:PSMutationWarmUses.Count | Should-Be 0
    }

    It 'serves exactly the lifetime, then rebuilds on the next ask' {
        # Asserted at BOTH ends of the boundary, and that is what makes it discriminating. A
        # version of this test that only checked "eventually a new one appears" passes whether the
        # comparison is -lt or -le, and whether the counter starts at 1 or 2 -- the mutation gate
        # said so, with three survivors on these four lines.
        Close-PSMutationWarmRunspacePool
        $n = $script:PSMutationWarmRunspaceLifetime
        $shells = @(1..($n + 1) | ForEach-Object { Get-PSMutationWarmShell -WorkerId 0 })
        # Use 1 and use N are the same runspace: it serves the whole lifetime.
        [object]::ReferenceEquals($shells[0], $shells[$n - 1]) | Should-BeTrue
        # Use N+1 is a different one: the lifetime is a ceiling, not a suggestion.
        [object]::ReferenceEquals($shells[0], $shells[$n]) | Should-BeFalse
    }

    It 'serves fifty mutants before rebuilding' {
        # The number is pinned rather than left to whatever the constant says, because it is a
        # DECISION and the test above is written in terms of the constant -- so changing 50 to
        # anything else would slide past it. At fifty the saving is already about 93% of the
        # per-mutant floor, so a larger number buys almost nothing while widening the window in
        # which state left by a covering suite could travel between mutants.
        $script:PSMutationWarmRunspaceLifetime | Should-Be 50
    }

    It 'DISPOSES the runspace it retires rather than dropping the reference' {
        # Without this the old runspace is merely unreferenced, and a long run retires one every
        # fifty mutants -- each holding a loaded Pester. Reference-dropping and disposal look
        # identical from the outside, which is why the disposed shell is used directly here.
        Close-PSMutationWarmRunspacePool
        $shell = Get-PSMutationWarmShell -WorkerId 0
        $runspace = $script:PSMutationWarmRunspace[0]
        Close-PSMutationWarmRunspace -WorkerId 0
        # The runspace is asserted by STATE and the shell by use, because those are the two
        # separate resources and a test that only tried to use the shell cannot say which of them
        # was released -- an object on a closed runspace throws exactly as a disposed one does.
        $runspace.RunspaceStateInfo.State | Should-Be 'Closed'
        { $shell.AddScript('1').Invoke() } | Should-Throw
    }

    It 'forgets a worker entirely when it closes, rather than leaving a null behind' {
        # A key whose value is $null still answers ContainsKey, so the close guard would fire
        # again and dispose $null -- and the getter would hand back nothing while believing it
        # had a shell. The counter goes with it: left set, it would retire the NEXT runspace
        # early, silently, since the only symptom is a little more rebuilding.
        Close-PSMutationWarmRunspacePool
        $null = Get-PSMutationWarmShell -WorkerId 0
        Close-PSMutationWarmRunspace -WorkerId 0
        $script:PSMutationWarmShell.ContainsKey(0) | Should-BeFalse
        $script:PSMutationWarmRunspace.ContainsKey(0) | Should-BeFalse
        $script:PSMutationWarmUses.ContainsKey(0) | Should-BeFalse
    }

    It 'is safe to close when nothing is open' {
        # Called from the run's finally, which runs even when the run threw before any mutant.
        Close-PSMutationWarmRunspace -WorkerId 0
        Close-PSMutationWarmRunspacePool
        $true | Should-BeTrue
    }

    It 'gives a shell that already has Pester in it' {
        Close-PSMutationWarmRunspacePool
        $shell = Get-PSMutationWarmShell -WorkerId 0
        $shell.Commands.Clear()
        [void]$shell.AddScript('(Get-Module Pester | Select-Object -First 1).Name')
        [string]($shell.Invoke() | Select-Object -Last 1) | Should-Be 'Pester'
    }

    It 'refuses to hand back a shell whose Pester import failed' {
        # A shell without Pester would run every covering suite into a command-not-found and
        # report no verdict -- which the verdict reader treats as a kill. Same shape as the
        # version collision: a broken child scoring as a caught fault.
        Close-PSMutationWarmRunspacePool
        Mock Get-PSMutationPesterPath { Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-pester.psd1' }
        { Get-PSMutationWarmShell -WorkerId 0 } | Should-Throw -ExceptionMessage '*Could not import Pester into the mutant runspace*'
    }
}

Describe 'the child script the warm runspace runs' {
    It 'is valid PowerShell' {
        # The child contract is a here-string, so nothing lints or parse-checks the code every
        # mutant runs (issue #49). A typo in it surfaces at run time, in a child, as "the covering
        # tests produced no result". Parsing it here is the cheapest possible guard.
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript).ToString(), [ref]$null, [ref]$errors)
        @($errors).Count | Should-Be 0
    }

    # The substring check that used to sit here is gone, superseded by the AST assertion above.
    # It matched '*SkipRemainingOnFailure*' anywhere in the text, which stayed true after the
    # early-stop decision moved inside the script and became conditional -- so it would have
    # passed with the condition inverted. That is the weakness #49 is about: a string admits no
    # better assertion, and once the thing is real code there is no reason to settle for one.

    It 'sets the property when the configuration has it' {
        # Both arms of the guard, exercised against stand-ins rather than against a real old
        # Pester -- CI runs 6.1.0 and the compatibility gate runs 5.8.0, so no gate here loads a
        # Pester without the property and the false arm would otherwise never execute.
        #
        # Measured, not assumed: Pester 5.2.0 does NOT carry SkipRemainingOnFailure and 5.3.0
        # does, so the guard exists for 5.0.0 to 5.2.x and nothing else.
        $withIt = [pscustomobject]@{ SkipRemainingOnFailure = 'None' }
        if ($withIt.PSObject.Properties['SkipRemainingOnFailure']) { $withIt.SkipRemainingOnFailure = 'Run' }
        $withIt.SkipRemainingOnFailure | Should-Be 'Run'
    }

    It 'leaves a configuration without the property untouched' {
        $withoutIt = [pscustomobject]@{ Path = 'x' }
        if ($withoutIt.PSObject.Properties['SkipRemainingOnFailure']) { $withoutIt.SkipRemainingOnFailure = 'Run' }
        ($withoutIt.PSObject.Properties['SkipRemainingOnFailure']) | Should-BeNull
    }
}

Describe 'the child script every mutant runs' {
    It 'PARSES' {
        # THE point of #49. This text is handed to a runspace at run time, and as a here-string
        # nothing ever examined it: the analyzer saw a string literal, the parser saw nothing
        # until AddScript, and the tests could only match substrings. A typo failed no lint, no
        # parse and no test, and appeared on a consumer's machine mid-run.
        #
        # A real assertion, and cheap, unlike the substring checks it replaces. Written as a
        # scriptblock the parser already catches this when the file is dot-sourced -- so this
        # test is the guard against someone converting it back to a string.
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript).ToString(), [ref]$null, [ref]$errors)
        @($errors) | Should-BeCollection -Count 0
    }

    It 'actually RUNS, and answers with the verdict and the killers' -ForEach @(
        @{ All = $false; Because = 'the default path' }
        @{ All = $true; Because = 'the record-every-killer path' }
    ) {
        # Invoked in-process against a real fixture, which an opaque string never allowed and
        # which #49 named as the payoff for making it code. It is also what COVERS these lines:
        # the block otherwise executes only inside a child runspace, where the parent's coverage
        # cannot see it -- so before this test the file sat at 98.95% with the body untouched.
        #
        # A nested Invoke-Pester is safe here because the coverage gate sets
        # CodeCoverage.UseBreakpoints, which exists for exactly this hazard.
        $fixture = Join-Path $TestDrive "child-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        @'
Describe 'fixture' {
    It 'passes' { 1 | Should-Be 1 }
    It 'fails first' { 1 | Should-Be 2 }
    It 'fails second' { 1 | Should-Be 2 }
}
'@ | Set-Content -LiteralPath $fixture -Encoding utf8

        # The ORIGINAL block, not a copy made from its text: a re-created scriptblock has no
        # file association, so nothing it runs is attributed to the lines under test.
        $out = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $All -sandboxRoot $TestDrive

        $out.Result | Should-Be 'Failed' -Because "a failing suite is what kills a mutant, on $Because"
        # The COUNT is the assertion, not merely that some killer came back. The fixture has two
        # failing tests, so the two modes differ observably -- 1 against 2 -- and that difference
        # is the only thing the guard inside the script controls. Asserting non-emptiness instead
        # left both of the guard's mutants alive: inverted or widened to -or, some killer still
        # comes back and every weaker assertion still passes.
        @($out.Killers).Count | Should-Be ($All ? 2 : 1)
        # The FIRST failing test is the one the early stop keeps, so it is present either way.
        ($out.Killers -join ' ') | Should-MatchString 'fails first'
        # And the second is exactly what the expensive mode buys.
        if ($All) { ($out.Killers -join ' ') | Should-MatchString 'fails second' }
        else { ($out.Killers -join ' ') | Should-NotMatchString 'fails second' }
        # Every test that reached a verdict, and no skipped one: the early stop leaves the second
        # failure unrun.
        $out.Ran | Should-Be ($All ? 3 : 2)
    }

    It 'answers Passed with no killers when nothing notices' {
        # The survivor path, which is the one a wrong verdict flatters. Asserted separately
        # because the failing case above would pass just as well if Killers were always
        # populated from somewhere.
        $fixture = Join-Path $TestDrive "green-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        "Describe 'g' { It 'passes' { 1 | Should-Be 1 } }" | Set-Content -LiteralPath $fixture -Encoding utf8

        $out = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $false -sandboxRoot $TestDrive
        $out.Result | Should-Be 'Passed'
        @($out.Killers) | Should-BeCollection -Count 0
        $out.Ran | Should-Be 1
    }

    It 'answers Passed having run NO test when a file''s discovery is ended (#251)' {
        # What a mutant that reaches `exit` while a test file loads looks like: Pester calls the
        # run Passed, and only the count says nothing was asked.
        $fixture = Join-Path $TestDrive "gone-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        "exit 3; Describe 'g' { It 'passes' { 1 | Should-Be 1 } }" | Set-Content -LiteralPath $fixture -Encoding utf8

        $out = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $false -sandboxRoot $TestDrive
        $out.Result | Should-Be 'Passed'
        $out.Ran | Should-Be 0
    }

    It 'declares the parameters the runner binds by name' {
        # AddParameter binds by NAME, so a rename here fails at run time with a binding error
        # rather than at parse time. These are the contract between this file and the runner.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript).ToString(), [ref]$null, [ref]$null)
        $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should-BeCollection @('tests', 'recordAllKillers', 'sandboxRoot', 'filter')
    }

    It 'keeps the early stop unless every killer is wanted' {
        # Asserted on the AST rather than on the text: the decision is now INSIDE the script, so
        # the string always mentions SkipRemainingOnFailure and a substring check would pass
        # whatever the condition said. What matters is that the assignment is guarded by the
        # parameter -- flip the guard and the expensive path becomes the only path.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript).ToString(), [ref]$null, [ref]$null)
        $guarded = @($ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Extent.Text -match 'SkipRemainingOnFailure'
                }, $true))
        $guarded | Should-BeCollection -Count 1
        $guarded[0].Clauses[0].Item1.Extent.Text | Should-MatchString 'recordAllKillers'
    }
}

Describe 'the child script, given a filter (#254)' {
    BeforeAll {
        # 'b fails' and 'c fails [x]' both fail; the -ForEach test is one name with two cases.
        $script:firstFixture = Join-Path $TestDrive "first-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        @'
Describe 'd' {
    It 'a passes' { 1 | Should-Be 1 }
    It 'b fails' { 1 | Should-Be 2 }
    It 'case <n>' -ForEach @(@{ n = 1 }, @{ n = 2 }) { $n | Should-BeGreaterThan 0 }
    It 'c fails [x]' { 1 | Should-Be 2 }
}
'@ | Set-Content -LiteralPath $script:firstFixture -Encoding utf8
        function script:Child { param([string[]]$Filter, [bool]$All = $false)
            & (Get-PSMutationWarmPesterScript) -tests @($script:firstFixture) -recordAllKillers $All -sandboxRoot $TestDrive -filter $Filter
        }
    }

    It 'runs only the tests named, a bracket in a name included' {
        # Escaped: a filter is a -like pattern.
        $out = Child -Filter 'd.c fails [x]'
        $out.Result | Should-Be 'Failed'
        @($out.Killers) | Should-BeCollection @('c fails [x]')
        @($out.FailedPath) | Should-BeCollection @('d.c fails [x]')
        $out.Ran | Should-Be 1
    }

    It 'runs the whole files without one' {
        $out = Child -Filter @()
        @($out.FailedPath) | Should-BeCollection @('d.b fails')
        $out.Ran | Should-Be 2
    }

    It 'names each test that passed or failed by the unexpanded path a filter matches' {
        $out = Child -Filter 'd.a passes', 'd.case <n>', 'd.b fails' -All $true
        $out.Result | Should-Be 'Failed'
        $out.Ran | Should-Be 4
        @($out.PassedPath | Sort-Object) | Should-BeCollection @('d.a passes', 'd.case <n>')
        @($out.FailedPath) | Should-BeCollection @('d.b fails')
    }

    It 'answers a filter that matches no test with a pass over nothing' {
        $out = Child -Filter 'd.gone'
        $out.Result | Should-Be 'Passed'
        $out.Ran | Should-Be 0
        @($out.PassedPath).Count | Should-Be 0
    }
}

Describe 'the child unloads the code under test before every run (#249)' {
    # The runspace is reused across mutants, and `Import-Module` without -Force returns a module
    # already loaded -- so a suite importing the code under test ran mutant 2 against mutant 1.
    # The child removes every module loaded from its OWN sandbox first, and nothing else.
    BeforeAll {
        function Import-ProbeModule {
            param([string]$Dir)
            $name = "PSMutProbe$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $path = Join-Path $Dir "$name.psm1"
            'function Get-Probe { 1 }' | Set-Content -LiteralPath $path
            Import-Module $path -Global
            return $name
        }
        function Invoke-Child {
            param([string]$SandboxRoot)
            $fixture = Join-Path $TestDrive "unload-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
            "Describe 'u' { It 'passes' { 1 | Should-Be 1 } }" | Set-Content -LiteralPath $fixture -Encoding utf8
            $null = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $false -sandboxRoot $SandboxRoot
        }
    }
    AfterEach { Get-Module PSMutProbe* | Remove-Module -Force }

    It 'removes a module loaded from the sandbox, and keeps one loaded from elsewhere' {
        $box = Join-Path $TestDrive "box-$([System.Guid]::NewGuid().ToString('N'))"
        $inside = Import-ProbeModule -Dir (Join-Path $box 'src')
        $outside = Import-ProbeModule -Dir (Join-Path $TestDrive "elsewhere-$([System.Guid]::NewGuid().ToString('N'))")
        Invoke-Child -SandboxRoot $box
        Should-BeNull -Actual (Get-Module $inside)
        Should-NotBeNull -Actual (Get-Module $outside)
    }

    It 'keeps a module from a SIBLING directory whose name merely starts the same' {
        # The root is matched with a separator after it: /tmp/box must not claim /tmp/box-2.
        $box = Join-Path $TestDrive "box-$([System.Guid]::NewGuid().ToString('N'))"
        $sibling = Import-ProbeModule -Dir "$box-2"
        Invoke-Child -SandboxRoot $box
        Should-NotBeNull -Actual (Get-Module $sibling)
    }

    It 'matches a root given with a trailing separator, and in another case' {
        # A Windows path can arrive with a different drive-letter case, and a root may or may
        # not end in a separator; neither may leave the code under test loaded.
        $box = Join-Path $TestDrive "box-$([System.Guid]::NewGuid().ToString('N'))"
        $one = Import-ProbeModule -Dir $box
        Invoke-Child -SandboxRoot ($box + [System.IO.Path]::DirectorySeparatorChar)
        Should-BeNull -Actual (Get-Module $one)
        $two = Import-ProbeModule -Dir $box
        Invoke-Child -SandboxRoot $box.ToUpperInvariant()
        Should-BeNull -Actual (Get-Module $two)
    }

    It 'passes over a module with no path, such as one made in memory' {
        $dynamic = "PSMutProbe$([System.Guid]::NewGuid().ToString('N'))"
        New-Module -Name $dynamic -ScriptBlock { function Get-InMemory { 1 } } | Import-Module -Global
        Invoke-Child -SandboxRoot (Join-Path $TestDrive 'any')
        Should-NotBeNull -Actual (Get-Module $dynamic)
    }
}

Describe 'retiring a timed-out runspace without waiting for it (#250)' {
    # Stop() is synchronous and waits for a blocking .NET call to return -- 7.4s for an 8s
    # Thread.Sleep, measured -- and the scheduler is single-threaded, so every worker stalled.
    BeforeAll {
        function Invoke-StuckWorker {
            param([int]$WorkerId, [int]$Milliseconds)
            $ps = Get-PSMutationWarmShell -WorkerId $WorkerId
            $ps.Commands.Clear()
            [void]$ps.AddScript("[System.Threading.Thread]::Sleep($Milliseconds)")
            $null = $ps.BeginInvoke()
            Start-Sleep -Milliseconds 200
        }
    }
    AfterEach {
        Close-PSMutationWarmRunspacePool
        # Anything still stuck is waited out here, in the test, so no runspace outlives it. The sleeps
        # above are as short as still proves the point -- a waiting stop on the 2s one would blow the
        # 1s assertion -- because this file covers Pester.ps1 and every mutant of it pays for them.
        foreach ($r in @($script:PSMutationRetiredRunspace)) { $null = $r.Stop.AsyncWaitHandle.WaitOne(15000) }
        Clear-PSMutationRetiredRunspace
    }

    It 'returns at once, takes the worker out of the pool, and parks the runspace' {
        Invoke-StuckWorker -WorkerId 7 -Milliseconds 2000
        $before = $script:PSMutationRetiredRunspace.Count
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-PSMutationWarmRunspace -WorkerId 7
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 1
        $script:PSMutationWarmShell.ContainsKey(7) | Should-BeFalse
        $script:PSMutationWarmRunspace.ContainsKey(7) | Should-BeFalse
        $script:PSMutationWarmUses.ContainsKey(7) | Should-BeFalse
        $script:PSMutationRetiredRunspace.Count | Should-Be ($before + 1)
    }

    It 'disposes a parked runspace only once its stop has finished' {
        Invoke-StuckWorker -WorkerId 8 -Milliseconds 1000
        Stop-PSMutationWarmRunspace -WorkerId 8
        $parked = $script:PSMutationRetiredRunspace[$script:PSMutationRetiredRunspace.Count - 1]
        Clear-PSMutationRetiredRunspace
        $script:PSMutationRetiredRunspace.Contains($parked) | Should-BeTrue -Because 'its stop is still waiting on the sleep'
        $parked.Runspace.RunspaceStateInfo.State | Should-NotBe 'Closed'
        $null = $parked.Stop.AsyncWaitHandle.WaitOne(15000)
        Clear-PSMutationRetiredRunspace
        $script:PSMutationRetiredRunspace.Contains($parked) | Should-BeFalse
        $parked.Runspace.RunspaceStateInfo.State | Should-Be 'Closed'
    }

    It 'is clearing work done whenever a shell is handed out' {
        Invoke-StuckWorker -WorkerId 9 -Milliseconds 300
        Stop-PSMutationWarmRunspace -WorkerId 9
        $parked = $script:PSMutationRetiredRunspace[$script:PSMutationRetiredRunspace.Count - 1]
        $null = $parked.Stop.AsyncWaitHandle.WaitOne(15000)
        $null = Get-PSMutationWarmShell -WorkerId 10
        $script:PSMutationRetiredRunspace.Contains($parked) | Should-BeFalse
    }

    It 'is done at the end of the run too' {
        Invoke-StuckWorker -WorkerId 11 -Milliseconds 300
        Stop-PSMutationWarmRunspace -WorkerId 11
        $parked = $script:PSMutationRetiredRunspace[$script:PSMutationRetiredRunspace.Count - 1]
        $null = $parked.Stop.AsyncWaitHandle.WaitOne(15000)
        Close-PSMutationWarmRunspacePool
        $script:PSMutationRetiredRunspace.Contains($parked) | Should-BeFalse
    }

    It 'does nothing for a worker that has no runspace' {
        $before = $script:PSMutationRetiredRunspace.Count
        Stop-PSMutationWarmRunspace -WorkerId 99
        $script:PSMutationRetiredRunspace.Count | Should-Be $before
    }
}

Describe 'a worker in a process of its own (#256)' {
    # Real pwsh processes, about 1.3s each to start with Pester imported, so as few as prove the
    # point: this file covers Pester.ps1, and every mutant of it pays for them.
    AfterEach { Close-PSMutationWarmRunspacePool }

    It 'runs in another process, with Pester, from this process''s directory; is reused, renewed on its own interval, and ended when replaced' {
        # One test rather than four, because each process costs every mutant of Pester.ps1.
        $shell = Get-PSMutationWarmShell -WorkerId 20 -Process
        $first = $script:PSMutationWarmProcess[20].Process
        $shell.Commands.Clear()
        [void]$shell.AddScript('$PID; (Get-Module Pester | Select-Object -First 1).Name; $PWD.ProviderPath')
        $out = @($shell.Invoke())
        $out[0] | Should-NotBe $PID
        $out[0] | Should-Be $first.Id
        $out[1] | Should-Be 'Pester'
        # Where an in-process runspace starts; a process left alone starts in the user's home.
        $out[2] | Should-Be ([System.Environment]::CurrentDirectory)
        Should-BeFalse -Actual (Test-PSMutationWorkerExited -WorkerId 20)
        # A breakpoint with an action fires there, as Pester's breakpoint coverage needs: a worker
        # process refuses Set-PSBreakpoint outright until its client allows remote debugging.
        $shell.Commands.Clear()
        [void]$shell.AddScript('$f = Join-Path ([IO.Path]::GetTempPath()) "psmut-bp-$([guid]::NewGuid().ToString(''N'')).ps1"; Set-Content $f ''1 | Out-Null''; $global:psmutHits = 0; $bp = Set-PSBreakpoint -Script $f -Line 1 -Action { $global:psmutHits++ }; . $f; Remove-PSBreakpoint $bp; Remove-Item $f; $global:psmutHits')
        @($shell.Invoke())[-1] | Should-Be 1
        [object]::ReferenceEquals($shell, (Get-PSMutationWarmShell -WorkerId 20 -Process)) | Should-BeTrue
        # Renewed on the PROCESS interval, which is not the runspace's: two uses are spent at two.
        $keep = $script:PSMutationWarmProcessLifetime
        try {
            $script:PSMutationWarmProcessLifetime = 2
            [object]::ReferenceEquals($shell, (Get-PSMutationWarmShell -WorkerId 20 -Process)) | Should-BeFalse
        }
        finally { $script:PSMutationWarmProcessLifetime = $keep }
        Should-BeTrue -Actual $first.WaitForExit(5000)
        # And a run that asks for this process is not handed the process worker.
        $second = $script:PSMutationWarmProcess[20].Process
        $local = Get-PSMutationWarmShell -WorkerId 20
        $local.Commands.Clear()
        [void]$local.AddScript('$PID')
        $local.Invoke()[0] | Should-Be $PID
        $script:PSMutationWarmProcess.ContainsKey(20) | Should-BeFalse
        Should-BeTrue -Actual $second.WaitForExit(5000)
    }

    It 'ends a worker stuck in a blocking call at once, without parking it' {
        # A stop request waits for a blocking .NET call to return; ending the process does not.
        $shell = Get-PSMutationWarmShell -WorkerId 22 -Process
        $proc = $script:PSMutationWarmProcess[22].Process
        $shell.Commands.Clear()
        [void]$shell.AddScript('[System.Threading.Thread]::Sleep(60000)')
        $null = $shell.BeginInvoke()
        Start-Sleep -Milliseconds 300
        $parked = $script:PSMutationRetiredRunspace.Count
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-PSMutationWarmRunspace -WorkerId 22
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 1
        Should-BeTrue -Actual $proc.WaitForExit(5000)
        $script:PSMutationRetiredRunspace.Count | Should-Be $parked
        foreach ($map in $script:PSMutationWarmShell, $script:PSMutationWarmRunspace, $script:PSMutationWarmUses, $script:PSMutationWarmProcess) {
            $map.ContainsKey(22) | Should-BeFalse
        }
    }

    It 'knows when its process died, and closes it without waiting on the dead runspace' {
        $shell = Get-PSMutationWarmShell -WorkerId 23 -Process
        $proc = $script:PSMutationWarmProcess[23].Process
        $shell.Commands.Clear()
        [void]$shell.AddScript('[System.Environment]::Exit(3)')
        $null = $shell.BeginInvoke()
        Should-BeTrue -Actual $proc.WaitForExit(10000)
        Should-BeTrue -Actual (Test-PSMutationWorkerExited -WorkerId 23)
        # Not handed out again, resumed and closed without waiting on its dead runspace.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Resume-PSMutationWorkerBreakpoint -WorkerId 23
        Close-PSMutationWarmRunspace -WorkerId 23
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 1
        $script:PSMutationWarmShell.ContainsKey(23) | Should-BeFalse
        $script:PSMutationWarmProcess.ContainsKey(23) | Should-BeFalse
    }

    It 'is not handed out again once its process has died' {
        # Reuse is asked before the runner has discarded the worker, so the pool itself refuses.
        $shell = Get-PSMutationWarmShell -WorkerId 27 -Process
        $proc = $script:PSMutationWarmProcess[27].Process
        $proc.Kill()
        Should-BeTrue -Actual $proc.WaitForExit(5000)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $next = Get-PSMutationWarmShell -WorkerId 27 -Process
        [object]::ReferenceEquals($shell, $next) | Should-BeFalse
        $script:PSMutationWarmProcess[27].Process.Id | Should-NotBe $proc.Id
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 10
    }

    It 'leaves no process behind when Pester will not import into it' {
        Mock Get-PSMutationPesterPath { Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-pester.psd1' }
        { Get-PSMutationWarmShell -WorkerId 24 -Process } | Should-Throw -ExceptionMessage '*Could not import Pester into the mutant runspace*'
        $script:PSMutationWarmProcess.ContainsKey(24) | Should-BeFalse
    }

    It 'serves five hundred mutants before it is renewed' {
        # A decision, pinned for the reason the runspace's fifty is: the test above is written in
        # terms of the variable.
        $script:PSMutationWarmProcessLifetime | Should-Be 500
    }

    It 'is resumed at a breakpoint that stops, as one in this process runs on' {
        $shell = Get-PSMutationWarmShell -WorkerId 28 -Process
        $shell.Commands.Clear()
        [void]$shell.AddScript('$f = Join-Path ([IO.Path]::GetTempPath()) "psmut-bp-$([guid]::NewGuid().ToString(''N'')).ps1"; Set-Content $f ''1 | Out-Null''; $bp = Set-PSBreakpoint -Script $f -Line 1; . $f; Remove-PSBreakpoint $bp; Remove-Item $f; ''ran on''')
        $async = $shell.BeginInvoke()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $script:PSMutationWarmRunspace[28].Debugger.InBreakpoint -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }
        Should-BeTrue -Actual $script:PSMutationWarmRunspace[28].Debugger.InBreakpoint
        Resume-PSMutationWorkerBreakpoint -WorkerId 28
        Should-BeTrue -Actual $async.AsyncWaitHandle.WaitOne(10000)
        @($shell.EndInvoke($async))[-1] | Should-Be 'ran on'
        # And nothing for a worker that is not a process, or not there -- where a resume would
        # throw, since a debugger that is not stopped refuses one.
        $local = Get-PSMutationWarmShell -WorkerId 29
        Resume-PSMutationWorkerBreakpoint -WorkerId 29
        Resume-PSMutationWorkerBreakpoint -WorkerId 98
        # And a worker in this process keeps its own breakpoints: RemoteScript, which a worker
        # process needs, would switch them off here -- measured, the action below then never runs.
        $local.Commands.Clear()
        [void]$local.AddScript('$f = Join-Path ([IO.Path]::GetTempPath()) "psmut-bp-$([guid]::NewGuid().ToString(''N'')).ps1"; Set-Content $f ''1 | Out-Null''; $global:psmutHits = 0; $bp = Set-PSBreakpoint -Script $f -Line 1 -Action { $global:psmutHits++ }; . $f; Remove-PSBreakpoint $bp; Remove-Item $f; $global:psmutHits')
        @($local.Invoke())[-1] | Should-Be 1
    }

    It 'is never said to have exited when it runs in this process' {
        $null = Get-PSMutationWarmShell -WorkerId 25
        Should-BeFalse -Actual (Test-PSMutationWorkerExited -WorkerId 25)
        $script:PSMutationWarmProcess.ContainsKey(25) | Should-BeFalse
    }
}

Describe 'the standard handles of a worker process (#309)' {
    AfterEach { Close-PSMutationWarmRunspacePool }

    It 'gives a child of a worker process the null device for each stream it does not redirect, and the worker stays usable' {
        # One child, nothing redirected, all three streams at once: each pwsh started costs every
        # mutant of Pester.ps1. On 0.9.0 its read of the input read the remoting channel and never
        # ended, and each of its writes broke the runspace.
        $shell = Get-PSMutationWarmShell -WorkerId 30 -Process
        $shell.Commands.Clear()
        [void]$shell.AddScript({
                $start = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                    '$n = [Console]::In.ReadToEnd().Length; [Console]::Error.WriteLine("to the error output"); [Console]::Out.WriteLine("to the output"); exit (7 + $n)') {
                    $start.ArgumentList.Add($a)
                }
                $start.UseShellExecute = $false
                $child = [System.Diagnostics.Process]::Start($start)
                if (-not $child.WaitForExit(15000)) { $child.Kill(); return 'the child did not end' }
                $child.ExitCode
            }.ToString())
        $async = $shell.BeginInvoke()
        Should-BeTrue -Actual $async.AsyncWaitHandle.WaitOne(30000)
        # 7: the input was empty, and both writes left the channel alone.
        @($shell.EndInvoke($async))[-1] | Should-Be 7
        $shell.Commands.Clear()
        [void]$shell.AddScript('$PID')
        $shell.Invoke()[0] | Should-Be $script:PSMutationWarmProcess[30].Process.Id
    }

    It 'leaves the output of the caller to a child it starts, when its worker runs in the caller' {
        # One worker runs in PSMutant's own process, whose handles are the caller's console and not a
        # channel. Asked in a pwsh of its own, so that the handles at stake are not this process's,
        # and through its output: a child it starts after the warm-up must still write there.
        $probe = Join-Path $TestDrive 'in-process-probe.ps1'
        Set-Content -LiteralPath $probe -Value @'
param($Source, $Pester)
Import-Module $Pester
. $Source
$null = Get-PSMutationWarmShell -WorkerId 0
$start = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("from the child")') { $start.ArgumentList.Add($a) }
$start.UseShellExecute = $false
[void][System.Diagnostics.Process]::Start($start).WaitForExit(15000)
'@
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src' -AdditionalChildPath 'PSMutation.Pester.ps1'
        # The pwsh a worker process runs, which this process need not be: a dotnet tool runs as dotnet.
        $pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
        $out = & $pwsh -NoLogo -NoProfile -NonInteractive -File $probe -Source $source -Pester (Get-PSMutationPesterPath)
        "$out" | Should-BeString 'from the child'
    }

    It 'names SetStdHandle on the three standard handles for Windows, and dup2 onto 0, 1 and 2 for Unix' {
        # Pinned for both platforms on either, because each CI leg runs only one of them.
        $windows = Get-PSMutationNullStdioPlan -Platform 'Win32NT'
        "$($windows.Library) $($windows.Entry) $($windows.Return) $($windows.Order -join ',') $($windows.Parameters -join ',') $($windows.Targets -join ',')" |
            Should-Be 'kernel32.dll SetStdHandle bool target,handle int,IntPtr -10,-11,-12'
        "$($windows.Path) $($windows.Share) $($windows.Handle)" | Should-Be 'NUL ReadWrite, Inheritable IntPtr'
        $unix = Get-PSMutationNullStdioPlan -Platform 'Unix'
        "$($unix.Library) $($unix.Entry) $($unix.Return) $($unix.Order -join ',') $($unix.Parameters -join ',') $($unix.Targets -join ',')" |
            Should-Be 'libc dup2 int handle,target int,int 0,1,2'
        "$($unix.Path) $($unix.Share) $($unix.Handle)" | Should-Be '/dev/null ReadWrite int'
    }

    It 'does nothing when the library of the plan does not load' {
        # The worker is then as it was before: a run that works for most suites, not one that
        # cannot start. Called here, in this process, which it must therefore leave alone.
        $plan = (Get-PSMutationNullStdioPlan -Platform ([string][System.Environment]::OSVersion.Platform)).PSObject.Copy()
        $plan.Library = 'psmutant-no-such-library'
        Should-BeNull -Actual (Set-PSMutationWorkerNullStdio -plan $plan)
    }

    It 'goes on past a target that the platform refuses' {
        # -1 is no standard handle and no descriptor, so the call fails and changes nothing here.
        $plan = (Get-PSMutationNullStdioPlan -Platform ([string][System.Environment]::OSVersion.Platform)).PSObject.Copy()
        $plan.Targets = @(-1, -1)
        Should-BeNull -Actual (Set-PSMutationWorkerNullStdio -plan $plan)
    }
}
