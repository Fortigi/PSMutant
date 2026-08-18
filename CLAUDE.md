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
with the reason**, rather than letting the number quietly sag. There is one such file
today and it is documented below.

Every exclusion in `psmutant.self.config.json` carries a written reason. If you add
one, write why — and re-read the existing reasons before trusting them, because one of
them ("shared sandbox") described a bug that has since been fixed.

---

## Gates

CI (`.github/workflows/ci.yml`) runs, in order:

| Gate | What it is |
|---|---|
| Import smoke | module loads, `Invoke-PSMutation` is exported |
| Lint | PSScriptAnalyzer, `-Severity Error, Warning` only |
| Unit tests | whole `tests/` directory, must be 0 failures |
| Complexity | sibling module PSComplexity, 15 cyclomatic / 15 cognitive per unit |
| Self-mutation | `Invoke-PSMutation -ConfigFile ./psmutant.self.config.json`, break = 100 |

Note CI does **not** measure coverage. That does not make coverage optional here — see
the rule above — it means you have to measure it yourself, correctly, which is harder
than it sounds. Read the next section before quoting a number.

---

## Measuring coverage: three traps, all of them hit in practice

**1. Measure PER FILE, never the whole directory at once.** Running coverage over all
of `tests/` against all of `src/` reports **0%** for `PSMutation.Report.ps1` and
`PSMutation.Recheck.ps1` — files that are self-mutation tested at 100%, which is
impossible for code that never runs. Point one test file at its own source file and
both report 100%. The whole-directory number is simply wrong (Pester 6.1.0).

```powershell
# Correct: one source file, its own tests.
$c = New-PesterConfiguration
$c.Run.Path = 'tests/Report.Tests.ps1'
$c.CodeCoverage.Enabled = $true
$c.CodeCoverage.Path = 'src/PSMutation.Report.ps1'
$c.Run.PassThru = $true
(Invoke-Pester -Configuration $c).CodeCoverage.CoveragePercent
```

**2. A nested Pester run destroys the outer run's coverage breakpoints.** A full
`Invoke-PSMutation` starts Pester for the baseline suite. Everything in
`Invoke-PSMutation.ps1` from that call onward is then reported as never executed —
including lines that print on every single run. `tests/EndToEnd.Tests.ps1` proves that
code works but **cannot measure it**.

This is why `src/PSMutation.Config.ps1` exists. Decision logic that used to sit inline
in the orchestrator (config defaults, the per-mutant timeout, the baseline-green guard,
the result shape) was lifted into pure functions so it is measurable *and*
self-mutatable. **Keep it that way**: new decisions belong in `Config.ps1` or another
pure unit, not in the body of `Invoke-PSMutation`, which should stay wiring.

**3. Pester version split.** CI pins **5.8.0**; development happens on **6.1.0**; the
runner does a bare `Import-Module Pester`. On a machine with both, all end-to-end tests
fail with *"An incompatible version of the Pester.dll assembly is already loaded"*. CI
is green only because its image has one version. Tracked in **#16**.

### Current state

| File | Coverage | Self-mutated |
|---|---|---|
| `PSMutation.Operators.ps1` | 100% | yes |
| `PSMutation.Report.ps1` | 100% | yes |
| `PSMutation.Recheck.ps1` | 100% | yes |
| `PSMutation.Config.ps1` | 100% | yes |
| `PSMutation.Runner.ps1` | 100% | no — executes real Pester runs |
| `PSMutation.Sandbox.ps1` | 100% | no — real temp side-effects |
| `Invoke-PSMutation.ps1` | **not measurable** | no |

`Invoke-PSMutation.ps1` is the one documented exception, for trap 2. It is wiring: every
line past the baseline call is a call into a function that is itself at 100%. If you
find yourself putting a *decision* there, extract it instead.

---

## Layout

```
src/PSMutation.Operators.ps1   AST walk -> mutation candidates. Pure.
src/PSMutation.Sandbox.ps1     temp sandbox: create, path-map, sweep. Side-effects.
src/PSMutation.Config.ps1      config resolution + run guards. Pure.
src/PSMutation.Report.ps1      scoring, thresholds, equivalents, report JSON. Pure.
src/PSMutation.Recheck.ps1     -RecheckFrom: compatibility + candidate selection. Pure.
src/PSMutation.Runner.ps1      baseline, per-mutant execution, the loop.
src/Invoke-PSMutation.ps1      public entry point. Wiring only.
```

Load order is fixed in `PSMutant.psm1` — pure layers first, runner and entry point last.
A new `src/*.ps1` must be added there or it will not load.

**Mutants must never touch tracked source.** Everything runs in a temp sandbox and the
real files are never written, even transiently, so a hard kill cannot leave a mutated
file staged in git. `tests/EndToEnd.Tests.ps1` asserts the tracked source is
byte-identical after a run — keep that assertion.

---

## Conventions

- Branches: `feature/<name>` or `bugfixes/<name>`, PR into `main`. One issue per branch.
- **Version**: bump `ModuleVersion` in `PSMutant.psd1` in the PR. `publish.yml` refuses
  to publish when the git tag and `ModuleVersion` disagree. Bugfix → patch, new surface
  → minor.
- `CHANGELOG.md` is maintained by hand here (unlike IdentityAtlas, where automation owns
  it).
- **ASCII only** in `src/` and `tests/`. Non-ASCII without a BOM trips
  `PSUseBOMForUnicodeEncodedFile` and fails the lint gate.
- Keep each function under the complexity ceiling; the gate is per unit, not per file.

## Writing tests here

The house style is a comment naming the *failure the test prevents*, not a restatement
of the assertion. Choose inputs that **discriminate**: a fixture where a guard's two
halves disagree, a collection of exactly one where the code says `-gt 0`, a value that
rounds differently at one decimal than two. A test that passes against the broken
version proves nothing — when fixing a bug, run the new test against the old code and
confirm it fails.

Two traps that have bitten in this repo specifically:

- `Should -BeLike '*[3/10]*'` — in a wildcard, `[3/10]` is a **character class**. Use
  `Should -Match ([regex]::Escape(...))`.
- A property getter that throws yields `$null` in PowerShell rather than raising, so a
  `try/catch` around it never runs. Test the value, not the exception.
