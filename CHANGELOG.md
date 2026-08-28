# Changelog

All notable changes to PSMutant are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

## [0.4.0] - 2026-08-26

> Renamed from an unreleased 0.3.3. That version was prepared but never tagged and never
> published -- the gallery went 0.3.2 straight to here -- so nothing pins it and nothing needs a
> 0.3.3 to exist. It became 0.4.0 rather than shipping twice when the run result gained fields.

### For consumers

**The Pester floor is 5.2.0, not 5.0.0, and it is now executed rather than declared.** The
manifest and README promised 5.0.0 and the gate ran exactly one version, so the number consumers
were given had never once been tried. Pointed at it, the module fails: PSMutant calls
`New-PesterConfiguration`, which **arrives in 5.2.0** -- measured across every installed version,
not looked up -- and the baseline cannot do without it, because code coverage cannot be configured
through the simple parameter set. Under 5.0.x and 5.1.x the command is not found, PowerShell
autoloads `Pester` by NAME to the newest installed, and that collides with the `Pester.dll` already
in the process.

If you are on 5.0.x or 5.1.x, PSMutant did not work for you before this release either; it now says
so instead of failing with an assembly-version error that never mentions this module. The gate runs
**one leg per minor** from 5.2.2 to 6.1.0, each in its own process, so the floor is proven rather
than asserted. Floor-plus-latest was considered and rejected: a defect arriving mid-range is
invisible at both ends, which is exactly the shape of this one.

**Several of these make a run that used to pass fail, and one makes a score go down. In every case
the new answer is the honest one.**

**SECURITY -- the mutation sandbox no longer uses a predictable path.** It was
`$TMPDIR/psmut-sandbox-<pid>`, and creating it began by removing whatever was already there. On a
shared machine another local user can create that path first as a symlink to a directory they own:
your `Remove-Item` of THEIR entry fails on the sticky bit, the failure is non-terminating, the run
carries on, and your source is copied through the link. Reproduced with two real users on a current
kernel -- `fs.protected_symlinks` does not help, because it guards only the FINAL path component and
the planted link is an intermediate one. The sandbox is where your tests run from, so whoever
controls it can substitute a file between the copy and the run.

Sandboxes now carry 128 bits from a cryptographic RNG, an existing path is **refused rather than
cleared**, and what was created is checked to be a plain directory. The stale sweep still reclaims
old-style names, and now skips symlinks instead of deleting through them. One residual, stated
rather than left to be found: the sandbox is world-READABLE while a run lasts, because it is created
with your umask. Closing that needs `File.SetUnixFileMode`, which is .NET 7 and above this module's
floor. The unguessable name closes the write-through attack; a reader must still find the name.

**A mutant that ran out of time is no longer counted as a kill.** A timeout scored exactly like a
test noticing the change, so a suite too slow for its budget reported mutants as caught that nothing
had caught. Timeouts are their own outcome now, reported separately. If your score drops after
upgrading it did not get worse -- it stopped counting the clock as a test.

**Runs are about three times faster, and no score moves.** A fresh runspace was created and Pester
imported into it for every mutant -- about 396 ms each, 219 s of an 801 s run spent re-importing a
module that does not change. It is now built once and reused. And a mutant asks one question, does
ANY test notice, so the covering suite stops at the first failure: a killed mutant's 2.03 s suite
finishes in 0.34 s, while a survivor is unaffected by construction. Measured end to end on a real
consumer repository, interleaved: **221 s -> 71 s** over 225 mutants, 225 killed, score 100 on both
sides, every per-mutant verdict identical.

The fail-fast half needs `SkipRemainingOnFailure`, which arrived in **Pester 5.3.0**, and is set
only when the loaded Pester has it -- so 5.2.x simply misses that part of the speedup.

**`ConditionForcing` now reaches the ternary operator and every `switch` clause, `default`
included.** It looked for one node type, `IfStatementAst`, so `$x = $cond ? $a : $b` was invisible
to it and to every other operator: a ternary compiles to no if-node, and a bare-variable condition
offers no comparison, literal or negation to touch.

A clause is forced to a SCRIPT BLOCK, not a bare value -- PowerShell matches with `$_ -eq <clause>`,
so `1` forced to `$true` merely changes what is compared. `1 { "one" }` becomes `{ $true } { "one" }`,
which always matches and shadows every later clause, or `{ $false } { "one" }`, which makes it dead.
Shadowing is the fault worth catching: a clause that swallows the ones below it is a real bug no
expression operator reaches. `default` is the one switch decision not on the AST -- only its BODY is
-- but the keyword is an ordinary token, so forcing it yields a switch whose fallback is dead. On a
235-file consumer the operator goes from **4404** candidates to **4548**.

**An absolute `reportPath` is honoured instead of being rewritten.** `Join-Path` concatenates rather
than letting a rooted right-hand side win, so `/var/artifacts/report.json` became
`<SourceRoot>/var/artifacts/report.json` -- written somewhere you did not ask for, with no error,
inside the tree this module otherwise never writes to. A CI step pointing at an artifacts directory
outside the checkout found nothing to upload. Relative paths still resolve against `-SourceRoot`,
`../shared/report.json` still climbs above it, and `recheckPath` is fixed with it.

**The run result now says WHY it failed.** `ExitCode 1` meant either a score under
`thresholds.break` or a stale equivalence declaration, and nothing said which -- so a run scoring
100% with one stale declaration failed with whatever reason your workflow had hardcoded. The result
carries `FailureReason` (`None` / `StaleEquivalents` / `BelowThreshold`), the stale list and the
declared-equivalent count. Nothing existing changed meaning.

**A recheck result now carries `ExitCode` and `Mode` too, and this fixes a live bug.** The two
shapes shared no field, so `if ($result.ExitCode -ne 0) { throw }` -- the idiom this README taught
-- compared `$null` against `0` and threw on a successful recheck, while `exit $result.ExitCode`
became `exit $null`, which is `0`, and passed even when every prior survivor was still alive. A
recheck `ExitCode` is always `0`; `StillSurviving` is the number to read.

**The report no longer publishes `"filesWithoutTestMapping": [null]`** -- an array holding one
`null` where the honest answer is `[]`. It was the DEFAULT path, so most reports carried it, and a
consumer listing the files that fell back to the whole suite got an entry that is not a file. All
three list fields now share one normaliser, and `filesWithNoMutants`, `filesWithoutTestMapping` and
`skippedAsUncovered` are **declared in the report schema** for the first time and required on a full
run -- their absence is why nothing caught this, since undeclared fields validate cleanly by design.

**The coverage XML no longer piles up in your temp directory.** The baseline wrote Pester's coverage
report to `$TMPDIR/psmut-coverage-<pid>.xml` and nothing deleted it: the startup sweep matched
*directories* named `psmut-sandbox-*`, so it could not match that file by construction. 67 had
accumulated on the machine this was found on. It now goes inside the sandbox, which is already
removed when the run ends, and the sweep reclaims what older versions left behind.

**A report that cannot be written now fails the run.** Writing the JSON failed non-terminatingly, so
an unwritable path left the run reporting success with no artefact behind it. That is the shape of
failure this tool exists to find, and it was in the tool.

**A number now answers for what was left out of it.** Candidates dropped by the covered-lines filter
are recorded beside the score, so a figure computed over less code than you asked for says so.

**A `tests` key that names no file in `mutate` is refused.** It covered no mutant, its test files
still joined the baseline's set, and the file it was meant to name had no entry -- so all of that
file's mutants fell back to running your whole suite. A typo made runs far slower while the score
stayed believable. `_`-prefixed comments belong at the top level, not inside `tests`.

**Three more config mistakes are refused instead of quietly changing what runs.** A file listed
twice in `mutate` doubled its mutants and its weight in the score. A `mutate` file with no `tests`
entry silently ran your whole suite per mutant. And a path escaping the source root was mutated
where it lives rather than in the sandbox -- interrupt such a run and the mutated file stayed on
disk. Paths merely containing `..` that still resolve inside, like `src/../src/a.ps1`, keep working.

**Under GitHub Actions, survivors now appear on the pull request diff.** One warning per survivor,
against its file and line, so a failing gate says what survived rather than only what it scored.
Nothing is emitted outside a recognised CI.

### Added

- **`FailureReason`, `StaleEquivalents`, `DeclaredEquivalent` and `Mode` on the full-run result;
  `ExitCode`, `FailureReason` and `Mode` on the recheck result.** The exit code is now derived from
  the reason rather than deciding the same rules a second time, so the two cannot disagree about one
  run. `ci.yml` reads the reason instead of assuming one.

- **Survivors land on the pull request diff instead of in job-log scrollback.** Under GitHub
  Actions the run now emits a `::warning file=...,line=...` per survivor, so the finding appears
  next to the code that needs the assertion. Both the full run and `-RecheckFrom` do it.

  They are emitted even under `-Quiet`, which is the point rather than an oversight: `-Quiet`
  exists so a CI log is not several hundred progress lines long, and CI is exactly where a
  survivor most needs to be visible -- suppressing both left a failed gate printing a score and
  nothing else. The annotations are built from the mutant row the line already carries, not by
  parsing the console text, and nothing is emitted outside a recognised CI.

  The suite is CI-neutral by construction: the files that start real mutation runs clear the
  variable and restore it, and the annotation path is tested by mocking the host check rather
  than by setting an environment variable. Otherwise this project's own fixtures decorate every
  pull request with warnings pointing at files that do not exist in the repository.

### Fixed

- **`Get-Help Invoke-PSMutation -Full` no longer points at a help topic that does not exist.** It
  said "see about_PSMutant / the README", and there is no `about_PSMutant` -- no `en-US` directory
  and no `*.help.txt` anywhere -- so a consumer installing from the gallery was sent somewhere that
  does not resolve. It now names `schemas/v1/config.schema.json`, which ships beside the module and
  is what the module validates against, so it cannot describe a config PSMutant would reject. A test
  now fails on any `about_` topic the package does not actually provide.

