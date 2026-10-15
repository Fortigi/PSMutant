@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.7.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.2.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5.2.0 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.0'

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
            ReleaseNotes = '**The report format is version 3: a mutant''s `Status` can be `TimedOut`, `CompileError` or
`RuntimeError`, and the version 2 schema rejected the first of those already.** A timed-out mutant
has always been written with `Status: TimedOut`, and `schemas/v2` allowed only `Killed` and
`Survived` -- so any report with a timeout in it failed the schema this module shipped. Version 3
defines all five. `TimedOut` still counts as killed. A mutant whose mutated source does not parse is
now recorded `CompileError` without running any test, where before it was run and scored a kill;
every operator works on the syntax tree, so one is a PSMutant defect -- please report it.
`RuntimeError` is defined for a run that ends without a verdict. Both are left out of the score and
counted in the new `compileErrors` and `runtimeErrors`, which, with `timedOut`, are now required
beside a score. `durations.perMutantTimeoutSeconds` is defined as the largest deadline any mutant got,
which is today''s only one. **A reader validating against `schemas/v2` must move to `schemas/v3`;**
v2 and v1 still ship, to validate archived reports.

**Two runs starting at once on one machine no longer kill each other at startup.** Every run
sweeps temp for sandboxes left by killed runs. Two sweeps at the same moment found the same leftover
and both removed it, and the loser''s `Remove-Item` threw "An object at the specified path ... does
not exist" -- a terminating error, which the sweep''s `-ErrorAction SilentlyContinue` does not
contain -- so a run died before it did anything. A removal that fails because the item is already
gone is now the outcome the sweep wanted; one that fails while the item remains is still an error.

It mattered to this module''s own gate too: with several workers, mutants of the sandbox code ran
the sweep''s tests side by side, and a covering run that failed on the race scored its mutant Killed.

**A suite that is green only because of your session is refused, instead of scoring 100%.**
The baseline runs your suite in the session you call `Invoke-PSMutation` from, with whatever that
session has loaded: modules, global functions and variables, `$ErrorActionPreference`, strict mode,
`$PSDefaultParameterValues`. Each mutant runs in a fresh runspace that has only Pester. A test that
leaned on the session passed the baseline and failed for every mutant, for a reason that had nothing
to do with the mutant, and every mutant was scored Killed: a perfect score with nothing to flag it.

Before the first mutant, every covering suite the run will use now runs once, unmutated, in every
worker''s runspace and sandbox -- the same shell and script a mutant gets. A suite that fails there,
returns nothing, or overruns the per-mutant timeout refuses the run, naming the suite, the worker and
the failed tests. The workers check in parallel, so the cost is about one pass over the covering
suites. A `-RecheckFrom` run checks only the suites its survivors use. If a run of yours is now
refused, make the failing test load what it needs itself, in its own `BeforeAll`.

**A suite that imports the code under test is judged on each mutant''s own code.** A worker reuses
its runspace for many mutants, and `Import-Module` without `-Force` returns a module that is already
loaded -- so a test importing the file under test ran later mutants against an earlier mutant''s code,
producing kills and survivals about code that was not running. Every module loaded from the sandbox
is now unloaded before each mutant, so the next import reads the file as it is; a module defining a
class reloads the same way. Dot-sourcing was never affected.

Two things PowerShell keeps for the life of the process are refused instead, naming file and line:
`using module <path>` of the code under test, which stays at the first version loaded even in a
fresh runspace, and a mutant inside an `Add-Type` call, whose type cannot be compiled twice. The
README''s new "How your tests should load the code under test" says what works.

**A mutant stuck in a blocking call no longer stalls every other worker.** Stopping a timed-out
mutant waited for the call it was stuck in to return -- 7.4 seconds for an 8-second
`Thread.Sleep`, and longer for a runaway regex -- and the scheduler waited with it, so every worker
stood idle and the stall check could abort the run blaming a machine that had slept. The stop is now
requested without waiting, and the worker carries on with a fresh runspace at once.'
        }
    }
}
