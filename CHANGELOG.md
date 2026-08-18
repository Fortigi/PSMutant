# Changelog

All notable changes to PSMutant are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]
### Internal
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
