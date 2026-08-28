# The pass/fail decisions behind the CI parity gate, as pure functions over workflow text.
#
# They live apart from the script that reads the files for the same reason the release decisions
# do: a gate that quietly stops being able to fail looks exactly like a green build, and this one
# is watching the workflows every other gate runs inside.
#
# What this gate is FOR is drift between two repositories, not the correctness of one. This module
# and the one it is paired with gate each other, so it is easy to assume their CI is comparable --
# and for a long time it was not, in thirteen ways, with nothing comparing them. The rules below are stated as
# SHAPE rather than by file name (an action pinned to a SHA, a lint gate that is not spelled
# inline) so that this file is byte-identical in both repos apart from the command prefix. Diffing
# the two copies is then the comparison, and a rule one repo declines is a deletion somebody has to
# argue for in a diff rather than a silence.
#
# Text, not a parsed document, and that is a deliberate limitation: PowerShell has no YAML parser
# in the box, pinning one would add a dependency to the gate that watches the dependencies, and
# every rule here is about a line that either appears or does not.

function Get-PSMutantWorkflowCode {
    # Workflow text with comments removed, for the rules that ask what a workflow DOES.
    #
    # A capability named only in a comment is not a capability, and the two are indistinguishable
    # to a grep: another repository's code-scanning.yml spends six lines of prose on
    # Invoke-ScriptAnalyzer explaining why it does NOT call it, which reads as an inline lint gate.
    #
    # A hash opens a comment where it starts a line or follows whitespace -- YAML's rule and
    # PowerShell's. Inside a quoted string it does not, and that case is deliberately NOT handled:
    # both repos hold one, and no rule here asks about the rest of that line, so the cost is nothing
    # and the alternative is a quoting parser nobody would trust either.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Line)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $Line) { $out.Add(($l -replace '(^|\s)#.*$', '')) }
    return $out.ToArray()
}

function Get-PSMutantWorkflowFact {
    # Everything the rules ask about one workflow, read once.
    #
    # Separated from the judging below because the parsing is where a regex is wrong and the judging
    # is where an inversion hides, and those are worth failing separately.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Line
    )
    $code = @(Get-PSMutantWorkflowCode -Line $Line)

    $cancel = $null
    $failFast = $null
    $os = @()
    foreach ($l in $code) {
        if ($l -match 'cancel-in-progress:\s*(.+?)\s*$') { $cancel = $Matches[1] }
        if ($l -match 'fail-fast:\s*(\S+)') { $failFast = $Matches[1] }
        # The matrix list itself, not every mention of a runner: `if: matrix.os == 'ubuntu-latest'`
        # names one without adding a leg, and counting mentions would read a Linux-only workflow
        # with one conditional step as a matrix over two platforms.
        if ($l -match '^\s+os:\s*\[(.+)\]') {
            $os = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'", '"') })
        }
    }

    [pscustomobject]@{
        Name = $Name
        # One runs-on per job, which is how a job is counted without a YAML parser.
        JobCount            = @($code | Where-Object { $_ -match '^\s+runs-on:' }).Count
        TimeoutCount        = @($code | Where-Object { $_ -match '^\s*timeout-minutes:' }).Count
        HasConcurrency      = @($code | Where-Object { $_ -match '^concurrency:' }).Count -gt 0
        HasConcurrencyGroup = @($code | Where-Object { $_ -match '^\s+group:' }).Count -gt 0
        CancelInProgress    = $cancel
        HasPermissions      = @($code | Where-Object { $_ -match '^\s*permissions:' }).Count -gt 0
        # Raw lines, not the comment-stripped ones: the trailing version comment is part of what
        # that rule requires, so stripping it first would report every correct pin as unpinned.
        UnpinnedUses        = @($Line | Where-Object { $_ -match '\buses:' -and $_ -notmatch '@[0-9a-f]{40}\s*#\s*\S' })
        InstallsModule      = @($code | Where-Object { $_ -match 'Install-Module' }).Count -gt 0
        LoadsPins           = @($code | Where-Object { $_ -match 'pins\.env' }).Count -gt 0
        AssertsPins         = @($code | Where-Object { $_ -match 'throw.*pins\.env' }).Count -gt 0
        VersionLiteral      = @($code | Where-Object { $_ -match '-(?:Required|Minimum)Version\s+["'']?\d+\.\d+' } | ForEach-Object { $_.Trim() })
        InlineAnalyzer      = @($code | Where-Object { $_ -match 'Invoke-ScriptAnalyzer' }).Count -gt 0
        PesterConfigCount   = @($code | Where-Object { $_ -match 'New-PesterConfiguration' }).Count
        DisableV5Count      = @($code | Where-Object { $_ -match 'Should\.DisableV5' }).Count
        MatrixOs            = $os
        FailFast            = $failFast
    }
}

