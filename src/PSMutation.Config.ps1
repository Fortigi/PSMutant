<#
.SYNOPSIS
    Config resolution for the mutation run: the "what did the user ask for, and what
    do we do when they didn't say" decisions.

.DESCRIPTION
    A config object in, a value out: pure, no side effects, nothing to sandbox.

    Every documented default is resolved here, so this is the one place to read for
    "what happens if the config omits this" -- the operator set excepted, which resolves
    in PSMutation.Operators.ps1 beside the vocabulary it names.
#>

# Default subtrees copied into the sandbox when the config does not name any. A neutral
# module convention; a consuming repo overrides it with `sandboxSubtrees`.
#
# The sandbox takes -Subtrees as a mandatory parameter rather than defaulting: it is
# mechanism, and holds no opinion about a repo's layout.
$script:PSMutationDefaultSubtrees = @('src', 'tests')

# Where the report goes when the config does not say. Documented optional and, until this
# existed, mandatory in practice: `Join-Path $root $null` returns the root itself, so an
# omitted key produced "unable to clear content ... because it is a directory" from the
# report writer -- after the whole run had already been done.
$script:PSMutationDefaultReportPath = 'reports/ps-mutation.json'

# The config format has ONE definition: schemas/v1/config.schema.json, which also ships to
# consumers. The key names, the threshold sub-keys and the type of every value are read
# from it rather than restated here -- a second copy in PowerShell would be a second place
# to edit when a key is added, and the copy that was forgotten is the one that decides.
#
# Cached because it is read once per run and parsing it per call would be pointless work.
$script:PSMutationConfigSchema = $null

function Get-PSMutationConfigSchemaPath {
    # Where the shipped schema lives, relative to this file: src/ and schemas/ are siblings
    # in the repo and in the published package alike.
    #
    # The version is in the PATH, not in the URL's git ref. A `$schema` URL pointing at a
    # branch means the document a consumer validates against changes under them the day a
    # v2 lands; a versioned directory means v2 is a NEW file and every existing pointer
    # keeps resolving to the format it was written for. A v2 goes in schemas/v2/ beside
    # this one rather than replacing it.
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'schemas' -AdditionalChildPath 'v1', 'config.schema.json')
}

function Get-PSMutationConfigSchema {
    <#
    .SYNOPSIS
        The config schema, as raw text.

    .DESCRIPTION
        Throws a message naming the missing path rather than skipping validation. A
        validator that quietly does nothing when its schema is absent is the failure this
        project is organised around: every config would pass, including the ones that empty
        the per-mutant timeout and score every mutant as killed.

        The package smoke test asserts the schema ships, so this should only ever fire for
        a partially copied module.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    if ($null -eq $script:PSMutationConfigSchema) {
        $path = Get-PSMutationConfigSchemaPath
        if (-not (Test-Path $path)) {
            throw "The PSMutant config schema is missing from this installation: $path. The module cannot validate a config without it."
        }
        $script:PSMutationConfigSchema = Get-Content $path -Raw
    }
    return $script:PSMutationConfigSchema
}

function Get-PSMutationConfigKey {
    # Every key the config understands, from the schema. A key the schema does not describe
    # resolves to $null and weakens the run in silence: `thresholds.brake` leaves the break
    # gate unable to fail, and `mutat` for `mutate` surfaces as a denied path inside the
    # sandbox, in a message mentioning neither the config nor the key.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([string]$Section = 'config')
    $schema = Get-PSMutationConfigSchema | ConvertFrom-Json
    $node = $Section -eq 'thresholds' ? $schema.properties.thresholds : $schema
    return [string[]]@($node.properties.PSObject.Properties.Name)
}

