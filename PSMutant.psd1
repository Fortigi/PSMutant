@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.2.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5.2.0 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.0'

    # One function. Get-PSMutationCandidate and Set-PSMutationText used to be exported too,
    # and between them they trafficked a nine-field [pscustomobject] that nothing declared,
    # tested as a contract or versioned -- discoverable only by running the function and
    # inspecting the output, and unchangeable once someone had. Neither was ever mentioned in
    # the README, and Set-PSMutationText had exactly one caller, inside this module (#48).
    #
    # "What would you mutate?" is a fair question to ask, and the answer should be a rendering
    # this module controls -- see #10's -ListOnly -- not a raw AST walker handing out its
    # internals.
    FunctionsToExport = @('Invoke-PSMutation')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # NO RequiredModules entry for Pester, deliberately. ModuleVersion there is a MINIMUM
    # and PowerShell satisfies it by importing the NEWEST installed version -- at import
    # time, before Assert-PSMutationPester or Get-PSMutationPesterPath can have a say. That
    # made `Import-Module PSMutant` followed by `Import-Module Pester -RequiredVersion 5.7.1`
    # fail on an assembly collision and leave the caller on 6.1.0, while the same two lines
    # in the other order worked -- issue #16's failure one layer up, with no diagnostic.
    #
    # Pester is needed at RUN time, not import time, and Assert-PSMutationPester is the single
    # point that enforces it: it accepts an already-loaded Pester >= 5, imports one only when
    # none is loaded, and refuses with an actionable message otherwise. The cost is that
    # Install-Module PSMutant no longer pulls Pester in for you; that is stated in the
    # description, the README and the error message.

    PrivateData = @{
        PSData = @{
            Tags         = @('mutation-testing', 'testing', 'pester', 'ast', 'quality', 'test-quality', 'coverage')
            LicenseUri   = 'https://github.com/Fortigi/PSMutant/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Fortigi/PSMutant'
            ReleaseNotes = '**Preview what a config would mutate, with `-ListOnly`.** There was no way to answer "what would
this actually mutate?" short of a run that takes minutes -- which matters most when you are least
sure: adding a file to `mutate`, changing `operators`, or wondering why a file scores 100%.

```powershell
Invoke-PSMutation -ConfigFile ./c.json -ListOnly
```

Per file, per operator, and how many candidates survive the `coveredLinesOnly` filter, then it
stops. It exists for the **vacuous 100%**: a file that produces no candidates is still listed in
`mutate`, still hashed into the report, contributes 0 of 0, and in a blended score is invisible.
Two files in a real repository were in that state. It names them, and separately the files whose
candidates coverage removed entirely: two faults with two different fixes, one a test to write, the
other a file that does not belong in `mutate`. `FilesWithNoCandidate` and `FilesEmptiedByCoverage`
travel on the result, so a repository that considers either a mistake can fail its own build on it.
`ExitCode` is always 0 -- a preview evaluated nothing, so it has no verdict, the same reason a
recheck applies no thresholds. It refuses `-RecheckFrom`, `-UpdateBaseline` and `-MergeIntoBaseline`.

**A committed list of accepted survivors, so the gate is adoptable on code already red.** Point
`survivorBaseline` at a path; its presence enables the gate, and `-UpdateBaseline` writes it.

```json
{ "mutate": ["src/a.ps1"], "survivorBaseline": ".psmutant-survivors.json" }
```

A survivor **not** in the list fails the run. So does a listed one that has been **fixed** (leave it
and the mutant can start surviving again with nothing failing), one whose **file has left `mutate`**
(dropping a file hides its survivors rather than fixing them), and one that is **also** declared
equivalent (the declaration already excuses it).

This is **debt, not equivalence**. `equivalents` means *this mutant cannot be killed* and carries a
written argument the gate checks; a baseline entry means *this mutant is not killed yet* and is
generated. Without the second, recording known debt meant overstating it as equivalence, which
corrupts the one list whose entries are claims somebody made.

A set of mutants rather than a per-file score, because a score is a ratio whose denominator moves
with the source: measured against a file baselined at 90%, three of four ordinary edits fail the
ratchet and only one usefully. PHPStan and Psalm baseline specific findings for the same reason.
Entries are keyed by file, function and change -- not by line -- so one survives a line moving.
`-UpdateBaseline` writes **even on a failing run**, which is what adoption needs; it cannot launder
a regression, because the next run compares against what was recorded.

**`-MergeIntoBaseline` folds a recheck''s verdicts back into the report it came from.** The loop was
full run, write tests, recheck, recheck -- then a **full run again** purely to refresh a baseline
the rechecks had already made stale.

```powershell
Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json -MergeIntoBaseline
```

Each re-evaluated mutant takes its new verdict; everything else keeps the status it had, and the
report is **re-scored** from the merged rows -- new verdicts under the old number is a
self-contradictory document.

**It refuses rather than merging when the carried-over statuses may be stale.** A merge is sound
only for additive test changes: adding a test cannot revive a mutant the baseline killed, editing or
deleting one can, and a recheck never looks at it. Reports record each mapped test file''s size, and
the merge refuses when one **shrank**, disappeared, or when the baseline predates the field. Length
rather than a hash, deliberately: hash equality asks "unchanged", which would refuse the very loop
this serves. A file that grew may still have had an assertion weakened, so growth **permits** the
merge rather than certifying it, and the merged report records `mergedFrom` and
`carriedOverUnverified` -- the caveat lives in the artifact, not the console.

**A recheck refuses a report that describes a different run.** The compatibility gate walked the
files *this* run mutates, so a file the **report** covers and the run does not was invisible --
measured, a config mutating `a.ps1` accepted a report over `a.ps1` and `b.ps1` with zero reasons.
`-RecheckFrom` takes the report''s whole survivor list, so that run would evaluate `b.ps1`''s
survivors with nothing mapped and no `b.ps1` in the sandbox, then report "N of M previous survivors
now killed" over a set it never had. A scoped run and a full run sharing the default `reportPath` is
enough to reach it.

**A run that stops running now stops, instead of looking like a slow one.** Every mutant was bounded
and the run was not. Observed: a run suspended overnight -- 875 minutes of wall clock against 333
seconds of CPU, a zero-byte report, and a sandbox its live pid kept the sweep from reclaiming.

Two bounds, checked **between** mutants so neither interrupts one mid-flight:

- **A stalled mutant.** The child gets a budget and its handle is waited on for exactly that, so a
  mutant far past it did not run slowly -- what should have stopped it never fired, which is what a
  sleeping machine does to a wait handle. Fires within one mutant and names that cause.
- **A whole-run budget** as the backstop: the baseline plus twice one per-mutant budget for every
  mutant, which no correct run can exceed. `runTimeoutSeconds` overrides it; **0 disables it**.

Both stop by throwing, so the partial-report path writes what the run got through. The limits are
loose on purpose: a bound that fires on a slow-but-working run gets switched off within a week.

**An interrupted run writes a partial report instead of nothing.** Ctrl-C, a cancelled CI job or a
killed agent used to discard everything. The document is marked `"mode": "Partial"` with `evaluated`
and `planned`, and is **counts, never a score** -- the loop evaluates in candidate order, so an
interrupted run has seen whichever files sort earliest, not a sample of anything.

**The report and the console break the score down per file.** A blended score is an average, so a
strong file carries a weak one and the gate passes on a number nobody would accept per file --
observed on a real consumer at ~89% blended while files ranged from 39.6% to 100%.

```
  2 of 3 file(s) score below 85%:
      39.6%  src/weak.ps1  (19 killed / 48)
        78%  src/middling.ps1  (39 killed / 50)
```

`perFile` in the report carries each file''s score with the counts it was computed over, weakest
first. The console prints only files below the good band, and nothing at all when one file was
mutated or every file is at or above it -- so a clean run reads exactly as before.

**The report says which tests killed each mutant.** Every row carries `KilledBy`. By default the
lists are **truncated** -- a mutant''s suite stops at the first failure, since once one test has
noticed, every test after it is work that cannot change the verdict. Truncated is not "exactly one":
over 118 killed mutants the default still reported several killers for 20 of them, so a row''s length
says nothing about how many tests really kill it. Read `killersComplete`.

Set **`recordAllKillers: true`** to record every killer. It costs the early stop -- 50s becomes 73s
on those 118 mutants, about 46% more, for identical verdicts -- so it buys data, not accuracy, and
is opt-in. With it on the report also names **`testsWithoutKills`**: mapped test files that killed
nothing. That field is **absent** on a default run and the schema refuses it there, because under
the early stop a test that would have killed but was skipped looks exactly like one that cannot.

**`-Verbose` now tells you something, and progress goes to the stream built for it.** Everything the
module said went to the run result or the host, so re-running with `-Verbose` produced nothing. A
run now traces its **resolutions**: the sandbox, the subtrees copied, the files that resolved into
the mutate set, the Pester found, and which covering suite each file mapped to. `-Verbose` and
`-Quiet` are **independent** -- `-Quiet` silences the console log, not a stream the console was not
showing -- so `-Quiet -Verbose` gives the trace with none of the per-mutant chatter. Per-mutant
progress also goes through `Write-Progress`, which no caller collecting output can swallow.

**`schemaVersion` is now 2, and the report discloses more of what its score does not cover.**

- `filesWithNoCandidate` -- files in `mutate` no operator matched, which score a vacuous 100%. It is
  **required** on a scored report, which is what the version bump is for: a document that cannot say
  whether a file contributed nothing is a score with a hole in it, and "the writer always sets it"
  is the assurance every other disclosure here declined to rely on.
- `filesWithNoMutants` -- files whose candidates the coverage filter removed entirely. Its schema
  description claimed to cover both cases while the code reported only this one; both descriptions
  are now true of what they hold.
- `filesMutated` -- how many files the score was computed over, now **required** too. It was left
  optional in v1 for one reason: requiring it would have failed every report 0.4.0 produced, and
  the version could not move for a merely added field. That deferral is spent. It counts the list
  your config names, never a directory listing.

`schemas/v2/report.schema.json` ships beside the module, and `schemas/v1/` still ships: an archived
report says `schemaVersion: 1` and that is the only schema that can validate it. The rule for the
number is stated correctly now -- it moves when a field changes **meaning**, **disappears** or
**becomes required**, and never when an optional one is added.

**Per-file paths in the report are repo-relative again.** `filesWithNoMutants` and the uncovered
caveat carried absolute paths under a temp sandbox -- a directory whose name changes every run,
which no consumer can match against a checkout, and which is deleted before a reader sees it.

**A schema failure on a scored report names the field that is actually missing.** The full/recheck
split was keyed on the presence of `mode`, so a report missing one disclosure failed the `else` arm
while the validator reported the `if` arm''s requirement -- naming `mode`, the one field whose
presence would turn the document into a different kind of report. The discriminator is keyed on
`mutationScore` now.'
        }
    }
}
