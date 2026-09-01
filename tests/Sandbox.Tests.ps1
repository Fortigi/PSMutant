# Unit tests for the sandbox isolation layer, and the covering suite for
# src/PSMutation.Sandbox.ps1 in psmutant.self.config.json.
#
# It exercises real temp side-effects, so every fixture uses a unique name to stay clear of any
# concurrent runner sandbox -- including the one the mutation run measuring THIS file is using.
# The sweep tests, which delete other processes' sandboxes by design, cannot meet that condition
# and live in SandboxSweep.Tests.ps1, which is deliberately mapped by nothing.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
    $script:root = Split-Path -Parent $PSScriptRoot
}

Describe 'ConvertTo/From-PSMutationSandboxPath' {
    It 'maps a repo path into the sandbox preserving structure' {
        # Use a real temp root (not a hardcoded 'C:/...') so the .NET path math works on
        # Linux/macOS runners too - GetFullPath throws on a non-existent drive letter.
        $sbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        $sb = ConvertTo-PSMutationSandboxPath -Path (Join-Path $script:root 'src/x.ps1') `
            -RepoRoot $script:root -SandboxRoot $sbRoot
        ConvertFrom-PSMutationSandboxPath -Path $sb -SandboxRoot $sbRoot | Should-Be 'src/x.ps1'
    }

    It 'refuses a config path that lands outside the sandbox' -ForEach @(
        @{ Rel = '../victim/Real.ps1'; What = 'one level up' }
        @{ Rel = '../../far/Real.ps1'; What = 'two levels up, out of temp entirely' }
        @{ Rel = '..'; What = 'the repo parent itself, whose way back is exactly ..' }
    ) {
        # The third case is the one that needs the middle arm of the guard. The other two are
        # caught by the StartsWith test, because '../victim/x' begins with '../' -- but '..'
        # alone does NOT begin with '../', so with only the first and third arms it escapes.
        # Without it, an -or in that condition can be flipped to -and and no test notices.
        # The caller WRITES to whatever this returns. A leading `..` survives the re-rooting,
        # so an escaped path is mutated where it lives -- in the directory the sandbox exists
        # to replace -- and the promise that a hard kill cannot leave a mutant in tracked
        # source then rests on a `finally` rather than on never touching a real file.
        $sbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        { ConvertTo-PSMutationSandboxPath -Path (Join-Path $script:root $Rel) `
                -RepoRoot $script:root -SandboxRoot $sbRoot } |
            Should-Throw -ExceptionMessage '*resolves outside the source root*'
    }

    It 'allows a path that contains .. but resolves back inside' {
        # The case that separates a real check from a string search for '..'.
        # `src/../src/x.ps1` IS `src/x.ps1`, and a config written that way was never
        # ambiguous -- refusing it would reject something correct.
        $sbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        $sb = ConvertTo-PSMutationSandboxPath -Path (Join-Path $script:root 'src/../src/x.ps1') `
            -RepoRoot $script:root -SandboxRoot $sbRoot
        ConvertFrom-PSMutationSandboxPath -Path $sb -SandboxRoot $sbRoot | Should-Be 'src/x.ps1'
    }

    It 'names the offending path and where it would have landed' {
        # The reader has to fix a config entry, so the message has to say which one -- and
        # the resolved target is what makes "outside" concrete rather than abstract.
        $sbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        { ConvertTo-PSMutationSandboxPath -Path (Join-Path $script:root '../shared/Util.ps1') `
                -RepoRoot $script:root -SandboxRoot $sbRoot } |
            Should-Throw -ExceptionMessage '*Util.ps1*mutated in place*-SourceRoot*'
    }
}

