# PSMutant — AI Assistant Development Guide

Mutation testing for PowerShell. Injects small faults into your source (flip `-eq` to
`-ne`, `$true` to `$false`, `N` to `N+1`, drop a `-not`) and scores how many your Pester
suite catches. Published to the PowerShell Gallery.

---

## The rule that matters most here

> **This is a testing tool, so its own numbers are the product. PSMutant must hold
> itself to 100% line coverage and 100% self-mutation — no exceptions carried quietly.**

A coverage tool that is itself half-covered, or a mutation tool whose own mutants
survive, has no standing to fail anyone else's build. The gate is not "high", it is
**100**, and `psmutant.self.config.json` sets `thresholds.break` to exactly that.

That cuts both ways: when a file genuinely cannot be measured, say so **in one place,
with the reason**, rather than letting the number quietly sag. Coverage now has no such
exception. Self-mutation has exactly one, and it is a structural impossibility rather
than a shortfall — see below.

Every exclusion in `psmutant.self.config.json` carries a written reason. If you add
one, write why — and re-read the existing reasons before trusting them, because two of
them have already turned out to describe something other than what was really going on.

---

## Gates

CI (`.github/workflows/ci.yml`) runs, in order:

| Gate | What it is |
|---|---|
| Import smoke | module loads, `Invoke-PSMutation` is exported |
| Lint | `tools/Invoke-PSMutantAnalyzer.ps1` — PSScriptAnalyzer over `PSSA_PATHS`, **every severity**. The same script code scanning runs |
| Unit tests | whole `tests/` directory, must be 0 failures. Two gates live only here: `Layering.Tests.ps1` (file-to-file edges, acyclicity, the one `Write-Host`) and the public-help and schema assertions in `EndToEnd.Tests.ps1` |
| Order independence | `tools/Test-PSMutantOrderIndependence.ps1` — the same suite again, reversed, plus an environment comparison |
| Coverage | `tools/Measure-PSMutantCoverage.ps1` — **100%** over `src/`, enforced |
| Complexity | sibling module PSComplexity, 15 cyclomatic / 15 cognitive per unit |
| Self-mutation | `Invoke-PSMutation -ConfigFile ./psmutant.self.config.json`, break = 100. Several hundred mutants and a handful of minutes -- deliberately not a figure to keep in step, because a hand-maintained count is how the numbers here became folklore before |
| Pester compatibility | `tools/Test-PSMutantPesterCompatibility.ps1` — a real mutation run under the Pester version the suite does *not* use |

`ci.yml` is not the whole story, and reading only this table is how #26 happened — publishing
used to run about one sixth of the merge gates with the package never once loaded.

