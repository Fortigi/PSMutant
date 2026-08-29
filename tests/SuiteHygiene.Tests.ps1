# Properties of the SUITE itself, rather than of src/.
#
# The suite is the oracle every other gate reads, so a defect in it is invisible to all of
# them: a test that cannot fail still reports a pass, and a file whose blocks depend on each
# other still reports a pass when run whole. Nothing else here looks at the tests as data.
#
# This file exists because #43 fixed two shared-state instances somebody happened to notice,
# and nothing then checked whether there were others. There were: measured across the nine
# covering files, 4 of 102 blocks failed when run on their own, all from one cause.

BeforeAll {
    $script:testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
            Sort-Object Name)
}

Describe 'a test file keeps its fixtures inside a Pester block' {
    It 'assigns no $script: variable at the top level of the file' -ForEach @(
        @{ Case = 'the real suite' }
    ) {
        # THE CAUSE, caught directly and instantly, beside the tool that catches the symptom
        # by running each block alone -- the same two-sided arrangement the order-independence
        # gate uses, and for the same reason: the probe is one permutation rather than a proof,
        # while this fires on the file that leaks whether or not anything reads it yet.
        #
        # A top-level `$script:x = ...` in a Pester 5+ file runs during DISCOVERY and never
        # reaches the run phase. It therefore does one of two things, and both are bad: the
        # variable is empty when the block runs on its own, or -- worse -- some sibling
        # Describe's BeforeAll has already written the same name, and the block silently reads
        # THAT instead. Measured: a Describe naming GetTempPath() was reading a fake repo under
        # TestDrive left by an earlier sibling, and passed for two releases because its
        # assertions only ever checked a file name.
        #
        # Assignments INSIDE BeforeAll/BeforeEach/Describe/Context/It are the correct spelling
        # and are not matched: the check is about depth, not about the $script: prefix.
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $script:testFiles) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            foreach ($a in $ast.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.Left.VariablePath.IsScript
                    }, $true)) {
                # Top level means: no enclosing scriptblock at all. Every Pester block body --
                # BeforeAll, Describe, It -- is a ScriptBlockExpressionAst, so anything properly
                # nested has one in its parent chain.
                $p = $a.Parent
                $nested = $false
                while ($p) {
                    if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
                    $p = $p.Parent
                }
                if (-not $nested) {
                    $offenders.Add("$($f.Name):$($a.Extent.StartLineNumber)  $($a.Extent.Text -split "`n" | Select-Object -First 1)")
                }
            }
        }
        $offenders -join ' | ' | Should-Be '' -Because 'a top-level $script: assignment runs at discovery and never reaches the run phase'
    }

    It 'is looking at the files it claims to be looking at' {
        # The pairing this repo requires of every "X is absent" assertion: without it, a glob
        # that matched nothing would certify the whole suite as clean.
        @($script:testFiles).Count | Should-BeGreaterThan 10
        @($script:testFiles.Name) | Should-ContainCollection 'Config.Tests.ps1'
    }
}
