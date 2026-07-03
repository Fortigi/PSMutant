<#
.SYNOPSIS
    Sandbox isolation for the PowerShell mutation runner.

.DESCRIPTION
    Mutants must NEVER be written into tracked source -- not even transiently, so a
    hard kill (Ctrl-C / TaskStop) can't leave a mutated file staged in git. So instead
    of mutating the real file in place, the runner copies the source subtrees into a
    throwaway temp sandbox and mutates only the copy. The tests run from the sandbox
    too, so their $PSScriptRoot-relative dot-sources resolve to the sandboxed modules.
    On any exit -- clean or killed -- only a temp dir is dirty, and it's disposable.

    Each function stays tiny (well under the complexity ceiling) and side-effects are
    confined here.
#>

# Default subtrees copied into the sandbox. Neutral module convention; a consuming
# repo overrides this via the config's `sandboxSubtrees` to match its own layout.
$script:PSMutationSandboxSubtrees = @('src', 'tests')

function New-PSMutationSandbox {
    # Copy the source subtrees into a fresh temp dir; return its root path.
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string[]]$Subtrees = $script:PSMutationSandboxSubtrees,
        [string]$Name = "psmut-sandbox-$PID"
    )
    $root = Join-Path ([System.IO.Path]::GetTempPath()) $Name
    if ($PSCmdlet.ShouldProcess($root, 'Create mutation sandbox')) {
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $Subtrees |
            Where-Object { Test-Path (Join-Path $RepoRoot $_) } |
            ForEach-Object { Copy-Item (Join-Path $RepoRoot $_) (Join-Path $root $_) -Recurse -Force }
    }
    return $root
}

function ConvertTo-PSMutationSandboxPath {
    # Map a repo path to its position inside the sandbox (structure is preserved). Pure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $rel = [System.IO.Path]::GetRelativePath($RepoRoot, [System.IO.Path]::GetFullPath($Path))
    return [System.IO.Path]::GetFullPath((Join-Path $SandboxRoot $rel))
}

function ConvertFrom-PSMutationSandboxPath {
    # Inverse of ConvertTo -- sandbox path back to a repo-relative display path. Pure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    return [System.IO.Path]::GetRelativePath($SandboxRoot, [System.IO.Path]::GetFullPath($Path)) -replace '\\', '/'
}

function Remove-PSMutationSandbox {
    # Delete a sandbox. Best-effort -- a leftover temp dir is harmless, never tracked.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)] [string]$SandboxRoot)
    if ($PSCmdlet.ShouldProcess($SandboxRoot, 'Remove mutation sandbox')) {
        if (Test-Path $SandboxRoot) { Remove-Item $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Clear-PSMutationStaleSandbox {
    # Sweep sandboxes left by a previously killed run (belt-and-braces at startup).
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if ($PSCmdlet.ShouldProcess('temp', 'Clear stale mutation sandboxes')) {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'psmut-sandbox-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
