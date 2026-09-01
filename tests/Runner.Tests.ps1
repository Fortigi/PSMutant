# Unit tests for the runner's pure selection/coverage helpers. The execution functions
# (baseline, per-mutant Pester, loop) are integration-tested by the self-mutation run;
# here we pin the pure parts that decide WHICH mutants to evaluate.
#
# Get-PSMutationPesterPath and Get-PSMutationBoundedPesterScript are MOCKED here and
# tested in Pester.Tests.ps1. That is what keeps this file cheap enough to be the
# covering suite: mutating a timeout necessarily produces mutants that DISABLE it, and
# against a real child runspace each one burns the whole per-mutant deadline.

BeforeAll {
    # UNIQUE PER RUN, not per process. $PID was unique enough while one process ran one suite;
    # `workers` runs several mutants of the same file at once, in separate runspaces of ONE
    # process, each running THIS file -- so a pid-named fixture is a fixture two of them share,
    # and one's cleanup deletes the other's file mid-test. Measured: it killed a mutant declared
    # equivalent, which the report then shows as a stale declaration rather than as a race.
    $script:tag = [System.Guid]::NewGuid().ToString('N')
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $src 'PSMutation.Operators.ps1')
    . (Join-Path $src 'PSMutation.Sandbox.ps1')
    . (Join-Path $src 'PSMutation.Pester.ps1')     # Get-PSMutationPesterPath, mocked below
    . (Join-Path $src 'PSMutation.Output.ps1')
    . (Join-Path $src 'PSMutation.Runner.ps1')

    $script:fixture = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-runner-$PID-$($script:tag).ps1"
    @'
function Test-Fixture {
    param($x)
    if ($x -eq 1) { return $true }
    return $false
}
'@ | Set-Content $script:fixture

    # Stands in for the sandbox, which is where the baseline's coverage XML now goes. A real
    # directory rather than temp itself, so a test can assert the file lands INSIDE it.
    $script:coverageDir = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-cov-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:coverageDir -Force | Out-Null

    # What a FINISHED job looks like from the scheduler's side. Dispatch is asynchronous, so a
    # test that wants to control a mutant's verdict mocks the PAIR: Start hands back a job whose
    # handle is already signalled, and Complete answers with the verdict under test. Nothing here
    # touches a runspace, which is what keeps this file cheap enough to be Runner.ps1's covering
    # suite -- mutating a timeout necessarily produces mutants that DISABLE it, and against a real
    # child each one burns the whole per-mutant deadline.
    function StubJob {
        param($Source, [int]$Index = 0, [double]$Seconds = 0, $Original = '', [bool]$Completed = $true,
            [int]$WorkerId = 0)
        return [pscustomobject]@{
            WorkerId        = $WorkerId
            Shell           = $null
            Async           = [pscustomobject]@{
                IsCompleted     = $Completed
                AsyncWaitHandle = [System.Threading.ManualResetEvent]::new($Completed)
            }
            Candidate       = $Source
            Source          = $Source
            Index           = $Index
            OriginalContent = $Original
            Clock           = [pscustomobject]@{ Elapsed = [timespan]::FromSeconds($Seconds) }
        }
    }
}

AfterAll {
    Remove-Item $script:fixture -ErrorAction SilentlyContinue
    Remove-Item $script:coverageDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-PSMutantCovered' {
    It 'is true when the candidate line was executed' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should-BeTrue
    }
    It 'is false when the line was not executed' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(99) }
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines $covered | Should-BeFalse
    }
    It 'is false when the file was never covered' {
        Test-PSMutantCovered -Candidate ([pscustomobject]@{ File = $script:fixture; Line = 3 }) -CoveredLines @{} | Should-BeFalse
    }
}

Describe 'Select-PSMutationCandidate' {
    It 'returns all candidates when coverage filtering is off' {
        $c = (Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false -CoveredLines @{}).Candidates
        $c.Count | Should-BeGreaterThan 0
    }
    It 'reports what filtering removed, per file' {
        # The pre-filter count exists only here. Without it the caller cannot tell a file
        # that contributed nothing from one that was never in `mutate`, because the file is
        # still listed and still hashed into the report either way.
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        $sel = Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered
        $sel.PerFile.Count | Should-Be 1
        # Discriminating: Produced must exceed Kept here, or the fixture proves nothing about
        # a filter that removed anything.
        $sel.PerFile[0].Produced | Should-BeGreaterThan $sel.PerFile[0].Kept
        $sel.PerFile[0].Kept | Should-Be $sel.Candidates.Count
    }

    It 'keeps only candidates on covered lines when filtering is on' {
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        $c = (Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered).Candidates
        ($c | ForEach-Object Line | Sort-Object -Unique) | Should-Be 3
    }
}

Describe 'Get-PSMutationProgressLine' {
    It 'marks a survivor with . as Warn and a kill with x as Muted' -ForEach @(
        @{ Status = 'Survived'; Glyph = '.'; Role = 'Warn' }
        @{ Status = 'Killed'; Glyph = 'x'; Role = 'Muted' }
        @{ Status = 'TimedOut'; Glyph = 'x'; Role = 'Muted' }
    ) {
        # The glyph is how a long run is read at a glance; swapping them would invert the
        # meaning of every line of output while still "reporting progress".
        $line = Get-PSMutationProgressLine -Index 3 -Total 10 `
            -Result ([pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = $Status }) -DisplayFile 'calc.ps1'
        # -Match with an escaped pattern, NOT -BeLike: in a wildcard, "[3/10]" is a
        # character class matching one of 3 / 1 0, so the obvious assertion silently tests
        # something else entirely.
        $line.Text | Should-MatchString ([regex]::Escape("[3/10] $Glyph "))
        $line.Role | Should-Be $Role
    }

    It 'shows the file, line and the change being tried' {
        $line = Get-PSMutationProgressLine -Index 1 -Total 2 `
            -Result ([pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = 'Killed' }) -DisplayFile 'calc.ps1'
        $line.Text | Should-BeLikeString '*calc.ps1:42*-eq -> -ne*'
    }

    It 'carries the mutant row as data' {
        # So a renderer other than the console has the values without parsing the text.
        $row = [pscustomobject]@{ Line = 42; Description = '-eq -> -ne'; Status = 'Survived' }
        $line = Get-PSMutationProgressLine -Index 1 -Total 2 -Result $row -DisplayFile 'calc.ps1'
        $line.Data.Line | Should-Be 42
    }
}

# The pure scheduler decisions come FIRST in this file, and the order is load-bearing. Several
# mutants of them do not produce a wrong answer but an INFINITE LOOP in Invoke-PSMutationLoop --
# a sweep that never collects anything, a dispatch that never dispatches. Reached through a loop
# test, each costs the whole per-mutant budget and is scored TimedOut; reached through the unit
# tests below, each fails in milliseconds. Pester stops a mutant's suite at the first failure, so
# whichever Describe runs first decides which of those two happens.

Describe 'Get-PSMutationFreeWorker' {
    It 'takes the LOWEST idle worker, so the choice is a fact rather than an enumeration order' {
        Get-PSMutationFreeWorker -InFlight @('busy', $null, $null) | Should-Be 1
    }

    It 'reports -1 when every worker is busy' {
        # Not 0 and not $null: the dispatch loop compares against zero to decide whether to stop,
        # and either of those would look like "worker 0 is free" and start a second mutant on a
        # [PowerShell] instance that is already running one, which throws.
        Get-PSMutationFreeWorker -InFlight @('busy', 'busy') | Should-Be -1
    }

    It 'binds an IDLE POOL, which is an array whose every element is null' {
        # PowerShell's mandatory check unwraps a single-element collection before testing it, so a
        # one-worker pool with nothing in flight is `@($null)` and binds as null -- refused unless
        # the parameter also says [AllowNull()]. The serial case, which every other test here
        # exercises, failed at the first dispatch while every parallel one bound fine.
        Get-PSMutationFreeWorker -InFlight ([object[]]::new(1)) | Should-Be 0
    }
}

