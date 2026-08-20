<#
.SYNOPSIS
    Config resolution for the mutation run: the "what did the user ask for, and what
    do we do when they didn't say" decisions.

.DESCRIPTION
    A config object in, a value out: pure, no side effects, nothing to sandbox.

    Every documented default is resolved here, so this is the one place to read for
    "what happens if the config omits this" -- the operator set excepted, which resolves
    in PSMutation.Operators.ps1 beside the vocabulary it names.
#>

# Default subtrees copied into the sandbox when the config does not name any. A neutral
# module convention; a consuming repo overrides it with `sandboxSubtrees`.
#
# The sandbox takes -Subtrees as a mandatory parameter rather than defaulting: it is
# mechanism, and holds no opinion about a repo's layout.
$script:PSMutationDefaultSubtrees = @('src', 'tests')

# Every key the config understands, and every sub-key of `thresholds`. A key absent from
# these lists resolves to $null and weakens the run in silence: `thresholds.brake` leaves
# the break gate unable to fail, and `mutat` for `mutate` surfaces as a denied path inside
# the sandbox, a message mentioning neither the config nor the key.
#
# Keys starting with `_` are exempt: JSON has no comments, and both the example config and
# this repo's own use `_comment` / `_operators` / `_timeout` to explain themselves.
$script:PSMutationConfigKeys = @(
    'mutate', 'tests', 'operators', 'coveredLinesOnly', 'sandboxSubtrees',
    'timeoutFactor', 'timeoutFloorSeconds', 'equivalents', 'thresholds', 'reportPath'
)
$script:PSMutationThresholdKeys = @('high', 'low', 'break')

