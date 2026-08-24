# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull (do the most-requested thing first)
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track progress
here: a second status list drifts from the first, which is the exact failure mode CLAUDE.md's
"check the docs against the code" rule exists to prevent.

Snapshot 2026-08-24, after **0.3.2 shipped**, with six more fixes unreleased. 30 issues open.

Since the last snapshot: Windows joined the CI matrix (#32), `ci.yml` dropped to
least privilege (#94), the gates learned to see a test file that never ran (#122),
`Get-PSMutationScore` became a per-set fold (#56), the complexity gate moved two majors to
PSComplexity 0.3.0 -- with 0.4.0 now prepared next door, so that pin is due again -- and
`publish.yml` stopped interpolating the tag name into a shell (#127).
Removed rather than ticked, per the rule above.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design -- that lives in the issues. Removal is the one
exception, because it is one-way and cannot drift out of date the way a checklist would. Wave
letters keep their original letters even as earlier ones disappear, so "Wave A" in an existing
commit or PR still resolves.

**So the gap in the letters is deliberate, and this is what filled it.** A, B and C are gone
because they shipped -- the sandbox and scoring foundations, the equivalence-declaration work,
and the operator set. D through H remain, out of order on the page because H arrived last and
outranks most of what was already queued. If you are looking for a wave that is not here, it
was finished; the issues are the record of what was in it.

An entry leaves when the **work** is done, which can be slightly before its issue closes -- so
the count above may briefly exceed what is listed here. Ordering is the only thing this file
claims; the issues remain the record of what is open.

**0.3.0 is out**, which changes one thing about sequencing rather than many: the public surface
is now written down and published -- `Invoke-PSMutation`, the report JSON, and the two schemas in
`schemas/v1/`. Anything that changes those shapes is a **breaking** change with a version cost
attached, where before 0.3.0 it was free. **#54** is the queued item that does, and it is better
early in a cycle than late.

*(This paragraph used to name "#54 and #4". There is no #4 in this repo -- that was the sibling's
numbering leaking in. Corrected rather than quietly dropped, because a roadmap that cites an
issue nobody can find is worse than one that cites none.)*

---

## Wave H -- what an audit of the unexamined lenses found

Seventeen issues arrived at once (#94-#110) from applying lenses this project had never been
pointed at: security, supply chain, edge-case robustness and performance. They are listed
first because they are not seventeen independent problems.

The two that outranked everything else on this roadmap are fixed and shipped in 0.3.2, and are
removed here per the rule above. Both were the failure this project exists to expose, turned
inward: a per-mutant timeout that resolved to zero scored **every** mutant Killed on the clock,
and a `..` in a config path escaped the sandbox and mutated a real file in the working tree.
Neither was large, and neither was visible from inside code at 100% coverage and 100%
self-mutation.

**That failure class is now mostly closed.** #96 (the coverage filter dropped whole mutate
files out of the score in silence), #98 (the report write failed non-terminatingly and the run
still returned `Score=100, ExitCode=0`) and #7 (a timeout scored as a plain kill) are all fixed
and unreleased. Each made the score go **up**, which is the direction that never announces
itself. **The class is closed.** #106 and #108 went last: a file listed twice doubled every
published count and made `(File, Id)` stop identifying one mutant, and a `mutate` file with no
`tests` entry ran the whole suite for every one of its mutants -- correct, never less thorough,
and invisible until it was disclosed on the console and in the report.

**The config-path cluster is closed, as one concept rather than four guards.** #100, #103,
#104 and #109 are fixed: two primitives that answer for a raw path before anything uses it, and
two resolvers over them. Fixing them separately would have produced four guards in four places,
which is what this grouping existed to prevent.

**#110 stays open and does not belong here.** Its fix is a run id in the report plus a check in
the recheck gate -- run *identity*, not path resolution. It sits nearer #54.

That is worth treating as one piece of work rather than five. Every other config value gained a
resolver with a documented default in 0.3.0; paths did not. Give them one -- resolve against
the source root, refuse an escape, name the file when it fails -- and four of those five close
together.

The rest are performance and housekeeping, and none blocks anything: **#101** (each mutant
reads and writes the whole mutate file twice), **#102** (a flat 130 ms Pester re-import per
mutant), **#105** (`psmut-coverage-$PID.xml` accumulates in temp forever -- the sweep's regex
structurally cannot match it), **#107** (every recheck round pays for coverage instrumentation
that cannot change what it rechecks).

**One more found while shipping the fixes.** **#115**: nothing fails when `main` claims a
version that is already on the gallery. Both fixes above merged without a version bump, every
gate passed, and `main` sat at a published 0.3.1 carrying code 0.3.1 does not contain. The
release gate asks whether the manifest, the CHANGELOG and the notes agree with each other --
never whether the version they agree on has already shipped. Belongs with the release-path
work rather than here.