Describe 'Get-PSMutationJobState' {
    It 'asks whether the child FINISHED before it asks the clock' {
        # A child that finished a hair before its budget ran out has a verdict, and reading the
        # clock first would throw that verdict away and score the mutant Killed on a timeout it
        # did not have -- toward the flattering answer.
        Get-PSMutationJobState -Completed $true -ElapsedSeconds 99 -TimeoutSeconds 5 | Should-Be 'Complete'
    }

    It 'expires a child that is still running past its budget' {
        Get-PSMutationJobState -Completed $false -ElapsedSeconds 5 -TimeoutSeconds 5 | Should-Be 'Expired'
    }

    It 'leaves a child inside its budget running' {
        Get-PSMutationJobState -Completed $false -ElapsedSeconds 4.9 -TimeoutSeconds 5 | Should-Be 'Running'
    }
}

Describe 'Get-PSMutationWaitBudget' {
    It 'waits only as long as the SOONEST budget still has left' {
        # The least, not the average and not a fixed poll interval: a mutant is cut off on its own
        # budget, and one that expires while the scheduler is asleep on somebody else's clock has
        # overrun by however long the nap was.
        Get-PSMutationWaitBudget -ElapsedSeconds @(1.0, 9.5, 3.0) -TimeoutSeconds 10 | Should-Be 500
    }

    It 'never returns zero, however far past its budget a mutant is' {
        # A zero timeout makes WaitAny a non-blocking poll, so a mutant already past its budget
        # would spin the scheduler at full speed until the sweep reached it.
        Get-PSMutationWaitBudget -ElapsedSeconds @(99) -TimeoutSeconds 10 | Should-Be 1
    }

    It 'falls back to the whole budget when nothing has started yet' {
        Get-PSMutationWaitBudget -ElapsedSeconds @() -TimeoutSeconds 7 | Should-Be 7000
    }
}

