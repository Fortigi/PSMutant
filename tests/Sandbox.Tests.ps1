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
}
