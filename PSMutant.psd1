@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.6.0'
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
            ReleaseNotes = '**Mutants on the later lines of a multi-line statement are evaluated now, and your score may go
down.** `coveredLinesOnly` keeps a mutant only on a line the baseline executed, and a line used to
count as executed only when a command STARTED on it. So the second line of a condition split over
two lines, a continued argument list or a message built from several strings was never covered,
although the statement ran, and every mutant there was dropped from the score in silence while
the coverage gate reported 100% over the same code.

A line is now covered when the innermost command spanning it ran. That is narrower than "any
command spanning it": a pipeline that ran does not cover the body of a script block that never
executed, so those mutants are still skipped rather than handed to the loop to survive. Checked
against a real Pester coverage run, not only against hand-built records.

**What to expect.** `skippedAsUncovered` falls, and the mutants it used to hide are evaluated.
Any that survive are real gaps: a comparison on the second line of a condition, say, that no test
pins. The same tests can therefore score lower than before, so a `thresholds.break` gate can go
red on upgrade. That is the gate measuring code it used to skip, not the code getting worse.

A `param()` default is still never covered: no command spans it, so nothing Pester instruments
can say whether it ran.

**A SARIF log of the survivors, with `"sarifPath"`.** Set it and a run also writes a SARIF 2.1.0
log, which GitHub code scanning and Azure DevOps Advanced Security turn into alerts that open,
persist and close across runs:

```json
{ "reportPath": "reports/ps-mutation.json", "sarifPath": "reports/ps-mutation.sarif" }
```

One rule per operator the run applied, `warning` level, and no alert for a declared equivalent.
Each alert is fingerprinted by `file:function:description` -- the address an equivalence declaration
uses -- never by mutant id or line, so an unrelated edit above a survivor does not close and reopen
it. A run with no survivors writes a log with no results, which is what closes old alerts.

Only a run that scored writes one. A `-ChangedFile` run writes `<name>.changed.sarif` beside the
configured file, never over it, and a `-RecheckFrom` run, a `-ListOnly` preview and an interrupted
run write none: a code-scanning service reads a missing result as a fixed one, so a partial log
would close every alert it did not re-examine. The log names no category of its own -- on GitHub a
category in the file overrides the upload step''s -- so give one in the pipeline (`category:` on
upload-sarif, `Category:` on `AdvancedSecurity-Publish@1`).

Checked with the SARIF validator''s GitHub Advanced Security and Azure DevOps rule sets: it passes
both, apart from the category, which is left to the pipeline on purpose.

**The stale-sandbox sweep no longer deletes a live run''s files on Windows.** At startup a run
reclaims sandboxes and coverage files whose owning process is gone, and treats an id that has been
reused as gone too: an owner that started after the file was made cannot have made it. That test
read the file''s CREATION time, and two things on Windows can make a live owner''s fresh file look
older than its owner -- a file stamp is only as fine as the timer tick, and NTFS hands a name that
was deleted and recreated moments later its old creation time. The sweep now reads the last WRITE
time, with two seconds of slack, so a concurrent run''s working files are left alone. Real id reuse
leaves a far larger gap, so leftovers are still reclaimed.

**Survivors are annotated under Azure Pipelines too.** Under GitHub Actions a survivor has always
been printed as a `::warning` workflow command. Under Azure Pipelines (`TF_BUILD=True`) it is now
a `##vso[task.logissue type=warning;...]` command, which lists it in the build summary linked to the
line. As before, `-Quiet` does not silence it, and nothing is printed outside a CI.

New in the README: how to get survivors onto a pull request, on both platforms, and
`examples/azure-pipelines.yml`, a complete Azure pipeline -- a full run on `main`, a `-ChangedFile`
run on pull requests, and both ways of publishing the log.

The SARIF log and the Azure annotations move no score and change no existing output. The config
gains one optional key.

**A red baseline says where to look when no failing test said why.** The refusal names the failing
tests and the first line of each one''s error. When NONE of them carried an error -- the shape of a
`BeforeAll` that died, whose error Pester attaches to the test file, or of a damaged Pester install
that fails even a test with no assertion -- the names alone point nowhere, so the message now says
so and names both places to look.'
        }
    }
}