function Get-PSMutationEditDistance {
    # Levenshtein distance between two strings.
    #
    # Exists only so a rejected key can say "did you mean 'break'?" rather than leaving the
    # reader to diff two lists by eye. The three typos this has to reach are a transposition
    # (brake/break, distance 2), a dropped letter (mutat/mutate, 1) and a wrong letter (1).
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$From,
          [Parameter(Mandatory)] [AllowEmptyString()] [string]$To)
    $n = $From.Length
    $m = $To.Length
    # No empty-string guard, deliberately. The obvious `if ($n -eq 0) { return $m }` pair
    # reads like a necessary base case and is not one: with either length zero the loop
    # below simply does not run and the seeded row already holds the answer. Verified by
    # deleting both and re-running the table in Config.Tests.ps1 -- identical. They would
    # also have been two mutants nothing could ever kill.
    #
    # Two rows rather than a full matrix: only the previous row is ever read.
    $prev = [int[]](0..$m)
    # Sized from $prev rather than as ($m + 1). Same length, but written as a literal it is
    # a mutant nothing can kill: the row is a buffer, so an oversized one computes exactly
    # the same distances. Deriving the length removes the mutant instead of excusing it.
    $curr = [int[]]::new($prev.Length)
    for ($i = 1; $i -le $n; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = $From[$i - 1] -eq $To[$j - 1] ? 0 : 1
            $curr[$j] = [math]::Min([math]::Min($prev[$j] + 1, $curr[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $curr.Clone()
    }
    return [int]$prev[$m]
}

function Get-PSMutationNearestName {
    # The valid name closest to a misspelling, or $null when nothing is close enough.
    #
    # Two edits is the cutoff because that is what a transposition costs; beyond it a
    # "did you mean" is a guess, and a wrong guess sends the reader off to change a key
    # that was never the problem.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name,
          [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Candidates)
    $best = $null
    $bestDistance = 3
    foreach ($c in $Candidates) {
        $d = Get-PSMutationEditDistance -From $Name.ToLowerInvariant() -To $c.ToLowerInvariant()
        if ($d -lt $bestDistance) {
            $bestDistance = $d
            $best = $c
        }
    }
    return $best
}

function Get-PSMutationUnknownKeyMessage {
    # The complaint about one unrecognised key, or $null when it is recognised.
    #
    # Returns the reason rather than throwing so the caller decides how to report, and so
    # the decision itself is a value a test can compare.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name,
          [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Known,
          [Parameter(Mandatory)] [string]$Where)
    # JSON has no comments; `_`-prefixed keys are how every config here explains itself.
    # `$schema` is exempt for a different reason: it points at the published config
    # schema, which is the format's definition. Rejecting the key would mean a config
    # cannot name the very schema it is written against.
    if ($Name.StartsWith('_') -or $Name -eq '$schema') { return $null }
    if ($Known -contains $Name) { return $null }
    $near = Get-PSMutationNearestName -Name $Name -Candidates $Known
    $hint = $near ? " Did you mean '$near'?" : ''
    return "Unknown $Where key '$Name'.$hint Valid keys: $(($Known | Sort-Object) -join ', ')."
}

function Get-PSMutationNameFault {
    # The first complaint about an unrecognised NAME anywhere in a config, or $null.
    #
    # Keys, threshold sub-keys and operator names are one question asked three times, so
    # they answer in one place: a caller that checked two of the three would leave a whole
    # class of typo silently accepted, which is the failure this checking exists to stop.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg)
    foreach ($prop in $Cfg.PSObject.Properties) {
        $why = Get-PSMutationUnknownKeyMessage -Name $prop.Name -Known (Get-PSMutationConfigKey) -Where 'config'
        if ($why) { return $why }
    }
    foreach ($prop in $Cfg.thresholds.PSObject.Properties) {
        $why = Get-PSMutationUnknownKeyMessage -Name $prop.Name -Known (Get-PSMutationConfigKey -Section 'thresholds') -Where 'thresholds'
        if ($why) { return $why }
    }
    foreach ($op in @($Cfg.operators)) {
        if ($null -eq $op) { continue }
        $why = Get-PSMutationUnknownKeyMessage -Name $op -Known (Get-PSMutationKnownOperator) -Where 'operators'
        if ($why) { return $why }
    }
    return $null
}

function Get-PSMutationConfigTypeFault {
    <#
    .SYNOPSIS
        Why a config does not match the schema, or $null when it does.

    .DESCRIPTION
        The schema decides. Both of PowerShell's coercions fail OPEN -- a string where a
        number belongs makes the timeout arithmetic yield nothing, and any non-empty string
        is $true -- so an unchecked type does not error, it produces a confident wrong
        answer. The timeout is the worst of them: an expiry is scored as a KILL, so the run
        reports a number it never measured.

        The config is re-serialised because Test-Json validates TEXT while the caller holds
        an object. -Depth 10 against a format that nests three deep, so nothing is quietly
        truncated into validity.

    .PARAMETER Cfg
        The parsed config.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg)
    $json = $Cfg | ConvertTo-Json -Depth 10
    $ok = Test-Json -Json $json -Schema (Get-PSMutationConfigSchema) -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if ($ok) { return $null }
    # EVERY violation, not just the first. Test-Json writes one error per violation and the
    # first is not reliably the one the reader caused, so reporting only that sends them to
    # a line that is fine.
    $detail = @($schemaErrors | ForEach-Object {
            $_.Exception.Message -replace '^The JSON is not valid with the schema: ', ''
        }) -join '; '
    return "The config does not match the PSMutant config schema: $detail"

}

function Assert-PSMutationConfig {
    # Refuse a config that asks for something this module does not understand.
    #
    # An error rather than a warning, deliberately: a warning in a CI log is
    # indistinguishable from silence, and every failure here makes the gate WEAKER while
    # the run stays green -- the exact class of silent wrong answer this tool exists to
    # find in other people's code.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg)
    # The ORDER is the message quality. Each check below can also be reached by the schema,
    # which is deliberate -- the schema is what consumers validate against -- but the schema
    # answers in JSON-pointer terms, and these three answer in terms of what to go and do.
    #
    # 1. A misspelled key, reported as a misspelling with the nearest valid name. The schema
    #    would call it "property not allowed", which does not say `break` when you wrote
    #    `brake`.
    $why = Get-PSMutationNameFault -Cfg $Cfg
    if ($why) { throw $why }

    # 2. Missing or empty `mutate` / `tests`, reported as what the key is FOR. The schema's
    #    "required properties are not present" is true and teaches nothing.
    #
    #    Before the type check, because these are about the value being absent or empty
    #    rather than the wrong kind. An object in `mutate` still reaches the schema and is
    #    named as a type error, which is the better answer for that case.
    if (@($Cfg.mutate).Where({ $_ }).Count -eq 0) {
        throw "Config must set 'mutate' to a non-empty list of files to mutate."
    }
    # .Where({ $_ }) rather than a bare .Count: with no `tests` key at all, .PSObject
    # yields $null and @($null) is an array of ONE, so a plain count reads a missing map
    # as a populated one.
    if (@($Cfg.tests.PSObject.Properties).Where({ $_ }).Count -eq 0) {
        throw "Config must set 'tests' to a map of mutate file -> the test file(s) covering it."
    }

    # 3. Everything about shape and type, decided by the schema alone.
    $why = Get-PSMutationConfigTypeFault -Cfg $Cfg
    if ($why) { throw $why }
}

function Get-PSMutationCoveredLinesOnly {
    # Whether to mutate only the lines the baseline actually executed.
    #
    # Defaults to TRUE, which is what the README promises and what every example sets.
    #
    # Resolved rather than cast at the call site, because `[bool]$null` is $false: an
    # omitted key would silently mean "mutate uncovered lines too", and every mutant on an
    # uncovered line is a guaranteed survivor. That reports a materially worse score than
    # the tool is designed to give, and measures coverage rather than test quality, which
    # is a separate gate.
    [OutputType([bool])]
    [CmdletBinding()]
    param($Cfg)
    if ($null -eq $Cfg.coveredLinesOnly) { return $true }
    return [bool]$Cfg.coveredLinesOnly
}

function Test-PSMutationBaselineNeeded {
    <#
    .SYNOPSIS
        Whether this run has to measure the baseline suite before it can answer.
    .DESCRIPTION
        An ordinary run always does: it needs a green suite to mutate against and a duration to
        size the per-mutant timeout from.

        -ListOnly evaluates nothing, so the only reason left to pay for a suite run is the
        COVERAGE the `coveredLinesOnly` filter needs. With that filter off, the preview is a
        parse and costs nothing. With it on, the filter is part of what the config would
        actually mutate, and a preview that skipped it would answer a different question than
        the run does -- confidently, and low.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$ListOnly,
        [Parameter(Mandatory)] [bool]$CoveredLinesOnly
    )
    return (-not $ListOnly) -or $CoveredLinesOnly
}

