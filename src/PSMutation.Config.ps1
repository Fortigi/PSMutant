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
    $node = if ($Section -eq 'thresholds') { $schema.properties.thresholds } else { $schema }
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
            $cost = if ($From[$i - 1] -eq $To[$j - 1]) { 0 } else { 1 }
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
    $hint = if ($near) { " Did you mean '$near'?" } else { '' }
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
    # silently rewritten. Same guard, and the same reason, as Get-PSCxRelativePath in the sibling
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
        Mutate      = $mutate
        TestsByFile = $byFile
        AllTests    = $all.ToArray()
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
    $high = if ($null -ne $Cfg.thresholds.high) { $Cfg.thresholds.high } else { 85 }
    $low = if ($null -ne $Cfg.thresholds.low) { $Cfg.thresholds.low } else { 70 }
    return @{ High = [double]$high; Low = [double]$low }
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
    param($Cfg, [Parameter(Mandatory)] [double]$BaselineSeconds)
    $factor = if ($Cfg.timeoutFactor) { $Cfg.timeoutFactor } else { 4 }
    $floor = if ($Cfg.timeoutFloorSeconds) { $Cfg.timeoutFloorSeconds } else { 15 }
    $budget = [int][math]::Max($floor, $BaselineSeconds * $factor)

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
