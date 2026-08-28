@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.4.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.2.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5.2.0 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.2'

    # One function. Get-PSMutationCandidate and Set-PSMutationText used to be exported too,
    # and between them they trafficked a nine-field [pscustomobject] that nothing declared,
    # tested as a contract or versioned -- discoverable only by running the function and
    # inspecting the output, and unchangeable once someone had. Neither was ever mentioned in
    # the README, and Set-PSMutationText had exactly one caller, inside this module (#48).
    #
    # "What would you mutate?" is a fair question to ask, and the answer should be a rendering
    # this module controls -- see #10's -ListOnly -- not a raw AST walker handing out its
    # internals.
    FunctionsToExport = @('Invoke-PSMutation')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # NO RequiredModules entry for Pester, deliberately. ModuleVersion there is a MINIMUM
    # and PowerShell satisfies it by importing the NEWEST installed version -- at import
    # time, before Assert-PSMutationPester or Get-PSMutationPesterPath can have a say. That
    # made `Import-Module PSMutant` followed by `Import-Module Pester -RequiredVersion 5.7.1`
    # fail on an assembly collision and leave the caller on 6.1.0, while the same two lines
    # in the other order worked -- issue #16's failure one layer up, with no diagnostic.
    #
    # Pester is needed at RUN time, not import time, and Assert-PSMutationPester is the single
    # point that enforces it: it accepts an already-loaded Pester >= 5, imports one only when
    # none is loaded, and refuses with an actionable message otherwise. The cost is that
    # Install-Module PSMutant no longer pulls Pester in for you; that is stated in the
    # description, the README and the error message.

    PrivateData = @{
        PSData = @{
            Tags         = @('mutation-testing', 'testing', 'pester', 'ast', 'quality', 'test-quality', 'coverage')
            LicenseUri   = 'https://github.com/Fortigi/PSMutant/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Fortigi/PSMutant'
            ReleaseNotes = '**The PowerShell floor is executed now, not just declared.** `PowerShellVersion = ''7.2''` was set in
the first commit and never touched, while CI ran whatever the runners shipped -- several minors
newer -- so the number consumers were told had never been run. A gate now downloads **every
supported host, one leg per minor**, and requires each to produce the *same mutant verdicts* the
launching host measured, not merely the same score: two hosts can agree on a percentage while
disagreeing about which mutants died. 7.2, 7.3, 7.4 and 7.5 all match exactly.

**If you are on PowerShell 7.2 or 7.3, use Pester 5.x, not Pester 6.** Measured while building
that gate: Pester 6.1.0 fails on PowerShell 7.2 with `Unable to find type [PesterConfiguration]`
and works on 7.4, while its own manifest claims it needs only PowerShell 5.1. That is Pester''s
constraint rather than this module''s, but PSMutant drives Pester, so it lands on you either way and
is better said out loud than discovered.

**The Pester floor is 5.2.0, not 5.0.0, and it is now executed rather than declared.** The
manifest and README promised 5.0.0 and the gate ran exactly one version, so the number consumers
were given had never once been tried. Pointed at it, the module fails: PSMutant calls
`New-PesterConfiguration`, which **arrives in 5.2.0** -- measured across every installed version,
not looked up -- and the baseline cannot do without it, because code coverage cannot be configured
through the simple parameter set. Under 5.0.x and 5.1.x the command is not found, PowerShell
autoloads `Pester` by NAME to the newest installed, and that collides with the `Pester.dll` already
in the process.

If you are on 5.0.x or 5.1.x, PSMutant did not work for you before this release either; it now says
so instead of failing with an assembly-version error that never mentions this module. The gate runs
**one leg per minor** from 5.2.2 to 6.1.0, each in its own process, so the floor is proven rather
than asserted. Floor-plus-latest was considered and rejected: a defect arriving mid-range is
invisible at both ends, which is exactly the shape of this one.

**Several of these make a run that used to pass fail, and one makes a score go down. In every case
the new answer is the honest one.**

**SECURITY -- the mutation sandbox no longer uses a predictable path.** It was
`$TMPDIR/psmut-sandbox-<pid>`, and creating it began by removing whatever was already there. On a
shared machine another local user can create that path first as a symlink to a directory they own:
your `Remove-Item` of THEIR entry fails on the sticky bit, the failure is non-terminating, the run
carries on, and your source is copied through the link. Reproduced with two real users on a current
kernel -- `fs.protected_symlinks` does not help, because it guards only the FINAL path component and
the planted link is an intermediate one. The sandbox is where your tests run from, so whoever
controls it can substitute a file between the copy and the run.

Sandboxes now carry 128 bits from a cryptographic RNG, an existing path is **refused rather than
cleared**, and what was created is checked to be a plain directory. The stale sweep still reclaims
old-style names, and now skips symlinks instead of deleting through them. One residual, stated
rather than left to be found: the sandbox is world-READABLE while a run lasts, because it is created
with your umask. Closing that needs `File.SetUnixFileMode`, which is .NET 7 and above this module''s
floor. The unguessable name closes the write-through attack; a reader must still find the name.

**A mutant that ran out of time is no longer counted as a kill.** A timeout scored exactly like a
test noticing the change, so a suite too slow for its budget reported mutants as caught that nothing
had caught. Timeouts are their own outcome now, reported separately. If your score drops after
upgrading it did not get worse -- it stopped counting the clock as a test.

**Runs are about three times faster, and no score moves.** A fresh runspace was created and Pester
imported into it for every mutant -- about 396 ms each, 219 s of an 801 s run spent re-importing a
module that does not change. It is now built once and reused. And a mutant asks one question, does
ANY test notice, so the covering suite stops at the first failure: a killed mutant''s 2.03 s suite
finishes in 0.34 s, while a survivor is unaffected by construction. Measured end to end on a real
consumer repository, interleaved: **221 s -> 71 s** over 225 mutants, 225 killed, score 100 on both
sides, every per-mutant verdict identical.

The fail-fast half needs `SkipRemainingOnFailure`, which arrived in **Pester 5.3.0**, and is set
only when the loaded Pester has it -- so 5.2.x simply misses that part of the speedup.

**`ConditionForcing` now reaches the ternary operator and every `switch` clause, `default`
included.** It looked for one node type, `IfStatementAst`, so `$x = $cond ? $a : $b` was invisible
to it and to every other operator: a ternary compiles to no if-node, and a bare-variable condition
offers no comparison, literal or negation to touch.

A clause is forced to a SCRIPT BLOCK, not a bare value -- PowerShell matches with `$_ -eq <clause>`,
so `1` forced to `$true` merely changes what is compared. `1 { "one" }` becomes `{ $true } { "one" }`,
which always matches and shadows every later clause, or `{ $false } { "one" }`, which makes it dead.
Shadowing is the fault worth catching: a clause that swallows the ones below it is a real bug no
expression operator reaches. `default` is the one switch decision not on the AST -- only its BODY is
-- but the keyword is an ordinary token, so forcing it yields a switch whose fallback is dead. On a
235-file consumer the operator goes from **4404** candidates to **4548**.

**An absolute `reportPath` is honoured instead of being rewritten.** `Join-Path` concatenates rather
than letting a rooted right-hand side win, so `/var/artifacts/report.json` became
`<SourceRoot>/var/artifacts/report.json` -- written somewhere you did not ask for, with no error,
inside the tree this module otherwise never writes to. A CI step pointing at an artifacts directory
outside the checkout found nothing to upload. Relative paths still resolve against `-SourceRoot`,
`../shared/report.json` still climbs above it, and `recheckPath` is fixed with it.

**The run result now says WHY it failed.** `ExitCode 1` meant either a score under
`thresholds.break` or a stale equivalence declaration, and nothing said which -- so a run scoring
100% with one stale declaration failed with whatever reason your workflow had hardcoded. The result
carries `FailureReason` (`None` / `StaleEquivalents` / `BelowThreshold`), the stale list and the
declared-equivalent count. Nothing existing changed meaning.

**A recheck result now carries `ExitCode` and `Mode` too, and this fixes a live bug.** The two
shapes shared no field, so `if ($result.ExitCode -ne 0) { throw }` -- the idiom this README taught
-- compared `$null` against `0` and threw on a successful recheck, while `exit $result.ExitCode`
became `exit $null`, which is `0`, and passed even when every prior survivor was still alive. A
recheck `ExitCode` is always `0`; `StillSurviving` is the number to read.

**The report no longer publishes `"filesWithoutTestMapping": [null]`** -- an array holding one
`null` where the honest answer is `[]`. It was the DEFAULT path, so most reports carried it, and a
consumer listing the files that fell back to the whole suite got an entry that is not a file. All
three list fields now share one normaliser, and `filesWithNoMutants`, `filesWithoutTestMapping` and
`skippedAsUncovered` are **declared in the report schema** for the first time and required on a full
run -- their absence is why nothing caught this, since undeclared fields validate cleanly by design.

**The coverage XML no longer piles up in your temp directory.** The baseline wrote Pester''s coverage
report to `$TMPDIR/psmut-coverage-<pid>.xml` and nothing deleted it: the startup sweep matched
*directories* named `psmut-sandbox-*`, so it could not match that file by construction. 67 had
accumulated on the machine this was found on. It now goes inside the sandbox, which is already
removed when the run ends, and the sweep reclaims what older versions left behind.

**A report that cannot be written now fails the run.** Writing the JSON failed non-terminatingly, so
an unwritable path left the run reporting success with no artefact behind it. That is the shape of
failure this tool exists to find, and it was in the tool.

**A number now answers for what was left out of it.** Candidates dropped by the covered-lines filter
are recorded beside the score, so a figure computed over less code than you asked for says so.

**A `tests` key that names no file in `mutate` is refused.** It covered no mutant, its test files
still joined the baseline''s set, and the file it was meant to name had no entry -- so all of that
file''s mutants fell back to running your whole suite. A typo made runs far slower while the score
stayed believable. `_`-prefixed comments belong at the top level, not inside `tests`.

**Three more config mistakes are refused instead of quietly changing what runs.** A file listed
twice in `mutate` doubled its mutants and its weight in the score. A `mutate` file with no `tests`
entry silently ran your whole suite per mutant. And a path escaping the source root was mutated
where it lives rather than in the sandbox -- interrupt such a run and the mutated file stayed on
disk. Paths merely containing `..` that still resolve inside, like `src/../src/a.ps1`, keep working.

**Under GitHub Actions, survivors now appear on the pull request diff.** One warning per survivor,
against its file and line, so a failing gate says what survived rather than only what it scored.
Nothing is emitted outside a recognised CI.'
        }
    }
}