function Test-PSMutationCoverageNeeded {
    <#
    .SYNOPSIS
        Whether this run's baseline has to be instrumented for coverage.
    .DESCRIPTION
        Two runs do not need it, and both used to pay for it anyway.

        A run with `coveredLinesOnly` off never reads a covered line, so the tracer is pure
        surcharge -- measured here at +24% on the baseline suite.

        A RECHECK does not need it either, and that is the less obvious half. It evaluates the
        mutants a prior report listed as survivors, matched by (File, Id) -- and ids are assigned
        over the UNFILTERED candidate set, before coverage removes anything (#59). So an
        unfiltered selection is a superset of the filtered one and the intersection is identical.
        The recheck exists to narrow the loop, so the fixed setup is exactly what dominates the
        round where the developer is iterating fastest.

        ONE answer drives both the tracer and the filter, deliberately. They must never disagree:
        coverage without the filter is the waste this closes, and the filter without coverage
        selects NOTHING -- measured, a recheck in that state evaluates zero mutants and reports
        that none of the previous survivors are still alive.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$CoveredLinesOnly,
        [Parameter(Mandatory)] [bool]$Recheck,
        # Whether this run has any file to mutate at all. A -ChangedFile run over a pull request
        # that touched only documentation has none, and there is nothing for the tracer to
        # instrument -- Pester would be handed an empty coverage target.
        #
        # Deliberately NOT on Test-PSMutationBaselineNeeded, where it was written first by
        # mistake: the green gate still matters for such a run. A red suite must fail a
        # docs-only pull request exactly as it fails any other.
        [bool]$HasMutateFile = $true
    )
    if (-not $HasMutateFile) { return $false }
    return $CoveredLinesOnly -and -not $Recheck
}

function Get-PSMutationInputFault {
    <#
    .SYNOPSIS
        The first reason this run's ARGUMENTS are refused, or empty when they are not.
    .DESCRIPTION
        Three refusals in one place, in a deliberate order, for the reason the sibling module
        sequences its scan faults together: written as separate guards at the call site they can
        only be read one at a time, and the order between them -- which is a decision -- is
        wherever somebody happened to put them.

        The order:

        1. **-SourceRoot**, because every other answer is relative to it. A root that is a file
           makes every config path resolve against a file, so reporting a mode conflict first
           would send the reader to argue about switches while the root is the actual fault.
        2. **Mode conflicts**, because they need nothing from the filesystem.
        3. **An empty -ChangedFile**, last because it is the narrowest: it says the caller's diff
           produced nothing, which is only worth saying once the run is otherwise coherent.

        Asked of `-ChangedFileBound` rather than of the value: an omitted -ChangedFile is a
        whole-tree run and an empty one is a broken pipeline, and `$null` and `@()` are
        indistinguishable once bound to `[string[]]`.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [bool]$ListOnly,
        [Parameter(Mandatory)] [bool]$Recheck,
        [Parameter(Mandatory)] [bool]$UpdateBaseline,
        [Parameter(Mandatory)] [bool]$MergeIntoBaseline,
        [Parameter(Mandatory)] [bool]$Changed,
        [bool]$Resume,
        [AllowEmptyString()] [AllowEmptyCollection()] [string[]]$ChangedFile = @()
    )
    $fault = Get-PSMutationSourceRootFault -SourceRoot $SourceRoot
    if ($fault) { return $fault }
    $fault = Get-PSMutationModeFault -ListOnly $ListOnly -Recheck $Recheck `
        -UpdateBaseline $UpdateBaseline -MergeIntoBaseline $MergeIntoBaseline -Changed $Changed -Resume $Resume
    if ($fault) { return $fault }
    return $Changed ? (Get-PSMutationChangedFileFault -ChangedFile $ChangedFile) : ''
}

function Get-PSMutationSourceRootFault {
    <#
    .SYNOPSIS
        The message refusing a -SourceRoot that is not a directory, or empty.
    .DESCRIPTION
        Every path in a config is resolved against this, so a -SourceRoot pointing at a FILE
        resolves each of them against a file and the run measures nothing it was asked about.

        It was already refused, but by the sandbox check several steps later, whose message names
        a temp directory the reader has never seen. That is the misdiagnosis this module exists to
        end, one layer down: the fault is real, and the message sends you to look at the wrong
        thing.

        Pipeline binding is what turns it from a typo into a likely mistake. Piping FILES binds
        -ConfigFile by value AND -SourceRoot from the same object's FullName, so
        `Get-ChildItem *.json | Invoke-PSMutation` silently points the root at the config file.
        Measured; the message below names that case because it is the one a caller will hit.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$SourceRoot)
    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        return "-SourceRoot '$SourceRoot' does not exist. Every path in the config is resolved " +
            'against it, so a root that is not there measures nothing.'
    }
    if (Test-Path -LiteralPath $SourceRoot -PathType Leaf) {
        return "-SourceRoot '$SourceRoot' is a file, not a directory. Every path in the config is " +
            'resolved against it, so nothing the config names would be found. If you piped files ' +
            'in, note that a file object binds BOTH -ConfigFile and -SourceRoot -- pipe the ' +
            'directory instead, or pass -SourceRoot explicitly.'
    }
    return ''
}

function Get-PSMutationModeFault {
    <#
    .SYNOPSIS
        The message refusing a combination of switches that name two different runs, or empty.
    .DESCRIPTION
        -ListOnly evaluates no mutants, so every switch that acts on verdicts is a request it
        cannot honour. Refused rather than ignored: a caller that asked for a baseline update and
        got a preview would read the exit code as a run that updated nothing, which is the
        silence this module exists to remove.

        Named separately rather than through parameter sets. A set would report "cannot be
        resolved using the specified named parameters", which says nothing about which pair is
        the problem or why the two do not go together.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$ListOnly,
        [Parameter(Mandatory)] [bool]$Recheck,
        [Parameter(Mandatory)] [bool]$UpdateBaseline,
        [Parameter(Mandatory)] [bool]$MergeIntoBaseline,
        [bool]$Changed,
        [bool]$Resume
    )
    # -ChangedFile first, because its conflicts hold whether or not -ListOnly is present, and
    # -ListOnly WITH -ChangedFile is the one combination here that is not a conflict at all:
    # previewing what a pull request would mutate is the cheapest use either has.
    #
    # A scoped run measures part of the tree. Folding its survivors into a whole-project baseline
    # would record "no survivors" for every file the run never looked at, which is the baseline
    # quietly forgetting debt rather than the run finding none. And a scoped resume of a
    # whole-tree partial is not a thing: the partial's rows cover files this run would not touch.
    $scoped = Get-PSMutationConflictName -When $Changed -Against @(
        @{ Name = '-RecheckFrom'; On = $Recheck }
        @{ Name = '-ResumeFrom'; On = $Resume }
        @{ Name = '-UpdateBaseline'; On = $UpdateBaseline }
        @{ Name = '-MergeIntoBaseline'; On = $MergeIntoBaseline })
    if ($scoped) {
        return "-ChangedFile scopes the run to part of the tree, so it cannot be combined with $scoped. " +
            'Run the whole tree for a project-wide answer, or drop -ChangedFile.'
    }
    # -RecheckFrom and -ResumeFrom each name a PRIOR REPORT to read, and they read different
    # kinds for different purposes -- one re-runs recorded survivors, the other continues an
    # interrupted run. -MergeIntoBaseline belongs to the recheck, so it goes with it.
    $resumed = Get-PSMutationConflictName -When $Resume -Against @(
        @{ Name = '-RecheckFrom'; On = $Recheck }
        @{ Name = '-MergeIntoBaseline'; On = $MergeIntoBaseline })
    if ($resumed) {
        return "-ResumeFrom continues an interrupted run, so it cannot be combined with $resumed. " +
            'Those name a different prior report and a different kind of run.'
    }
    $with = Get-PSMutationConflictName -When $ListOnly -Against @(
        @{ Name = '-RecheckFrom'; On = $Recheck }
        @{ Name = '-ResumeFrom'; On = $Resume }
        @{ Name = '-UpdateBaseline'; On = $UpdateBaseline }
        @{ Name = '-MergeIntoBaseline'; On = $MergeIntoBaseline })
    if (-not $with) { return '' }
    return "-ListOnly evaluates no mutants, so it cannot be combined with $with. " +
        'Drop -ListOnly to run, or drop the other switch to preview the mutant set.'
}

function Get-PSMutationConflictName {
    <#
    .SYNOPSIS
        The switches that conflict with one that is present, joined for a message. Pure.
    .DESCRIPTION
        Extracted because the complexity gate said so, and it earned its keep immediately: the
        three lists below were nine `if`s and adding -ResumeFrom would have made twelve, against
        a ceiling of fifteen. As data they are one loop, and the ORDER of the message is the
        order of the array rather than whatever a hashtable enumerates -- which is why this takes
        an ordered list and not a map.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$When,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Against
    )
    if (-not $When) { return '' }
    return (@($Against | Where-Object { $_.On } | ForEach-Object { $_.Name }) -join ' or ')
}

function Get-PSMutationChangedFileFault {
    <#
    .SYNOPSIS
        The message refusing an EMPTY -ChangedFile list, or empty when there is nothing to refuse.
    .DESCRIPTION
        The one guard that earns its place, and it is about the caller's pipeline rather than
        their code. `git diff --name-only` against a ref that was never fetched prints nothing
        and exits 0. Taken at face value that is a confident pass over zero mutants -- a green
        per-PR gate that measured nothing, which is precisely the failure this module exists to
        make impossible.

        It is deliberately NOT the same situation as a list that holds files, none of which are
        in `mutate`. That is an ordinary pull request touching documentation or tests, and it
        passes and says so. Only one of the two indicates a broken pipeline, and a gate that
        conflated them would either fail every docs-only change or pass every broken one.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    # AllowEmptyString as well as AllowEmptyCollection: a shell that emitted blank lines binds
    # @('', '') here, and PowerShell's own refusal -- "Cannot bind argument because it is an
    # empty string" -- says nothing about diffs or pipelines. Binding it lets the message below
    # do the explaining, which is the whole point of this function.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile)
    if (@($ChangedFile | Where-Object { $_ }).Count -gt 0) { return '' }
    return ('-ChangedFile was given an empty list. A diff that produced no files is more often a ' +
        'broken pipeline than a pull request that changed nothing -- `git diff --name-only` against ' +
        'a ref that was never fetched prints nothing and exits 0 -- so this is refused rather than ' +
        'read as a pass over zero mutants. Omit -ChangedFile to mutate everything in `mutate`.')
}

function Select-PSMutationScopedMutateFile {
    <#
    .SYNOPSIS
        The mutate files a scoped run should actually mutate: the intersection with what changed.
    .DESCRIPTION
        Pure, and matched on the SANDBOX path both sides resolve to, so a caller may name a file
        however they like -- repo-relative, absolute, or with the other platform's separators --
        and still hit the same entry the config named.

        A changed file that is not in `mutate` is dropped without comment. That is the ordinary
        case: a pull request touches tests, documentation and source together, and only the last
        is this module's business.
    #>
    # BOTH types, and the second is the price of the comma-wrap: `, $x` is statically an
    # Object[] wrapper that PowerShell unrolls on return, so PSUseOutputTypeCorrectly
    # contradicts a bare [string[]]. Declaring only [object[]] would satisfy the analyzer
    # and stop documenting what a caller actually receives.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Mutate,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [string]$SandboxRoot
    )
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # NO blank guard. `Join-Path $SourceRoot ''` and `... $null` both yield the source root, whose
    # sandbox path is the sandbox root -- and no mutate file is ever the sandbox root, so a blank
    # entry adds a key that matches nothing. Measured. A guard here would be a branch whose two
    # arms produce identical output, which is the shape this repo deletes rather than tests: its
    # mutants survive because nothing can tell it from its own absence.
    foreach ($f in $ChangedFile) {
        [void]$wanted.Add((ConvertTo-PSMutationSandboxPath -Path (Join-Path $SourceRoot $f) `
                    -RepoRoot $SourceRoot -SandboxRoot $SandboxRoot))
    }
    # ORDER FROM $Mutate, not from $ChangedFile. The config's order is what every other run
    # reports in, and a scoped report that listed files in diff order would sort differently
    # from a full one over the same repository.
    # COMMA-WRAPPED. A function returning an empty collection unrolls it to NOTHING, so a scope
    # that matched no mutate file would hand the caller $null rather than an empty array -- and
    # `$null | ForEach-Object` runs its body once with $_ = $null. That is the docs-only pull
    # request, which is the case this whole mode has to get right. The caller ASSIGNS this; it
    # must never wrap it in @( ) again.
    $scoped = [string[]]@($Mutate | Where-Object { $wanted.Contains($_) })
    return , $scoped
}

