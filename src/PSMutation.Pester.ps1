<#
.SYNOPSIS
    Everything this module knows about Pester: which one is loaded, where it lives, and
    the contract a child runspace imports it under.

.DESCRIPTION
    This is the module's boundary with the one dependency it cannot abstract. It exists
    as its own file because the same three-step resolution used to be written out twice
    -- once to validate a version, once to hand a path to every child runspace -- in two
    files that had no reason to be read together (#38).

    They must agree on WHICH Pester. If they ever diverge the process validates one
    version and mutates under another, which is issue #16 reproduced from the inside:
    a child runspace that dies on an assembly collision returns no verdict, and a mutant
    with no verdict was scored Killed, so the run reported a silent and entirely fake
    100%. One definition, in one place, is the fix.
#>

$script:PSMutationPesterRequired = 'Pester 5+ is required. Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser'

function Get-PSMutationLoadedPester {
    <#
    .SYNOPSIS
        The Pester this process has already loaded, or $null if none is.
    .DESCRIPTION
        The single answer to "which Pester", because both callers below must reach the
        same one -- see this file's header for what divergence costs.
    .OUTPUTS
        [psmoduleinfo] the loaded module, or $null.
    #>
    [OutputType([psmoduleinfo])]
    [CmdletBinding()]
    param()
    # Highest wins: two Pester 5.x releases CAN coexist in one process (the dll guard
    # only rejects a LOWER loaded version), and the newer of them is the one whose
    # assembly is actually serving calls.
    return Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1
}

function Assert-PSMutationPester {
    <#
    .SYNOPSIS
        Make sure a usable Pester is available, WITHOUT pulling in a second one.
    .DESCRIPTION
        `Import-Module Pester -MinimumVersion 5.0.0` is not the no-op it looks like when
        a satisfying Pester is already loaded: PowerShell re-resolves the name against
        PSModulePath, picks the NEWEST version installed, and on a machine that has two
        it collides with the Pester.dll already in the process -- which is fatal, and
        happens before a single mutant runs.

        So an already-loaded Pester is checked and accepted as it is, and the import
        only happens when nothing is loaded at all. That is also what lets the module
        honour the >= 5.0.0 in its manifest: it runs under the caller's Pester rather
        than choosing one for them.
    #>
    [CmdletBinding()]
    param()
    $loaded = Get-PSMutationLoadedPester
    if ($loaded) {
        if ($loaded.Version -lt [version]'5.0.0') { throw $script:PSMutationPesterRequired }
        return
    }
    if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge '5.0.0')) {
        throw $script:PSMutationPesterRequired
    }
    Import-Module Pester -MinimumVersion 5.0.0
}

function Get-PSMutationPesterPath {
    <#
    .SYNOPSIS
        File path of the Pester ALREADY LOADED in this process, so a child runspace can
        import that one by path instead of resolving the name for itself.
    .DESCRIPTION
        A fresh runspace resolves `Pester` by NAME against PSModulePath and gets the
        NEWEST version installed -- which is not necessarily the version this process
        already loaded. Assemblies are per-process, so when the two differ the child
        dies on "An incompatible version of the Pester.dll assembly is already loaded".
        A child that dies produces no verdict, and a mutant with no verdict used to be
        classified Killed: on any machine with two Pesters installed, every mutant died
        and the run reported a silent, entirely fake 100%.

        Importing by PATH is what makes the module version-agnostic in the way the
        manifest promises: whatever Pester >= 5 the consuming repo runs, the mutant
        runs under that same one.
    .OUTPUTS
        [string] path to the loaded Pester module file.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $loaded = Get-PSMutationLoadedPester
    if (-not $loaded) {
        throw 'Pester is not loaded in this session, so a mutant cannot be run against it.'
    }
    return $loaded.Path
}

function Get-PSMutationBoundedPesterScript {
    <#
    .SYNOPSIS
        The script a mutant's child runspace runs: import the pinned Pester, run the
        covering tests, emit the one-word result.
    .DESCRIPTION
        Named rather than inlined because it is the child's whole contract. Two things
        in it are load-bearing and easy to "simplify" away:

        * `Import-Module $pester` imports by PATH. Importing by name lets the runspace
          resolve Pester itself, which picks the newest installed rather than the one
          this process loaded -- the collision Get-PSMutationPesterPath exists to stop.
        * `-ErrorAction Stop` makes a failed import terminate the child, so the caller
          gets an exception instead of an empty result that reads as a dead mutant.
    .OUTPUTS
        [string] the script text.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return @'
param($tests, $pester)
Import-Module $pester -Force -ErrorAction Stop
$c = New-PesterConfiguration
$c.Run.Path = $tests
$c.Run.PassThru = $true
$c.Output.Verbosity = 'None'
(Invoke-Pester -Configuration $c).Result
'@
}
