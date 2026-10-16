# Equivalent-mutant declarations written in the code (#262).
#
# The covering suite for self-mutating src/PSMutation.Inline.ps1 -- keep it self-contained and
# cheap: fixtures are strings parsed in memory, plus a few small files under a GUID-named temp
# directory for the one function that reads them. Whether a declaration's key then matches its
# mutant is the ordinary equivalence check, in tests/Report.Tests.ps1; the whole path is in
# tests/EndToEnd.Tests.ps1.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Inline.ps1')

    function script:Tokens {
        param([string]$Source)
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$null)
        return , @($tokens)
    }
    function script:Declare {
        param([string]$Source)
        return Get-PSMutationInlineDeclaration -Text $Source -Token (Tokens $Source) -File 'src/a.ps1'
    }

    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-inline-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:work 'src') -Force | Out-Null
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'a declaration directly above a mutated line' {

    It 'becomes a line-keyed config entry naming the line below it, with its reason' {
        $r = Declare "function A { 1 }`n    # PSMutant-Equivalent: 0 -> 1: -Path is the only positional parameter`n    [Parameter(Position = 0)] `$x = 1"
        $r.Faults.Count | Should-Be 0
        $r.Declared.Count | Should-Be 1
        $r.Declared[0].Key | Should-Be 'src/a.ps1:3:0 -> 1'
        $r.Declared[0].Reason | Should-Be '-Path is the only positional parameter'
        $r.Declared[0].File | Should-Be 'src/a.ps1'
        $r.Declared[0].Line | Should-Be 2
    }

    It 'reads the first line of a file, through comment lines, case-insensitively' {
        $r = Declare "#psmutant-equivalent: `$a -gt 1 -> `$true: forced`n# why`n`$y = `$a -gt 1"
        $r.Declared[0].Key | Should-Be 'src/a.ps1:3:$a -gt 1 -> $true'
        $r.Declared[0].Line | Should-Be 1
    }

    It 'reads a colon on the original side as part of the description' {
        $r = Declare "# PSMutant-Equivalent: `$env:X -eq 1 -> `$true: never set in tests`n`$y = `$env:X -eq 1"
        $r.Declared[0].Key | Should-Be 'src/a.ps1:2:$env:X -eq 1 -> $true'
        $r.Declared[0].Reason | Should-Be 'never set in tests'
    }

    It 'is no declaration inside a string, or further into a comment' {
        $r = Declare "`$s = '# PSMutant-Equivalent: 0 -> 1: no'`n# see PSMutant-Equivalent: 0 -> 1: no`n`$x = 0"
        $r.Declared.Count | Should-Be 0
        $r.Faults.Count | Should-Be 0
    }

    It 'declares each of several mutants on one line separately' {
        $r = Declare "# PSMutant-Equivalent: 0 -> 1: a`n# PSMutant-Equivalent: 2 -> 3: b`n`$x = 0 + 2"
        @($r.Declared.Key) | Should-BeCollection @('src/a.ps1:3:0 -> 1', 'src/a.ps1:3:2 -> 3')
    }
}

Describe 'a declaration that cannot become a key' {

    It 'is refused when <Why>' -ForEach @(
        @{ Why = 'a blank line follows it'; Source = "# PSMutant-Equivalent: 0 -> 1: x`n`n`$x = 0"; Like = '*blank line*' }
        @{ Why = 'it shares a line with code'; Source = "`$x = 0 # PSMutant-Equivalent: 0 -> 1: x"; Like = '*shares its line with code*' }
        @{ Why = 'it follows the first token of the file'; Source = "x # PSMutant-Equivalent: 0 -> 1: x`n`$x = 0"; Like = '*shares its line with code*' }
        @{ Why = 'nothing follows it'; Source = "`$x = 0`n# PSMutant-Equivalent: 0 -> 1: x"; Like = '*no code follows it*' }
        @{ Why = 'only comments follow it'; Source = "`$x = 0`n# PSMutant-Equivalent: 0 -> 1: x`n# more"; Like = '*no code follows it*' }
        @{ Why = 'it names no mutation'; Source = "# PSMutant-Equivalent: because`n`$x = 0"; Like = "*'because' is not '<original> -> <mutated>: <reason>'*" }
        @{ Why = 'it gives no reason'; Source = "# PSMutant-Equivalent: 0 -> 1:   `n`$x = 0"; Like = '*gives no reason*' }
    ) {
        $r = Declare $Source
        $r.Declared.Count | Should-Be 0
        $r.Faults.Count | Should-Be 1
        $r.Faults[0] | Should-BeLikeString "src/a.ps1:* declares an equivalent mutant, but $Like"
    }

    It 'names the line of the declaration' {
        (Declare "`$x = 0`n# PSMutant-Equivalent: 0 -> 1: x`n`n`$x = 0").Faults[0] | Should-BeLikeString 'src/a.ps1:2 declares*'
    }
}

