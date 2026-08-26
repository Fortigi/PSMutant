# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull (do the most-requested thing first)
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track progress
here: a second status list drifts from the first, which is the exact failure mode CLAUDE.md's
"check the docs against the code" rule exists to prevent.

Snapshot 2026-08-26, with **0.4.0 prepared and unreleased**. 28 issues open.

**The prepared 0.3.3 became 0.4.0 and never existed.** It was never tagged and never published --
the gallery goes 0.3.2 straight to here, and nothing pins it, including the sibling -- so when the
run result gained fields it was renamed rather than shipped twice. Recorded rather than quietly
overwritten, so nobody later goes looking for the version between them.

Since the last snapshot: survivors now land on the pull request diff (#11), a red baseline names
the tests that failed and why (#144), the suite stopped inheriting the ambient CI in both
directions (#145), the analyzer script became a verdict rather than a return value (#136), and
ten entries that had accumulated under `[Unreleased]` were prepared as 0.3.3 (#148) -- which also
retired a release-check warning that had been printing on every run long enough to become
scenery.

**The run result carries the reason it failed** (#54). `ExitCode 1` meant either a stale
equivalence declaration or a score under the break threshold, and nothing said which -- so a run
scoring 100% with one stale declaration failed with a hardcoded "below the break threshold", which
was false, and the real reason lived only in a summary line `-Quiet` suppresses and a JSON file
nothing uploads. Both result shapes now share `Mode`, `ExitCode` and `FailureReason`; they had no
field in common at all, which broke the README's own CI idiom in both directions at once.

**A `tests` key that names no `mutate` file is now refused** (#152). It covered no mutant, its
test files still joined the baseline's set, and whichever file it was meant to name fell back to
running the whole suite for every one of its mutants -- so a typo made runs far slower while the
score stayed believable. Found by writing a comment inside `tests`, where `_`-prefixed keys are
exempt from validation and were then consumed as paths.

**The Guards section closed entirely.** Every renderer call now binds `-Quiet`, so no mock filter
can be ambiguous about which calls it selected (#146), and the suite has to give the same answer
reversed and leave the environment as it found it (#147). Both were properties that had already
cost CI rounds while being true only by habit. Removed rather than ticked, per the rule above --
what is worth keeping from either is in `CLAUDE.md`, where somebody about to write a mock or a
test file will actually meet it.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design -- that lives in the issues. Removal is the one
exception, because it is one-way and cannot drift out of date the way a checklist would.

**The waves were re-derived from the whole backlog, and renumbered 1-5.** They used to be
lettered, and removal had eaten A, B and C while H -- which arrived last from an audit --
outranked most of D through G. What was left was a page whose order did not match its numbering
and whose gaps read as deletions. Letters in older commits and PRs no longer resolve to
anything here; the issues they name still do, which is the only reference that was ever
reliable.

Grouping is by **what one decision fixes**, not by theme. Wave 1 is four issues and one
identity; Wave 2 is four issues and one missing field. That is the useful unit, because it is
what tells you the second issue in a wave is nearly free once the first lands.

An entry leaves when the **work** is done, which can be slightly before its issue closes -- so
the count above may briefly exceed what is listed here. Ordering is the only thing this file
claims; the issues remain the record of what is open.

**0.3.0 is out**, which changes one thing about sequencing rather than many: the public surface
is now written down and published -- `Invoke-PSMutation`, the report JSON, and the two schemas in
`schemas/v1/`. Anything that changes those shapes is a **breaking** change with a version cost
attached, where before 0.3.0 it was free. **#54** and **#4** are the two queued items that do --
#54 changes the run result, #4 folds recheck results into the baseline report -- and both are
better early in a cycle than late.

---

## The constraints that force the order

```
#53 isolation off $PID ---> #22 sandbox self-mutation, #95 symlink disclosure,
                            #105 temp accumulation, #110 recheck seed ambiguity
                            ONE identity fixes four issues. Every one exists because
                            ownership and liveness are fused into the pid.

#62 timeout from a     ---> #1 parallel evaluation
    SOLO baseline           under N-way contention an honest run becomes timeouts, and a
                            timeout scores with the kills. Parallelism would inflate the
                            score silently. #62 first, always.

#54 run result         ---> #6 per-file scores
                            the object CI reads carries a verdict without its reason, so a
                            failing gate prints a percentage and a shrug.
```

**One arrow in this block was wrong, and the correction is worth more than the arrow was.** It
also pointed #54 at #11, on the reasoning that survivors could not reach CI until the run result
carried them. #11 shipped without touching #54. The survivors were already there -- every output
line carries a **role** and a survivor line carries its mutant row in `-Data`, put there for
exactly this renderer -- so the annotation path reads the lines, not the result.

The lesson is not "the file was wrong"; it is which kind of dependency is real. #54 is about what
a **caller in PowerShell** receives from `Invoke-PSMutation`. #11 needed what a **renderer**
receives, which is a different seam that already existed. A dependency asserted between layers
should be checked against the seam, not assumed from the subject matter.

Three things worth stating out loud:

- **#1 is the most-requested item and should not be first.** Sequential evaluation is a
  *correctness invariant*, not a tuning default: the loop mutates one shared sandbox and runs
  the covering tests against the whole tree, so two mutants are not independent **even in
  different files**. Serialisation is the isolation mechanism. Parallelism needs N complete
  sandbox trees, which needs #53 -- the sandbox name carries the pid.
- **#39 is not #1's twin.** They were paired because both touch the loop, but #39 is about
  durability of results and #1 about isolation of execution. #39 is much cheaper, needs
  nothing from #53, and belongs early.
- **#63 is deferred on evidence.** Three fixes went through the orchestrator seam and two added
  *zero* parameters. Exclusion is the argument against a context object: it must not reach the
  recheck path. Revisit when a value is genuinely shared by three or more callees.

---

## Wave 1 -- the unit of isolation is the run, not the process

Four issues, one identity. Ownership and liveness are both fused into the process id, and
every consequence below follows from that single choice. Do **#53** first; the rest largely
fall out of it.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#53** | the identity itself. Everything below is downstream |
| 2 | **#95** | a pre-planted symlink at the predictable sandbox path leaks mutated source to another local user. The path is predictable *because* it is the pid |
| 3 | **#105** | the coverage XML accumulates in temp forever, and the sweep structurally cannot match it |
| 4 | **#22** | Sandbox.ps1 cannot be self-mutated: its covering suite sweeps the live run's sandbox, because the sweep treats its own pid as reclaimable |
| 5 | **#110** | concurrent runs race on reportPath, and a recheck seeded from the survivor answers confidently about the wrong set. A run id is what the gate lacks |

**#22 is the tell.** A gate this project holds at 100% has one permanent exception, and the
reason is not effort -- the isolation unit is wrong. Fixing #53 retires the exception rather
than documenting it a fourth time.

## Wave 2 -- a run that survives its own interruption

| Order | Issue | Why here |
|---|---|---|
| 1 | **#39** | an interrupted run loses everything: the report is written after the last mutant |
| 2 | **#124** | a suspended run hangs forever -- mutants are bounded, the run is not |

**This wave is what is left after its own premise dissolved.** It existed because a failing gate
printed `99.8% (532/533)` and nothing else. That is no longer true three times over: survivors are
annotated onto the pull request diff (#11), a red baseline names the failing tests with their
messages (#144), and the run result now carries the REASON it failed rather than only the verdict
(#54). Nothing here is urgent any more; both remaining items are about a run that ends badly rather
than one that reports badly.

*One claim this file made about #54 was wrong, and the correction is worth more than the entry
was.* It read "#54 is breaking, so it wants to be early in a cycle rather than just before a
release", and scheduled the work around a cost it did not have. Adding `FailureReason`, `Mode`,
`StaleEquivalents` and `DeclaredEquivalent` left `Score`, `Killed`, `Survived`, `Total` and
`ExitCode` meaning exactly what they meant, so no consumer broke. What it broke was three of this
project's OWN tests, which pin the exact field lists so that widening them is a decision rather than
a side effect of a rename -- and a test failing on purpose is the mechanism working, not a breaking
change.

The lesson is about which kind of "breaking" a plan tracks. A published contract that only GROWS is
safe for consumers and expensive for nobody. #54 sat behind a release that had not happened, for a
reason that was not true.

## Wave 3 -- the operator set sees the language

| Order | Issue | Why here |
|---|---|---|
| 1 | **#46** | the AST walk covers only if/elseif: switch and ternary are invisible to **every** operator |

A file whose branching is a switch produces no mutants and scores a **vacuous 100%** -- the
exact failure this project exists to expose, pointed inward. The sibling closed the same class
in its 0.4.0, and the argument transfers: an unrecognised construct can only make a score look
better.

## Wave 4 -- what a mutant costs

Measure before choosing a mechanism. This wave was re-ordered once the measuring was actually
done, and the answer was not where the wave assumed.

**Per-mutant overhead is not the cost.** Measured over the committed reports: 557 mutants in
1035s here, 195 in 870s next door -- 1.83s and 4.34s per mutant. Known fixed overhead is about
0.2s of that. So **85-90% of a run is the covering suite**, executing tests that never touch the
mutated line and therefore cannot possibly observe the change.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#141** | run only the test files that execute the mutated line. The only lever that cuts time without cutting detection -- a test that never runs the line cannot tell the mutant from the original, so not running it is verdict-preserving **by construction** |
| 2 | **#102** | every mutant re-imports Pester into a fresh runspace: a flat 130 ms floor |
| 3 | **#101** | each mutant reads and writes the whole file twice; past 16 KB a write costs 40 ms on Windows |
| 4 | **#107** | every recheck round pays for coverage instrumentation that cannot change what it rechecks. #141 gives that instrumentation a second consumer, which changes the calculation |
| 5 | **#62** | the timeout is derived from a *solo* baseline. Blocks #1 |
| 6 | **#1** | parallel evaluation. Needs #53 and #62 first, and is bigger than "add a runspace pool" |

**#43 gates only half of #141.** Selecting whole test FILES needs nothing from the test estate.
Selecting finer -- per `Describe`, per `It` -- needs files that can be run in part, which is #43.

**Two cheaper-looking levers are refused, and the refusal belongs here.** Dropping an operator
removes 228 of 557 mutants and 418s, and the run still reports 100% -- a score over a smaller set
is indistinguishable from a score over the full one unless you already know which set ran.
Sampling is the same objection plus irreproducibility. Both shorten the run by making the number
mean less, which is the failure this project exists to find in other people's code.

## Wave 5 -- the features people ask for

Reachable once the waves above land, in this order because each one's prerequisites are the
ones before it.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#10** | preview the mutant set without running tests. Smallest, and the honest answer to "what would you mutate?" -- a rendering this module controls |
| 2 | **#6** | per-file scores and a committed ratchet. Wants #54's shape |
| 3 | **#8** | mutate only what a PR changed. Wants #6 |
| 4 | **#9** | report which test killed each mutant |
| 5 | **#4** | fold recheck results back into the baseline report. Wants Wave 1's run identity, or it merges two runs that are not comparable |

## Cheap, and not blocked by anything

- **#115** -- nothing fails when main claims a version already on the gallery. The sibling
  shipped exactly this; its decision function ports directly.
- **#43** -- test files share script state across blocks, so a filtered run fails on tests that
  are fine. A suite that cannot be run in part cannot be bisected.
- **#36** -- end-to-end counts asserted as open inequalities over a fixture whose answer is
  exact, so they pass against a run that produced twice what it should.
- **#35** -- no test exercises a consumer-shaped layout; every fixture is this repo's own flat
  src/+tests/, which is not the shape the module promises to support.
- **#49** -- the child runspace contract is an unparsed string: nothing lints or parse-checks
  the code every mutant runs.
- **#41** -- the help points at an about_PSMutant topic that does not exist.
- **#117** -- the parity tracker. Keep it until the last row closes.

## Decisions to record, not work

- **#57** -- the process-and-state stance exists only in this file, framed as a limitation. It
  is a design position and belongs where a consumer reads it. Settle it in whichever PR touches
  the README, the way the sibling settled its two equivalents.