Describe 'Get-PSMutationLoopFault' {
    It 'reports a STALLED mutant ahead of an over-budget run' {
        # The order is the answer's quality. A mutant whose own clock says its bound never fired
        # names the CAUSE; a run past its total budget names only the symptom, and both are true
        # at once on a machine that slept mid-run.
        Get-PSMutationLoopFault -MutantSeconds 52500 -ElapsedSeconds 60000 -TimeoutSeconds 15 `
            -DeadlineSeconds 100 -Index 3 -Total 9 | Should-MatchString 'suspended or wedged'
    }

    It 'falls through to the run budget when no single mutant is to blame' {
        Get-PSMutationLoopFault -MutantSeconds 2 -ElapsedSeconds 600 -TimeoutSeconds 15 `
            -DeadlineSeconds 100 -Index 3 -Total 9 | Should-MatchString 'passed its wall-clock budget'
    }

    It 'says nothing about a run that is merely working' {
        Should-BeNull -Actual (Get-PSMutationLoopFault -MutantSeconds 2 -ElapsedSeconds 30 `
                -TimeoutSeconds 15 -DeadlineSeconds 100 -Index 3 -Total 9)
    }
}

Describe 'the scheduler retires in candidate order' {
    BeforeAll {
        $script:rowCand = [pscustomobject]@{ Id = 1; Function = 'F'; File = 'a.ps1'; Line = 1
            Operator = 'BinaryOperator'; Description = 'x' }
        function StubContext {
            param($Sink, [int]$Total = 3)
            return [pscustomobject]@{
                Candidates = @(); Total = $Total; Roots = @('/s'); SandboxRoot = '/s'
                TestsByFile = @{}; AllTests = @('t.ps1'); TimeoutSeconds = 15
                RecordAllKillers = $false; Quiet = $true; DeadlineSeconds = 0
                Originals = @{}; Sink = $Sink
                RunClock = [System.Diagnostics.Stopwatch]::StartNew()
            }
        }
        function StubParked {
            param([string]$Id)
            return [pscustomobject]@{
                Row = [pscustomobject]@{ Id = $Id; File = 'a.ps1'; Line = 1; Description = 'x'; Status = 'Killed' }
                Seconds = 0.0
            }
        }
    }

    It 'records finished mutants in candidate order, not completion order' {
        # Workers finish out of order -- a killed mutant stops at the first failing test and a
        # survivor runs the whole suite, a 6x spread measured on this repo's sibling -- and a
        # report whose row order depended on that would differ between two runs of one config.
        $sink = [System.Collections.Generic.List[object]]::new()
        $sched = [pscustomobject]@{
            InFlight = [object[]]::new(3)
            Parked = @{ 2 = (StubParked -Id 'third'); 0 = (StubParked -Id 'first')
                1 = (StubParked -Id 'second') }
            Next = 3; Retired = 0
        }
        Complete-PSMutationRetirement -Schedule $sched -Context (StubContext -Sink $sink)
        @($sink | ForEach-Object { $_.Id }) | Should-BeCollection @('first', 'second', 'third')
        $sched.Retired | Should-Be 3
    }

    It 'holds a finished mutant back while an earlier one is still running' {
        # Which is what makes the partial report an interrupted run writes a genuine PREFIX of
        # the full one, rather than whichever mutants happened to land first.
        $sink = [System.Collections.Generic.List[object]]::new()
        $sched = [pscustomobject]@{
            InFlight = [object[]]::new(3); Parked = @{ 1 = (StubParked -Id 'second') }
            Next = 2; Retired = 0
        }
        Complete-PSMutationRetirement -Schedule $sched -Context (StubContext -Sink $sink)
        $sink.Count | Should-Be 0
        $sched.Retired | Should-Be 0
        # And it is still parked, not dropped: the run would otherwise report fewer mutants than
        # it evaluated, which is the one arithmetic error a mutation score must never make.
        $sched.Parked.ContainsKey(1) | Should-BeTrue
    }
}

Describe 'the scheduler sweep' {
    It 'passes over an idle worker and one whose mutant is still running' {
        # Two `continue`s, and neither is decoration: sweeping an idle slot would collect a $null
        # job, and collecting a running one would EndInvoke a pipeline that has not finished.
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; File = 'a.ps1'; Line = 1
            Operator = 'BinaryOperator'; Description = 'x' }
        $running = StubJob -Source $cand -Index 0 -Completed $false -WorkerId 1
        $sched = [pscustomobject]@{
            InFlight = [object[]]@($null, $running); Parked = @{}; Next = 1; Retired = 0
        }
        $ctx = [pscustomobject]@{ TimeoutSeconds = 3600; SandboxRoot = '/s' }
        Complete-PSMutationSweep -Schedule $sched -Context $ctx
        $sched.Parked.Count | Should-Be 0
        [object]::ReferenceEquals($sched.InFlight[1], $running) | Should-BeTrue
    }

    It 'PARKS a worker whose mutant has finished, and says it was not expired' {
        # The other arm, and the one the idle/running test cannot reach. Forcing the guard so that
        # every job looks Running leaves nothing ever swept -- which is not a wrong answer but an
        # infinite loop, so it has to be caught here rather than by a loop test discovering it as
        # a timeout.
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; Line = 1
            Operator = 'BinaryOperator'; Description = 'x'
            File = (Join-Path ([System.IO.Path]::GetTempPath()) 'a.ps1') }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $sched = [pscustomobject]@{
            InFlight = [object[]]@((StubJob -Source $cand -Index 4 -WorkerId 0)); Parked = @{}
            Next = 5; Retired = 0
        }
        Complete-PSMutationSweep -Schedule $sched -Context ([pscustomobject]@{ TimeoutSeconds = 3600
                SandboxRoot = [System.IO.Path]::GetTempPath() })
        # Parked under its CANDIDATE index, not the worker's, or the retirement order is scheduling.
        $sched.Parked.ContainsKey(4) | Should-BeTrue
        $sched.InFlight[0] | Should-BeNull
        # A finished job is collected for its verdict, never stopped. Reversed, every completed
        # mutant would be scored TimedOut -- which counts with the kills, so the run would look
        # fine and the report would say the suite never finished.
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { -not $Expired }
    }

    It 'EXPIRES a worker whose mutant outlived its budget' {
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; Line = 1
            Operator = 'BinaryOperator'; Description = 'x'
            File = (Join-Path ([System.IO.Path]::GetTempPath()) 'a.ps1') }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'TimedOut'; Killers = @() } }
        $sched = [pscustomobject]@{
            InFlight = [object[]]@((StubJob -Source $cand -Index 0 -WorkerId 0 -Seconds 99 -Completed $false))
            Parked = @{}; Next = 1; Retired = 0
        }
        Complete-PSMutationSweep -Schedule $sched -Context ([pscustomobject]@{ TimeoutSeconds = 5
                SandboxRoot = [System.IO.Path]::GetTempPath() })
        $sched.Parked.ContainsKey(0) | Should-BeTrue
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { $Expired }
    }
}


Describe 'Invoke-PSMutationLoop' {
    It 'accepts an empty candidate set and returns no results' {
        # Reachable two ways: a mutate file with no covered candidates, and a
        # -RecheckFrom run whose previous survivors are all dead. Both are ordinary
        # outcomes, so neither may throw.
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @() -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        @($r).Count | Should-Be 0
    }

    It 'uses the per-file test mapping when the candidate file has one' {
        # The paired case below covers the fallback. This is the mapping actually
        # being honoured -- get it wrong and every mutant runs the entire suite,
        # which is correct but turns a minutes-long run into an hours-long one.
        $script:seenTests = $null
        Mock Start-PSMutantEvaluation { $script:seenTests = $CoveringTests; StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }
        $map = @{ $script:fixture = @('specific.Tests.ps1') }

        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile $map -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        $script:seenTests | Should-BeCollection @('specific.Tests.ps1')
        $r[0].Status | Should-Be 'Killed'
    }

    It 'renders a progress line naming the mutant it just finished' {
        # Every other test here passes -Quiet, so this branch would otherwise never run.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        Mock Write-PSMutationOutput { }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }

        Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) | Out-Null

        # [[]1/1] escapes the bracket: in a wildcard a bare [1/1] is a character class.
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Lines.Text -like '*[[]1/1]*' }
        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { -not $Quiet }
    }

    It 'hands -Quiet to the renderer rather than skipping the call' {
        # The loop no longer decides whether to speak. It always renders and passes the
        # switch on, because Write-PSMutationOutput is the single place -Quiet is honoured
        # -- so what has to be proven here is that the switch is FORWARDED. A loop that
        # dropped it would print for real while any "was not called" assertion stayed green.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        Mock Write-PSMutationOutput { }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }

        Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet | Out-Null

        Should-Invoke Write-PSMutationOutput -Exactly 1 -ParameterFilter { $Quiet }
    }

    It 'falls back to the whole test set for a file with no per-file mapping' {
        # An unmapped file must still be evaluated against SOMETHING; running zero
        # tests would mark every one of its mutants Survived and quietly tank the
        # score for a config typo.
        # CLEARED first, and that is the assertion's whole validity. $script:seenTests is written
        # by the sibling test above, so without this the check below can pass on the PREVIOUS
        # test's value -- with the mock never firing at all, which is exactly the case it exists
        # to catch.
        $script:seenTests = $null
        Mock Start-PSMutantEvaluation { $script:seenTests = $CoveringTests; StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        $script:seenTests | Should-BeCollection @('all-tests.ps1')
        $r[0].Status     | Should-Be 'Killed'
    }
}

Describe 'Invoke-PSMutationBaseline' {
    # The baseline run is what decides (a) whether mutation may proceed at all and
    # (b) which lines are covered, i.e. which mutants are even worth evaluating. It
    # was only ever exercised end-to-end, so its result-shaping was unpinned. Pester
    # itself is mocked here: the point is what this function does with the result.
    It 'reports a passing suite and collapses covered lines per file' {
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Passed'
                CodeCoverage = [pscustomobject]@{
                    CommandsExecuted = @(
                        [pscustomobject]@{ File = $script:fixture; Line = 3 }
                        [pscustomobject]@{ File = $script:fixture; Line = 7 }
                        # Same line reported twice -- one command per statement means
                        # this is normal, and the line must not be counted twice.
                        [pscustomobject]@{ File = $script:fixture; Line = 3 }
                    )
                }
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.Passed | Should-BeTrue
        $key = [System.IO.Path]::GetFullPath($script:fixture)
        $r.CoveredLines[$key].Count     | Should-Be 2
        $r.CoveredLines[$key].Contains(3) | Should-BeTrue
        $r.CoveredLines[$key].Contains(7) | Should-BeTrue
        $r.DurationSeconds | Should-BeGreaterThanOrEqual 0
    }

    It 'asks Pester for the result object and for coverage' {
        # Both flags are invisible to a mocked test unless the configuration itself is
        # asserted, and both are load-bearing: without PassThru there is no result
        # object to read at all, and without CodeCoverage enabled every candidate looks
        # uncovered -- so coveredLinesOnly would quietly reduce the run to nothing and
        # report a perfect score over zero mutants.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) `
            -SandboxRoot $script:coverageDir -Coverage | Out-Null

        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter {
            $Configuration.Run.PassThru.Value -eq $true -and $Configuration.CodeCoverage.Enabled.Value -eq $true
        }
    }

    It 'leaves the tracer OFF unless asked, and still returns a usable baseline' {
        # The tracer is a +24% surcharge on this repo's own suite, and two run shapes never read
        # a covered line -- a config with coveredLinesOnly off, and any recheck. Off by default
        # so paying for it is a decision rather than the absence of one.
        Mock Invoke-Pester { [pscustomobject]@{ Result = 'Passed'; CodeCoverage = $null } }
        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir
        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter { $Configuration.CodeCoverage.Enabled.Value -eq $false }
        # An EMPTY map, which is the true answer -- nothing was measured. Reaching this line at
        # all is half the test: Pester reports no CommandsExecuted with the tracer off, and
        # `$null | ForEach-Object` runs its body ONCE with $_ = $null, so the collector used to
        # hand GetFullPath an empty string and the whole run died inside the baseline.
        $r.CoveredLines.Count | Should-Be 0
        $r.Passed | Should-BeTrue
    }

    It 'keys covered lines by FULL path, whatever Pester reported' {
        # Candidates carry absolute paths, so a relative key here would match nothing
        # and every mutant would look uncovered -- an empty run reported as success.
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            $leaf = Split-Path $script:fixture -Leaf
            Mock Invoke-Pester {
                [pscustomobject]@{
                    Result       = 'Passed'
                    CodeCoverage = [pscustomobject]@{ CommandsExecuted = @([pscustomobject]@{ File = $leaf; Line = 1 }) }
                }
            }
            $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir
            @($r.CoveredLines.Keys)[0] | Should-Be ([System.IO.Path]::GetFullPath($leaf))
        }
        finally { Pop-Location }
    }

    It 'reports a failing suite so the run can refuse to start' {
        # Mutating against a red suite is meaningless: every mutant "dies" for the
        # reason the suite was already failing.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Failed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.Passed | Should-BeFalse
        $r.CoveredLines.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationVerdict' {
    It 'reports Survived only when the suite still fully passes' {
        (Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Passed'; Killers = @() })).Status |
            Should-Be 'Survived'
    }

    It 'reports TimedOut apart from Killed, because a hang is not evidence' {
        # The bounded runner has always distinguished this; the verdict was discarded one
        # line later, so a suite that was merely too slow scored kills it never earned.
        (Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'TimedOut'; Killers = @() })).Status |
            Should-Be 'TimedOut'
    }

    It 'reports Killed for any outcome that is not a clean pass' {
        # Anything but Passed is a kill, which is why an outcome that means "we could
        # not tell" must never reach here -- see Receive-PSMutationJob.
        $v = Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Failed'; Killers = @('a test') })
        $v.Status | Should-Be 'Killed'
        $v.Killers | Should-BeCollection @('a test')
    }

    It 'carries an EMPTY killer list for a survivor and a timeout, never none' {
        # "Nothing killed it" and "we did not look" must not be the same value, and they differ
        # most at exactly these two verdicts.
        @((Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Passed'; Killers = @('x') })).Killers).Count | Should-Be 0
        @((Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'TimedOut'; Killers = @('x') })).Killers).Count | Should-Be 0
    }

    It 'refuses an outcome it does not model rather than scoring it' {
        # The collapse below is toward the FLATTERING answer: an unmodelled value would be
        # scored Killed, so a Pester that grew a third run-level state would report a perfect
        # score with no test failing and nothing to notice. A rename fails loudly at the
        # baseline; a widening does not, which is why the set is closed here.
        { Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Inconclusive'; Killers = @() }) } |
            Should-Throw -ExceptionMessage '*flatters the score*'
        # Asserted on the LAST fragment of the message, not the first. Breaking a `+` between
        # the fragments raises a conversion error that QUOTES its left operand, so a pattern
        # taken from an earlier fragment matches the mutant's own failure and the assertion
        # passes against a message that was never built.
    }
}

Describe 'one mutant, started and completed' {
    BeforeEach {
        $script:target = Join-Path $TestDrive 'mutable.ps1'
        $script:before = "function Get-Thing { return 1 }`n"
        [System.IO.File]::WriteAllText($script:target, $script:before)
        $script:candidate = [pscustomobject]@{ File = $script:target }
        $script:stub = [pscustomobject]@{
            WorkerId = 0; Shell = $null; Async = $null
            Candidate = $script:candidate; Source = $script:candidate; Index = 0
            OriginalContent = $script:before
            Clock = [pscustomobject]@{ Elapsed = [timespan]::Zero }
        }
    }

    It 'writes the mutant into the file, and puts it back when the job is collected' {
        # The restore is what lets the next mutant on this worker start from clean source. Miss
        # it and every later mutant is evaluated against an accumulating pile of earlier ones.
        # Split across the pair now, so both halves are asserted where they happen.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Passed"; Killers = @() }' }

        $job = Start-PSMutantEvaluation -Candidate $script:candidate -Source $script:candidate -Index 0 `
            -MutatedContent 'MUTATED' -OriginalContent $script:before -CoveringTests @('t.Tests.ps1') -WorkerId 0
        [System.IO.File]::ReadAllText($script:target) | Should-Be 'MUTATED'

        $null = $job.Async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds(30))
        (Complete-PSMutantEvaluation -Job $job).Status | Should-Be 'Survived'
        [System.IO.File]::ReadAllText($script:target) | Should-Be $script:before
    }

    It 'restores the file even when the covering run throws' {
        # A child that cannot be evaluated throws rather than scoring a kill, so the restore has
        # to survive that path too -- otherwise one broken mutant leaves the sandbox corrupted
        # for every mutant after it.
        [System.IO.File]::WriteAllText($script:target, 'MUTATED')
        Mock Receive-PSMutationJob { throw 'child exploded' }
        { Complete-PSMutantEvaluation -Job $script:stub } | Should-Throw
        [System.IO.File]::ReadAllText($script:target) | Should-Be $script:before
    }

    It 'collects an EXPIRED job by stopping it, not by asking it for a verdict' {
        # The scheduler decides which of the two happened, because only it knows what else is in
        # flight. Asking here would mean a second clock reading and a second answer to a question
        # already settled -- and a job that is still running has no verdict to end-invoke for.
        Mock Stop-PSMutationJob { [pscustomobject]@{ Result = 'TimedOut'; Killers = @() } }
        Mock Receive-PSMutationJob { throw 'must not be asked' }
        (Complete-PSMutantEvaluation -Job $script:stub -Expired).Status | Should-Be 'TimedOut'
        Should-Invoke Stop-PSMutationJob -Exactly 1
    }
}

Describe "a worker's child runspace" {
    # Get-PSMutationPesterPath is NOT mocked here. The runspace is warmed once per worker and
    # reused, and warming it means really importing Pester -- so a fake path would break the
    # import rather than being ignored the way it was when the child script carried it.
    BeforeAll {
        $script:childCand = [pscustomobject]@{ File = (Join-Path $TestDrive 'child.ps1') }
        Set-Content -LiteralPath $script:childCand.File -Value 'x'

        # Defined in BeforeAll, not beside it. A bare `function` inside a Describe is declared
        # during DISCOVERY and is gone by the time a test runs, so every test here failed with
        # "not recognized" while the file read perfectly well.
        function Invoke-ChildForTest {
            param([int]$TimeoutSeconds = 10)
            $job = Start-PSMutantEvaluation -Candidate $script:childCand -Source $script:childCand -Index 0 `
                -MutatedContent 'x' -OriginalContent 'x' -CoveringTests @('t.Tests.ps1') -WorkerId 0
            $done = $job.Async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))
            return $done ? (Receive-PSMutationJob -Job $job) : (Stop-PSMutationJob -Job $job)
        }
    }

    It 'hands back the verdict the child produced' {
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Passed"; Killers = @() }' }
        (Invoke-ChildForTest).Result | Should-Be 'Passed'
    }

    It 'fails loudly when the child returns no verdict, and says what the child said' {
        # A child that returned nothing proved nothing, but the verdict reader takes
        # anything-but-Passed as a kill -- so silence used to score as a caught fault.
        # That is how the Pester version collision produced a fake 100%.
        #
        # Both halves of the message are asserted deliberately. Matching only the
        # literal prefix is not discriminating: if the concatenation breaks, the
        # resulting conversion error QUOTES the prefix, so a prefix-only pattern still
        # matches and the diagnosis is silently lost.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) Write-Error "child said no"' }
        { Invoke-ChildForTest } | Should-Throw -ExceptionMessage '*produced no result*child said no*'
    }

    It 'takes the LAST thing the child emitted as the verdict' {
        # A covering test file can write its own output before Pester's result -- a
        # stray Write-Output, a warning surfacing as an object. Only the final value is
        # the verdict; carrying any of the noise with it stops the string ever matching
        # 'Passed', which silently turns every survivor into a kill.
        # TWO records, not noise-then-record. Since the child began returning an object, taking
        # more than the last one no longer concatenates into an unusable string -- PowerShell
        # enumerates .Result across the collection and the first value can still look like a
        # verdict. Two records with DIFFERENT verdicts is what distinguishes "last" from "any":
        # take both and the outcome is 'Failed Passed', which no known outcome matches.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Failed"; Killers = @() }; [pscustomobject]@{ Result = "Passed"; Killers = @() }' }
        (Invoke-ChildForTest).Result | Should-Be 'Passed'
    }

    It 'cuts off a child that overruns and reports TimedOut' {
        # The real non-terminating case is proven in tests/Mutant.Tests.ps1. Here the
        # child merely sleeps, so the deadline is reached in seconds rather than by
        # spinning a mutated loop -- same branch, a fraction of the wall clock.
        #
        # ONE second, not two, and the second matters more than it looks. This file is the
        # covering suite for src/PSMutation.Runner.ps1, so every one of that file's mutants
        # re-runs this test and waits out the deadline.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) Start-Sleep -Seconds 30' }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = (Invoke-ChildForTest -TimeoutSeconds 1).Result
        $sw.Stop()

        $outcome | Should-Be 'TimedOut'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20   # cut off, not waited out
    }

    It 'discards the worker whose child it had to stop' {
        # Stop() leaves a runspace unusable, so handing it to the next mutant would fail every
        # one of them -- and anything-but-Passed is a kill, so the run would report a perfect
        # score after the first timeout.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) Start-Sleep -Seconds 30' }
        $null = Invoke-ChildForTest -TimeoutSeconds 1
        $script:PSMutationWarmShell.ContainsKey(0) | Should-BeFalse
    }
}

