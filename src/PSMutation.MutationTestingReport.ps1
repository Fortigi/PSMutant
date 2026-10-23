# The mutation testing report: every mutant, in the open format Stryker's tools read (#261).
#
# A third published format beside the report and the SARIF log, and like the SARIF log a projection
# of the same result rows rather than a second measurement. The SARIF log answers a reviewer's
# question -- where is a fault my tests miss -- and holds survivors only; this one answers a
# browsing question -- what happened at every mutated place in every file -- and so holds every
# mutant, with the source text it was cut from. The format is the `mutation-testing-elements`
# report schema; viewing it is the reader's business, through Stryker's HTML component or its
# dashboard, and this module ships no viewer.
#
# The rows alone are not enough, which is why this sits in the run rather than converting a JSON
# report after the fact: a row carries only a line, and the format places each mutant by line AND
# column, start and end, with the replacement text. The candidates carry the offsets and the
# replacement; the files carry the text the offsets index into.
#
# Pure except for Save-PSMutationMutationTestingDocument, which is the one function that touches a
# file, and Get-PSMutationMutationTestingFile, which reads the mutated sources.

function Get-PSMutationLineStart {
    # The offset each line of a text starts at, line 1 first. A line starts after every `n, so a
    # CRLF file is placed correctly too: the `r is the last character of the line before.
    [OutputType([int[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)
    $starts = [System.Collections.Generic.List[int]]::new()
    $starts.Add(0)
    $at = $Text.IndexOf("`n")
    while ($at -ge 0) {
        $starts.Add($at + 1)
        $at = $Text.IndexOf("`n", $at + 1)
    }
    # Not comma-protected: the list always holds line 1, and a one-start list unrolled to a bare
    # int still binds to an [int[]] parameter.
    return $starts.ToArray()
}

function Get-PSMutationTextPosition {
    # A character offset as the format's position: line and column, both counted from 1.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int[]]$LineStart,
        [Parameter(Mandatory)] [int]$Offset
    )
    # BinarySearch answers the index of an exact hit, or the complement of the first larger start;
    # either way the line is the last start at or before the offset.
    $found = [System.Array]::BinarySearch($LineStart, $Offset)
    $index = $found
    # PSMutant-Equivalent: 0 -> (-1): BinarySearch answers -1 only for an offset before line 1, which starts at 0, and no offset is negative.
    if ($found -lt 0) { $index = (-bnot $found) - 1 }
    return [ordered]@{ line = $index + 1; column = $Offset - $LineStart[$index] + 1 }
}

function Get-PSMutationMutationTestingStatus {
    # The format's status for one row, and why, when there is something to say.
    #
    # A declared equivalent is `Ignored`, which the format leaves out of its score exactly as this
    # module leaves it out of its own, with the declaration's argument as the reason. TimedOut is
    # `Timeout`, which both count as detected.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [hashtable]$Declared
    )
    if ($Result.Status -eq 'Survived') {
        $key = Get-PSMutationDeclaredKey -Result $Result -Declared $Declared
        if ($null -ne $key) { return [ordered]@{ status = 'Ignored'; statusReason = "Declared equivalent: $($Declared[$key])" } }
    }
    $out = [ordered]@{ status = [string]$Result.Status }
    if ($Result.Status -eq 'TimedOut') { $out.status = 'Timeout' }
    $killers = @($Result.KilledBy | Where-Object { $_ })
    if ($killers.Count -gt 0) { $out.statusReason = "Killed by $($killers -join '; ')" }
    return $out
}

function Get-PSMutationMutationTestingMutant {
    # One mutant as the format writes it.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] [int[]]$LineStart,
        [Parameter(Mandatory)] [hashtable]$Declared
    )
    $mutant = [ordered]@{
        # File and id, because an id is numbered within its file and the format wants one unique
        # across the report.
        id          = "$($Result.File)#$($Result.Id)"
        mutatorName = [string]$Result.Operator
        description = [string]$Result.Description
        replacement = [string]$Candidate.Mutated
        location    = [ordered]@{
            start = Get-PSMutationTextPosition -LineStart $LineStart -Offset $Candidate.StartOffset
            # Exclusive in the format as in the offsets, so the end offset maps across unchanged.
            end   = Get-PSMutationTextPosition -LineStart $LineStart -Offset $Candidate.EndOffset
        }
    }
    $verdict = Get-PSMutationMutationTestingStatus -Result $Result -Declared $Declared
    foreach ($k in $verdict.Keys) { $mutant[$k] = $verdict[$k] }
    return $mutant
}

