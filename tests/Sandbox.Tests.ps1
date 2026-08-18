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

    It 'wipes a sandbox left over from a previous run instead of merging into it' {
        # A killed run leaves its sandbox behind, and the name is per-PID, so the next
        # run in the same shell reuses it. Merging would leave the previous run's
        # mutated copy in place -- mutants stacking on mutants, and a score describing
        # code that never existed.
        $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-src-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'keep') -Force | Out-Null
        'current' | Set-Content (Join-Path $srcDir 'keep/file.txt')
        $name = "psmut-sandbox-test-$([System.Guid]::NewGuid().ToString('N'))"
        $stale = Join-Path ([System.IO.Path]::GetTempPath()) $name
        try {
            New-Item -ItemType Directory -Path (Join-Path $stale 'keep') -Force | Out-Null
            'left over from a killed run' | Set-Content (Join-Path $stale 'keep/file.txt')
            'orphan' | Set-Content (Join-Path $stale 'keep/ghost.txt')

            $sb = New-PSMutationSandbox -RepoRoot $srcDir -Subtrees @('keep') -Name $name
            Get-Content (Join-Path $sb 'keep/file.txt') | Should-Be 'current'
            Test-Path (Join-Path $sb 'keep/ghost.txt')  | Should-BeFalse
        }
        finally {
            Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $stale -Recurse -Force -ErrorAction SilentlyContinue
        }
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
