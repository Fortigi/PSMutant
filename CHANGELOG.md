# Changelog

All notable changes to PSMutant are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

## [0.1.0] - 2026-07-03
### Added
- Initial release.
- AST-based mutation operators: binary operators (`-eq`↔`-ne`, `-and`↔`-or`,
  `+`↔`-`, …), boolean literals (`$true`↔`$false`), integer literals (`N`→`N+1`),
  quoted strings (`→ ''`, opt-in), and negation removal (`-not X`→`X`).
- Sandboxed, in-process execution — mutants run against a throwaway temp copy, so
  tracked source is never modified even if the run is killed.
- Loop-condition guard so a mutated comparison can never spin an infinite loop.
- Covered-lines-only filtering (Pester code coverage), per-file test mapping.
- JSON report + console summary; report-only or `thresholds.break` gating.
- `Invoke-PSMutation`, `Get-PSMutationCandidate`, `Set-PSMutationText` exported.
