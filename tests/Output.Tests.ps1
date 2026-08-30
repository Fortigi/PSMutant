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
        #
        # The literal list is the point. A role is a promise to every renderer, so growing the
        # vocabulary has to fail here first and be a decision -- this test caught Annotation
        # being added, which is the behaviour wanted rather than a nuisance.
        ((Get-PSMutationKnownRole) -join ',') | Should-Be 'Annotation,Bad,Banner,Detail,Good,Muted,Rule,Trace,Warn'
    }
}

Describe 'Test-PSMutationAnnotationHost' {
    # The one place that touches the real variable, because it is the thing under test. The
    # ORIGINAL value is restored rather than cleared: $env: is process state, this suite runs
    # inside CI where the variable is genuinely set, and a test that resets it to $null quietly
    # changes what every later test file sees. That is not hypothetical -- it is why the whole
    # suite passed locally and the gate failed.
    BeforeAll { $script:priorActions = $env:GITHUB_ACTIONS }
    AfterEach { $env:GITHUB_ACTIONS = $script:priorActions }
    AfterAll { $env:GITHUB_ACTIONS = $script:priorActions }

    It 'recognises a GitHub Actions step' {
        $env:GITHUB_ACTIONS = 'true'
        Should-BeTrue -Actual (Test-PSMutationAnnotationHost)
    }

    It 'does not treat an unset variable as a CI' {
        # The paired half, and the one that matters for a developer: emitting workflow commands
        # at a human puts '::warning' noise in front of them for no reason.
        $env:GITHUB_ACTIONS = $null
        Should-BeFalse -Actual (Test-PSMutationAnnotationHost)
    }

    It 'does not treat the string false as a CI' {
        # Actions sets this to the literal 'false' in some contexts, and any non-empty string is
        # truthy in PowerShell -- so a truthiness check here reads 'false' as yes.
        $env:GITHUB_ACTIONS = 'false'
        Should-BeFalse -Actual (Test-PSMutationAnnotationHost)
    }
}

Describe 'Get-PSMutationAnnotationLine' {
    BeforeAll {
        $script:row = [pscustomobject]@{ File = 'src/Thing.ps1'; Line = 42; Description = '-and -> -or' }
    }

    It 'points the annotation at the file and line from the DATA' {
        # The whole reason the Data field exists. Text here names a DIFFERENT file, so a
        # renderer that parsed the formatted string would produce 'wrong.ps1' and this fails.
        $line = New-PSMutationLine -Role 'Warn' -Data $script:row -Text '    wrong.ps1:999  something else'
        (Get-PSMutationAnnotationLine -Lines @($line)).Text |
            Should-Be '::warning file=src/Thing.ps1,line=42::Mutant survived: -and -> -or'
    }

    It 'annotates only the lines that carry a row' {
        # Both halves in one call. A heading has no file to point at, and an annotation without
        # a location renders against the workflow file -- sending the reviewer to YAML that has
        # nothing to do with the finding. A fixture of survivors alone cannot show that.
        $lines = @(
            New-PSMutationLine -Role 'Warn' -Text '  Survivors (add assertions to kill these):'
            New-PSMutationLine -Role 'Warn' -Data $script:row -Text '    src/Thing.ps1:42  -and -> -or'
            New-PSMutationLine -Role 'Detail' -Text '  Report: reports/x.json'
        )
        @(Get-PSMutationAnnotationLine -Lines $lines).Count | Should-Be 1
    }

    It 'skips a row that has no file to point at' {
        # A line can carry Data that is not a mutant row -- a summary object, or a row from a
        # future caller. An annotation with no location renders against the workflow file, so
        # the guard is on the FILE and not merely on Data being present.
        $line = New-PSMutationLine -Role 'Warn' -Data ([pscustomobject]@{ Total = 12 }) -Text 'x'
        @(Get-PSMutationAnnotationLine -Lines @($line)).Count | Should-Be 0
    }

    It 'skips a line with no row even under StrictMode' {
        # The guard on Data is NOT redundant with the guard on File, although $null.File
        # quietly yields $null in an ordinary session. Under Set-StrictMode -Version Latest --
        # which a consumer may well have on -- it THROWS, so dropping the first check turns a
        # heading line into an exception inside somebody else's build.
        #
        # Nothing else in this suite runs strict, which is exactly why the mutation gate found
        # this: the check looked like it did nothing.
        $lines = @(New-PSMutationLine -Role 'Warn' -Text '  Survivors (add assertions to kill these):')
        $out = & {
            Set-StrictMode -Version Latest
            Get-PSMutationAnnotationLine -Lines $lines
        }
        @($out).Count | Should-Be 0
    }

    It 'emits nothing at all when nothing survived' {
        $lines = @(New-PSMutationLine -Role 'Good' -Text '  Mutation score: 100%')
        @(Get-PSMutationAnnotationLine -Lines $lines).Count | Should-Be 0
    }

    It 'starts the line at the workflow command, with nothing before it' {
        # A workflow command is parsed from the START of the line. Anything ahead of the '::' --
        # an ANSI colour escape, an indent copied from the console format -- stops it being a
        # command and makes it a line of log nobody sees.
        $line = New-PSMutationLine -Role 'Warn' -Data $script:row -Text '    indented for a console'
        (Get-PSMutationAnnotationLine -Lines @($line)).Text | Should-BeLikeString '::warning*'
    }

    It 'carries the row through, so a later renderer need not re-derive it' {
        $line = New-PSMutationLine -Role 'Warn' -Data $script:row -Text 'x'
        (Get-PSMutationAnnotationLine -Lines @($line)).Data.File | Should-Be 'src/Thing.ps1'
    }
}

