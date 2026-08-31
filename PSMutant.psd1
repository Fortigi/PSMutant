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
            ReleaseNotes = '**Configs pipe in, one independent run each.** There was no pipeline binding at all, so a monorepo
gating per package meant a `foreach` with the exit codes collected by hand.

```powershell
Get-ChildItem ./packages -Directory |
    Invoke-PSMutation -ConfigFile ./psmutant.config.json -Quiet | Where-Object ExitCode -ne 0
```

`-ConfigFile` binds by value and by property name; `-SourceRoot` by property name with `FullName`
aliased, and `PSPath` deliberately not -- it is provider-qualified. Each config runs **as it
arrives** with its own sandbox, baseline and report, so twenty packages give the first verdict in
the time the first run takes. One result object each.

**`-SourceRoot` must be a directory, and now says so at the source** rather than surfacing later as
a sandbox error naming a temp directory the reader has never seen. Pipeline binding makes it easy
to hit: piping FILES binds `-ConfigFile` by value **and** `-SourceRoot` from the same object''s
`FullName`, pointing the root at the config file.

**Gate a pull request on what it changed, with `-ChangedFile`.**

```powershell
$changed = git diff --name-only origin/main...HEAD
exit (Invoke-PSMutation -ConfigFile ./c.json -ChangedFile $changed).ExitCode
```

`mutate` is intersected with what changed, so a run costs a fraction of a full one and answers the
question a reviewer has: are the lines this PR introduced tested well enough? A whole-repo score
cannot answer that, and a whole-repo score is what makes people turn the gate off.

**You compute the diff** -- there is deliberately no `-ChangedSince <ref>`. It needs a base, and
every way that goes wrong goes wrong in *your* environment: a shallow clone where the ref was never
fetched, a detached HEAD, a merge base that is not the one the reviewer sees. An **empty list is
refused**, because `git diff` against an unfetched ref prints nothing and exits 0 -- a green gate
over zero mutants. A list holding files that are simply not in `mutate` is an ordinary documentation
change: it passes and says so, even under a break threshold.

The score is real but not the project''s, so the report goes to `<report>.changed.json`, `mode` is
`Changed`, and the schema **requires** `changedFiles` beside the score. It cannot combine with
`-RecheckFrom`, `-UpdateBaseline` or `-MergeIntoBaseline` -- folding a scoped run''s survivors into a
whole-project baseline would record "no survivors" for every file it never looked at. `-ListOnly` is
allowed. Restricting mutants to changed *lines* is not implemented.

**Preview what a config would mutate, with `-ListOnly`.** Per file, per operator, and how many
candidates survive `coveredLinesOnly`, then it stops -- nothing evaluated, no report written.

It exists for the **vacuous 100%**: a file that produces no candidates is still listed in
`mutate`, hashed into the report, contributes 0 of 0, and in a blended score is invisible --
two files in a real repository were in that state. It names them, and separately the files
whose candidates coverage removed entirely: two faults, two different fixes.
`FilesWithNoCandidate` and `FilesEmptiedByCoverage` travel on the result so a repository can
fail its own build on either. `ExitCode` is always 0 -- a preview has no verdict.

**A committed list of accepted survivors, so the gate is adoptable on code already red.** Point
`survivorBaseline` at a path; its presence enables the gate and `-UpdateBaseline` writes it.

```json
{ "mutate": ["src/a.ps1"], "survivorBaseline": ".psmutant-survivors.json" }
```

A survivor **not** in the list fails the run. So does a listed one that has been **fixed** (leave it
and the mutant can start surviving again with nothing failing), one whose **file has left `mutate`**
(dropping a file hides its survivors), and one that is **also** declared equivalent.

This is **debt, not equivalence**. `equivalents` means *this mutant cannot be killed* and carries a
written argument the gate checks; a baseline entry means *this mutant is not killed yet* and is
generated. Without the second, recording debt meant overstating it as equivalence, which corrupts
the one list whose entries are claims somebody made.

A set of mutants rather than a per-file score: a score is a ratio whose denominator moves with the
source, and against a file baselined at 90% three of four ordinary edits fail the ratchet. PHPStan
and Psalm baseline specific findings for the same reason. Entries are keyed by file, function and
change, so one survives a line moving. `-UpdateBaseline` writes **even on a failing run**, which
adoption needs; the next run still compares against what was recorded.

**`-MergeIntoBaseline` folds a recheck''s verdicts back into the report it came from**, instead of a
full run purely to refresh a baseline the rechecks already made stale. Each re-evaluated mutant
takes its new verdict, everything else keeps its status, and the report is **re-scored** -- new
verdicts under the old number is a self-contradictory document.

