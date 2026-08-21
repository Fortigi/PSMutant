# The dependency direction between files in src/, as a checked allowlist.
#
# The other gates are not blind to a new shortcut edge -- it still has to reach full
# coverage and survive self-mutation -- but they are blind to its DIRECTION. Nothing else
# in this repo would notice Operators.ps1 growing a call into Report.ps1, and the ordered
# list in PSMutant.psm1 cannot help: every cross-file reference resolves at call time, so
# loading the files in reverse order behaves identically. The order there is a readable
# convention, not a constraint.
#
# Two blind spots, both inherited from the module's own AST walk, and stated here rather
# than rediscovered later:
#
#   - the child-runspace script is a here-string, so the parser never sees the code inside
#     it. Turning it into a scriptblock would close this for free.
#   - the operator map is dispatched with `& $fn`, whose callee is a variable.
#
# Both are within-file today, so neither hides a cross-file edge.

BeforeAll {
    $script:srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'

    # One entry per file-to-file RELATIONSHIP, not per call site. Adding a call between two
    # files that already have an edge is free; adding the first one is a decision.
    $script:allowedEdges = @(
        # The composition root. It owns most of the graph on purpose: it is wiring, so it
        # is allowed to know about everything, and nothing is allowed to know about it.
        'Invoke-PSMutation.ps1 -> PSMutation.Config.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Operators.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Output.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Pester.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Recheck.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Report.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Runner.ps1'
        'Invoke-PSMutation.ps1 -> PSMutation.Sandbox.ps1'

        # Config resolves the sandbox plan and the operator list, so it reads both
        # vocabularies. It decides; neither of them decides anything about config.
        'PSMutation.Config.ps1 -> PSMutation.Operators.ps1'
        'PSMutation.Config.ps1 -> PSMutation.Sandbox.ps1'

        # Recheck holds a whole feature, orchestration included, so it drives the runner
        # and reuses the report layer rather than restating either.
        'PSMutation.Recheck.ps1 -> PSMutation.Output.ps1'
        'PSMutation.Recheck.ps1 -> PSMutation.Report.ps1'
        'PSMutation.Recheck.ps1 -> PSMutation.Runner.ps1'
        'PSMutation.Recheck.ps1 -> PSMutation.Sandbox.ps1'

        # Everything that decides what a run should SAY depends on the seam that defines
        # what a line is. The arrows point this way and must not reverse: Output.ps1
        # renders, and a renderer that knew how a score was computed would be the seam
        # dissolving back into the layers it was extracted from.
        'PSMutation.Report.ps1 -> PSMutation.Output.ps1'
        'PSMutation.Runner.ps1 -> PSMutation.Output.ps1'

        'PSMutation.Runner.ps1 -> PSMutation.Operators.ps1'
        'PSMutation.Runner.ps1 -> PSMutation.Pester.ps1'
        'PSMutation.Runner.ps1 -> PSMutation.Sandbox.ps1'
    )

    function Get-SrcAst {
        $out = @{}
        foreach ($f in Get-ChildItem $script:srcDir -Filter *.ps1) {
            $out[$f.Name] = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        }
        return $out
    }

    function Get-FileEdge {
        param($Asts)
        $definedBy = @{}
        foreach ($name in $Asts.Keys) {
            foreach ($fn in $Asts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $definedBy[$fn.Name] = $name
            }
        }
        $edges = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($name in $Asts.Keys) {
            foreach ($c in $Asts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $called = $c.GetCommandName()
                if ($called -and $definedBy.ContainsKey($called) -and $definedBy[$called] -ne $name) {
                    [void]$edges.Add("$name -> $($definedBy[$called])")
                }
            }
        }
        return $edges
    }
}