function Get-PSMutationEditDistance {
    # Levenshtein distance between two strings.
    #
    # Exists only so a rejected key can say "did you mean 'break'?" rather than leaving the
    # reader to diff two lists by eye. The three typos this has to reach are a transposition
    # (brake/break, distance 2), a dropped letter (mutat/mutate, 1) and a wrong letter (1).
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$From,
          [Parameter(Mandatory)] [AllowEmptyString()] [string]$To)
    $n = $From.Length
    $m = $To.Length
    # No empty-string guard, deliberately. The obvious `if ($n -eq 0) { return $m }` pair
    # reads like a necessary base case and is not one: with either length zero the loop
    # below simply does not run and the seeded row already holds the answer. Verified by
    # deleting both and re-running the table in Config.Tests.ps1 -- identical. They would
    # also have been two mutants nothing could ever kill.
    #
    # Two rows rather than a full matrix: only the previous row is ever read.
    $prev = [int[]](0..$m)
    # Sized from $prev rather than as ($m + 1). Same length, but written as a literal it is
    # a mutant nothing can kill: the row is a buffer, so an oversized one computes exactly
    # the same distances. Deriving the length removes the mutant instead of excusing it.
    $curr = [int[]]::new($prev.Length)
    for ($i = 1; $i -le $n; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($From[$i - 1] -eq $To[$j - 1]) { 0 } else { 1 }
            $curr[$j] = [math]::Min([math]::Min($prev[$j] + 1, $curr[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $curr.Clone()
    }
    return [int]$prev[$m]
}

function Get-PSMutationNearestName {
    # The valid name closest to a misspelling, or $null when nothing is close enough.
    #
    # Two edits is the cutoff because that is what a transposition costs; beyond it a
    # "did you mean" is a guess, and a wrong guess sends the reader off to change a key
    # that was never the problem.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name,
          [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Candidates)
    $best = $null
    $bestDistance = 3
    foreach ($c in $Candidates) {
        $d = Get-PSMutationEditDistance -From $Name.ToLowerInvariant() -To $c.ToLowerInvariant()
        if ($d -lt $bestDistance) {
            $bestDistance = $d
            $best = $c
        }
    }
    return $best
}

function Get-PSMutationUnknownKeyMessage {
    # The complaint about one unrecognised key, or $null when it is recognised.
    #
    # Returns the reason rather than throwing so the caller decides how to report, and so
    # the decision itself is a value a test can compare.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name,
          [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Known,
          [Parameter(Mandatory)] [string]$Where)
    # JSON has no comments; `_`-prefixed keys are how every config here explains itself.
    if ($Name.StartsWith('_')) { return $null }
    if ($Known -contains $Name) { return $null }
    $near = Get-PSMutationNearestName -Name $Name -Candidates $Known
    $hint = if ($near) { " Did you mean '$near'?" } else { '' }
    return "Unknown $Where key '$Name'.$hint Valid keys: $(($Known | Sort-Object) -join ', ')."
}

function Assert-PSMutationConfig {
    # Refuse a config that asks for something this module does not understand.
    #
    # An error rather than a warning, deliberately: a warning in a CI log is
    # indistinguishable from silence, and every failure here makes the gate WEAKER while
    # the run stays green -- the exact class of silent wrong answer this tool exists to
    # find in other people's code.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg)
    foreach ($prop in $Cfg.PSObject.Properties) {
        $why = Get-PSMutationUnknownKeyMessage -Name $prop.Name -Known $script:PSMutationConfigKeys -Where 'config'
        if ($why) { throw $why }
    }
    foreach ($prop in $Cfg.thresholds.PSObject.Properties) {
        $why = Get-PSMutationUnknownKeyMessage -Name $prop.Name -Known $script:PSMutationThresholdKeys -Where 'thresholds'
        if ($why) { throw $why }
    }
    foreach ($op in @($Cfg.operators)) {
        if ($null -eq $op) { continue }
        $why = Get-PSMutationUnknownKeyMessage -Name $op -Known (Get-PSMutationKnownOperator) -Where 'operators'
        if ($why) { throw $why }
    }
    if (@($Cfg.mutate).Where({ $_ }).Count -eq 0) {
        throw "Config must set 'mutate' to a non-empty list of files to mutate."
    }
    # .Where({ $_ }) rather than a bare .Count: with no `tests` key at all, .PSObject
    # yields $null and @($null) is an array of ONE, so a plain count reads a missing map
    # as a populated one.
    if (@($Cfg.tests.PSObject.Properties).Where({ $_ }).Count -eq 0) {
        throw "Config must set 'tests' to a map of mutate file -> the test file(s) covering it."
    }
}

function Get-PSMutationCoveredLinesOnly {
    # Whether to mutate only the lines the baseline actually executed.
    #
    # Defaults to TRUE, which is what the README promises and what every example sets.
    #
    # Resolved rather than cast at the call site, because `[bool]$null` is $false: an
    # omitted key would silently mean "mutate uncovered lines too", and every mutant on an
    # uncovered line is a guaranteed survivor. That reports a materially worse score than
    # the tool is designed to give, and measures coverage rather than test quality, which
    # is a separate gate.
    [OutputType([bool])]
    [CmdletBinding()]
    param($Cfg)
    if ($null -eq $Cfg.coveredLinesOnly) { return $true }
    return [bool]$Cfg.coveredLinesOnly
}

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

function Get-PSMutationScoreBand {
    # The bands the console summary colours the score by: at or above High is green, at or
    # above Low is yellow, below Low is red.
    #
    # Resolved here, with defaults, because in PowerShell any number `-ge $null` is $true.
    # Compare a raw config value and a config with no thresholds -- or the entirely
    # reasonable `{"thresholds":{"break":80}}` -- makes the first branch always win and
    # prints EVERY score green, `Mutation score: 0%  (0 killed / 42)` included, in a run
    # that exits 0. The smallest possible instance of the failure this tool exists to
    # prevent, in front of the person least able to spot it: a new adopter whose thresholds
    # are not tuned yet.
    #
    # Tested with `$null -ne`, not for truthiness like the resolvers above. A band of 0 is a
    # meaningful setting -- "never colour this red" -- and 0 is falsy, so a truthiness test
    # would silently substitute the default for it.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param($Cfg)
    $high = if ($null -ne $Cfg.thresholds.high) { $Cfg.thresholds.high } else { 85 }
    $low = if ($null -ne $Cfg.thresholds.low) { $Cfg.thresholds.low } else { 70 }
    return @{ High = [double]$high; Low = [double]$low }
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
