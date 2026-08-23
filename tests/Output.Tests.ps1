# Unit tests for the console seam (src/PSMutation.Output.ps1), and the covering suite for
# self-mutating it - keep it self-contained.
#
# This is the ONLY file that mocks Write-Host, and deliberately so. Everywhere else the
# question "what should the run say" is answered by a function returning lines, which is
# assertable without touching the host. Here the subject IS the emitting, so the mock is
# the thing under test rather than a way around an untestable design.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Output.ps1')
}

Describe 'New-PSMutationLine' {
    It 'carries exactly the fields a renderer may depend on' {
        # The line shape is a contract between the deciding half and every renderer,
        # including ones not written yet. Widening it should cost a deliberate edit rather
        # than happening as a side effect of an internal change.
        $line = New-PSMutationLine -Role 'Good' -Text 'hello'
        ($line.PSObject.Properties.Name -join ',') | Should-Be 'Role,Text,Data'
    }

    It 'keeps the role and text it was given' {
        $line = New-PSMutationLine -Role 'Warn' -Text '  two survivors'
        $line.Role | Should-Be 'Warn'
        $line.Text | Should-Be '  two survivors'
    }

    It 'carries a record when one is supplied, and $null when not' {
        # Paired, because a fixture that always passes -Data cannot tell a working
        # parameter from one hard-wired to the last thing it saw.
        $row = [pscustomobject]@{ File = 'a.ps1'; Line = 7 }
        (New-PSMutationLine -Role 'Warn' -Text 'x' -Data $row).Data.Line | Should-Be 7
        Should-BeNull -Actual (New-PSMutationLine -Role 'Warn' -Text 'x').Data
    }

    It 'accepts an empty string, which is a blank line and not a mistake' {
        (New-PSMutationLine -Role 'Detail' -Text '').Text | Should-Be ''
    }

    It 'refuses an unknown role and names the valid ones' {
        # Not a silent fallback to a default colour. An unrecognised role means a renderer
        # will not know what to do with the line, which surfaces as output going missing in
        # whichever renderer was added last -- far from the typo that caused it.
        { New-PSMutationLine -Role 'Urgent' -Text 'x' } |
            Should-Throw -ExceptionMessage "*Unknown output role 'Urgent'*Banner*"
    }
}

Describe 'Get-PSMutationRoleColour' {
    It 'maps <Role> to <Expected>' -ForEach @(
        @{ Role = 'Banner'; Expected = 'Cyan' }
        @{ Role = 'Good'; Expected = 'Green' }
        @{ Role = 'Warn'; Expected = 'Yellow' }
        @{ Role = 'Bad'; Expected = 'Red' }
        @{ Role = 'Detail'; Expected = 'Gray' }
        @{ Role = 'Muted'; Expected = 'DarkGray' }
        @{ Role = 'Rule'; Expected = 'DarkGray' }
    ) {
        # Every role, not a sample: this table is where the console vocabulary now lives,
        # so an unmapped role is a runtime throw in the middle of a run's output.
        Get-PSMutationRoleColour -Role $Role | Should-Be $Expected
    }

    It 'refuses an unknown role' {
        { Get-PSMutationRoleColour -Role 'Chartreuse' } |
            Should-Throw -ExceptionMessage "*Unknown output role 'Chartreuse'*"
    }
}

Describe 'Get-PSMutationKnownRole' {
    It 'lists every role, sorted' {
        # Joined and compared as a string: Should-BeCollection ignores order and has no
        # strict switch, so it would pass against an unsorted list.
        ((Get-PSMutationKnownRole) -join ',') | Should-Be 'Bad,Banner,Detail,Good,Muted,Rule,Warn'
    }
}

Describe 'Write-PSMutationOutput' {
    BeforeEach {
        $script:said = [System.Collections.Generic.List[string]]::new()
        $script:colours = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:said.Add([string]$Object); $script:colours.Add([string]$ForegroundColor) }
    }

    It 'emits one line each, in the order given' {
        # Order is the claim, so the texts are joined and compared as a string --
        # Should-BeCollection would pass against them arriving backwards.
        Write-PSMutationOutput -Lines @(
            (New-PSMutationLine -Role 'Banner' -Text 'first')
            (New-PSMutationLine -Role 'Detail' -Text 'second')
        )
        ($script:said -join ',') | Should-Be 'first,second'
    }

    It 'colours each line by its role' {
        Write-PSMutationOutput -Lines @(
            (New-PSMutationLine -Role 'Bad' -Text 'broken')
            (New-PSMutationLine -Role 'Good' -Text 'fine')
        )
        ($script:colours -join ',') | Should-Be 'Red,Green'
    }

    It 'says nothing at all when quiet' {
        # The whole -Quiet contract, in one place. Guarded at each call site instead, a new
        # emitter that forgets prints in quiet mode and no existing test notices, because
        # they assert on the output the CURRENT callers produce.
        Write-PSMutationOutput -Quiet -Lines @(
            (New-PSMutationLine -Role 'Banner' -Text 'first')
            (New-PSMutationLine -Role 'Bad' -Text 'second')
        )
        Should-NotInvoke Write-Host
    }

    It 'accepts an empty collection without emitting anything' {
        # A section that produced no lines is an ordinary outcome, not a caller error.
        Write-PSMutationOutput -Lines @()
        Should-NotInvoke Write-Host
    }

    It 'emits a single line passed without a wrapping array' {
        # The commonest call in the codebase: one New-PSMutationLine handed straight in,
        # which PowerShell binds as a scalar rather than a collection.
        Write-PSMutationOutput -Lines (New-PSMutationLine -Role 'Good' -Text 'alone')
        ($script:said -join ',') | Should-Be 'alone'
    }
}
