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

Requires PowerShell 7.2+ and Pester 5+.

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
exit $result.ExitCode        # 0 unless thresholds.break is set and unmet
```

Survivors are printed with `file:line` and the exact source→mutant change — each is a
missing assertion, an equivalent mutant (a change that can't alter behaviour), or dead code.

## How it works

1. **Baseline** — runs your tests once (must be green) with Pester code coverage over the
   `mutate` files, recording which lines actually executed.
2. **Enumerate** — parses each file's AST and collects candidates; only those on covered
   lines are kept (an uncovered mutant is guaranteed to survive and teaches nothing).
3. **Evaluate** — copies the source subtrees into a temp **sandbox**, splices each mutant
   into the copy, runs the covering tests in-process, and restores the copy. Tracked source
   is never touched.
4. **Score** — `killed / total`, written to the JSON report.

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
| `StringLiteral` | quoted string → `''` (off by default — high-volume/low-signal) |

## Config reference

| Key | Meaning |
|---|---|
| `mutate` | Files to mutate. Pure / I/O-free logic pays off most. |
| `tests` | Map each mutate file → the Pester file(s) covering it (per-file test scoping). |
| `operators` | Operator classes to inject (default omits `StringLiteral`). |
| `coveredLinesOnly` | Restrict mutants to lines the baseline executed (default `true`). |
| `sandboxSubtrees` | Directories copied into the sandbox (default `["tools","test","setup"]`; set to your layout, e.g. `["src","tests"]`). |
| `timeoutFactor` / `timeoutFloorSeconds` | Per-mutant timeout = `max(floor, baseline × factor)` (defaults 4 / 15). A non-terminating mutant is cut off and counted Killed, so the run never hangs. |
| `thresholds.break` | `null` = report-only. A number fails the run (`ExitCode 1`) below it. |
| `reportPath` | Where the JSON report is written (relative to `-SourceRoot`). |

## What to point it at

Pure, deterministic logic where a subtle fault is a real bug: transforms, validators,
classifiers, SQL-fragment builders. Skip entry points that do live I/O on load — a mutant
there is unreachable without real infrastructure.

Treat the score like a ratchet: **directional**. Don't chase 100% — equivalent mutants and
untested log strings make the last stretch noise. Raise `thresholds.break` to lock in gains.

## Development

```powershell
Invoke-Pester ./tests                                              # unit tests + complexity gate
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1   # lint
Invoke-PSMutation -ConfigFile ./psmutant.self.config.json -SourceRoot .   # dogfood: PSMutant on itself
```

### Quality gates (all required on `main`)

Every one of these runs in the CI `test` job and blocks the merge on failure:

- **Unit tests** — the four suites under `tests/`.
- **PSScriptAnalyzer** — zero Error/Warning findings (`Write-Host` is the one allowed rule).
- **Complexity** — every function and script body must stay at or under **15 cyclomatic**
  and **15 cognitive** complexity (`tools/Get-PSComplexity.ps1` + `tests/Complexity.Tests.ps1`).
- **Self-mutation** — PSMutant mutation-tests itself; the score must stay above the
  `thresholds.break` floor in `psmutant.self.config.json`.

Separately, `code-scanning.yml` uploads PSScriptAnalyzer findings to GitHub code scanning.

## License

MIT © Fortigi