Describe 'Write-PSMutationOutput' {
    It 'renders an uncoloured role without asking for a colour' {
        # -ForegroundColor '' does not mean "no colour" -- it throws, because the empty string
        # is not a ConsoleColor. So the uncoloured case has to OMIT the parameter rather than
        # pass an empty value, and every other role supplies a real colour and never reaches
        # that branch.
        Get-PSMutationRoleColour -Role 'Annotation' | Should-Be ''
        # Rendered for real, and the absence of an exception is the assertion -- there is no
        # Should-NotThrow in Pester 6 because the runner already fails on one. Pass the empty
        # string through to -ForegroundColor and this line is where it dies.
        Write-PSMutationOutput -Lines @(New-PSMutationLine -Role 'Annotation' -Text '::warning file=a.ps1,line=1::x')
    }

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

Describe 'a line goes to the stream its role names' {
    It 'writes a Trace line to VERBOSE, never to the host' {
        # The module had no verbose stream at all, so -Verbose -- the usual first move when a
        # minutes-long run behaves oddly -- produced nothing. Asserted on the stream rather than
        # on the text, because the text would be identical whichever sink it reached.
        $verbose = Write-PSMutationOutput -Lines (New-PSMutationLine -Role 'Trace' -Text 'resolved x') `
            -Verbose 4>&1
        ($verbose | Out-String) | Should-MatchString 'resolved x'
    }

    It 'is NOT silenced by -Quiet, which is about the console log' {
        # The two switches answer different questions, and a consumer collecting a run's trace
        # while keeping CI output short wants exactly this combination. Gating verbose on -Quiet
        # would make that impossible and would silence a stream -Quiet was never about.
        $verbose = Write-PSMutationOutput -Lines (New-PSMutationLine -Role 'Trace' -Text 'still traced') `
            -Quiet -Verbose 4>&1
        ($verbose | Out-String) | Should-MatchString 'still traced'
    }

    It 'still silences ordinary console lines under -Quiet' {
        # The pairing: without it, a renderer that ignored -Quiet entirely would satisfy the two
        # tests above.
        $host6 = Write-PSMutationOutput -Lines (New-PSMutationLine -Role 'Detail' -Text 'console only') `
            -Quiet 6>&1
        ($host6 | Out-String) | Should-NotMatchString 'console only'
    }

    It 'still writes an ordinary line to the HOST when not quiet' {
        $host6 = Write-PSMutationOutput -Lines (New-PSMutationLine -Role 'Detail' -Text 'on the host') 6>&1
        ($host6 | Out-String) | Should-MatchString 'on the host'
    }
}

Describe 'Write-PSMutationProgress' {
    It 'computes the percentage, and clamps both ends' -ForEach @(
        @{ Index = 5; Total = 10; Expect = 50; Why = 'the ordinary case' }
        @{ Index = 0; Total = 0; Expect = 0; Why = 'a run with no candidates -- 100 * 0 / 0' }
        @{ Index = 11; Total = 10; Expect = 100; Why = 'an index past the total' }
        @{ Index = 1; Total = 1; Expect = 100; Why = 'the single-candidate run' }
        @{ Index = 1; Total = 3; Expect = 33; Why = 'a value that rounds' }
    ) {
        # Asserted on the NUMBER, extracted from the reporter for exactly this reason:
        # Write-Progress goes to a stream PowerShell cannot redirect, so inside the reporter the
        # arithmetic was unobservable and every mutant of it survived a "did not throw" test.
        # The 1-of-3 row is what tells multiplication from division apart.
        Get-PSMutationProgressPercent -Index $Index -Total $Total |
            Should-Be $Expect -Because "the percentage must be right for $Why"
    }

    It 'reports without throwing across the whole range of index and total' -ForEach @(
        @{ Index = 5; Total = 10; Why = 'an ordinary mutant' }
        @{ Index = 0; Total = 0; Why = 'a run whose files contributed no candidates -- 100 * 0 / 0' }
        @{ Index = 11; Total = 10; Why = 'an index past the total, which PercentComplete refuses' }
        @{ Index = 1; Total = 1; Why = 'the single-candidate run, exactly 100 percent' }
    ) {
        # PercentComplete demands 0..100 and THROWS rather than clamping, so each of these is a
        # terminating error mid-run rather than a cosmetic slip. The zero row is the one that
        # matters most: an empty run is a legitimate outcome, and it would divide by zero.
        $threw = $false
        try { Write-PSMutationProgress -Index $Index -Total $Total -Activity 'x' } catch { $threw = $true }
        $threw | Should-BeFalse -Because "progress must survive $Why"
    }
}
