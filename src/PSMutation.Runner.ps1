<#
.SYNOPSIS
    Execution engine for the PowerShell mutation runner - baseline, candidate
    selection, and per-mutant Pester runs. Operates entirely on SANDBOX paths
    (see PSMutation.Sandbox.ps1); tracked source is never touched.

.DESCRIPTION
    Depends on PSMutation.Operators.ps1 for candidates and PSMutation.Pester.ps1 for the
    child runspace's import contract. Each function is small and single-purpose so
    every unit stays under the complexity ceiling. Each mutant's covering tests run in a
    cancellable runspace under a wall-clock timeout (Invoke-PSBoundedPester): the loop-
    condition guard is a speed optimisation that avoids obviously-doomed condition
    mutants, but the timeout is the real safety net -- a mutated loop *body* can still
    make a guarded loop never terminate, and Stop() interrupts it so the run never hangs.
#>

function Invoke-PSMutationBaseline {
    <#
    .SYNOPSIS
        Run the suite once (green-gate) and capture per-file covered line numbers,
        so we only mutate lines a test actually exercises (Stryker's perTest idea).
    .OUTPUTS
        @{ Passed = <bool>; DurationSeconds = <double>; CoveredLines = @{ file = HashSet[int] } }
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$TestPath,
        [Parameter(Mandatory)] [string[]]$MutateFiles
    )

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = $MutateFiles
    # Read coverage from the result object; steer the XML to temp so we don't
    # litter a coverage.xml in the working tree (Pester's default output path).
    $cfg.CodeCoverage.OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-coverage-$PID.xml"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Pester -Configuration $cfg
    $sw.Stop()

    $covered = @{}
    $result.CodeCoverage.CommandsExecuted | ForEach-Object {
        $f = [System.IO.Path]::GetFullPath($_.File)
        if (-not $covered.ContainsKey($f)) { $covered[$f] = [System.Collections.Generic.HashSet[int]]::new() }
        [void]$covered[$f].Add([int]$_.Line)
    }

    return @{
        Passed          = ($result.Result -eq 'Passed')
        DurationSeconds = $sw.Elapsed.TotalSeconds
        CoveredLines    = $covered
    }
}

function Assert-PSMutationBaselineGreen {
    # Refuse to mutate against a failing suite. Every mutant would "die" for the
    # reason the suite was already red, producing a perfect score that means nothing
    # -- the single most misleading result this tool could hand back.
    #
    # Lives beside Invoke-PSMutationBaseline, whose output it is the only reader of.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Baseline)
    if (-not $Baseline.Passed) {
        throw 'Baseline suite is not green - fix the tests before mutating.'
    }
}

function Test-PSMutantCovered {
    # True if a candidate's line was executed by the baseline run. Pure.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Candidate, [Parameter(Mandatory)] [hashtable]$CoveredLines)
    $f = [System.IO.Path]::GetFullPath($Candidate.File)
    return $CoveredLines.ContainsKey($f) -and $CoveredLines[$f].Contains([int]$Candidate.Line)
}

function Select-PSMutationCandidate {
    # Enumerate candidates across the mutate files, keeping only covered ones (opt).
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$MutateFiles,
        [Parameter(Mandatory)] [string[]]$Operators,
        [bool]$CoveredLinesOnly,
        $CoveredLines
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $MutateFiles) {
        Get-PSMutationCandidate -Path $file -Operators $Operators |
            Where-Object { -not $CoveredLinesOnly -or (Test-PSMutantCovered -Candidate $_ -CoveredLines $CoveredLines) } |
            ForEach-Object { $out.Add($_) }
    }
    return , $out.ToArray()
}

function Invoke-PSBoundedPester {
    <#
    .SYNOPSIS
        Run the covering tests in a CANCELLABLE runspace with a wall-clock timeout.
    .DESCRIPTION
        The loop-condition guard prevents a flipped *condition* from spinning, but a
        mutated loop *body* (e.g. `$i + 1` -> `$i - 1`) can still make a guarded loop
        never terminate. There is no way to know that statically, so each mutant runs
        under a hard timeout: a fresh PowerShell/runspace whose pipeline is Stop()'d
        when it overruns -- Stop() interrupts even a tight loop, so the run never hangs.

        The child imports Pester by PATH (see Get-PSMutationPesterPath) rather than
        letting the runspace resolve the name to whatever is newest on disk.
    .OUTPUTS
        The Pester result string ('Passed'/'Failed'/...), or 'TimedOut'.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$CoveringTests, [Parameter(Mandatory)] [int]$TimeoutSeconds)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript((Get-PSMutationBoundedPesterScript)).
        AddParameter('tests', $CoveringTests).
        AddParameter('pester', (Get-PSMutationPesterPath))
    $async = $ps.BeginInvoke()
    try {
        if (-not $async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))) {
            $ps.Stop()
            return 'TimedOut'
        }
        $outcome = [string]($ps.EndInvoke($async) | Select-Object -Last 1)
        # A child that returned no verdict proved nothing about the mutant. Handing
        # that back would classify it Killed -- anything but 'Passed' is a kill -- so a
        # broken child reads as a perfect score. That is exactly how the Pester version
        # collision stayed invisible for so long. Fail the run instead of scoring it.
        if (-not $outcome) { throw ('The covering tests produced no result: ' + (Get-PSMutationRunspaceError -Runspace $ps)) }
        return $outcome
    }
    finally { $ps.Dispose() }
}

