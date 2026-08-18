# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull (do the most-requested thing first)
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track progress
here: a second status list drifts from the first, which is the exact failure mode CLAUDE.md's
"check the docs against the code" rule exists to prevent.

Snapshot taken 2026-08-18. Updated the same day after a dedicated architecture review, which
added #52-#57, #59 and #60-#63, and re-priced #1 (see below). 48 issues open.

---

## The constraints that force the order

```
#47 output seam        ---> #11 annotations, #10 -ListOnly, #6 per-file scores
                            all three add a new rendering of the same data

#45 + #38 file layout  ---> #24 config validation, #25 defaults, #40 colour bands,
                            #4 merge, #6 ratchet
                            each adds a guard, a resolver or a report field -- exactly
                            the decision #45 says is currently ambiguous

#34 report provenance  ---> #4 merge, #6 ratchet, #20 recheck chaining
                            all three read reports and would each invent field-sniffing

#48 candidate contract ---> #28 identity, #29 ids
                            both change fields a consumer may already be reading

#1 parallelism         <==> #39 resumability
                            both restructure the same loop: one PR, or strictly sequenced
```

Two things follow that are worth stating out loud:

- **#1 is the most-requested item and should not be first.** It rewrites the loop that #39 also
  needs and the output that #47 wants to abstract. Doing it early means doing parts of it twice.
- **#24 is the highest-value single fix, and still should not be first.** It adds validation and
  resolvers, and #45 is what decides where those live. #45 is a pure-move change with no
  behaviour change, so the prerequisite is cheap -- it is a reordering, not a delay.
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

## Wave A -- harden the release path

Independent of everything else, touches only `.github/` and `tools/`, and protects the one
irreversible action in the project.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#42** CI hygiene | Four lines (`concurrency`, `timeout-minutes`, module cache). Do it first because it makes every later wave's CI cheaper, and CI just went from 1m39s to 6m20s. |
| 2 | **#26** publish gate + artifact smoke test | A gallery version cannot be withdrawn, and publishing runs about one sixth of the merge gates with the package never once loaded. Highest consequence in the backlog. |
| 3 | **#37** version / CHANGELOG / ReleaseNotes gate | Five lines, same file as #26. Would have caught 0.2.2 shipping while its entry was still under `[Unreleased]`. |
| 4 | **#33** workflow pin divergence | Same area again. This is the drift class that produced #16. |

Land 2, 3 and 4 as one PR if convenient -- they are all `publish.yml` and `code-scanning.yml`.

## Wave B -- make the numbers trustworthy

| Order | Issue | Why here |
|---|---|---|
| 1 | **#27** `tools/` untested | The two scripts asserting "100% coverage" and "Pester >= 5 works" have no tests, no coverage and no mutants. Until this is done, every other number in the project is unverified. |
| 2 | **#31** sweep guard untested | The #2 fix can be deleted with the suite staying green. One test closes the only place a fixed bug can silently return. |

## Wave C -- structural groundwork

All three are prerequisites, and none changes behaviour. Cheaper as one "make room" pass than
as three refactors interleaved with features.

| Order | Issue | Why here |
|---|---|---|
| 0 | **#52** layering has no enforcement | Decide whether to gate the layering or stop claiming it is enforced. Cheap, and it settles the ground the rest of this wave moves. |
| 1 | **#45 + #38** together | File responsibilities and the duplication overlap: #45's proposed `PSMutation.Pester.ps1` is the home that resolves #38's duplicated Pester resolution. Doing #38 alone puts the shared helper in a file #45 then wants to split. |
| 2 | **#34** report provenance | `schemaVersion`, producing module version, timestamp, durations. Unblocks three issues and gives #1 a before/after number it currently has no way to produce. |
| 3 | **#47** output seam | Separate deciding what to say from saying it. Unblocks three more. |
| 4 | **#48** candidate contract | Decide what is public before #28/#29 change it. May resolve by simply un-exporting `Set-PSMutationText`. |

#47 can slip to just before Wave E if you want output features sooner -- but then #11, #10 and #6
each pay for it separately.

## Wave D -- the silent-wrong-answer cluster

Now has a home to land in. This is the wave with the most user-visible value.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#24** config validation | Largest remaining silent-wrong-answer surface: `"brake"` for `"break"` makes the gate unable to fail. |
| 2 | **#25** documented defaults | `coveredLinesOnly` needs the resolver #24's work introduces. Same file, same review. |
| 3 | **#40** 0% prints green | Threshold-band resolution: again the same file. Do 1, 2 and 3 together. |
| 4 | **#29** operator-order renumbering | Reordering a JSON array silently invalidates recheck reports. |
| 5 | **#28** identity collision, with **#3** and **#59** | Same identity scheme, three different defects: a colliding key, a stale key, and an id whose stability rests on an unstated ordering. Fix once. |
| 6 | **#54**, **#56** | The run-result shape and the score function's fused scope. #56 blocks per-file scores in Wave E. |
| 7 | **#60**, **#61** | Two files documented Pure that do I/O, and `-Quiet` implemented two ways. Both are small, both are prerequisites for #47/#11 being done cleanly. |

## Wave E -- output features

**#11** CI annotations, then **#10** `-ListOnly`, then **#6** per-file scores and ratchet.
All three want #47; #6 also wants #34.

## Wave F -- the loop

**Do not start until B and C are done, and do not write the design before you are ready to
build it** -- a design for a loop nobody is rebuilding goes stale, which this repo has already
had happen twice with its own documentation.

1. **#53** first -- isolation keyed to the run rather than the OS process. #1 cannot be built on
   a `$PID`-named sandbox.
2. One narrow design pass on the runner/loop. It is the only place the current design genuinely
   does not extend: sequential, accumulates in memory, writes nothing until the last mutant.
   Note #57 records the existing stance, so the design pass starts from a written baseline.
3. **#1** parallelism and **#39** resumability together -- but see the re-pricing above; these
   sit on different halves of the loop and #1 is the larger of the two by some margin.
3. **#7** TimedOut as a distinct status.
4. **#8** diff-scoped runs.

---

## Low-coupling, good fillers

Pick these up between waves; none blocks anything.

- **#30** `RequiredModules` auto-imports the newest Pester. Small, consumer-facing, no dependencies -- the best early win outside Wave A.
- **#46** `switch`/ternary blind spot. Natural follow-up to #5.
- **#55** nothing asserts Pester's result vocabulary is two-valued. Small, and it guards the
  external boundary the module deliberately does not abstract.
- **#63** no run-context object, so each new mode threads another long parameter list. Decide
  before **#10** or **#8**, since both add a mode and the decision is far cheaper before there
  are four call sites.
- **#39** interrupted runs -- see the note above; likely cheaper than its pairing with #1 implies.
- **#49** child runspace script is an unparsed string.
- **#41** help surface / missing `about_PSMutant`.
- **#36** end-to-end exact counts, **#43** cross-Context `$script:` coupling, **#35** consumer-shaped layout.
- **#32** Windows CI matrix -- after #42, since it adds runner time.
- **#22** sandbox self-mutation, **#14** recheck skips declared equivalents, **#9** killed-by map.
- **#20** recheck chaining and **#4** merge into baseline -- both after #34.
