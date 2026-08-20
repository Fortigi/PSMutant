# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull (do the most-requested thing first)
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track progress
here: a second status list drifts from the first, which is the exact failure mode CLAUDE.md's
"check the docs against the code" rule exists to prevent.

Snapshot 2026-08-20. 30 issues open.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design -- that lives in the issues. Removal is the one
exception, because it is one-way and cannot drift out of date the way a checklist would. Wave
letters keep their original letters even as earlier ones disappear, so "Wave A" in an existing
commit or PR still resolves.

An entry leaves when the **work** is done, which can be slightly before its issue closes -- so
the count above may briefly exceed what is listed here. Ordering is the only thing this file
claims; the issues remain the record of what is open.

---

## The constraints that force the order

```
#47 output seam        ---> #11 annotations, #10 -ListOnly, #6 per-file scores
                            all three add a new rendering of the same data

#34 report provenance  ---> #4 merge, #6 ratchet, #20 recheck chaining
                            all three read reports and would each invent field-sniffing

#1 parallelism         <==> #39 resumability
                            both restructure the same loop: one PR, or strictly sequenced
```

Two things follow that are worth stating out loud:

- **#1 is the most-requested item and should not be first.** It rewrites the loop that #39 also
  needs and the output that #47 wants to abstract. Doing it early means doing parts of it twice.
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

## Wave C -- structural groundwork

All three are prerequisites, and none changes behaviour. Cheaper as one "make room" pass than
as three refactors interleaved with features.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#34** report provenance | `schemaVersion`, producing module version, timestamp, durations. Unblocks three issues and gives #1 a before/after number it currently has no way to produce. |
| 2 | **#47** output seam | Separate deciding what to say from saying it. Unblocks three more, and the surface keeps growing -- #3 added two more `Write-Host` sites to the summary. |

#47 can slip to just before Wave E if you want output features sooner -- but then #11, #10 and #6
each pay for it separately.

**#52 is deliberately not a position here.** Option (a) -- correcting the three places that
claimed dot-source order enforced the dependency direction -- is done. Option (b), the
`tests/Layering.Tests.ps1` edge allowlist, is specified on the issue and is triggered rather than
scheduled: do it with whichever of **#1**, **#8** or **#47** is picked up first. Those are the
three changes that add edges in the region where a shortcut reads as reasonable in review, and an
allowlist is worth most written just before the code that would violate it, rather than ageing
quietly while nothing touches the graph. Within this wave that trigger is #47.

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
| 1 | **#54**, **#56** | The run-result shape and the score function's fused scope. #56 blocks per-file scores in Wave E, and both sit in `Report.ps1`, which #28 and #3 have just been through. |
| 2 | **#60**, **#61** | Two files documented Pure that do I/O, and `-Quiet` implemented two ways. Both are small, both are prerequisites for #47/#11 being done cleanly. |

## Wave E -- output features

**#11** CI annotations, then **#10** `-ListOnly`, then **#6** per-file scores and ratchet.
All three want #47; #6 also wants #34.

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
- **#41** help surface / missing `about_PSMutant`.
- **#36** end-to-end exact counts, **#43** cross-Context `$script:` coupling, **#35** consumer-shaped layout.
- **#32** Windows CI matrix. Adds runner time, but the caching and concurrency work it was
  waiting on has landed, so it is affordable now.
- **#22** sandbox self-mutation, **#9** killed-by map.

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
| 1 | **#4** fold recheck results into the baseline | Now the interesting one, and it answers a question worth asking: since the baseline already knows what every mutant did and the recheck knows what changed, why re-run anything to refresh the number? Because the arithmetic is only sound if the test changes were purely additive, and the compatibility guard watches the *source*, not the tests. The sound version is to hash the mapped test files too: a mutant whose covering tests are byte-identical is provably still killed and can be carried, one whose tests changed must be re-run. That trades a full run for re-running the file you were working in. Wants #34, since it merges two report shapes. |
| 2 | **#59** option (2) | Identity independent of walk position. Option (1) landed in #75; (2) was blocked on #48 and is not any more. Fewer refusals means fewer forced full runs, which is the same bar again -- but it is the smallest remaining item here, not the most valuable. |