function Get-PSMutationScopedReportPath {
    <#
    .SYNOPSIS
        Where a -ChangedFile run writes, which is never the project report.
    .DESCRIPTION
        The convention -RecheckFrom established, for the same reason: this run measured part of
        the tree, and a number over part of it must not land in the file a dashboard reads as
        the project's. Idempotent, so a scoped run seeded from a scoped path does not grow a
        second suffix.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ReportPath)
    $dir = Split-Path $ReportPath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ReportPath)
    $ext = [System.IO.Path]::GetExtension($ReportPath)
    if ($name.EndsWith('.changed')) { return (Join-Path $dir "$name$ext") }
    return (Join-Path $dir "$name.changed$ext")
}

function Get-PSMutationRecordEveryKiller {
    <#
    .SYNOPSIS
        Whether to record EVERY test that kills a mutant, rather than only the first.
    #>
    # Default FALSE, and that direction is the whole point. Recording every killer means
    # forfeiting SkipRemainingOnFailure, which stops a mutant's suite at the first failure --
    # measured over this repo's Operators.ps1, 118 mutants all killed: 50s with the early stop and
    # 73s without, a ~46% increase that lands on killed mutants, which are nearly all of them.
    # Both runs produced the same 118 verdicts, so the flag buys data rather than accuracy.
    #
    # So the expensive data is opt-in. What it buys is the only honest answer to "which of my
    # tests never kill anything": with the early stop, a test that WOULD have killed but was
    # skipped looks exactly like one that cannot kill at all, and acting on that reading means
    # deleting a test that works. That analysis is an occasional audit, not something a gate
    # needs on every run, so it should not be a standing tax on every consumer's wall clock.
    [OutputType([bool])]
    [CmdletBinding()]
    param($Cfg)
    # No absent-key guard, unlike Get-PSMutationCoveredLinesOnly beside it, and the asymmetry is
    # the point: that one defaults TRUE, so it needs a branch to tell "absent" from "false". This
    # one defaults false and [bool]$null is already false, so a guard here would be a branch whose
    # two arms return the same value -- which self-mutation duly reported as a survivor.
    return [bool]$Cfg.recordAllKillers
}