Describe 'New/Remove-PSMutationSandbox' {
    It 'copies only the requested subtrees into a fresh temp dir' {
        $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-src-$PID-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'keep') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'skip') -Force | Out-Null
        'hi' | Set-Content (Join-Path $srcDir 'keep/file.txt')
        $name = "psmut-sandbox-test-$([System.Guid]::NewGuid().ToString('N'))"
        try {
            $sb = New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name
            Test-Path (Join-Path $sb 'keep/file.txt') | Should-BeTrue
            Test-Path (Join-Path $sb 'skip')          | Should-BeFalse

            Remove-PSMutationSandbox -SandboxRoot $sb
            Test-Path $sb | Should-BeFalse
        }
        finally {
            Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path ([System.IO.Path]::GetTempPath()) $name) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'REFUSES a path that already exists rather than clearing it' {
        # This replaces a test that asserted the opposite, and the reversal is the security fix.
        #
        # The old name was exactly "psmut-sandbox-$PID", so a killed run left a directory the next
        # run in the same shell would reuse -- and clearing it first was how merging was avoided.
        # Clearing is also what made the sandbox attackable: temp is world-writable, another local
        # user could create that predictable path first as a symlink, the removal of THEIR entry
        # fails on a sticky directory, the failure is non-terminating, and the copy then wrote the
        # source through the link. Reproduced end to end.
        #
        # With an unguessable name there is no reuse to design for, so the safe answer is available:
        # refuse. A path that exists under a 128-bit random name is not a collision.
        $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-src-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'keep') -Force | Out-Null
        'current' | Set-Content (Join-Path $srcDir 'keep/file.txt')
        $name = "psmut-sandbox-test-$([System.Guid]::NewGuid().ToString('N'))"
        $occupied = Join-Path ([System.IO.Path]::GetTempPath()) $name
        try {
            New-Item -ItemType Directory -Path (Join-Path $occupied 'keep') -Force | Out-Null
            'left over from a killed run' | Set-Content (Join-Path $occupied 'keep/file.txt')

            # Asserted against the LAST line of the message, not the first. The message is four
            # string operands joined by '+', and PowerShell's failure mode for a broken join
            # quotes the left operand back at you: "Cannot convert value '<the whole first
            # string>' to type System.Int32". A wildcard matching text from operand one therefore
            # passes for a message that was never actually built -- measured, against the mutant
            # that turns that '+' into '-'. Text from the last operand can only appear if the
            # concatenation ran.
            { New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name } |
                Should-Throw -ExceptionMessage '*investigate if you do not*'
            # And it did not touch what was there, which is the half that matters when the thing
            # in the way belongs to somebody else.
            Get-Content (Join-Path $occupied 'keep/file.txt') | Should-Be 'left over from a killed run'
        }
        finally {
            Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $occupied -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a sandbox path that is a SYMLINK to somewhere else' {
        # The attack itself, as a test. Another local user cannot be simulated here, but the shape
        # they create can: a link where the sandbox is about to be, pointing at a directory they
        # own. Without the guard the source is copied through it.
        $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-src-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'keep') -Force | Out-Null
        'secret' | Set-Content (Join-Path $srcDir 'keep/file.txt')
        $elsewhere = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-elsewhere-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        $name = "psmut-sandbox-test-$([System.Guid]::NewGuid().ToString('N'))"
        $link = Join-Path ([System.IO.Path]::GetTempPath()) $name
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $elsewhere -Force | Out-Null
            { New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name } |
                Should-Throw -ExceptionMessage '*already there*'
            @(Get-ChildItem $elsewhere -Recurse -File -ErrorAction SilentlyContinue).Count | Should-Be 0
        }
        finally {
            Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $elsewhere -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'names a sandbox nobody can guess, and differently every time' {
        # The property the fix rests on. Two names from one process must differ, and both must
        # carry the process id the stale sweep identifies an owner by.
        $a = New-PSMutationSandboxName
        $b = New-PSMutationSandboxName
        $a | Should-NotBe $b
        $a | Should-MatchString "^psmut-sandbox-$PID-[0-9a-f]{32}$"
        Get-PSMutationSandboxOwnerId -Name $a | Should-Be $PID
    }

    It 'refuses a sandbox path that turns out not to be a real directory' {
        # Assert-PSMutationSandboxReal is the guard for the RACE, and it is tested directly
        # because that is the only way to reach it: Assert-PSMutationSandboxPath refuses an
        # existing path first, so through New-PSMutationSandbox this arm fires only when a path
        # is substituted between the check and the create. That window is real -- it is why the
        # check is repeated after creation -- and not something a test can schedule.
        $elsewhere = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-elsewhere-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        $link = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-link-$([System.Guid]::NewGuid().ToString('N'))"
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-file-$([System.Guid]::NewGuid().ToString('N'))"
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $elsewhere -Force | Out-Null
            'not a directory' | Set-Content -LiteralPath $file
            { Assert-PSMutationSandboxReal -Path $link } | Should-Throw -ExceptionMessage '*not a directory this run created*'
            { Assert-PSMutationSandboxReal -Path $file } | Should-Throw -ExceptionMessage '*not a directory this run created*'
            # And it says which of the two it found, because the answers send you to different places.
            { Assert-PSMutationSandboxReal -Path $file } | Should-Throw -ExceptionMessage '*is a file*'
            # The other arm of that same ternary: a link is named by its TYPE and its target, so
            # the message says where the writes would have gone. Asserting only 'not a directory
            # this run created' passes just as well when the link is described as a plain file,
            # which is the one description that sends the reader nowhere.
            { Assert-PSMutationSandboxReal -Path $link } |
                Should-Throw -ExceptionMessage "*SymbolicLink to '$elsewhere'*"
        }
        finally {
            Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            Remove-Item $elsewhere -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts the ordinary case: a plain directory it just made' {
        # The other half. A guard asserted only by what it rejects would pass just as well if it
        # rejected everything.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-real-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # Called directly rather than wrapped: the assertion is that it returns, and a throw here
        # fails the test on its own with the real error rather than a wrapper's.
        try { Assert-PSMutationSandboxReal -Path $dir; $true | Should-BeTrue }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'creates NOTHING under -WhatIf' {
        # ShouldProcess is declared, so -WhatIf must actually preview. Without an assertion here
        # the guard can be forced true and every -WhatIf run does the work it promised to describe
        # -- which for this command means copying a source tree into temp.
        $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-src-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'keep') -Force | Out-Null
        'current' | Set-Content (Join-Path $srcDir 'keep/file.txt')
        $name = "psmut-sandbox-test-$([System.Guid]::NewGuid().ToString('N'))"
        try {
            New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name -WhatIf | Out-Null
            Should-BeFalse -Actual (Test-Path (Join-Path ([System.IO.Path]::GetTempPath()) $name))
        }
        finally {
            Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path ([System.IO.Path]::GetTempPath()) $name) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not REACH the removal under -WhatIf' {
        # Asserted by mocking Remove-Item rather than by checking the tree afterwards, and the
        # difference is not stylistic. -WhatIf propagates into nested cmdlets: with the outer
        # ShouldProcess forced true, the inner Remove-Item is ITSELF in WhatIf mode and still
        # deletes nothing, so a surviving tree proves only that PowerShell propagated the
        # preference. Measured -- the file-based version of this test passed against the mutant.
        # A mock has no WhatIf semantics, so reaching it is observable.
        Mock Remove-Item { }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-whatif-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            Remove-PSMutationSandbox -SandboxRoot $dir -WhatIf
            Should-Invoke Remove-Item -Times 0
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Remove-PSMutationSandbox is a no-op on a path that is already gone' {
        # Called from a finally block, so it runs even when the sandbox was never
        # created (an early throw). Throwing there would mask the original error.
        # Asserted as 'never reached the removal', not as 'the path is still absent' -- the
        # second is true however the function behaves, since Remove-Item on a missing path with
        # -ErrorAction SilentlyContinue is itself a silent no-op. That made the Test-Path guard
        # unfalsifiable from outside: measured, forcing it true left every assertion passing.
        Mock Remove-Item { }
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-never-$([System.Guid]::NewGuid().ToString('N'))"
        Remove-PSMutationSandbox -SandboxRoot $gone
        Should-Invoke Remove-Item -Times 0
        Should-BeFalse -Actual (Test-Path $gone)
    }
}