- **The `-Operators` help named one opt-in operator when there are four.** It read "StringLiteral
  off -- opt in explicitly", implying that was the only one, while `ConditionalBoundary`,
  `ConditionForcing` and `ReturnValue` are equally off by default -- and those three are what stop
  structural code scoring a vacuous 100%.

- **A `tests` key naming no `mutate` file is refused rather than accepted and misused.** Its values
  still joined `AllTests` -- the baseline's test set and the fallback covering suite -- while its
  entry covered nothing, and the file it was meant to name silently fell back to the whole suite per
  mutant. Checked in `Get-PSMutationSandboxPlan` on resolved paths, beside the duplicate-mutate
  check and for the same reason: two spellings of one path are only equal once resolved. The schema
  cannot express this -- a bare string is a legal single test file, so a comment key is schema-valid.

- **Running the analyzer by hand is now the same as passing it.**
  `tools/Invoke-PSMutantAnalyzer.ps1` returned its findings and exited 0 whether or not it found
  any, so `$?` was not a verdict and the gate was the `if` around it in `ci.yml`. A branch was
  reported analyzer-clean three times before CI failed it on both legs. It throws now, like
  `Measure-PSMutantCoverage.ps1` and `Test-PSMutantRelease.ps1` beside it -- two of the three
  committed gate scripts failed loudly and this one did not, which is the inconsistency that made
  the trap invisible. `-PassThru` returns the findings without failing, for `code-scanning.yml`,
  which uploads them rather than gating on them; the decision itself is `Get-PSMutantLintFault`
  in `GateDecisions.ps1`, with tests, like every other gate decision.

- **A file listed twice in `mutate` is refused instead of doubling the run.** Every mutant was
  generated and evaluated twice, so `total`, `killed` and `survived` in the report -- a published
  contract -- were all doubled, the run cost twice what it should, and `(File, Id)` stopped
  identifying one mutant, which is what `-RecheckFrom` matches on. Checked on the **resolved**
  paths, so `src/a.ps1` and `src/../src/a.ps1` are caught as the one file they are.

- **A `mutate` file with no `tests` entry now says so.** The fallback runs the whole suite for
  every one of that file's mutants -- correct, never less thorough, and measured at 74% slower on
  a four-mutant fixture. On a several-hundred-mutant run it is the difference between minutes and
  tens of minutes, and it was invisible: adding a file to `mutate` and forgetting its `tests`
  entry produced no error, no warning and no symptom other than a slow run. Named on the console
  before the loop starts, where it can still be acted on, and recorded as `filesWithoutTestMapping`
  in the report -- because the console line is suppressed by `-Quiet`, which is how CI runs it.


- **Config paths get a resolver, like every other config value.** Four failures shared one
  missing concept, and each used to fail in its own place with a message naming neither the key
  nor the cause. `reportPath` is documented optional and was mandatory in practice --
  `Join-Path $root $null` returns the root, so an omitted key surfaced as "unable to clear
  content ... because it is a directory" **after the whole run had finished**; it now has a
  documented default of `reports/ps-mutation.json`. A `..` in `sandboxSubtrees` copied from
  outside the source root into the sandbox and was never reclaimed by the sweep; it is refused.
  A `[`, `]`, `*` or `?` in any config path is a wildcard to PowerShell and to Pester's
  `Run.Path`, so `sr[c]` matched nothing and died far away; it is refused, naming the key and
  the character. And a path that never reached the sandbox -- what a consumer-shaped layout does
  when `sandboxSubtrees` still names this module's own -- was diagnosed as "Baseline suite is
  not green", an affirmatively false statement about a green suite; it is now caught **before**
  the baseline, naming the paths and the setting that decides them.


- **A score now answers for what the coverage filter removed.** Uncovered candidates are
  dropped per file before the run, silently, and that is the **default** path. A file added to
  `mutate` before its tests exist, or one a refactor stopped exercising, contributed nothing --
  and the score went **up** while the gate stayed green. In a three-file fixture, eight of ten
  candidates were removed and the run reported `100% (2 killed / 2)`, exit 0; the only trace
  was that `sourceHashes` listed three files while `mutants` listed one. The report now carries
  `skippedAsUncovered` and `filesWithNoMutants`, and the console prints
  `N mutant(s) skipped as uncovered (M file(s) contributed none: ...)` beside the score --
  named, not just counted. `declaredEquivalent` was already reported for exactly this reason;
  this filter removes far more.

- **An outcome PSMutant does not model is refused rather than scored.** Every mutant verdict
  came from one comparison over an open string channel -- whatever Pester's run result says,
  plus `TimedOut` minted into the same namespace -- and anything unrecognised fell through to
  `Killed`, toward the flattering answer, with no test failing. The collapse is correct for
  every shipping Pester, whose run-level result is two-valued; what was unguarded is a
  **widened** vocabulary rather than a renamed one. A rename fails loudly at the baseline,
  which compares against the literal `Passed` before any mutant runs; a third state coexisting
  with it would leave the baseline green while every mutant returning it scored as killed.


- **A report that cannot be written now fails the run instead of reporting success.** The
  directory creation and the write were both non-terminating, so an ordinary `reportPath`
  mistake -- one containing a `[`, an absolute path, a read-only directory, a file open in an
  editor -- printed `Report: <path>` for a file nothing had written and returned
  `Score=100, ExitCode=0`. A consumer's CI published an empty artifact over a green build. Both
  writers now go through one function that uses a literal path and stops on failure; a
  `reportPath` containing a bracket, which used to fail silently, now works.

- **A timed-out mutant is no longer counted as a plain kill.** `Invoke-PSBoundedPester` has
  always distinguished a timeout; the verdict was discarded one line later, so "the suite
  proved this fault is caught" and "the suite hung and we assumed so" became the same number.
  A covering suite that is merely too slow therefore inflated the score, and a genuinely
  non-terminating mutant -- often a loop whose termination nothing asserts -- disappeared into
  the kill count. Timeouts still score **with** the kills, so your number does not move, but
  they are now reported apart from them: `timedOut` in the JSON report, and
  `[N killed on the clock, not by a failing test]` on the summary line. A rising count means
  the timeout is too tight or a suite too slow, not that the tests got better.

### Security

- `publish.yml` no longer interpolates the tag name into a PowerShell script. An Actions
  expression is pasted into the script as text before pwsh parses it, so a tag name
  containing a quote closed the string literal and ran as code -- in the one job holding
  the gallery API key. git accepts `v1.0";$x;"` as a ref name, and pushing a tag requires
  no review while pushing to main does. The name now arrives through an environment
  variable, which is read at run time and stays data whatever it contains.

