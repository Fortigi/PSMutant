<#
.SYNOPSIS
    Config resolution for the mutation run: the "what did the user ask for, and what
    do we do when they didn't say" decisions.

.DESCRIPTION
    These used to be inline in Invoke-PSMutation, between the baseline call and the
    mutation loop. Out here they are ordinary pure functions: a config object in, a
    value out, no side effects and nothing to sandbox, so each is worth unit-testing
    and self-mutating on its own terms.

    NOTE: this docstring used to say they had to be pulled out because a nested Pester
    run destroys the outer run's coverage breakpoints, and that Invoke-PSMutation's own
    body therefore could not be measured. The tracer teardown was real, but the fix was
    CodeCoverage.UseBreakpoints, not this file: the orchestrator measures at 100% and is
    self-mutated. Isolating decisions is still the right reason to keep them here.

    Defaults live here rather than at the call site so there is exactly one place to
    read for "what happens if the config omits this". The one default that cannot is
    the operator set: Get-PSMutationCandidate is EXPORTED and its -Operators default is
    part of the public promise, so that default and the resolver that falls back to it
    both live in PSMutation.Operators.ps1 instead.

    This file holds resolvers only. A run guard and the public result shape used to sit
    here too, neither of which the synopsis above described (#45); they now live beside
    the baseline they judge and the report contract they belong to.
#>

# Default subtrees copied into the sandbox when the config does not name any. A neutral
# module convention; a consuming repo overrides it with `sandboxSubtrees`.
#
# It lives here, next to its only reader, rather than in PSMutation.Sandbox.ps1 where it
# used to. The sandbox is mechanism and should be told what to copy rather than hold an
# opinion about the repo's layout -- and a constant one file writes while another reads
# leaves neither file readable on its own (#38).
$script:PSMutationDefaultSubtrees = @('src', 'tests')

function Get-PSMutationSandboxPlan {
    # Translate the config's source-relative mutate/tests into sandbox absolute paths.
    #
    # Pure string work, and the last piece of config resolution that was still sitting
    # in the orchestrator rather than here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'SourceRoot and SandboxRoot are used inside the $toSb closure, which the analyzer does not track.')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$SourceRoot, [Parameter(Mandatory)] [string]$SandboxRoot)
    $toSb = { param($p) ConvertTo-PSMutationSandboxPath -Path (Join-Path $SourceRoot $p) -RepoRoot $SourceRoot -SandboxRoot $SandboxRoot }
    $byFile = @{}
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in $Cfg.tests.PSObject.Properties) {
        $vals = @($prop.Value | ForEach-Object { & $toSb $_ })
        $byFile[(& $toSb $prop.Name)] = $vals
        $vals | ForEach-Object { $all.Add($_) }
    }
    return @{
        Mutate      = @($Cfg.mutate | ForEach-Object { & $toSb $_ })
        TestsByFile = $byFile
        AllTests    = $all.ToArray()
    }
}

function Get-PSMutationSubtree {
    # Which source subtrees get copied into the sandbox. A consuming repo overrides
    # this to match its own layout; unset means the module's own convention.
    [OutputType([string[]])]
    [CmdletBinding()]
    param($Cfg)
    if ($Cfg.sandboxSubtrees) { return [string[]]@($Cfg.sandboxSubtrees) }
    return [string[]]$script:PSMutationDefaultSubtrees
}

function Get-PSMutationTimeout {
    # Per-mutant timeout in whole seconds.
    #
    # A mutant should never take much longer than the baseline suite, so the budget
    # is max(floor, baseline x factor). The floor matters for fast suites: a baseline
    # of 0.2s would otherwise give a 0-second budget and kill every mutant on time
    # rather than on behaviour, scoring 100% against tests that never ran. The factor
    # matters for slow ones. A mutant that runs past this is cut off and counted
    # Killed -- which is the right answer for a non-terminating loop.
    [OutputType([int])]
    [CmdletBinding()]
    param($Cfg, [Parameter(Mandatory)] [double]$BaselineSeconds)
    $factor = if ($Cfg.timeoutFactor) { $Cfg.timeoutFactor } else { 4 }
    $floor = if ($Cfg.timeoutFloorSeconds) { $Cfg.timeoutFloorSeconds } else { 15 }
    return [int][math]::Max($floor, $BaselineSeconds * $factor)
}
