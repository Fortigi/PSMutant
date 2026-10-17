# Patterns in mutate and tests, and pairing a file with its tests by name (#265).
#
# The covering suite for self-mutating src/PSMutation.Glob.ps1 -- self-contained and cheap: a small
# tree of empty files under a GUID-named temp directory. That the run prints the lines and reads the
# expanded lists is tests/EndToEnd.Tests.ps1.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Glob.ps1')

    $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-glob-$([System.Guid]::NewGuid().ToString('N'))"
    foreach ($f in 'src/a.ps1', 'src/b.ps1', 'src/B2.psm1', 'src/sub/c.ps1', 'src/sub/deep/d.ps1', 'src/notes.md',
        'tests/a.Tests.ps1', 'tests/sub.Tests.ps1', 'other/e.ps1') {
        $p = Join-Path $script:root $f
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        Set-Content -LiteralPath $p -Value '' -Encoding utf8
    }

    function script:Expand {
        param([string]$Pattern)
        return @(Expand-PSMutationGlob -Pattern $Pattern -Root $script:root)
    }
    function script:Config {
        param([string]$Json)
        return $Json | ConvertFrom-Json
    }
}

AfterAll { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Test-PSMutationGlob' {
    It 'reads <Value> as a pattern: <Expected>' -ForEach @(
        @{ Value = 'src/*.ps1'; Expected = $true }
        @{ Value = 'src/a?.ps1'; Expected = $true }
        @{ Value = 'src/a.ps1'; Expected = $false }
        @{ Value = ''; Expected = $false }
    ) {
        Test-PSMutationGlob -Value $Value | Should-Be $Expected
    }
}

Describe 'Expand-PSMutationGlob' {
    It 'matches <Pattern> as <Expected>' -ForEach @(
        @{ Pattern = 'src/*.ps1'; Expected = 'src/a.ps1,src/b.ps1' }
        @{ Pattern = 'src/?.ps1'; Expected = 'src/a.ps1,src/b.ps1' }
        @{ Pattern = 'src/**/*.ps1'; Expected = 'src/a.ps1,src/b.ps1,src/sub/c.ps1,src/sub/deep/d.ps1' }
        @{ Pattern = 'src/**'; Expected = 'src/a.ps1,src/b.ps1,src/B2.psm1,src/notes.md,src/sub/c.ps1,src/sub/deep/d.ps1' }
        @{ Pattern = '**/c.ps1'; Expected = 'src/sub/c.ps1' }
        @{ Pattern = 'SRC/*.PS1'; Expected = 'src/a.ps1,src/b.ps1' }
        @{ Pattern = 'src\*.psm1'; Expected = 'src/B2.psm1' }
        @{ Pattern = './src/sub/*'; Expected = 'src/sub/c.ps1,src/sub/deep/d.ps1' }
        @{ Pattern = 'nowhere/*.ps1'; Expected = '' }
        @{ Pattern = 'src/*.txt'; Expected = '' }
    ) {
        (Expand $Pattern) -join ',' | Should-Be $Expected
    }

    It 'returns an array for none and for one' {
        $none = Expand-PSMutationGlob -Pattern 'nowhere/*' -Root $script:root
        Should-BeTrue -Actual ($none -is [string[]])
        $one = Expand-PSMutationGlob -Pattern '**/d.ps1' -Root $script:root
        Should-BeTrue -Actual ($one -is [string[]])
    }

    It 'walks only the directory a pattern names' {
        @(Get-PSMutationGlobStart -Pattern 'src/sub/**/*.ps1' -Root $script:root) | Should-BeCollection @((Join-Path $script:root 'src/sub'))
        @(Get-PSMutationGlobStart -Pattern '*.ps1' -Root $script:root) | Should-BeCollection @($script:root)
        @(Get-PSMutationGlobStart -Pattern 'gone/x/*.ps1' -Root $script:root).Count | Should-Be 0
    }
}

