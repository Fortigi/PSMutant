# Unit tests for the sandbox isolation layer. NOT a self-mutation covering suite (it
# exercises real temp side-effects), so it uses unique sandbox names to stay clear of
# any concurrent runner sandbox.

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
    ) {
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

            { New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name } |
                Should-Throw -ExceptionMessage '*already there*'
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

    It 'Remove-PSMutationSandbox is a no-op on a path that is already gone' {
        # Called from a finally block, so it runs even when the sandbox was never
        # created (an early throw). Throwing there would mask the original error.
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-never-$([System.Guid]::NewGuid().ToString('N'))"
        Remove-PSMutationSandbox -SandboxRoot $gone
        Should-BeFalse -Actual (Test-Path $gone)
    }
}

Describe 'Get-PSMutationSandboxOwnerId' {
    It 'reads the process id out of a runner sandbox name' {
        Get-PSMutationSandboxOwnerId -Name 'psmut-sandbox-1234' | Should-Be 1234
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

    It 'reclaims a directory already holding our own process id' {
        # A leftover from an earlier process that happened to get this id; we are
        # about to recreate the path anyway.
        Test-PSMutationSandboxAbandoned -Directory (NewDir "psmut-sandbox-$PID") -CurrentProcessId $PID | Should-BeTrue
    }

    It 'reclaims a sandbox whose owning process is gone' {
        Mock Get-Process { $null }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242') -CurrentProcessId 1 | Should-BeTrue
    }

    It 'SPARES a sandbox whose owning process is still running' {
        # The bug: the sweep deleted this, so starting a second run pulled the first
        # run's source files out from under it and it failed later with a confusing
        # missing-file error.
        $dirCreated = Get-Date
        Mock Get-Process { [pscustomobject]@{ StartTime = $dirCreated.AddMinutes(-5) } }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242' $dirCreated) -CurrentProcessId 1 |
            Should-BeFalse
    }

    It 'reclaims a sandbox whose id has been RECYCLED onto a newer process' {
        # The id is live, but that process started after the directory existed, so it
        # cannot be the owner. Without this, a recycled id leaks the directory forever.
        $dirCreated = Get-Date
        Mock Get-Process { [pscustomobject]@{ StartTime = $dirCreated.AddMinutes(5) } }
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242' $dirCreated) -CurrentProcessId 1 |
            Should-BeTrue
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
        Test-PSMutationSandboxAbandoned -Directory (NewDir 'psmut-sandbox-4242') -CurrentProcessId 1 | Should-BeFalse
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

Describe 'Clear-PSMutationStaleSandbox' {
    It 'sweeps a sandbox left behind by a killed run' {
        # Runs at startup, which is why a killed run does not accumulate temp dirs
        # forever. The name must carry a dead process id, because that is the only
        # shape the runner creates and the only one the sweep now reclaims.
        do { $deadId = Get-Random -Minimum 100000 -Maximum 999999 }
        until (-not (Get-Process -Id $deadId -ErrorAction SilentlyContinue))

        $stale = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-sandbox-$deadId"
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        'junk' | Set-Content (Join-Path $stale 'leftover.txt')
        try {
            Clear-PSMutationStaleSandbox
            Test-Path $stale | Should-BeFalse
        }
        finally { Remove-Item $stale -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'spares a live process''s sandbox while reclaiming a dead one in the same sweep' {
        # THE test for issue #2, and the one thing nothing asserted: that the sweep APPLIES
        # its filter. Deleting the `Where-Object { Test-PSMutationSandboxAbandoned ... }`
        # stage from Clear-PSMutationStaleSandbox reverts the module to the #2 bug -- a
        # concurrent run's files pulled out from under it -- and before this test the entire
        # 246-test suite still passed.
        #
        # It needs a REAL second process, because the predicate resolves ownership from the
        # process id in the directory name and treats OUR id as reclaimable by design. A
        # sandbox named for our own $PID is therefore one the sweep is entitled to delete,
        # which is why the predicate test above cannot stand in for this.
        #
        # The pairing is the point: spared AND reclaimed in one sweep is what proves a
        # filter rather than an inert pipeline stage.
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 30' -PassThru
        do { $deadId = Get-Random -Minimum 100000 -Maximum 999999 }
        until (-not (Get-Process -Id $deadId -ErrorAction SilentlyContinue))

        $temp = [System.IO.Path]::GetTempPath()
        $live = Join-Path $temp "psmut-sandbox-$($proc.Id)"
        $dead = Join-Path $temp "psmut-sandbox-$deadId"
        try {
            # Created AFTER the process started, so the recycled-id rule (a process that
            # began after its sandbox cannot own it) does not fire and the owner reads live.
            New-Item -ItemType Directory -Path $live -Force | Out-Null
            New-Item -ItemType Directory -Path $dead -Force | Out-Null
            'in use' | Set-Content (Join-Path $live 'live.txt')

            Clear-PSMutationStaleSandbox

            Test-Path $live | Should-BeTrue
            Test-Path $dead | Should-BeFalse
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item $live, $dead -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats a foreign live owner as not abandoned' {
        # A PREDICATE test, not an end-to-end one -- it never calls the sweep. The test
        # below does that, and had to be written because this one's old title claimed to.
        # Our own id stands in for "a live process", since it is by definition running.
        $live = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-sandbox-$PID"
        $preExisting = Test-Path $live
        if (-not $preExisting) { New-Item -ItemType Directory -Path $live -Force | Out-Null }
        'in use' | Set-Content (Join-Path $live 'live.txt')
        try {
            # CurrentProcessId is deliberately something else, so $PID reads as a
            # foreign, live owner rather than as our own reclaimable leftover.
            Test-PSMutationSandboxAbandoned -Directory (Get-Item $live) -CurrentProcessId 1 | Should-BeFalse
        }
        finally { if (-not $preExisting) { Remove-Item $live -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

Describe 'the sweep reclaims the coverage files older versions left in temp' {
    # Transitional, and deliberately so. The coverage XML now lives inside the sandbox and goes
    # with it, but every machine that ran an earlier version still has "psmut-coverage-<pid>.xml"
    # files that nothing could ever match: the sweep looked only at DIRECTORIES named
    # psmut-sandbox-*. Refusing to recognise them would orphan them permanently.
    It 'reads the process id out of a legacy coverage file name' {
        Get-PSMutationSandboxOwnerId -Name 'psmut-coverage-4321.xml' | Should-Be 4321
    }

    It 'still ignores a name the runner never produced' {
        # The other half: the parser widening must not start claiming other people's files.
        Get-PSMutationSandboxOwnerId -Name 'psmut-coverage-notapid.xml' | Should-BeNull
        Get-PSMutationSandboxOwnerId -Name 'coverage-4321.xml' | Should-BeNull
        Get-PSMutationSandboxOwnerId -Name 'psmut-coverage-4321.txt' | Should-BeNull
    }

    It 'sweeps an abandoned coverage FILE, not just directories' {
        # The sweep used to take -Directory only, which is why these accumulated. A file left by a
        # process that is gone is reclaimable on exactly the same terms as a sandbox.
        $temp = [System.IO.Path]::GetTempPath()
        $dead = 999002   # no such process
        $orphan = Join-Path $temp "psmut-coverage-$dead.xml"
        '<coverage/>' | Set-Content -LiteralPath $orphan -Encoding utf8
        try {
            Clear-PSMutationStaleSandbox
            Test-Path -LiteralPath $orphan | Should-BeFalse
        }
        finally { Remove-Item -LiteralPath $orphan -Force -ErrorAction SilentlyContinue }
    }

    It 'SPARES a coverage file whose owning process is still alive' {
        # A REAL second process, for the reason the sandbox version of this test gives: the
        # predicate resolves ownership from the id in the name and treats OUR id as reclaimable by
        # design, so a file named for $PID is one the sweep is entitled to delete.
        #
        # The first draft hard-coded id 1 as "something alive". That is true on Linux and false on
        # Windows, where 1 is not a normal process -- the sweep then found no owner, called the
        # file abandoned, deleted it, and the assertion failed on the Windows leg only. Exactly the
        # platform-assumption failure this repo's guidance warns about, and it cost a red CI run.
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 30' -PassThru
        $temp = [System.IO.Path]::GetTempPath()
        $live = Join-Path $temp "psmut-coverage-$($proc.Id).xml"
        try {
            '<coverage/>' | Set-Content -LiteralPath $live -Encoding utf8
            Clear-PSMutationStaleSandbox
            Test-Path -LiteralPath $live | Should-BeTrue
        }
        finally {
            Remove-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
