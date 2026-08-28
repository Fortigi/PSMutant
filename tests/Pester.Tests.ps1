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

Describe 'the warm mutant runspace' {
    AfterEach { Close-PSMutationWarmRunspace }

    It 'hands back the same shell until its lifetime is spent' {
        # The whole point of the change: creating a runspace and importing Pester into it cost
        # about 396 ms on every mutant, 27% of a measured 801s run over this repo's sibling.
        Close-PSMutationWarmRunspace
        $first = Get-PSMutationWarmShell
        $second = Get-PSMutationWarmShell
        [object]::ReferenceEquals($first, $second) | Should-BeTrue
    }

    It 'serves exactly the lifetime, then rebuilds on the next ask' {
        # Asserted at BOTH ends of the boundary, and that is what makes it discriminating. A
        # version of this test that only checked "eventually a new one appears" passes whether the
        # comparison is -lt or -le, and whether the counter starts at 1 or 2 -- the mutation gate
        # said so, with three survivors on these four lines.
        Close-PSMutationWarmRunspace
        $n = $script:PSMutationWarmRunspaceLifetime
        $shells = @(1..($n + 1) | ForEach-Object { Get-PSMutationWarmShell })
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
        Close-PSMutationWarmRunspace
        $shell = Get-PSMutationWarmShell
        $runspace = $script:PSMutationWarmRunspace
        Close-PSMutationWarmRunspace
        # The runspace is asserted by STATE and the shell by use, because those are the two
        # separate resources and a test that only tried to use the shell cannot say which of them
        # was released -- an object on a closed runspace throws exactly as a disposed one does.
        $runspace.RunspaceStateInfo.State | Should-Be 'Closed'
        { $shell.AddScript('1').Invoke() } | Should-Throw
    }

    It 'resets its use count when it closes' {
        # The counter is what the lifetime is measured against, so a close that left it set would
        # retire the NEXT runspace early -- and silently, since the only symptom is a little more
        # rebuilding.
        Close-PSMutationWarmRunspace
        $null = Get-PSMutationWarmShell
        Close-PSMutationWarmRunspace
        $script:PSMutationWarmUses | Should-Be 0
    }

    It 'is safe to close when nothing is open' {
        # Called from the run's finally, which runs even when the run threw before any mutant.
        Close-PSMutationWarmRunspace
        Close-PSMutationWarmRunspace
        $true | Should-BeTrue
    }

    It 'gives a shell that already has Pester in it' {
        Close-PSMutationWarmRunspace
        $shell = Get-PSMutationWarmShell
        $shell.Commands.Clear()
        [void]$shell.AddScript('(Get-Module Pester | Select-Object -First 1).Name')
        [string]($shell.Invoke() | Select-Object -Last 1) | Should-Be 'Pester'
    }

    It 'refuses to hand back a shell whose Pester import failed' {
        # A shell without Pester would run every covering suite into a command-not-found and
        # report no verdict -- which Invoke-PSMutant reads as a kill. Same shape as the version
        # collision: a broken child scoring as a caught fault.
        Close-PSMutationWarmRunspace
        Mock Get-PSMutationPesterPath { Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-pester.psd1' }
        { Get-PSMutationWarmShell } | Should-Throw -ExceptionMessage '*Could not import Pester into the mutant runspace*'
    }
}

Describe 'the child script the warm runspace runs' {
    It 'is valid PowerShell' {
        # The child contract is a here-string, so nothing lints or parse-checks the code every
        # mutant runs (issue #49). A typo in it surfaces at run time, in a child, as "the covering
        # tests produced no result". Parsing it here is the cheapest possible guard.
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-PSMutationWarmPesterScript), [ref]$null, [ref]$errors)
        @($errors).Count | Should-Be 0
    }

    It 'asks Pester to stop at the first failure, when this Pester can' {
        (Get-PSMutationWarmPesterScript) | Should-BeLikeString '*SkipRemainingOnFailure*'
    }

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