Describe 'the baseline coverage XML' {
    It 'points Pester at the sandbox, not at shared temp' {
        # It used to be "psmut-coverage-$PID.xml" in temp, and nothing ever deleted it: the startup
        # sweep matched DIRECTORIES named psmut-sandbox-*, so it could not match this file by
        # construction, and they accumulated for the life of the machine -- 67 of them on the box
        # this was found on. Inside the sandbox it is removed by the cleanup that already exists.
        #
        # Invoke-Pester is MOCKED, as everywhere else in this Describe. The first draft of this
        # test let the real one run, and -TestPath @('tests') is the whole suite -- which contains
        # EndToEnd.Tests.ps1, which starts real mutation runs of its own. The suite went from 33
        # seconds to not finishing.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir | Out-Null

        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter {
            $Configuration.CodeCoverage.OutputPath.Value -eq (Join-Path $script:coverageDir 'coverage.xml')
        }
    }

    It 'no longer names the file after the process, anywhere' {
        # The other half. Asserting only where it DOES point would pass just as well if the path
        # were built from both -- and the whole complaint is the temp-shaped name.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }

        Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir | Out-Null

        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter {
            $Configuration.CodeCoverage.OutputPath.Value -notlike '*psmut-coverage-*'
        }
    }
}

Describe 'Invoke-PSMutationBaseline, on a red suite' {
    It 'carries the first line of each failure, without a stray carriage return' {
        # Two claims on one fixture, because the line does two things. A Pester message is an
        # expectation, then the actual, then a stack -- index 1 would report "at <ScriptBlock>"
        # as the reason, which is a fact about nothing.
        #
        # And the fixture uses CRLF on purpose: splitting on "`n" alone leaves the carriage
        # return on the end of the first line, which then travels into the exception the gate
        # throws and prints as a stray break in the middle of its one line of output.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{
                        ExpandedPath = 'Recheck.annotates under a CI'
                        ErrorRecord  = [pscustomobject]@{
                            Exception = [pscustomobject]@{
                                Message = "Expected 1 call, but was 0.`r`nat <ScriptBlock>, Recheck.Tests.ps1:389"
                            }
                        }
                    }
                )
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.Passed | Should-BeFalse
        @($r.FailedTest).Count | Should-Be 1
        $r.FailedTest[0] | Should-Be 'Recheck.annotates under a CI -- Expected 1 call, but was 0.'
    }

    It 'skips a LEADING BLANK line rather than reporting an empty reason' {
        # A Pester message can begin with a blank line -- it does on the CI runners and did not on
        # the machine the original was written on, so the first form of this took index 0 and the
        # gate printed "Failed: Some.Test -- ." on CI only.
        #
        # That empty reason is the bare test name this field exists to improve on: a -Quiet gate
        # prints one line, and a name with no reason sends the reader to reproduce a failure that
        # is not happening on their machine. Found by an end-to-end test going red on both legs.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{
                        ExpandedPath = 'Get-Sign.is pos'
                        ErrorRecord  = [pscustomobject]@{
                            Exception = [pscustomobject]@{
                                Message = "`r`n   `r`nThe term 'Get-Sign' is not recognized.`r`nat <ScriptBlock>, calc.Tests.ps1:2"
                            }
                        }
                    }
                )
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.FailedTest[0] | Should-Be "Get-Sign.is pos -- The term 'Get-Sign' is not recognized."
    }

    It 'reports a message that is ONE line, blank-padded, as just that line' {
        # The commonest real shape, and the one no other fixture here has: exactly one non-empty
        # line. The two-line fixtures above cannot distinguish `-gt 0` from `-gt 1` -- both take
        # index 0 when there are two -- so the boundary was unpinned and the mutation gate found
        # it. With one line and `-gt 1`, the guard falls through to the whole raw message, blank
        # padding and all.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{
                        ExpandedPath = 'Solo.Test'
                        ErrorRecord  = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = "`r`nonly this line`r`n" } }
                    }
                )
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.FailedTest[0] | Should-Be 'Solo.Test -- only this line'
    }

    It 'names the test ALONE when there is no reason to give' {
        # A dangling "Some.Test -- " reads as a reason that was lost; the bare name reads as one
        # that never existed, which is the truth. This happens for real: when a BeforeAll dies
        # under ErrorActionPreference = Stop -- which is how CI runs the suite and how a developer
        # machine usually does not -- Pester marks every test in the block Failed and attaches the
        # error to the CONTAINER, so the test carries no error record at all.
        #
        # The container's record is deliberately not reached for: it holds Pester's own
        # break/continue guard text, which says nothing about the consumer's failure.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{
                        ExpandedPath = 'Some.Test'
                        ErrorRecord  = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = "`r`n  `r`n" } }
                    }
                )
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.FailedTest[0] | Should-Be 'Some.Test'
    }

    It 'names the test alone when Pester attaches no error record at all' {
        # The shape that actually occurs, rather than the degenerate all-blank message above: an
        # EMPTY ErrorRecord collection. ErrorRecord is a List, and reading .Exception.Message off
        # the list works only by member enumeration -- which yields the inner value for one element
        # and nothing for zero or many. That is why this is read as a collection.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{ ExpandedPath = 'Blocked.Test'; ErrorRecord = @() }
                )
            }
        }

        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir

        $r.FailedTest[0] | Should-Be 'Blocked.Test'
    }
}

