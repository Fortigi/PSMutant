# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull (do the most-requested thing first)
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track progress
here: a second status list drifts from the first, which is the exact failure mode CLAUDE.md's
"check the docs against the code" rule exists to prevent.

Snapshot 2026-08-21, after 0.3.1. 43 issues open.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design -- that lives in the issues. Removal is the one
exception, because it is one-way and cannot drift out of date the way a checklist would. Wave
letters keep their original letters even as earlier ones disappear, so "Wave A" in an existing
commit or PR still resolves.

An entry leaves when the **work** is done, which can be slightly before its issue closes -- so
the count above may briefly exceed what is listed here. Ordering is the only thing this file
claims; the issues remain the record of what is open.

**0.3.0 is out**, which changes one thing about sequencing rather than many: the public surface
is now written down and published -- `Invoke-PSMutation`, the report JSON, and the two schemas in
`schemas/v1/`. Anything that changes those shapes is a **breaking** change with a version cost
attached, where before 0.3.0 it was free. #54 and #4 are the two queued items that do, and both
are better early in a cycle than late.

---

## Wave H -- what an audit of the unexamined lenses found

Seventeen issues arrived at once (#94-#110) from applying lenses this project had never been
pointed at: security, supply chain, edge-case robustness and performance. They are listed
first because two of them outrank everything already on this roadmap, and because they are not
seventeen independent problems.

**Two things are broken that this project exists to prevent.**

| Issue | What happens |
|---|---|
| **#99** | A resolved per-mutant timeout at or below 0.5s becomes **0**, and then *every mutant is scored Killed*. A silent, perfect, fake score -- in the tool built to expose exactly that. |
| **#97** | A `..` in a config path escapes the sandbox and mutates a **real file in place**. A hard kill there leaves the mutant in tracked source, which CLAUDE.md states cannot happen. |

Do these two first, ahead of anything else in this file. Neither is large.

**Five more are the same failure class** -- the run reports a number it did not measure:
**#96** (the coverage filter drops whole mutate files out of the score, silently), **#98** (the
report write fails non-terminatingly and the run still returns `Score=100, ExitCode=0`),
**#103** (a path that does not survive into the sandbox is diagnosed as a red baseline),
**#107** (a file listed twice doubles the denominator), and **#108** (a missing `tests` entry
silently runs the whole suite for every mutant).

**And five trace to one missing concept: config paths have no resolver.** #97, #100 (`..` in
`sandboxSubtrees` copies outside the sandbox, carries no `$PID`, and is never cleaned up),
#104 (`reportPath` is documented optional and is mandatory in practice, and the run finds out
last), #109 (a `[` in a path fails with a message naming neither the file nor the cause) and
#110 (concurrent runs race on `reportPath`, and a `-RecheckFrom` seeded from the survivor
answers confidently about the wrong survivor set).

That is worth treating as one piece of work rather than five. Every other config value gained a
resolver with a documented default in 0.3.0; paths did not. Give them one -- resolve against
the source root, refuse an escape, name the file when it fails -- and four of those five close
together.

The rest are performance and housekeeping, and none blocks anything: **#101** (each mutant
reads and writes the whole mutate file twice), **#102** (a flat 130 ms Pester re-import per
mutant), **#105** (`psmut-coverage-$PID.xml` accumulates in temp forever -- the sweep's regex
structurally cannot match it), **#106** (every recheck round pays for coverage instrumentation
that cannot change what it rechecks).

**Security, in proportion.** **#95** is real but narrow: a symlink pre-planted at the
predictable `/tmp/psmut-sandbox-<pid>` path leaks the mutated source to another local user. CI
runners are single-tenant and Windows temp is per-user, so this reaches shared Linux build
hosts and nothing else. It wants the same change as **#53**, which already proposes moving
isolation off `$PID` -- do them together. **#94** is a missing `permissions` block on `ci.yml`
against a `write` default, which matters because that job installs four modules from the
gallery and then executes them.

**What the audit could NOT break is worth as much as what it could**, and is recorded so it is
not re-tested: the sweep cannot be redirected through a junction or symlink -- it deletes the
name, not the target; its name match is anchored; a hard kill leaves tracked source
byte-identical **by construction**, because the real files are never opened for write; nothing
in a consumer's config reaches an eval sink; zero mutants scores 0% and exits 1 rather than a
vacuous 100%; two processes never sweep each other's live sandbox, so #2's fix holds; and
scoring is linear, not quadratic. The one documented self-mutation exclusion was verified
empirically rather than inherited.

