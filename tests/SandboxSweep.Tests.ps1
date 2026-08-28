# The DESTRUCTIVE half of the sandbox tests: everything here calls
# Clear-PSMutationStaleSandbox for real, because the sweep is the thing under test.
#
# Split out of Sandbox.Tests.ps1 so that file can be a covering suite (#22). A
# self-mutation baseline runs its covering suites IN-PROCESS, sharing $PID with the sandbox
# the run is executing from -- and Test-PSMutationSandboxAbandoned treats its own process id
# as reclaimable, so the sweep deletes the live run's sandbox mid-baseline. Observed: the run
# dies with "Baseline suite is not green" before a single mutant is evaluated.
#
# THIS FILE MUST NOT BE NAMED IN psmutant.self.config.json, under `tests` or anywhere else.
# AllTests is the union of every file named there, so listing it as a covering suite for
# ANYTHING is enough to kill the run. It still runs in the ordinary suite, which is where its
# value is; what it cannot do is run inside a mutation gate.
#
# The underlying assumption -- that the current process cannot already own a sandbox -- is a
# separate question and stays open on #22.

# Unit tests for the sandbox isolation layer. NOT a self-mutation covering suite (it
# exercises real temp side-effects), so it uses unique sandbox names to stay clear of
# any concurrent runner sandbox.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
    $script:root = Split-Path -Parent $PSScriptRoot
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
