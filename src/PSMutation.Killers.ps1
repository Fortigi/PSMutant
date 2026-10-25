# Which tests to run FIRST for a mutant (#254): the tests that already killed a mutant near it.
#
# A killed mutant runs its covering files until the first test fails, and most of a run's time is
# spent there -- measured on this repo's self-run, one source file took 74% of all worker time
# because its covering suite takes 26s and a kill stops only at the first failure. One named test
# takes 0.22s. And mutants in one function are mostly killed by the same few tests: over 1584
# kills, trying the tests that had already killed a mutant in the same function, then the same
# file, would have caught at least 61% with three names tried -- at least, because the report
# records only the first killer of each.
#
# Learned within the run, from mutants already finished, so a first run gets it too and no
# report has to be kept between runs.
#
# A name is TRUSTED only once it has passed on its own against unmutated source. A test that
# depends on an earlier test's state fails alone whatever the code, and trusted unproven it would
# kill every mutant it was tried on -- a perfect score that nothing flags. The runner proves each
# name once, on an idle worker, before any mutant is run against it; a name that fails alone, or
# matches no test, is never tried.
#
# Pure: the runner owns the jobs and hands each outcome here.

function New-PSMutationKillerMemory {
    # An empty memory for one run.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: returns a new object, changes no state.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        # "file`nfunction" -> the names that killed a mutant there, oldest first.
        ByFunction = @{}
        # file -> the same, for the whole file.
        ByFile     = @{}
        Proven     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        # name -> seconds its proof took, which sizes the deadline of a first pass that runs it.
        Seconds    = [System.Collections.Generic.Dictionary[string, double]]::new([System.StringComparer]::Ordinal)
        # Every name ever queued for proof, so a name is proven once however often it kills.
        Queued     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        # Waiting for proof: { Name; Suite }, in the order they were learned.
        Pending    = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-PSMutationKiller {
    # Record the tests that killed one mutant, and queue for proof each name never queued before.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Memory,
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Function,
        # The killers by the UNEXPANDED path a Pester filter matches, not the report's names.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Name,
        # The covering files these names were found in, which a proof runs.
        [Parameter(Mandatory)] [string[]]$Suite
    )
    $fnKey = "$File`n$Function"
    foreach ($n in $Name) {
        if (-not $Memory.ByFunction.ContainsKey($fnKey)) { $Memory.ByFunction[$fnKey] = [System.Collections.Generic.List[string]]::new() }
        if (-not $Memory.ByFile.ContainsKey($File)) { $Memory.ByFile[$File] = [System.Collections.Generic.List[string]]::new() }
        $Memory.ByFunction[$fnKey].Add($n)
        $Memory.ByFile[$File].Add($n)
        if ($Memory.Queued.Add($n)) { $Memory.Pending.Add([pscustomobject]@{ Name = $n; Suite = $Suite }) }
    }
}

function Get-PSMutationFirstTest {
    # The proven names to try first for a mutant: the latest killers in its function, then in its
    # file, each once, at most Limit.
    #
    # Latest first because a function's mutants are numbered in source order, so the one finished
    # just before sits next to this one. Three is where the measured hit rate flattens -- 61% at 3,
    # 64% at 5, 65% at 10 -- and every name costs a survivor a little more.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Memory,
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Function,
        [int]$Limit = 3
    )
    $picked = [System.Collections.Generic.List[string]]::new()
    $lists = @($Memory.ByFunction["$File`n$Function"], $Memory.ByFile[$File])
    foreach ($list in $lists) {
        # A foreach STATEMENT over a reversed copy: an absent list iterates zero times.
        foreach ($n in [System.Linq.Enumerable]::Reverse([string[]]@($list | Where-Object { $_ }))) {
            if ($picked.Count -eq $Limit) { return [string[]]$picked }
            if ($Memory.Proven.Contains($n) -and -not $picked.Contains($n)) { $picked.Add($n) }
        }
    }
    return [string[]]$picked
}

function Get-PSMutationProofBatch {
    # Take the waiting names that share the first one's covering files, to prove in one run:
    # { Suite; Name }. $null when nothing waits.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Memory)
    if ($Memory.Pending.Count -eq 0) { return $null }
    $suite = $Memory.Pending[0].Suite
    $key = $suite -join "`n"
    $batch = @($Memory.Pending | Where-Object { ($_.Suite -join "`n") -eq $key })
    foreach ($b in $batch) { [void]$Memory.Pending.Remove($b) }
    return [pscustomobject]@{ Suite = $suite; Name = [string[]]@($batch | ForEach-Object { $_.Name }) }
}

function Complete-PSMutationProof {
    # Record what one proof run said: a name is proven when a test by it passed and none by it
    # failed -- a -ForEach test is one name with several cases. One that failed, or matched no test, stays unproven for the rest of the run -- it was
    # queued once and is not queued again -- and so is never tried first.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Memory,
        [Parameter(Mandatory)] [string[]]$Name,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$PassedPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$FailedPath,
        # How long the proof took, kept against every name it proved.
        [Parameter(Mandatory)] [double]$Seconds
    )
    foreach ($n in $Name) {
        if (($PassedPath -ccontains $n) -and -not ($FailedPath -ccontains $n)) {
            [void]$Memory.Proven.Add($n)
            $Memory.Seconds[$n] = $Seconds
        }
    }
}

function Get-PSMutationFirstPassTimeout {
    # The deadline of a first pass over these names, in whole seconds: the slowest name's proof
    # time times the factor, never under the floor, and never over Cap -- the deadline of the whole
    # files. Not times the workers (#310): a proof runs in a worker while the others run their
    # mutants, so its time already holds the load, as each file's does (Get-PSMutationTimeoutByFile).
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Memory,
        [Parameter(Mandatory)] [string[]]$Name,
        # { Factor; Floor }: the run's timeoutFactor and timeoutFloorSeconds.
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [int]$Cap
    )
    $slowest = ($Name | ForEach-Object { $Memory.Seconds[$_] } | Measure-Object -Maximum).Maximum
    $sized = [math]::Max([double]$Rule.Floor, $slowest * $Rule.Factor)
    return [int][math]::Min($Cap, [math]::Ceiling($sized))
}