**`code-scanning.yml`** runs `tools/Invoke-PSMutantAnalyzer.ps1` — the very script the lint gate
runs — and uploads its findings as SARIF. It is a **required** check, so it can block a merge on
its own. One script rather than two shared variables: the two used to agree about `PSSA_PATHS`
and the settings file and still disagree about severity (#76).

**`publish.yml`** gates the one irreversible action in the project — a gallery version cannot
be withdrawn — and runs, in order:

| Gate | What it is |
|---|---|
| Unit tests | the suite again, on the tagged commit, under the pinned Pester |
| CI must have passed | the `ci.yml` conclusion for this exact commit is queried and required |
| Tag vs `ModuleVersion` | refuses when the git tag and the manifest disagree |
| Release consistency | `tools/Test-PSMutantRelease.ps1` — `ModuleVersion`, the newest CHANGELOG heading and the shipped `ReleaseNotes` must agree |
| Already published | skips rather than fails when that version is on the gallery, and warns that it skipped |
| Package smoke test | `tools/Test-PSMutantPackage.ps1` — loads the *staged* package in a fresh process, asserts every exported name resolves, asserts every shipped `src/*.ps1` is dot-sourced by the root module, and runs a real mutation whose fixture must leave survivors |

---

## Pester: one version for the estate, any version for consumers

Two different things. Conflating them is what caused #16.

- **The test estate** is pinned to exactly **6.1.0** — `ci.yml`, `publish.yml`, and local
  development. Every CI step runs `Import-Module Pester -RequiredVersion` rather than
  letting the name resolve, so CI and your machine cannot end up on different Pesters.
  Bumping it means changing `.github/pins.env` and this file together -- every workflow
  loads its versions from that one file.
- **The module** promises `Pester >= 5.0.0` in its manifest and has to drive whatever the
  consuming repo already has. The pin above narrows nothing about that.

The second promise is the fragile one, because it only breaks when **two** versions are
installed. Everything below lives in `src/PSMutation.Pester.ps1`, which exists so that the
answer to "which Pester" is given **once**: the two functions used to resolve it separately,
in two files, and if they had ever disagreed the process would validate one version and
mutate under another -- this same bug, from the inside.

- A child runspace resolves `Pester` by **name** and gets the newest installed, not the
  one this process loaded. Assemblies are per-process, so a mismatch kills the child
  outright. Fixed by `Get-PSMutationPesterPath`, which hands the child the loaded
  module's **path** (from the shared `Get-PSMutationLoadedPester`); the child script itself
  lives in `Get-PSMutationBoundedPesterScript` so that contract sits in one named place.
- `Import-Module Pester -MinimumVersion 5.0.0` is **not** a no-op when a satisfying Pester
  is already loaded — PowerShell re-resolves the name to the newest installed and
  collides. Fixed by `Assert-PSMutationPester`, which accepts what is already loaded.
- **The manifest must not declare Pester in `RequiredModules`.** `ModuleVersion` there is a
  *minimum*, satisfied by importing the newest installed — at **import** time, before either
  guard above can run. So `Import-Module PSMutant` then
  `Import-Module Pester -RequiredVersion 5.7.1` died on an assembly collision and left the
  caller on 6.1.0, while the same two lines in the other order worked fine (#30). Pester is a
  **run-time** dependency and `Assert-PSMutationPester` is the single place that enforces it.
  The price is that `Install-Module PSMutant` does not pull Pester in; that is the right trade
  for a module whose whole promise is running under *your* Pester, and it is stated in the
  manifest description, the README and the error message.

**Why this mattered more than a red suite.** A dead child returns no verdict, and
`Invoke-PSMutant` reads anything-but-`Passed` as a kill. So on any machine with two
Pesters the *shipped* module scored **every** mutant Killed and reported a silent,
perfect, entirely fake 100% — no error, no failed test. `Invoke-PSBoundedPester` now
throws instead of returning nothing, and the compatibility guard exists to make that
particular lie impossible: it runs a real mutation over a fixture whose deliberately weak
test **must** leave survivors, and fails if everything comes back killed.

---

## Running the self-mutation gate while developing

The gate is several hundred mutants and a handful of minutes, nearly all of it re-proving
files nobody edited. `tools/New-PSMutantScopedConfig.ps1` narrows the real config to the
files in the current change and writes an untracked `psmutant.scoped.config.json`:

```powershell
./tools/New-PSMutantScopedConfig.ps1 -Run          # vs main, committed and uncommitted
./tools/New-PSMutantScopedConfig.ps1 -Since HEAD   # uncommitted only, the tightest loop
```

One file scopes to about 80 mutants and half a minute, against 400-odd and several minutes
for the whole set.

**Run the full set only when you are about to push.** During development there are two
cheaper answers and they are not interchangeable:

| Situation | Use | Cost |
|---|---|---|
| changed a file, want to know if it is still clean | `New-PSMutantScopedConfig.ps1 -Since HEAD` | ~80 mutants, ~30s |
| just fixed a survivor, want to know if it is dead | `-RecheckFrom <report>` | the survivors only, seconds |
| about to push, or opening a PR | the real config | 500-odd mutants, ~9 min |

The middle row is the one that gets forgotten, and it is the one this module exists to
provide. A recheck seeded from the last report evaluates **only** what survived, skips
declared equivalents -- no test can kill those, so re-evaluating them is guaranteed-wasted
work -- and answers in seconds. Measured on this repo: 4 survivors in the report, 1 actually
re-evaluated, **19.2s**, against **~9 minutes** for the full sweep that answers the same
question.

Verifying one mutant does not need the whole suite either. The config maps each source file
to one covering suite, so `Config.Tests.ps1` is 101 tests in 4.6s where the whole `tests/`
directory is 546 in 49s. Apply the mutant by hand, run that one file, restore.

**Run the suite the way CI runs it, which means `$ErrorActionPreference = 'Stop'`.**

```powershell
$ErrorActionPreference = 'Stop'
Invoke-Pester -Configuration $cfg
```

A developer shell defaults to `Continue`; the workflow steps run under `Stop`, and the difference
is not cosmetic. Under `Stop` a failing `Import-Module` in a `BeforeAll` becomes terminating, so
Pester marks every test in the block Failed and attaches the error to the **container** rather than
to the test -- which means `$test.ErrorRecord` is EMPTY, and any code reading a reason off it gets
nothing. That is a real difference in behaviour, not in formatting.

It cost three pushes to find. A fixture went red on both CI legs while passing locally, and the
first two fixes each addressed a different plausible cause -- Pester's wording, then a leading blank
line -- without reaching it. One line in front of `Invoke-Pester` reproduces both legs on the
machine you are standing on.

The general shape, which is worth more than the specific bug: **the environment differences that
matter are the ones that change control flow**, not the ones that change text. `$ErrorActionPreference`,
`$PSNativeCommandUseErrorActionPreference` and strict mode all belong on that list; a locale or a
console width does not.

**CI is the LAST gate, not the first.** It exists to catch what local checking cannot see --
the other operating system, the pinned dependency set, and the interaction between gates. A
Linux-only defect shipped green from a Windows machine this way: a hard-coded backslash in a
path normaliser, which is a no-op on Linux and therefore invisible to the very gate that would
have caught it. None of that is reproducible here.

So do not push in order to find out whether something works. A red CI should be a surprise
worth investigating, not a step in the loop -- `publish.yml` requires CI green for the exact
commit, and a signal that fires routinely stops being a signal. Run the cheap local checks
always, the full local gate when the change is broad, and expect CI green.

The corollary is a gap worth knowing: when CI's mutation gate does fail, it prints
`Self mutation score: 99.8% (532/533)` and nothing else. `-Quiet` is all-or-nothing and the
run result carries no survivor list, so the one number a backstop produces cannot say what
failed. That is #54's subject, and until it is fixed the answer is a local `-RecheckFrom`.

**A scoped run is never the gate, and every part of this is built to keep that true.** Its
score describes the files it mutated, not this project, so it can be a confident 100% over
a change that broke something two files away. The output is untracked, it writes to its own
`reportPath` so it cannot overwrite the artifact CI reads, it prints the files it left out
by name, and the generated config says so in a `_comment`. Before a PR, run the real config.

Two narrowing decisions are worth knowing. A changed **test** file pulls in the source it
covers, because writing the assertion that kills a survivor is exactly the edit whose effect
you want to see. And declarations are subset with the files -- carrying the full set into a
narrowed run means every declaration for an out-of-scope file matches no mutant, which fails
the run for a reason that has nothing to do with the change.

The narrowing itself is a pure function in `tools/ScopedConfig.ps1` with tests, for the same
reason the gate decisions are: `tools/` is outside `sandboxSubtrees` and is never mutated, so
tests are the only thing standing between a scoping bug and a fast green run that measured
less than it claimed.

---

## Measuring coverage

One invocation, the whole directory, no exclusions and no exempt files:

```powershell
./tools/Measure-PSMutantCoverage.ps1        # fails below 100%
```

**`CodeCoverage.UseBreakpoints = $true` is the load-bearing setting.** Pester 6 switched
coverage to the Profiler tracer by default, and a nested Pester run — which
`tests/EndToEnd.Tests.ps1` starts for real, because a full `Invoke-PSMutation` runs the
baseline suite — tears that tracer down. Every test file discovered after it then reports
almost nothing, which reads as a believable ~20% for files that are in fact fully
covered. Breakpoints survive the nested run.

It is a committed script rather than a snippet in `ci.yml` so that measuring by hand and
measuring in CI cannot drift. The figures here used to be folklore for exactly that
reason.

**This corrects two claims this file used to make.** Whole-directory coverage does *not*
mis-attribute across files, and `Invoke-PSMutation.ps1` is *not* unmeasurable. Both were
the same thing — the tracer being destroyed — observed on 6.1.0 while CI ran 5.8.0, which
only ever had breakpoints and so never saw it.

`src/PSMutation.Config.ps1` still exists for a good reason, just not that one: config
resolution is *decision* logic, and decisions are worth isolating, unit-testing and
self-mutating on their own terms. Keep new decisions there rather than in the body of
`Invoke-PSMutation`, which should stay wiring.

### Current state

| File | Coverage | Self-mutated |
|---|---|---|
| `PSMutation.Operators.ps1` | 100% | yes |
| `PSMutation.Report.ps1` | 100% | yes |
| `PSMutation.Recheck.ps1` | 100% | yes |
| `PSMutation.Pester.ps1` | 100% | yes |
| `PSMutation.Config.ps1` | 100% | yes |
| `PSMutation.Output.ps1` | 100% | yes |
| `PSMutation.Runner.ps1` | 100% | yes |
| `Invoke-PSMutation.ps1` | 100% | yes |
| `PSMutation.Sandbox.ps1` | 100% | **no** — see below |

`PSMutation.Sandbox.ps1` is the one file that cannot be self-mutated, and the reason is
structural rather than a gap in effort. Its covering suite, `tests/Sandbox.Tests.ps1`,
calls `Clear-PSMutationStaleSandbox` for real. A self-mutation baseline runs **in-process**,
so it shares `$PID` with the sandbox that run is executing from — and the sweep treats its
own process id as reclaimable. Listing that suite anywhere in the config therefore deletes
the live run's sandbox mid-baseline and turns the run red before a single mutant is tried.
Its behaviour is pinned by the normal suite at 100% coverage instead.

---

## The mutant runspace is warm, and what that costs to keep true

Every mutant used to get a fresh `[PowerShell]` and its own `Import-Module Pester`. Measured with
PSComplexity as the target -- a real consumer repo, which is a better subject than this module's own
source and is also the consumer-shaped fixture #35 asks for -- that floor is about **396 ms**, and
over an 801 s run it was **219 s, 27%**, re-importing a module that does not change between mutants.

The runspace is now built once and reused, and the covering suite stops at the first failure. End to
end, interleaved, two pairs: **221 s -> 71 s** over 225 mutants, 225 killed both sides, every
per-mutant verdict identical.

Four things about it are easy to undo:

- **Reuse is safe because nothing about a mutant is cached.** The covering suite dot-sources the
  file under test, so each run reads the spliced source afresh. What COULD travel is state a suite
  leaves behind, which is why the runspace is retired after a fixed number of uses. Fifty is a
  decision, not a constant to tune upward: the saving is already ~93% of the floor there, so a
  larger number buys almost nothing and widens the window in which a leak goes unnoticed. A test
  pins the number for exactly that reason -- the boundary test is written in terms of the constant,
  so changing it would otherwise slide past.
- **A timeout discards the runspace.** `Stop()` leaves it unusable, so handing it to the next mutant
  would fail every subsequent one.
- **A failed Pester import throws rather than yielding a shell.** A shell without Pester runs every
  covering suite into a command-not-found and returns no verdict -- which `Invoke-PSMutant` reads as
  a KILL. Same shape as the version collision this file already documents at length, reached through
  a different door. There is deliberately no `HadErrors` check beside the `catch`: the child's
  `-ErrorAction Stop` makes a failed import terminating, so that branch could never fire.
- **`SkipRemainingOnFailure` is feature-detected, never version-compared.** It arrived in **Pester
  5.3.0** -- measured, not looked up: 5.2.0 does not carry the property and 5.3.0 does. So the guard
  exists for 5.0.0 to 5.2.x and nothing else. It is kept because the module promises to run under
  whatever Pester >= 5 the consumer already has, and assigning a missing property would fail the
  whole run for a speed optimisation. The comment beside it said 5.5 until the versions were
  actually installed and checked, which is why it now says how it was measured.

  Both arms are pinned by tests against stand-in objects, because CI runs 6.1.0 and the
  compatibility gate runs 5.8.0 -- no gate here loads a Pester without the property, so the false
  arm would otherwise never execute.

**`Get-PSMutationRunspaceError` lives in `PSMutation.Pester.ps1`, not `PSMutation.Runner.ps1`.**
Reading a child runspace's error stream is this file's domain. The first draft of the warm runspace
left it in Runner and called upward, making a cycle -- and coverage, the suite and the mutation gate
all passed. `tests/Layering.Tests.ps1` failed on the second run, naming both the undeclared edge and
the cycle. That is the gate doing the one job nothing else can do.

## The sandbox path is a security boundary, not just a scratch location

The sandbox used to be `$TMPDIR/psmut-sandbox-$PID`, and creating it began by removing whatever
was already there. On a shared machine that is a hole, and it was reproduced end to end rather
than argued about: another local user creates that path first as a symlink to a directory they
own, the victim's `Remove-Item` fails because the sticky bit protects the attacker's entry, the
failure is **non-terminating** so execution carries on, and `Copy-Item` writes the source through
the link.

`fs.protected_symlinks` does not save you here, which is the part worth remembering: it guards
only the **final** path component, and the planted symlink is an intermediate one. Confirmed with
two real users on a current kernel with the sticky bit set.

The exposure is larger than disclosure. The sandbox is where the tests **run from**, so whoever
controls that directory can substitute a source or test file between the copy and the run -- code
execution as the victim, from a directory they were merely allowed to create.

Three rules now, and none of them is decoration:

- **The name is unguessable.** `New-PSMutationSandboxName` appends 128 bits from
  `RandomNumberGenerator`, not `Get-Random` and not a GUID: those are about uniqueness, and the
  property needed is that an attacker cannot predict the next value. The process id stays in the
  name because the stale sweep identifies an owner by it.
- **An existing path is REFUSED, never cleared.** Clearing is what made the attack work. With an
  unguessable name a collision is not a case worth recovering from, so refusing is both safer and
  the more honest answer.
- **What was created is checked to be a plain directory.** A check followed by a create is a race;
  the post-creation check is what catches a path substituted inside it.

`Get-PSMutationSandboxOwnerId` still accepts the OLD `psmut-sandbox-<pid>` form, deliberately.
The suffix is what makes a name unguessable when it is *written*; reading one is a different
question, and refusing the legacy shape would orphan every sandbox left by a previous version the
moment this ships.

The sweep also skips reparse points now. Anyone can leave a symlink in temp named like a sandbox,
and recursively removing one asks the sweep to follow a path an attacker chose -- nothing this
module creates is ever a link, so skipping costs nothing and removes the sweep as a deletion
primitive.

**Residual, and stated rather than left to be discovered:** the sandbox directory is created with
the process umask, so on a typical Unix box it is world-READABLE while the run lasts. Closing that
needs `File.SetUnixFileMode`, which is .NET 7 and above this module's PowerShell 7.2 floor. The
unguessable name closes the write-through attack, which is the one with the proof of concept; a
reader still has to find the name first.

## Output: deciding what to say, and saying it

Every file that produces output returns **lines**; `src/PSMutation.Output.ps1` emits them and
holds the module's only `Write-Host`. `tests/Layering.Tests.ps1` asserts that count, so a
second one anywhere in `src/` fails a test naming the renderer it should have gone through.
PSScriptAnalyzer cannot do that job: `PSAvoidUsingWriteHost` is excluded repo-wide because
the gate scripts in `tools/` print for a living.

A line carries a **role**, never a colour: `Banner`, `Good`, `Warn`, `Bad`, `Detail`,
`Muted`, `Rule`, `Annotation`. The console renderer maps role to colour; the second renderer
predicted here now exists, and maps the same lines to GitHub workflow commands. An unknown role
**throws** -- a silently uncoloured line reads as a styling slip, when what it signals is a
renderer that will not know what to do with the line at all.

`Annotation` is the one role with **no colour**, and that is load-bearing rather than
cosmetic: a workflow command is parsed from the START of a line, so an ANSI escape written
ahead of the `::` turns a finding into a line of log nobody reads -- and it looks perfectly
fine on a console. `Write-PSMutationOutput` therefore splats, because an `if`/`else` with a
`Write-Host` in each arm would make **two**, and `tests/Layering.Tests.ps1` asserts the count.

The role list is pinned literally by a test, so growing the vocabulary fails there first. That
is the intent: a role is a promise to every renderer.

`Rule` and `Muted` both print DarkGray and are still distinct, which is the point of roles
rather than colours: a renderer that is not a console drops separators, and must not take
the recheck caveats with them.

A survivor line carries the mutant row in **`-Data`**, and `Get-PSMutationAnnotationLine` reads
only that -- never `Text`. Recovering a file and line by parsing the formatted string back apart
is exactly the coupling this seam removes, and it would break the first time the console format
is tuned. A line whose `Data` has no `File` is skipped: an annotation with no location renders
against the workflow file, sending the reviewer to YAML that has nothing to do with the finding.

**Annotations are deliberately NOT passed `-Quiet`**, and that is the one place a caller does
not forward the switch. `-Quiet` exists so a CI log is not several hundred progress lines; CI is
also where a survivor most needs to be seen, and suppressing both leaves a failed gate printing
a score and nothing else -- a backstop that cannot say what failed. The switch silences the
**log**; a finding is not log.

The empty case is the one to be careful with: with nothing to annotate the mapper yields no
lines at all, and `-Lines` accepts an empty collection but not `$null`. Without an `@()` wrap
the **green** run is the one that throws, under Actions only.

**`-Quiet` is honoured in one place**: `Write-PSMutationOutput`. Callers always render and
pass the switch down; they never guard. Guarding at the call site means each new emitter has
to remember, and one that forgets prints in quiet mode while every existing test stays green,
because those tests assert on the output the *current* callers produce.

## Forcing a decision: what a `switch` clause actually needs

`ConditionForcing` reaches `if`/`elseif`, the ternary, and every `switch` clause. Getting the
`switch` right took two attempts and the wrong reasoning was recorded in an issue before it was
checked, so the conclusion is written here.

**A clause condition is its own extent, so forcing it is an ordinary offset splice.** Both #46 and
the follow-up I filed claimed a value clause needed a "syntax rewrite" and new machinery. It does
not: `1 { 'one' }` becomes `{ $true } { 'one' }` by replacing the extent of `1`, exactly as every
other operator replaces an extent.

**Force to a SCRIPT BLOCK, never to a bare `$true`.** This is the part that is easy to get wrong and
was got wrong first. PowerShell matches a clause with `$_ -eq <clause>`, so a bare `$true` spliced
over `1` does not mean "always match" -- measured, it stops matching `x = 1` and starts matching
`x = $true`. That is a value substitution with murky semantics, as likely to be equivalent as
informative. Wrapping it makes the clause a CONDITION, which is what forcing means everywhere else:

```
switch ($x) { 1 { 'one' } 'a' { 'letter' } default { 'none' } }
  baseline          x=1 one    x='a' letter      x=99 none
  1 -> { $true }    x=1 one    x='a' one letter  x=99 one     <- shadows, and falls through
  1 -> { $false }   x=1 none   x='a' letter      x=99 none
```

The shadowing case is the fault worth catching, and it is why `New-PSMutationForcedCandidate` takes
the forced spellings as a PARAMETER rather than assuming `$true`/`$false`.

**`default` is still not reached**, and that is a real limitation rather than an oversight: it sits
outside `Clauses` on the AST and has no condition to force. Removing the clause entirely is
statement removal, an operator this module does not have; #172 records it.

**Measure reach on a consumer, not on this repo.** Neither this module's source nor PSComplexity's
contains a single ternary, and between them they hold exactly one `switch` -- so neither is any use
for judging whether an operator matters. another repository, 238 files: 2137 `if` statements, 18 `switch`
statements, 59 value clauses against 3 script-block ones. The value clauses are where nearly every
switch decision lives, and measuring that is what turned this from a leftover into the substantive
half.

## The two published schemas

`schemas/` holds the formats this module exchanges with the outside world, and both ship in
the package -- the staging `Copy-Item` in `publish.yml` is the single place that decides
whether they travel, and `tools/Test-PSMutantPackage.ps1` fails if they do not arrive.

- **`config.schema.json` is the config format** -- and not a description of it. The module
  READS it: `Get-PSMutationConfigKey` takes the key names and the threshold sub-keys from
  it, and `Get-PSMutationConfigTypeFault` validates against it with `Test-Json`. There is no
  second copy in PowerShell to fall out of step, because there is no second copy.
- **`report.schema.json` is the report format**, covering both shapes.

**What stays in code is only what a schema cannot say**, and each earns its place by giving
a better answer than the schema would:

| In code | Because the schema would say |
|---|---|
| nearest-name suggestion for an unknown key | "property not allowed" -- which does not say `break` when you wrote `brake` |
| `mutate` / `tests` missing or empty | "required properties are not present" -- true, and it teaches nothing |
| operator names, checked against the operator map | it would need the vocabulary copied out of the map, which is the drift this move removed |

**The ORDER those run in is the message quality**, so do not reshuffle
`Assert-PSMutationConfig` casually: name, then missing-or-empty, then the schema. Absence
and emptiness come before the type check because they are about the *value*, not its kind;
an object in `mutate` falls through to the schema and is named as a type error, which is the
better answer for that one.

**The module now depends on a data file at run time**, which nothing in `src/` did before.
Two consequences, both handled and both easy to undo by accident:

- `Get-PSMutationConfigSchema` **throws, naming the path**, when the schema is absent. A
  validator that skips when it cannot find its schema accepts every config, including the
  ones this exists to catch. The package smoke test asserts both schemas ship.
- `psmutant.self.config.json` copies `schemas` into the sandbox. A sandboxed `src/` that
  cannot find the schema refuses every config and turns the baseline red before a mutant is
  tried.

Three things about the schemas worth knowing before editing either:

- **Validate the FILE, not a parsed object**, for reports. `ConvertFrom-Json` re-types the
  ISO-8601 `generatedAt` into a `[datetime]`, so the string the schema describes is gone by
  the time PowerShell hands you an object. The config path re-serialises instead, because
  the caller holds an object and a config has no field that survives the round trip badly.
- **`Test-Json` silently ignores `not`.** The obvious spelling of "a recheck must not carry
  a mutationScore" is a clause that can never fire. It is written as
  `"properties": { "mutationScore": false }`, which NJsonSchema does honour. Verify any new
  keyword the same way -- a schema rule that cannot fire looks exactly like one that passes.
- **Prefer a type union to `oneOf`.** `oneOf` reports a failure in every branch as a
  sub-error, so an unrelated mistake elsewhere in the file drags a bogus complaint about
  this key along with it and points the reader at a line that is fine. `"type": ["array",
  "string", "null"]` with `items` says the same thing with one accurate error.

Additional properties are permitted in the **report** schema on purpose: `schemaVersion`
changes when a field changes meaning or disappears, never when one is added, so a consumer
validating against it survives a release that records more. That is also why the exact field
lists stay pinned in the tests -- the schema states the guaranteed **minimum** for
consumers, and the literal lists keep *widening* a deliberate act on our side. The **config**
schema is the opposite: `additionalProperties: false`, because an unrecognised key there is
a typo that would otherwise weaken the run in silence.

Two things about the report schema worth knowing before editing it:

- **Validate the FILE, not a parsed object.** `ConvertFrom-Json` re-types the ISO-8601
  `generatedAt` into a `[datetime]`, so the string the schema describes no longer exists by
  the time PowerShell hands you an object.
- **`Test-Json` silently ignores `not`.** The obvious spelling of "a recheck must not carry
  a mutationScore" is a clause that can never fail. It is written as
  `"properties": { "mutationScore": false }` instead, which NJsonSchema does honour --
  verified, because a schema rule that cannot fire is exactly the kind of quiet
  non-enforcement this repo exists to distrust. Check any new keyword the same way.

Additional properties are permitted in the report schema on purpose. `schemaVersion` changes
when a field changes meaning or disappears, never when one is added, so a consumer
validating against it survives a release that records more. That is also why the exact
field lists stay pinned in the tests: the schema states the guaranteed **minimum** for
consumers, and the literal lists keep *widening* a deliberate act on our side. Two
assertions, two different claims.

## Operators, and the vacuous 100%

The default set mutates **expressions**: `BinaryOperator`, `BooleanLiteral`,
`NumberLiteral`, `NegationRemoval`. Code whose logic lives in *structure* produces zero
mutants under it and therefore scores a **vacuous 100%** — a phase guard
(`if ($SyncUsers) { ... }`) or a reference-fallback chain
(`if ($Ref.Value) { return ... }`) contains no comparison, no literal and no negation.

Four operators are **opt-in**, and this repo turns three of them on for itself:

| Operator | Reaches |
|---|---|
| `ConditionalBoundary` | off-by-one: `-gt`↔`-ge`, `-lt`↔`-le`. `BinaryOperator` maps `-gt` to `-le` — a negation, not a boundary shift — so it can never produce a fencepost |
| `ConditionForcing` | an `if`/`elseif` condition forced to `$true` and to `$false`. The one that reaches bare guards |
| `ReturnValue` | `return <expr>` → `return $null`, for a result nothing asserts on |
| `StringLiteral` | quoted string → `''`. Still off here: high-volume, low-signal |

They are opt-in for consumers because switching one on roughly doubles the mutant count
and lowers the score, so a repo gating on `thresholds.break` would go red purely from
upgrading. **Never add one to `$script:PSMutationDefaultOperators` without a major-version
conversation.**

Two consequences worth knowing before you touch the operator set:

- **Every operator change renumbers mutants**, so existing reports stop being valid seeds
  for `-RecheckFrom`. That is detected and refused rather than guessed at (the operator
  set is recorded in the report), but it does mean a rerun.
- **The loop-condition no-mutate zone applies to all of them.** Forcing `while (X)` to
  `$true` is an unconditional hang, not a finding. That guard is reachable for *every*
  operator, including `ConditionForcing` and `ReturnValue`, because a `$( )` subexpression
  can put an `if` or a `return` inside a loop condition — `tests/Operators.Tests.ps1`
  pins each one with the construct appearing both inside the condition and in the body.

## Layout

```
src/PSMutation.Operators.ps1   AST walk -> mutation candidates; the operator set. Pure.
src/PSMutation.Sandbox.ps1     temp sandbox: create, path-map, sweep. Side-effects.
src/PSMutation.Pester.ps1      the boundary with Pester: which one, its path, the child's contract.
src/PSMutation.Config.ps1      config resolution: subtrees, timeout, the sandbox plan. Pure.
src/PSMutation.Output.ps1      the console seam: what a line is, and the ONE Write-Host.
src/PSMutation.Report.ps1      scoring, thresholds, equivalents, the report document, the
                               summary lines, run result. Pure except for writing the JSON.
src/PSMutation.Recheck.ps1     -RecheckFrom, whole: compatibility, selection, the run.
src/PSMutation.Runner.ps1      baseline + its green guard, per-mutant execution, the loop.
src/Invoke-PSMutation.ps1      public entry point. Wiring, and nothing else.
schemas/                       the two published formats. config.schema.json is READ at run
                               time -- it is the config format, not a copy of it.
tools/                         the committed coverage, analyzer and compatibility gates.
```

`PSMutant.psm1` dot-sources these files from an explicit list. A new `src/*.ps1` must be added
to it or it is never loaded — and, because the publish step copies `src/` wholesale, a file
missing from the list still ships (see #26).

The **order** in that list does not matter, despite what this file and `PSMutant.psm1` used to
claim. Every cross-file reference sits inside a function body and resolves at call time, so
loading all eight in reverse order behaves identically — verified.

Keep it in that order regardless. It is a topological order of the real dependency graph, so
reading the list top to bottom is the cheapest description of the architecture anyone gets —
a readable convention rather than a constraint. What is *not* true is that anything enforces
the direction it expresses: the graph is acyclic today because nobody has added a shortcut
edge, not because a gate would catch one. That is #52.

**Mutants must never touch tracked source.** Everything runs in a temp sandbox and the
real files are never written, even transiently, so a hard kill cannot leave a mutated
file staged in git. `tests/EndToEnd.Tests.ps1` asserts the tracked source is
byte-identical after a run — keep that assertion.

**A covering suite must be self-contained.** The sandbox copies only `src/` and `tests/`,
so a suite that reaches for `PSMutant.psd1` at the repo root finds nothing there, proves
nothing, and leaves the file silently unmutated while still appearing in the config.
`tests/EndToEnd.Tests.ps1` imports the manifest and is therefore useless as a covering
suite; `tests/Orchestrator.Tests.ps1` dot-sources `src/` and is the covering suite for
`Invoke-PSMutation.ps1`.

**A covering suite must also be cheap.** Mutating a timeout mechanism necessarily
produces mutants that *disable* the timeout, and against a real child runspace each of
those runs until the outer per-mutant deadline -- minutes apiece, for a verdict a mocked
child reaches in seconds. So `tests/Runner.Tests.ps1` covers `PSMutation.Runner.ps1` on
its own, mocking `Get-PSMutationBoundedPesterScript` and `Get-PSMutationPesterPath` (both
now in `PSMutation.Pester.ps1`, tested for real by `tests/Pester.Tests.ps1`);
`tests/Mutant.Tests.ps1` keeps the real-runspace proofs (a genuinely non-terminating
mutant, the isolate-and-restore guarantee) and is deliberately *not* a covering suite.
Both branches of every runner decision are reachable from the mocked file, which is what
lets the self-mutation gate stay in the single digits of minutes.

## Conventions

- Branches: `feature/<name>` or `bugfixes/<name>`, PR into `main`. One issue per branch.
- **Version**: bump `ModuleVersion` in `PSMutant.psd1` in the PR. `publish.yml` refuses
  to publish when the git tag and `ModuleVersion` disagree. Bugfix → patch, new surface
  → minor.
- `CHANGELOG.md` is maintained by hand here (unlike another repository, where automation owns
  it).
- **ASCII only** in `src/`, `tests/` and `tools/`. Non-ASCII without a BOM trips
  `PSUseBOMForUnicodeEncodedFile` and fails the lint gate.
- Keep each function under the complexity ceiling; the gate is per unit, not per file.

## Practices to preserve

These are habits the codebase already has. They are written down because they are cheap to
lose in a hurry and expensive to rebuild, and because each one has already earned its keep.

- **A comment names the failure it prevents, not the mechanism.** `# Read coverage from the
  result object; steer the XML to temp so we don't litter a coverage.xml in the working
  tree` tells you why the line cannot be simplified. `# set the output path` would not.
  This applies to `src/`, to tests, and to every reason string in
  `psmutant.self.config.json`.

  **Present tense, and no issue numbers.** A comment in `src/` states the failure that
  would happen *if the line were written differently* -- not the story of how the code
  reached its current shape. "Four operators used to supply their own description, and
  three of those said nothing about what was mutated (#28)" and "the same twelve lines
  twice (#38)" are archaeology: the reader is here to change this file, not to learn what
  it looked like before. Say what breaks if they change it. `#NN` is worse than useless
  in a shipped module -- a consumer reading `Get-Help` or the source has no access to
  this repo's issue tracker, and the number decays into a token nobody can resolve.

  The same goes for **why a file exists**, or why a function sits in one file rather than
  another. That is a fact about the repo's architecture, so it belongs here in CLAUDE.md,
  where someone deciding where to put new code will look. A file docstring says what the
  file contains and which contracts it must not widen.

  These rules are why the two practices below read as they do: they govern **this file**
  and the reason strings in `psmutant.self.config.json`, which are arguments addressed to
  a maintainer, not documentation shipped to a consumer.

  The sweep that established this also found two comments that had gone *stale* -- one
  claiming `Get-PSMutationCandidate` was exported, one claiming the lint gate filtered by
  severity, both true when written and both false for months. History narration ages badly
  in exactly this way, which is the second reason not to write it.
- **A corrected reason says what it used to claim.** When a stated reason turns out to be
  wrong, the replacement records the old claim and why it was wrong rather than quietly
  overwriting it. The sandbox exclusion in `psmutant.self.config.json` has been through
  three reasons and says so. This is what stops the same wrong conclusion being
  rediscovered, and it is the single most useful thing in the repo for a new reader.
- **Every gate is a committed script, not a snippet inside a workflow.** `tools/` exists so
  that measuring by hand and measuring in CI cannot drift. Numbers that live only in
  `ci.yml` become folklore -- that is exactly how the coverage figures here went wrong.
- **A new operator is a function plus a map entry.** `Get-PSMutation*Candidate` +
  `$script:PSMutationOperatorMap`, with `New-PSMutationCandidate` as the only place a
  candidate is shaped. Three operators were added without touching the dispatcher. Keep
  that shape; do not special-case an operator inside `Get-PSMutationCandidate`.
- **Decisions live in pure units; the entry point is wiring.** A new *decision* belongs in
  `PSMutation.Config.ps1` or another pure file, where it can be unit-tested and
  self-mutated on its own terms. `Invoke-PSMutation.ps1` is one function and should stay
  one function.
- **A `$script:` constant is read only in the file that writes it.** No file reaches into
  another's module state. Two did (#38), and the fix went in opposite directions on purpose,
  which is the part worth remembering: `$script:PSMutationDefaultOperators` stayed put and
  its resolver came to it, while the sandbox subtree default moved to `PSMutation.Config.ps1`
  beside its only reader and `New-PSMutationSandbox -Subtrees` became mandatory. Ask which
  side owns the default before deciding which one moves.

  *The reason given for that asymmetry no longer holds. It said the operator default could
  not move because `Get-PSMutationCandidate` is **exported** with it as a parameter default,
  so moving it would break a public promise. #48 un-exported that function, and the promise
  went with it. What is left is a weaker but real argument -- the operator vocabulary and its
  default belong in the file that owns the operators -- and if you ever want the two defaults
  symmetric, nothing external stops you now. Recorded rather than rewritten, per the practice
  above: the old reason was true when written and is worth knowing was load-bearing.*

  *This rule also used to say the cross-file reads "work only because of dot-source order".
  That was wrong -- they are inside function bodies and resolve at call time, so
  reverse-loading every file behaves identically.*
- **A file's docstring is a claim about its contents, and a guard lives with its subject.**
  When you add a function, either it fits the file's stated purpose or that file is the wrong
  home -- and if you move it, fix the docstring and the layout table above in the same commit.

  The rule for *where* is the subject, not the grammatical form: `Assert-PSMutationPester`
  guards which Pester is loaded, so it sits in `PSMutation.Pester.ps1` beside the resolution
  it shares; `Assert-PSMutationBaselineGreen` judges a baseline, so it sits beside
  `Invoke-PSMutationBaseline`. Grouping by form instead -- one file for "the guards" -- is how
  a `utils.ps1` starts, and it would have split the Pester guard from the Pester resolution
  that #38 had just finished deduplicating. Issue #45 proposed exactly that grouping; this is
  a deliberate departure from it.
- **Add a new pinned dependency to `.github/pins.env`, never inline.** Every workflow loads
  that file into its environment after checkout and asserts each key arrived, so the gates
  cannot analyse with different analyzers or test against different Pesters. `PSSA_PATHS`
  lives there too, so the lint gate and the required code-scanning check cannot disagree
  about what they look at. Before this existed the two coincided only because
  PSScriptAnalyzer ignores non-PowerShell files -- a coincidence, not an agreement.

  The one thing the file cannot hold is a `uses:` action SHA, because `uses:` does not
  expand variables. Those stay written out per workflow, all SHA-pinned with the version in
  a trailing comment, and have to be kept in step by hand.

  **Install a pinned module only if it is not already there, then assert it is.** Both
  workflows now do this. An unconditional `Install-Module -Force` collides with what the
  runner image already ships: the install warns "currently in use" and carries on, and the
  tool then fails somewhere else entirely -- `code-scanning.yml` died inside
  `Invoke-ScriptAnalyzer` with a bare "Object reference not set to an instance of an object"
  naming neither a file nor a rule, on a branch that was green, and a re-run with no code
  change passed. Agreeing on the version is not enough if the workflows disagree about how
  they get it.
- **A pass/fail decision in `tools/` belongs in `tools/GateDecisions.ps1`, behind a pure
  function with tests.** A gate that silently stops being able to fail looks exactly like a
  green build, and these are the scripts that decide whether every other number here is true.
  The decisions are arithmetic and string comparison -- free to test, and where an inversion
  hides.

  The orchestration around them is deliberately **not** tested or mutated, and that is a
  decision rather than an omission. Three of the four scripts are side effects end to end
  (run Pester, stage a package, spawn a child process), so a covering suite would have to
  execute them and each mutant would cost a full gate run -- the same wall that makes
  `Sandbox.ps1` impossible to self-mutate. `tools/` is also outside `sandboxSubtrees`, so it
  is not copied into the sandbox at all. Coverage stays measured over `src/`; the gates are
  proven by running for real in CI.

  *This bullet lived under "Practices to adopt" citing #27 after #27 had been closed, which
  made a finished mechanism read as owed work. Two of that section's four entries were done;
  when you close an issue whose rule is written there, move the rule here in the same PR.*
- **A workflow gets a concurrency group and a `timeout-minutes`.** All three have both. A
  superseded run that keeps going is waste, and a wedged runner holds a **required** check
  pending for the six-hour default, which blocks every merge behind it.

  `cancel-in-progress` is the part to think about rather than copy: `ci.yml` and
  `code-scanning.yml` cancel on pull requests, because a superseded run answers a question
  nobody is asking any more. `publish.yml` must **never** cancel -- a half-finished publish
  is a gallery version that cannot be withdrawn -- so its group serialises releases and a
  second tag waits. #42 fixed only `ci.yml`; the other two each went on missing one of the
  two guards until this was written down.
- **The public surface is `Invoke-PSMutation` and the report JSON. Nothing else.** Two more
  functions used to be exported, and between them trafficked a nine-field `[pscustomobject]`
  that nothing declared, tested as a contract or versioned -- discoverable only by running the
  function and reading the output, and unchangeable once someone had. Neither was ever
  mentioned in the README, and `Set-PSMutationText` had one caller, inside this module (#48).

  Un-exporting did not dissolve that contract, it **relocated** it: the mutant rows in the
  report are a projection of the same internal object. So both surfaces are now pinned by
  tests that assert the exact field list -- the run result in `Report.Tests.ps1`, the report's
  top-level keys there too, and the mutant row in `Runner.Tests.ps1`, where it is actually
  built rather than merely serialised. Widening any of the three should fail a test and be a
  decision, not a side effect of an internal rename.

  **A verdict travels with its reason.** `ExitCode` 1 means either a stale equivalence
  declaration or a score under `thresholds.break`, and for a long time nothing in the returned
  object told them apart -- so a run scoring 100% with one stale declaration failed with whatever
  the workflow had hardcoded, which was "below the break threshold", which was false. The
  explanation existed in exactly two places a CI run destroys: a summary line `-Quiet` suppresses,
  and a JSON file nothing uploads.

  `FailureReason` is now on the result, and **`Get-PSMutationExitCode` is derived from
  `Get-PSMutationFailureReason`** rather than deciding the same two rules again. Two independent
  rule sets would drift the first time a third failure mode arrived, one of them silently keeping
  the old vocabulary. Stale is reported before threshold when both fire: a score computed with a
  false declaration in it is not one to act on, so "below threshold" would send the reader to write
  tests when the config is what needs editing.

  **Both result shapes now share `Mode`, `ExitCode` and `FailureReason`.** They shared no field at
  all, and the absence failed in both directions from one cause: `if ($result.ExitCode -ne 0)`
  compared `$null` against `0` and threw on a successful recheck, while `exit $result.ExitCode`
  became `exit $null`, which is `0`, and passed with every survivor still alive. A recheck
  `ExitCode` is always `0` -- it applies no thresholds by design, and a verdict over a subset
  somebody chose is the filtered number this project exists to stop people quoting.

  `Id` is **not** contractual. It is a walk position, it has changed once already (#29), and
  its only consumer is this project's own `-RecheckFrom`.

  When someone asks for "what would you mutate?", the answer is a rendering this module
  controls -- #10's `-ListOnly` -- not a re-export of the AST walker.
- **An unrecognised config key is an error, and the message names the key.** Every key is
  checked against `$script:PSMutationConfigKeys`, every `thresholds` sub-key and every
  operator name likewise, and the message offers the nearest valid name within two edits --
  two being what a transposition costs, beyond which a suggestion is a guess that sends the
  reader to fix a key that was never the problem.

  An **error**, never a warning: a warning in a CI log is indistinguishable from silence,
  and every failure in this class made the gate weaker while the run stayed green.
  `thresholds.brake` left the break gate unable to fail; a misspelled operator was dropped
  and then written into the report as though it had run, handing back the vacuous score #5
  exists to prevent. `_`-prefixed keys are exempt, because JSON has no comments and the
  shipped configs use them.

  **The type is checked too, and the schema is what checks it.** A wrong type does not
  error in PowerShell, it produces a confident wrong answer: a non-numeric `timeoutFactor`
  makes the timeout arithmetic yield *nothing*, and a timeout expiry is scored as a
  **kill**. `coveredLinesOnly` is milder and the same shape of bug -- any non-empty string
  is `$true`.

  **A `tests` key is checked differently, because the schema cannot check it.** Its keys are
  arbitrary file paths, so `additionalProperties` describes their VALUES and says nothing about
  their names -- and `"_comment": "prose"` is schema-VALID, because a bare string is a legal
  single test file. JSON Schema also cannot say "this key must appear in that array". So the rule
  lives in code and only in code: a `tests` key must name a file in `mutate`.

  It earns that place by what it catches. A key matching nothing was accepted, and did three
  quiet things: its test files still joined the baseline's set, its entry covered no mutant, and
  whichever file it was MEANT to name had no entry -- so every one of that file's mutants fell
  back to running the whole suite. Nothing failed. The run just got slower while the score stayed
  believable, which is #141's cost arriving by accident and unseen.

  It is checked in `Get-PSMutationSandboxPlan` rather than `Assert-PSMutationConfig`, beside the
  duplicate-mutate check and for the same recorded reason: the validator sees config STRINGS, and
  two spellings of one path are only equal once resolved.

  A `_`-prefixed key gets its own sentence in the message. Those are comments at the **top level**
  only -- somebody who has just written `_comment` beside `mutate` has no reason to expect the
  rule to change one level down, and this was found by doing exactly that.

  **Adding a key means editing `schemas/v1/config.schema.json`, and that is the whole list.**
  The key names, the threshold sub-keys and every type are read back out of the schema at
  run time, so there is no PowerShell copy to keep in step. Update the README table in the
  same commit; that one is still on you. (#24, #83, #84)
- **Never compare a raw config value; compare a resolved one.** Both of PowerShell's
  null coercions fail *open* -- `$anyNumber -ge $null` is `$true`, and `[bool]$null` is
  `$false` -- so an unresolved config value does not produce an error, it produces a
  confident wrong answer in whichever direction flatters the run.

  Both have already shipped. `[bool]$cfg.coveredLinesOnly` silently meant "mutate uncovered
  lines too" (#25), and `$Summary.Score -ge $Thresholds.high` printed **every** score green,
  `0%` included, for any config without colour bands (#40). Each config value gets a resolver
  in `PSMutation.Config.ps1` with a documented default. The one legitimate exception is a
  value whose *absence is meaningful* -- `thresholds.break` being unset means report-only --
  and that one guards with an explicit `$null -ne` before it compares.

  A corollary worth stating separately: a resolver tests `$null -ne`, not truthiness, whenever
  `0` or `''` is a legal setting. `Get-PSMutationScoreBand` has to, because a band of `0`
  means "never colour this red"; `Get-PSMutationOperatorList` deliberately does not, because
  an empty operator list means "use the defaults".
- **A documented default is pinned by a test, not by prose.** `tests/Config.Tests.ps1` has a
  Describe asserting every default the README config table claims, so the table cannot drift
  from the resolvers again. It had drifted twice: `sandboxSubtrees` was documented as a value
  the code never had, and `coveredLinesOnly` was documented `true` while the code had no
  resolver at all and `[bool]$null` gave `$false`.

  This is the enforceable half of "check the docs against the code". The rest still is not
  enforced -- when you change a threshold, an operator set or a message, grep `README.md`,
  `CLAUDE.md` and `examples/psmutant.config.json` in the same commit. (#25)
- **Both analyzer gates run one committed script, `tools/Invoke-PSMutantAnalyzer.ps1`.** They
  used to spell the invocation out inline in each workflow, sharing `PSSA_PATHS` and the settings
  file but not the severity: `ci.yml` filtered to `-Severity Error, Warning` and
  `code-scanning.yml` -- a **required** check -- did not. So every Information-severity rule was
  invisible to the gate that *fails* and visible to the gate that *blocks*, and a finding in that
  band passed lint locally and in CI before surfacing where nobody was looking. It happened twice
  in one PR before anyone noticed the band existed (#76).

  There is **no `-Severity` filter** now. Rules are excluded by name in
  `PSScriptAnalyzerSettings.psd1`, with a reason -- a decision someone made -- where a severity
  filter mutes a whole band nobody decided about. Run `./tools/Invoke-PSMutantAnalyzer.ps1`
  before pushing; it reads `PSSA_PATHS` and `PSSA_VERSION` from `.github/pins.env` itself, so by
  hand and in CI are the same run with no setup step.

  **It throws on a finding, so the exit code is the answer.** It did not always: it returned
  findings and exited 0 either way, the verdict lived in `ci.yml`, and running it was therefore
  not the same as passing it -- a branch was reported analyzer-clean three times before CI failed
  it on both legs. Two of the three committed gate scripts failed loudly and this one did not,
  which is what made the trap invisible. `-PassThru` returns the findings without failing, for
  `code-scanning.yml`, which uploads them rather than gating on them; the decision itself is
  `Get-PSMutantLintFault` in `GateDecisions.ps1`, with tests, like every other gate decision.

  It refuses to analyse nothing, which is the failure that would otherwise look identical to
  success: an empty `PSSA_PATHS` would have both gates report clean over zero files. The pin
  parsing behind that lives in `GateDecisions.ps1` with tests, for the same reason.
- **An equivalence declaration is a checkable claim, not a mute button.** It carries a
  written argument someone can disagree with, and the run fails if it is ever killed, stops
  matching a mutant, **or matches more than one**. Before declaring one, verify the claim --
  run the code without the guard and confirm the output is identical.

  The key is `File:Function:Description`, with `File:Line:Description` still accepted so
  existing configs keep working -- and it is the only form available for code outside any
  function. Prefer the function form: a line number moves whenever anything above the mutant
  is edited, and the declaration then goes stale although the mutant has not changed. That
  happened on the first run after the feature shipped and twice more while fixing #28 (#3).

  The function form is not universally better, which is worth knowing before reaching for it:
  a function containing three `if ($isDeclared)` guards makes
  `Get-PSMutationScore:$isDeclared -> $true` match all three, so it is refused as ambiguous
  and that declaration has to stay keyed by line. This repo has exactly one such case, and
  its reason string says so.

  The ambiguity arm was the hole (#28). A declaration
  argues about ONE mutant, so matching several is not a broader claim -- it is an ambiguous
  one that excludes mutants nobody argued about, silently, while stale-detection stays quiet
  because the key still matches something. Two mutants can share a key honestly:
  `[math]::Min($prev[$j] + 1, $curr[$j - 1] + 1)` puts two `1 -> 2` on one line, and this
  repo has nine such ties. Undeclared ties are fine and are left alone; only a declaration
  over one is refused.
- **A description is derived from the source, never written by the operator.**
  `New-PSMutationCandidate` builds `<original> -> <mutated>` and takes no `-Description`.
  Four operators used to supply their own and three said nothing about what was mutated
  (`remove negation`, `return value -> $null`, `condition -> $false`), which is what made
  identical keys possible in the first place. Deriving it centrally means a NEW operator
  cannot reintroduce the problem, where the old arrangement left that entirely to whoever
  wrote the call.

  It is whitespace-collapsed, because an extent can span lines and a newline in a console
  line or a config key does not survive being pasted back, and truncated at 120 characters.
  That number is measured, not chosen: over this repo's source with every operator on, 120
  produces exactly as many distinct descriptions as no truncation at all, 80 loses a few and
  60 noticeably more.
- **A "this is filtered" assertion pairs the filtered case with a kept one.** A fixture that
  lacks the construct being filtered makes the assertion pass without proving anything.
  This is not hypothetical: two such tests were written and shipped green in the #5 work,
  and only the self-mutation gate caught them.
- **Covering a predicate is not covering its application, and both gates will tell you it
  is.** `Test-PSMutationSandboxAbandoned` was at 100% line coverage and survived every
  mutant, and the pipeline stage in `Clear-PSMutationStaleSandbox` that *called* it could
  still be deleted with all 246 tests green -- reverting issue #2, a fixed bug, in silence.
  Coverage saw the predicate's lines execute; self-mutation mutated the predicate's logic.
  Neither gate has any way to notice that the caller ignores the answer.

  So exercise a filter **through the real entry point**, with one item that survives and one
  that does not in the same call. Two items, because a single-outcome fixture passes just as
  well against a stage that was deleted. This is the strongest routine check in the repo and
  it has exactly this blind spot; nothing else will catch it for you. (#31)
- **A new file-to-file edge in `src/` is a decision, and `tests/Layering.Tests.ps1` makes you
  make it.** Every other gate is blind to DIRECTION: a shortcut call from `Operators.ps1`
  into `Report.ps1` still reaches full coverage and still survives self-mutation. The test
  holds an allowlist of file-to-file *relationships* -- one entry per pair, not per call
  site -- so adding a call between files that already have an edge is free and adding the
  first one is deliberate.

  It fails in **both** directions. An undeclared edge fails, and so does a declared edge the
  code no longer has: an allowlist describing relationships that were dropped is a document
  nobody can trust, and it silently readmits an edge later. Same argument as a stale
  equivalence declaration.

  It also asserts the graph is **acyclic**, which the allowlist alone cannot give you -- two
  edges each reasonable on their own review make a cycle between them, and nobody reviewing
  the second is looking at the first.

  Two blind spots are stated in the file rather than left to be rediscovered: the child
  runspace script is a here-string, so the parser never sees inside it, and the operator map
  is dispatched through `& $fn`, whose callee is a variable. Both are within-file today.

  The ordered list in `PSMutant.psm1` is not enforcement and never was -- every cross-file
  reference resolves at call time, so reverse-loading behaves identically.
- **A test's title names what the test calls.** The test titled "does NOT sweep the sandbox
  of a concurrently running process" never called the sweep. It was not wrong about anything
  -- it asserted a true fact about the predicate -- but its title claimed coverage of the
  behaviour above it, which is what let the gap sit unnoticed. When a title says a *verb*,
  the body invokes that verb.

- **A resolved number gets a floor that means something, and the floor refuses rather than
  clamps.** The per-mutant budget is `max(floor, baseline x factor)`, and it must be at least as
  long as the unmutated suite took -- not merely non-zero. A 1-second budget against a 3-second
  baseline times out every mutant by construction, exactly as a 0-second one does, so a minimum
  of 1 would only move the boundary. It throws instead of substituting a working value, because
  the substituted number would then be written into the report as though the config had asked
  for it -- a silent substitution in the same place a silent substitution caused the bug.

  This is the project's own headline failure turned inward: every mutant dying on the clock is
  scored Killed, so the run reports a perfect score over tests that never ran.

- **Every path in a config is mapped into the sandbox, and the mapper checks where the path
  landed.** Not whether it contains `..` -- `src/../src/a.ps1` is `src/a.ps1` and was never
  ambiguous -- but whether the mapped result is still inside. The caller writes to whatever the
  mapper returns, so a path that escapes is mutated in the directory the sandbox exists to
  replace, and the promise that a hard kill cannot leave a mutant in tracked source then rests
  on a `finally` rather than on the real files never being opened for write.

  The check lives in the mapper because that is the single choke point both `mutate` and `tests`
  pass through, and because it runs before the baseline, so a bad path fails immediately instead
  of surfacing later as a red baseline.

- **Record what you could not break, and check the negative for vacuity before believing it.**
  A confirmed negative is worth as much as a finding and costs as much to establish, and without
  it the same ground gets re-dug. The sandbox sweep deletes the *name* and not the target, so a
  planted symlink does not redirect it; a hard kill leaves tracked source byte-identical **by
  construction** rather than by cleanup, since the real files are never opened for write; no
  config value reaches an eval sink; zero mutants scores 0% and exits 1, not a vacuous 100%; two
  concurrent runs never sweep each other's live sandbox. The full list is in `ROADMAP.md` on
  the long-lived `docs/sequencing` branch, deliberately **not** on `main`: the roadmap is a
  working artefact rather than a description of the repo, and two copies of a plan drift.
  Confirming a negative belongs there whether or not it is convenient to reach.

  The vacuity check is the part that is easy to skip. "I changed X and nothing broke" means
  nothing until you have also confirmed that a change which *should* break it does -- a fixture
  that cannot fail proves the same thing about every hypothesis.

- **The suite runs in two orders here, and both are checked.** `Invoke-Pester ./tests` discovers
  files alphabetically; the mutation baseline runs the mapped covering suites in the order
  `psmutant.self.config.json` lists them. Those orders differ, and they have already disagreed:
  `Output.Tests.ps1` sorts first and its `AfterEach` cleared an environment variable, so
  `Recheck.Tests.ps1` saw the ambient value in config order and the cleared one alphabetically. The
  suite was green locally and red in the gate, and three CI rounds went into finding out why.

  `tools/Test-PSMutantOrderIndependence.ps1` runs the suite **reversed** and compares the
  environment before and after. The two halves fail on opposite ends of the same problem, which is
  why both are there: the reversed run catches a dependency by its **symptom** and is a probe
  rather than a proof -- one more permutation, not all of them -- while the environment comparison
  catches the **cause** and is direction-blind, firing on the file that leaks whether or not
  anything reads it yet. Reversal alone can miss exactly that, because it moves the reader in front
  of the leaker as readily as behind it.

  **Two other kinds of state were tried and rejected, and the measurements are in the script.** The
  working directory cannot fire, because Pester restores it around a run -- verified both with a
  test that wanders off via `Set-Location` and with a full run of this suite. Global variables fire
  on a *clean* suite: this one already leaves `d`, `p`, `root` and `LASTEXITCODE` behind, so
  keeping the check would mean an allowlist that grows with the tests it is watching. A check that
  cannot fire and a check that always fires are the same defect wearing different clothes; neither
  was written and left in.

  The failure message names keys and **never values**. An environment variable holds tokens as
  often as it holds flags, and this message is printed into a build log anyone can read.

- **Review by lens, not by file.** A pass over the same files with the same question finds what
  the last one found. Pointing an unused question at the project -- what does a hostile local
  user get, what does this cost per mutant, what does a monorepo layout do to it -- returned
  seventeen issues at once, two of them outranking everything already in the backlog. Both were
  in code that had been read many times and was at 100% coverage and 100% self-mutation.

## Practices to adopt

Gaps in how the repo is maintained, as rules rather than as a backlog. Each has a tracked
issue; the rule is what stops the next instance, and it moves up to "Practices to preserve"
in the PR that closes its issue.

- **A config path gets a resolver, exactly like every other config value** (#100, #103, #104,
  #109, #110). This is one missing concept, not five bugs. Every other config value got a
  resolver with a documented default; paths did not, so `..` copies outside the sandbox and is
  never cleaned up, a `[` fails with a message naming neither the file nor the cause,
  `reportPath` is documented optional and is in practice mandatory, and a path that does not
  survive into the sandbox is diagnosed as a red baseline. Fixing them separately produces five
  guards in five places.

- **A number in the report answers for what it excluded** (#96, #7, #59). The coverage filter can
  remove a whole `mutate` file from the score with nothing recording that it did, and a
  timed-out mutant is counted as Killed. Both make the score go **up**. Anything that drops a
  mutant, or classifies one without observing a test fail, has to be visible in the report next
  to the number it changed.

- **A failure that leaves the run green is worse than one that fails** (#98, #55). The report
  write fails non-terminatingly and the run still returns `Score=100, ExitCode=0`; nothing
  asserts that Pester's result is two-valued, though the mutant classifier depends on it. Every
  fake-perfect-score bug in this project's history is this shape.

- **The unit of isolation is the run, not the process** (#53, #22, #95, #105). Fusing ownership
  and liveness into `$PID` is why the sandbox file cannot be self-mutated, why a planted symlink
  at a predictable path is reachable at all, and why `psmut-coverage-$PID.xml` accumulates in
  temp forever with a sweep that structurally cannot match it. Four issues, one identity.

- **A guarantee proven on one OS is proven on one OS** (#32, #35). CI runs Linux only, and the
  path layer carries the headline guarantee. Every fixture is also PSMutant's own flat
  `src/`+`tests/`, so the consumer-shaped layout the module promises to support is never
  executed.

- **Assert the exact answer when the fixture has one** (#36, #43). End-to-end counts are asserted
  as open inequalities over a fixture whose answer is exact, which passes against a run that
  produced twice what it should. Test files sharing `$script:` state across blocks means a
  filtered run fails on tests that are fine -- and a suite that cannot be run in part cannot be
  bisected.

- **A per-mutant cost is paid once per mutant** (#101, #102, #107, #108, #62). Each mutant reads
  and writes the whole file twice, re-imports Pester into a fresh runspace, and -- with no
  `tests` entry -- runs the entire suite. None of it is wrong; all of it multiplies. Measure
  before choosing a mechanism, and note that the timeout is derived from a *serial* baseline, so
  parallel evaluation (#1) would manufacture false kills on top of whatever it saved.

- **A pin nobody watches has already drifted** (#89, #94). `.github/pins.env` and the `uses:` SHAs
  go stale silently, and `ci.yml` declares no `permissions` block, so it executes third-party
  code with a write-scoped token.

- **A run needs a context object before it needs another mode** (#63, #54, #56). Each mode
  currently adds another long parameter list threaded through the orchestrator; the run result
  carries a verdict without its reason and has no field common to both modes; and
  `Get-PSMutationScore` validates the whole config while scoring a subset, so per-file scores
  (#6) cannot reuse it. Three of the queued features push through this seam, and it is cheaper
  to widen once than three times.

## Writing tests here

The house style is a comment naming the *failure the test prevents*, not a restatement
of the assertion. Choose inputs that **discriminate**: a fixture where a guard's two
halves disagree, a collection of exactly one where the code says `-gt 0`, a value that
rounds differently at one decimal than two. A test that passes against the broken
version proves nothing — when fixing a bug, run the new test against the old code and
confirm it fails.

Traps that have bitten in this repo specifically:

- `Should -BeLike '*[3/10]*'` — in a wildcard, `[3/10]` is a **character class**. Use
  `Should -Match ([regex]::Escape(...))`.
- A property getter that throws yields `$null` in PowerShell rather than raising, so a
  `try/catch` around it never runs. Test the value, not the exception.
- **Help may only point at topics that ship.** The `.PARAMETER ConfigFile` block said "see
  about_PSMutant / the README" and there was no such topic -- no `en-US/`, no `*.help.txt` -- so a
  gallery consumer running `Get-Help Invoke-PSMutation -Full` was sent nowhere. `tests/EndToEnd.Tests.ps1`
  now scans the resolved help for `about_*` names and fails on any the package does not provide,
  paired with a case that proves the search finds things, because the list it iterates is empty
  today and an empty loop passes whatever it is asked.

  **An `about_` topic was considered and refused.** It would be a second place the config format is
  described, and this project removed the last of those on purpose: `schemas/v1/config.schema.json`
  IS the format, read at run time, with no PowerShell copy to fall out of step. The help now points
  at the schema, which ships in the package and cannot describe a config the module would reject.

- **A `<# #>` block immediately before `function` becomes that function's help.** So a
  file header written that way SHADOWS the comment-based help inside the body, and
  `Get-Help` serves the file's architecture notes instead of the documentation written for
  users -- synopsis, parameters and examples all. Nothing in the source looks wrong, and
  the source is not wrong; only the resolution is. File headers in `src/` are `#` line
  comments for that reason, and `tests/EndToEnd.Tests.ps1` asserts the public help resolves
  to the real thing.
- **A `$null` in a `-ForEach` case hashtable does not bind the variable.** `@{ Value = $null }`
  runs the body with `$Value` unset, so the case silently exercises whatever the previous case
  left behind rather than the null it names. A null arm tested that way is not tested: the
  self-mutation gate found one by flipping `-or` to `-and` in a guard whose null branch nothing
  reached. Test `$null` in its own `It`, where it is passed explicitly.
- **Pester 6 removed mock fall-through.** A call that matches none of your
  `-ParameterFilter` mocks no longer runs the real command — it throws. Any command
  mocked with a filter needs either a default mock or a filter for every shape of call
  the code under test makes. `Assert-PSMutationPester` calls `Get-Module` two different
  ways and needs both.

## Assertion style

The suite is fully on the Pester 6 `Should-*` commands (hyphen, no space), and
`Should.DisableV5 = $true` is set in `ci.yml` and in the coverage script so the classic
syntax is an **error**, not a style note.

**There is no `Should-NotThrow`, and that is not a gap to work around.** An unhandled
exception fails the test on its own, so "does not throw" asserts nothing — v6 leaves it
out on purpose. Call the thing directly and assert what it actually did:

```powershell
# not this -- the only claim is "no exception", which the runner already makes
{ Assert-PSMutationPester } | Should -Not -Throw

# this -- accepting the session means taking the already-loaded branch, so say that
Assert-PSMutationPester
Should-NotInvoke Import-Module
```

Where a guard has no observable output, assert the absence of it
(`Should-BeNull -Actual (Assert-PSMutationBaselineGreen ...)`); where it has a
postcondition, assert that (`Should-BeFalse -Actual (Test-Path $gone)`).

**Fixture source stays classic.** The here-strings written out as a consumer's test
files — in `tests/EndToEnd.Tests.ps1`, `tests/Mutant.Tests.ps1` and
`tools/Test-PSMutantPesterCompatibility.ps1` — must keep `Should -Be`, because the
compatibility guard runs one of them under **Pester 5.8.0**, where the `Should-*`
commands do not exist. `DisableV5` cannot reach them: every one of those files is
executed by a *different* `New-PesterConfiguration` built inside the module. Do not
"finish the migration" by converting them.

Two traps worth knowing when adding assertions:

- `Should-Be` **errors** if the expected value is a collection — use
  `Should-BeCollection`. This bites on a parenthesised range (`(1..$n)`) just as much as
  on `@(...)`.
- `Should-BeCollection` **ignores order**, and has no switch to make it strict — its only
  parameters are `Actual`, `Expected`, `Because` and `Count`. `51,124,67,101` passes against
  an expected `51,67,101,124`. That is right for a set, and silently vacuous when the *order*
  is the claim: a test written that way passed against the exact defect it was added to catch
  (#29). When sequence matters, join both sides and use `Should-Be`.
- `Should-BeTrue`/`Should-BeFalse` are **strict** in v6 (`$true`/`$false` only), where
  the classic ones accepted anything truthy/falsy. Every use here is a real boolean, so
  strict is correct — reach for `Should-BeTruthy`/`Should-BeFalsy` only if that changes.
