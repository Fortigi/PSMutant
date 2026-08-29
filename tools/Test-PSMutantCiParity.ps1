<#
.SYNOPSIS
    Assert this repository's CI still holds every capability the matching one's does.

.DESCRIPTION
    This module and the one it is paired with gate each other -- one measures the other's
    complexity, the other mutation-tests its suite -- so it is easy to assume their CI is
    comparable. It was not, in thirteen ways, and nothing compared them: each workflow reads fine on its own, and a
    capability present in one repository and absent in the other is invisible from inside either.

    The rules are stated as shape rather than by file name, so tools/ParityDecisions.ps1 is
    byte-identical in both repositories apart from the command prefix. That makes diffing the two
    copies the comparison, and makes declining a rule a deletion somebody has to argue for in a
    diff rather than a silence.

    Throws on a fault, so the exit code is the answer and running it by hand is the same as
    passing it. A gate that reports and exits 0 is a report.

.PARAMETER WorkflowPath
    Directory of workflow files. Defaults to .github/workflows beside this script's repository.

.PARAMETER PassThru
    Return the faults instead of throwing, for a caller that wants to render them.

.OUTPUTS
    [string[]] with -PassThru; nothing otherwise.
#>
[CmdletBinding()]
[OutputType([string[]])]
param(
    [string]$WorkflowPath,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'ParityDecisions.ps1')

if (-not $WorkflowPath) {
    $WorkflowPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '.github/workflows'
}
if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    throw "No workflow directory at $WorkflowPath. This gate cannot compare what it cannot read, and an unreadable path would otherwise pass every rule."
}

$files = @(Get-ChildItem -LiteralPath $WorkflowPath -Filter *.yml -File | Sort-Object Name)
$facts = foreach ($f in $files) {
    Get-PSMutantWorkflowFact -Name $f.Name -Line @(Get-Content -LiteralPath $f.FullName)
}

$faults = @(Get-PSMutantParityFault -Fact @($facts))

if ($PassThru) { return $faults }

if ($faults) {
    $body = ($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "CI parity gate: $($faults.Count) fault(s) across $($files.Count) workflow(s).$([Environment]::NewLine)$body"
}
# Write-Output rather than Write-Host, though this repo DOES exclude PSAvoidUsingWriteHost and its
# other gate scripts print with Write-Host. Kept as-is because a caller may want to capture this
# line, and because the sibling copy of this gate cannot use Write-Host at all -- the two scripts
# stay swappable that way. (This comment previously asserted the exclusion was absent here, which
# was true of the repo it was ported from and false the moment it landed.)
Write-Output "CI parity: $($files.Count) workflow(s) hold every shared capability."