**Security, in proportion.** **#95** is real but narrow: a symlink pre-planted at the
predictable `/tmp/psmut-sandbox-<pid>` path leaks the mutated source to another local user. CI
runners are single-tenant and Windows temp is per-user, so this reaches shared Linux build
hosts and nothing else. It wants the same change as **#53**, which already proposes moving
isolation off `$PID` -- do them together. (**#94**, the missing `permissions` block on
`ci.yml`, shipped: every workflow now runs `contents: read` against a repository default that
is write-scoped.)

**Two more found by running the gates rather than by auditing them.** **#124**: a run
suspended overnight and never finished -- 333 seconds of CPU across 875 minutes. Each MUTANT is
bounded; the RUN is not, and there is no output until it completes, so a hung run and a slow
one are the same observation. CI is covered by `timeout-minutes`; a developer running it by
hand is not, and the stranded sandbox survives every subsequent sweep because its owning
process is still alive. **#123 was filed and closed the same day**: the self-mutation gate
appeared to generate a different mutant set on Windows, and did not -- 447 generated on both
platforms, same score. It is closed with the counter-measurement rather than deleted, because
it records how a real divergence would present if `coveredLinesOnly` ever does bite.

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

a config path resolver ---> #100, #103, #104, #109, #110
                            one missing concept, five issues; every other config value got a
                            resolver in 0.3.0 and paths did not. #97 was the sixth and is
                            fixed -- at the mapper, so the concept is still owed

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
| 1 | **#54** | The run result carries a verdict without its reason and no field common to both modes. |

**#56 shipped in 0.3.2** and is removed rather than ticked: `Get-PSMutationScore` is a per-set
fold again, so per-file scores in Wave E are no longer blocked by it.

**#54 and #63 are split, on evidence.** They were paired on the assumption that each new mode
threads another parameter list -- and three fixes later, two of them added *zero* parameters.
`Exclusion` turned out to be the argument AGAINST a context object rather than for one: it must
**not** reach the recheck path, which does no coverage filtering, and a context object carries
every field everywhere. #63 keeps waiting. #54 got stronger over the same period -- three
numbers that qualify a score now live in the report and not in the run result, so CI's mutation
gate prints a bare percentage and cannot say what failed.

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

## The sibling repo, and the release path

- **#117** -- the parity tracker. The two Fortigi modules gate each other, so it is easy to
  assume their CI is comparable; it was not, and nothing compared them. Most rows are closed
  now on both sides. The one that mattered here was the OS matrix: this module's headline
  guarantee is a PATH property and it was proven on one platform, while the pure AST analyser
  next door was proven on two. Keep the tracker until the last row is closed.
- **#115** -- nothing fails when `main` claims a version already on the gallery. Still open,
  still cheap, and now the only remaining item on the release path.

  *#116 (a second person for an irreversible publish) is closed as decided, not done.* Tag
  creation, update and deletion are now restricted to a one-person team, so who may publish is
  enforced rather than assumed -- proven by a push that was refused when the bypass was removed.
  A genuine four-eyes rule needs a smaller admin set, which is an organisation setting across
  thirteen repositories; a separate org would buy it and was declined. Worth knowing before
  reaching for the same idea again: a `tag_name_pattern` ruleset **looks** like it constrains
  tag names and does not -- GitHub accepts the configuration and never evaluates the rule.

## Low-coupling, good fillers

Pick these up between waves; none blocks anything.

- **#63** no run-context object. Re-measured after three fixes went through that seam, and the
  case got *weaker*: two of the three added no parameters at all. Revisit when a value is
  genuinely shared by three or more callees, not before.
- **#39** interrupted runs -- see the note above; likely cheaper than its pairing with #1 implies.
- **#49** child runspace script is an unparsed string.
- **#41** missing `about_PSMutant`. **Smaller than its title implies, twice over.** The title
  also says two of three exports are undocumented -- there is one export now, so that half is
  gone. And the real defect underneath it was found and fixed separately: a `<# #>` file header
  shadowed the public help, so `Get-Help` served the file's architecture notes instead of the
  documentation. Parameters, examples and the synopsis are complete now and pinned by tests.
  What remains is the topic the help still points at and which does not exist.
- **#36** end-to-end exact counts, **#43** cross-Context `$script:` coupling, **#35** consumer-shaped layout.
- **#22** sandbox self-mutation, **#9** killed-by map.
*#89 is gone.* Both halves shipped, and the split was real: Dependabot for the action SHAs,
  because `uses:` does not expand variables and looking at a SHA tells you nothing about
  whether something newer exists; a weekly job over `.github/pins.env` for the modules. It
  earned itself on day one, finding two stale action SHAs per repo.

  One thing came out of running it that reading could not have found: the first version asked
  "is there a newer version" of every pin and reported `PESTER_COMPAT_VERSION` 5.8.0 as stale
  against 6.1.0. Acting on that would have been exactly wrong -- that pin is deliberately old
  so the compatibility guard runs under the Pester the suite does NOT use, and at 6.1.0 it
  would equal the estate pin and prove nothing, while looking more up to date than a pin that
  works. Its invariant is difference, not freshness.

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