function Get-PSMutationSurvivorBaselinePath {
    <#
    .SYNOPSIS
        The accepted-survivor baseline this config asks for, or $null when it asks for none.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$SourceRoot)
    # ITS PRESENCE IS THE SWITCH. There is no separate enable flag, because two settings that can
    # disagree are two somebody has to reconcile -- and the disagreement is silent in the direction
    # that matters: a path with the feature off is a baseline nobody enforces.
    #
    # A path in the CONFIG, and the file itself kept out of it. A config is a declaration of
    # intent; a baseline is recorded state. A tool that rewrites its own config makes the user's
    # hand-authored file something the machine edits, and then nobody can tell which lines a
    # person meant. Naming the path rather than fixing it also lets a monorepo keep one per
    # package.
    if ([string]::IsNullOrWhiteSpace($Cfg.survivorBaseline)) { return $null }
    $raw = [string]$Cfg.survivorBaseline
    $fault = Get-PSMutationPathFault -Value $raw -Key 'survivorBaseline'
    if ($fault) { throw $fault }
    # Resolved exactly as reportPath is, honouring a ROOTED path as given: Join-Path concatenates
    # rather than letting a rooted right-hand side win, so an absolute path would otherwise be
    # silently rewritten to sit inside the source tree.
    if ([System.IO.Path]::IsPathRooted($raw)) { return [System.IO.Path]::GetFullPath($raw) }
    return [System.IO.Path]::GetFullPath((Join-Path $SourceRoot $raw))
}

function Get-PSMutationRunDeadlineBudget {
    <#
    .SYNOPSIS
        The wall-clock budget for the WHOLE run, beyond which it is hung rather than slow.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        $Cfg,
        [Parameter(Mandatory)] [int]$CandidateCount,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] [double]$BaselineSeconds,
        # Mandatory for the reason it is on Get-PSMutationTimeout: this bound and that budget are
        # two halves of one arithmetic, and a default on either would let them describe different
        # runs.
        [Parameter(Mandatory)] [int]$Workers
    )
    # Every MUTANT is bounded and the RUN is not, which is a gap that only shows up as patience.
    # Observed: a run suspended overnight -- 875 minutes elapsed against 333 seconds of CPU --
    # with a zero-byte report, a sandbox its live pid kept the sweep from ever reclaiming, and no
    # output to tell a hang from progress. The honest response to both is to wait, so the cost is
    # measured in hours.
    #
    # Derived rather than configured by default, because the true upper bound is already implied
    # by numbers the run has: no correct run can exceed its baseline plus one per-mutant budget
    # for every mutant. Anything past that is not slow, it is stuck.
    #
    # The x2 is for per-mutant overhead outside the bounded child -- reading and splicing the
    # file, restoring it, the progress line -- and for the baseline being measured once on a warm
    # machine. It is deliberately loose: this exists to end an overnight hang, not to trim a run
    # that is merely having a bad day, and a bound that fires on a slow-but-working run would be
    # switched off within a week.
    # DIVIDED by the worker count, because N mutants running at once is N times less wall clock
    # for the same work. Left undivided the bound would grow with the very thing that makes a run
    # shorter -- the per-mutant budget already carries a factor of Workers -- so a parallel run
    # would be allowed N^2 times the patience of the serial one it replaced, which is a bound
    # that has stopped bounding anything.
    $derived = [int]([math]::Ceiling($BaselineSeconds) + ($CandidateCount * $TimeoutSeconds * 2 / $Workers))
    # An explicit setting wins, including a deliberately small one, so a caller who knows their
    # run's shape can tighten it. Zero disables the bound: a consumer running in a harness that
    # already kills wedged jobs should be able to say so rather than tune a number they do not
    # care about.
    if ($null -ne $Cfg.runTimeoutSeconds) { return [int]$Cfg.runTimeoutSeconds }
    return $derived
}

function Get-PSMutationPathFault {
    <#
    .SYNOPSIS
        The fault, if any, in a raw config path -- before anything tries to use it.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Value,
        [Parameter(Mandatory)] [string]$Key
    )
    # Every other config value got a resolver; paths did not, so each failed in its own place
    # and its own way -- a missing one as "unable to clear content of a directory", a bracketed
    # one as "the path is empty", neither naming the key that caused it. This answers for the
    # value BEFORE it reaches Join-Path, Pester or the filesystem.
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
        return "Config key '$Key' is empty. Give it a path relative to the source root."
    }
    if ($Value -isnot [string]) {
        return "Config key '$Key' must be a string path, not $($Value.GetType().Name)."
    }
    # Wildcard metacharacters. PowerShell's providers -- and Pester's Run.Path and
    # CodeCoverage.Path -- expand these, so `sr[c]` is a character class that matches nothing:
    # Pester finds no files and the run fails somewhere far away with a message naming neither
    # the key nor the cause. Refused here, where both can be named.
    $meta = '[', ']', '*', '?'
    $found = @($meta | Where-Object { $Value.Contains($_) })
    if ($found.Count -gt 0) {
        return ("Config key '$Key' contains $($found -join ' and ') in '$Value'. PowerShell " +
            'treats those as wildcards when resolving a path, so the file this names is not the ' +
            'file that gets used -- and a class that matches nothing fails much later, naming ' +
            'neither this key nor the reason. Rename the file or directory.')
    }
    return $null
}

function Test-PSMutationPathOutsideRoot {
    <#
    .SYNOPSIS
        Whether a path resolves outside the root it is supposed to sit under.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )
    # Asked as a relative path rather than by string-matching for '..', because a path may
    # contain '..' and still resolve inside: `src/../src` is `src`, and refusing that would
    # reject a config that was never ambiguous.
    # An ALREADY-ROOTED path is taken as it stands. Joining it onto the root instead produces
    # nonsense that differs by platform: on Linux `Join-Path /tmp/anchor /tmp/elsewhere/x.ps1`
    # yields /tmp/anchor/tmp/elsewhere/x.ps1, which then relativises to something INSIDE the
    # root -- so an absolute config path pointing anywhere on the machine reported itself as
    # safe. Windows masked it, because Join-Path there produced a path that failed differently.
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) }
    else { [System.IO.Path]::GetFullPath((Join-Path $Root $Path)) }
    $back = [System.IO.Path]::GetRelativePath($Root, $full)
    return [System.IO.Path]::IsPathRooted($back) -or $back -eq '..' -or
        $back.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar)
}