Describe 'ConvertTo-PSMutationGlobRegex' {
    It 'keeps * and ? inside a segment, and lets ** span them' {
        $one = ConvertTo-PSMutationGlobRegex -Pattern 'a/*/c'
        $one.IsMatch('a/b/c') | Should-BeTrue
        $one.IsMatch('a/b/x/c') | Should-BeFalse
        $one.IsMatch('a/b/c/below') | Should-BeTrue
        (ConvertTo-PSMutationGlobRegex -Pattern 'a/**/c').IsMatch('a/b/x/c') | Should-BeTrue
        (ConvertTo-PSMutationGlobRegex -Pattern 'a/**/c').IsMatch('a/c') | Should-BeTrue
        # A ** in the middle spans whole segments only.
        (ConvertTo-PSMutationGlobRegex -Pattern 'a/**/c').IsMatch('a/bc') | Should-BeFalse
        (ConvertTo-PSMutationGlobRegex -Pattern 'a?').IsMatch('a/') | Should-BeFalse
        (ConvertTo-PSMutationGlobRegex -Pattern 'a.b').IsMatch('axb') | Should-BeFalse
    }
}

Describe 'Expand-PSMutationPathList' {
    It 'keeps paths as written, adds what patterns match, and adds none twice' {
        $r = Expand-PSMutationPathList -Entry @('src/sub/c.ps1', 'src/*.ps1', './src/b.ps1', 'src/**/*.ps1') -Root $script:root -Key 'mutate'
        $r.Files | Should-BeCollection @('src/sub/c.ps1', './src/b.ps1', 'src/a.ps1', 'src/sub/deep/d.ps1')
        $r.Faults.Count | Should-Be 0
        @($r.Expanded.Pattern) | Should-BeCollection @('src/*.ps1', 'src/**/*.ps1')
        $r.Expanded[0].Files | Should-BeCollection @('src/a.ps1', 'src/b.ps1')
    }

    It 'names each pattern that matches nothing, and still expands the rest' {
        $r = Expand-PSMutationPathList -Entry @('src/*.ps1', 'gone/*.ps1', 'x/??.ps1') -Root $script:root -Key "tests['src/a.ps1']"
        $r.Files | Should-BeCollection @('src/a.ps1', 'src/b.ps1')
        $r.Faults | Should-BeCollection @(
            "Config key 'tests['src/a.ps1']' has the pattern 'gone/*.ps1', which matches no file under $script:root"
            "Config key 'tests['src/a.ps1']' has the pattern 'x/??.ps1', which matches no file under $script:root"
        )
    }

    It 'keeps an entry that is not a string for the schema to refuse' {
        (Expand-PSMutationPathList -Entry @(1, 'src/a.ps1') -Root $script:root -Key 'mutate').Files.Count | Should-Be 2
    }

    It 'gives empty lists for an empty one' {
        $r = Expand-PSMutationPathList -Entry @() -Root $script:root -Key 'mutate'
        $r.Files.Count | Should-Be 0
        $r.Expanded.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationConventionTest' {
    It 'pairs a file with tests/<Name>.Tests.ps1, from any directory, and nothing when that is not there' {
        Get-PSMutationConventionTest -File 'src/a.ps1' -Root $script:root | Should-Be 'tests/a.Tests.ps1'
        Get-PSMutationConventionTest -File 'src/deep/sub.psm1' -Root $script:root | Should-Be 'tests/sub.Tests.ps1'
        Get-PSMutationConventionTest -File 'src/b.ps1' -Root $script:root | Should-BeNull
    }
}

Describe 'ConvertTo-PSMutationRootRelative' {
    It 'spells <Path> as <Expected>' -ForEach @(
        @{ Path = 'src/a.ps1'; Expected = 'src/a.ps1' }
        @{ Path = './src/a.ps1'; Expected = 'src/a.ps1' }
        @{ Path = 'src\a.ps1'; Expected = 'src/a.ps1' }
        @{ Path = 'src/../src/a.ps1'; Expected = 'src/a.ps1' }
        @{ Path = '.hidden/a.ps1'; Expected = '.hidden/a.ps1' }
    ) {
        ConvertTo-PSMutationRootRelative -Path $Path -Root $script:root | Should-Be $Expected
    }
}

Describe 'Resolve-PSMutationConfigPattern' {
    It 'expands mutate and every tests list, and says what each pattern became' {
        $cfg = Config '{ "mutate": ["src/*.ps1"], "tests": { "src/a.ps1": ["tests/*.Tests.ps1"], "src/b.ps1": "tests/a.Tests.ps1" }, "workers": 2 }'
        $r = Resolve-PSMutationConfigPattern -Cfg $cfg -Root $script:root
        $r.Cfg.mutate | Should-BeCollection @('src/a.ps1', 'src/b.ps1')
        $r.Cfg.tests.'src/a.ps1' | Should-BeCollection @('tests/a.Tests.ps1', 'tests/sub.Tests.ps1')
        $r.Cfg.tests.'src/b.ps1' | Should-BeCollection @('tests/a.Tests.ps1')
        $r.Cfg.workers | Should-Be 2
        $r.Lines | Should-BeCollection @(
            "  mutate 'src/*.ps1' -> src/a.ps1, src/b.ps1"
            "  tests['src/a.ps1'] 'tests/*.Tests.ps1' -> tests/a.Tests.ps1, tests/sub.Tests.ps1"
        )
        # The caller's object is left as it was.
        $cfg.mutate | Should-BeCollection @('src/*.ps1')
    }

    It 'says nothing for a config with no pattern' {
        $r = Resolve-PSMutationConfigPattern -Cfg (Config '{ "mutate": "src/a.ps1", "tests": { "src/a.ps1": ["tests/a.Tests.ps1"] } }') -Root $script:root
        $r.Lines.Count | Should-Be 0
        $r.Cfg.mutate | Should-BeCollection @('src/a.ps1')
    }

    It 'refuses every pattern that matches nothing, in mutate and in tests, at once' {
        $cfg = Config '{ "mutate": ["gone/*.ps1"], "tests": { "src/a.ps1": ["none/*.ps1"] } }'
        { Resolve-PSMutationConfigPattern -Cfg $cfg -Root $script:root } |
            Should-Throw -ExceptionMessage "Config key 'mutate' has the pattern 'gone/*.ps1'*; Config key 'tests*' has the pattern 'none/*.ps1'*. A pattern is a claim about files*"
    }

    It 'pairs by name only when asked, and never over an explicit entry' {
        $json = '{ "mutate": ["src/*.ps1", "src/sub/*.ps1"], "tests": { "./src/b.ps1": ["tests/sub.Tests.ps1"] }, "testsByConvention": BY }'
        $off = Resolve-PSMutationConfigPattern -Cfg (Config $json.Replace('BY', 'false')) -Root $script:root
        @($off.Cfg.tests.PSObject.Properties.Name) | Should-BeCollection @('./src/b.ps1')
        $on = Resolve-PSMutationConfigPattern -Cfg (Config $json.Replace('BY', 'true')) -Root $script:root
        # a pairs by name; b keeps its entry; c has no tests/c.Tests.ps1, so it stays unmapped.
        @($on.Cfg.tests.PSObject.Properties.Name) | Should-BeCollection @('./src/b.ps1', 'src/a.ps1')
        $on.Cfg.tests.'src/a.ps1' | Should-BeCollection @('tests/a.Tests.ps1')
        $on.Lines[-1] | Should-Be '  src/a.ps1 -> tests/a.Tests.ps1 (by name)'
    }

    It 'refuses one pattern that matches nothing' {
        { Resolve-PSMutationConfigPattern -Cfg (Config '{ "mutate": ["src/*.ps1", "gone/*.ps1"], "tests": {} }') -Root $script:root } |
            Should-Throw -ExceptionMessage "Config key 'mutate' has the pattern 'gone/*.ps1'*"
    }

    It 'keeps an explicit entry even where a test by name exists' {
        $r = Resolve-PSMutationConfigPattern -Cfg (Config '{ "mutate": ["src/a.ps1"], "tests": { "src/a.ps1": ["tests/sub.Tests.ps1"] }, "testsByConvention": true }') -Root $script:root
        $r.Cfg.tests.'src/a.ps1' | Should-BeCollection @('tests/sub.Tests.ps1')
        $r.Lines.Count | Should-Be 0
    }

    It 'pairs by name with no tests map at all' {
        $r = Resolve-PSMutationConfigPattern -Cfg (Config '{ "mutate": ["src/a.ps1"], "tests": {}, "testsByConvention": true }') -Root $script:root
        $r.Cfg.tests.'src/a.ps1' | Should-BeCollection @('tests/a.Tests.ps1')
    }
}

Describe 'Test-PSMutationTestsEntry' {
    It 'finds an entry however the config spells the file' {
        $tests = [ordered]@{ './src/a.ps1' = @('t') }
        Test-PSMutationTestsEntry -Tests $tests -File 'src/a.ps1' -Root $script:root | Should-BeTrue
        Test-PSMutationTestsEntry -Tests $tests -File 'src/b.ps1' -Root $script:root | Should-BeFalse
        Test-PSMutationTestsEntry -Tests ([ordered]@{}) -File 'src/a.ps1' -Root $script:root | Should-BeFalse
    }
}