### Internal
- **A re-run of `Test-PSMutantRelease.ps1 -Apply` no longer corrupts the manifest** (#171). The
  value is escaped correctly on the way in -- each `'` doubled -- but the pattern that FOUND the
  value to replace did not understand that escaping. It was `'.*?'` guarded by a lookahead for a
  newline or a closing brace, which reads correctly until the stored value already contains a
  doubled quote: the second quote of an escaped pair, followed by ` }` or a line break, satisfies
  the lookahead, so the match ends INSIDE the old value, the new one is spliced in there, and the
  remainder is left behind as bare tokens. The manifest then fails to parse, and the error names a
  stray word rather than the cause.

  Any quoted phrase at the end of a line arms it -- `the mode is called 'strict'` is enough -- and
  it takes two `-Apply` runs and no other change to fire, because it is the value the FIRST write
  leaves behind that arms the second. Found while regenerating the notes for this release.

  The pattern is now the unrolled-loop spelling of a single-quoted PowerShell string,
  `'[^']*(?:''[^']*)*'`, which consumes an escaped quote as content, can only end at the real
  terminator, and backtracks linearly. Being exact it needs no lookahead at all.

  `Get-PSMutantRewrittenManifest` had **no tests**, which is how this shipped. It has five now,
  and three of them rewrite the manifest twice -- deliberately, because a single rewrite over a
  pristine manifest passes with the broken pattern too. Verified by reverting the fix: all three
  go red, and a one-shot version of the same tests stayed green.

- The script-block-only guard in `Get-PSMutationSwitchConditionCandidate` is gone, which makes the
  walker simpler rather than more complex: every clause is forced the same way. The reasoning that
  put the guard there -- that a value clause needed a syntax rewrite and new machinery -- was wrong,
  and was written into an issue before it was checked. It is now recorded in CLAUDE.md so the next
  reader does not have to re-derive it.
- **CLAUDE.md gains the practice that would have caught a three-push CI failure**: run the suite
  with `$ErrorActionPreference = 'Stop'`, because that is how the workflow steps run it and a
  developer shell defaults to `Continue`. Under `Stop` a dying `BeforeAll` becomes terminating, so
  Pester attaches the error to the container rather than the test and `$test.ErrorRecord` is empty
  -- a difference in control flow, not in formatting.
- **A failing baseline no longer prints a dangling `Some.Test -- .`** Three separate things were
  wrong in one line, and only the first was the one guessed at.

  `ErrorRecord` is a **collection**, not one record -- a test can fail for several reasons and
  Pester hands back a `List`. Reading `.Exception.Message` off the list works only by PowerShell's
  member enumeration, which yields the inner value for a one-element list and nothing for zero or
  many. It is now read as the collection it is.

  The **first non-empty** line is taken rather than simply the first, so a message that opens with
  a blank line is not reported as an empty reason.

  And when there is genuinely nothing to say, the test is named **alone**. That case is real: when
  a `BeforeAll` dies under `ErrorActionPreference = Stop` -- which is how CI runs the suite and how
  a developer machine usually does not -- Pester marks every test in the block Failed and attaches
  the error to the CONTAINER, so the test carries no error record at all. The container's record
  holds Pester's own break/continue guard text, which says nothing about the consumer's failure, so
  it is deliberately not reached for. `Some.Test -- ` reads as a reason that was lost; `Some.Test`
  reads as one that never existed, which is the truth.

  The behaviour predates this change -- `main` produces the same dangling output -- and was found
  by one of the new consumer-shaped fixtures going red on both CI legs while passing locally.

- **The end-to-end counts are asserted exactly** (#36). They were open inequalities --
  `Total | Should-BeGreaterThan 0` -- over a fixture that is fully determined and produces the
  same three mutants on every run, so they could not tell 3 from 30 or from 1. That suite is the
  last line of defence against a run producing plausible-looking but wrong counts. The mutant SET
  is pinned too: three mutants of the wrong operator on the wrong lines sum to three just as well.
- **Two shared-state defects in the suite are closed** (#43). `Operators.Tests`' `guards` Context
  read `$script:returns` from its sibling Context and so could not run alone -- verified on main,
  a run filtered to `guards` failed on a `$null` unrelated to what it asserts. And `Runner.Tests`
  carried an assertion that could not fail: a local was declared, never assigned, then asserted
  null. Removing it exposed the real problem underneath -- `$script:seenTests` is written by a
  sibling test, so the surviving assertion could pass on the previous test's value with the mock
  never firing. Both tests now clear it first.
- **Two consumer-shaped fixtures** (#35), where every previous one had this module's own flat
  `src/` + `tests/` shape. A NESTED source tree, which is where the sandbox path mapping is
  actually exercised -- a flat layout has no separator in the relative part and cannot assert the
  display path comes back `src/Domain/Calc.ps1` with forward slashes. And a MODULE-SHAPED consumer
  whose test imports a manifest at the repo root, outside `sandboxSubtrees`.

  The second came out differently from what #35 assumed, which is why it was worth running rather
  than reasoning about: the issue expected a silent, vacuous score and proposed a new feature to
  detect it. Measured, the run already refuses loudly -- `Assert-PSMutationBaselineGreen` throws
  and names the failing test and its message. The tests pin a guard that was already right, and
  the proposed feature is not needed.

- `Invoke-PSMutationBaseline` takes `-SandboxRoot` and writes coverage there. Mandatory rather than
  defaulted to temp: the sandbox is the one directory a run owns and disposes of, and a default
  would put the file back in shared temp for any caller who forgot.
- `Get-PSMutationSandboxOwnerId` also reads the id out of a legacy `psmut-coverage-<pid>.xml` name,
  and the sweep now looks at files as well as directories. Both arms are transitional and say so:
  they exist to reclaim what earlier versions left, and can go once no machine plausibly still has
  any.

- `Get-PSMutationConditionCandidate` is now a dispatcher over three small walkers -- if, ternary,
  script-block switch clause -- sharing `New-PSMutationForcedCandidate` so the loop guard, the
  already-forced guard and the operator name cannot drift between them. The shared helper takes the
  two forced spellings rather than assuming `$true`/`$false`, because a switch clause is a script
  block and forcing it means `{ $true }`; comparing a script-block extent against a bare `$true`
  would never match and would emit an unkillable identical-source mutant.

- **The mutate file is read once per FILE, not twice per mutant** (#101). It was read in the loop
  to splice against and again inside `Invoke-PSMutant` to restore from -- the same unchanged bytes
  off disk twice, producing two strings equal by construction, for every one of a file's mutants
  (125 for the largest file in this repo's sibling). `Invoke-PSMutant` now takes the original text
  rather than fetching it.

  On Linux the four operations totalled about 0.16 ms per mutant, which is not where the time goes;
  #101 reports a far larger cost on Windows, which this removes either way. The reason it is worth
  doing regardless is that the cache is a **correctness** property: a loop that re-reads would
  splice the next mutant onto whatever is on disk, so a restore that did not happen -- a process
  killed between the write and the restore -- would stack mutants and produce a score describing
  code that never existed. A test pins that, because re-reading returns the same bytes and is
  otherwise invisible; the mutation gate said so.

  The per-mutant **restore** write is deliberately kept. It is redundant between two mutants of one
  file, since the next writes the whole file anyway, but it is what makes `Invoke-PSMutant`
  self-contained: a mutant that throws leaves the sandbox as it found it.

- **The mutant runspace is warm.** `Get-PSMutationWarmShell` builds one runspace with Pester in it
  and hands it to every mutant, rebuilding after a fixed number of uses and unconditionally after a
  timeout -- `Stop()` leaves a runspace unusable. Nothing about a mutant is cached: the covering
  suite dot-sources the file under test, so each run reads the spliced source afresh. The recycle
  interval bounds any state a suite leaves behind.
- `Get-PSMutationRunspaceError` moved from `PSMutation.Runner.ps1` to `PSMutation.Pester.ps1`, where
  the child-runspace contract lives. Leaving it made `Pester.ps1` call upward into `Runner.ps1` --
  a cycle `tests/Layering.Tests.ps1` caught on the first run, which coverage, the suite and the
  mutation gate would all have passed. Its tests moved with it, because a test in the wrong file
  covers a function while being unable to kill any of its mutants.
- The child script is now **parse-checked by a test** (part of #49): it is a here-string, so nothing
  lints the code every mutant runs, and a typo in it surfaces only at run time as "the covering
  tests produced no result".
- Two guards in `Close-PSMutationWarmRunspace` were collapsed into one. The shell and the runspace
  are always set together and cleared together, so two guards implied a state that cannot exist --
  and the mutation gate proved the cost: forcing either one false left the OTHER object disposed,
  so a test asking whether the shell still worked threw anyway and both mutants survived.

- **The sandbox path is now a security boundary.** `New-PSMutationSandbox` gained two guards with
  their own tests: `Assert-PSMutationSandboxPath` refuses an occupied path, and
  `Assert-PSMutationSandboxReal` refuses one that is not the plain directory just created. The
  second is tested directly, because through `New-PSMutationSandbox` it is reachable only in the
  race between the check and the create -- a window that is real, which is why the check is
  repeated, and not one a test can schedule.
- The test asserting that creation **wipes** an existing sandbox is replaced by one asserting it
  refuses. The wipe existed only because the name was per-process and therefore reused; it is also
  exactly what the attack rode on.
- The complexity gate now runs against PSComplexity **0.5.0**, up from 0.3.0.


- **The suite now has to give the same answer in a different order.** This project runs its own
  tests in two orders -- alphabetically by hand, in config order under the mutation baseline -- and
  nothing checked they agree, which is how one file's uncleaned `AfterEach` made the suite green
  locally and red in the gate for three rounds. A new gate runs the suite reversed and compares the
  environment before and after it. The reversed run catches such a dependency by its symptom; the
  environment comparison catches the cause, and is the half that fires on the file that leaks
  rather than the file that happens to read. Values are never printed -- a variable holds tokens as
  often as it holds flags.

- **Pinned dependencies are watched instead of only written down.** A weekly job checks each
  pinned module against the gallery and opens one tracking issue when any has moved on;
  Dependabot watches the action SHAs, which `pins.env` structurally cannot hold because `uses:`
  does not expand variables and a SHA cannot be read to learn whether something newer exists.
  An unreachable gallery is reported as **unknown** rather than as current, because a watcher
  that reads "could not look" as "nothing newer" has stopped being able to fail.

  `PESTER_COMPAT_VERSION` is judged on **difference, not freshness**: it is deliberately old,
  because the compatibility guard runs a real mutation under the Pester the suite does *not*
  use. Bumped to the newest it would equal the estate pin and prove nothing about the
  manifest's `>= 5.0.0` promise -- while looking more up to date than a pin that works.

- The orchestrator splats two clusters of run values rather than naming each at every call
  site: what a run **executes** with (candidates, timeout, sandbox, quiet) and what a report
  **documents** itself with (source hashes, operators, equivalents, report path). Three calls
  that needed line continuations now fit on one line each. `Provenance` stays explicit at both
  sites, because the recheck takes the scriptblock and the report takes its invoked result --
  a difference a shared key would hide.

## [0.3.2] - 2026-08-21

### Internal
- The complexity gate moves from PSComplexity 0.1.0 to **0.3.0**, two majors on. That release
  scores the flow constructs PowerShell actually has -- `ForEach-Object`, `Where-Object`, `&&`,
  `||`, `??` -- which previously counted as straight-line code, so 16 of this module's 78 units
  score higher than they did. Nothing breaches: the worst unit is cognitive 13 against a
  ceiling of 15.
- `Get-PSMutationScore` is a per-set fold again. It also answered a whole-run question --
  whether a declaration matched no mutant, or several -- which made that answer wrong for
  any subset: scoring one file's rows accused every declaration belonging to another file of
  being stale. The check moved to `Get-PSMutationDeclarationCoverageFault`, which takes every
  row, and `Write-PSMutationReport` merges the two. No output changes for a whole run.

### For consumers

**A per-mutant timeout that resolves too low is now refused instead of faking a perfect
score.** The budget is `max(timeoutFloorSeconds, baseline x timeoutFactor)`, and with a small
enough floor *and* factor it could resolve to zero. A zero-second budget expires immediately,
an expired mutant counts as a kill, and so every mutant was killed on the clock rather than on
behaviour -- 100%, exit 0, over tests that never ran. The budget must now be at least as long
as your unmutated suite took, and a config that asks for less fails with a message saying so.

If this affects you, your reported score was wrong in the flattering direction, and the run
that fails after upgrading is the honest one.

**A config path that escapes the source root is now refused.** Every path in a config is
copied into a temp sandbox and mutated there; a leading `..` survived that mapping, so a path
like `../shared/Util.ps1` was mutated **where it lives**, in your working tree. Interrupt such
a run and the mutated file stays on disk. Paths that merely contain `..` and still resolve
inside -- `src/../src/a.ps1` -- keep working.

### Fixed

- `Get-PSMutationTimeout` bounds the resolved budget below by the baseline duration rather
  than by zero, because a budget shorter than the suite times out every mutant by construction
  whatever the number is.
- `ConvertTo-PSMutationSandboxPath` checks where a mapped path landed, not whether the input
  contained `..`.

## [0.3.1] - 2026-08-21

### For consumers

**Breaking: the module now exports one function.** `Invoke-PSMutation` is the whole surface.
If you called `Get-PSMutationCandidate` or `Set-PSMutationText`, they are gone -- they were
never documented, and the object they returned was never a declared contract. What you should
depend on instead is the report JSON, which now has a published schema.

**Your config is checked more strictly, and mistakes are errors rather than silence.** A
misspelled key used to be ignored, which quietly weakened the run: `thresholds.brake` left the
break gate unable to fail at all, and a misspelled operator was dropped and then reported as
though it had run. A value of the wrong type did the same -- `"timeoutFactor": "four"` left the
per-mutant timeout empty, and an expired timeout counts as a kill, so the score was higher than
the tests earned. Both are refused now, and the message names the key and suggests the nearest
valid one.

If you have been running with a typo, this release will fail your config where it previously
ran. That is the point: the run it was giving you was not measuring what you thought.

**Both formats are published as JSON Schemas**, in `schemas/v1/`. Point your config at
`config.schema.json` with a `$schema` key and it can be checked before a run instead of minutes
into one. Validate a report against `report.schema.json` if you build anything on top of it --
a dashboard, a ratchet, a merge tool. Extra fields are allowed on purpose, so a validating
reader keeps working when a later release records more.

**Reports say how they were produced**: a schema version, the module version, a timestamp, and
how long the baseline, the whole run and the per-mutant timeout took.

**`-RecheckFrom` does less work.** It skips mutants your config already declared unkillable,
and a recheck report can now seed another recheck, so the loop narrows as you write assertions.

**`Get-Help Invoke-PSMutation` returns the real documentation** -- every parameter described,
with worked examples. It was previously serving an internal note by accident.

**Score colours are correct.** A config without colour bands used to print every score green,
including 0%.

### Fixed
- **The gallery page for a release was the maintainer changelog entry.** It opened mid-document
  at `### Changed`, ran to 9646 characters, and carried ten `[#nn]` references that are
  undefined in the notes and so rendered as literal text pointing at nothing. Its reader has no
  access to this repo's issue tracker, and the prose was an argument addressed to whoever wrote
  the code rather than to someone deciding whether to upgrade.

  Each version section now carries a `### For consumers` block, and that block is what the
  gallery gets. The rest of the entry stays as it is -- issue numbers, the argument behind a
  decision, and what a stated reason used to claim are all worth keeping for a maintainer, and
  none of them survive the trip to a package page.

  **A missing block fails the release.** Falling back to the full section is what published
  0.3.0, and a gallery page cannot be edited or withdrawn -- only unlisted, which is what
  happened to it. Refusing costs one paragraph before a release; the fallback cost a permanent
  page.

- **The release-notes limit is 10600, not the 35000 the first error reports.** The gallery
  enforces two: 35000 for a generic NuGet package, and 10600 when the notes are extracted from
  a PowerShell manifest. Only the first is mentioned when you exceed it, so bounding at 35000
  looks correct, publishes, and then fails on the second. Both numbers cost a release before
  the smaller one was believed.

## [0.3.0] - 2026-08-21

**Unlisted.** The code is identical to 0.3.1; the gallery page was the maintainer changelog
entry rather than notes written for a consumer. Use 0.3.1.

### Changed
- **The module exports one function.** `Get-PSMutationCandidate` and `Set-PSMutationText` are no
  longer public ([#48]). Between them they trafficked a nine-field `[pscustomobject]` that
  nothing declared, tested as a contract or versioned -- discoverable only by running the
  function and inspecting the output, and unchangeable once anybody had. Neither was mentioned
  anywhere in the README, and `Set-PSMutationText` had exactly one caller, inside this module.
  They were a leak, not an API.

  Un-exporting them did not dissolve that contract, it **relocated** it: the mutant rows in the
  report are a projection of the same internal object, so the report was always the real public
  surface. What a consumer can depend on is now exactly two things, both of which this module
  fully controls, and both now pinned by tests asserting the exact field list:
  - the object `Invoke-PSMutation` returns -- `Score`, `Killed`, `Survived`, `Total`, `ExitCode`
  - the report JSON, top level and mutant row

  The row assertion lives in `Runner.Tests.ps1`, where `Invoke-PSMutationLoop` actually builds
  it. Asserting it through `Write-PSMutationReport` would have tested the fixture instead, since
  that function serialises whatever it is handed.

  **`Id` is not contractual.** It is a walk position, it changed once already in [#29], and its
  only consumer is this project's own `-RecheckFrom`. Saying so is what frees the remaining
  identity work to pick a scheme on its merits.

  "What would you mutate?" remains a fair question, and the answer should be a rendering this
  module controls -- see [#10]'s `-ListOnly` -- rather than a re-export of the AST walker.
- **Both PSScriptAnalyzer gates now run one committed script**, `tools/Invoke-PSMutantAnalyzer.ps1`
  ([#76]). They each spelled the invocation out inline, sharing `PSSA_PATHS` and the settings file
  but **not the severity**: `ci.yml` filtered to `-Severity Error, Warning` and
  `code-scanning.yml` -- a **required** check -- passed no filter. Every Information-severity rule
  was therefore invisible to the gate that fails the build and visible to the gate that blocks the
  merge, so a finding in that band passed lint both locally and in CI and then surfaced as a code
  scanning alert where nobody was looking. It happened twice in one PR before the band was noticed
  at all.

  Dropping the filter would have fixed that instance; a shared script is what stops the class,
  and it is the rule this repo already had -- a gate is a committed script precisely so measuring
  by hand and measuring in CI cannot drift. There is no `-Severity` filter now: rules are excluded
  by name in `PSScriptAnalyzerSettings.psd1` with a reason, which is a decision someone made,
  where a severity filter mutes a whole band nobody decided about.

  The script reads `PSSA_PATHS` and `PSSA_VERSION` from `.github/pins.env` itself, so running it
  by hand needs no setup and cannot use a different analyzer than the gate. It **refuses to
  analyse nothing** -- an empty or misparsed path list would otherwise have both gates report
  clean over zero files, which is indistinguishable from success -- and the pin parsing behind
  that is `Get-PSMutantPinValue` in `tools/GateDecisions.ps1`, with tests, because a parser that
  quietly returns nothing is exactly how a gate stops being able to fail.
- **Mutant ids no longer depend on the order the config listed its operators in** ([#29]).
  Ids came from the order the operator list was iterated, while `Write-PSMutationReport`
  records that list **sorted** and `Test-PSMutationRecheckCompatible` compares it sorted. So
  swapping two entries in `"operators"` renumbered every mutant while the recorded set stayed
  byte-identical: the gate saw no change, accepted the report, and a `-RecheckFrom` run matched
  survivors by id against a different set of mutants. A formatter or an alphabetising editor
  plugin does that unprompted.

  Reproduced before fixing: with `["BinaryOperator","BooleanLiteral"]`, id 1 was `-eq -> -ne`
  at offset 51; with the two swapped, id 1 was `$true -> $false` at offset 67. That is the
  confident-wrong-answer case `PSMutation.Recheck.ps1` says it prevents, reachable by
  reordering a JSON array.

  Candidates are now sorted into a canonical order -- `StartOffset`, then `Operator`, then
  `Description` -- before ids are assigned, so an id means a position in the file. `Description`
  is part of the key because `ConditionForcing` emits both the `$true` and the `$false` forcing
  at one extent, so offset and operator together are not unique. The compatibility gate is
  unchanged and still compares the operator set sorted, which is now simply correct: a reorder
  no longer changes anything, so refusing one would be a nuisance rather than a guard.

  **Existing reports are invalidated once.** Ids for a given source and operator set change with
  this release, so a `-RecheckFrom` against a report written by an earlier version will match
  the wrong mutants. Run the full set once to regenerate.
- `Get-PSMutationCandidate` and `Get-PSMutantUnloadedFile` now cast their returned array to the
  type they declare, silencing two `PSUseOutputTypeCorrectly` findings. The first was introduced
  by the sort above; the second had been sitting in `tools/GateDecisions.ps1` unnoticed. Neither
  was visible to the lint gate, which filters to Error and Warning, while the **required**
  code-scanning check evaluates Information rules too -- an asymmetry now tracked as [#76].
  The cast goes on the *expression* with `@()` inside it: casting the variable leaves the
  analyzer inferring `System.Object[]` regardless, and dropping the `@()` turns an empty result
  into `$null` rather than an empty array, which four tests caught immediately.
- The invariant that mutant ids are assigned **before** the covered-lines filter is now stated
  at the numbering site and pinned by a test ([#59]). It was correct but undocumented, and it is
  what lets a recheck match survivors across a coverage change -- which matters because writing
  the assertions that kill survivors is exactly what widens coverage, and the compatibility gate
  deliberately does not inspect coverage. The plausible refactor is "do not number candidates you
  are about to discard": move the numbering into `Select-PSMutationCandidate` and a recheck
  starts answering confidently about the wrong mutants, with every gate still green. The test
  fails the moment that happens.
- **PSMutant no longer declares Pester in `RequiredModules`, and no longer imports one when
  you import PSMutant** ([#30]). `ModuleVersion` in `RequiredModules` is a *minimum*, and
  PowerShell satisfies it by importing the **newest installed** version -- at import time,
  before `Assert-PSMutationPester` or `Get-PSMutationPesterPath` can have a say. Every #16 fix
  operates one layer below the thing that had already chosen a Pester.

  Verified on a machine holding 6.1.0, 5.8.0, 5.7.1 and 3.4.0: a clean session went from no
  Pester to **6.1.0** purely by importing PSMutant. The consumer-visible symptom was worse than
  a wrong version -- `Import-Module PSMutant` followed by
  `Import-Module Pester -RequiredVersion 5.7.1` died on
  `Could not load file or assembly 'Pester, Version=5.7.1.0' ... Assembly with same name is
  already loaded`, cascaded into `Should operator 'Be' is not registered`, and left the caller
  on 6.1.0 anyway. The **same two lines in the other order worked fine**, because
  `RequiredModules` was then already satisfied. Order-dependent, with no diagnostic pointing at
  the cause.

  Pester is a **run-time** dependency, and `Assert-PSMutationPester` already enforces it: it
  accepts an already-loaded Pester >= 5, imports one only when none is loaded, and refuses with
  an actionable message otherwise. It is now the single point of enforcement, which is what
  makes the manifest's >= 5.0.0 promise something the module honours rather than pre-empts.

  **The trade, stated plainly:** `Install-Module PSMutant` will no longer install Pester for
  you. That is deliberate for a module whose whole promise is running under *your* Pester, and
  the dependency stays documented in the manifest description, the README and the error
  message. Run `Install-Module Pester -MinimumVersion 5.0.0` if you do not already have it.

- **A config key the module does not recognise is now an error** ([#24]). Keys were read
  straight off the parsed JSON, so a misspelling was never rejected -- it resolved to `$null`
  and made the run quietly weaker while staying green, which is the exact failure class this
  tool exists to find in other people's code. Three verified instances:
  - `thresholds.brake` disabled the break gate outright. `Get-PSMutationExitCode` reads
    `$Thresholds.break`, so a repo shipping `{"brake": 100}` had a mutation gate that could
    never fail and nothing said so.
  - A misspelled operator name was silently dropped **and then written into the report's
    `operators` array**, so the artifact recorded a set that was never applied. That defeats
    the operators added in [#5]: opt into `ConditionForcing`, misspell it, and you get your
    old vacuous score back and conclude the new operator found nothing in your code.
    `Get-PSMutationCandidate` now throws instead of skipping.
  - `mutat` for `mutate` surfaced as
    `Access to the path '...\psmut-sandbox-<pid>' is denied`, mentioning neither the config
    nor the key.

  The message names the offending key and offers the nearest valid one within two edits --
  two being what a transposition costs, which is what `brake`/`break` is. Beyond that no
  suggestion is made, because a wrong guess sends the reader off to fix a key that was never
  the problem. `mutate` and `tests` are now required and must be non-empty. Keys starting
  with `_` are exempt: JSON has no comments, and the shipped configs use them. An error and
  not a warning, deliberately -- a warning in a CI log is indistinguishable from silence.
- **`coveredLinesOnly` now defaults to `true`, matching what the README has always promised**
  ([#25]). It was the only config value with no resolver at all: the orchestrator cast the
  raw value inline, and `[bool]$null` is `$false`, so omitting the key silently opted into
  mutating uncovered lines. Every mutant on an uncovered line is a guaranteed survivor, so a
  consumer who trusted the table and omitted the key got a materially worse score than the
  tool is designed to give, with nothing to explain why -- and the number measured coverage
  rather than test quality, which is a separate gate. Set `"coveredLinesOnly": false`
  explicitly to keep the old behaviour.

  The documented defaults are now pinned by tests rather than by prose, so the README config
  table cannot drift from the resolvers again. It had drifted twice: this one, and
  `sandboxSubtrees`, documented as `["tools","test","setup"]` -- a value the code has never
  had -- and corrected when [#45] moved that constant.

### Added
- **The config format and the report format are published as JSON Schemas** ([#84]).
  `schemas/v1/config.schema.json` defines every key `-ConfigFile` understands, what it means and
  what it must hold -- the definition a PSMutant config is written against. Name it with a
  `"$schema"` key and the config becomes self-describing, so a mistake surfaces while it is
  being written rather than several minutes into a run.

  `schemas/v1/report.schema.json` defines the report format, covering both shapes: a full run,
  and the partial run `-RecheckFrom` writes. Anything reading a report -- a dashboard, a
  ratchet, a merge tool -- can now validate one without reading this repo's tests, which
  were the only description of the format that existed, and were three hand-maintained lists
  inside Pester assertions.

  Both ship with the module, and the package smoke test fails if they do not arrive.

  A recheck report **may not carry `mutationScore` at all**. Worth encoding in the format
  rather than leaving to the printed caveat: a partial number quoted as a real one is the
  failure this project is organised around, and a reader who ignores prose cannot ignore a
  validation error.

  Two findings from building it. `ConvertFrom-Json` re-types the ISO-8601 `generatedAt` into
  a `[datetime]`, so the schema has to be applied to the **file** -- the string it describes
  is already gone once PowerShell hands back an object. And `Test-Json` silently **ignores
  the `not` keyword**, so the obvious way to spell "a recheck carries no score" is a rule
  that can never fail; it is written as a boolean-`false` property schema instead, which is
  honoured. Every keyword relied on was checked that way, because a schema rule that cannot
  fire is indistinguishable from one that passes.

  Extra properties are permitted deliberately: `schemaVersion` changes when a field changes
  meaning or disappears, never when one is added, so a validating reader survives a release
  that records more. The exact field lists stay pinned in the tests, because that is a
  different claim -- the schema states the guaranteed minimum for consumers, the lists keep
  *widening* deliberate on our side.

  Two enforcements of one format invite drift, so the agreement is asserted rather than
  maintained by hand: the schema's keys, threshold keys, operator vocabulary and required
  keys are all compared against the code. That test earned its keep immediately -- the first
  config schema refused `"break": null`, which the module has always accepted.
- **Every report records how it was produced** ([#34]): `schemaVersion`, `producedBy`
  (module and version), `generatedAt` in UTC, and `durations` covering the baseline, the whole
  run, and the per-mutant timeout. Both report shapes carry the same block, so a consumer reads
  provenance one way rather than learning two conventions.

  `schemaVersion` exists so a reader can branch on a number instead of guessing from which keys
  are present. That guessing was already happening: reconciling the full and recheck shapes by
  hand was part of [#20], and merging them is what [#4] will have to do. It changes when a field
  changes meaning or disappears, not when one is added.

  `durations` is not decoration. [#1] is a large, risky change to the runner justified entirely
  by speed, and until now the only way to evaluate it was timing two runs by hand on one
  machine. [#7] is likewise invisible as a trend -- nothing recorded that a suite was drifting
  toward its timeout bound until it crossed. The timeout is written beside the baseline it was
  derived from, which is what makes the comparison meaningful.

  The compatibility guard now names the schema when a report has one. Its old message said
  "predates source-hash recording" to anyone chaining a recheck, when the real reason was that
  recheck reports carried no hashes at all -- a version number is what lets it tell "too old"
  from "not that kind of report".

  Worth knowing when reading a report from PowerShell: `ConvertFrom-Json` recognises the
  ISO-8601 `generatedAt` string and hands back a `[datetime]`, so the text is only visible in
  the file itself. The file is the contract, and that is what the tests assert against.

### Fixed
- **A config value of the wrong type is now refused, instead of quietly breaking the run**
  ([#83]). `Assert-PSMutationConfig` checked key *names* and never types, so
  `"timeoutFactor": "four"` validated -- and then the timeout arithmetic yielded **nothing**,
  leaving an empty per-mutant deadline. A timeout expiry is scored as a **kill**, so the run
  reported a number it had not measured: the exact failure this tool exists to find in other
  people's code. `"coveredLinesOnly": "yes please"` was milder and the same absence of
  checking -- any non-empty string is `$true`.

  **The schema does the checking**, rather than a second table of types written in
  PowerShell. The module reads `schemas/v1/config.schema.json` at run time -- key names,
  threshold sub-keys and every type come out of it -- so adding a config key means editing
  one file, not four. An explicit `null` is never a fault, because absence is meaningful:
  `thresholds.break` unset means report-only.

  What stays in code is what a schema cannot say, and each gives a better answer than the
  schema would: the nearest valid name for a misspelled key, what `mutate` and `tests` are
  *for* when one is missing, and the operator names, which come from the operator map
  itself. The order those run in is the message quality.

  One new failure mode, handled: the schema can be absent from a partially copied
  installation, and a validator that skipped in that case would accept every config. It
  throws, naming the path, and the package smoke test asserts both schemas ship.
- **`Get-Help Invoke-PSMutation` served the wrong documentation.** PowerShell treats a `<# #>`
  block sitting immediately before the `function` keyword as that function's comment-based
  help, so this file's header shadowed the help written inside the body. Anyone running
  `Get-Help` got a one-line architecture note, no parameter descriptions and no examples,
  while the real documentation sat unreachable a few lines below. Nothing in the source looked
  wrong -- and the source was not wrong; only the resolution was.

  File headers in `src/` are `#` line comments now, and the suite asserts the public help
  resolves to the real thing: every parameter documented and described, examples present and
  non-empty. The audit that found this was itself fooled first, reading the shadowing block and
  concluding the help was complete, which is how `-Quiet` turned out to be undocumented.

  The help is also fuller than it was: five worked examples including the recheck loop, and a
  written `.PARAMETER` for every parameter.
- **The recheck loop now narrows** ([#14], [#20]). Its whole purpose is not paying for mutants
  you are not working on -- several hundred mutants with a handful of survivors should not mean
  re-running the set to report on those few -- and it was leaving two kinds of work on the table.

  **A recheck re-ran declared equivalents.** They appear in `survivors` legitimately: they
  survived, they were merely excluded from the denominator. But the config states in writing
  that no test can kill them, so re-evaluating one is guaranteed-wasted work -- 16 of 20 mutants
  in the case that prompted the issue, and it grows exactly as a repo gets more disciplined
  about declaring. They are skipped now, in both key forms.

  **A recheck report could not seed another recheck**, so every round after the first went back
  to the full report and re-ran what the previous round had already killed. Five survivors, kill
  two, and the next round evaluated five again -- with the waste compounding as you approach
  done, which is when the loop should be fastest. Now: five, then three, then one.

  Two things were needed, and the issue named only the first. Carrying `sourceHashes` and
  `operators` forward lets the compatibility gate accept a recheck report -- but
  `Select-PSMutationRecheckCandidate` reads `$Report.survivors`, and a recheck report wrote that
  list as `stillSurviving`. Provenance alone would have produced a report the gate **accepts**
  and selection then finds nothing in: `Recheck: 0 of 0 previous survivor(s) now killed`, a
  confident "you are done", which is a worse failure than the honest refusal it replaced. The
  list is now `survivors`, and an end-to-end test chains two rounds and asserts the second
  evaluates exactly what the first left alive.

  `Get-PSMutationRecheckReportPath` is idempotent, so rounds overwrite one scratch report
  instead of growing `report.recheck.recheck.json` and worse. The guarantee that matters is
  untouched: a partial run still can never overwrite the full report CI reads.
- **An equivalence declaration no longer goes stale when an unrelated line moves** ([#3]).
  Keys were `file:line:description`, so editing anything **above** a declared mutant -- a
  comment, an import, another function entirely -- invalidated the declaration although the
  mutant itself was untouched. That happened on the very first run after the feature shipped,
  and twice more while fixing [#28]: once when doc comments moved a mutant from line 126 to
  140, and again when extracting a function moved it to 165. Neither edit changed any
  behaviour.

  The key is now `file:function:description`, stable under every edit that does not move the
  mutant out of its function. The report's mutant rows carry a `Function` field to make that
  possible -- a deliberate widening of the contract [#48] pinned, which is what the pinning
  test is for; it failed when the field was added.

  `file:line:description` is **still accepted**, so existing configs keep working: a fix for
  key churn that invalidated every key would be a poor trade. It is also the only form
  available for code outside any function, which has no name to be addressed by.

  Worth knowing before reaching for the new form: **it is not universally more specific.** A
  function containing three `if ($isDeclared)` guards makes
  `Get-PSMutationScore:$isDeclared -> $true` match all three, so [#28]'s check refuses it as
  ambiguous and such a declaration has to stay keyed by line. Keeping both forms is what makes
  that case expressible at all.

  One of this repo's four equivalence declarations **retired** rather than moving. It argued
  that counting undeclared keys into `$matched` could not be observed, because `$matched` is
  only read for keys that are declared. That was true when written, and stopped being true
  here: the key is now `$null` for an undeclared mutant, `$matched[$null]` throws, and the
  suite kills all three of those mutants outright. A declaration is a checkable claim, and
  this is what it looks like when one stops being needed.
- **One equivalence declaration could silently exclude every mutant sharing its line and
  description** ([#28]). The key is `File:Line:Description`, and four operators emitted a
  description that said nothing about what was mutated -- `remove negation`,
  `return value -> $null`, `condition -> $true`, `string -> ''`. Two `-not` removals on a line,
  or two forced conditions, produced identical keys, so a declaration written about one of
  them excluded all of them. Stale-detection could not notice, because the key still matched
  something.

  That turns `equivalents` into precisely the mute button it was designed not to be. Measured
  over this repo's own source with every operator enabled: **84 mutants were reachable by an
  over-broad declaration, and one key covered 8 of them.**

  Two changes, because the first is not sufficient on its own:
  - **Descriptions are derived, not supplied.** `New-PSMutationCandidate` now builds
    `<original> -> <mutated>` itself and no longer takes a `-Description`, so a new operator
    cannot reintroduce a non-discriminating one -- which is what the old arrangement left
    entirely to whoever wrote the call. `remove negation` becomes `-not $done -> $done`;
    `condition -> $false` becomes `$ref.Value -> $false`. Whitespace is collapsed so a
    multi-line construct stays on one line, and the text is truncated at 120 characters --
    chosen by measurement, since 120 yields exactly as many distinct descriptions as no
    truncation at all over this repo, while 80 loses a few and 60 noticeably more.
  - **A declaration matching more than one mutant fails the run**, on the same footing as one
    that matches nothing or gets killed. This is the part that closes the hole: descriptions
    alone still leave **nine** colliding keys in this repo, because
    `[math]::Min($prev[$j] + 1, $curr[$j - 1] + 1)` legitimately puts two `1 -> 2` mutants on
    one line.

  The issue proposed failing whenever *any two candidates* share a key. That was tried and
  rejected on evidence: it would fail this repo's own run over those nine harmless ties, none
  of which is declared. Failing only when a **declaration** is ambiguous refuses exactly the
  unsound case and leaves undeclared ties alone. Genuine ties still cannot be declared at all;
  an occurrence index is the follow-up if anyone ever needs one, and the error now says so
  instead of silently over-excluding.

  Consequences worth knowing: descriptions appear in reports and console output, so existing
  equivalence declarations for those four operators need re-keying -- this repo's own two
  `ConditionForcing` declarations did. The console heading is now `INVALID equivalence
  declarations` rather than `STALE`, since ambiguity is not staleness.
- **A 0% mutation score no longer prints in green** ([#40]). The console summary compared the
  score against `$Thresholds.high` and `$Thresholds.low` straight off the parsed config, and
  in PowerShell any number `-ge $null` is `$true` -- so with no `thresholds` at all, or with
  the entirely reasonable `{"thresholds":{"break":80}}`, the first branch always won and
  **every** score rendered green. `Mutation score: 0%  (0 killed / 42)`, in green, in a
  report-only run that exits 0.

  It appeared in exactly the situation a new adopter is in -- minimal config, bands not tuned
  yet -- so the first impression of a tool built to expose flattering numbers was a green
  zero. The bands are now resolved in `PSMutation.Config.ps1` like every other config value
  (defaults 85 / 70, which the README documented only by example), and the colour is decided
  by a pure `Get-PSMutationScoreColour` taking resolved numbers, so the null cannot reach the
  comparison. `thresholds.high` and `thresholds.low` are now documented rows in the README
  config table, pinned by the same tests that pin every other documented default.

  The resolver tests `$null -ne` rather than truthiness, unlike its neighbours: a band of `0`
  is a meaningful setting -- never colour this red -- and `0` is falsy, so a truthiness test
  would have quietly substituted the default for it.

### Internal
- **Output has a seam: deciding what to say is separated from saying it** ([#47], [#60], [#61]).
  Twenty `Write-Host` calls were spread across four files, each picking its own
  `-ForegroundColor`. There is **one** now, in `Write-PSMutationOutput`, and
  `tests/Layering.Tests.ps1` asserts that count -- a second one anywhere in `src/` fails a
  test naming the renderer it should have gone through. PSScriptAnalyzer cannot do that job,
  since `PSAvoidUsingWriteHost` is excluded repo-wide for the gate scripts in `tools/`.

  Everything above the seam returns **lines**, each carrying a *role* rather than a colour --
  `Banner`, `Good`, `Warn`, `Bad`, `Detail`, `Muted`, `Rule`. CI annotations and markdown
  become a second renderer instead of a conditional at twenty call sites. A survivor line
  also carries the mutant row in `-Data`, so a renderer has the file and line as values
  rather than parsing them back out of formatted text.

  Nothing a consumer sees changes: same text, same colours.

  **This is why the output tests were the way they were.** Every one either mocked
  `Write-Host` or captured the information stream and pattern-matched prose, so rewording a
  line broke tests. They now assert on roles and text returned by a function. One file still
  mocks `Write-Host` -- `tests/Output.Tests.ps1`, where the emitting *is* the subject.

  **`-Quiet` has one implementation** ([#61]). It was enforced two ways: as a switch some
  functions honoured, and as an `if (-not $Quiet)` wrapper the caller had to remember --
  including around the two functions holding most of the output, which had no `-Quiet`
  parameter at all. There are zero caller-side guards now; callers always render and pass
  the switch to `Write-PSMutationOutput`, the only place it is honoured. A new emitter
  inherits the contract by signature instead of by copying whichever pattern it read first.

  **Two files no longer claim to be pure while printing** ([#60]). `Report.ps1` and
  `Recheck.ps1` were labelled Pure in the layout table while holding 15 `Write-Host` calls
  and 4 file writes between them. The console half is gone; the JSON write is not, and the
  table now says so rather than being edited to match a compromise.
- **The dependency direction between `src/` files is enforced** ([#52]). Every other gate is
  blind to it: a shortcut call from `Operators.ps1` into `Report.ps1` still reaches full
  coverage and still survives self-mutation. `tests/Layering.Tests.ps1` holds an allowlist of
  file-to-file relationships -- one entry per pair, not per call site -- and fails in both
  directions, since an allowlist describing edges the code dropped silently readmits them
  later. It also asserts the graph is acyclic, which the allowlist alone cannot give: two
  edges each reasonable on their own review make a cycle between them.

  Written now rather than earlier because this change adds four edges, and an allowlist is
  worth most written just beside the code that would violate it. Its two blind spots are
  stated in the file: the child-runspace script is a here-string, and the operator map is
  dispatched through `& $fn`.

  It found one thing already: there are **no** cross-file `$script:` reads left, so the
  locality rule now holds mechanically rather than by convention.
- **A scoped self-mutation config for the development loop.**
  `tools/New-PSMutantScopedConfig.ps1` narrows the real config to the files the current
  change touched: one file is about 80 mutants and half a minute, against 400-odd and
  several minutes for the whole set. Maintainer tooling -- nothing shipped changes.

  It is built so a scoped run cannot be mistaken for the gate, because that is the only way
  it could do harm: its score describes the files it mutated and can be a confident 100%
  over a change that broke something two files away. So the generated config is untracked,
  writes to its own `reportPath` rather than the artifact CI reads, prints the files it left
  out **by name**, and carries the warning in a `_comment` key.

  Two narrowing decisions earn their tests. A changed *test* file pulls in the source it
  covers, since writing the assertion that kills a survivor is the edit whose effect you
  most want to see. And declarations are subset with the files -- carrying the full set into
  a narrowed run leaves every out-of-scope declaration matching no mutant, which fails the
  run for a reason unrelated to the change.
- The rules that closed issues were supposed to leave behind are now actually written down,
  and two workflows gained the guard [#42] only ever applied to one of them. An audit of the
  nine issues closed so far found four gaps:
  - `publish.yml` had no `concurrency` group and `code-scanning.yml` had no `timeout-minutes`.
    #42 fixed `ci.yml` and stopped there, and nothing said a workflow needs both, so the other
    two each kept missing one. `publish.yml` deliberately sets `cancel-in-progress: false` --
    a superseded CI run is waste, but a half-finished publish is a gallery version that cannot
    be withdrawn -- so its group serialises releases instead of cancelling them.
    `code-scanning.yml` is a **required** check, so a wedged runner there held every merge
    behind a pending status for the six-hour default.
  - **The lesson of [#31] was never recorded**, and it is the sharpest one available: a
    predicate can sit at 100% coverage and survive every mutant while the pipeline stage that
    *calls* it is deleted and the suite stays green. Coverage watched the predicate's lines
    run; self-mutation mutated the predicate's logic; neither gate can see that the caller
    ignores the answer. The rule is to exercise a filter through its real entry point with one
    item kept and one dropped in the same call. A second rule came out of the same issue: the
    test titled "does NOT sweep the sandbox of a concurrently running process" never called
    the sweep, so a title claimed coverage the body did not provide.
  - CLAUDE.md's "Practices to adopt" section, which says of itself that every entry is an open
    gap with a tracked issue, held two entries that were finished work -- the `pins.env` rule
    ([#33]) and the `GateDecisions.ps1` rule ([#27], cited by number after it closed). Both
    moved to "Practices to preserve", and the rule for next time is to move a rule across in
    the same PR that closes its issue.
  - `code-scanning.yml` installed its two pinned modules unconditionally with
    `Install-Module -Force`, where `ci.yml` skips the install when the runner image already
    has the pinned version and then asserts it is present. The unconditional form collides
    with the PSScriptAnalyzer the image ships: the install warns "currently in use" and
    continues, and `Invoke-ScriptAnalyzer` then dies with a bare "Object reference not set to
    an instance of an object" naming neither a file nor a rule. This surfaced by failing the
    **required** check on a green branch; a re-run with no code change passed. Same class as
    [#33] -- two workflows agreeing on a version but not on how they obtain it.
  - The Gates table documented `ci.yml` only. The publish path had grown real gates from [#26]
    and [#37] and the required code-scanning check was absent entirely, so the file described
    a project whose one irreversible action looked ungated -- which is what #26 was about. The
    mutant count is no longer quoted exactly; keeping a number like that in step by hand is
    how the coverage figures here became folklore.
- Each source file now holds what its docstring says it holds ([#45]), and no file reaches
  into another's module state ([#38]). Nothing here changes behaviour; the point is that the
  repo's own rule for where new logic goes -- "put the decision in a pure unit, keep the
  entry point wiring" -- was only followable while the file names meant something, and four
  files had drifted from their own synopses.
  - **`src/PSMutation.Pester.ps1` is new** and owns the boundary with Pester: which one is
    loaded, its path, the version guard, and the script a child runspace imports it under.
    `Assert-PSMutationPester` and `Get-PSMutationPesterPath` were writing out the same
    `Get-Module | Sort-Object | Select-Object -First 1` in two files that had no reason to be
    read together -- one validating a version, the other handing a path to every child. If
    they had ever diverged the process would have validated one Pester and mutated under
    another, which is #16 reproduced from the inside. They now share one
    `Get-PSMutationLoadedPester`.
  - `Invoke-PSMutation.ps1` is one function. The Pester guard, a message constant and a
    second complete orchestrator for the recheck mode used to live there under a synopsis
    that said "public entry point". The recheck orchestrator moved to
    `PSMutation.Recheck.ps1`, which now holds the whole feature instead of only its pure
    half -- the old split was by purity rather than by feature, which is why two test files
    each owned half of one behaviour.
  - `PSMutation.Config.ps1` is resolvers only: `Assert-PSMutationBaselineGreen` moved beside
    `Invoke-PSMutationBaseline`, whose output it is the only reader of, and
    `ConvertTo-PSMutationRunResult` joined `PSMutation.Report.ps1`, which already owns the
    other contract a consumer's CI reads. The rule this settles -- a guard lives with its
    subject, not in a file grouped by grammatical form -- is recorded in CLAUDE.md, because
    "someone adding a third guard has no basis for choosing" was the original complaint.
  - The two cross-file `$script:` reads are gone, in opposite directions on purpose.
    `$script:PSMutationDefaultOperators` stayed in `PSMutation.Operators.ps1` and
    `Get-PSMutationOperatorList` moved to it, because `Get-PSMutationCandidate` is exported
    with that constant as a parameter default and moving it would break the public promise.
    The sandbox subtree default had no such claim on it, so it became
    `$script:PSMutationDefaultSubtrees` in `PSMutation.Config.ps1` beside its only reader,
    and `New-PSMutationSandbox -Subtrees` is now mandatory -- what to copy is a config
    decision, and every caller already passed one.
  - `Get-PSMutationBinaryCandidate` and `Get-PSMutationBoundaryCandidate` were the same
    twelve lines twice, differing only in map and operator name; they now delegate to one
    `Get-PSMutationSwapCandidate`, so the loop-condition guard and the `ErrorPosition` trick
    cannot be fixed in one and missed in the other.
  - `Get-PSMutationSandboxPlan` deliberately did **not** move to `PSMutation.Sandbox.ps1` as
    #45 proposed. The stated reason for moving it -- that it would remove the cross-file
    subtree read -- was wrong: that read was in `Get-PSMutationSubtree`, not in the plan
    builder. It takes the parsed config as input, so it is config resolution, and
    `Sandbox.ps1` is the one file that cannot be self-mutated, so moving it there would have
    quietly dropped it from the mutation gate.
  - `README.md` documented the `sandboxSubtrees` default as `["tools","test","setup"]`, which
    the code has never had. Corrected to `["src","tests"]` here because this change moves that
    exact constant, per the rule about grepping the docs when a default moves. The broader
    documented-defaults audit is still [#25].
  - The four equivalence declarations in `psmutant.self.config.json` were re-keyed. They are
    identified by `file:line:description`, so adding lines to a docstring *above* one shifts
    its key and the declaration stops matching -- the run then fails, correctly, reporting the
    mutant as a survivor rather than silently ignoring a stale claim. Worth recording as a live
    instance of [#3]: nothing here changed about the mutants or the arguments for them.
- The fix for #2 is now actually tested ([#31]). Deleting the
  `Where-Object { Test-PSMutationSandboxAbandoned ... }` stage from
  `Clear-PSMutationStaleSandbox` reverts the module to #2 -- a concurrent run's files pulled
  out from under it -- and the entire 246-test suite still passed. The predicate was well
  covered; the sweep APPLYING it was not. The existing test titled "does NOT sweep the
  sandbox of a concurrently running process" never called the sweep at all, which is how the
  gap hid; it is retitled to say what it really checks. The new test starts a real second
  process, since the predicate treats our own process id as reclaimable by design, and
  asserts one sandbox spared and another reclaimed in the same sweep -- the pairing being
  what proves a filter rather than an inert pipeline stage.
- The CI gates' pass/fail decisions are now pure functions with tests ([#27]). The scripts
  asserting "100% coverage", "the package works" and "Pester >= 5 still works" had no tests,
  no coverage and no mutants -- so an inverted comparison or a lowered default would have
  left every gate green while the numbers became fiction. `tools/GateDecisions.ps1` holds the
  three judgements, `tests/GateDecisions.Tests.ps1` pins them, and the package gate and the
  compatibility guard now share one "is this mutation result sane" decision instead of
  duplicating it. The orchestration around them is deliberately not tested or mutated: three
  of the four scripts are side effects end to end, so every mutant would cost a full gate run
  and `tools/` is not copied into the sandbox at all. That reasoning is recorded in CLAUDE.md
  rather than left implicit.
- Every pinned dependency now comes from one committed file, `.github/pins.env` ([#33]).
  `ci.yml` pinned its modules, `code-scanning.yml` installed PSScriptAnalyzer and
  ConvertToSARIF unpinned, and `publish.yml` hardcoded the Pester version twice and used an
  unpinned `actions/checkout` -- in the one workflow holding the Gallery API key. So the lint
  gate and the required code-scanning check could analyse with different analyzers, and the
  release path could run a different Pester than the test estate is written against, which is
  the drift class that hid #16. Each workflow now loads the file after checkout and asserts
  every key arrived, so a missing pin fails loudly instead of becoming an empty version
  string. `PSSA_PATHS` is shared too: the two analyzer gates previously agreed only because
  PSScriptAnalyzer ignores non-PowerShell files. Action SHAs cannot live in the file --
  `uses:` does not expand variables -- but all five references across the three workflows are
  now SHA-pinned.
- A release-consistency gate ([#37]). ModuleVersion, the newest CHANGELOG heading and the
  Gallery release notes are three descriptions of one release and nothing compared them --
  0.2.2 shipped while its entry was still under Unreleased, and the heading was renamed by
  hand afterwards. `tools/Test-PSMutantRelease.ps1` now refuses to publish unless the
  manifest's version has its own heading, that heading is the newest versioned one, and its
  section is not empty; it warns when entries are left stranded under Unreleased. It also
  captures that section, and the publish workflow applies it to the *staged* manifest, so
  the Gallery notes are derived from the changelog rather than transcribed into the manifest
  by hand. The decisions are pure functions with unit tests, per the rule that a tools/
  pass-or-fail decision belongs behind a tested function.
- Publishing is gated properly ([#26]). It used to run one of the seven gates that guard a
  merge, and the package it pushed had never been loaded by anything -- the first execution
  of that exact folder happened on a consumer's machine, and a Gallery version cannot be
  replaced or withdrawn. Now: the workflow refuses unless CI **passed for that exact commit**
  (stronger than re-running a subset, and it covers coverage, complexity, self-mutation and
  the Pester compatibility guard, none of which ran on this path); staging happens in its own
  step so the artifact can be inspected before it ships; and `tools/Test-PSMutantPackage.ps1`
  loads the staged package in a fresh process, asserts every name in `FunctionsToExport`
  resolves, checks that every `src/*.ps1` shipped is actually dot-sourced by the manifest's
  root module, and runs a real mutation over a deliberately under-asserted fixture that must
  leave survivors.
- CI gained a concurrency group, a job timeout and a module cache ([#42]). A superseded
  push no longer runs the full chain to completion, a wedged runner is bounded at 25
  minutes rather than the 6-hour default, and the four pinned modules are restored from
  cache instead of downloaded on every run -- so a PowerShell Gallery blip no longer reds
  a build that has nothing wrong with it. The cache key names the exact pinned versions,
  with no `restore-keys`: a partial restore would hand the run a different version set
  than the one asked for, which is the class of failure #16 was. All four pins now live
  in one `env:` block, and the install step skips what the cache already provided and
  then asserts every required version is present.

### Added
- **Three opt-in operators that reach decisions no expression operator can touch**
  ([#5]). Code whose logic lives in structure rather than in an expression produced
  ZERO mutants and therefore a vacuous 100% -- a phase guard (`if ($SyncUsers) { ... }`)
  or a reference-fallback chain (`if ($Ref.Value) { return ... }`) holds no comparison,
  no literal and no negation, so nothing in the default set could perturb it.
  - `ConditionForcing` -- an `if`/`elseif` condition forced to `$true` and to `$false`.
    This is the one that reaches the bare guards above. Loop conditions are excluded:
    forcing `while (X)` to `$true` is an unconditional hang, not a finding.
  - `ConditionalBoundary` -- `-gt` <-> `-ge`, `-lt` <-> `-le`. The classic off-by-one,
    which `BinaryOperator` cannot produce because it maps `-gt` to `-le` (a negation,
    not a boundary shift).
  - `ReturnValue` -- `return <expr>` -> `return $null`, for a result nothing asserts on.

  All three are **opt-in**, like `StringLiteral`: switching one on roughly doubles the
  mutant count and lowers the score, so a repo gating on `thresholds.break` would go red
  purely from upgrading. Adding an operator also renumbers mutants, so an existing report
  can no longer seed a `-RecheckFrom` run -- the operator set is recorded in the report,
  and the mismatch is refused rather than guessed at.

## [0.2.2] - 2026-08-18
### Fixed
- **A run on a machine with two Pester versions reported a fake 100%** ([#16]). Mutants
  are evaluated in a child runspace, and that runspace resolved `Pester` by *name* --
  getting the newest version installed rather than the one the process had already
  loaded. Assemblies are per-process, so the child died on an incompatible `Pester.dll`,
  returned no verdict, and a mutant with no verdict was classified `Killed`. The result
  was a silent, perfect score over tests that never ran: no error, no failed test,
  nothing to notice. The child is now handed the loaded module's *path*, and a child
  that returns no verdict fails the run instead of counting as a kill.
- `Assert-PSMutationPester` no longer re-imports Pester when a suitable one is already
  loaded. `Import-Module Pester -MinimumVersion 5.0.0` is not the no-op it looks like:
  PowerShell re-resolves the name to the newest installed version and collides with the
  assembly already in the process, which aborted the run before the first mutant.

### Internal
- Config resolution (subtree/operator defaults, the per-mutant timeout, the
  baseline-green guard, the run-result shape) moved out of `Invoke-PSMutation` into a
  pure `PSMutation.Config.ps1`. No behaviour change; an empty `operators: []` still falls
  back to the defaults. The sandbox path plan moved there too, and gained unit tests.
- Line coverage is **100% for every source file**, measured in one whole-directory pass
  and enforced in CI by `tools/Measure-PSMutantCoverage.ps1`. The orchestrator was
  previously documented as unmeasurable; that diagnosis was wrong. Pester 6 defaults
  coverage to the Profiler tracer, a nested Pester run destroys it, and everything
  discovered afterwards reports near-zero. Breakpoints survive, so the gate sets
  `CodeCoverage.UseBreakpoints = $true`.
- Self-mutation now covers `PSMutation.Runner.ps1` and `Invoke-PSMutation.ps1` as well,
  and is 100% over 103 mutants. `tests/Runner.Tests.ps1` gained mocked equivalents of the
  per-mutant execution tests so it can cover the runner on its own: mutating a timeout
  mechanism produces mutants that *disable* the timeout, and against the real child
  runspace in `tests/Mutant.Tests.ps1` each of those ran to the outer deadline -- minutes
  apiece. The gate went from over twenty minutes to under three.
  `PSMutation.Sandbox.ps1` remains excluded, with the real reason recorded: its covering
  suite calls `Clear-PSMutationStaleSandbox`, and a baseline runs in-process, so the
  sweep reclaims the live run's own sandbox and turns the baseline red.
- The test estate is pinned to Pester **6.1.0** in `ci.yml` and `publish.yml`, and every
  CI step imports that exact version instead of letting the name resolve. CI previously
  pinned 5.8.0 while development happened on 6.1.0. `RequiredModules` still asks only for
  Pester >= 5.0.0 -- that is a promise about the *consumer's* Pester, and it is now
  checked by `tools/Test-PSMutantPesterCompatibility.ps1`, which runs a real mutation
  under the version the suite does not use and fails if nothing survives.
- The suite's assertions were migrated to the Pester 6 `Should-*` commands, and
  `Should.DisableV5` is now set so the classic syntax is an error rather than a
  convention. v6 has no `Should-NotThrow` by design -- an unhandled exception fails a
  test on its own -- so the five `Should -Not -Throw` sites now call the command
  directly and assert what it actually did (which branch it took, or its
  postcondition). The here-string fixtures written out as a consumer's test files stay
  on classic syntax deliberately: the compatibility guard runs one of them under Pester
  5.8.0, where `Should-*` does not exist, and `DisableV5` cannot reach them because each
  is executed by its own configuration built inside the module.
- `coverage.xml` is no longer tracked; it was committed by accident and shipped in 0.2.1.

## [0.2.1] - 2026-08-18
### Fixed
- **Concurrent runs no longer destroy each other's sandbox** ([#2]). The startup sweep
  deleted every `psmut-sandbox-*` directory in temp, so starting a second run pulled the
  first run's source files out from under it -- which surfaced later as a confusing
  missing-file error rather than as a concurrency problem. A sandbox is now reclaimed
  only when its owning process is gone, including the case where the process id has been
  recycled onto an unrelated process.

## [0.2.0] - 2026-08-17
### Added
- **`-RecheckFrom <report>`** — re-run only the mutants a previous report recorded as
  survivors, for the write-assertions-and-retry loop. It reports counts rather than a
  score (a filtered set has no denominator worth quoting), writes to
  `<report>.recheck.json` so a partial run can never overwrite the baseline, and
  applies no thresholds. Sound only for *additive* test changes — editing a test can
  revive a mutant a recheck never evaluates — and the console says so on every run.
- Reports now record `operators` and a `sourceHashes` map (SHA256 per mutated file).
  `-RecheckFrom` refuses to run when either has changed, because mutant ids are
  AST-walk positions: matching them against moved code would confidently recheck the
  wrong mutants.
- **`equivalents`** config map (`file:line:description` → reason) for mutants that
  provably cannot change behaviour, excluded from the denominator so
  `thresholds.break: 100` means "every catchable fault is caught". A declaration is a
  checkable claim, not a mute button: a blank reason is ignored, and the run **fails**
  if a declared mutant is killed or no longer exists — regardless of thresholds,
  including report-only mode. The exclusion count is printed beside the score and
  stored as `declaredEquivalent`, so a declared 100% never reads as an earned one.

### Fixed
- `Invoke-PSMutationLoop` threw on an empty candidate set. Reachable whenever a mutate
  file contributes no covered candidates, and on every recheck whose previous
  survivors are all dead.

### Changed
- CI now gates complexity using the **PSComplexity** module (a faithful cognitive
  metric), replacing the bundled `tools/Get-PSComplexity.ps1`. The two Fortigi modules
  dogfood each other: PSMutant's CI uses PSComplexity for its complexity gate, and
  PSComplexity's CI uses PSMutant to mutation-test itself.
- Pinned CI tooling (Pester 5.8.0, PSScriptAnalyzer 1.25.0) and SHA-pinned actions.

## [0.1.0] - 2026-07-03
### Added
- Initial release.
- AST-based mutation operators: binary operators (`-eq`↔`-ne`, `-and`↔`-or`,
  `+`↔`-`, …), boolean literals (`$true`↔`$false`), integer literals (`N`→`N+1`),
  quoted strings (`→ ''`, opt-in), and negation removal (`-not X`→`X`).
- Sandboxed execution — mutants run against a throwaway temp copy, so tracked source
  is never modified even if the run is killed.
- Per-mutant wall-clock timeout (cancellable runspace): a non-terminating mutant —
  e.g. a mutated loop body that defeats a guarded loop — is cut off and counted Killed
  instead of hanging the run. The loop-condition guard is a speed optimisation on top.
- Covered-lines-only filtering (Pester code coverage), per-file test mapping.
- JSON report + console summary; report-only or `thresholds.break` gating.
- `Invoke-PSMutation`, `Get-PSMutationCandidate`, `Set-PSMutationText` exported.