---

## The constraints that force the order

```
#1 parallelism         <==> #39 resumability
                            both restructure the same loop: one PR, or strictly sequenced

a config path resolver ---> #97, #100, #104, #109, #110
                            one missing concept, five issues; every other config value got a
                            resolver in 0.3.0 and paths did not

#53 isolation off $PID ---> #95 symlink disclosure, #22 sandbox self-mutation
                            all three want the sandbox named by something other than the pid
```

Two things follow that are worth stating out loud:

- **#1 is the most-requested item and should not be first.** It rewrites the loop #39 also
  needs. The output half of that argument is spent -- the seam exists -- but the loop half is
  not, and doing #1 early still means doing parts of it twice.
- **#1 is bigger than "add a runspace pool".** The architecture review established that
  sequential evaluation is a *correctness invariant*, not a tuning default: the loop mutates one
  shared sandbox copy and runs the covering tests against the whole tree
  (`src/PSMutation.Runner.ps1:219-227`), so two mutants are not independent **even when they are
  in different files**. Serialisation is the isolation mechanism. Parallelism therefore needs N
  complete `Copy-Item -Recurse` sandbox trees, not N sandbox names -- and #53 (isolation keyed to
  the process rather than the run) has to land first, because the sandbox name carries `$PID`.
  **#62** is a second blocking consideration: the per-mutant timeout is derived from a *solo*
  baseline, so under N-way parallelism ordinary CPU contention becomes timeouts, and a timeout
  counts as a kill -- parallelism would silently inflate the score. Do #7 before or with #1 so
  that failure is visible rather than flattering.
- **#1 and #39 may not belong together after all.** They were paired here because both touch the
  loop, but they sit on different axes of the same stance: #39 is about durability of results,
  #1 about isolation of execution. #39 is much the cheaper half and does not need #53. Consider
  splitting them and doing #39 early as a filler.

---

## Wave D -- the silent-wrong-answer cluster

Now has a home to land in. This is the wave with the most user-visible value.

Its identity half is finished. #29 made mutant ids independent of operator order, #28 stopped
one equivalence declaration silently covering every mutant on its line, and #3 keyed
declarations by enclosing function so they stop drifting when unrelated lines move. What that
established, and what the remaining work should not undo: **neither key form dominates** -- the
function form is stable but coarse (41 ambiguous keys over this repo's source, against 9 for
the line form), so both are kept and the summary now prints whichever one actually identifies
the mutant.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#54** with **#63** | The run result carries a verdict without its reason and has no field common to both modes -- which is what a run-context object fixes, so doing them apart means threading the same parameters twice. |
| 2 | **#56** | The score function validates a whole config while scoring a subset, which blocks per-file scores in Wave E. |

**#54 is breaking, so it wants to be EARLY in the 0.4.0 cycle**, not just before the release --
the same argument that shipped 0.3.0 when it did rather than folding this in. Landing it now
means the next release carries one deliberate surface change with time to settle; landing it
late means either delaying the release or shipping it hot.

## Wave E -- output features

**#11** CI annotations, then **#10** `-ListOnly`, then **#6** per-file scores and ratchet. The
seam all three wanted is built, and report provenance, which #6 also wanted, has landed.

**Take #11 first, ahead of Wave D.** Not for its own value, though it has the most of any
issue left -- survivors surfaced on the PR diff instead of buried in a log. Take it because
the seam was justified by a claim that is still untested: *annotations become a new renderer
rather than a change to the reporting layer*. A seam with exactly one renderer is a
hypothesis. #11 is the first thing that can prove or break that design, and the cheapest
moment to find out it is wrong is while the design is a week old rather than a year.

## Wave F -- the loop

**Do not start until C is done, and do not write the design before you are ready to
build it** -- a design for a loop nobody is rebuilding goes stale, which this repo has already
had happen twice with its own documentation.

1. **#53** first -- isolation keyed to the run rather than the OS process. #1 cannot be built on
   a `$PID`-named sandbox.
2. One narrow design pass on the runner/loop. It is the only place the current design genuinely
   does not extend: sequential, accumulates in memory, writes nothing until the last mutant.
   Note #57 records the existing stance, so the design pass starts from a written baseline.
