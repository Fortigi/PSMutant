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
        { Assert-PSMutationPester } | Should-Throw -ExceptionMessage '*Pester 5+ is required*'
    }

    It 'refuses when the LOADED Pester is too old, even though a newer one is installed' {
        # The tempting repair -- import the newer one -- is itself the bug: the old
        # assembly is already in the process, so the import fails rather than upgrades.
        # Refusing names the real problem while the session can still be restarted.
        $script:loaded = @([pscustomobject]@{ Version = [version]'4.10.1' })
        $script:available = @([pscustomobject]@{ Version = [version]'6.1.0' })
        { Assert-PSMutationPester } | Should-Throw -ExceptionMessage '*Pester 5+ is required*'
        Should-NotInvoke Import-Module
    }

    It 'accepts a loaded Pester of exactly the minimum version' {
        # -lt, not -le. 5.0.0 is the documented floor, so the boundary value itself has
        # to pass -- rejecting it would refuse the very version the manifest asks for.
        $script:loaded = @([pscustomobject]@{ Version = [version]'5.0.0' })
        Assert-PSMutationPester
        Should-NotInvoke Import-Module
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