Describe 'Get-PSMutationSandboxOwnerId' {
    It 'reads the process id out of a runner sandbox name' {
        Get-PSMutationSandboxOwnerId -Name 'psmut-sandbox-1234' | Should-Be 1234
    }
    It 'reads the process id out of a legacy coverage file name' {
        # The TRANSITIONAL arm: older versions wrote psmut-coverage-<pid>.xml to temp and
        # nothing ever deleted it. It is the only reason that arm exists, and it was reachable
        # by no test -- so the regex, the [int] cast and the capture-group index were all free
        # to be wrong. The value is asserted, not just its presence: an index pointing at the
        # wrong group returns nothing, which a truthiness check cannot tell from a match.
        Get-PSMutationSandboxOwnerId -Name 'psmut-coverage-1234.xml' | Should-Be 1234
    }

    It 'returns nothing for a name the runner never produces' {
        # The runner only ever creates psmut-sandbox-<pid>. Anything else under that
        # prefix belongs to somebody else -- including this suite's own fixtures --
        # and must not be treated as a sandbox to reclaim.
        foreach ($n in 'psmut-sandbox-test-abc', 'psmut-sandbox-', 'psmut-sandbox-12ab', 'unrelated') {
            Should-BeNull -Actual (Get-PSMutationSandboxOwnerId -Name $n)
        }
    }
}

