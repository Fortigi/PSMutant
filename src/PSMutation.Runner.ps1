<#
.SYNOPSIS
    Execution engine for the PowerShell mutation runner - baseline, candidate
    selection, and per-mutant Pester runs. Operates entirely on SANDBOX paths
    (see PSMutation.Sandbox.ps1); tracked source is never touched.

.DESCRIPTION
    Depends on PSMutation.Operators.ps1. Each function is small and single-purpose so
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

function Get-PSMutationPesterPath {
    <#
    .SYNOPSIS
        File path of the Pester ALREADY LOADED in this process, so a child runspace can
        import that one by path instead of resolving the name for itself.
    .DESCRIPTION
        A fresh runspace resolves `Pester` by NAME against PSModulePath and gets the
        NEWEST version installed -- which is not necessarily the version this process
        already loaded. Assemblies are per-process, so when the two differ the child
        dies on "An incompatible version of the Pester.dll assembly is already loaded".
        A child that dies produces no verdict, and a mutant with no verdict used to be
        classified Killed: on any machine with two Pesters installed, every mutant died
        and the run reported a silent, entirely fake 100%.

        Importing by PATH is what makes the module version-agnostic in the way the
        manifest promises: whatever Pester >= 5 the consuming repo runs, the mutant
        runs under that same one.
    .OUTPUTS
        [string] path to the loaded Pester module file.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    # Highest wins: two Pester 5.x releases CAN coexist in one process (the dll guard
    # only rejects a LOWER loaded version), and the newer of them is the one whose
    # assembly is actually serving calls.
    $loaded = Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $loaded) {
        throw 'Pester is not loaded in this session, so a mutant cannot be run against it.'
    }
    return $loaded.Path
}

function Get-PSMutationBoundedPesterScript {
    <#
    .SYNOPSIS
        The script a mutant's child runspace runs: import the pinned Pester, run the
        covering tests, emit the one-word result.
    .DESCRIPTION
        Named rather than inlined because it is the child's whole contract. Two things
        in it are load-bearing and easy to "simplify" away:

        * `Import-Module $pester` imports by PATH. Importing by name lets the runspace
          resolve Pester itself, which picks the newest installed rather than the one
          this process loaded -- the collision Get-PSMutationPesterPath exists to stop.
        * `-ErrorAction Stop` makes a failed import terminate the child, so the caller
          gets an exception instead of an empty result that reads as a dead mutant.
    .OUTPUTS
        [string] the script text.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return @'
param($tests, $pester)
Import-Module $pester -Force -ErrorAction Stop
$c = New-PesterConfiguration
$c.Run.Path = $tests
$c.Run.PassThru = $true
$c.Output.Verbosity = 'None'
(Invoke-Pester -Configuration $c).Result
'@
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
        'Killed' | 'Survived' -- Survived only if the suite still fully passes; any
        failure OR a timeout (a runaway mutant) counts as Killed.
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
        if ($outcome -eq 'Passed') { return 'Survived' } else { return 'Killed' }
    }
    finally {
        [System.IO.File]::WriteAllText($Candidate.File, $original)
    }
}

function Write-PSMutationProgress {
    # One per-mutant progress line.
    [CmdletBinding()]
    param([int]$Index, [int]$Total, $Result, [string]$DisplayFile)
    $survived = $Result.Status -eq 'Survived'
    $glyph = if ($survived) { '.' } else { 'x' }
    $col = if ($survived) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  [{0}/{1}] {2} {3}:{4} {5}" -f $Index, $Total, $glyph, $DisplayFile, $Result.Line, $Result.Description) -ForegroundColor $col
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
            Id = $c.Id; File = $display; Line = $c.Line
            Operator = $c.Operator; Description = $c.Description; Status = $status
        }
        $results.Add($row)
        if (-not $Quiet) { Write-PSMutationProgress -Index $n -Total $Candidates.Count -Result $row -DisplayFile (Split-Path $display -Leaf) }
    }
    return , $results.ToArray()
}
