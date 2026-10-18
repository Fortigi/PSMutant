@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.8.0'
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
            ReleaseNotes = '**Killed mutants are much cheaper: the tests that killed a neighbour run first.** Once a mutant is
killed, its killing tests are remembered, and each later mutant in the same function, then the same
file, first runs up to three of them alone; only if none fails do its whole covering files run. A test
is trusted for this only after it has passed on its own against unmutated source, checked once on an
idle worker -- so a test that depends on an earlier test''s state is never tried alone, and verdicts
are unchanged. On by default; the new `killersFirst` config key turns it off, and `recordAllKillers`
does too. **The test a report names in `KilledBy` can change**, and with several workers can differ
between two runs of the same config. Measured interleaved on this repo''s own runner file, 307
mutants with three workers over two rounds each way: wall clock 931 and 924 seconds off, 703 and 729
on -- about 22% less -- every mutant killed both ways. A first pass gets its own short deadline,
sized from how long its tests took alone, so a mutant that hangs them is not held for the whole
files'' deadline before they run.

**With more than one worker, each worker is a `pwsh` process of its own, and runs scale further.**
Workers used to be runspaces in PSMutant''s process, sharing one GC heap, and stopped gaining at
about four. Measured against PSComplexity''s whole self-mutation config, 1424 mutants with identical
verdicts in every run: at `workers: 8`, 426 and 438 seconds before, 251 and 255 after; at
`workers: 3` pinned to four cores, as a CI runner has, 376 and 380 before, 282 and 326 after. One
worker still runs in PSMutant''s own process, where it is as fast and pays for no process start.
Two parallel-safety hazards go with the shared process: a test that writes an environment variable
now writes its own worker''s, and `$PID` names one worker. **A mutant that ends its worker''s
process** -- `[Environment]::Exit`, or a recursion that overflows the stack -- is scored `Killed`
with no test named, and the worker is replaced; an unmutated covering suite that does so is refused
before the first mutant. A worker process is renewed every 500 mutants rather than every 50: a new
process compiles Pester and your code afresh, which at 50 cost more than the processes saved.

**A mutant that stops the tests from being found is no longer a survivor.** When mutated code
reaches `exit` while a test file is being discovered -- in a function a `BeforeDiscovery` calls for
its cases, say -- the file''s tests are never found, and Pester calls a run of no test `Passed`.
Such a mutant was scored Survived, as though the tests had looked and missed it. It is now a
`RuntimeError`: left out of the score, counted in `runtimeErrors`, and named on the summary line.
For the same reason, an unmutated covering suite that runs no test in a worker -- every test
skipped or never discovered -- now refuses the run before any mutant, naming the suite, where its
mutants used to be scored as survivors over tests that never ran. A mutant reaching `exit` anywhere
else was already contained: inside a test it fails that test, and at the top of a dot-sourced file
it ends only that file. `[Environment]::Exit()` ends the process and still cannot be contained; the
README says to leave code that calls it out of `mutate`.

**An equivalent mutant can be declared in the code.** A `# PSMutant-Equivalent: <original> ->
<mutated>: <reason>` comment on the line directly above a mutated line declares that mutant
equivalent. It becomes the same `file:line:description` key a config entry would, so it faces the
same checks -- it must match exactly one mutant, and the run fails if the suite kills it -- and it
moves with the code instead of going stale on an edit above it. A declaration that cannot become a
key (a blank line below it, code beside it, no description or no reason) is refused before anything
is mutated. One mutant declared twice -- in the code and in the config, or under both of a config''s
key forms -- is now refused by name, where before the second key was reported as matching no
mutant.

**Logging calls are no longer mutated.** Mutants inside the arguments of `Write-Verbose`,
`Write-Debug`, `Write-Information`, `Write-Host` and `Write-Progress` are skipped, because the text
of a log line rarely tells you anything about your tests. The new `ignoreCalls` config key replaces
that list, and `[]` turns it off. Every operator''s mutants inside such a call are skipped, and the
number is printed beside the score and written to the report as `skippedAsIgnoredCall`, with the
list applied as `ignoreCalls`; neither is counted in `total` or either score. Mutant ids do not
change, so a recheck still matches. **This can lower your mutant count after upgrading** -- a run
that mutated inside logging calls before will now skip those mutants; set `"ignoreCalls": []` to
keep the old behaviour. `Write-Warning`, `Write-Error` and `throw` are not in the default, because
tests often assert those messages. A `-ListOnly` result carries the count as `Ignored`.

**Patterns in `mutate` and `tests`, and pairing by name.** An entry holding `*` or `?` is a pattern,
read as PSComplexity reads its config''s `exclude`: `*` and `?` stay within one path segment, `**`
spans any number of them, and a pattern also matches everything below what it names. Patterns are
expanded once at start-up, before anything else reads the lists, and the files each matched are
printed, so the run still names exactly what it covers. A pattern matching no file is refused,
naming every such pattern at once. The new `testsByConvention` switch pairs a mutate file that has no
`tests` entry with `tests/<Name>.Tests.ps1` when that exists; an explicit entry always wins, each
pair is printed, and `tests` may then be `{}`. Off by default, so upgrading changes no mapping.
Matched without regard to case on every platform, as every other path here is.'
        }
    }
}
