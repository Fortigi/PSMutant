# Public entry point for PSMutant: wiring, and nothing else -- the prelude every mode
# shares, then the entry point that chooses between them.

function Get-PSMutationRunContext {
    <#
    .SYNOPSIS
        Everything a run resolves before the modes diverge, packaged once.

    .DESCRIPTION
        Every mode -- full, recheck, -ListOnly -- needs the same prelude in full before it can
        differ: plan the sandbox paths, check the config's paths actually arrived, measure the
        baseline, size the timeout, enumerate the candidates, hash the sources. Threaded out as
        separate values, each new mode re-lists the parts it wants and every new value the
        prelude produces has to be added to every one of those lists.

        This does NOT create the sandbox, and the omission is the point: the caller creates it
        outside its own try/finally so the tree is removed even when the prelude throws, which is
        exactly what a red baseline or a missing config path does.

        The two clusters -- Exec and Doc -- are what a run EXECUTES with and what a report
        DOCUMENTS itself with, each shared by two callees. A value is spelled once here, so
        adding one is an edit at its source rather than at every call site forwarding it.

    .PARAMETER ChangedFile
        Scope the run to these files: `mutate` intersected with what a pull request changed.
        Everything else follows -- only those files are enumerated, hashed, and answered for.

        It answers the question a reviewer actually has: are the lines this PR introduced tested
        well enough? A whole-repo score cannot answer that, and a whole-repo score is what makes
        people turn the gate off.

        THE CALLER COMPUTES THE DIFF, and there is deliberately no -ChangedSince <ref>. A diff is
        not a fact this module can work out: it needs a base, and every way that goes wrong goes
        wrong in the CALLER's environment -- a shallow clone where the ref was never fetched, a
        detached HEAD, a merge base that is not the one the reviewer sees. Resolving it here would
        turn those into a mutation tool refusing to run, several layers from the shell where they
        can be fixed. The sibling module refused the same parameter for the same reason.

            $changed = git diff --name-only origin/main...HEAD
            Invoke-PSMutation -ConfigFile ./c.json -ChangedFile $changed

        AN EMPTY LIST IS REFUSED. `git diff` against a ref that was never fetched prints nothing
        and exits 0, and taken at face value that is a confident pass over zero mutants. A list
        that holds files, none of which are in `mutate`, is a different situation entirely -- an
        ordinary documentation change -- and passes, saying so.

        The score is real but it is not the project's: it covers the files named and nothing else.
        So the report goes to <report>.changed.json, never the project's file, `mode` is 'Changed',
        and `changedFiles` sits beside the score in both the document and the result. It cannot be
        combined with -RecheckFrom, -UpdateBaseline or -MergeIntoBaseline; folding a scoped run's
        survivors into a whole-project baseline would record "no survivors" for every file the run
        never looked at.

        Restricting mutants to changed LINES is not implemented. It needs hunk offsets, which have
        the same problem -ChangedSince has and no agreed shape yet.

    .PARAMETER ListOnly
        Preview the mutant set. Decides only whether the baseline is worth measuring; the
        rendering and the early return belong to the caller.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Cfg,
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Subtrees,
        [switch]$ListOnly,
        # This run rechecks a prior report. Decides only whether the baseline is instrumented --
        # which mutants a recheck evaluates is Recheck.ps1's business, not this function's.
        [switch]$Recheck,
        # Scope the run to these files. $null is a whole-tree run; an EMPTY list never reaches
        # here -- the caller refuses it, because a diff that produced nothing is more often a
        # broken pipeline than a pull request that changed nothing.
        [string[]]$ChangedFile,
        [switch]$Quiet
    )
    $t = Get-PSMutationSandboxPlan -Cfg $Cfg -SourceRoot $SourceRoot -SandboxRoot $SandboxRoot

    # The plan's Mutate is NARROWED, and everything downstream follows from it: what the baseline
    # instruments, what is enumerated, what is hashed, what the report answers for. One definition
    # of "what this run mutates" rather than a scope flag each of them has to remember separately.
    #
    # AllTests is deliberately left whole. The green gate covers the entire mapped suite even when
    # two files are being mutated: a baseline that ran only the changed files' tests would be a
    # weaker gate bought for speed, and speed is already what this mode is.
    $inScope = $null
    if ($null -ne $ChangedFile) {
        $t.Mutate = Select-PSMutationScopedMutateFile -Mutate $t.Mutate -ChangedFile $ChangedFile `
            -SourceRoot $SourceRoot -SandboxRoot $SandboxRoot
        # Named the way the CONFIG names them, because that is how equivalence declarations are
        # keyed. Stays $null on a whole-tree run: absent and empty are different answers, and
        # only absent means "every declaration was judged".
        # A foreach STATEMENT, not a pipeline: over an empty scope a pipeline iterates once with
        # $_ = $null and indexes the map with it. The same shape as the coverage collector in
        # Invoke-PSMutationBaseline, and reached the same way -- by a case that produces nothing.
        $inScope = [System.Collections.Generic.List[string]]::new()
        foreach ($m in $t.Mutate) { $inScope.Add($t.ConfigByPath[$m]) }
        $inScope = [string[]]@($inScope)
    }

    # THE RESOLUTIONS, on the verbose stream. These are narration while a run works and the
    # first four questions when it does not: which sandbox, which files were actually
    # resolved into the mutate set, which suite each one maps to, and which Pester answered.
    # None of them was recoverable before -- the module had no verbose stream at all, so
    # re-running with -Verbose, the usual first move, produced nothing.
    Write-PSMutationOutput -Quiet:$Quiet -Lines @(
        (New-PSMutationLine -Role 'Trace' -Text "sandbox: $SandboxRoot")
        (New-PSMutationLine -Role 'Trace' -Text ("subtrees copied: {0}" -f ($Subtrees -join ', ')))
        (New-PSMutationLine -Role 'Trace' -Text ("mutate set resolved to {0} file(s): {1}" -f `
                    @($t.Mutate).Count, ((@($t.Mutate) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))
        (New-PSMutationLine -Role 'Trace' -Text ("pester: {0}" -f (Get-PSMutationPesterPath)))
    )
    foreach ($f in @($t.Mutate)) {
        $covering = Get-PSMutationCoveringSuite -File $f -TestsByFile $t.TestsByFile -AllTests $t.AllTests
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Trace' `
                -Text ("  {0} -> {1}" -f (Split-Path $f -Leaf),
                    ((@($covering) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))
    }

    # Before the baseline, because after it the answer is a false statement about the
    # tests rather than a true one about the config. Checked on a preview too: a config
    # naming a path the sandbox never received is wrong whether or not anything runs.
    $missing = Get-PSMutationMissingSandboxPath -Paths (@($t.Mutate) + @($t.AllTests)) -Subtrees $Subtrees
    if ($missing) { throw $missing }

    $coveredOnly = Get-PSMutationCoveredLinesOnly -Cfg $Cfg
    $baselineNeeded = Test-PSMutationBaselineNeeded -ListOnly $ListOnly.IsPresent -CoveredLinesOnly $coveredOnly
    # ONE answer, read twice: it enables the tracer below and applies the filter further down.
    # Split into two decisions they could disagree, and one of the two disagreements evaluates
    # nothing at all -- a filter with no coverage behind it keeps no candidate.
    $coverageNeeded = Test-PSMutationCoverageNeeded -CoveredLinesOnly $coveredOnly `
        -Recheck $Recheck.IsPresent -HasMutateFile (@($t.Mutate).Count -gt 0)
    $baseline = Get-PSMutationRunBaseline -Plan $t -SandboxRoot $SandboxRoot -Measure:$baselineNeeded `
        -Coverage:$coverageNeeded -Quiet:$Quiet
    # Derived on BOTH paths from the one duration, rather than a literal in the preview arm. A
    # timeout nothing in a preview reads is unobservable, and every mutant of a hardcoded one
    # survives a test that can only assert the preview did not throw.
    $timeout = Get-PSMutationTimeout -Cfg $Cfg -BaselineSeconds $baseline.DurationSeconds
    if ($baselineNeeded) {
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Good' `
                -Text ("  Baseline green in {0:N1}s (per-mutant timeout {1}s)" -f $baseline.DurationSeconds, $timeout))
    }

    $ops = Get-PSMutationOperatorList -Cfg $Cfg
    $selection = Select-PSMutationCandidate -MutateFiles $t.Mutate -Operators $ops `
        -CoveredLinesOnly $coverageNeeded -CoveredLines $baseline.CoveredLines
    # Locals first, because two of these appear both as their own field and inside Doc. Spelled
    # twice they would be COMPUTED twice -- a second hash of every mutate file -- and the copies
    # could drift; there would then be two answers to "which report does this run write".
    # ASSIGNED, never wrapped: the projection returns `, @(...)` so an empty selection stays an
    # empty array, and @( ) around that gives a one-element array holding the array.
    $perFile = ConvertTo-PSMutationDisplayPerFile -PerFile $selection.PerFile -SandboxRoot $SandboxRoot
    $hashes = Get-PSMutationSourceHashMap -MutateFiles $t.Mutate -SandboxRoot $SandboxRoot
    $reportPath = Get-PSMutationReportPath -Cfg $Cfg -SourceRoot $SourceRoot
    # Never the project's file. This run measured part of the tree, and the convention
    # -RecheckFrom established is that a partial answer gets a path of its own.
    if ($null -ne $ChangedFile) { $reportPath = Get-PSMutationScopedReportPath -ReportPath $reportPath }
    return @{
        Plan             = $t
        Baseline         = $baseline
        BaselineMeasured = $baselineNeeded
        # What the CONFIG asks for, which is what the preview must report against -- not
        # $coverageNeeded, which a recheck turns off. A preview is never a recheck, so the two
        # agree there; carrying the config's answer keeps that a fact rather than a coincidence.
        CoveredLinesOnly = $coveredOnly
        TimeoutSeconds   = $timeout
        Operators        = $ops
        Selection        = $selection
        # The tally everything HUMAN-facing reads: same numbers, repo-relative paths.
        PerFile          = $perFile
        # Derived here in the wiring and carried, because the pre-filter counts exist only
        # inside the selection; recomputing them later means parsing every file again.
        Exclusion        = Get-PSMutationCoverageExclusion -PerFile $perFile
        SourceHashes     = $hashes
        ReportPath       = $reportPath
        # $null on a whole-tree run, which is what the report writer keys its `mode` marker off
        # and what tells a reader the score covered everything in `mutate`.
        ChangedFiles     = $ChangedFile
        InScopeFile      = $inScope
        # NOT in Exec, which is splatted into the recheck run as well. A recheck evaluates its
        # mutants through the same loop and still records a first killer per row; what it does
        # not do is pay for the complete list, because its report carries no killersComplete
        # disclosure to make one readable.
        RecordAllKillers = Get-PSMutationRecordEveryKiller -Cfg $Cfg
        # The provenance values that are known NOW. The scriptblock stays with the caller --
        # see the comment at its call site -- because a scriptblock built here and invoked
        # after this function returns would read $null for every one of these.
        ProvenanceArgs   = @{
            ModuleVersion           = (Get-Module PSMutant).Version
            BaselineSeconds         = $baseline.DurationSeconds
            PerMutantTimeoutSeconds = $timeout
        }
        Exec             = @{ Candidates = $selection.Candidates; TimeoutSeconds = $timeout; SandboxRoot = $SandboxRoot; Quiet = $Quiet }
        Doc              = @{ SourceHashes = $hashes; Operators = $ops; Equivalents = $Cfg.equivalents; ReportPath = $reportPath }
    }
}

function Invoke-PSMutation {
    <#
    .SYNOPSIS
        Run mutation testing over a set of PowerShell files and score how many
        injected faults ("mutants") the Pester suite catches ("kills").

    .DESCRIPTION
        All work happens in a throwaway temp sandbox: the source subtrees are copied
        out, mutants are spliced into the COPY, and the tests run from the copy - so
        tracked source is never modified, even if the run is killed mid-way. Returns
        a summary object; report-only unless the config sets thresholds.break.

    .PARAMETER ConfigFile
        Path to a JSON config: mutate, tests, operators, coveredLinesOnly, thresholds,
        reportPath, sandboxSubtrees.

        The format is DEFINED by schemas/v1/config.schema.json, which ships beside this module
        and is what the module itself validates against -- so it cannot describe a config this
        module would reject. Point a config's $schema at it for editor completion. The README
        carries the same table with prose around it.

    .PARAMETER SourceRoot
        Root of the code under test; config paths are relative to it. Defaults to the
        current directory.

    .PARAMETER RecheckFrom
        Path to a report from a previous run -- full or from an earlier recheck.
        Evaluates ONLY the mutants that report recorded as survivors, minus any declared
        equivalent, which is the fast inner loop while you are writing assertions.

        Chaining is the point: recheck a recheck and each round evaluates only what the
        previous one left alive, so the loop shortens as you close in rather than
        restarting from the full set every time. Rounds overwrite one
        <report>.recheck.json; the full report is never written by a recheck.

        This is not a measurement and does not produce a score: the set is filtered,
        so no percentage over it means anything, thresholds are not applied, and the
        result is written to a separate <report>.recheck.json so the full baseline
        cannot be overwritten by a partial run.

        It is also only sound for test changes that purely ADD assertions. Editing or
        deleting an existing test can revive a mutant that was killed before, and a
        recheck never evaluates those -- so finish with a full run before trusting a
        number or moving a threshold.

    .PARAMETER ListOnly
        Print what this config WOULD mutate -- per file, per operator, and how many candidates
        survive the coveredLinesOnly filter -- then stop. No mutant is evaluated, no report is
        written and no score is produced.

        It answers the question you have when you are least sure: adding a file to `mutate`,
        changing operators, or wondering why a file scores 100%. A file that produces no
        candidate at all scores a VACUOUS 100% and contributes nothing, and in a blended score
        that is invisible -- two files in a real repository were in exactly that state. This
        names them, in seconds, along with the files whose candidates the coverage filter
        removed entirely. Different faults with different fixes, so they are listed apart.

        Cost: the baseline suite runs ONCE, because `coveredLinesOnly` is part of what would
        actually be mutated and a preview that skipped it would answer a different question than
        the run does. That filter defaults to ON, so this is the ordinary case; set it to false
        and the preview is a parse. Either way it never pays the mutants x suite a run pays --
        which is minutes against seconds on any repository worth previewing.

    .PARAMETER Quiet
        Suppress the console output: the banner, the per-mutant progress lines and the
        closing summary. The JSON report is still written and the result object is still
        returned, so nothing is lost -- only the narration.

        Worth using in CI, where a build log gains nothing from a line per mutant. Worth
        leaving OFF interactively, where those lines are the only sign of progress during
        a run that can take minutes, and survivors appear in yellow as they are found
        rather than all at the end.

    .OUTPUTS
        [pscustomobject]. Two shapes, sharing Mode, ExitCode and FailureReason so a caller that
        did not choose the mode can still branch on the result:

            full     @{ Mode='Full'; Score; Killed; Survived; Total; ExitCode; FailureReason;
                        StaleEquivalents; DeclaredEquivalent }
            recheck  @{ Mode='Recheck'; PriorSurvivors; Rechecked; NowKilled; StillSurviving;
                        ExitCode; FailureReason }
            list     @{ Mode='List'; Files; Produced; Total; FilesWithNoCandidate;
                        FilesEmptiedByCoverage; BaselineMeasured; ExitCode; FailureReason }

        A -ChangedFile run returns the FULL shape with Mode='Changed' and ChangedFiles naming the
        scope. ChangedFiles is $null on an unscoped run -- absent and empty are different answers,
        and only absent may be read as a measurement of everything in `mutate`.

        FailureReason is 'None', 'StaleEquivalents' or 'BelowThreshold'. It exists because
        ExitCode 1 means either of the last two, and the difference decides what to go and fix:
        a stale declaration is a false statement in the config inflating the score, not a
        shortfall to write tests against.

        A -ListOnly ExitCode is always 0 for the same reason a recheck's is: it evaluates
        nothing, so it has no verdict and must not manufacture one. What it hands back instead is
        the two vacuous-100% sets by name, so a caller can fail its own build on them.

        A recheck ExitCode is always 0. It applies no thresholds by design -- it answers "is this
        one dead yet" over a set you chose, and a verdict over a chosen subset is the filtered
        number this module exists to stop people quoting. Read StillSurviving.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./psmutant.config.json

        A full run. Prints a coloured score, lists the survivors to go and kill, and
        writes the JSON report named by the config's reportPath.

    .EXAMPLE
        $r = Invoke-PSMutation -ConfigFile ./psmutant.config.json -Quiet
        if ($r.ExitCode -ne 0) { throw "Mutation run failed: $($r.FailureReason)" }

        A CI gate. -Quiet drops the per-mutant progress lines, which are worth watching
        interactively and are noise in a build log.

        Read FailureReason rather than assuming the score. ExitCode 1 also means a stale
        equivalence declaration, which fires at any score and in report-only mode -- so a
        message hardcoded to "below the threshold" is a false statement about that run, and on
        a destroyed CI runner it is the only thing left.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json

        Re-run ONLY the mutants the previous report recorded as survivors -- the fast
        inner loop while you are writing assertions to kill them. Declared equivalents
        are skipped, since the config already argues no test can kill those.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json
        Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.recheck.json

        A recheck report seeds the next recheck, so the loop NARROWS: five survivors,
        kill two, and the second round evaluates three rather than five again. Each round
        overwrites the same *.recheck.json; the full report is never touched.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -ListOnly

        What would this config mutate? Prints a per-file, per-operator breakdown and stops --
        no mutant evaluated, no report written. The line to look for is a file with 0
        candidates: it scores a vacuous 100% that a blended number cannot show you.

    .EXAMPLE
        $p = Invoke-PSMutation -ConfigFile ./c.json -ListOnly -Quiet
        if ($p.FilesWithNoCandidate.Count -gt 0) { throw "no mutants: $($p.FilesWithNoCandidate -join ', ')" }

        The same preview as a gate of your own. The module will not fail the run for you --
        a file with nothing to mutate is not always a mistake -- but it names the files so
        a repository that considers it one can say so.

    .EXAMPLE
        $changed = git diff --name-only origin/main...HEAD
        $r = Invoke-PSMutation -ConfigFile ./c.json -ChangedFile $changed
        exit $r.ExitCode

        A per-PR gate. Only the changed files in `mutate` are evaluated, so the run costs a
        fraction of a full one, and the score is about the code under review rather than the
        repository. A pull request touching no mutable file passes and says so.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -ChangedFile $changed -ListOnly

        What would this pull request mutate? The one combination -ListOnly permits, and the
        cheapest use either has.

    .EXAMPLE
        Invoke-PSMutation -ConfigFile ./c.json -SourceRoot ../other-repo

        Mutate a different repository. Every path in the config is relative to
        -SourceRoot, which defaults to the current directory.

    .LINK
        https://github.com/Fortigi/PSMutant
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigFile,
        [string]$SourceRoot = (Get-Location).Path,
        [string]$RecheckFrom,
        # Preview the mutant set and stop. Evaluates nothing, so it refuses to combine with
        # any switch that acts on verdicts -- see Get-PSMutationModeFault.
        [switch]$ListOnly,
        # Scope the run to the files a pull request changed. The CALLER computes the diff -- see
        # the .PARAMETER block for why there is no -ChangedSince. AllowEmptyString so a list of
        # blanks reaches Get-PSMutationChangedFileFault, whose message names the likely cause.
        [AllowEmptyString()] [string[]]$ChangedFile,
        [switch]$Quiet,
        # Record this run's survivors as the accepted baseline. Writes even on a failing run --
        # see the call site.
        [switch]$UpdateBaseline,
        # With -RecheckFrom: fold this recheck's verdicts back into the report it was seeded
        # from, instead of leaving the baseline stale until the next full run.
        [switch]$MergeIntoBaseline
    )

    # Started before anything else so `totalSeconds` covers what a user actually waits for,
    # sandbox setup and baseline included, rather than only the mutation loop.
    $runClock = [System.Diagnostics.Stopwatch]::StartNew()
    $root = (Resolve-Path $SourceRoot).Path
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Assert-PSMutationConfig -Cfg $cfg
    # Refused before anything is built. The answer needs nothing a sandbox or a Pester could
    # tell us, and copying a tree first is a slower way to say no.
    $modeFault = Get-PSMutationModeFault -ListOnly $ListOnly.IsPresent -Recheck ([bool]$RecheckFrom) `
        -UpdateBaseline $UpdateBaseline.IsPresent -MergeIntoBaseline $MergeIntoBaseline.IsPresent `
        -Changed $PSBoundParameters.ContainsKey('ChangedFile')
    if ($modeFault) { throw $modeFault }
    # BOUND, not truthy. An omitted -ChangedFile is a whole-tree run; one passed as an empty list
    # is a caller whose diff produced nothing, and those must not be the same answer. $null and
    # @() are indistinguishable once bound to [string[]], so the question has to be asked of
    # $PSBoundParameters rather than of the value.
    if ($PSBoundParameters.ContainsKey('ChangedFile')) {
        $changedFault = Get-PSMutationChangedFileFault -ChangedFile $ChangedFile
        if ($changedFault) { throw $changedFault }
    }
    Assert-PSMutationPester
    Clear-PSMutationStaleSandbox

    $subtrees = Get-PSMutationSubtree -Cfg $cfg -SourceRoot $root
    # Created OUTSIDE the try that removes it, with the prelude INSIDE. The prelude throws on a
    # red baseline and on a config path the sandbox never received; created inside, a full tree
    # copy would be left behind on exactly those two failures.
    $sandbox = New-PSMutationSandbox -RepoRoot $root -Subtrees $subtrees
    try {
        $ctx = Get-PSMutationRunContext -Cfg $cfg -SourceRoot $root -SandboxRoot $sandbox `
            -Subtrees $subtrees -ListOnly:$ListOnly -Recheck:([bool]$RecheckFrom) `
            -ChangedFile $ChangedFile -Quiet:$Quiet
        if ($ListOnly) {
            Write-PSMutationOutput -Quiet:$Quiet -Lines (Get-PSMutationMutantListLine `
                    -PerFile $ctx.PerFile -CoveredLinesOnly $ctx.CoveredLinesOnly `
                    -BaselineMeasured $ctx.BaselineMeasured)
            return ConvertTo-PSMutationListResult -PerFile $ctx.PerFile -BaselineMeasured $ctx.BaselineMeasured
        }

        $t = $ctx.Plan
        $cands = $ctx.Selection.Candidates
        $exec = $ctx.Exec
        $doc = $ctx.Doc
        # Built HERE, and that is a scoping fact rather than a preference. A PowerShell
        # scriptblock resolves an unbound variable in the scope that INVOKES it, walking the
        # call stack -- not the scope that created it. Measured: a scriptblock built inside a
        # function and invoked after that function has returned reads $null for every local it
        # names, with no error. Defined here it works for the same reason it always did, because
        # every callee that invokes it is called from this frame.
        #
        # The early values are bound in the context, where they are known. The clock is read on
        # invocation, which has to be AFTER the loop or totalSeconds records how long the run
        # took to start rather than to finish.
        $provArgs = $ctx.ProvenanceArgs
        $provenance = { New-PSMutationProvenance @provArgs -TotalSeconds $runClock.Elapsed.TotalSeconds }
        if ($RecheckFrom) {
            return Invoke-PSMutationRecheckRun @exec @doc -RecheckFrom $RecheckFrom -Plan $t -Provenance $provenance -MergeIntoBaseline:$MergeIntoBaseline
        }

        # Said before the loop, because that is when it can still be acted on -- the cost it
        # names is paid on every mutant that follows.
        # Wrapped: a PowerShell function returning an empty collection unrolls it to NOTHING,
        # so this binds $null on the ordinary path however carefully the callee types its
        # output. That $null is what reached the report as `[null]` in #158.
        $unmapped = @(Get-PSMutationUnmappedMutateFile -MutateFiles $t.Mutate -TestsByFile $t.TestsByFile)
        if ($unmapped.Count -gt 0) {
            Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                    -Text ("  {0} mutate file(s) have no tests entry, so every one of their mutants runs the WHOLE suite: {1}" -f `
                            $unmapped.Count, (($unmapped | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))
        }
        # Said before the loop, on every scoped run, because a passing gate is otherwise silent
        # about the fact that it measured part of the tree -- and a number over part of a tree
        # that nobody knows is partial is the one this module exists to stop being quoted.
        if ($null -ne $ctx.ChangedFiles) {
            Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                    -Text ("  SCOPED run: {0} changed file(s) given, {1} of them in mutate. The score covers those only, and the report goes to {2}." -f `
                            @($ctx.ChangedFiles).Count, @($t.Mutate).Count, (Split-Path $ctx.ReportPath -Leaf)))
        }
        Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Detail' `
                -Text "  Mutants to evaluate: $($cands.Count)`n")

        # FINALLY, not catch, and the difference is the whole feature. Ctrl-C and a cancelled CI
        # job raise a pipeline STOP, which a catch block never sees -- measured: a catch beside
        # this one does not run, a finally does. Written with a catch, the partial report would
        # appear for a crash and be missing for the interruption people actually hit.
        #
        # $done is the flag rather than testing $results, because the loop returning normally
        # with zero rows is a legitimate outcome (a config whose files contribute no covered
        # candidates) and must write the ordinary empty report, not a partial one.
        $partial = [System.Collections.Generic.List[object]]::new()
        $done = $false
        try {
            $results = Invoke-PSMutationLoop @exec -TestsByFile $t.TestsByFile -AllTests $t.AllTests -Sink $partial -RecordAllKillers:$($ctx.RecordAllKillers) -DeadlineSeconds (Get-PSMutationRunDeadlineBudget -Cfg $cfg -CandidateCount $cands.Count -TimeoutSeconds $ctx.TimeoutSeconds -BaselineSeconds $ctx.Baseline.DurationSeconds)
            $done = $true
        }
        finally {
            if (-not $done) {
                $written = Write-PSMutationPartialReport -Results @($partial) -Planned $cands.Count `
                    -ReportPath $ctx.ReportPath -Operators $ctx.Operators -SourceHashes $ctx.SourceHashes -Provenance (& $provenance)
                # Printed rather than returned: the run is being torn down, so there is no caller
                # left to hand a value to, and a file written where nobody was told about it is
                # only marginally better than no file.
                Write-PSMutationOutput -Quiet:$false -Lines (New-PSMutationLine -Role 'Muted' `
                        -Text ("`n  Interrupted after {0} of {1} mutant(s). Wrote a PARTIAL report to {2} -- counts only, no score." -f `
                                $partial.Count, $cands.Count, $written))
            }
        }
        # Invoked here, not above: the elapsed time has to be read AFTER the loop, or
        # totalSeconds records how long the run took to start rather than to finish.
        $summary = Write-PSMutationReport @doc -Results $results -Thresholds $cfg.thresholds -Provenance (& $provenance) -Exclusion $ctx.Exclusion -UnmappedFiles $unmapped -MutateFiles $t.Mutate -KillersComplete $ctx.RecordAllKillers -MappedTests $t.AllTests `
            -TestFileLength (Get-PSMutationTestFileLength -Path $t.AllTests -SandboxRoot $sandbox) `
            -ChangedFiles $ctx.ChangedFiles -InScopeFile $ctx.InScopeFile
        $band = Get-PSMutationScoreBand -Cfg $cfg
        $summaryLines = Get-PSMutationSummaryLine -Summary $summary -Results $results `
            -High $band.High -Low $band.Low -ReportPath $ctx.ReportPath -Equivalents $cfg.equivalents -Exclusion $ctx.Exclusion -PerFile (Get-PSMutationPerFileScore -Results $results -Equivalents $cfg.equivalents)
        Write-PSMutationOutput -Quiet:$Quiet -Lines $summaryLines
        # Annotations are NOT passed -Quiet, and that is the point rather than an oversight.
        # -Quiet exists so a CI log is not filled with several hundred progress lines, and CI is
        # exactly where a survivor most needs to be visible: suppressing both leaves a failed
        # gate printing a score and nothing else, which is a backstop that cannot say what
        # failed. The switch silences the LOG; a finding is not log.
        if (Test-PSMutationAnnotationHost) {
            # @() because a run with NOTHING to annotate yields no lines at all, and -Lines
            # accepts an empty collection but not $null. Without it a clean run under Actions
            # throws on binding -- so the green path would be the one that crashed.
            # -Quiet:$false rather than omitting the switch. Not decoration: an omitted switch
            # is UNBOUND on the call, and a Should-Invoke filter that mentions $Quiet then has
            # to resolve it -- $false, or the caller's own $Quiet further up the scope chain --
            # and the two answers are not the same on every PowerShell. Binding it explicitly
            # makes every renderer call carry the parameter, so no filter anywhere can be
            # ambiguous about which calls it selected.
            #
            # It also says the thing out loud at the call site: annotations are deliberately
            # NOT suppressed, because -Quiet silences the log and a finding is not log.
            Write-PSMutationOutput -Quiet:$false -Lines @(Get-PSMutationAnnotationLine -Lines $summaryLines)
        }

        # The reason first, and the exit code derived from it, so the two cannot disagree about
        # the same run.
        # The accepted-survivor baseline, when the config names one. Applied AFTER the report is
        # written, so a run that fails here still leaves the evidence a reader needs to act on.
        # The work is in Report.ps1: this file keeps the one line that decides whether to do it.
        $baselinePath = Get-PSMutationSurvivorBaselinePath -Cfg $cfg -SourceRoot $root
        $baselineFault = $baselinePath ?
            @(Invoke-PSMutationSurvivorBaseline -BaselinePath $baselinePath -Results $results `
                -MutateFiles @($cfg.mutate) -Equivalents $cfg.equivalents `
                -Update:$UpdateBaseline -Quiet:$Quiet) : @()

        # The reason first, and the exit code derived from it, so the two cannot disagree about
        # the same run.
        # A scoped run that matched no mutable file. Computed once and read by both, so the
        # reason and the code cannot disagree about the same run.
        $emptyScope = ($null -ne $ctx.ChangedFiles) -and (@($t.Mutate).Count -eq 0)
        if ($emptyScope) {
            Write-PSMutationOutput -Quiet:$Quiet -Lines (New-PSMutationLine -Role 'Muted' `
                    -Text ("  None of the {0} changed file(s) is in mutate, so there was nothing to mutate. Passing." -f `
                            @($ctx.ChangedFiles).Count))
        }
        $reason = Get-PSMutationFailureReason -Summary $summary -Thresholds $cfg.thresholds -BaselineFault $baselineFault -EmptyScope $emptyScope
        $exit = Get-PSMutationExitCode -Summary $summary -Thresholds $cfg.thresholds -BaselineFault $baselineFault -EmptyScope $emptyScope
        return ConvertTo-PSMutationRunResult -Summary $summary -ExitCode $exit -FailureReason $reason `
            -ChangedFiles $ctx.ChangedFiles
    }
    finally {
        # The warm mutant runspace outlives individual mutants by design; it must not outlive the
        # run, or a long-lived host keeps a Pester-loaded runspace per completed run.
        Close-PSMutationWarmRunspace
        Remove-PSMutationSandbox -SandboxRoot $sandbox
    }
}