function Get-PSMutationRunspaceError {
    # Whatever the child wrote to its error stream, as one line. Reported rather than
    # swallowed: without it a failed child is indistinguishable from a killed mutant.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Runspace)
    $messages = @($Runspace.Streams.Error | ForEach-Object { $_.Exception.Message })
    if (-not $messages) { return 'the child runspace reported no error' }
    return ($messages -join '; ')
}

function Invoke-PSMutant {
    <#
    .SYNOPSIS
        Evaluate one mutant: splice it into its SANDBOX file, run the covering tests
        under a timeout, classify, and restore the sandbox file for the next mutant.
    .OUTPUTS
        'Killed' | 'Survived' | 'TimedOut' -- Survived only if the suite still fully
        passes. A timeout scores WITH the kills, because a mutant that hangs the suite is a
        fault, but it is reported apart from them: "the suite proved this fault is caught"
        and "the suite hung and we assumed so" are different claims and only the first is
        evidence. Folded together, a suite that is merely too slow inflates the score.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] [string]$MutatedContent,
        [Parameter(Mandatory)] [string[]]$CoveringTests,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )
    $original = [System.IO.File]::ReadAllText($Candidate.File)
    try {
        [System.IO.File]::WriteAllText($Candidate.File, $MutatedContent)
        $outcome = Invoke-PSBoundedPester -CoveringTests $CoveringTests -TimeoutSeconds $TimeoutSeconds
        if ($outcome -eq 'Passed') { return 'Survived' }
        # Invoke-PSBoundedPester already distinguishes this; the verdict used to be
        # discarded one line later, which is the whole of the bug.
        if ($outcome -eq 'TimedOut') { return 'TimedOut' }
        return 'Killed'
    }
    finally {
        [System.IO.File]::WriteAllText($Candidate.File, $original)
    }
}

function Get-PSMutationProgressLine {
    # One per-mutant progress line. Pure, and emitted as the loop goes rather than
    # collected: a run of several hundred mutants takes minutes, and a progress report
    # delivered at the end is not a progress report.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([int]$Index, [int]$Total, $Result, [string]$DisplayFile)
    $survived = $Result.Status -eq 'Survived'
    $glyph = if ($survived) { '.' } else { 'x' }
    $role = if ($survived) { 'Warn' } else { 'Muted' }
    return New-PSMutationLine -Role $role -Data $Result `
        -Text ("  [{0}/{1}] {2} {3}:{4} {5}" -f $Index, $Total, $glyph, $DisplayFile, $Result.Line, $Result.Description)
}

function Invoke-PSMutationLoop {
    # Evaluate every candidate; return the result rows.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        # Empty is a legitimate input, not an error: a mutate file may contribute no
        # covered candidates, and a recheck run whose previous survivors are all dead
        # has nothing left to evaluate. Both should report zero, not throw.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$TestsByFile,
        [Parameter(Mandatory)] [string[]]$AllTests,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [string]$SandboxRoot,
        [switch]$Quiet
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($c in $Candidates) {
        $n++
        $content = [System.IO.File]::ReadAllText($c.File)
        $mutated = Set-PSMutationText -Content $content -Candidate $c
        $covering = if ($TestsByFile.ContainsKey($c.File)) { $TestsByFile[$c.File] } else { $AllTests }
        $status = Invoke-PSMutant -Candidate $c -MutatedContent $mutated -CoveringTests $covering -TimeoutSeconds $TimeoutSeconds
        $display = ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot
        $row = [pscustomobject]@{
            # Function is carried so an equivalence declaration can address this mutant by
            # the function it lives in rather than by a line number, which moves whenever
            # anything above the mutant is edited and takes the declaration stale with it.
            #
            # This row is the report's published shape. Adding a field widens what every
            # consumer may depend on, so a test asserts the exact list: widening should
            # cost a deliberate edit, not happen as a side effect of an internal rename.
            Id = $c.Id; Function = $c.Function; File = $display; Line = $c.Line
            Operator = $c.Operator; Description = $c.Description; Status = $status
        }
        $results.Add($row)
        Write-PSMutationOutput -Quiet:$Quiet -Lines (Get-PSMutationProgressLine -Index $n `
                -Total $Candidates.Count -Result $row -DisplayFile (Split-Path $display -Leaf))
    }
    return , $results.ToArray()
}
