# Reusing a previous run's verdicts for the files nothing has touched (#255).
#
# A mutant's verdict depends on three things: its file, the tests that run against it, and the other
# code those tests run. When all three are byte-identical to what the previous run saw, running the
# mutant again can only repeat its answer. So each mutate file gets a KEY -- a hash over the file, its
# covering test files, and every other source file its covering suite executed -- and the report
# records it. `-Incremental` re-computes the keys and reuses every verdict of a file whose key is
# unchanged.
#
# "Every other source file its covering suite executed" is MEASURED, once per covering suite, with
# Pester coverage over every non-test script in the sandbox, and recorded beside the key. A later run
# re-hashes the recorded files rather than measuring again: if none of them changed, the suite runs
# the same code, so it executes the same files. Measured on this repo's history, a key on the mutate
# file and its tests alone would reuse 78% of verdicts between merges -- and miss every change to a
# helper the tests also load, which is most of what a suite loads here. Keyed on all of src/ instead,
# reuse falls to 35-40%. The executed files sit between, and are the ones that can change a verdict.
#
# What the key cannot see, and the README says: a file a suite reads as DATA rather than running --
# a JSON fixture, a schema -- and an installed module, which is not in the sandbox. Change one of
# those and run without -Incremental.
#
# OPT-IN, and said out loud. A reused verdict is a claim this run did not check, so a run that
# reuses any prints how many before it starts, and the report marks each reused row and counts them.

function New-PSMutationIncrementalBasis {
    # What, besides the files, a verdict depends on. A previous report written under a different
    # basis is not reused at all: another PSMutant or Pester can decide differently, and the timeout
    # settings decide which mutants time out.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: returns a new object, changes no state.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        # Empty-able: dot-sourced rather than imported, as this repo's own tests load it, the module
        # has no version to give -- and a basis is built on every run, incremental or not.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ModuleVersion,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$PesterVersion,
        [Parameter(Mandatory)] [string]$PowerShellVersion,
        # { Factor; Floor }: the run's timeoutFactor and timeoutFloorSeconds.
        [Parameter(Mandatory)] $TimeoutRule,
        [Parameter(Mandatory)] [bool]$RecordAllKillers
    )
    return [ordered]@{
        psmutant = $ModuleVersion; pester = $PesterVersion; powershell = $PowerShellVersion
        timeoutFactor = [double]$TimeoutRule.Factor; timeoutFloorSeconds = [double]$TimeoutRule.Floor
        recordAllKillers = $RecordAllKillers
    }
}

function Get-PSMutationIncrementalBasisFault {
    # Why a previous report's verdicts cannot be reused under this run's basis, naming the first
    # difference; empty when they can. Pure.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # The previous report's recorded basis, as read back from JSON.
        [Parameter(Mandatory)] [AllowNull()] $Prior,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Current
    )
    if ($null -eq $Prior) { return 'it records no incremental data' }
    foreach ($name in $Current.Keys) {
        $was = $Prior.$name
        if ("$was" -cne "$($Current[$name])") { return "its $name was '$was' and is '$($Current[$name])' now" }
    }
    return ''
}

function Get-PSMutationIncrementalKey {
    # The key of one mutate file: SHA256 over "path=hash" for the file, its covering tests and its
    # suite's other executed files, each once, in ordinal order. A file that is not there hashes as
    # 'missing', so deleting a helper changes the key rather than dropping out of it. Paths are the
    # repo-relative ones the report uses.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Path,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $lines = foreach ($p in @($Path | Sort-Object -Unique -CaseSensitive)) {
        $full = Join-Path $SandboxRoot $p
        $hash = [System.IO.File]::Exists($full) ? (Get-PSMutationSourceHash -Path $full) : 'missing'
        "$p=$hash"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((@($lines) -join "`n"))
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-PSMutationIncrementalSource {
    # Every script in the sandbox that could be a covering suite's dependency: each .ps1 and .psm1,
    # less the mapped test files, which each key names on their own. A test HELPER is kept -- it is
    # code the tests run. Repo-relative, sorted.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$AllTests
    )
    $tests = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $AllTests) { [void]$tests.Add([System.IO.Path]::GetFullPath($t)) }
    $found = foreach ($f in Get-ChildItem -LiteralPath $SandboxRoot -Recurse -File -Include '*.ps1', '*.psm1') {
        if (-not $tests.Contains($f.FullName)) { ConvertFrom-PSMutationSandboxPath -Path $f.FullName -SandboxRoot $SandboxRoot }
    }
    return [string[]]@($found | Sort-Object -CaseSensitive)
}