function Get-PSMutationMutationTestingFile {
    # The `files` object: each mutated file's text and its mutants, keyed by the path the report
    # uses, in the order the rows came.
    #
    # A row is paired with its candidate by file and id, the same key the incremental join uses. A
    # row with no candidate cannot be placed and is left out rather than placed at line 1: a
    # mutant drawn somewhere it is not is worse than one missing.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        [Parameter(Mandatory)] [hashtable]$Declared
    )
    $byKey = @{}
    $pathOf = @{}
    foreach ($c in $Candidates) {
        $display = ConvertFrom-PSMutationSandboxPath -Path $c.File -SandboxRoot $SandboxRoot
        $byKey["$display|$($c.Id)"] = $c
        $pathOf[$display] = $c.File
    }
    $files = [ordered]@{}
    $starts = @{}
    foreach ($r in $Results) {
        $c = $byKey["$($r.File)|$($r.Id)"]
        if ($null -eq $c) { continue }
        if (-not $files.Contains($r.File)) {
            # The text the parser read, so the offsets index into exactly this string.
            $text = [System.IO.File]::ReadAllText($pathOf[$r.File])
            $files[$r.File] = [ordered]@{ language = 'powershell'; source = $text; mutants = [System.Collections.Generic.List[object]]::new() }
            $starts[$r.File] = Get-PSMutationLineStart -Text $text
        }
        $files[$r.File].mutants.Add((Get-PSMutationMutationTestingMutant -Result $r -Candidate $c -LineStart $starts[$r.File] -Declared $Declared))
    }
    return $files
}

function Get-PSMutationMutationTestingDocument {
    <#
    .SYNOPSIS
        A mutation-testing-elements report for one completed run.
    .DESCRIPTION
        Written only by a run that finished and scored, as the SARIF log is. A -RecheckFrom run
        and an interrupted one hold some of the mutants, and a reader of this format takes the
        file to be the run.

        Mutants never run because no test executed their line are not listed. The format would
        call them NoCoverage and count them as undetected, which would put a lower score on the
        page than the one this run reported and gated on; they are in the JSON report's counts.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        $Equivalents,
        # The resolved bands the console colours by, not the raw config: an absent `thresholds`
        # still has bands, and the format requires both.
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low,
        [AllowEmptyString()] [string]$ModuleVersion
    )
    $version = $ModuleVersion
    if ([string]::IsNullOrEmpty($ModuleVersion)) { $version = 'unknown' }
    $declared = Get-PSMutationDeclaredEquivalent -Equivalents $Equivalents
    return [ordered]@{
        schemaVersion = '2'
        # Whole numbers in the format; a configured 87.5 is shown as 87 rather than refused.
        thresholds    = [ordered]@{ high = [int][math]::Floor($High); low = [int][math]::Floor($Low) }
        files         = Get-PSMutationMutationTestingFile -Results $Results -Candidates $Candidates -SandboxRoot $SandboxRoot -Declared $declared
        framework     = [ordered]@{ name = 'PSMutant'; version = $version }
    }
}

function Save-PSMutationMutationTestingDocument {
    # Write the document, failing the run when it cannot be written: the SARIF writer's guards, for
    # its reasons. -Depth 6, measured: a position's line and column sit under root, files, file,
    # mutants, mutant, location and start, and at -Depth 5 ConvertTo-Json drops them SILENTLY,
    # writing the start as a type name. The suite reads a column back, so 5 cannot pass it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Document,
        [Parameter(Mandatory)] [string]$Path
    )
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $Document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -ErrorAction Stop
}

function Export-PSMutationMutationTestingReport {
    # Write the report when the config asked for one, and return the line that says so. An empty
    # -Path is the config saying "none", and returns no line -- the decision lives here, as the
    # SARIF one does, rather than as an `if` in the orchestrator.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Results,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates,
        [Parameter(Mandatory)] [string]$SandboxRoot,
        $Equivalents,
        [Parameter(Mandatory)] [double]$High,
        [Parameter(Mandatory)] [double]$Low,
        [AllowEmptyString()] [string]$ModuleVersion
    )
    if ([string]::IsNullOrEmpty($Path)) { return }
    $doc = Get-PSMutationMutationTestingDocument -Results $Results -Candidates $Candidates -SandboxRoot $SandboxRoot `
        -Equivalents $Equivalents -High $High -Low $Low -ModuleVersion $ModuleVersion
    Save-PSMutationMutationTestingDocument -Document $doc -Path $Path
    $count = 0
    foreach ($f in $doc.files.Values) { $count += $f.mutants.Count }
    return New-PSMutationLine -Role 'Muted' -Text ("  Mutation testing report: {0} ({1} mutant(s))" -f $Path, $count)
}