Describe 'Assert-PSMutationBaselineGreen' {
    It 'refuses to mutate against a red suite' {
        # The most misleading result this tool could produce: against a failing
        # suite every mutant "dies" for the reason the suite was already red, and
        # the run reports a perfect score.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $false }) } |
            Should-Throw -ExceptionMessage '*Baseline suite is not green*'
    }
    It 'lets a green baseline through' {
        # A guard that lets the run continue emits nothing at all. Calling it directly
        # covers the refusal case too: an exception here fails the test on its own,
        # which is why v6 offers no "does not throw" assertion to wrap it in.
        Should-BeNull -Actual (Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $true }))
    }

    It 'names the tests that failed' {
        # The gate that reports a red baseline runs -Quiet, so the whole run prints one line.
        # "Not green" without a name sends the reader to reproduce a failure that, by
        # definition, is not happening on the machine they are standing on -- which is exactly
        # what it cost when this message had no detail.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @('Output.annotates a survivor', 'Recheck.still surviving')
                }) } | Should-Throw -ExceptionMessage '*Failed: Output.annotates a survivor; Recheck.still surviving.*'
    }

    It 'caps the list and says how many it left out' {
        # A wholly broken suite would otherwise paste hundreds of names into one exception and
        # bury the first, which is the one most likely to explain the rest.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @(1..14 | ForEach-Object { "T$_" })
                }) } | Should-Throw -ExceptionMessage '*T10 (and 4 more).*'
    }

    It 'names a single failure rather than losing it' {
        # Exactly ONE. The guard reads `-gt 0`, and as `-gt 1` a lone failure loses its name
        # while the run still fails -- putting the reader back to reproducing something they
        # cannot see, which is the whole cost this message exists to remove. Two names or more
        # pass under either reading, so only a fixture of one discriminates.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @('Only.one -- Expected 1, got 0')
                }) } | Should-Throw -ExceptionMessage '*Failed: Only.one -- Expected 1, got 0.*'
    }

    It 'says nothing about names it does not have' {
        # The refusal is the point and the names are a courtesy -- but a courtesy that fires on
        # an empty list reads " Failed: ." which is worse than silence. Asserted as an ABSENCE,
        # because a message that merely still contains the refusal passes either way.
        $message = $null
        try {
            Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $false; FailedTest = @() })
        }
        catch { $message = $_.Exception.Message }
        $message | Should-BeLikeString '*fix the tests before mutating*'
        $message | Should-NotBeLikeString '*Failed:*'
    }

    It 'claims no remainder when it showed every name' {
        # Exactly ten, the cap itself. Read as at-or-over, the message ends "(and 0 more)" --
        # a remainder that does not exist, on the one input where the two readings differ.
        $message = $null
        try {
            Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @(1..10 | ForEach-Object { "T$_" })
                })
        }
        catch { $message = $_.Exception.Message }
        $message | Should-BeLikeString '*T10.*'
        $message | Should-NotBeLikeString '*more)*'
    }
}

