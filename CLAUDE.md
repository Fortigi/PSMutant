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
| `PSMutation.Pester.ps1` | 100% | yes |
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
src/PSMutation.Operators.ps1   AST walk -> mutation candidates; the operator set. Pure.
src/PSMutation.Sandbox.ps1     temp sandbox: create, path-map, sweep. Side-effects.
src/PSMutation.Pester.ps1      the boundary with Pester: which one, its path, the child's contract.
src/PSMutation.Config.ps1      config resolution: subtrees, timeout, the sandbox plan. Pure.
src/PSMutation.Report.ps1      scoring, thresholds, equivalents, report JSON, run result. Pure.
src/PSMutation.Recheck.ps1     -RecheckFrom, whole: compatibility, selection, the run.
src/PSMutation.Runner.ps1      baseline + its green guard, per-mutant execution, the loop.
src/Invoke-PSMutation.ps1      public entry point. Wiring, and nothing else.
tools/                         the committed coverage and compatibility gates.
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
  its resolver came to it, because `Get-PSMutationCandidate` is **exported** with that
  constant as a parameter default and moving it would break the public promise; the sandbox
  subtree default had no such claim on it, so it moved to `PSMutation.Config.ps1` beside its
  only reader and `New-PSMutationSandbox -Subtrees` became mandatory. Ask which side owns the
  default before deciding which one moves.

  *This rule used to say the cross-file reads "work only because of dot-source order". That
  was wrong -- they are inside function bodies and resolve at call time, so reverse-loading
  every file behaves identically. Recorded rather than deleted, per the practice above.*
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
- **An equivalence declaration is a checkable claim, not a mute button.** It carries a
  written argument someone can disagree with, and the run fails if it is ever killed or
  stops matching a mutant. Before declaring one, verify the claim -- run the code without
  the guard and confirm the output is identical.
- **A "this is filtered" assertion pairs the filtered case with a kept one.** A fixture that
  lacks the construct being filtered makes the assertion pass without proving anything.
  This is not hypothetical: two such tests were written and shipped green in the #5 work,
  and only the self-mutation gate caught them.

## Practices to adopt

Gaps in how the repo is maintained, as rules rather than as a backlog. Each has a tracked
issue; the rule is what stops the next instance.

- **Check the docs against the code when you change behaviour.** Nothing enforces this, and
  it has already failed twice: CLAUDE.md described a coverage trap that was misattributed
  for months, and `README.md` still documented a `sandboxSubtrees` default the code never
  had. When you change a default, a threshold or an operator set, grep `README.md`,
  `CLAUDE.md` and `examples/psmutant.config.json` for it in the same commit. (#25)
- **Validate a new config key, and make a typo name the config.** Keys are read straight off
  the parsed JSON, so a misspelling is not rejected -- it resolves to `$null` and fails much
  later somewhere unrelated. `mutat` for `mutate` currently ends in
  `Access to the path '...\psmut-sandbox-<pid>' is denied`. Any key you add should be
  validated where the config is resolved, with a message that names the key. (#24)
- **Add a new pinned dependency to `.github/pins.env`, never inline.** Every workflow loads
  that file into its environment after checkout and asserts each key arrived, so the gates
  cannot analyse with different analyzers or test against different Pesters. `PSSA_PATHS`
  lives there too, so the lint gate and the required code-scanning check cannot disagree
  about what they look at. Before this existed the two coincided only because
  PSScriptAnalyzer ignores non-PowerShell files -- a coincidence, not an agreement.

  The one thing the file cannot hold is a `uses:` action SHA, because `uses:` does not
  expand variables. Those stay written out per workflow, all SHA-pinned with the version in
  a trailing comment, and have to be kept in step by hand.
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
  proven by running for real in CI. (#27)

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
