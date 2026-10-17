# Patterns in `mutate` and `tests` (#265), and pairing a file with its tests by name.
#
# Expanded ONCE, at start-up, into the plain file lists everything else already reads -- so the
# sandbox plan, the coverage mapping, a recheck and -ChangedFile see literal paths exactly as
# before, and the run prints what each pattern became. A pattern is a promise about files, and one
# that matches nothing is refused rather than read as an empty selection.
#
# The rules are PSComplexity's config `exclude` (Fortigi/PSComplexity#164), so the two modules read
# a pattern the same way: `*` and `?` stay inside one path segment, `**` spans any number of
# segments, and a pattern also matches everything below what it names. Matched without regard to
# case, as every other path comparison here is.

function Test-PSMutationGlob {
    # Whether a config entry is a pattern rather than a path.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Value)
    return $Value.Contains('*') -or $Value.Contains('?')
}

function Get-PSMutationGlobSegment {
    # A pattern's path segments, written with either separator, without empty or `.` segments.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Pattern)
    return [string[]]@($Pattern -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })
}

function ConvertTo-PSMutationGlobRegex {
    # One pattern as a regular expression over a path relative to the source root, `/`-separated.
    [OutputType([regex])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Pattern)
    $segments = @(Get-PSMutationGlobSegment -Pattern $Pattern)
    $body = ''
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $last = $i -eq $segments.Count - 1
        if ($segments[$i] -eq '**') {
            $body += $last ? '.*' : '(?:[^/]+/)*'
            continue
        }
        $body += [regex]::Escape($segments[$i]).Replace('\*', '[^/]*').Replace('\?', '[^/]')
        if (-not $last) { $body += '/' }
    }
    $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    return [regex]::new("^$body(?:/.*)?$", $options)
}

function Expand-PSMutationGlob {
    # The files under Root a pattern matches, relative to Root with `/`, sorted.
    #
    # Walked from the pattern's literal prefix -- `src/**/*.ps1` reads src/ and nothing else -- so a
    # pattern costs the tree it names rather than the whole repository.
    #
    # Comma-wrapped so none stays an empty array; both types declared for that wrap.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter(Mandatory)] [string]$Root
    )
    $regex = ConvertTo-PSMutationGlobRegex -Pattern $Pattern
    $found = foreach ($start in (Get-PSMutationGlobStart -Pattern $Pattern -Root $Root)) {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($start, '*', [System.IO.SearchOption]::AllDirectories)) {
            $relative = [System.IO.Path]::GetRelativePath($Root, $f).Replace('\', '/')
            if ($regex.IsMatch($relative)) { $relative }
        }
    }
    return , [string[]]@($found | Sort-Object -Unique)
}

function Get-PSMutationGlobStart {
    # The directories a pattern's literal prefix names -- `src/sub` for `src/sub/**/*.ps1` --
    # found without regard to case, as the rest of the pattern is matched, so a pattern selects the
    # same files on every platform. Two directories differing only in case are both walked.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter(Mandatory)] [string]$Root
    )
    $dirs = @($Root)
    foreach ($segment in (Get-PSMutationGlobSegment -Pattern $Pattern)) {
        if (Test-PSMutationGlob -Value $segment) { break }
        $dirs = @(foreach ($d in $dirs) {
                [System.IO.Directory]::EnumerateDirectories($d) | Where-Object { [System.IO.Path]::GetFileName($_) -eq $segment }
            })
    }
    return [string[]]$dirs
}

function Expand-PSMutationPathList {
    # A config list with every pattern replaced by the files it matches: [pscustomobject]@{ Files;
    # Faults; Expanded }. A path is kept as written, so the checks that already refuse a missing or
    # repeated file still answer for it. A file a pattern adds that the list already holds is not
    # added again; Expanded says what each pattern became, for the start-up lines.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Entry,
        [Parameter(Mandatory)] [string]$Root,
        # How the list is named in a fault: 'mutate', or "tests['src/a.ps1']".
        [Parameter(Mandatory)] [string]$Key
    )
    $files = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $faults = [System.Collections.Generic.List[string]]::new()
    $expanded = [System.Collections.Generic.List[object]]::new()
    # Paths first, so a file both listed and matched keeps the place its explicit entry gives it.
    foreach ($e in $Entry) {
        if ($e -is [string] -and (Test-PSMutationGlob -Value $e)) { continue }
        $files.Add($e)
        [void]$seen.Add((ConvertTo-PSMutationRootRelative -Path ([string]$e) -Root $Root))
    }
    foreach ($e in $Entry) {
        if (-not ($e -is [string] -and (Test-PSMutationGlob -Value $e))) { continue }
        # Assigned, not wrapped: the comma-wrapped return would nest inside @().
        $matched = Expand-PSMutationGlob -Pattern $e -Root $Root
        if ($matched.Count -eq 0) {
            $faults.Add("Config key '$Key' has the pattern '$e', which matches no file under $Root")
            continue
        }
        $expanded.Add([pscustomobject]@{ Pattern = $e; Files = $matched })
        foreach ($m in $matched) { if ($seen.Add($m)) { $files.Add($m) } }
    }
    return [pscustomobject]@{ Files = $files.ToArray(); Faults = $faults.ToArray(); Expanded = $expanded.ToArray() }
}

