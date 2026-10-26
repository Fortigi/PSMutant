# Unit tests for tools/ReleaseThanks.ps1 -- who a release thanks, and how (#314).

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools' -AdditionalChildPath 'ReleaseThanks.ps1')

    function script:New-ThanksItem([int]$Number, [string]$Author, [string]$Association, [bool]$IsBot = $false, [bool]$IsTeam = $false) {
        [pscustomobject]@{ Number = $Number; Author = $Author; Association = $Association; IsBot = $IsBot; IsTeam = $IsTeam }
    }
    function script:New-ThanksPr([int]$Number, [string]$Author, [string]$Association, [object[]]$Closes = @(), [bool]$IsBot = $false) {
        $p = New-ThanksItem $Number $Author $Association $IsBot
        $p | Add-Member -NotePropertyName Closes -NotePropertyValue $Closes
        $p
    }
}

Describe 'Test-PSMutantOutsideAuthor' {
    It 'counts every association GitHub gives someone outside the team' {
        foreach ($a in 'CONTRIBUTOR', 'FIRST_TIME_CONTRIBUTOR', 'FIRST_TIMER', 'NONE') {
            Test-PSMutantOutsideAuthor -Association $a | Should-BeTrue
        }
    }

    It 'never counts the team, an unknown association or a bot' {
        foreach ($a in 'MEMBER', 'OWNER', 'COLLABORATOR', 'MANNEQUIN', '') {
            Test-PSMutantOutsideAuthor -Association $a | Should-BeFalse
        }
        # A bot is not thanked even when GitHub calls it a contributor, which dependabot is.
        Test-PSMutantOutsideAuthor -Association 'CONTRIBUTOR' -IsBot $true | Should-BeFalse
        # Nor anyone with write access here, whatever association the asking token was shown (#317).
        Test-PSMutantOutsideAuthor -Association 'CONTRIBUTOR' -IsTeam $true | Should-BeFalse
    }
}

Describe 'Test-PSMutantTeamPermission' {
    It 'calls write, maintain and admin the team, and nothing else' {
        foreach ($p in 'admin', 'maintain', 'write') { Test-PSMutantTeamPermission -Permission $p | Should-BeTrue }
        foreach ($p in 'triage', 'read', 'none', '') { Test-PSMutantTeamPermission -Permission $p | Should-BeFalse }
    }
}

Describe 'Get-PSMutantOutsideContribution' {
    It 'leaves out a maintainer whose private membership makes them look like a contributor (#317)' {
        # The 0.9.1 release: to the workflow's token a private org member reads CONTRIBUTOR.
        $prs = @(
            New-ThanksPr 313 'taeke' 'CONTRIBUTOR' @(New-ThanksItem 309 'alexey' 'CONTRIBUTOR'; New-ThanksItem 314 'taeke' 'CONTRIBUTOR' $false $true) $false
            New-ThanksPr 312 'alexey' 'CONTRIBUTOR'
        )
        $prs[0].IsTeam = $true
        $c = @(Get-PSMutantOutsideContribution -PullRequest $prs)
        ($c | ForEach-Object Login) -join ',' | Should-Be 'alexey'
        $c[0].Reported -join ',' | Should-Be '309'
        $c[0].Authored -join ',' | Should-Be '312'
    }

    It 'credits an outside reporter for the issue an inside pull request closes' {
        $c = @(Get-PSMutantOutsideContribution -PullRequest @(New-ThanksPr 313 'taeke' 'MEMBER' @(New-ThanksItem 309 'alexey' 'CONTRIBUTOR')))
        $c.Count | Should-Be 1
        $c[0].Login | Should-Be 'alexey'
        $c[0].Reported -join ',' | Should-Be '309'
        @($c[0].Authored).Count | Should-Be 0
    }

    It 'gathers one person''s reports and pull requests, each once and in order, and leaves the team out' {
        $prs = @(
            New-ThanksPr 312 'alexey' 'CONTRIBUTOR' @(New-ThanksItem 310 'alexey' 'CONTRIBUTOR')
            New-ThanksPr 313 'taeke' 'MEMBER' @(New-ThanksItem 309 'alexey' 'CONTRIBUTOR'; New-ThanksItem 305 'taeke' 'MEMBER')
            # The same issue closed twice must not be credited twice.
            New-ThanksPr 315 'taeke' 'MEMBER' @(New-ThanksItem 309 'alexey' 'CONTRIBUTOR')
            New-ThanksPr 308 'dependabot' 'CONTRIBUTOR' @() $true
            New-ThanksPr 316 'bea' 'FIRST_TIME_CONTRIBUTOR'
        )
        $c = @(Get-PSMutantOutsideContribution -PullRequest $prs)
        ($c | ForEach-Object Login) -join ',' | Should-Be 'alexey,bea'
        $c[0].Reported -join ',' | Should-Be '309,310'
        $c[0].Authored -join ',' | Should-Be '312'
        $c[1].Authored -join ',' | Should-Be '316'
    }

    It 'returns nothing for a release with no outside work, or no pull requests at all' {
        @(Get-PSMutantOutsideContribution -PullRequest @(New-ThanksPr 1 'taeke' 'OWNER' @(New-ThanksItem 2 'wim' 'MEMBER'))).Count | Should-Be 0
        @(Get-PSMutantOutsideContribution -PullRequest @()).Count | Should-Be 0
    }
}

