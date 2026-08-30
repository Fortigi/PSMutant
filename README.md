# PSMutant

**Mutation testing for PowerShell.** The metric that proves a test would *catch a bug*,
not merely *run the line*.

Line/branch coverage only tells you a line executed. PSMutant injects small faults
("mutants") into your scripts — flip `-eq` to `-ne`, `$true` to `$false`, `5` to `6`,
drop a `-not` — and checks whether your Pester suite **fails**. The percentage it catches
is your **mutation score**: the share of injected bugs your tests would actually stop.

It's built on PowerShell's own AST (no Python, no external parser — StrykerJS is JS-only),
and every mutant runs inside a **throwaway sandbox**, so your source is never modified,
even if a run is interrupted.

> To our knowledge, PSMutant is the first mutation-testing module on the PowerShell Gallery.

## Install

```powershell
Install-Module PSMutant -Scope CurrentUser
```

Requires PowerShell 7.0+ and Pester 5.2+. Both floors are executed by a CI gate rather than
declared -- one leg per supported minor of each. On PowerShell 7.0 to 7.3 use Pester 5.x:
Pester 6 fails there with `Unable to find type [PesterConfiguration]`, which is Pester's
constraint rather than this module's.

**PSMutant does not import a Pester for you, and does not declare one as a required module.**
It runs under whichever Pester >= 5.2.0 your session already has, and only imports one if none
is loaded at all. That is what makes the >= 5 promise real: a manifest dependency is a
*minimum* that PowerShell satisfies with the newest version installed, so declaring one would
mean choosing your Pester before you got a say. The trade is that `Install-Module PSMutant`
will not install Pester for you -- `Install-Module Pester -MinimumVersion 5.2.0` if you need
it, which is also what the error message says.

## Use

Create a config pointing at the pure modules you want to test and the Pester files that
cover them (see [`examples/psmutant.config.json`](examples/psmutant.config.json)):

```json
{
  "mutate": ["src/MyModule.Transform.ps1"],
  "tests":  { "src/MyModule.Transform.ps1": ["tests/Transform.Tests.ps1"] },
  "coveredLinesOnly": true,
  "thresholds": { "high": 85, "low": 70, "break": null },
  "reportPath": "reports/ps-mutation.json"
}
```

Run it from your repo root:

```powershell
Import-Module PSMutant
$result = Invoke-PSMutation -ConfigFile ./psmutant.config.json
"$($result.Score)% ($($result.Killed)/$($result.Total))"
exit $result.ExitCode        # 0 unless thresholds.break is unmet, or a declaration went stale
                            # $result.FailureReason says which: None | StaleEquivalents | BelowThreshold
```