Describe 'the dependency graph in src/' {
    It 'has no file-to-file edge that is not declared' {
        # The message names the offender rather than reporting a count, because the useful
        # question on a red build is "which edge did I add", and the answer is either "add
        # it to the list deliberately" or "that call belongs somewhere else".
        $actual = Get-FileEdge -Asts (Get-SrcAst)
        $undeclared = @($actual | Where-Object { $_ -notin $script:allowedEdges })
        ($undeclared -join '; ') | Should-Be ''
    }

    It 'declares no edge that no longer exists' {
        # The other direction, and it matters for the same reason a stale equivalence
        # declaration does: an allowlist describing relationships the code dropped is a
        # document nobody can trust, and it silently permits an edge coming back.
        $actual = Get-FileEdge -Asts (Get-SrcAst)
        $stale = @($script:allowedEdges | Where-Object { $_ -notin $actual })
        ($stale -join '; ') | Should-Be ''
    }

    It 'is acyclic' {
        # The property the allowlist is protecting. An allowlist alone cannot give it:
        # two edges each reasonable on their own review make a cycle between them, and
        # nobody reviewing the second one is looking at the first.
        $edges = Get-FileEdge -Asts (Get-SrcAst)
        $out = @{}
        foreach ($e in $edges) {
            $parts = $e -split ' -> '
            if (-not $out.ContainsKey($parts[0])) { $out[$parts[0]] = [System.Collections.Generic.List[string]]::new() }
            $out[$parts[0]].Add($parts[1])
        }
        # Repeatedly drop files that depend on nothing still present. Anything left when no
        # more can be dropped is inside a cycle.
        $remaining = [System.Collections.Generic.List[string]]::new()
        (Get-SrcAst).Keys | ForEach-Object { $remaining.Add($_) }
        $progress = $true
        while ($progress) {
            $progress = $false
            foreach ($file in @($remaining)) {
                $deps = if ($out.ContainsKey($file)) { @($out[$file] | Where-Object { $remaining -contains $_ }) } else { @() }
                if ($deps.Count -eq 0) {
                    [void]$remaining.Remove($file)
                    $progress = $true
                }
            }
        }
        ($remaining -join ', ') | Should-Be ''
    }
}

Describe 'the console seam' {
    It 'keeps every Write-Host in src/ inside the one renderer' {
        # The seam's whole value is that output has a single choke point: one renderer to
        # give CI annotations or markdown, one place -Quiet is honoured, and no formatting
        # decisions loose in the scoring layer. A second Write-Host anywhere in src/ takes
        # that away silently -- the output still looks right, and every other gate passes.
        #
        # PSAvoidUsingWriteHost cannot do this job: it is excluded repo-wide because the
        # gate scripts in tools/ print for a living.
        $sites = foreach ($name in (Get-SrcAst).Keys) {
            $found = @((Get-SrcAst)[$name].FindAll({
                        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host'
                    }, $true))
            if ($found.Count -gt 0) { "${name}:$($found.Count)" }
        }
        (@($sites) -join ', ') | Should-Be 'PSMutation.Output.ps1:1'
    }
}

Describe 'module state' {
    It 'never reads a $script: variable from the file that did not write it' {
        # Locality: a constant one file writes while another reads leaves neither readable
        # on its own. Two such reads existed once and were removed in opposite directions
        # -- one default moved to its reader, the other stayed and its resolver came to it.
        # This is what stops a third appearing.
        $asts = Get-SrcAst
        $writtenIn = @{}
        foreach ($name in $asts.Keys) {
            foreach ($a in $asts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.UserPath -like 'script:*') {
                    $writtenIn[$a.Left.VariablePath.UserPath] = $name
                }
            }
        }
        $foreign = foreach ($name in $asts.Keys) {
            foreach ($v in $asts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $path = $v.VariablePath.UserPath
                if ($path -like 'script:*' -and $writtenIn.ContainsKey($path) -and $writtenIn[$path] -ne $name) {
                    "$name reads `$$path from $($writtenIn[$path])"
                }
            }
        }
        (@($foreign) -join '; ') | Should-Be ''
    }
}