**It refuses rather than merging when the carried-over statuses may be stale.** A merge is sound
only for additive test changes: adding a test cannot revive a mutant the baseline killed, editing or
deleting one can, and a recheck never looks at it. Reports record each mapped test file''s size, and
the merge refuses when one **shrank** or disappeared. Length rather than a hash: hash equality asks
"unchanged", which would refuse the very loop this serves. Growth **permits** the merge rather than
certifying it, and the merged report records `mergedFrom` and `carriedOverUnverified`.

**A recheck refuses a report that describes a different run.** The compatibility gate walked the
files *this* run mutates, so a file the **report** covers and the run does not was invisible --
measured, a config mutating `a.ps1` accepted a report over `a.ps1` and `b.ps1` with zero reasons,
then would report "N of M previous survivors now killed" over a set it never had.

**A recheck no longer pays for coverage instrumentation it cannot use.** It evaluates the mutants a
prior report listed, matched on `(File, Id)`, and ids are assigned over the *unfiltered* candidate
set -- so an unfiltered selection is a superset whose extra members no report lists, and the
intersection is identical. Measured interleaved: the baseline is **13.2s without the tracer against
16.4s with, +24%**. The green-gate baseline stays; a recheck against a red suite would mean nothing.

**A run that stops running now stops, instead of looking like a slow one.** Every mutant was bounded
and the run was not -- observed, a run suspended overnight at 875 minutes of wall clock against 333
seconds of CPU. Two bounds, checked **between** mutants: a **stalled mutant**, waited on for exactly
its budget so far past it means the thing that should have stopped it never fired, and a
**whole-run budget** as backstop. `runTimeoutSeconds` overrides it, **0 disables it**, and both stop
by throwing so the partial report is still written.

**An interrupted run writes a partial report instead of nothing.** Ctrl-C, a cancelled CI job or a
killed agent used to discard everything. It is marked `"mode": "Partial"` with `evaluated` and
`planned`, and is **counts, never a score**: the loop evaluates in candidate order, so it has seen
whichever files sort earliest, not a sample of anything.

**The report and the console break the score down per file.** A blend is an average, so a strong
file carries a weak one and the gate passes on a number nobody would accept per file -- observed on
a real consumer at ~89% blended while files ranged from 39.6% to 100%.

```
  2 of 3 file(s) score below 85%:
      39.6%  src/weak.ps1  (19 killed / 48)
        78%  src/middling.ps1  (39 killed / 50)
```

`perFile` carries each file''s score with its counts, weakest first. The console prints only files
below the good band, and nothing when one file was mutated or every file clears it.

**The report says which tests killed each mutant.** Every row carries `KilledBy`, **truncated** by
default -- a mutant''s suite stops at the first failure, since once one test has noticed the rest
cannot change the verdict. Truncated is not "exactly one": over 118 killed mutants the default still
reported several killers for 20. Read `killersComplete`. **`recordAllKillers: true`** records every
killer at the cost of the early stop (50s becomes 73s for identical verdicts), and adds
**`testsWithoutKills`** -- absent by default, because under the early stop a test that would have
killed but was skipped looks exactly like one that cannot.

**`-Verbose` now tells you something, and progress goes to the stream built for it.** Everything the
module said went to the run result or the host, so `-Verbose` produced nothing. A run now traces its
**resolutions**: the sandbox, the subtrees copied, the files that resolved into the mutate set, the
Pester found, and which covering suite each file mapped to. `-Verbose` and `-Quiet` are
**independent**, so `-Quiet -Verbose` gives the trace without the per-mutant chatter. Per-mutant
progress also goes through `Write-Progress`, which no caller collecting output swallows.

**`schemaVersion` is now 2, and the report discloses more of what its score does not cover.**

- `filesWithNoCandidate` -- files in `mutate` no operator matched, which score a vacuous 100%.
  **Required** on a scored report, which is what the version bump is for.

`schemas/v2/report.schema.json` ships beside the module, and `schemas/v1/` still ships: an archived
report says `schemaVersion: 1` and only that schema can validate it. The rule for the number is
stated correctly now -- it moves when a field changes **meaning**, **disappears** or **becomes
required**, never when an optional one is added.

**Per-file paths in the report are repo-relative again.** `filesWithNoMutants` and the uncovered
caveat carried absolute paths under a temp sandbox whose name changes every run, which no consumer
can match against a checkout and which is deleted before a reader sees it.

**Fixed: the `-ListOnly` result promised arrays and delivered `$null`** for
`FilesWithNoCandidate` and `FilesEmptiedByCoverage` on a clean run. The report was unaffected.

**A schema failure on a scored report names the field that is actually missing.** The full/recheck
split was keyed on the presence of `mode`, so a report missing one disclosure failed the `else` arm
while the validator reported the `if` arm''s requirement -- naming `mode`, the one field whose
presence would make it a different kind of report. The discriminator is keyed on `mutationScore`.'
        }
    }
}
