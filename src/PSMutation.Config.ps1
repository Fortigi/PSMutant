<#
.SYNOPSIS
    Config resolution for the mutation run: the "what did the user ask for, and what
    do we do when they didn't say" decisions.

.DESCRIPTION
    These used to be inline in Invoke-PSMutation, between the baseline call and the
    mutation loop. That put them past a NESTED Pester run, and a nested run clobbers
    the outer run's coverage breakpoints -- so lines that demonstrably execute (the
    startup banner among them) were reported as never run, and no amount of testing
    could show otherwise.

    Pulled out here they are ordinary pure functions: a config object in, a value
    out, no side effects and nothing to sandbox. That makes them measurable, and it
    makes them worth self-mutating (see psmutant.self.config.json), which the
    orchestrator's own body cannot be.

    Defaults live here rather than at the call site so there is exactly one place to
    read for "what happens if the config omits this".
#>

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
    return [string[]]$script:PSMutationSandboxSubtrees
}

function Get-PSMutationOperatorList {
    # Which mutation operators to apply; unset means the default set.
    #
    # Note the truthiness test is deliberate and matches the behaviour this replaced:
    # an EMPTY operators list falls back to the defaults rather than selecting none.
    # Arguably an explicit [] should mean "none", but that is a behaviour change, not
    # a refactor, so it is left alone here.
    [OutputType([string[]])]
    [CmdletBinding()]
    param($Cfg)
    if ($Cfg.operators) { return [string[]]@($Cfg.operators) }
    return [string[]]$script:PSMutationDefaultOperators
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

function Assert-PSMutationBaselineGreen {
    # Refuse to mutate against a failing suite. Every mutant would "die" for the
    # reason the suite was already red, producing a perfect score that means nothing
    # -- the single most misleading result this tool could hand back.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Baseline)
    if (-not $Baseline.Passed) {
        throw 'Baseline suite is not green - fix the tests before mutating.'
    }
}

function ConvertTo-PSMutationRunResult {
    # The public shape of a completed run. Kept out of the orchestrator body so the
    # contract callers depend on is pinned somewhere measurable.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary, [Parameter(Mandatory)] [int]$ExitCode)
    return [pscustomobject]@{
        Score    = $Summary.Score
        Killed   = $Summary.Killed
        Survived = $Summary.Survived
        Total    = $Summary.Total
        ExitCode = $ExitCode
    }
}