function Get-PSMutationReportPath {
    <#
    .SYNOPSIS
        Where the report is written, resolved, with the documented default applied.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$SourceRoot)
    $raw = [string]$Cfg.reportPath
    # Absence is meaningful here and means "use the default", so this tests for the empty
    # value rather than truthiness -- and the default is applied BEFORE the fault check, so an
    # omitted key is not reported as an empty one.
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $script:PSMutationDefaultReportPath }
    $fault = Get-PSMutationPathFault -Value $raw -Key 'reportPath'
    if ($fault) { throw $fault }
    # No escape check: a report is an OUTPUT, not a mutation target, and writing one to a
    # shared artifacts directory above the source root is a reasonable thing to ask for.
    #
    # An ABSOLUTE path is honoured as given. PowerShell's Join-Path CONCATENATES rather than
    # letting a rooted right-hand side win, so `/var/artifacts/r.json` used to come back as
    # `<SourceRoot>/var/artifacts/r.json` -- the report written somewhere the caller did not ask
    # for, with no error, and INSIDE the tree this module otherwise takes care never to write to.
    # Observed for real: a run created a directory chain under the repo being mutated, which came
    # within one `git add -A` of being committed.
    #
    # `../shared/r.json` already worked and still does; it was only the rooted form that was
    # silently rewritten. The same guard, and the same reason, that any path-mapping layer needs
    # module -- which carries a comment about GetFullPath quietly using the working directory when
    # nobody checks.
    if ([System.IO.Path]::IsPathRooted($raw)) { return [System.IO.Path]::GetFullPath($raw) }
    return [System.IO.Path]::GetFullPath((Join-Path $SourceRoot $raw))
}

function Get-PSMutationMissingSandboxPath {
    <#
    .SYNOPSIS
        Config paths that did not survive into the sandbox, with what to do about it.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Paths,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Subtrees
    )
    # Asked BEFORE the baseline, because afterwards it is unanswerable. A mutate or tests file
    # that is not in the sandbox makes Pester report a coverage path it cannot resolve, the
    # baseline comes back not-green, and the run says "Baseline suite is not green - fix the
    # tests before mutating." The suite is green. The message is an affirmatively false
    # statement that sends the reader to debug the wrong files.
    #
    # The cause is almost always the same and is worth naming rather than leaving to be
    # deduced: sandboxSubtrees decides what gets copied, and it defaults to this module's own
    # layout, so a repo laid out any other way copies nothing the config points at.
    $missing = @($Paths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq 0) { return $null }
    return ("These config paths do not exist inside the sandbox: $($missing -join ', '). " +
        "Only these subtrees are copied into it: $($Subtrees -join ', '). A path outside them " +
        'is never copied, so the baseline runs against files that are not there and reports ' +
        'itself not green -- which is not what went wrong. Add the directory to ' +
        "'sandboxSubtrees', or point -SourceRoot at the directory that contains them all.")
}

function Get-PSMutationDuplicateMutateFault {
    <#
    .SYNOPSIS
        The fault, if any, when the same file reaches the mutate list more than once.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Resolved)
    # Asked on the RESOLVED paths, not the raw config strings: `src/a.ps1` and
    # `src/../src/a.ps1` are the same file and double the run just as surely, and a validator
    # comparing strings would pass the second one. Case-insensitively, because Windows would
    # otherwise let `SRC/a.ps1` through and Linux would not -- a config that fails on one
    # platform and not the other is worse than one that fails on both.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $dupes = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Resolved) { if (-not $seen.Add($r)) { $dupes.Add($r) } }
    if ($dupes.Count -eq 0) { return $null }
    # Every mutant is generated twice, so `total`, `killed` and `survived` in the report -- a
    # published contract -- are all doubled, the run costs twice what it should, and (File, Id)
    # stops identifying one mutant, which is what a recheck dedupes on.
    return ("The 'mutate' list names the same file more than once: " +
        "$(($dupes | Sort-Object -Unique) -join ', '). Every mutant in it would be generated " +
        'and evaluated twice, doubling the run and the counts the report publishes, and ' +
        '(File, Id) would no longer identify one mutant -- which is what -RecheckFrom matches on.')
}

function Get-PSMutationUnmappedMutateFile {
    <#
    .SYNOPSIS
        Mutate files with no tests entry, which fall back to running the whole suite.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$TestsByFile
    )
    # The fallback is correct -- the whole suite is slower and never less thorough, so the
    # score cannot be wrong because of it. What it is not, is visible. Adding a file to
    # `mutate` and forgetting its `tests` entry is a config change with no error, no warning
    # and a per-mutant cost measured at 74% on a four-mutant fixture; on a several-hundred
    # mutant run it is the difference between minutes and tens of minutes.
    return [string[]]@($MutateFiles | Where-Object { -not $TestsByFile.ContainsKey($_) })
}

function Get-PSMutationOrphanTestsFault {
    <#
    .SYNOPSIS
        The fault, if any, when a `tests` key names no file in `mutate`.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # The keys as written, for the message. Same length as Resolved and in the same order:
        # the one caller builds both in lockstep from a single walk of the tests map, so an
        # index valid in one is valid in the other.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Raw,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Resolved,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Mutate
    )
    # A key in `tests` IS a mutate file -- the map answers "which tests cover this one". A key that
    # matches nothing is accepted today and does three wrong things quietly: its test files still
    # join the baseline's set, its entry covers no mutant, and whichever file it was MEANT to name
    # has no entry at all, so every one of that file's mutants falls back to running the whole
    # suite. None of it fails. It makes the run slower while the score stays believable.
    #
    # Resolved and case-insensitive, for the reasons on the duplicate check above: `src/a.ps1` and
    # `src/../src/a.ps1` are one file, and a config that fails on one platform but not the other
    # is worse than one that fails on both.
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $Mutate) { [void]$known.Add($m) }

    $orphans = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Resolved.Count; $i++) {
        if ($known.Contains($Resolved[$i])) { continue }
        # The raw spelling, because that is the text the reader has to go and edit.
        #
        # No length guard on $Raw. The obvious defensive `if ($i -lt $Raw.Count)` was written
        # first and removed: the two lists are built together from one walk, so the else branch
        # cannot be reached, and it was a pair of mutants nothing could ever kill -- the same
        # call Get-PSMutationEditDistance makes about its empty-string base cases. If the lists
        # ever do drift, an index error naming this line is a better answer than a message
        # quietly built from the wrong column.
        $orphans.Add($Raw[$i])
    }
    if ($orphans.Count -eq 0) { return $null }

    # A `_`-prefixed key earns its own sentence. Those ARE comments at the top level -- JSON has
    # none of its own and every config here relies on them -- so somebody who has just written
    # `_comment` beside `mutate` has no reason to expect the rule to change one level down.
    $comment = ''
    if (@($orphans | Where-Object { $_.StartsWith('_') }).Count -gt 0) {
        $comment = " A '_'-prefixed key is a comment only at the TOP level of a config; inside " +
        "'tests' every key is a path, so the note is looked for as a file."
    }
    return ("These 'tests' keys name no file in 'mutate': $(($orphans | Sort-Object -Unique) -join ', '). " +
        'A key there is the mutate file whose covering tests it lists, so one that matches nothing ' +
        'covers nothing -- while its test files still join the baseline suite, and whichever file ' +
        'it was meant to name falls back to running your WHOLE suite for every one of its mutants.' +
        $comment)
}