Describe 'finding a token by offset' {

    It 'finds the token starting at an offset, the last included, and none between tokens' {
        $t = Tokens 'a b cd e'
        Get-PSMutationTokenIndexAt -Token $t -Offset 0 | Should-Be 0
        Get-PSMutationTokenIndexAt -Token $t -Offset 4 | Should-Be 2
        Get-PSMutationTokenIndexAt -Token $t -Offset $t[-1].Extent.StartOffset | Should-Be ($t.Count - 1)
        Get-PSMutationTokenIndexAt -Token $t -Offset 5 | Should-Be -1
        Get-PSMutationTokenIndexAt -Token $t -Offset 99 | Should-Be -1
    }
}

Describe 'the target of a declaration' {

    It 'allows one line break, refuses two, and resets at each comment' {
        (Get-PSMutationInlineTarget -Token (Tokens "# a`n`$x") -Index 0).Line | Should-Be 2
        (Get-PSMutationInlineTarget -Token (Tokens "# a`n`n`$x") -Index 0).Fault | Should-BeLikeString '*blank line*'
        (Get-PSMutationInlineTarget -Token (Tokens "# a`n# b`n# c`n`$x") -Index 0).Line | Should-Be 4
        (Get-PSMutationInlineTarget -Token (Tokens "# a`n`$x") -Index 0).Fault | Should-BeNull
    }
}

Describe 'every equivalence a run applies' {

    BeforeAll {
        function script:Write-Src([string]$Name, [string]$Text) {
            Set-Content -LiteralPath (Join-Path $script:work "src/$Name") -Value $Text -Encoding utf8
        }
        Write-Src 'one.ps1' "# PSMutant-Equivalent: 0 -> 1: in code`n`$x = 0"
        Write-Src 'two.ps1' "`$y = 2"
        Write-Src 'bad.ps1' "# PSMutant-Equivalent: 0 -> 1: lost`n`n`$x = 0"
        Write-Src 'worse.ps1' "# PSMutant-Equivalent: nothing`n`$x = 0"
    }

    It 'is the config set with the code set added, in that order' {
        $cfg = [pscustomobject]@{ mutate = @('src/one.ps1', 'src/two.ps1'); equivalents = [pscustomobject]@{ 'src/two.ps1:F:2 -> 3' = 'in config' } }
        $all = Get-PSMutationAllEquivalent -Cfg $cfg -SourceRoot $script:work
        @($all.PSObject.Properties.Name) | Should-BeCollection @('src/two.ps1:F:2 -> 3', 'src/one.ps1:2:0 -> 1')
        $all.'src/one.ps1:2:0 -> 1' | Should-Be 'in code'
        $all.'src/two.ps1:F:2 -> 3' | Should-Be 'in config'
    }

    It 'is the code set alone when the config declares nothing' {
        $all = Get-PSMutationAllEquivalent -Cfg ([pscustomobject]@{ mutate = @('src/one.ps1') }) -SourceRoot $script:work
        @($all.PSObject.Properties.Name) | Should-BeCollection @('src/one.ps1:2:0 -> 1')
    }

    It 'refuses a single declaration that cannot become a key' {
        # One fault, not several: the refusal is "any", and a fixture with three cannot tell that
        # from "more than one".
        { Get-PSMutationAllEquivalent -Cfg ([pscustomobject]@{ mutate = @('src/bad.ps1') }) -SourceRoot $script:work } |
            Should-Throw -ExceptionMessage '*cannot be used: src/bad.ps1:1 declares*blank line*.'
    }

    It 'refuses a key the config already declares, and every declaration that cannot become one, at once' {
        $cfg = [pscustomobject]@{ mutate = @('src/one.ps1', 'src/bad.ps1', 'src/worse.ps1'); equivalents = [pscustomobject]@{ 'src/one.ps1:2:0 -> 1' = 'twice' } }
        { Get-PSMutationAllEquivalent -Cfg $cfg -SourceRoot $script:work } | Should-Throw -ExceptionMessage (
            '*cannot be used: src/one.ps1:1 declares src/one.ps1:2:0 -> 1 equivalent, and so does the config -- keep one argument; ' +
            'src/bad.ps1:1 declares*blank line*; src/worse.ps1:1 declares*not*.')
    }
}

Describe 'a mutate file that is not there' {
    It 'declares nothing, leaving the missing file to the check that owns it' {
        $r = Get-PSMutationInlineDeclaration -Text '' -Token @() -File 'src/missing.ps1'
        $r.Declared.Count | Should-Be 0
        $r.Faults.Count | Should-Be 0
        $all = Get-PSMutationAllEquivalent -Cfg ([pscustomobject]@{ mutate = @('src/missing.ps1') }) -SourceRoot $script:work
        @($all.PSObject.Properties).Count | Should-Be 0
    }
}