Survivors are printed with `file:line` and the exact source→mutant change — each is a
missing assertion, an equivalent mutant (a change that can't alter behaviour), or dead code.

### Seeing what a config would mutate, before it costs you minutes

```powershell
Invoke-PSMutation -ConfigFile ./psmutant.config.json -ListOnly
```

Prints the mutant set — per file, per operator, and how many candidates survive the
`coveredLinesOnly` filter — and stops. Nothing is evaluated, no report is written, no score is
produced. It is the answer to "what would this actually do?", which is the question you have
exactly when you are least sure: adding a file to `mutate`, changing `operators`, or wondering
why a file scores 100%.

That last one is the reason it exists. **A file that produces no candidates scores a vacuous
100%** — it is listed in `mutate`, hashed into the report, contributes 0 of 0, and in a blended
score is invisible. Two files in a real repository were in that state and it took a dedicated
investigation to notice. `-ListOnly` names them, along with the files whose candidates the
coverage filter removed entirely. Different faults with different fixes, so they are listed
apart: one is a test to write, the other is a file that does not belong in `mutate`.

```
     34 src/Transform.ps1 -> 31 covered
     19     ConditionForcing -> 18
     11     BinaryOperator -> 10
      4     ReturnValue -> 3
      0 src/Constants.ps1

  31 mutant(s) over 2 file(s) would be evaluated.
  1 file(s) produced NO candidate, so each scores a vacuous 100%: src/Constants.ps1
```

The result object carries both sets by name — `FilesWithNoCandidate` and
`FilesEmptiedByCoverage` — so a repository that considers either one a mistake can fail its own
build on it. The module does not: a file with nothing to mutate is not always an error, and a
preview that evaluated nothing has no business issuing a verdict. `ExitCode` is always 0.

Cost: one baseline suite run, because `coveredLinesOnly` is part of what would actually be
mutated and a preview that skipped it would answer a different question than the run does. Never
the mutants x suite that a run pays.

### Rechecking survivors while you write assertions

Killing survivors is an edit-run-edit loop, and re-running the mutants you already killed
is most of the wait. `-RecheckFrom` runs **only** the mutants a previous report recorded as
survivors, minus any you have declared equivalent — the config already states in writing that
no test can kill those, so re-evaluating them is guaranteed-wasted work.

**A recheck report can seed the next recheck**, so the loop gets shorter every round rather
than starting over from the full set:

```powershell
Invoke-PSMutation -ConfigFile ./c.json                                        # full: 127 mutants
# ...add assertions...
Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.json          # 56
# ...add more, killing 20...
Invoke-PSMutation -ConfigFile ./c.json -RecheckFrom ./reports/ps-mutation.recheck.json  # 36
```

Each round overwrites that one `*.recheck.json` scratch report. The full report is never
touched, whichever report you chain from.

Two things it deliberately will not do:

- **It produces no score.** Killing 6 of 10 survivors is not 60% of anything — the
  denominator is a filtered set. The result object and the `*.recheck.json` report carry
  counts (`NowKilled`, `StillSurviving`), never a percentage, and thresholds are not
  applied. The recheck report is written beside the full one, so a partial run can never
  overwrite the baseline that CI reads.
- **It will not guess.** Mutants are matched by `(file, id)`, and the id is an AST-walk
  position — it only means anything for byte-identical source and the same operator set.
  Reports therefore record a SHA256 per mutated file plus the operator list, and a recheck
  whose source or operators moved *refuses to run* rather than confidently rechecking the
  wrong mutants.

Finish with a full run before trusting a number or raising `thresholds.break`. A recheck is
sound only for **additive** test changes: editing or deleting an existing test can revive a
mutant that was killed before, and a recheck never evaluates those.

### Declaring equivalent mutants

Some mutants provably cannot change behaviour — `ConvertTo-Json -Depth 6` versus `-Depth 7`
on data four levels deep, for instance. No test can kill them, and chasing them produces
fixtures that assert nothing. Declare them, with a reason:

```json
"equivalents": {
  "src/Report.ps1:55:6 -> 7": "Depth N and N+1 emit identical JSON for any graph shallower than N; this report nests 4 deep at worst."
}
```

The key is `file:line:description`, exactly as printed in the survivor list. A declared
mutant leaves the denominator, so `thresholds.break: 100` becomes a meaningful gate:
*every catchable fault is caught*.

The declaration is a **claim that gets checked**, not a mute button:

- A blank reason is ignored — the mutant stays in the score.
- If a declared mutant is ever **killed**, the run fails: the config asserted no test could
  catch it, and one did.
- If a declared mutant **no longer exists**, the run fails: the code moved and nobody
  revisited the claim.
- Both fail **regardless of `thresholds.break`**, including report-only mode — a stale
  declaration is not a low score, it is a false statement inflating whatever score is printed.

The number of exclusions is printed next to the score and stored as `declaredEquivalent`, so
a 100% resting on a dozen declarations can never be mistaken for one that killed everything.

## How it works

1. **Baseline** — runs your tests once (must be green) with Pester code coverage over the
   `mutate` files, recording which lines actually executed.
2. **Enumerate** — parses each file's AST and collects candidates; only those on covered
   lines are kept (an uncovered mutant is guaranteed to survive and teaches nothing).
3. **Evaluate** — copies the source subtrees into a temp **sandbox**, splices each mutant
   into the copy, runs the covering tests in-process, and restores the copy. Tracked source
   is never touched. The sandbox is created under a name carrying 128 bits of randomness, and
   a path that already exists is refused rather than cleared: temp is world-writable on a
   shared machine, and a predictable name is one another local user can occupy first.
4. **Score** — `killed / total`, written to the JSON report. A mutant that hits the
   per-mutant timeout counts toward `killed`, because a mutant that hangs your suite is a
   fault -- but it is also reported on its own as `timedOut`, in the JSON and on the
   summary line. "The suite proved this fault is caught" and "the suite hung and we
   assumed so" are different claims, and a rising `timedOut` means your timeout is too
   tight or a covering suite too slow, not that your tests got better.

A **loop-condition guard** drops any candidate inside a `while`/`for`/`do` condition, so a
flipped comparison can never spin an infinite loop — which is what makes in-process
execution safe and fast.

## Operators

| Name | Mutation |
|---|---|
| `BinaryOperator` | `-eq`↔`-ne`, `-gt`↔`-le`, `-lt`↔`-ge`, `-and`↔`-or`, `+`↔`-`, `*`↔`/` |
| `BooleanLiteral` | `$true`↔`$false` |
| `NumberLiteral` | `N` → `N+1` |
| `NegationRemoval` | `-not X` → `X`, `!X` → `X` |
| `StringLiteral` | quoted string → `''` (opt-in — high-volume/low-signal) |
| `ConditionalBoundary` | `-gt`↔`-ge`, `-lt`↔`-le` (opt-in — off-by-one at a boundary, which the swaps above cannot produce) |
| `ConditionForcing` | an `if`/`elseif` condition → `$true` and → `$false` (opt-in) |
| `ReturnValue` | `return <expr>` → `return $null` (opt-in) |

The last three reach decisions that live in **structure** rather than in an expression.
A phase guard like `if ($SyncUsers) { ... }`, or a fallback chain of
`if ($Ref.Value) { return ... }`, holds no comparison, no literal and no negation — so
every default operator emits nothing and the file scores a **vacuous 100%** over code
nothing has tested. `ConditionForcing` asks the only question that matters about such a
guard: does any test notice which way the decision went?

They are opt-in because switching one on roughly doubles the mutant count and lowers the
score, so a repo gating on `thresholds.break` would go red purely from upgrading. Turn
them on deliberately, and expect to move the threshold down before moving it back up.
Adding an operator also renumbers mutants, so any existing report can no longer seed a
`-RecheckFrom` run — the operator set is recorded in the report and the mismatch is
refused rather than guessed at.

## Config reference

The format is defined by **[`schemas/v1/config.schema.json`](schemas/v1/config.schema.json)**, which
ships with the module. Naming it in the config makes the file self-describing -- a mistake
surfaces while you are writing the config, rather than several minutes into a run:

```json
{
  "$schema": "https://raw.githubusercontent.com/Fortigi/PSMutant/main/schemas/v1/config.schema.json",
  "mutate": ["src/MyModule.ps1"],
  "tests": { "src/MyModule.ps1": ["tests/MyModule.Tests.ps1"] }
}
```

**The module validates against this same file when it runs**, so nothing depends on the
config having been checked first — the schema is the format, not a description of it. It
refuses rather than warns: a warning in a CI log is indistinguishable from silence, and every
mistake in this class makes the gate *weaker* while the build stays green.

That matters because both of PowerShell's coercions fail **open**. `"timeoutFactor": "four"`
would otherwise leave the per-mutant timeout empty, and a timeout expiry counts as a *kill* —
a run reporting a number it never measured. `"coveredLinesOnly": "no"` would mean yes.

An unknown key is still answered with the nearest valid name (`Did you mean 'break'?`), and a
missing `mutate` or `tests` with what the key is for, because those are the two answers a
schema cannot give.

| Key | Meaning |
|---|---|
| `mutate` | Files to mutate. Pure / I/O-free logic pays off most. **Required.** |
| `tests` | Map each mutate file → the Pester file(s) covering it (per-file test scoping). **Required.** Every key must be a file listed in `mutate`; one that is not is refused, because it covers nothing while its tests still join the baseline. Comments (`_`-prefixed keys) go at the top level, not inside this map. |
| `operators` | Operator classes to inject. Default is the four expression operators; `StringLiteral`, `ConditionalBoundary`, `ConditionForcing` and `ReturnValue` are opt-in. |
| `coveredLinesOnly` | Restrict mutants to lines the baseline executed (default `true`). |
| `sandboxSubtrees` | Directories copied into the sandbox (default `["src","tests"]`; set to your layout). |
| `timeoutFactor` / `timeoutFloorSeconds` | Per-mutant timeout = `max(floor, baseline × factor)` (defaults 4 / 15). A non-terminating mutant is cut off and counted Killed, so the run never hangs. |
| `equivalents` | `file:function:description` → reason, for mutants that provably cannot change behaviour. Excluded from the denominator. The run fails if a declaration is killed, matches nothing, **or matches more than one mutant** — a declaration argues about one mutant, so matching several is ambiguous rather than a broader claim. `description` is `<original> -> <mutated>`, taken from the source. `file:line:description` is still accepted, and is the only form available for code outside any function; prefer the function form, because a line number moves whenever anything above it is edited. |
| `thresholds.high` / `thresholds.low` | Colour bands for the console score: green at or above `high`, yellow at or above `low`, red below (defaults 85 / 70). They affect the printed colour only, never the exit code. |
| `thresholds.break` | `null` = report-only. A number fails the run (`ExitCode 1`) below it. |
| `reportPath` | Where the JSON report is written (relative to `-SourceRoot`). A `-RecheckFrom` run writes `<name>.recheck.json` beside it and never touches this file. |

**Unrecognised keys are an error, not a warning.** A misspelling used to resolve to `null`
and quietly weaken the run: `thresholds.brake` left the break gate unable to fail, and a
misspelled operator name was dropped while still being recorded in the report as though it
had been applied. The run now stops and names the key, with the nearest valid one where
there is one. Keys starting with `_` are ignored, so you can use them for comments — JSON
has none of its own.

Every report also carries how it was produced:

```json
"schemaVersion": 1,
"producedBy": { "module": "PSMutant", "version": "0.3.0" },
"generatedAt": "2026-08-20T14:05:09Z",
"durations": { "baselineSeconds": 12.4, "totalSeconds": 354.1, "perMutantTimeoutSeconds": 50 }
```

`schemaVersion` is there so a consumer can branch on a number instead of guessing from which
keys are present. It changes when a field changes meaning or disappears, not when one is
added. `durations` makes a run comparable with the next one — the timeout sits beside the
baseline it was derived from, so a suite drifting toward its bound is visible before it
crosses.

A full report also discloses what its score does **not** answer for: `skippedAsUncovered`,
`filesWithNoMutants` (files whose candidates the coverage filter removed entirely) and
`filesWithNoCandidate` (files no operator matched at all). The last two are the two shapes of a
vacuous 100%, kept apart because the fixes differ, and they are what `-ListOnly` shows you
before a run rather than after one.

Reports also record `operators` and a `sourceHashes` map (SHA256 per mutated file). Those
exist so `-RecheckFrom` can prove the mutant ids in a report still refer to the same code.

The report format is defined by **[`schemas/v1/report.schema.json`](schemas/v1/report.schema.json)**,
which ships with the module, so a dashboard or a ratchet can validate a report without
reading this repo's tests:

```powershell
Test-Json -Json (Get-Content ./reports/ps-mutation.json -Raw) `
          -Schema (Get-Content ./schemas/v1/report.schema.json -Raw)
```

It covers both shapes — a full run, and the partial run `-RecheckFrom` writes, identified by
`"mode": "Recheck"`. A recheck may not carry `mutationScore` at all, so a partial number
cannot be mistaken for a real one even by a reader who ignores the `note`.

Validate the **file**, not a parsed object: PowerShell's `ConvertFrom-Json` recognises the
ISO-8601 `generatedAt` and hands back a `[datetime]`, so the string the schema describes is
already gone. Extra properties are permitted deliberately — `schemaVersion` changes when a
field changes meaning or disappears, never when one is added, so a validating reader keeps
working across releases that record more.

## What to point it at

Pure, deterministic logic where a subtle fault is a real bug: transforms, validators,
classifiers, SQL-fragment builders. Skip entry points that do live I/O on load — a mutant
there is unreachable without real infrastructure.

Treat the score like a ratchet: **directional**. Don't chase 100% — equivalent mutants and
untested log strings make the last stretch noise. Raise `thresholds.break` to lock in gains.

## Development

The test estate is written against **Pester 6.1.0** and CI pins that exact version. That
is a contributor requirement only -- the module itself still supports Pester 5+, and
`tools/Test-PSMutantPesterCompatibility.ps1` proves it on every CI run.

```powershell
Import-Module Pester -RequiredVersion 6.1.0 -Force                 # the pinned version
Invoke-Pester ./tests                                              # unit tests
./tools/Measure-PSMutantCoverage.ps1                               # coverage gate (100%)
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1   # lint
Test-PSComplexity ./src -Recurse                                   # complexity gate (needs PSComplexity)
Invoke-PSMutation -ConfigFile ./psmutant.self.config.json -SourceRoot .   # dogfood: PSMutant on itself
./tools/Test-PSMutantPesterCompatibility.ps1 -PesterVersion 5.8.0  # needs 5.8.0 installed too
```

### Quality gates (all required on `main`)

Every one of these runs in the CI `test` job and blocks the merge on failure:

- **Unit tests** — the suites under `tests/`.
- **Coverage** — 100% of `src/`, measured by `tools/Measure-PSMutantCoverage.ps1`.
- **PSScriptAnalyzer** — zero Error/Warning findings (`Write-Host` is the one allowed rule).
- **Complexity** — every unit must stay at or under **15 cyclomatic** and **15 cognitive**,
  measured by [**PSComplexity**](https://github.com/Fortigi/PSComplexity)
  (`Test-PSComplexity`) — a faithful cognitive metric, not a bundled approximation.
- **Self-mutation** — PSMutant mutation-tests itself; the score must stay above the
  `thresholds.break` floor in `psmutant.self.config.json`.

The two Fortigi modules dogfood each other: PSMutant gates its complexity with PSComplexity,
and PSComplexity gates its test quality with PSMutant. Separately, `code-scanning.yml`
uploads PSScriptAnalyzer findings to GitHub code scanning.

## License

MIT © Fortigi
