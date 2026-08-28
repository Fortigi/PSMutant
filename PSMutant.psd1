@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.4.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.0.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
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
            ReleaseNotes = '**The coverage XML no longer piles up in your temp directory.** The baseline wrote Pester''s
coverage report to `$TMPDIR/psmut-coverage-<pid>.xml`, and nothing ever deleted it: the startup
sweep matched *directories* named `psmut-sandbox-*`, so it could not match that file by
construction. They accumulated for the life of the machine -- 67 of them on the box this was found
on. The file is never read back; it exists only because Pester writes one somewhere and its default
is a `coverage.xml` in your working tree.

It now goes inside the sandbox, which is already removed when the run ends, so the cleanup is the
one that already exists rather than a second one to keep in step. The startup sweep also reclaims
the files older versions left behind, so upgrading clears them rather than orphaning them. As a side
effect it removes another predictable write into world-writable temp -- the same shape as the
sandbox path, lesser because the content is coverage data rather than source, but there was no
reason to keep one after removing the other.

**Runs are about three times faster, and no score moves.** Two costs went, both paid on every
mutant. A fresh runspace was created and Pester imported into it for each one -- measured at about
396 ms, which over a real 801 s run was 219 s, 27%, spent re-importing a module that does not change
between mutants. The runspace is now built once and reused. And a mutant only ever asks one question
-- does ANY test notice -- so once one has, every test after it is work whose outcome cannot change
the verdict; the covering suite now stops at the first failure. A killed mutant''s 2.03 s suite
finishes in 0.34 s; a SURVIVOR is unaffected by construction, because nothing fails and so nothing
is skipped.

Measured end to end against 0.4.0 on a real consumer repository, interleaved, two pairs:
**221 s -> 71 s** over 225 mutants, with 225 killed and a score of 100 on both sides and every
per-mutant verdict identical.

The fail-fast half needs `SkipRemainingOnFailure`, which arrived in **Pester 5.3.0**. It is set only
when the loaded Pester has it, so nothing changes for a consumer on 5.0.0 to 5.2.x beyond not
getting that part of the speedup -- the module still promises, and still honours, Pester >= 5.0.0.

**SECURITY -- the mutation sandbox no longer uses a predictable path.** It was
`$TMPDIR/psmut-sandbox-<pid>`, and creating it began by removing whatever was already there. On a
machine you share with anyone else that is a hole: another local user creates that path first as a
symlink to a directory they own, your `Remove-Item` of THEIR entry fails because the sticky bit
protects it, the failure is non-terminating so the run carries on, and your source is copied through
the link. Reproduced end to end with two real users on a current kernel -- `fs.protected_symlinks`
does not prevent it, because that guard covers only the final path component and the planted symlink
is an intermediate one. The exposure is larger than disclosure: the sandbox is where your tests RUN
FROM, so whoever controls it can substitute a file between the copy and the run.

Sandboxes are now created under a name carrying 128 bits from a cryptographic RNG, a path that
already exists is **refused rather than cleared**, and what was created is checked to be a plain
directory rather than a link. The stale sweep still recognises and reclaims sandboxes named the old
way, so nothing left by a previous version is orphaned, and it now skips symlinks rather than
recursively deleting through them. On a single-user machine this changes nothing you will notice
beyond longer names in temp; on a shared box or a multi-tenant build agent, it is the reason to take
this release.

One residual is stated rather than left to be discovered: the sandbox is created with your process
umask, so it is world-READABLE while a run lasts. Closing that needs `File.SetUnixFileMode`, which
is .NET 7 and above this module''s PowerShell 7.2 floor. The unguessable name closes the
write-through attack; a reader still has to find the name first.

**Two of these make a run that used to pass fail, and one makes a score go down. In every case
the new answer is the honest one.**

**The run result now says WHY it failed, not just that it did.** `ExitCode 1` meant either a score
under `thresholds.break` or an equivalence declaration that had gone stale, and nothing in the
returned object told you which -- so a run scoring 100% with one stale declaration failed with
whatever message your workflow had hardcoded, usually "below the break threshold", which was simply
untrue. The result carries `FailureReason` (`None` / `StaleEquivalents` / `BelowThreshold`) plus the
stale list and the declared-equivalent count. Nothing existing changed meaning; branch on
`FailureReason` before printing a reason.

**A recheck result now carries `ExitCode` and `Mode` too, and this fixes a live bug.** The two
shapes shared no field at all, so `if ($result.ExitCode -ne 0) { throw }` -- the idiom this README
taught -- compared `$null` against `0` and threw on a perfectly successful recheck, while
`exit $result.ExitCode` became `exit $null`, which is `0`, and passed even when every prior survivor
was still alive. A recheck `ExitCode` is always `0`: it applies no thresholds by design, and
`StillSurviving` is the number to read.

**A mutant that ran out of time is no longer counted as a kill.** A timeout was scored exactly
like a test noticing the change, so a suite too slow for its budget reported mutants as caught
that nothing had caught. Timeouts are now their own outcome and are reported separately. If your
score drops after upgrading, it did not get worse -- it stopped counting the clock as a test.

**A report that cannot be written now fails the run.** Writing the JSON failed
non-terminatingly, so an unwritable path left the run reporting success with no artefact behind
it. That is the shape of failure this tool exists to find, and it was in the tool.

**A number now answers for what was left out of it.** Candidates dropped by the covered-lines
filter are recorded in the report beside the score, so a figure computed over less code than you
asked for says so rather than reading as a clean sweep.

**A `tests` key that names no file in `mutate` is refused.** It covered no mutant, its test files
still joined the baseline''s set, and whichever file it was meant to name had no entry at all -- so
every one of that file''s mutants fell back to running your whole suite. A typo made runs far slower
while the score stayed believable. If your config has one, the message names it; `_`-prefixed
comments belong at the top level, not inside `tests`.

**Three config mistakes are refused instead of quietly changing what runs.** A file listed twice
in `mutate` doubled that file''s mutants and its weight in the score. A `mutate` file with no
`tests` entry silently ran your whole suite for every one of its mutants. And a path that escapes
the source root was mutated where it lives rather than in the sandbox -- interrupt such a run and
the mutated file stayed on disk. Paths that merely contain `..` and still resolve inside, like
`src/../src/a.ps1`, keep working.

**Under GitHub Actions, survivors now appear on the pull request diff.** One warning per survivor,
against the file and line it is in, so a failing gate says what survived instead of only what it
scored. Nothing is emitted outside a recognised CI.'
        }
    }
}
