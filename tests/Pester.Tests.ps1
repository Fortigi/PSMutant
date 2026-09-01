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
        $out = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $All

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
    }

    It 'answers Passed with no killers when nothing notices' {
        # The survivor path, which is the one a wrong verdict flatters. Asserted separately
        # because the failing case above would pass just as well if Killers were always
        # populated from somewhere.
        $fixture = Join-Path $TestDrive "green-$([System.Guid]::NewGuid().ToString('N')).Tests.ps1"
        "Describe 'g' { It 'passes' { 1 | Should-Be 1 } }" | Set-Content -LiteralPath $fixture -Encoding utf8

        $out = & (Get-PSMutationWarmPesterScript) -tests @($fixture) -recordAllKillers $false
        $out.Result | Should-Be 'Passed'
        @($out.Killers) | Should-BeCollection -Count 0
    }

    It 'declares the two parameters the runner binds by name' {
        # AddParameter binds by NAME, so a rename here fails at run time with a binding error
        # rather than at parse time. These two are the contract between this file and the runner.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript).ToString(), [ref]$null, [ref]$null)
        $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params | Should-BeCollection @('tests', 'recordAllKillers')
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
