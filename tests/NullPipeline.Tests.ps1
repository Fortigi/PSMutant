# Piping a PROPERTY into ForEach-Object, as a checked allowlist.
#
# `$null | ForEach-Object` runs its body ONCE with $_ = $null. That is not a corner case: it is
# how PSMutation.Runner.ps1 came to hand [System.IO.Path]::GetFullPath an empty string and die
# inside the baseline the first time the coverage tracer was switched off, because Pester reports
# $result.CodeCoverage as $null rather than as an object with no commands.
#
# Measured, because every intuition about this is wrong:
#
#     $null | ForEach-Object        -> 1 iteration
#     @($null) | ForEach-Object     -> 1 iteration   (@($null) has one element, and it is $null)
#     foreach ($x in $null)         -> 0 iterations
#     <command emitting nothing> |  -> 0 iterations
#
# The last line is why this is hard to see by eye: `& $fn | ForEach-Object { ... }` is safe, and
# looks identical. Only a value -- a variable or a property -- behaves this way.
#
# NO OTHER GATE HERE CAN SEE IT. Coverage watches the line execute; self-mutation finds no
# survivor, because no operator turns a pipeline into a foreach; and the tests never supply the
# one value that triggers it. Coverage and mutation were both at 100% while this was live.

BeforeAll {
    $script:srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'

    # One entry per SITE, spelled `File -> expression`, each with the reason the property cannot
    # be $null. A line number would churn on every edit above it; the expression is what a
    # reviewer actually has to think about.
    $script:allowedPipelines = @(
        # Both are config properties, and Assert-PSMutationConfig has already validated the
        # document against schemas/v1/config.schema.json by the time the plan is built. The schema
        # types `mutate` as an array and each `tests` value as an array, so neither can arrive
        # null without the run having been refused first.
        'PSMutation.Config.ps1 -> $Cfg.mutate'
        'PSMutation.Config.ps1 -> $prop.Value'

        # A PSDataCollection on a live runspace. It is created with the runspace and is empty
        # rather than absent when nothing was written to it.
        'PSMutation.Pester.ps1 -> $Runspace.Streams.Error'

        # Pester's own result object. MEASURED on 6.1.0: a green run reports .Failed as an empty
        # collection, not $null, so the pipeline yields nothing. This is the property that sits
        # beside the one that DID come back null -- .CodeCoverage with the tracer off -- which is
        # why neither is assumed.
        'PSMutation.Pester.ps1 -> $r.Failed'
        'PSMutation.Runner.ps1 -> $result.Failed'
    )

    function Get-PropertyPipeline {
        # Every pipeline in src/ whose first element is a bare property access feeding
        # ForEach-Object. Returned as `File -> expression`, matching the allowlist.
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($f in Get-ChildItem $script:srcDir -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
                if ($p.PipelineElements.Count -lt 2) { continue }
                $first = $p.PipelineElements[0]
                if ($first -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                if ($first.Expression -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
                foreach ($el in $p.PipelineElements[1..($p.PipelineElements.Count - 1)]) {
                    if ($el -isnot [System.Management.Automation.Language.CommandAst]) { continue }
                    if ($el.GetCommandName() -in 'ForEach-Object', '%') {
                        $found.Add("$($f.Name) -> $($first.Expression.Extent.Text)")
                        break
                    }
                }
            }
        }
        return , [string[]]@($found | Sort-Object -Unique)
    }
}

Describe 'a property piped into ForEach-Object' {
    It 'is declared, or written as a foreach statement' {
        # The message names the offender rather than counting, because the useful question on a
        # red build is "which one did I add", and the answer is either "write it as a foreach" or
        # "declare it, with the reason that property cannot be null".
        # ASSIGNED, then filtered. Get-PropertyPipeline comma-wraps its result so an empty answer
        # stays an array, and PIPING that wrapper hands the whole array through as one element --
        # the sibling of the very trap this file exists to catch, met while writing it.
        $actual = Get-PropertyPipeline
        $undeclared = @($actual | Where-Object { $_ -notin $script:allowedPipelines })
        ($undeclared -join '; ') | Should-Be ''
    }

    It 'declares nothing the code no longer does' {
        # The other direction, for the reason a stale equivalence declaration matters: a list
        # describing sites the code dropped is one nobody can trust, and it silently permits the
        # same pipeline coming back somewhere else in the file.
        $actual = Get-PropertyPipeline
        $stale = @($script:allowedPipelines | Where-Object { $_ -notin $actual })
        ($stale -join '; ') | Should-Be ''
    }

    It 'finds the sites at all, so neither assertion can pass vacuously' {
        # Two empty lists agree. A walker that silently matched nothing -- a renamed Ast type, a
        # changed property -- would satisfy both tests above while checking nothing.
        @(Get-PropertyPipeline).Count | Should-BeGreaterThan 0
    }
}

Describe 'what this rule deliberately leaves out' {
    # Both exclusions are measured rather than assumed, and both are recorded here so the next
    # person weighing them starts from the numbers instead of the intuition.

    It 'does not cover a VARIABLE piped into ForEach-Object, and the count is why' {
        # 33 sites in src/, against 9 property-sourced. Almost all are locals assigned from
        # @( ... ) a line or two above, where the value provably cannot be null -- so an
        # allowlist over them would be a rubber stamp, and a rubber stamp is how a list stops
        # being read. A property is different: it is null when its OWNER chose not to populate
        # it, which is exactly what Pester does with .CodeCoverage.
        $script:variableSourced = 0
        foreach ($f in Get-ChildItem $script:srcDir -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
                if ($p.PipelineElements.Count -lt 2) { continue }
                $first = $p.PipelineElements[0]
                if ($first -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                if ($first.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                foreach ($el in $p.PipelineElements[1..($p.PipelineElements.Count - 1)]) {
                    if ($el -is [System.Management.Automation.Language.CommandAst] -and
                        $el.GetCommandName() -in 'ForEach-Object', '%') { $script:variableSourced++; break }
                }
            }
        }
        # Asserted as a bound rather than a figure, so ordinary edits do not fail this and a
        # tenfold change still does. If this ever drops to a handful, the exclusion is worth
        # revisiting -- which is the only reason the number is checked at all.
        $script:variableSourced | Should-BeGreaterThan 9
    }

    It 'does not cover Where-Object, because a null element fails a truthiness predicate' {
        # 28 sites, and the mechanism is the same but the consequence is not: `$null` reaching
        # `Where-Object { $_ }` is discarded, which is the idiom this codebase already uses to
        # guard against exactly this. The dangerous shape is a DEREFERENCING predicate --
        # `Where-Object { $_.StartsWith('_') }` throws on $null -- and that is a narrower rule
        # than "any Where-Object", worth its own decision rather than folded in here.
        #
        # Every property-sourced Where-Object in src/ today is the `{ $_ }` form, so widening
        # the rule now would add four entries that all say "this is the guard".
        $bare = 0
        foreach ($f in Get-ChildItem $script:srcDir -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
                if ($p.PipelineElements.Count -lt 2) { continue }
                $first = $p.PipelineElements[0]
                if ($first -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                if ($first.Expression -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
                foreach ($el in $p.PipelineElements[1..($p.PipelineElements.Count - 1)]) {
                    if ($el -is [System.Management.Automation.Language.CommandAst] -and
                        $el.GetCommandName() -in 'Where-Object', '?') { $bare++; break }
                }
            }
        }
        $bare | Should-BeGreaterThan 0 -Because 'the exclusion is about sites that exist; if there are none, delete the exclusion'
    }
}
