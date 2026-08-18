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
| Lint | PSScriptAnalyzer over `src/`, `tests/`, `tools/`, `-Severity Error, Warning` only |
| Unit tests | whole `tests/` directory, must be 0 failures |
| Coverage | `tools/Measure-PSMutantCoverage.ps1` — **100%** over `src/`, enforced |
| Complexity | sibling module PSComplexity, 15 cyclomatic / 15 cognitive per unit |
| Self-mutation | `Invoke-PSMutation -ConfigFile ./psmutant.self.config.json`, break = 100 (~6 min: 303 mutants) |
| Pester compatibility | `tools/Test-PSMutantPesterCompatibility.ps1` — a real mutation run under the Pester version the suite does *not* use |

---

## Pester: one version for the estate, any version for consumers

Two different things. Conflating them is what caused #16.

- **The test estate** is pinned to exactly **6.1.0** — `ci.yml`, `publish.yml`, and local
  development. Every CI step runs `Import-Module Pester -RequiredVersion` rather than
  letting the name resolve, so CI and your machine cannot end up on different Pesters.
  Bumping it means changing `ci.yml` (`PESTER_VERSION`), `publish.yml`, and this file
  together.
- **The module** promises `Pester >= 5.0.0` in its manifest and has to drive whatever the
  consuming repo already has. The pin above narrows nothing about that.

The second promise is the fragile one, because it only breaks when **two** versions are
installed:

- A child runspace resolves `Pester` by **name** and gets the newest installed, not the
  one this process loaded. Assemblies are per-process, so a mismatch kills the child
  outright. Fixed by `Get-PSMutationPesterPath`, which hands the child the loaded
  module's **path**; the child script itself lives in `Get-PSMutationBoundedPesterScript`
  so that contract sits in one named place.
- `Import-Module Pester -MinimumVersion 5.0.0` is **not** a no-op when a satisfying Pester
  is already loaded — PowerShell re-resolves the name to the newest installed and
  collides. Fixed by `Assert-PSMutationPester`, which accepts what is already loaded.

**Why this mattered more than a red suite.** A dead child returns no verdict, and
`Invoke-PSMutant` reads anything-but-`Passed` as a kill. So on any machine with two
Pesters the *shipped* module scored **every** mutant Killed and reported a silent,
perfect, entirely fake 100% — no error, no failed test. `Invoke-PSBoundedPester` now
throws instead of returning nothing, and the compatibility guard exists to make that
particular lie impossible: it runs a real mutation over a fixture whose deliberately weak
test **must** leave survivors, and fails if everything comes back killed.

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
| `PSMutation.Config.ps1` | 100% | yes |
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
src/PSMutation.Operators.ps1   AST walk -> mutation candidates. Pure.
src/PSMutation.Sandbox.ps1     temp sandbox: create, path-map, sweep. Side-effects.
src/PSMutation.Config.ps1      config resolution + run guards + sandbox plan. Pure.
src/PSMutation.Report.ps1      scoring, thresholds, equivalents, report JSON. Pure.
src/PSMutation.Recheck.ps1     -RecheckFrom: compatibility + candidate selection. Pure.
src/PSMutation.Runner.ps1      baseline, per-mutant execution, the Pester pin, the loop.
src/Invoke-PSMutation.ps1      public entry point: the Pester guard and the wiring.
tools/                         the committed coverage and compatibility gates.
```

Load order is fixed in `PSMutant.psm1` — pure layers first, runner and entry point last.
A new `src/*.ps1` must be added there or it will not load.

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
its own, mocking `Get-PSMutationBoundedPesterScript` and `Get-PSMutationPesterPath`;
`tests/Mutant.Tests.ps1` keeps the real-runspace proofs (a genuinely non-terminating
mutant, the isolate-and-restore guarantee) and is deliberately *not* a covering suite.
Both branches of every runner decision are reachable from the mocked file, which is what
lets the self-mutation gate stay in the single digits of minutes.

## Conventions

- Branches: `feature/<name>` or `bugfixes/<name>`, PR into `main`. One issue per branch.
- **Version**: bump `ModuleVersion` in `PSMutant.psd1` in the PR. `publish.yml` refuses
  to publish when the git tag and `ModuleVersion` disagree. Bugfix → patch, new surface
  → minor.
- `CHANGELOG.md` is maintained by hand here (unlike IdentityAtlas, where automation owns
  it).
- **ASCII only** in `src/`, `tests/` and `tools/`. Non-ASCII without a BOM trips
  `PSUseBOMForUnicodeEncodedFile` and fails the lint gate.
- Keep each function under the complexity ceiling; the gate is per unit, not per file.

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
- `Should-BeTrue`/`Should-BeFalse` are **strict** in v6 (`$true`/`$false` only), where
  the classic ones accepted anything truthy/falsy. Every use here is a real boolean, so
  strict is correct — reach for `Should-BeTruthy`/`Should-BeFalsy` only if that changes.
