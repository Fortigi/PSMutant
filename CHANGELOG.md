# Changelog

All notable changes to PSMutant are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]
### Internal
- Config resolution (subtree/operator defaults, the per-mutant timeout, the
  baseline-green guard, the run-result shape) moved out of `Invoke-PSMutation` into a
  pure `PSMutation.Config.ps1`. No behaviour change; an empty `operators: []` still falls
  back to the defaults.
- Line coverage is now 100% for every source file except the orchestrator, which cannot
  be measured (a nested Pester run clears the outer run's coverage breakpoints).
  Self-mutation remains 100%.
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
