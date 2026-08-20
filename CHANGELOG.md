# Changelog

All notable changes to PSMutant are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]
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

### Fixed
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