Describe 'Test-PSMutationSandboxAbandoned' {
    BeforeAll {
        function script:NewDir([string]$Name, [datetime]$Created = (Get-Date)) {
            [pscustomobject]@{ Name = $Name; CreationTime = $Created }
        }
    }

    It 'leaves a directory alone when the name carries no process id' {
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-test-abc') | Should-BeFalse
    }

    It 'SPARES a directory holding our own process id, because a live sibling run may own it' {
        # This assertion is INVERTED from what it used to be, and the inversion is the fix. It
        # read "reclaims a directory already holding our own process id", on the argument that
        # such a directory was a leftover from an earlier process that happened to get this id
        # and that we were about to recreate the path anyway.
        #
        # The second half stopped being true when the sandbox name gained 128 bits of randomness:
        # a new run creates a DIFFERENT directory, so there is nothing to recreate. What the
        # carve-out still did was make this process's own live sandboxes reclaimable -- measured,
        # a sibling run's sandbox and the caller's own both read as abandoned, which is what
        # deletes a nested run's working files mid-flight.
        #
        # What is given up is reclaiming a crashed run's leftovers while the same process is
        # still alive. With the process alive there is no way to tell that from a live sibling,
        # and deleting a live run's files is worse than leaving a directory until the process
        # exits.
        Test-PSMutationSandboxAbandoned -Directory (NewDir "psmut-sandbox-$PID") |
            Should-BeFalse
    }

    It 'still reclaims a directory whose owner really is gone, same shape' {
        # The pairing: without it, a predicate that spared everything would satisfy the test
        # above. Same name shape, an owner id that no live process holds.
        Mock Get-Process { $null }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-424242') |
            Should-BeTrue
    }

    It 'reclaims a sandbox whose owning process is gone' {
        Mock Get-Process { $null }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242') | Should-BeTrue
    }

    It 'SPARES a sandbox whose owning process is still running' {
        # The bug: the sweep deleted this, so starting a second run pulled the first
        # run's source files out from under it and it failed later with a confusing
        # missing-file error.
        $dirCreated = Get-Date
        Mock Get-Process { [pscustomobject]@{ StartTime = $dirCreated.AddMinutes(-5) } }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242' $dirCreated) |
            Should-BeFalse
    }

    It 'reclaims a sandbox whose id has been RECYCLED onto a newer process' {
        # The id is live, but that process started after the directory existed, so it
        # cannot be the owner. Without this, a recycled id leaks the directory forever.
        $dirCreated = Get-Date
        Mock Get-Process { [pscustomobject]@{ StartTime = $dirCreated.AddMinutes(5) } }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242' $dirCreated) |
            Should-BeTrue
    }

    It 'SPARES a sandbox whose owner started at the very tick it was created' {
        # The boundary between the two cases above, and it is not academic: the sandbox is
        # created BY its owner, so creation can never precede the start, and equal is what a
        # coarse clock reports for the ordinary case. It must read as 'still running' -- with
        # the comparison relaxed to -ge, an equal pair reclaims the sandbox of a LIVE run and
        # pulls its source files out from under it, which is the bug the recycled-id arm was
        # added to fix, reintroduced from the other side.
        $dirCreated = Get-Date
        Mock Get-Process { [pscustomobject]@{ StartTime = $dirCreated } }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242' $dirCreated) |
            Should-BeFalse
    }

    It 'spares a sandbox when the owner start time cannot be read' {
        # Protected/system processes fail on StartTime. Note the failure is
        # NON-terminating: the property yields $null rather than raising into a
        # catch, which is why the value is tested rather than the exception. An
        # earlier version of this test asserted the right answer while never
        # executing the fallback at all.
        $proc = New-Object psobject
        $proc | Add-Member ScriptProperty StartTime { throw 'Access is denied' }
        Mock Get-Process { $proc }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242') | Should-BeFalse
    }

    It 'treats an unreadable start time as the distant past' {
        # Directly pins the fallback the case above relies on.
        Get-PSMutationProcessStart -Process ([pscustomobject]@{ StartTime = $null }) |
            Should-Be ([datetime]::MinValue)
    }

    It 'returns a readable start time unchanged' {
        $when = [datetime]'2026-01-02T03:04:05'
        Get-PSMutationProcessStart -Process ([pscustomobject]@{ StartTime = $when }) | Should-Be $when
    }
}

