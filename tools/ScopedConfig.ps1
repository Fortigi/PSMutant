<#
.SYNOPSIS
    Narrowing a mutation config to the files a change actually touched, as a pure function.

.DESCRIPTION
    A full self-mutation run is several hundred mutants and a handful of minutes. While
    developing, most of that re-proves files nobody edited. This derives a smaller config
    from the real one so the edit-run-edit loop costs seconds.

    The output is NOT a gate and must never be treated as one: it measures a subset, so its
    score answers "did I break what I touched", not "is this project at 100%". Everything
    that makes that mistake harder lives here -- a separate report path, an untracked output
    file, and a warning written into the config itself.

    Pure so the narrowing decisions can be tested: which files are in scope, which
    declarations survive the subsetting, and when the answer is "nothing to do". Each of
    those is a place where being silently wrong looks like a fast, green run.
#>

function Get-PSMutantScopedFile {
    <#
    .SYNOPSIS
        The mutatable files a set of changed paths puts in scope, in the base config's order.

    .DESCRIPTION
        Two ways in, and the second is the one worth knowing about.

        A changed SOURCE file is in scope directly. A changed TEST file puts the source it
        covers in scope, because editing tests is exactly how a survivor becomes a kill --
        scoping only by source would skip the run that proves the assertion you just wrote
        does what you think.

        Order follows the base config rather than the change list, so the same change
        produces the same config no matter what order git reports it in.

    .PARAMETER MutateFiles
        The base config's full mutate list.

    .PARAMETER TestMap
        The base config's file-to-suite map, used backwards to resolve changed tests.

    .PARAMETER ChangedFiles
        Repo-relative paths, forward slashes. Anything that is neither a mutatable source
        file nor a mapped test file is ignored.
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$MutateFiles,
        [Parameter(Mandatory)] $TestMap,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ChangedFiles
    )
    $changed = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($ChangedFiles | ForEach-Object { $_ -replace '\\', '/' }),
        [System.StringComparer]::OrdinalIgnoreCase)

    $scoped = foreach ($file in $MutateFiles) {
        if ($changed.Contains($file)) { $file; continue }
        # The reverse lookup. $TestMap is a JSON object, so its per-file entry is reached
        # through PSObject rather than by index.
        $suites = @($TestMap.PSObject.Properties | Where-Object Name -eq $file | ForEach-Object { $_.Value })
        if (@($suites | Where-Object { $changed.Contains($_) }).Count -gt 0) { $file }
    }
    return [string[]]@($scoped)
}

function Get-PSMutantScopedConfig {
    <#
    .SYNOPSIS
        A mutation config narrowed to one change, or $null when nothing in the change is
        mutatable.

    .DESCRIPTION
        Returns $null rather than an empty-mutate config, because an empty mutate list is
        refused by Assert-PSMutationConfig -- so the caller would get a validation error
        naming a config it did not write, for the ordinary case of "you only edited the
        README". The caller says "nothing to do" instead.

        Declarations are subset with the files. A declaration whose file is out of scope
        matches no mutant, and the run FAILS on that rather than ignoring it -- correctly,
        since a stale declaration is a claim about code that moved. Carrying the full set
        into a narrowed run would turn every scoped run red for a reason that has nothing
        to do with the change.

    .PARAMETER BaseConfig
        The real config, parsed. Copied through except for the narrowed keys.

    .PARAMETER ChangedFiles
        Repo-relative paths, forward slashes.

    .PARAMETER ReportPath
        Where the scoped run writes. Must differ from the base config's reportPath, or a
        scoped run overwrites the artifact CI reads and a partial number starts being quoted
        as the real one.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $BaseConfig,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ChangedFiles,
        [Parameter(Mandatory)] [string]$ReportPath
    )
    # Refuse rather than warn. Sharing the path means a scoped run silently replaces the
    # artifact CI reads, and the next person to open reports/ finds a partial run wearing
    # the full run's filename -- with a mutation score in it, because the file gives no
    # sign of which kind of run produced it.
    if ($ReportPath -eq $BaseConfig.reportPath) {
        throw "A scoped run must not write to the base config's reportPath ('$ReportPath')."
    }

    # @() around the call, not a comma-wrap inside it: a one-file scope returns a single
    # string otherwise, and .Count on a string is an error under Set-StrictMode -Latest --
    # which is how the one-file case, the commonest one there is, would fail.
    $scoped = @(Get-PSMutantScopedFile -MutateFiles @($BaseConfig.mutate) -TestMap $BaseConfig.tests `
            -ChangedFiles $ChangedFiles)
    if ($scoped.Count -eq 0) { return $null }

    $tests = @{}
    foreach ($file in $scoped) {
        $entry = @($BaseConfig.tests.PSObject.Properties | Where-Object Name -eq $file)
        if ($entry.Count -gt 0) { $tests[$file] = [string[]]@($entry[0].Value) }
    }

    $equivalents = @{}
    foreach ($declaration in @($BaseConfig.equivalents.PSObject.Properties)) {
        # Match on the whole "file:" prefix rather than splitting the key. A key is
        # File:Function:Description or File:Line:Description, and splitting on the first
        # colon is one Windows absolute path away from being wrong.
        if (@($scoped | Where-Object { $declaration.Name.StartsWith($_ + ':') }).Count -gt 0) {
            $equivalents[$declaration.Name] = $declaration.Value
        }
    }

    $out = [ordered]@{
        _comment    = 'GENERATED, and NOT the gate. Scoped to the files one change touched, so its score describes those files and not this project -- a full run over the real config is the only number worth quoting. Regenerate with tools/New-PSMutantScopedConfig.ps1; do not commit this file or point CI at it.'
        mutate      = [string[]]@($scoped)
        tests       = $tests
        reportPath  = $ReportPath
    }
    # Copied verbatim, not re-decided. A scoped run that quietly used different operators or
    # a different coverage rule would disagree with the full run for a reason the person
    # reading it has no way to see.
    foreach ($key in 'sandboxSubtrees', 'operators', 'coveredLinesOnly', 'thresholds') {
        $value = @($BaseConfig.PSObject.Properties | Where-Object Name -eq $key)
        if ($value.Count -gt 0) { $out[$key] = $value[0].Value }
    }
    if ($equivalents.Count -gt 0) { $out['equivalents'] = $equivalents }
    return $out
}