function Get-PSMutationSuiteDependency {
    <#
    .SYNOPSIS
        The source files one covering suite executed, repo-relative and sorted: what its mutate
        files' keys are built from.
    .DESCRIPTION
        One Pester run of the suite, unmutated, with coverage over every candidate source file. A
        file counts once any command in it ran. Breakpoints, as the baseline uses, for the reason it
        gives: the profiler tracer fails a test that touches a class. The suite's own test files are
        left out -- each key names them anyway.

        THROWS when the measurement cannot be trusted (#305): Pester returned nothing (the first error
        it wrote then says why), threw, or the suite did not pass. An error a passing test provokes
        is not one of those. Each of those is a run that may have executed less than
        the suite does, and a dependency list short of a file is a key that later calls a changed
        verdict unchanged. What Pester writes is captured rather than left on the error stream,
        because there it failed a CI step whose run had scored fine -- a pwsh step on GitHub fails on
        any error written, for a measurement that only decides what the NEXT run may reuse.

        And the caller's $LASTEXITCODE is put back. Pester sets the GLOBAL one -- to the number of
        failed tests, or -1 when it could not run -- and a GitHub pwsh step ends `exit
        $LASTEXITCODE`, so the measurement failed the step even with its errors captured. Measured:
        that, not the error stream, is what turned #304's first run red after it had scored 100%.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Suite,
        # Repo-relative, as Get-PSMutationIncrementalSource gives them.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Source,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    if ($Source.Count -eq 0) { return [string[]]@() }
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $Suite
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = [string[]]@(foreach ($s in $Source) { Join-Path $SandboxRoot $s })
    # In the sandbox, which the run removes, as the baseline's is.
    $cfg.CodeCoverage.OutputPath = Join-Path $SandboxRoot 'coverage-dependencies.xml'
    Set-PSMutationCoverageBreakpoint -CodeCoverage $cfg.CodeCoverage
    $names = @(foreach ($s in $Suite) { ConvertFrom-PSMutationSandboxPath -Path $s -SandboxRoot $SandboxRoot }) -join ', '
    $written = $null
    $exitBefore = $global:LASTEXITCODE
    # No catch: even "no test files were found" arrives as a written error under SilentlyContinue,
    # and anything Pester still throws is caught by the caller, which treats it as unmeasured too.
    try { $result = Invoke-Pester -Configuration $cfg -ErrorAction SilentlyContinue -ErrorVariable written }
    finally { $global:LASTEXITCODE = $exitBefore }
    $fault = Get-PSMutationDependencyFault -Result $result -Written @($written)
    if ($fault) { throw "could not measure what $names runs: $fault" }
    $ran = foreach ($c in $result.CodeCoverage.CommandsExecuted) { ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot }
    return [string[]]@($ran | Sort-Object -Unique -CaseSensitive)
}

function Get-PSMutationDependencyFault {
    # Why one measuring run cannot be trusted, or nothing when it can. Pure.
    #
    # The RESULT decides, never the error stream alone. -ErrorVariable collects every error written
    # during the run, and that includes the ones a passing test provokes on purpose -- each
    # Should-Throw writes one. Read as faults they marked every real suite of this repo unmeasured
    # on #306's first CI run, so nothing got a key and nothing could ever be reused. A written error
    # is only the explanation when there is no result to judge by.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [AllowNull()] $Result,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Written
    )
    if ($null -eq $Result) {
        if ($Written.Count -gt 0) { return [string]$Written[0] }
        return 'Pester returned no result'
    }
    if ($Result.Result -ne 'Passed') { return "the suite's run ended '$($Result.Result)'" }
}

function Read-PSMutationIncrementalPrior {
    # The previous report's incremental data, as lookups: Files (path -> { key; dependsOn }) and
    # Rows ("path|id" -> row). Reason says why there is nothing to reuse; empty when there is.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Basis
    )
    $none = { param($Why) [pscustomobject]@{ Files = @{}; Rows = @{}; Reason = $Why } }
    if (-not [System.IO.File]::Exists($ReportPath)) { return & $none 'there is no previous report there' }
    $doc = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    # A partial, recheck or scoped report is not a measurement of every mutant, and a report whose
    # rows were decided under another basis may not answer for this run.
    if ($doc.mode) { return & $none "that report is a '$($doc.mode)' run, not a full one" }
    $fault = Get-PSMutationIncrementalBasisFault -Prior $doc.incremental.basis -Current $Basis
    if ($fault) { return & $none $fault }
    $files = @{}
    foreach ($p in $doc.incremental.files.PSObject.Properties) { $files[$p.Name] = $p.Value }
    $rows = @{}
    foreach ($m in @($doc.mutants)) { $rows["$($m.File)|$($m.Id)"] = $m }
    return [pscustomobject]@{ Files = $files; Rows = $rows; Reason = '' }
}