function Get-PSMutationSandboxPlan {
    # Translate the config's source-relative mutate/tests into sandbox absolute paths.
    #
    # Pure string work, and the last piece of config resolution that was still sitting
    # in the orchestrator rather than here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'SourceRoot and SandboxRoot are used inside the $toSb closure, which the analyzer does not track.')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$SourceRoot, [Parameter(Mandatory)] [string]$SandboxRoot)
    $toSb = { param($p) ConvertTo-PSMutationSandboxPath -Path (Join-Path $SourceRoot $p) -RepoRoot $SourceRoot -SandboxRoot $SandboxRoot }
    $mutate = @($Cfg.mutate | ForEach-Object { & $toSb $_ })
    # Here rather than in Assert-PSMutationConfig, which sees config STRINGS: two spellings of
    # one path are only equal once resolved, and this is the first place that is true. The orphan
    # check below is here for the same reason and needs the resolved mutate list, so both now
    # happen before the tests map is walked.
    $dupe = Get-PSMutationDuplicateMutateFault -Resolved $mutate
    if ($dupe) { throw $dupe }
    # The inverse of the mapping just done, built HERE because this is the only place holding both
    # spellings at once. A scoped run needs its files named the way the CONFIG names them --
    # equivalence declarations are keyed that way, and a sandbox path matches none of them.
    # Rebuilding it later would be a second implementation of $toSb, and the duplicate check above
    # is what guarantees the keys are unique.
    $byPath = @{}
    for ($i = 0; $i -lt $mutate.Count; $i++) { $byPath[$mutate[$i]] = @($Cfg.mutate)[$i] }

    $byFile = @{}
    $all = [System.Collections.Generic.List[string]]::new()
    $rawKeys = [System.Collections.Generic.List[string]]::new()
    $mappedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in $Cfg.tests.PSObject.Properties) {
        $vals = @($prop.Value | ForEach-Object { & $toSb $_ })
        $key = & $toSb $prop.Name
        $rawKeys.Add($prop.Name)
        $mappedKeys.Add($key)
        $byFile[$key] = $vals
        $vals | ForEach-Object { $all.Add($_) }
    }
    $orphan = Get-PSMutationOrphanTestsFault -Raw $rawKeys.ToArray() `
        -Resolved $mappedKeys.ToArray() -Mutate $mutate
    if ($orphan) { throw $orphan }
    return @{
        Mutate       = $mutate
        TestsByFile  = $byFile
        AllTests     = $all.ToArray()
        ConfigByPath = $byPath
    }
}

function Get-PSMutationSubtree {
    # Which source subtrees get copied into the sandbox. A consuming repo overrides
    # this to match its own layout; unset means the module's own convention.
    [OutputType([string[]])]
    [CmdletBinding()]
    param($Cfg, [Parameter(Mandatory)] [string]$SourceRoot)
    $subtrees = if ($Cfg.sandboxSubtrees) { [string[]]@($Cfg.sandboxSubtrees) }
    else { [string[]]$script:PSMutationDefaultSubtrees }
    foreach ($t in $subtrees) {
        $fault = Get-PSMutationPathFault -Value $t -Key 'sandboxSubtrees'
        if ($fault) { throw $fault }
        # The one path family that reached the filesystem unchecked. `..` in a subtree makes
        # New-PSMutationSandbox copy from outside the source root INTO the sandbox, and the
        # sweep that reclaims sandboxes keys on a name it no longer recognises -- so the copy
        # is left behind, holding whatever was above the root.
        if (Test-PSMutationPathOutsideRoot -Path $t -Root $SourceRoot) {
            throw ("Config key 'sandboxSubtrees' names '$t', which resolves outside the source " +
                'root. Subtrees are copied into a temp sandbox by relative position, so one that ' +
                'escapes copies from outside the root and is not reclaimed by the sweep. Name a ' +
                'directory inside the source root, or point -SourceRoot at the directory that ' +
                'contains them all.')
        }
    }
    return $subtrees
}

function Get-PSMutationScoreBand {
    # The bands the console summary colours the score by: at or above High is green, at or
    # above Low is yellow, below Low is red.
    #
    # Resolved here, with defaults, because in PowerShell any number `-ge $null` is $true.
    # Compare a raw config value and a config with no thresholds -- or the entirely
    # reasonable `{"thresholds":{"break":80}}` -- makes the first branch always win and
    # prints EVERY score green, `Mutation score: 0%  (0 killed / 42)` included, in a run
    # that exits 0. The smallest possible instance of the failure this tool exists to
    # prevent, in front of the person least able to spot it: a new adopter whose thresholds
    # are not tuned yet.
    #
    # Tested with `$null -ne`, not for truthiness like the resolvers above. A band of 0 is a
    # meaningful setting -- "never colour this red" -- and 0 is falsy, so a truthiness test
    # would silently substitute the default for it.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param($Cfg)
    $high = $null -ne $Cfg.thresholds.high ? $Cfg.thresholds.high : 85
    $low = $null -ne $Cfg.thresholds.low ? $Cfg.thresholds.low : 70
    return @{ High = [double]$high; Low = [double]$low }
}

# The most mutants that can be in flight at once. WaitHandle.WaitAny -- which is how the scheduler
# blocks until something finishes -- throws above 64 handles, so this is the framework's number and
# not a tuning choice. Named rather than inlined because Get-PSMutationWorkerCount clamps to it and
# a test pins it: a literal in both places is a limit that can drift apart from the thing enforcing
# it.
$script:PSMutationMaxWorkers = 64

function Get-PSMutationWorkerCount {
    <#
    .SYNOPSIS
        How many mutants this run may evaluate at once.
    .DESCRIPTION
        Absent means ONE, and that is a decision rather than a missing default. Parallel
        evaluation runs the consumer's covering suite N times CONCURRENTLY, each in its own
        sandbox copy; file isolation is complete, but a suite that binds a fixed port, writes an
        absolute temp path or leans on any other machine-wide resource is not parallel-safe, and
        turning it on by default would fail such a gate for a reason that is not about the tests'
        quality. So it is opted into, per config, by someone who can look at their own suite.

        The condition for changing that default, recorded now so it is not re-argued from
        memory: evidence from real consumer suites that a pool of workers reproduces the serial
        report. This repo's own suite is one data point and the wrong kind -- it is written by
        the people who wrote the scheduler.

        ZERO means "this machine", resolved as ProcessorCount - 1, leaving a core for the host
        that is orchestrating them. Zero rather than a string, because a config is validated
        against a JSON schema and a type union spends a `oneOf` -- which reports a failure in
        every branch -- to express what one sentinel expresses exactly. Zero has no other
        possible meaning here: a run with no workers evaluates nothing.

        SIXTY-FOUR IS A HARD CEILING, and it is the framework's rather than a taste. The scheduler
        blocks on `WaitHandle.WaitAny`, which throws above 64 handles -- measured: 70 gives "The
        number of WaitHandles must be less than or equal to 64." So on a 128-core machine
        `workers: 0` would resolve to 127 and the run would die at the first wait, on the largest
        machine anybody pointed it at.

        Clamped rather than refused, unlike most numbers here, because the worker count does not
        change the ANSWER -- a parallel run and a serial one produce identical reports, which
        tests/EndToEnd.Tests.ps1 asserts. Refusing would fail a run over a number that is merely
        optimistic, and would fail "this machine" for owning a big one.
    .OUTPUTS
        [int] between 1 and 64.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        $Cfg,
        # Injected so the decision is testable without asking what machine the test is on. A run
        # never passes it; a test always does.
        [int]$ProcessorCount = [Environment]::ProcessorCount
    )
    if ($null -eq $Cfg.workers) { return 1 }
    $want = ([int]$Cfg.workers -eq 0) ? ($ProcessorCount - 1) : [int]$Cfg.workers
    # Floored at 1 rather than refused: a single-core machine asking for "this machine" wants a
    # run, not an error about its own hardware. Capped at the WaitAny ceiling above it.
    return [int][math]::Max(1, [math]::Min($want, $script:PSMutationMaxWorkers))
}

function Get-PSMutationWorkerSandboxCount {
    <#
    .SYNOPSIS
        How many EXTRA sandbox copies a run needs -- one per worker past the first.
    .DESCRIPTION
        Capped at the mutant count, because a sandbox no mutant can be dispatched into is a full
        subtree copy paid for nothing. That matters most on the runs parallelism is for: a
        -RecheckFrom over two surviving mutants on a 24-core machine would otherwise copy the
        tree 23 times to leave 21 workers idle.

        The cap is NOT applied to the per-mutant timeout, deliberately. That budget is sized on
        what the config asked for, which is the concurrency the machine may actually see; sizing
        it on the smaller number would be a second answer to "how many workers", and the two
        would differ on exactly the short runs where a wrong budget is cheapest to ship.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Workers,
        [Parameter(Mandatory)] [int]$CandidateCount
    )
    return [int][math]::Max(0, [math]::Min($Workers, $CandidateCount) - 1)
}

function Get-PSMutationTimeout {
    # Per-mutant timeout in whole seconds.
    #
    # A mutant should never take much longer than the baseline suite, so the budget
    # is max(floor, baseline x factor). The floor matters for fast suites: a baseline
    # of 0.2s would otherwise give a 0-second budget and kill every mutant on time
    # rather than on behaviour, scoring 100% against tests that never ran. The factor
    # matters for slow ones. A mutant that runs past this is cut off and counted
    # Killed -- which is the right answer for a non-terminating loop.
    [OutputType([int])]
    [CmdletBinding()]
    param(
        $Cfg,
        [Parameter(Mandatory)] [double]$BaselineSeconds,
        # How many mutants will be sharing this machine. MANDATORY rather than defaulted to 1:
        # a default is a second answer to a question the caller already knows, and the caller
        # that forgot it would get a budget sized for a machine it does not have.
        [Parameter(Mandatory)] [int]$Workers
    )
    $factor = $Cfg.timeoutFactor ? $Cfg.timeoutFactor : 4
    $floor = $Cfg.timeoutFloorSeconds ? $Cfg.timeoutFloorSeconds : 15
    # x Workers, and the asymmetry is the whole argument. The baseline is measured ONCE, ALONE,
    # with the machine to itself; N mutants sharing it are slower for reasons that have nothing
    # to do with the fault injected in them. A mutant that overruns is scored KILLED, so a budget
    # sized for a solo run turns ordinary contention into kills -- and the score goes UP. A repo
    # adopting parallelism to make the gate affordable would watch its score improve and have no
    # way to tell that from having written better tests.
    #
    # The error in the other direction is that a genuinely non-terminating mutant takes N times
    # longer to cut off, bounded by the run deadline, which is patience rather than a wrong
    # answer. Between a slow truth and a fast flattering lie this module takes the slow truth.
    #
    # The FLOOR is not scaled. It exists for suites so fast that the factor gives a near-zero
    # budget, and a fast suite is still fast under contention.
    $budget = [int][math]::Max($floor, $BaselineSeconds * $factor * $Workers)

    # Refuse a budget the unmutated suite could not itself meet. Below that line every
    # mutant expires on the clock rather than on behaviour, and an expiry is scored as a
    # KILL -- so the run comes back 100% over tests that never finished. That is the
    # failure the floor above exists to prevent, and nothing was bounding the result.
    #
    # An error rather than a clamp. Clamping would run to completion under a budget the
    # config did not ask for and cannot be seen in the report; the two configs that reach
    # here are a floor and factor that are both tiny, and neither is a thing anyone means.
    $least = [math]::Max(1, $BaselineSeconds)
    if ($budget -lt $least) {
        throw ("Per-mutant timeout resolves to ${budget}s, which is below the " +
            "$([math]::Round($BaselineSeconds, 1))s the unmutated suite took. Every mutant would " +
            "expire on the clock rather than on behaviour, and an expiry is scored as a kill -- " +
            "the run would report a perfect score over tests that never finished. Raise " +
            "'timeoutFloorSeconds' (currently $floor) or 'timeoutFactor' (currently $factor).")
    }
    return $budget
}