function Get-PSMutationConventionTest {
    # The test file a mutated file is paired with by name, `tests/<Name>.Tests.ps1`, relative to
    # Root -- or $null when that file is not there.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [string]$Root
    )
    $test = "tests/$([System.IO.Path]::GetFileNameWithoutExtension($File)).Tests.ps1"
    if ([System.IO.File]::Exists((Join-Path $Root $test))) { return $test }
    return $null
}

function Resolve-PSMutationConfigPattern {
    # The config with its patterns expanded and, under testsByConvention, its missing tests
    # entries filled in by name: [pscustomobject]@{ Cfg; Lines }. Lines say what each pattern and
    # each pairing became, for the run to print. Throws, naming every pattern that matched nothing.
    #
    # A copy, not an edit: the parsed config is the caller's, and a recheck reads it again.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Cfg,
        [Parameter(Mandatory)] [string]$Root
    )
    # Shallow: every value this changes is replaced whole, never edited in place.
    $copy = [pscustomobject]@{}
    foreach ($p in $Cfg.PSObject.Properties) { $copy | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    $lines = [System.Collections.Generic.List[string]]::new()
    $faults = [System.Collections.Generic.List[string]]::new()
    $mutate = Expand-PSMutationPathList -Entry @($Cfg.mutate) -Root $Root -Key 'mutate'
    $faults.AddRange([string[]]$mutate.Faults)
    foreach ($x in $mutate.Expanded) { $lines.Add("  mutate '$($x.Pattern)' -> $($x.Files -join ', ')") }
    $copy.mutate = [string[]]$mutate.Files
    $tests = [ordered]@{}
    foreach ($p in @($Cfg.tests.PSObject.Properties | Where-Object { $_ })) {
        $list = Expand-PSMutationPathList -Entry @($p.Value) -Root $Root -Key "tests['$($p.Name)']"
        $faults.AddRange([string[]]$list.Faults)
        foreach ($x in $list.Expanded) { $lines.Add("  tests['$($p.Name)'] '$($x.Pattern)' -> $($x.Files -join ', ')") }
        $tests[$p.Name] = [string[]]$list.Files
    }
    if ($faults.Count -gt 0) { throw (($faults -join '; ') + '. A pattern is a claim about files; one that matches none is a typo or a moved directory.') }
    if ([bool]$Cfg.testsByConvention) { $lines.AddRange([string[]]@(Add-PSMutationConventionTest -Tests $tests -Mutate $copy.mutate -Root $Root)) }
    $copy | Add-Member -NotePropertyName tests -NotePropertyValue ([pscustomobject]$tests) -Force
    return [pscustomobject]@{ Cfg = $copy; Lines = $lines.ToArray() }
}

function Add-PSMutationConventionTest {
    # Fill in, by name, the tests entry of every mutated file that has none and whose
    # tests/<Name>.Tests.ps1 is there, returning a line per pair made. An explicit entry wins.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary]$Tests,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Mutate,
        [Parameter(Mandatory)] [string]$Root
    )
    foreach ($file in $Mutate) {
        if (Test-PSMutationTestsEntry -Tests $Tests -File $file -Root $Root) { continue }
        $test = Get-PSMutationConventionTest -File $file -Root $Root
        if ($null -eq $test) { continue }
        $Tests[$file] = [string[]]@($test)
        "  $file -> $test (by name)"
    }
}

function Test-PSMutationTestsEntry {
    # Whether the tests map already has an entry for a file, spelt as the config spells it or not.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary]$Tests,
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [string]$Root
    )
    $want = ConvertTo-PSMutationRootRelative -Path $File -Root $Root
    foreach ($k in $Tests.Keys) { if ((ConvertTo-PSMutationRootRelative -Path $k -Root $Root) -eq $want) { return $true } }
    return $false
}

function ConvertTo-PSMutationRootRelative {
    # A config path as the one spelling a pattern's matches use: relative to Root, with `/`.
    # `src/a.ps1`, `./src/a.ps1` and `src\a.ps1` are one file.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )
    return [System.IO.Path]::GetRelativePath($Root, [System.IO.Path]::GetFullPath((Join-Path $Root $Path.Replace('\', '/')))).Replace('\', '/')
}