Describe 'ids are assigned before the coverage filter, not after' {
    It 'keeps a candidate id the same whether or not covered-lines filtering ran' {
        # The invariant #59 named: numbering happens in Get-PSMutationCandidate over the
        # UNFILTERED set, and Select-PSMutationCandidate filters afterwards. It is what lets
        # a recheck match survivors by id across a coverage change -- and coverage changing
        # is precisely what happens when you write the assertions that kill survivors, so
        # the compatibility gate can stay narrow and not inspect coverage at all.
        #
        # This test fails the moment someone "optimises" by filtering first, or by moving
        # the numbering into Select-PSMutationCandidate. That refactor looks obviously
        # correct and silently makes a recheck answer about the wrong mutants.
        # Assigned directly, NOT wrapped in @(). Select-PSMutationCandidate comma-wraps its
        # return to preserve a single-element array, so @(...) hands back one item that IS
        # the array and every count below reads 1 (see the convention note in #38).
        $all = (Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false).Candidates
        $all.Count | Should-BeGreaterThan 1

        # Admit only the lines of the LAST candidate, so any renumbering shows up as id 1.
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $last = $all[-1]
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@($last.Line) }
        $filtered = (Select-PSMutationCandidate -MutateFiles @($script:fixture) `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered).Candidates

        $filtered.Count | Should-BeLessThan $all.Count
        # The surviving candidate keeps the id it had in the full set. Renumbering after
        # filtering would make this 1.
        $filtered[-1].Id | Should-Be $last.Id
    }
}

Describe 'the mutant row the report publishes' {
    It 'carries exactly the fields the report contract names' {
        # Built here, not by Write-PSMutationReport, which serialises whatever it is handed
        # -- so this is the only place the shape is really decided.
        #
        # It is a PROJECTION of the internal candidate: StartOffset, EndOffset, Original and
        # Mutated are deliberately absent. Widening it to project the whole candidate would
        # re-publish the undeclared nine-field object #48 just withdrew, through the report
        # instead of through an export.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cand = [pscustomobject]@{
            Id = 7; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = '-eq -> -ne'; StartOffset = 0; EndOffset = 1; Mutated = ' '
            Original = '-eq'
        }
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        # Function joined this list in #3, deliberately: an equivalence declaration keyed on
        # a line number goes stale whenever anything above the mutant is edited, so the row
        # carries the function it lives in. Widening the contract is what this assertion is
        # for -- it failed when the field was added, which is the pin working.
        @($r)[0].PSObject.Properties.Name |
            Should-BeCollection @('Id', 'Function', 'File', 'Line', 'Operator', 'Description', 'Status', 'KilledBy')
    }
}

Describe 'the mutate file is read once per FILE, not twice per mutant' {
    # It used to be read twice for every mutant: once in the loop to splice against, and again
    # inside Invoke-PSMutant to restore from -- the same unchanged bytes off disk twice, producing
    # two strings equal by construction. A file contributes MANY candidates (125 for the largest in
    # this repo's sibling), so that was per mutant, not per file.
    #
    # Asserted as a CONTRACT rather than by counting reads: [System.IO.File] is a .NET type and
    # cannot be mocked, and a wall-clock assertion could not tell 0.16 ms from noise on Linux --
    # issue #101 reports a far larger cost on Windows. What makes one read enough is that every
    # mutant is HANDED the original text instead of fetching it, and that is observable.
    It 'hands every mutant of a file the same original text, read by the loop' {
        $script:seenOriginals = @()
        Mock Start-PSMutantEvaluation { $script:seenOriginals += $OriginalContent; StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cands = 1..5 | ForEach-Object {
            [pscustomobject]@{
                Id = $_; Function = ''; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
                Description = "m$_"; StartOffset = 0; EndOffset = 1; Mutated = ' '
            }
        }
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) -TestsByFile @{} -AllTests @('t.Tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        @($r).Count | Should-Be 5
        # Five mutants, five identical originals -- and each is the file's real text, so the loop
        # read it rather than passing something it happened to have.
        @($script:seenOriginals).Count | Should-Be 5
        $expected = [System.IO.File]::ReadAllText($script:fixture)
        @($script:seenOriginals | Sort-Object -Unique) | Should-BeCollection @($expected)
    }

    It 'splices every mutant against the ORIGINAL text even if the file changes mid-run' {
        # The half that makes the cache a CORRECTNESS property rather than a speed one, and the
        # only thing that tells a cached read from a repeated one -- re-reading returns the same
        # bytes and is invisible, which is exactly what the mutation gate reported.
        #
        # The scenario is a restore that did not happen: Invoke-PSMutant writes the mutant, runs,
        # and restores in a finally, but a process killed between the write and the restore leaves
        # the sandbox mutated. A loop that re-read the file would then splice the NEXT mutant onto
        # the previous one -- mutants stacking, and a score describing code that never existed.
        $original = [System.IO.File]::ReadAllText($script:fixture)
        $script:seenOriginals = @()
        $script:calls = 0
        Mock Start-PSMutantEvaluation {
            $script:calls++
            $script:seenOriginals += $OriginalContent
            # Corrupt the file behind the loop's back, once, after the first mutant.
            if ($script:calls -eq 1) { [System.IO.File]::WriteAllText($script:fixture, 'CORRUPTED') }
            StubJob -Source $Source -Index $Index -WorkerId $WorkerId
        }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cands = 1..2 | ForEach-Object {
            [pscustomobject]@{
                Id = $_; Function = ''; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
                Description = "m$_"; StartOffset = 0; EndOffset = 1; Mutated = ' '
            }
        }
        try {
            $null = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) -TestsByFile @{} -AllTests @('t.Tests.ps1') `
                -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
            # The second mutant must have been handed the original, not what was on disk by then.
            @($script:seenOriginals).Count | Should-Be 2
            $script:seenOriginals[1] | Should-Be $original
            $script:seenOriginals[1] | Should-NotBe 'CORRUPTED'
        }
        finally { [System.IO.File]::WriteAllText($script:fixture, $original) }
    }
}

Describe 'Get-PSMutationStalledFault' {
    It 'says nothing for a mutant that merely ran, or merely timed out' -ForEach @(
        @{ Seconds = 2; Why = 'an ordinary mutant' }
        @{ Seconds = 16; Why = 'one that hit its own timeout' }
        @{ Seconds = 50; Why = 'a slow one on a loaded machine' }
    ) {
        # The bound must not fire on a working run, or it is switched off within a week. A
        # timed-out mutant already costs its full budget plus discarding and rebuilding the
        # runspace, so the limit sits well clear of it.
        Should-BeNull -Actual (Get-PSMutationStalledFault -MutantSeconds $Seconds -TimeoutSeconds 15 -Index 3 -Total 9)
    }

    It 'reports a mutant whose wall clock says the bound did not fire' {
        # What an overnight hang looks like from inside: the child is given a budget and its
        # handle is waited on for exactly that, so a mutant far past it did not run slowly -- the
        # mechanism that should have stopped it never fired. The observed case was 875 minutes of
        # wall clock against 333 seconds of CPU.
        $f = Get-PSMutationStalledFault -MutantSeconds 52500 -TimeoutSeconds 15 -Index 3 -Total 9
        $f | Should-MatchString 'took 52500s against a per-mutant budget of 15s'
        # It must name the CAUSE, not just the number, or the reader is sent to tune a timeout.
        $f | Should-MatchString 'suspended or wedged'
    }

    It 'scales its limit with the budget rather than fixing a number' {
        # A repo with a slow suite has a large per-mutant budget, and a fixed limit would either
        # fire on its ordinary mutants or never fire on a fast repo's hang.
        Should-BeNull -Actual (Get-PSMutationStalledFault -MutantSeconds 300 -TimeoutSeconds 120 -Index 1 -Total 2)
        Should-NotBeNull -Actual (Get-PSMutationStalledFault -MutantSeconds 300 -TimeoutSeconds 5 -Index 1 -Total 2)
    }
}