function Get-PSMutantWorkflowGuardFault {
    # The four guards every workflow owes regardless of what it does.
    #
    # Split from the tooling rules below to stay inside the complexity ceiling this repo gates
    # itself on, and because they fail for different reasons: these are about the RUN -- what it may
    # cancel, how long it may hold a required check, what token it executes with.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Fact)
    $faults = [System.Collections.Generic.List[string]]::new()

    # Every rule below reads a shape this file could not find here, so reporting them all would be
    # four restatements of one fact. The shape failure is the finding.
    if ($Fact.JobCount -eq 0) {
        $faults.Add("$($Fact.Name) declares no job. Either it is not a workflow or the shape this gate reads has changed, and every rule below would pass over it in silence.")
        return $faults.ToArray()
    }
    if ($Fact.TimeoutCount -ne $Fact.JobCount) {
        $faults.Add("$($Fact.Name) declares $($Fact.JobCount) job(s) and $($Fact.TimeoutCount) timeout-minutes. A wedged runner holds a required check pending for the six-hour default, which blocks every merge behind it.")
    }
    if (-not ($Fact.HasConcurrency -and $Fact.HasConcurrencyGroup)) {
        $faults.Add("$($Fact.Name) declares no concurrency group. A superseded run answers a question nobody is asking any more, and for a publish it is worse: two tags racing on an action that cannot be undone.")
    }
    if (-not $Fact.HasPermissions) {
        $faults.Add("$($Fact.Name) declares no permissions block, so it runs with the default write-scoped token while executing third-party code from the gallery.")
    }
    return $faults.ToArray()
}

function Get-PSMutantWorkflowToolingFault {
    # How a workflow gets its tools, and whether it does its own gating inline.
    #
    # Every rule here is a way the two repositories drifted apart before anything compared them: a
    # version written out in one file and not the other, a lint gate spelled inline in two places
    # that then disagreed about severity, a Pester configuration missing the one setting that makes
    # the assertion style enforceable.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Fact)
    $faults = [System.Collections.Generic.List[string]]::new()

    foreach ($u in $Fact.UnpinnedUses) {
        $faults.Add("$($Fact.Name) has an action that is not pinned to a 40-character SHA with the version in a trailing comment: $($u.Trim()). A tag is mutable, and a uses: line cannot read a variable, so this is the one pin no shared file can hold for you.")
    }
    if ($Fact.InstallsModule -and -not ($Fact.LoadsPins -and $Fact.AssertsPins)) {
        $faults.Add("$($Fact.Name) installs a module without loading .github/pins.env and asserting its keys arrived. A missing key installs the latest release or analyses nothing, and both look like a clean run.")
    }
    foreach ($v in $Fact.VersionLiteral) {
        $faults.Add("$($Fact.Name) names a version literally rather than reading it from the pins file: $v. Two workflows agreeing today is not the same as one file they both read.")
    }
    if ($Fact.InlineAnalyzer) {
        $faults.Add("$($Fact.Name) calls Invoke-ScriptAnalyzer directly instead of the committed script both lint gates share. Spelled out in two places they agreed about scope and disagreed about severity, so a finding failed nothing and blocked everything.")
    }
    if ($Fact.PesterConfigCount -ne $Fact.DisableV5Count) {
        $faults.Add("$($Fact.Name) builds $($Fact.PesterConfigCount) Pester configuration(s) but sets Should.DisableV5 on $($Fact.DisableV5Count). Pester 6 keeps the classic Should syntax working, so without it a suite drifts back into a mix one test at a time -- and a gate that permits what the merge gate forbids is not the same gate.")
    }
    return $faults.ToArray()
}

function Get-PSMutantParityFault {
    # Every parity fault across a repository's workflows. Empty means the two repos agree, to the
    # extent anything here can tell.
    #
    # The two role rules are keyed on file NAME, which is the one place this file is not shape-only.
    # Both repositories call them ci.yml and publish.yml; if that ever stops being true, the
    # parameter is where it is said rather than an assumption buried in a regex.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Fact,
        [string]$CiName = 'ci.yml',
        [string]$PublishName = 'publish.yml'
    )
    $faults = [System.Collections.Generic.List[string]]::new()

    if (-not $Fact) {
        $faults.Add('No workflows were read, so this gate compared nothing. An empty set passes every rule below, which is the failure it exists to find.')
        return $faults.ToArray()
    }
    foreach ($f in $Fact) {
        $faults.AddRange([string[]]@(Get-PSMutantWorkflowGuardFault -Fact $f))
        $faults.AddRange([string[]]@(Get-PSMutantWorkflowToolingFault -Fact $f))
    }

    $publish = @($Fact | Where-Object { $_.Name -eq $PublishName })
    if (-not $publish) {
        $faults.Add("No $PublishName was found. The irreversible workflow is the one whose guards matter most, so its absence is a fault rather than a repository that happens not to publish.")
    }
    elseif ($publish[0].CancelInProgress -ne 'false') {
        $faults.Add("$PublishName has cancel-in-progress '$($publish[0].CancelInProgress)' where it must be the literal false. A half-finished publish is a gallery version that cannot be withdrawn; its group exists to serialise releases, not to drop them.")
    }

    $ci = @($Fact | Where-Object { $_.Name -eq $CiName })
    if (-not $ci) {
        $faults.Add("No $CiName was found, so nothing here checked the matrix that proves this module on more than one operating system.")
        return $faults.ToArray()
    }
    foreach ($os in 'ubuntu-latest', 'windows-latest') {
        if ($ci[0].MatrixOs -notcontains $os) {
            $seen = if ($ci[0].MatrixOs) { $ci[0].MatrixOs -join ', ' } else { 'no os matrix at all' }
            $faults.Add("$CiName does not run a matrix leg on ${os}: it has $seen. A guarantee about paths proven on one operating system is proven on one operating system.")
        }
    }
    if ($ci[0].FailFast -ne 'false') {
        $faults.Add("$CiName does not set fail-fast: false. With it on, the first leg to fail cancels the other, so a run that could have named two problems names one and hides whether the second platform is affected at all.")
    }
    return $faults.ToArray()
}