3. **#1** parallelism and **#39** resumability together -- but see the re-pricing above; these
   sit on different halves of the loop and #1 is the larger of the two by some margin.
4. **#7** TimedOut as a distinct status.
5. **#8** diff-scoped runs.

---

## Low-coupling, good fillers

Pick these up between waves; none blocks anything.

- **#46** `switch`/ternary blind spot. Natural follow-up to the operators #5 landed.
- **#55** nothing asserts Pester's result vocabulary is two-valued. Small, and it guards the
  external boundary the module deliberately does not abstract.
- **#63** no run-context object, so each new mode threads another long parameter list. Decide
  before **#10** or **#8**, since both add a mode and the decision is far cheaper before there
  are four call sites.
- **#39** interrupted runs -- see the note above; likely cheaper than its pairing with #1 implies.
- **#49** child runspace script is an unparsed string.
- **#41** missing `about_PSMutant`. **Smaller than its title implies, twice over.** The title
  also says two of three exports are undocumented -- there is one export now, so that half is
  gone. And the real defect underneath it was found and fixed separately: a `<# #>` file header
  shadowed the public help, so `Get-Help` served the file's architecture notes instead of the
  documentation. Parameters, examples and the synopsis are complete now and pinned by tests.
  What remains is the topic the help still points at and which does not exist.
- **#36** end-to-end exact counts, **#43** cross-Context `$script:` coupling, **#35** consumer-shaped layout.
- **#32** Windows CI matrix. Adds runner time, but the caching and concurrency work it was
  waiting on has landed, so it is affordable now.
- **#22** sandbox self-mutation, **#9** killed-by map.
- **#89** nothing watches the pinned dependencies. Split unevenly: the `github-actions` half
  is a ten-line `dependabot.yml` and could go in beside anything, while `.github/pins.env`
  has no tool that reads it and needs a decision rather than a config file. Worth doing the
  cheap half early -- a frozen PSScriptAnalyzer does not weaken the lint gate visibly, it
  just stops finding things, which is this project's own failure mode pointed inward.

---

## Wave G -- the recheck loop

**`-RecheckFrom` stays.** Decided 2026-08-20. In the maintainer's words: *it does not give you
the full measure, but while developing it speeds things up tremendously.*

Both halves of that matter, and the code already takes them seriously. The speed is the point:
a run of several hundred mutants with a handful of survivors must not re-run the whole set to
tell you about those few, so anything that makes a recheck do work it does not need to do is a
defect against the feature's purpose rather than a nicety. And "not the full measure" is
enforced rather than trusted -- no score, thresholds skipped, a separate report file, and the
caveat printed on every run -- because a partial number quoted as a real one is the failure
this whole project exists to prevent.

Recorded because it was a live question, though the question was worse framed than the answer.
It was asked as "a sixth of `src/` serving a single user" -- and that conflated **adoption**
with **value**. Nothing outside this repo was exercising `-RecheckFrom` yet, which says the
module is young, not that the feature is bespoke: it ships to every consumer, and the
edit-run-edit loop it shortens is what using a mutation tester *is*. A feature nobody has
reached for yet is not the same as a feature nobody needs.

The loop NARROWS as of #14 and #20: five survivors, kill two, and the next round evaluates
three. Declared equivalents are skipped, and a recheck report seeds the next one.

What is left is a different question -- not "how few mutants can a round run" but "can the
score be refreshed without a full run at all". That is #4, and it is bounded by what the tool
can actually verify rather than by effort.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#4** fold recheck results into the baseline | Now the interesting one, and it answers a question worth asking: since the baseline already knows what every mutant did and the recheck knows what changed, why re-run anything to refresh the number? Because the arithmetic is only sound if the test changes were purely additive, and the compatibility guard watches the *source*, not the tests. The sound version is to hash the mapped test files too: a mutant whose covering tests are byte-identical is provably still killed and can be carried, one whose tests changed must be re-run. That trades a full run for re-running the file you were working in. Its prerequisite is met -- both report shapes now carry the same provenance block, so merging them is a question about the mutant rows rather than about telling the two shapes apart. |
| 2 | **#59** option (2) | Identity independent of walk position. Option (1) landed in #75; (2) was blocked on #48 and is not any more. Fewer refusals means fewer forced full runs, which is the same bar again -- but it is the smallest remaining item here, not the most valuable. |