Describe 'the loop is bounded as a whole' {
    BeforeAll {
        $script:dCand = [pscustomobject]@{ Id = 1; File = (Join-Path $TestDrive 'd.ps1'); Line = 1
            Operator = 'BinaryOperator'; Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '; Function = 'F' }
        Set-Content -LiteralPath $script:dCand.File -Value 'x'
    }

    It 'stops when the run passes its wall-clock budget, naming how far it got' {
        # Checked BETWEEN mutants, so it can never interrupt one mid-flight and leave a spliced
        # file behind. A deadline of 0 elapsed seconds fires on the first check.
        # 600ms a mutant against a 1s budget: the check after the first passes, the one after the
        # second does not. Three candidates so the throw is demonstrably mid-loop rather than
        # something that only happens once there is nothing left to do.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { Start-Sleep -Milliseconds 600; [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        { Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) `
                -Candidates @($script:dCand, $script:dCand, $script:dCand) -TestsByFile @{} -AllTests @('t.ps1') `
                -TimeoutSeconds 5 -SandboxRoot $TestDrive -Quiet -DeadlineSeconds 1 } |
            Should-Throw -ExceptionMessage '*passed its wall-clock budget*'
    }

    It 'leaves the rows it finished in the caller''s sink, so a stopped run still has evidence' {
        # The whole point of stopping BETWEEN mutants rather than at the end. The orchestrator's
        # finally writes a partial report from this list, so a hang now says how far it got
        # instead of leaving the zero-byte report the observed case did.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { Start-Sleep -Milliseconds 600; [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $sink = [System.Collections.Generic.List[object]]::new()
        try {
            Invoke-PSMutationLoop -Sink $sink -Candidates @($script:dCand, $script:dCand, $script:dCand) `
                -TestsByFile @{} -AllTests @('t.ps1') -TimeoutSeconds 5 -SandboxRoot $TestDrive `
                -Quiet -DeadlineSeconds 1
        }
        catch {
            # Swallowed on purpose: the throw is asserted by the test above, and what THIS test
            # is about is what the sink holds afterwards. Re-throwing here would fail the test
            # for the behaviour it is checking.
            Write-Verbose "expected: $($_.Exception.Message)"
        }
        $sink.Count | Should-BeGreaterThan 0
    }

    It 'stops on a stalled mutant, and keeps what it finished' {
        # The detector is tested directly above; what this covers is the loop ACTING on it. It
        # is mocked rather than provoked because the real limit has a 30-second floor -- there so
        # an ordinary overrun cannot trip it -- and waiting that out would buy nothing this
        # assertion does not already say.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        Mock Get-PSMutationStalledFault { 'the handle never came back' }
        $sink = [System.Collections.Generic.List[object]]::new()
        { Invoke-PSMutationLoop -Sink $sink -Candidates @($script:dCand, $script:dCand) `
                -TestsByFile @{} -AllTests @('t.ps1') -TimeoutSeconds 5 -SandboxRoot $TestDrive `
                -Quiet -DeadlineSeconds 0 } | Should-Throw -ExceptionMessage '*handle never came back*'
        # Checked AFTER the first mutant, so the row it finished is already recorded -- which is
        # what lets the partial report say how far a hung run got.
        $sink.Count | Should-Be 1
    }

    It 'runs to completion when the budget is zero' {
        # Zero disables the bound, for a harness that already kills wedged jobs. Without this arm
        # a caller who does not want the bound would have to invent a number they do not care about.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) `
            -Candidates @($script:dCand, $script:dCand) -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot $TestDrive -Quiet -DeadlineSeconds 0
        $r.Count | Should-Be 2
    }
}

Describe 'the run bounds at their boundaries' {
    It 'treats a mutant exactly AT the stall limit as fine, and one second past it as stalled' -ForEach @(
        @{ Budget = 15; At = 60; Past = 61; Which = 'the four-times-budget arm' }
        @{ Budget = 5; At = 35; Past = 36; Which = 'the plus-thirty floor' }
    ) {
        # Two rows because the limit is a max() of two arms and only one wins at a time. With a
        # 15s budget the multiple wins (60 > 45); with a 5s budget the floor does (35 > 20). A
        # fixture on one arm cannot see the other change at all -- measured: every mutant of the
        # multiplier, the addend and the comparison survived tests that used only round numbers
        # far from either boundary.
        Should-BeNull -Actual (Get-PSMutationStalledFault -MutantSeconds $At -TimeoutSeconds $Budget -Index 1 -Total 2) `
            -Because "exactly at the limit is not yet stalled, on $Which"
        Should-NotBeNull -Actual (Get-PSMutationStalledFault -MutantSeconds $Past -TimeoutSeconds $Budget -Index 1 -Total 2) `
            -Because "one second past it is, on $Which"
    }

    It 'treats elapsed exactly AT the run budget as fine, and past it as over' {
        # The reason this decision was extracted from the loop: elapsed wall-clock never lands
        # exactly on the budget, so inline nothing could tell -gt from -ge.
        Should-BeNull -Actual (Get-PSMutationOverBudgetFault -ElapsedSeconds 100 -DeadlineSeconds 100 -Index 1 -Total 2)
        Should-NotBeNull -Actual (Get-PSMutationOverBudgetFault -ElapsedSeconds 100.5 -DeadlineSeconds 100 -Index 1 -Total 2)
    }

    It 'never fires when the budget is zero or negative' {
        # Zero is "disabled". Without this arm a disabled budget would read as a budget of zero
        # seconds, which every run exceeds immediately.
        foreach ($d in 0, -1) {
            Should-BeNull -Actual (Get-PSMutationOverBudgetFault -ElapsedSeconds 9999 -DeadlineSeconds $d -Index 1 -Total 2)
        }
    }

    It 'says what to do about it, in the part of the message built last' {
        # Asserted against the LAST operand of the concatenation, not the first. PowerShell fails
        # a string subtraction by converting to Int32 and quotes the whole left operand back, so a
        # wildcard matching early text still passes for a message that was never built -- the trap
        # this repo has already paid for once.
        $f = Get-PSMutationOverBudgetFault -ElapsedSeconds 200 -DeadlineSeconds 100 -Index 7 -Total 9
        $f | Should-MatchString 'set it to 0 if something else already kills wedged runs'
        $f | Should-MatchString 'after 7 of 9'
    }
}

Describe 'Get-PSMutationCoveringSuite' {
    It 'uses the file''s OWN mapping when it has one' {
        # Getting this wrong runs every mutant against the whole suite -- correct, but it turns a
        # minutes-long run into an hours-long one.
        Get-PSMutationCoveringSuite -File 'src/a.ps1' `
            -TestsByFile @{ 'src/a.ps1' = @('tests/a.Tests.ps1') } -AllTests @('tests/all.Tests.ps1') |
            Should-BeCollection @('tests/a.Tests.ps1')
    }

    It 'falls back to the whole suite when it has none' {
        # The other arm, and the safe direction: a file with no mapping must be covered by
        # everything rather than by nothing, or its mutants die for want of a test that ran.
        Get-PSMutationCoveringSuite -File 'src/b.ps1' `
            -TestsByFile @{ 'src/a.ps1' = @('tests/a.Tests.ps1') } -AllTests @('tests/all.Tests.ps1') |
            Should-BeCollection @('tests/all.Tests.ps1')
    }
}

Describe 'Get-PSMutationCandidateByOperator' {
    BeforeAll {
        $script:prod = @(
            [pscustomobject]@{ Operator = 'BinaryOperator'; Line = 1 }
            [pscustomobject]@{ Operator = 'BinaryOperator'; Line = 2 }
            [pscustomobject]@{ Operator = 'BinaryOperator'; Line = 3 }
            [pscustomobject]@{ Operator = 'BooleanLiteral'; Line = 4 }
        )
    }

    It 'counts what each operator produced' {
        $by = Get-PSMutationCandidateByOperator -Produced $script:prod -Kept $script:prod
        $by['BinaryOperator'].Produced | Should-Be 3
        $by['BooleanLiteral'].Produced | Should-Be 1
    }

    It 'counts produced and kept SEPARATELY' {
        # The pair is the whole point. One number cannot tell "no operator matched this file" --
        # which no test can fix -- from "the mapped suite reaches none of its lines", which is
        # a test to write. Kept must not be read off Produced.
        $by = Get-PSMutationCandidateByOperator -Produced $script:prod -Kept @($script:prod[0])
        $by['BinaryOperator'].Produced | Should-Be 3
        $by['BinaryOperator'].Kept | Should-Be 1
        $by['BooleanLiteral'].Produced | Should-Be 1
        $by['BooleanLiteral'].Kept | Should-Be 0
    }

    It 'lists only the operators that matched, in first-seen order' {
        # Ordered, so the preview reads the same way twice for the same file. An operator that
        # produced nothing is absent rather than a zero row: a page of zeros buries the counts
        # that matter.
        $by = Get-PSMutationCandidateByOperator -Produced $script:prod -Kept @()
        @($by.Keys) | Should-BeCollection @('BinaryOperator', 'BooleanLiteral')
    }

    It 'returns an empty map for a file that produced nothing' {
        (Get-PSMutationCandidateByOperator -Produced @() -Kept @()).Count | Should-Be 0
    }
}

Describe 'Select-PSMutationCandidate per-operator tally' {
    It 'carries the breakdown on every per-file row' {
        # Through the real selection, not the helper alone: the tally is only useful if the
        # thing that builds the rows actually attaches it.
        $sel = Select-PSMutationCandidate -MutateFiles @($script:fixture) -Operators @('BinaryOperator') `
            -CoveredLinesOnly $false
        $sel.PerFile[0].ByOperator['BinaryOperator'].Produced | Should-Be $sel.PerFile[0].Produced
        $sel.PerFile[0].ByOperator['BinaryOperator'].Kept | Should-Be $sel.PerFile[0].Kept
    }
}

Describe 'ConvertTo-PSMutationDisplayPerFile' {
    It 'replaces the sandbox path with the repo-relative one' {
        # The rows come out of the sandbox, so File is an absolute path under a temp directory
        # whose name changes every run and which is deleted before a reader sees it. That value
        # reached the report and the summary caveat.
        $sb = Join-Path ([System.IO.Path]::GetTempPath()) 'psmut-display-fixture'
        $rows = @([pscustomobject]@{ File = (Join-Path $sb 'src/a.ps1'); Produced = 4; Kept = 2; ByOperator = [ordered]@{} })
        $out = ConvertTo-PSMutationDisplayPerFile -PerFile $rows -SandboxRoot $sb
        # The exact string, not "does not contain the sandbox": a separator assertion is a
        # platform assumption, and an absence certifies whatever the code happens to do.
        $out[0].File | Should-Be 'src/a.ps1'
    }

    It 'carries the counts and the breakdown through unchanged' {
        $sb = Join-Path ([System.IO.Path]::GetTempPath()) 'psmut-display-fixture'
        $rows = @([pscustomobject]@{ File = (Join-Path $sb 'src/a.ps1'); Produced = 4; Kept = 2
                ByOperator = [ordered]@{ BinaryOperator = @{ Produced = 4; Kept = 2 } }
            })
        $out = ConvertTo-PSMutationDisplayPerFile -PerFile $rows -SandboxRoot $sb
        $out[0].Produced | Should-Be 4
        $out[0].Kept | Should-Be 2
        $out[0].ByOperator['BinaryOperator'].Kept | Should-Be 2
    }

    It 'returns an empty ARRAY for an empty selection, not $null' {
        # `, @()` and an assignment at the call site. Wrapped or piped, an empty result becomes
        # $null and every count downstream reads 1 or throws.
        $out = ConvertTo-PSMutationDisplayPerFile -PerFile @() -SandboxRoot '/tmp/whatever'
        $out.Count | Should-Be 0
    }
}

Describe 'Get-PSMutationRunBaseline' {
    BeforeAll {
        $script:plan = @{ AllTests = @('t.Tests.ps1'); Mutate = @('a.ps1') }
    }

    It 'reports no time taken and no coverage when it did not measure' {
        # Asserted DIRECTLY, which is the reason this is a function at all. The zeros reach the
        # timeout through Get-PSMutationTimeout, where the floor swallows any small value -- so
        # a mutant turning 0.0 into 1.0 produces the identical budget and would survive every
        # test that only looks at the run.
        $b = Get-PSMutationRunBaseline -Plan $script:plan -SandboxRoot $script:coverageDir
        $b.DurationSeconds | Should-Be 0
        $b.CoveredLines.Count | Should-Be 0
    }

    It 'carries no Passed flag when it did not measure' {
        # The one thing a skipped baseline did not establish. Fabricating a green verdict here
        # is the "a number nobody measured, reported as one" failure this module exists to catch.
        $b = Get-PSMutationRunBaseline -Plan $script:plan -SandboxRoot $script:coverageDir
        # The exact field list, not an absence: an absence certifies whatever the code happens
        # to return, and would still pass if the function stopped returning anything at all.
        @($b.PSObject.Properties.Name) | Should-BeCollection @('DurationSeconds', 'CoveredLines')
    }

    It 'measures, and refuses a red suite, when asked to' {
        Mock Invoke-PSMutationBaseline { @{ Passed = $false; DurationSeconds = 3.0; CoveredLines = @{} } }
        { Get-PSMutationRunBaseline -Plan $script:plan -SandboxRoot $script:coverageDir -Measure -Quiet } |
            Should-Throw
        Should-Invoke Invoke-PSMutationBaseline -Exactly 1
    }

    It 'returns the measured baseline when the suite is green' {
        Mock Invoke-PSMutationBaseline { @{ Passed = $true; DurationSeconds = 7.5; CoveredLines = @{ 'a.ps1' = @(1) } } }
        $b = Get-PSMutationRunBaseline -Plan $script:plan -SandboxRoot $script:coverageDir -Measure -Quiet
        $b.DurationSeconds | Should-Be 7.5
        $b.CoveredLines.Count | Should-Be 1
    }
}


Describe 'the worker pool the loop is given' {
    It 'spreads mutants across every worker, each in its OWN sandbox' {
        # The isolation the whole feature rests on. Two workers writing the same file would
        # splice one mutant over another and score both against source neither chose -- and the
        # TESTS are re-rooted too, which is the half that is easy to forget: a worker running the
        # primary sandbox's test files would dot-source unmutated source and every mutant would
        # survive.
        $root = [System.IO.Path]::GetTempPath()
        $script:seenWorkers = @()
        $script:seenFiles = @()
        $script:seenSuites = @()
        Mock Start-PSMutantEvaluation {
            $script:seenWorkers += $WorkerId
            $script:seenFiles += $Candidate.File
            $script:seenSuites += $CoveringTests[0]
            StubJob -Source $Source -Index $Index -WorkerId $WorkerId
        }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cands = 1..3 | ForEach-Object {
            [pscustomobject]@{
                Id = $_; Function = 'F'; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
                Description = "m$_"; StartOffset = 0; EndOffset = 1; Mutated = ' '
            }
        }
        $w1 = Join-Path $root 'psmut-w1'
        $w2 = Join-Path $root 'psmut-w2'

        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) `
            -TestsByFile @{} -AllTests @((Join-Path $root 'all.Tests.ps1')) -TimeoutSeconds 5 `
            -SandboxRoot $root -WorkerSandbox @($w1, $w2) -Quiet

        @($r).Count | Should-Be 3
        @($script:seenWorkers | Sort-Object) | Should-BeCollection @(0, 1, 2)
        # Worker 0 mutates the PRIMARY sandbox -- that identity is what keeps a serial run
        # byte-identical to what it was before workers existed -- and the other two do not.
        $script:seenFiles[0] | Should-Be $script:fixture
        $script:seenFiles[1] | Should-Be (Join-Path $w1 (Split-Path $script:fixture -Leaf))
        $script:seenSuites[2] | Should-Be (Join-Path $w2 'all.Tests.ps1')
    }

    It 'still reports every row against the PRIMARY sandbox, whichever worker ran it' {
        # Which worker ran a mutant is scheduling, and scheduling must not be visible in the
        # answer: a row naming a per-worker temp directory would differ between two runs of the
        # same config, and a consumer diffing reports would see churn that means nothing.
        $root = [System.IO.Path]::GetTempPath()
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cands = 1..2 | ForEach-Object {
            [pscustomobject]@{
                Id = $_; Function = 'F'; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
                Description = "m$_"; StartOffset = 0; EndOffset = 1; Mutated = ' '
            }
        }
        $r = Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) `
            -TestsByFile @{} -AllTests @((Join-Path $root 'all.Tests.ps1')) -TimeoutSeconds 5 `
            -SandboxRoot $root -WorkerSandbox @((Join-Path $root 'psmut-w1')) -Quiet

        @($r | ForEach-Object { $_.File } | Sort-Object -Unique) |
            Should-BeCollection @((Split-Path $script:fixture -Leaf))
    }
}