function Select-PSMutationReusedRow {
    # The previous rows for one file's candidates, marked Reused -- or $null when any candidate has
    # no previous row describing the same mutant, and the file then runs in full. Pure. A candidate
    # set that changed with the key unchanged means the CONFIG changed -- operators, ignoreCalls,
    # coverage -- and the ids no longer name the same mutants; one mismatch is enough to say so.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [hashtable]$Rows
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Candidates) {
        $row = $Rows["$File|$($c.Id)"]
        if ($null -eq $row -or $row.Description -cne $c.Description -or $row.Line -ne $c.Line -or $row.Operator -cne $c.Operator) { return $null }
        $copy = $row.PSObject.Copy()
        $copy | Add-Member -NotePropertyName Reused -NotePropertyValue $true -Force
        $out.Add($copy)
    }
    return , $out.ToArray()
}

function Get-PSMutationIncrementalState {
    <#
    .SYNOPSIS
        What an incremental run reuses, what it evaluates, what it records, and what it says --
        the same shape whether or not the run is incremental, so the caller needs no branch.
    .DESCRIPTION
        For each mutate file: its key from the previous report's recorded dependencies, re-hashed
        now. A file whose key matches, and whose every candidate matches a previous row, reuses
        those rows. Every other file is evaluated, and its suite's dependencies are measured so its
        key can be recorded for the next run.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$Incremental,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Basis
    )
    if (-not $Incremental) {
        return [pscustomobject]@{ Candidates = $Candidates; Reused = @(); Record = $null; Lines = @() }
    }
    $prior = Read-PSMutationIncrementalPrior -ReportPath $ReportPath -Basis $Basis
    $source = Get-PSMutationIncrementalSource -SandboxRoot $SandboxRoot -AllTests $Plan.AllTests
    $files = [ordered]@{}
    $reused = [System.Collections.Generic.List[object]]::new()
    $evaluate = [System.Collections.Generic.List[object]]::new()
    # Covering suite -> the files it executed, so a suite several files share is measured once.
    $measured = @{}
    $reusedFiles = 0
    foreach ($f in $Plan.Mutate) {
        $rel = ConvertFrom-PSMutationSandboxPath -Path $f -SandboxRoot $SandboxRoot
        $mine = @($Candidates | Where-Object { $_.File -eq $f })
        $hit = Get-PSMutationIncrementalReuse -File $f -Candidates $mine -Plan $Plan -SandboxRoot $SandboxRoot -Prior $prior
        if ($hit) {
            foreach ($r in $hit.Rows) { $reused.Add($r) }
            $files[$rel] = $hit.Entry
            $reusedFiles++
            continue
        }
        foreach ($c in $mine) { $evaluate.Add($c) }
        # No entry at all for a file whose suite could not be measured: with no key recorded, the
        # next run has nothing to match and evaluates it, which is the safe answer.
        $entry = Get-PSMutationIncrementalEntry -File $f -Plan $Plan -SandboxRoot $SandboxRoot -Source $source -Measured $measured
        if ($entry) { $files[$rel] = $entry }
    }
    return [pscustomobject]@{
        Candidates = $evaluate.ToArray(); Reused = $reused.ToArray()
        Record     = [ordered]@{ basis = $Basis; files = $files }
        Lines      = @(@(Get-PSMutationIncrementalLine -ReportPath $ReportPath -Reason $prior.Reason `
                    -Reused $reused.Count -ReusedFiles $reusedFiles -Evaluate $evaluate.Count) +
            @(Get-PSMutationUnmeasuredLine -Measured $measured))
    }
}

function Get-PSMutationUnmeasuredLine {
    # One warning per covering suite whose dependencies could not be measured (#305), sorted so two
    # runs print them alike. Pure.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Measured)
    # No `if ($m.Fault)`: a measured suite's Fault is $null, and Sort-Object passes no $null on, so
    # the guard was a branch nothing could tell from its absence. The test keeps a measured suite
    # beside the failed ones to pin exactly that.
    $faults = foreach ($m in $Measured.Values) { $m.Fault }
    foreach ($f in @($faults | Sort-Object -Unique)) {
        New-PSMutationLine -Role 'Warn' -Text "  INCREMENTAL: $f. The files it covers get no key, so the next run evaluates them in full."
    }
}

function Get-PSMutationCoveringSuitePath {
    # One mutate file's covering test files, absolute and repo-relative.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$File, [Parameter(Mandatory)] [hashtable]$Plan, [Parameter(Mandatory)] [string]$SandboxRoot)
    # Assigned, not wrapped in @(): the suite comes back comma-protected, and @() around the call
    # nested it, so the [string[]] cast joined a two-file suite into ONE path with a space in it.
    # Dependency measurement then failed on a path that does not exist, and the sandbox's own
    # random name ended up inside the key -- so a file mapped to two test files was never reused.
    $suite = Get-PSMutationCoveringSuite -File $File -TestsByFile $Plan.TestsByFile -AllTests $Plan.AllTests
    return [pscustomobject]@{
        Suite = $suite
        Relative = [string[]]@(foreach ($t in $suite) { ConvertFrom-PSMutationSandboxPath -Path $t -SandboxRoot $SandboxRoot })
    }
}

function Get-PSMutationIncrementalReuse {
    # One mutate file's previous rows and record, when its key -- re-hashed now from the files the
    # previous report recorded -- is unchanged and every candidate matches a row; $null otherwise.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] $Prior
    )
    $rel = ConvertFrom-PSMutationSandboxPath -Path $File -SandboxRoot $SandboxRoot
    # No guard for a file the previous report never keyed: its key is then compared with $null,
    # which no hash equals, and the self-mutation gate showed a guard here changed nothing.
    $was = $Prior.Files[$rel]
    # Filtered: an empty list read back from JSON can be $null, and @($null) is one path.
    $deps = [string[]]@($was.dependsOn | Where-Object { $_ })
    $suite = Get-PSMutationCoveringSuitePath -File $File -Plan $Plan -SandboxRoot $SandboxRoot
    if ((Get-PSMutationIncrementalKey -Path (@($rel) + $suite.Relative + $deps) -SandboxRoot $SandboxRoot) -ne $was.key) { return $null }
    $rows = Select-PSMutationReusedRow -Candidates $Candidates -File $rel -Rows $Prior.Rows
    if ($null -eq $rows) { return $null }
    return [pscustomobject]@{ Rows = $rows; Entry = [ordered]@{ key = $was.key; dependsOn = $deps } }
}

function Get-PSMutationIncrementalEntry {
    # The record of one mutate file this run evaluates: its key over what its covering suite
    # executes now, measured once per suite into -Measured, and those files. A file is not its own
    # dependency -- the key names it already.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [hashtable]$Plan,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Source,
        [Parameter(Mandatory)] [hashtable]$Measured
    )
    $rel = ConvertFrom-PSMutationSandboxPath -Path $File -SandboxRoot $SandboxRoot
    $suite = Get-PSMutationCoveringSuitePath -File $File -Plan $Plan -SandboxRoot $SandboxRoot
    $suiteKey = $suite.Suite -join "`n"
    if (-not $Measured.ContainsKey($suiteKey)) {
        # Caught here, not in the measurement: it is this function that decides what an
        # unmeasured suite means, and the answer is no key -- the next run evaluates the file.
        try { $Measured[$suiteKey] = @{ Files = @(Get-PSMutationSuiteDependency -Suite $suite.Suite -Source $Source -SandboxRoot $SandboxRoot) } }
        catch { $Measured[$suiteKey] = @{ Fault = $_.Exception.Message } }
    }
    if ($Measured[$suiteKey].Fault) { return $null }
    $deps = [string[]]@($Measured[$suiteKey].Files | Where-Object { $_ -cne $rel })
    return [ordered]@{ key = (Get-PSMutationIncrementalKey -Path (@($rel) + $suite.Relative + $deps) -SandboxRoot $SandboxRoot); dependsOn = $deps }
}

function Get-PSMutationIncrementalLine {
    # What an incremental run says before it starts. Pure.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Reason,
        [Parameter(Mandatory)] [int]$Reused,
        [Parameter(Mandatory)] [int]$ReusedFiles,
        [Parameter(Mandatory)] [int]$Evaluate
    )
    $from = Split-Path $ReportPath -Leaf
    if ($Reason) {
        return New-PSMutationLine -Role 'Muted' -Text ("  INCREMENTAL: nothing reused from {0}, because {1}. Evaluating all {2} mutant(s), and recording what the next run needs." -f $from, $Reason, $Evaluate)
    }
    return New-PSMutationLine -Role 'Muted' -Text ("  INCREMENTAL from {0}: {1} verdict(s) reused from {2} unchanged file(s), not re-run; {3} mutant(s) to evaluate." -f $from, $Reused, $ReusedFiles, $Evaluate)
}

function Join-PSMutationIncrementalRow {
    # The reused rows and this run's rows together, in candidate order -- the order one run over
    # everything would have recorded them in. Pure. With nothing reused, the rows as they came.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Reused,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    if ($Reused.Count -eq 0) { return , $Results }
    $byKey = @{}
    foreach ($r in @($Reused) + @($Results)) { $byKey["$($r.File)|$($r.Id)"] = $r }
    $out = foreach ($c in $Candidates) { $byKey["$(ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot)|$($c.Id)"] }
    return , @($out)
}