Describe 'Get-PSMutationWorkerPath' {
    It 'leaves worker 0 alone, because it mutates the primary sandbox itself' {
        # An identity rather than a special case: with one worker the whole re-rooting question
        # does not arise, which is what keeps a serial run byte-identical to what it was before
        # workers existed.
        $sb = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        Get-PSMutationWorkerPath -Path (Join-Path $sb 'src/a.ps1') -SandboxRoot $sb -WorkerRoot $sb |
            Should-Be (Join-Path $sb 'src/a.ps1')
    }

    It 'answers even when both roots are empty, which is what shows the two arms differ' {
        # The identity arm is not an optimisation of the other one. GetRelativePath THROWS on an
        # empty base, so with the guard forced away this input fails outright -- which is the only
        # thing that tells the two apart, since for a normalised path under a real root they
        # return the same string.
        Get-PSMutationWorkerPath -Path '/x/a.ps1' -SandboxRoot '' -WorkerRoot '' | Should-Be '/x/a.ps1'
    }

    It 'moves a path into another worker''s copy, structure preserved' {
        $sb = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        $w = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        Get-PSMutationWorkerPath -Path (Join-Path $sb 'src/a.ps1') -SandboxRoot $sb -WorkerRoot $w |
            Should-Be ([System.IO.Path]::GetFullPath((Join-Path $w 'src/a.ps1')))
    }

    It 'refuses a path that escapes the worker sandbox, on the same terms as the primary one' {
        # Reused rather than string-replaced, so a worker path is refused for escaping on exactly
        # the terms the primary one is -- and so a root that is a prefix of an unrelated directory
        # beside it cannot be matched by accident.
        $sb = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        $w = Join-Path ([System.IO.Path]::GetTempPath()) "sb-$([System.Guid]::NewGuid().ToString('N'))"
        { Get-PSMutationWorkerPath -Path (Join-Path $sb '../outside.ps1') -SandboxRoot $sb -WorkerRoot $w } |
            Should-Throw -ExceptionMessage '*resolves outside the source root*'
    }
}

Describe 'New-PSMutationWorkerSandbox' {
    BeforeAll {
        $script:pRoot = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-primary-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:pRoot 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:pRoot 'src/a.ps1') -Value 'original'
        $script:made = @()
    }
    AfterAll {
        foreach ($m in $script:made) { Remove-Item $m -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item $script:pRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates through the sandbox factory, so -WhatIf still reaches it' {
        # There is no ShouldProcess of its own: a second gate over the same act is unobservable,
        # and New-PSMutationSandbox already has one. What has to stay true is that this goes
        # THROUGH that function rather than copying by hand, or the guards on the sandbox name
        # and the reparse-point check would be bypassed for every worker past the first.
        Mock New-PSMutationSandbox { 'stand-in' }
        # ASSIGNED, never piped: the return is comma-wrapped so an empty result survives, and a
        # pipeline hands the wrapper along as one object rather than unrolling it.
        $made = New-PSMutationWorkerSandbox -SandboxRoot $script:pRoot -Subtrees @('src') -Count 3
        $made | Should-BeCollection @('stand-in', 'stand-in', 'stand-in')
        Should-Invoke New-PSMutationSandbox -Exactly 3 -ParameterFilter { $RepoRoot -eq $script:pRoot }
    }

    It 'copies nothing for a serial run' {
        # Worker 0 mutates the primary sandbox, so one worker means nothing extra is copied --
        # and the caller needs no branch to say so.
        $r = New-PSMutationWorkerSandbox -SandboxRoot $script:pRoot -Subtrees @('src') -Count 0
        @($r).Count | Should-Be 0
        # An ARRAY, not $null. The caller counts it to learn how many workers it has, and $null
        # would still count 0 while joining a null root into the pool that no worker can mutate in.
        $r -is [array] | Should-BeTrue
    }

    It 'clones the PRIMARY SANDBOX, once per extra worker' {
        # Cloned from the sandbox rather than from tracked source: the primary is what the
        # candidate list, the covered lines and the baseline were all computed against, so a
        # worker's copy is the same bytes those decisions were made on. Re-copying the repo would
        # re-read files that may have been edited since the run started.
        $r = New-PSMutationWorkerSandbox -SandboxRoot $script:pRoot -Subtrees @('src') -Count 2
        $script:made += @($r)
        @($r).Count | Should-Be 2
        $r[0] | Should-NotBe $r[1]
        foreach ($w in $r) {
            Get-Content -LiteralPath (Join-Path $w 'src/a.ps1') -Raw | Should-MatchString 'original'
        }
    }
}
