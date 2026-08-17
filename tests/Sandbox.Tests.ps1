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
        ConvertFrom-PSMutationSandboxPath -Path $sb -SandboxRoot $sbRoot | Should -Be 'src/x.ps1'
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
            Test-Path (Join-Path $sb 'keep/file.txt') | Should -BeTrue
            Test-Path (Join-Path $sb 'skip')          | Should -BeFalse

            Remove-PSMutationSandbox -SandboxRoot $sb
            Test-Path $sb | Should -BeFalse
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
            Get-Content (Join-Path $sb 'keep/file.txt') | Should -Be 'current'
            Test-Path (Join-Path $sb 'keep/ghost.txt')  | Should -BeFalse
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
        { Remove-PSMutationSandbox -SandboxRoot $gone } | Should -Not -Throw
    }
}

Describe 'Clear-PSMutationStaleSandbox' {
    It 'sweeps sandboxes left behind by a killed run' {
        # Runs at startup, which is why a killed run does not accumulate temp dirs
        # forever. Matches psmut-sandbox-* by design.
        $stale = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-sandbox-stale-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        'junk' | Set-Content (Join-Path $stale 'leftover.txt')
        try {
            Clear-PSMutationStaleSandbox
            Test-Path $stale | Should -BeFalse
        }
        finally { Remove-Item $stale -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