Describe 'Join-PSMutantItemList' {
    It 'names one, two and three items the way a sentence does' {
        Join-PSMutantItemList -Number 5 | Should-Be '#5'
        Join-PSMutantItemList -Number 5, 7 | Should-Be '#5 and #7'
        Join-PSMutantItemList -Number 5, 7, 9 | Should-Be '#5, #7 and #9'
    }
}

Describe 'Format-PSMutantThankYou' {
    It 'thanks a reporter for the report, an author for the change, and someone who did both for both' {
        $c = @(
            [pscustomobject]@{ Login = 'alexey'; Reported = [int[]]@(309, 310); Authored = [int[]]@(312) }
            [pscustomobject]@{ Login = 'bea'; Reported = [int[]]@(); Authored = [int[]]@(316) }
            [pscustomobject]@{ Login = 'cas'; Reported = [int[]]@(400); Authored = [int[]]@() }
        )
        Format-PSMutantThankYou -Contribution $c | Should-Be ("### Thank you`n`n" +
            "- @alexey for reporting #309 and #310, and for #312.`n" +
            "- @bea for #316.`n" +
            '- @cas for reporting #400.')
    }

    It 'adds no section when nobody outside contributed' {
        Should-BeNull -Actual (Format-PSMutantThankYou -Contribution @())
    }
}

Describe 'Get-PSMutantThanksComment' {
    It 'writes one comment per item, in number order, linking the release' {
        $c = @(
            [pscustomobject]@{ Login = 'alexey'; Reported = [int[]]@(310); Authored = [int[]]@(312) }
            [pscustomobject]@{ Login = 'bea'; Reported = [int[]]@(309); Authored = [int[]]@() }
        )
        $out = @(Get-PSMutantThanksComment -Contribution $c -Tag 'v0.9.1' -ReleaseUrl 'https://x/v0.9.1')
        ($out | ForEach-Object Number) -join ',' | Should-Be '309,310,312'
        $out[0].Body | Should-Be 'Thank you for reporting this, @bea! The fix shipped in [v0.9.1](https://x/v0.9.1).'
        $out[1].Body | Should-Be 'Thank you for reporting this, @alexey! The fix shipped in [v0.9.1](https://x/v0.9.1).'
        $out[2].Body | Should-Be 'Thank you for this, @alexey! It shipped in [v0.9.1](https://x/v0.9.1).'
    }

    It 'writes none when nobody outside contributed' {
        @(Get-PSMutantThanksComment -Contribution @() -Tag 'v1' -ReleaseUrl 'u').Count | Should-Be 0
    }
}
