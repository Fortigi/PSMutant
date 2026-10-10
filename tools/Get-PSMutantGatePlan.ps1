# Which expensive CI gates this change can affect. Writes `selfmutation` and `compatibility` to
# $GITHUB_OUTPUT for ci.yml to read, and prints why, so a skipped gate is never a silent one.
#
# The decision is Get-PSMutantGatePlan in GateDecisions.ps1, with tests. This script only gathers
# its inputs: the event, the files the pull request changed, and the covering suites the self
# config maps. Runnable by hand with -EventName and -ChangedPath to see what CI would decide.
[CmdletBinding()]
param(
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    # Omitted, a pull request's changes are read from the merge commit CI checks out: its first
    # parent is the base branch, so the diff between the two is exactly what the PR changes.
    [string[]]$ChangedPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'GateDecisions.ps1')
$repo = Split-Path -Parent $PSScriptRoot

if (-not $PSBoundParameters.ContainsKey('ChangedPath') -and $EventName -eq 'pull_request') {
    # A failed git command leaves the list empty, and the decision reads an empty list as "run
    # everything" -- so a broken diff costs time, never a gate. Not -ErrorAction Stop's business:
    # git is a native command and reports through its exit code.
    $ChangedPath = @(git -C $repo diff --name-only HEAD^1 HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $ChangedPath = @() }
}

$config = Get-Content -LiteralPath (Join-Path $repo 'psmutant.self.config.json') -Raw | ConvertFrom-Json
$covering = @(foreach ($p in $config.tests.PSObject.Properties) { @($p.Value) })

$plan = Get-PSMutantGatePlan -EventName $EventName -ChangedPath $ChangedPath -CoveringSuite $covering
foreach ($line in $plan.Reason) { Write-Output $line }
if ($env:GITHUB_OUTPUT) {
    "selfmutation=$($plan.SelfMutation.ToString().ToLowerInvariant())" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "compatibility=$($plan.Compatibility.ToString().ToLowerInvariant())" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
