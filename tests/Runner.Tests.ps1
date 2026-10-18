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
    . (Join-Path $src 'PSMutation.Killers.ps1')
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
    # ABSOLUTE, and under temp. A stub candidate's File is a path something eventually WRITES:
    # Complete-PSMutantEvaluation restores it in a `finally`, and while the unmutated sweep never
    # reaches that for a running job, a MUTANT of the sweep does. Spelled relatively -- 'a.ps1' --
    # that write lands in the process working directory, which is the repo root, and a stray empty
    # a.ps1 appears in the working tree during self-mutation and nowhere else.
    #
    # The sandbox does not cover this. It protects tracked source from the mutants of a RUN; this
    # is a unit test's own fixture, and its path never went through the sandbox mapper at all.
    $script:stubFile = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-stub-$($script:tag).ps1"

    function StubJob {
        param($Source, [int]$Index = 0, [double]$Seconds = 0, $Original = '', [bool]$Completed = $true,
            [int]$WorkerId = 0, [int]$TimeoutSeconds = 5)
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
            TimeoutSeconds  = $TimeoutSeconds
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
        $c = (Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false -CoveredLines @{}).Candidates
        $c.Count | Should-BeGreaterThan 0
    }
    It 'reports what filtering removed, per file' {
        # The pre-filter count exists only here. Without it the caller cannot tell a file
        # that contributed nothing from one that was never in `mutate`, because the file is
        # still listed and still hashed into the report either way.
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@(3) }
        $sel = Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() `
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
        $c = (Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $true -CoveredLines $covered).Candidates
        ($c | ForEach-Object Line | Sort-Object -Unique) | Should-Be 3
    }
}

Describe 'Select-PSMutationCandidate and ignored calls (#263)' {
    BeforeAll {
        $script:loud = Join-Path $TestDrive 'loud.ps1'
        Set-Content -LiteralPath $script:loud -Encoding utf8 -Value @(
            'function Get-Loud {'
            '    Write-Verbose ("{0}" -f (1 + 2))'
            '    return 3 + 4'
            '}'
        )
    }

    It 'takes out the mutants inside an ignored call, counts them, and leaves every id where it was' {
        $all = Select-PSMutationCandidate -MutateFiles @($script:loud) -Operators @('BinaryOperator', 'NumberLiteral') -IgnoreCall @() -CoveredLinesOnly $false
        $some = Select-PSMutationCandidate -MutateFiles @($script:loud) -Operators @('BinaryOperator', 'NumberLiteral') -IgnoreCall @('write-verbose') -CoveredLinesOnly $false
        $inside = @($all.Candidates | Where-Object Line -EQ 2)
        $inside.Count | Should-BeGreaterThan 0
        @($some.Candidates | Where-Object Line -EQ 2).Count | Should-Be 0
        $some.PerFile[0].Ignored | Should-Be $inside.Count
        $some.PerFile[0].Produced | Should-Be ($all.PerFile[0].Produced - $inside.Count)
        $some.PerFile[0].Kept | Should-Be $some.Candidates.Count
        $all.PerFile[0].Ignored | Should-Be 0
        # Numbered over everything, so a mutant keeps its id whatever the list says.
        @($some.Candidates.Id) | Should-BeCollection @($all.Candidates | Where-Object Line -NE 2 | ForEach-Object Id)
    }

    It 'takes them out before the coverage filter, so none is also counted as uncovered' {
        $covered = @{ ([System.IO.Path]::GetFullPath($script:loud)) = [System.Collections.Generic.HashSet[int]]@(3) }
        $sel = Select-PSMutationCandidate -MutateFiles @($script:loud) -Operators @('BinaryOperator', 'NumberLiteral') -IgnoreCall @('Write-Verbose') -CoveredLinesOnly $true -CoveredLines $covered
        $sel.PerFile[0].Produced | Should-Be $sel.PerFile[0].Kept
    }

    It 'carries the count into the display tally' {
        $tally = ConvertTo-PSMutationDisplayPerFile -PerFile @([pscustomobject]@{ File = $script:loud; Produced = 3; Kept = 2; Ignored = 4; ByOperator = @{} }) -SandboxRoot (Split-Path $script:loud)
        $tally[0].Ignored | Should-Be 4
    }
}

Describe 'Get-PSMutationProgressLine' {
    It 'marks a survivor with . as Warn and a kill with x as Muted' -ForEach @(
        @{ Status = 'Survived'; Glyph = '.'; Role = 'Warn' }
        @{ Status = 'Killed'; Glyph = 'x'; Role = 'Muted' }
        @{ Status = 'TimedOut'; Glyph = 'x'; Role = 'Muted' }
        # No verdict: neither a survivor's '.' nor a kill's 'x', and worth a reader's eye.
        @{ Status = 'CompileError'; Glyph = '!'; Role = 'Warn' }
        @{ Status = 'RuntimeError'; Glyph = '!'; Role = 'Warn' }
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

    It 'calls a job whose worker process died Crashed, whatever its clock, unless it finished (#256)' {
        Get-PSMutationJobState -Completed $false -Exited $true -ElapsedSeconds 1 -TimeoutSeconds 5 | Should-Be 'Crashed'
        Get-PSMutationJobState -Completed $false -Exited $true -ElapsedSeconds 99 -TimeoutSeconds 5 | Should-Be 'Crashed'
        Get-PSMutationJobState -Completed $true -Exited $true -ElapsedSeconds 1 -TimeoutSeconds 5 | Should-Be 'Complete'
    }
}

Describe 'Get-PSMutationWaitBudget' {
    It 'waits only as long as the SOONEST budget still has left' {
        # The least, not the average and not a fixed poll interval: a mutant is cut off on its own
        # budget, and one that expires while the scheduler is asleep on somebody else's clock has
        # overrun by however long the nap was.
        Get-PSMutationWaitBudget -RemainingSeconds @(9.0, 0.5, 7.0) -TimeoutSeconds 10 | Should-Be 500
    }

    It 'never returns zero, however far past its budget a mutant is' {
        # A zero timeout makes WaitAny a non-blocking poll, so a mutant already past its budget
        # would spin the scheduler at full speed until the sweep reached it.
        Get-PSMutationWaitBudget -RemainingSeconds @(-89) -TimeoutSeconds 10 | Should-Be 1
    }

    It 'falls back to the whole budget when nothing has started yet' {
        Get-PSMutationWaitBudget -RemainingSeconds @() -TimeoutSeconds 7 | Should-Be 7000
    }

    It 'is capped by the run-wide deadline when a per-file one is longer (#253)' {
        # A longer per-file deadline only means the scheduler looks again sooner; it must never
        # sleep past the run-wide one.
        Get-PSMutationWaitBudget -RemainingSeconds @(40.0) -TimeoutSeconds 10 | Should-Be 10000
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
        $script:rowCand = [pscustomobject]@{ Id = 1; Function = 'F'; File = $script:stubFile; Line = 1
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
                Row = [pscustomobject]@{ Id = $Id; File = $script:stubFile; Line = 1; Description = 'x'; Status = 'Killed' }
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
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; File = $script:stubFile; Line = 1
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
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { -not $Expired -and -not $Crashed }
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
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { $Expired -and -not $Crashed }
    }

    It 'collects a job whose worker PROCESS died as crashed, well inside its budget (#256)' {
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; Line = 1
            Operator = 'BinaryOperator'; Description = 'x'
            File = (Join-Path ([System.IO.Path]::GetTempPath()) 'a.ps1') }
        Mock Test-PSMutationWorkerExited { $WorkerId -eq 1 }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $sched = [pscustomobject]@{
            InFlight = [object[]]@($null, (StubJob -Source $cand -Index 0 -WorkerId 1 -Seconds 1 -Completed $false))
            Parked = @{}; Next = 1; Retired = 0
        }
        Complete-PSMutationSweep -Schedule $sched -Context ([pscustomobject]@{ TimeoutSeconds = 3600
                SandboxRoot = [System.IO.Path]::GetTempPath() })
        $sched.Parked.ContainsKey(0) | Should-BeTrue
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { $Crashed -and -not $Expired }
    }
}


Describe 'Invoke-PSMutationLoop' {
    It 'accepts an empty candidate set and returns no results' {
        # Reachable two ways: a mutate file with no covered candidates, and a
        # -RecheckFrom run whose previous survivors are all dead. Both are ordinary
        # outcomes, so neither may throw.
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @() -TestsByFile @{} -AllTests @('t.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        @($r).Count | Should-Be 0
    }

    It 'uses the per-file test mapping when the candidate file has one' {
        # The paired case below covers the fallback. This is the mapping actually
        # being honoured -- get it wrong and every mutant runs the entire suite,
        # which is correct but turns a minutes-long run into an hours-long one.
        $script:seenTests = $null
        Mock Start-PSMutantEvaluation { $script:seenTests = $CoveringTests; $script:seenOneProcess = [bool]$Process; StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cand = [pscustomobject]@{
            Id = 1; File = $script:fixture; Line = 3; Operator = 'BinaryOperator'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = ' '
        }
        $map = @{ $script:fixture = @('specific.Tests.ps1') }

        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile $map -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet

        $script:seenTests | Should-BeCollection @('specific.Tests.ps1')
        $r[0].Status | Should-Be 'Killed'
        # One worker runs in this process (#256).
        Should-BeFalse -Actual $script:seenOneProcess
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

        Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
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

        Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
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
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('all-tests.ps1') `
            -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        $script:seenTests | Should-BeCollection @('all-tests.ps1')
        $r[0].Status     | Should-Be 'Killed'
    }
}

Describe 'Get-PSMutationCoveredLine' {
    BeforeAll {
        # One Pester command record. Line is what Pester reports as StartLine, kept so the
        # fixture has the real shape rather than only the fields read today.
        function script:Cmd {
            param([int]$Start, [int]$End = $Start, [int]$Column = 1, [string]$File = $script:fixture)
            [pscustomobject]@{ File = $File; Line = $Start; StartLine = $Start; StartColumn = $Column; EndLine = $End }
        }
        function script:LinesOf {
            param($Covered)
            @($Covered[[System.IO.Path]::GetFullPath($script:fixture)] | Sort-Object) -join ','
        }
    }

    It 'covers every continuation line of a statement that ran, through its last' {
        # The shape that was dropped: `return "..." +` with three more lines of string. Pester
        # reports one command on line 10 spanning to 13; lines 11-13 start nothing. Line 13 is the
        # LAST line, so a stack that popped a command on its own last line would lose it.
        LinesOf (Get-PSMutationCoveredLine -Executed @((Cmd 10 13))) | Should-Be '10,11,12,13'
    }

    It 'leaves the continuation lines of a statement that did NOT run uncovered' {
        LinesOf (Get-PSMutationCoveredLine -Executed @((Cmd 1)) -Missed @((Cmd 10 13))) | Should-Be '1'
    }

    It 'does not let a command that ran speak for the script block inside it that did not' {
        # `Get-X | ForEach-Object {` on line 1, closing on line 5: the pipeline ran, its body never
        # did. Line 3 is a continuation of a body statement (2-3), line 4 a body statement alone.
        # Read as "any command spanning it", lines 2-4 would all be covered and their mutants come
        # back as survivors nothing could have killed.
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 1 5)) -Missed @((Cmd 2 3 -Column 5), (Cmd 4 -Column 5))
        LinesOf $r | Should-Be '1,5'
    }

    It 'covers a body that ran inside a command that ran, continuation included' {
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 1 5), (Cmd 2 3 -Column 5), (Cmd 4 -Column 5))
        LinesOf $r | Should-Be '1,2,3,4,5'
    }

    It 'covers a start line when ANY command starting on it ran, and not when none did' {
        # `$a = 1; $b = 2` style: two commands on line 2, one ran. Line 3 has two commands and
        # neither ran -- the half that fails a rule which covers every start line.
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 2 -Column 1)) -Missed @((Cmd 2 -Column 9), (Cmd 3 -Column 1), (Cmd 3 -Column 9))
        LinesOf $r | Should-Be '2'
    }

    It 'returns to the outer command once an inner one has ended' {
        # Outer 1-6 ran; inner 2-3 did not. Line 4 starts nothing and sits inside the outer only, so
        # the outer decides it -- which needs the inner popped first.
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 1 6)) -Missed @((Cmd 2 3 -Column 5))
        LinesOf $r | Should-Be '1,4,5,6'
    }

    It 'leaves a gap between two commands uncovered' {
        # A line no command spans -- a blank line, a param() default -- has nothing that can say
        # whether it ran. The first command is the FIRST record, so skipping it shows up here too.
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 1), (Cmd 4))
        LinesOf $r | Should-Be '1,4'
    }

    It 'reads commands in document order whatever order Pester lists them in' {
        # Executed and missed arrive as two lists, so the inner missed command comes AFTER the outer
        # one in the input and BEFORE it in nothing. Unsorted, the outer would be pushed last and
        # speak for line 3.
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 4), (Cmd 1 5)) -Missed @((Cmd 2 3 -Column 5))
        LinesOf $r | Should-Be '1,4,5'
    }

    It 'keys each file by its full path and keeps files apart' {
        $other = Join-Path ([System.IO.Path]::GetTempPath()) "psmut-cov-$([guid]::NewGuid().ToString('N')).ps1"
        $r = Get-PSMutationCoveredLine -Executed @((Cmd 1 2), (Cmd 7 -File $other)) -Missed @((Cmd 9 -File $other))
        LinesOf $r | Should-Be '1,2'
        @($r[[System.IO.Path]::GetFullPath($other)] | Sort-Object) -join ',' | Should-Be '7'
    }

    It 'runs under StrictMode, which a consumer may well have on' {
        # Strict mode turns an out-of-range index into an error. Without it, reading one past the
        # last command quietly yields $null and every boundary on the command index looks fine.
        $r = & {
            Set-StrictMode -Version Latest
            Get-PSMutationCoveredLine -Executed @((Cmd 1 2), (Cmd 3)) -Missed @((Cmd 5))
        }
        LinesOf $r | Should-Be '1,2,3'
    }

    It 'covers nothing when Pester measured nothing' {
        # The tracer off: both lists null. An empty map, not an exception.
        $r = Get-PSMutationCoveredLine -Executed $null -Missed $null
        $r.Count | Should-Be 0
    }

    It 'knows a file whose every command was missed, and covers none of it' {
        $r = Get-PSMutationCoveredLine -Executed @() -Missed @((Cmd 1 3))
        $r.ContainsKey([System.IO.Path]::GetFullPath($script:fixture)) | Should-BeTrue
        LinesOf $r | Should-Be ''
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
                    # The shape Pester reports: Line is StartLine, and the extent travels with it.
                    CommandsExecuted = @(
                        [pscustomobject]@{ File = $script:fixture; Line = 3; StartLine = 3; StartColumn = 5; EndLine = 3 }
                        [pscustomobject]@{ File = $script:fixture; Line = 7; StartLine = 7; StartColumn = 5; EndLine = 7 }
                        # Same line reported twice -- one command per statement means
                        # this is normal, and the line must not be counted twice.
                        [pscustomobject]@{ File = $script:fixture; Line = 3; StartLine = 3; StartColumn = 20; EndLine = 3 }
                    )
                    CommandsMissed   = @(
                        [pscustomobject]@{ File = $script:fixture; Line = 5; StartLine = 5; StartColumn = 5; EndLine = 5 }
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
        # The missed command reaches the collector too, and leaves its line uncovered.
        $r.CoveredLines[$key].Contains(5) | Should-BeFalse
        $r.DurationSeconds | Should-BeGreaterThanOrEqual 0
    }

    It 'measures coverage with breakpoints, which survive a class where the tracer does not (#270)' {
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() } }
        }
        Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) `
            -SandboxRoot $script:coverageDir -Coverage | Out-Null
        Should-Invoke Invoke-Pester -Exactly 1 -ParameterFilter { $Configuration.CodeCoverage.UseBreakpoints.Value -eq $true }
    }

    It 'leaves the setting alone on a Pester that does not have it' {
        # Pester 5.2.2 has no UseBreakpoints (measured): it only ever had breakpoints, and
        # assigning a property that is not there would fail the run for nothing.
        $old = [pscustomobject]@{ Enabled = $true }
        Set-PSMutationCoverageBreakpoint -CodeCoverage $old
        $old.PSObject.Properties['UseBreakpoints'] | Should-BeNull
        $new = [pscustomobject]@{ Enabled = $true; UseBreakpoints = $false }
        Set-PSMutationCoverageBreakpoint -CodeCoverage $new
        $new.UseBreakpoints | Should-BeTrue
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
                    CodeCoverage = [pscustomobject]@{ CommandsExecuted = @([pscustomobject]@{ File = $leaf; Line = 1; StartLine = 1; StartColumn = 1; EndLine = 1 }) }
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
        (Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Passed'; Ran = 1; Killers = @() })).Status |
            Should-Be 'Survived'
    }

    It 'reports RuntimeError, with no killers, for a pass over no test at all (#251)' {
        # A mutant that ended the tests' discovery: nothing looked at it, so it neither survived
        # nor was killed.
        $v = Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Passed'; Ran = 0; Killers = @('x') })
        $v.Status | Should-Be 'RuntimeError'
        @($v.Killers).Count | Should-Be 0
    }

    It 'still reports Killed for a failing run, whatever its count' {
        (Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Failed'; Ran = 0; Killers = @() })).Status | Should-Be 'Killed'
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
        @((Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Passed'; Ran = 1; Killers = @('x') })).Killers).Count | Should-Be 0
        @((Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'TimedOut'; Killers = @('x') })).Killers).Count | Should-Be 0
    }

    It 'reports Killed, naming no test, for a mutant that ended its worker process (#256)' {
        $v = Get-PSMutationVerdict -Run ([pscustomobject]@{ Result = 'Crashed'; Killers = @() })
        $v.Status | Should-Be 'Killed'
        @($v.Killers).Count | Should-Be 0
        @($v.KillerPath | Where-Object { $_ }).Count | Should-Be 0
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
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Passed"; Ran = 1; Killers = @() }' }

        $job = Start-PSMutantEvaluation -Candidate $script:candidate -Source $script:candidate -Index 0 `
            -MutatedContent 'MUTATED' -OriginalContent $script:before -CoveringTests @('t.Tests.ps1') -WorkerId 0 -SandboxRoot $TestDrive
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

    It 'collects a job whose worker died by ending the worker, scores it Killed, and restores the file (#256)' {
        [System.IO.File]::WriteAllText($script:target, 'MUTATED')
        Mock Stop-PSMutationJob { [pscustomobject]@{ Result = $Outcome; Killers = @() } }
        Mock Receive-PSMutationJob { throw 'must not be asked' }
        (Complete-PSMutantEvaluation -Job $script:stub -Crashed).Status | Should-Be 'Killed'
        Should-Invoke Stop-PSMutationJob -Exactly 1 -ParameterFilter { $Outcome -eq 'Crashed' }
        [System.IO.File]::ReadAllText($script:target) | Should-Be $script:before
    }

    It 'stops a job as TimedOut unless told its worker died, and ends that worker either way (#256)' {
        Mock Stop-PSMutationWarmRunspace { }
        (Stop-PSMutationJob -Job ([pscustomobject]@{ WorkerId = 3 })).Result | Should-Be 'TimedOut'
        (Stop-PSMutationJob -Job ([pscustomobject]@{ WorkerId = 3 }) -Outcome Crashed).Result | Should-Be 'Crashed'
        Should-Invoke Stop-PSMutationWarmRunspace -Exactly 2 -ParameterFilter { $WorkerId -eq 3 }
    }
}

Describe 'a proof or a first pass whose worker died (#256)' {
    It 'proves nothing from a crashed proof, and ends its worker' {
        Mock Stop-PSMutationJob { [pscustomobject]@{ Result = $Outcome; Killers = @() } }
        Mock Receive-PSMutationJob { throw 'must not be asked' }
        $ctx = [pscustomobject]@{ Killers = (New-PSMutationKillerMemory) }
        Complete-PSMutationProofJob -Job ([pscustomobject]@{ WorkerId = 0; Proof = @('D.a') }) -State 'Crashed' -Context $ctx
        $ctx.Killers.Proven.Count | Should-Be 0
        Should-Invoke Stop-PSMutationJob -Exactly 1
    }

    It 'collects a finished mutant as crashed only when it crashed' {
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $cand = [pscustomobject]@{ Id = 1; Function = 'F'; Line = 1; Operator = 'BinaryOperator'; Description = 'x'
            File = (Join-Path ([System.IO.Path]::GetTempPath()) 'a.ps1') }
        $null = Get-PSMutationFinishedMutant -Job (StubJob -Source $cand) -State 'Crashed' -SandboxRoot ([System.IO.Path]::GetTempPath())
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { $Crashed -and -not $Expired }
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
                -MutatedContent 'x' -OriginalContent 'x' -CoveringTests @('t.Tests.ps1') -WorkerId 0 -SandboxRoot $TestDrive
            $done = $job.Async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))
            return $done ? (Receive-PSMutationJob -Job $job) : (Stop-PSMutationJob -Job $job)
        }
    }

    It 'hands back the verdict the child produced' {
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Passed"; Ran = 4; Killers = @() }' }
        $r = Invoke-ChildForTest
        $r.Result | Should-Be 'Passed'
        # And how many tests it ran, which is what tells a pass from a pass over nothing (#251).
        $r.Ran | Should-Be 4
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

    It 'cuts off a child stuck in a BLOCKING .NET call without waiting for the call (#250)' {
        # Start-Sleep above is a cmdlet, which a stop interrupts. Thread.Sleep is not: a synchronous
        # Stop() waited the whole call out, and every other worker waited with it.
        # Sized to stay cheap -- this file covers Runner.ps1, so every one of its mutants that gets
        # here pays for it. A 4s sleep with a 1s budget: a waiting stop returns after 4s, a
        # non-waiting one after the budget plus the warm-up. The parked runspace is NOT waited out:
        # it finishes its sleep in the background and is disposed by a later sweep, which is the
        # behaviour under test, and waiting here cost 9s of every run of this file.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [System.Threading.Thread]::Sleep(4000)' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $outcome = (Invoke-ChildForTest -TimeoutSeconds 1).Result
        $sw.Stop()
        $outcome | Should-Be 'TimedOut'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 3.5
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
        $r.Unexplained | Should-Be 1
    }

    It 'counts only the failures that came back with nothing to say' {
        # One of each, so a count that included every failure, or none, is wrong here. The blank
        # message is the second shape of "nothing": an error record whose text is only whitespace.
        Mock Invoke-Pester {
            [pscustomobject]@{
                Result       = 'Failed'
                CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }
                Failed       = @(
                    [pscustomobject]@{ ExpandedPath = 'Blocked.Test'; ErrorRecord = @() }
                    [pscustomobject]@{ ExpandedPath = 'Blank.Test'
                        ErrorRecord = @([pscustomobject]@{ Exception = [pscustomobject]@{ Message = " `r`n " } }) }
                    [pscustomobject]@{ ExpandedPath = 'Said.Test'
                        ErrorRecord = @([pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'Expected 1, got 2' } }) }
                )
            }
        }
        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir
        $r.Unexplained | Should-Be 2
    }

    It 'counts no unexplained failure on a green run' {
        # Failed is null when nothing failed. A pipeline over it runs once with $null and would
        # count a phantom failure -- harmless today, because the guard reads it only when the run
        # is red, and exactly the kind of harmless that stops being so.
        Mock Invoke-Pester {
            [pscustomobject]@{ Result = 'Passed'; CodeCoverage = [pscustomobject]@{ CommandsExecuted = @() }; Failed = $null }
        }
        $r = Invoke-PSMutationBaseline -TestPath @('tests') -MutateFiles @($script:fixture) -SandboxRoot $script:coverageDir
        $r.Unexplained | Should-Be 0
    }
}

Describe 'Get-PSMutationFailedTestReason' {
    BeforeAll {
        function Rec([string]$Message) { [pscustomobject]@{ Exception = [pscustomobject]@{ Message = $Message } } }
    }

    It 'gives the first non-blank line of the first record, trimmed' {
        $t = [pscustomobject]@{ ErrorRecord = @((Rec "`r`n  Expected 1, got 2  `r`nat <ScriptBlock>")) }
        Get-PSMutationFailedTestReason -Test $t | Should-Be 'Expected 1, got 2'
    }

    It 'takes the FIRST record of several, not a later one' {
        $t = [pscustomobject]@{ ErrorRecord = @((Rec 'first'), (Rec 'second')) }
        Get-PSMutationFailedTestReason -Test $t | Should-Be 'first'
    }

    It 'does not fall through to a later record when the first one is blank' {
        # The first record is the reason; a later one is usually cascade from it, and promoting it
        # would name a consequence as the cause.
        $t = [pscustomobject]@{ ErrorRecord = @((Rec " `r`n "), (Rec 'cascade')) }
        Get-PSMutationFailedTestReason -Test $t | Should-Be ''
    }

    It 'answers empty for a test with no record, under StrictMode' {
        # The BeforeAll-died case. Indexing an empty collection throws under StrictMode, so this is
        # the shape the function must walk rather than index.
        $r = & {
            Set-StrictMode -Version Latest
            Get-PSMutationFailedTestReason -Test ([pscustomobject]@{ ErrorRecord = @() })
        }
        $r | Should-Be ''
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

    It 'says where to look when NO failure carried a reason' {
        # Anchored at the refusal's first word and running through the hint, so the hint is shown
        # to be part of THIS message rather than matched somewhere inside a quoted one.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @('Blocked.One', 'Blocked.Two'); Unexplained = 2
                }) } | Should-Throw -ExceptionMessage 'Baseline suite is not green*Failed: Blocked.One; Blocked.Two. None of them carried an error.*Install-Module Pester*-Force.'
    }

    It 'gives the hint for a single unexplained failure too' {
        # Exactly one, so a guard that wanted "more than one" before speaking is caught: a single
        # dead BeforeAll in a one-test file is the commonest way to land here.
        { Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @('Blocked.Only'); Unexplained = 1
                }) } | Should-Throw -ExceptionMessage 'Baseline suite is not green*Failed: Blocked.Only. None of them carried an error.*'
    }

    It 'gives no hint when any failure did carry a reason' {
        # One failure explained itself, so the reader has somewhere to start and the hint would
        # send them away from it.
        $message = $null
        try {
            Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{
                    Passed = $false; FailedTest = @('Blocked.One', 'Said.Two -- Expected 1'); Unexplained = 1
                })
        }
        catch { $message = $_.Exception.Message }
        $message | Should-BeLikeString '*Failed: Blocked.One; Said.Two -- Expected 1.'
        $message | Should-NotBeLikeString '*None of them*'
    }

    It 'gives no hint when it has no names at all' {
        # Zero of zero is "every failure unexplained" by arithmetic and by nothing else: there is
        # no failure to explain, and a hint about failures that were never named reads as noise.
        $message = $null
        try {
            Assert-PSMutationBaselineGreen -Baseline ([pscustomobject]@{ Passed = $false; FailedTest = @(); Unexplained = 0 })
        }
        catch { $message = $_.Exception.Message }
        $message | Should-NotBeLikeString '*None of them*'
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
        $all = (Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() `
            -Operators @('BinaryOperator', 'BooleanLiteral') -CoveredLinesOnly $false).Candidates
        $all.Count | Should-BeGreaterThan 1

        # Admit only the lines of the LAST candidate, so any renumbering shows up as id 1.
        $full = [System.IO.Path]::GetFullPath($script:fixture)
        $last = $all[-1]
        $covered = @{ $full = [System.Collections.Generic.HashSet[int]]@($last.Line) }
        $filtered = (Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() `
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
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) -TestsByFile @{} -AllTests @('t.ps1') `
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
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) -TestsByFile @{} -AllTests @('t.Tests.ps1') `
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
            $null = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) -TestsByFile @{} -AllTests @('t.Tests.ps1') `
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
        { Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) `
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
            Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink $sink -Candidates @($script:dCand, $script:dCand, $script:dCand) `
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
        { Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink $sink -Candidates @($script:dCand, $script:dCand) `
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
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) `
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
        $sel = Select-PSMutationCandidate -MutateFiles @($script:fixture) -IgnoreCall @() -Operators @('BinaryOperator') `
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
        $script:seenProcess = @()
        Mock Start-PSMutantEvaluation {
            $script:seenProcess += [bool]$Process
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

        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) `
            -TestsByFile @{} -AllTests @((Join-Path $root 'all.Tests.ps1')) -TimeoutSeconds 5 `
            -SandboxRoot $root -WorkerSandbox @($w1, $w2) -Quiet

        @($r).Count | Should-Be 3
        @($script:seenWorkers | Sort-Object) | Should-BeCollection @(0, 1, 2)
        # Three workers: each runs in a process of its own (#256).
        @($script:seenProcess | Sort-Object -Unique) | Should-BeCollection @($true)
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
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cands) `
            -TestsByFile @{} -AllTests @((Join-Path $root 'all.Tests.ps1')) -TimeoutSeconds 5 `
            -SandboxRoot $root -WorkerSandbox @((Join-Path $root 'psmut-w1')) -Quiet

        @($r | ForEach-Object { $_.File } | Sort-Object -Unique) |
            Should-BeCollection @((Split-Path $script:fixture -Leaf))
    }
}

Describe 'Get-PSMutationSuiteGroup' {
    It 'yields each distinct suite once, in the order candidates first use it' {
        # Two files mapped to the same tests are ONE suite to prove, and every candidate of a file
        # shares its file's -- so without the dedupe the check would run a suite once per mutant.
        $c = @(
            [pscustomobject]@{ File = 'b.ps1' }, [pscustomobject]@{ File = 'a.ps1' },
            [pscustomobject]@{ File = 'b.ps1' }, [pscustomobject]@{ File = 'c.ps1' }
        )
        $map = @{ 'a.ps1' = @('a.Tests.ps1'); 'b.ps1' = @('b.Tests.ps1', 'x.Tests.ps1'); 'c.ps1' = @('a.Tests.ps1') }
        $groups = Get-PSMutationSuiteGroup -Candidates $c -TestsByFile $map -AllTests @('all.Tests.ps1')
        (@($groups | ForEach-Object { $_ -join '+' }) -join ' | ') | Should-Be 'b.Tests.ps1+x.Tests.ps1 | a.Tests.ps1'
    }

    It 'falls back to the whole suite for an unmapped file, as a mutant of it would' {
        $groups = Get-PSMutationSuiteGroup -Candidates @([pscustomobject]@{ File = 'z.ps1' }) -TestsByFile @{} `
            -AllTests @('one.Tests.ps1', 'two.Tests.ps1')
        (@($groups | ForEach-Object { $_ -join '+' }) -join ' | ') | Should-Be 'one.Tests.ps1+two.Tests.ps1'
    }

    It 'yields nothing for no candidates' {
        # Not wrapped in @(): the result is comma-returned, and @() would count the empty array as one.
        (Get-PSMutationSuiteGroup -Candidates @() -TestsByFile @{} -AllTests @('t.ps1')).Count | Should-Be 0
    }
}

Describe 'Get-PSMutationWorkerGreenFault' {
    It 'says nothing about a suite that passed' {
        Should-BeNull -Actual (Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Passed'; Ran = 1; Killers = @() }) `
                -Suite @('a.Tests.ps1') -WorkerId 0 -TimeoutSeconds 5)
    }

    It 'refuses a suite that passed by running no test (#251)' {
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Passed'; Ran = 0; Killers = @() }) `
            -Suite @('tests/a.Tests.ps1') -WorkerId 1 -TimeoutSeconds 5
        $f | Should-Be 'The unmutated covering suite ran no test in a clean runspace: tests/a.Tests.ps1 in worker 1. Every test in it was skipped or never discovered, so it cannot pass a verdict on any mutant it covers.'
    }

    It 'names the suite, the worker and the failed tests, and what the session may have provided' {
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Failed'; Killers = @('A.one', 'A.two') }) `
            -Suite @('tests/a.Tests.ps1', 'tests/b.Tests.ps1') -WorkerId 2 -TimeoutSeconds 5
        # Anchored at both ends, so a broken concatenation -- which QUOTES the text so far -- cannot match.
        $f | Should-BeLikeString 'The covering suite passes in this session but not in a clean runspace*'
        $f | Should-BeLikeString '*: tests/a.Tests.ps1, tests/b.Tests.ps1 in worker 2. Failed: A.one; A.two. It depends on*'
        $f | Should-BeLikeString '*$ErrorActionPreference, strict mode, $PSDefaultParameterValues*'
        $f | Should-BeLikeString '*scored Killed by that failure rather than by a test.'
    }

    It 'caps the names at ten and counts the rest' {
        $eleven = @(1..11 | ForEach-Object { "T.$_" })
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Failed'; Killers = $eleven }) `
            -Suite @('a.Tests.ps1') -WorkerId 0 -TimeoutSeconds 5
        $f | Should-BeLikeString '*Failed: T.1; T.2; T.3; T.4; T.5; T.6; T.7; T.8; T.9; T.10 (and 1 more). It*'
    }

    It 'names exactly ten without counting a remainder' {
        # The boundary: ten names is the cap, not past it.
        $ten = @(1..10 | ForEach-Object { "T.$_" })
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Failed'; Killers = $ten }) `
            -Suite @('a.Tests.ps1') -WorkerId 0 -TimeoutSeconds 5
        $f | Should-BeLikeString '*Failed: T.1;*; T.10. It*'
        $f | Should-NotBeLikeString '*more)*'
    }

    It 'points at a BeforeAll when no test carried the error' {
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Failed'; Killers = @() }) `
            -Suite @('a.Tests.ps1') -WorkerId 0 -TimeoutSeconds 5
        $f | Should-BeLikeString '*in worker 0. No test carried the error, so a BeforeAll failed: run the file alone in a new session to see it. It depends on*'
    }

    It 'says an unmutated suite that ended its worker process would kill every mutant (#256)' {
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'Crashed'; Killers = @() }) `
            -Suite @('a.Tests.ps1') -WorkerId 1 -TimeoutSeconds 7
        $f | Should-Be 'The unmutated covering suite ended the worker process running it: a.Tests.ps1 in worker 1. Something in it calls [Environment]::Exit or overflows the stack, and every mutant it covers would be scored Killed by that rather than by a test.'
    }

    It 'says an unmutated suite that overran would time out every mutant' {
        $f = Get-PSMutationWorkerGreenFault -Run ([pscustomobject]@{ Result = 'TimedOut'; Killers = @() }) `
            -Suite @('a.Tests.ps1') -WorkerId 1 -TimeoutSeconds 7
        $f | Should-Be 'The unmutated covering suite did not finish within the per-mutant timeout of 7 s: a.Tests.ps1 in worker 1. Every mutant it covers would time out, and a timeout scores with the kills.'
    }
}

Describe 'the unmutated suite, in every worker, before any mutant' {
    # Real worker runspaces with Pester really imported, running stub child scripts -- the same
    # shape as "a worker's child runspace" above. The stub decides its verdict from the paths it
    # was handed, which is what shows each worker got ITS OWN re-rooted copy of the suite.
    BeforeAll {
        $script:primary = Join-Path $TestDrive 'primary'
        $script:second = Join-Path $TestDrive 'second'
        New-Item -ItemType Directory -Path (Join-Path $script:primary 'tests'), (Join-Path $script:second 'tests') -Force | Out-Null
        $script:greenCand = @(
            [pscustomobject]@{ File = (Join-Path $script:primary 'src/a.ps1') },
            [pscustomobject]@{ File = (Join-Path $script:primary 'src/b.ps1') }
        )
        $script:greenMap = @{
            (Join-Path $script:primary 'src/a.ps1') = @(Join-Path $script:primary 'tests/a.Tests.ps1')
            (Join-Path $script:primary 'src/b.ps1') = @(Join-Path $script:primary 'tests/b.Tests.ps1')
        }
        function Invoke-GreenForTest {
            param([int]$TimeoutSeconds = 30, [switch]$OneWorker)
            $extra = $OneWorker ? @() : @($script:second)
            Assert-PSMutationWorkerGreen -Candidates $script:greenCand -TestsByFile $script:greenMap -AllTests @() `
                -TimeoutSeconds $TimeoutSeconds -SandboxRoot $script:primary -WorkerSandbox $extra
        }
    }
    # Closed once, after the block, not after every test: with two workers each is a process (#256),
    # and starting two per test cost every mutant of Runner.ps1 about twenty seconds.
    AfterAll { Close-PSMutationWarmRunspacePool }

    It 'passes when every suite is green in every worker' {
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Passed"; Ran = 1; Killers = @() }' }
        $seconds = Invoke-GreenForTest
        # And it says how long each mutate file's suite took, which sizes its deadline (#253).
        (@($seconds.Keys | Sort-Object | ForEach-Object { Split-Path $_ -Leaf }) -join ',') | Should-Be 'a.ps1,b.ps1'
        foreach ($k in $seconds.Keys) { $seconds[$k] | Should-BeGreaterThan 0 }
    }

    It 'refuses a suite red in the PRIMARY worker, naming it and the failed tests' {
        Mock Get-PSMutationWarmPesterScript {
            'param($tests, $recordAllKillers) [pscustomobject]@{ Result = ($tests -like "*primary*b.Tests.ps1") ? "Failed" : "Passed"; Ran = 1; Killers = @("B.needs the session") }'
        }
        # Relative to the source root, as the report names files -- not the temp sandbox path.
        { Invoke-GreenForTest } | Should-Throw -ExceptionMessage '*runs: tests/b.Tests.ps1 in worker 0. Failed: B.needs the session.*'
    }

    It 'refuses a suite red only in ANOTHER worker''s sandbox, after a worker where it passed' {
        # Every worker, not one: a suite red in one copy kills that worker's mutants only. And the
        # fault comes from the SECOND job, after a passing first -- so the first fault is found
        # past the empty answer a green worker gives.
        Mock Get-PSMutationWarmPesterScript {
            'param($tests, $recordAllKillers) [pscustomobject]@{ Result = ($tests -like "*second*a.Tests.ps1") ? "Failed" : "Passed"; Ran = 1; Killers = @("A.copy") }'
        }
        # Named as the PRIMARY copy is: which sandbox a worker ran is scheduling, and the worker
        # number says it.
        { Invoke-GreenForTest } | Should-Throw -ExceptionMessage '*runs: tests/a.Tests.ps1 in worker 1. Failed: A.copy.*'
    }

    It 'refuses a suite that ends its worker PROCESS, without waiting out the timeout (#256)' {
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [System.Environment]::Exit(3)' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { Invoke-GreenForTest -TimeoutSeconds 60 } | Should-Throw -ExceptionMessage '*ended the worker process running it: tests/a.Tests.ps1 in worker 0.*'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20
    }

    It 'asks for EVERY failing test, not the first' {
        # Paid once per run, and read by a person who has to act on it.
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) [pscustomobject]@{ Result = "Failed"; Killers = @("all=$recordAllKillers") }' }
        { Invoke-GreenForTest -OneWorker } | Should-Throw -ExceptionMessage '*Failed: all=True.*'
    }

    It 'refuses a suite that overruns the per-mutant timeout, and discards the runspace it stopped' {
        Mock Get-PSMutationWarmPesterScript { 'param($tests, $recordAllKillers) Start-Sleep -Seconds 30' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { Invoke-GreenForTest -TimeoutSeconds 1 -OneWorker } | Should-Throw -ExceptionMessage '*did not finish within the per-mutant timeout of 1 s*'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20
        $script:PSMutationWarmShell.ContainsKey(0) | Should-BeFalse
    }

    It 'runs the suites in worker processes when there is more than one worker, and in this one otherwise (#256)' {
        $script:greenProcess = @()
        Mock Start-PSMutationGreenJob { $script:greenProcess += [bool]$Process; [pscustomobject]@{ WorkerId = $WorkerId } }
        Mock Wait-PSMutationGreenJob { [pscustomobject]@{ Result = 'Passed'; Ran = 1; Killers = @() } }
        $null = Invoke-GreenForTest
        @($script:greenProcess | Sort-Object -Unique) | Should-BeCollection @($true)
        $script:greenProcess = @()
        $null = Invoke-GreenForTest -OneWorker
        @($script:greenProcess | Sort-Object -Unique) | Should-BeCollection @($false)
    }

    It 'runs nothing for no candidates' {
        Mock Get-PSMutationSuiteShell { throw 'must not run' }
        (Assert-PSMutationWorkerGreen -Candidates @() -TestsByFile @{} -AllTests @('t.ps1') `
                -TimeoutSeconds 5 -SandboxRoot $script:primary).Count | Should-Be 0
    }
}

Describe 'Wait-PSMutationGreenJob (#256)' {
    BeforeAll {
        function script:GreenStub { param([bool]$Done) [pscustomobject]@{ WorkerId = 4; Async = [pscustomobject]@{ AsyncWaitHandle = [System.Threading.ManualResetEvent]::new($Done) } } }
    }

    It 'hands back what a finished job said' {
        Mock Receive-PSMutationJob { [pscustomobject]@{ Result = 'Passed' } }
        Mock Stop-PSMutationJob { throw 'must not be asked' }
        (Wait-PSMutationGreenJob -Job (GreenStub $true) -TimeoutSeconds 5).Result | Should-Be 'Passed'
    }

    It 'keeps waiting, slice after slice, for a job that is still running inside its timeout' {
        # Finishes 1.3s in: after the first one-second slice, before the timeout.
        Mock Test-PSMutationWorkerExited { $false }
        Mock Receive-PSMutationJob { [pscustomobject]@{ Result = 'Passed' } }
        Mock Stop-PSMutationJob { throw 'must not be stopped' }
        $late = [System.Threading.Tasks.Task]::Delay(1300)
        $job = [pscustomobject]@{ WorkerId = 4; Async = [pscustomobject]@{ AsyncWaitHandle = ([System.IAsyncResult]$late).AsyncWaitHandle } }
        (Wait-PSMutationGreenJob -Job $job -TimeoutSeconds 10).Result | Should-Be 'Passed'
    }

    It 'says Crashed for a job whose worker died, at the next slice rather than at the timeout' {
        Mock Test-PSMutationWorkerExited { $WorkerId -eq 4 }
        Mock Stop-PSMutationJob { [pscustomobject]@{ Result = $Outcome } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        (Wait-PSMutationGreenJob -Job (GreenStub $false) -TimeoutSeconds 60).Result | Should-Be 'Crashed'
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 2
    }

    It 'says TimedOut for a job still running at its timeout, and no sooner' {
        Mock Test-PSMutationWorkerExited { $false }
        Mock Stop-PSMutationJob { [pscustomobject]@{ Result = $Outcome } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        (Wait-PSMutationGreenJob -Job (GreenStub $false) -TimeoutSeconds 1).Result | Should-Be 'TimedOut'
        $sw.Elapsed.TotalSeconds | Should-BeGreaterThan 0.9
    }
}

Describe 'a mutant that ends its worker process (#256)' {
    # Two real worker processes. The stub child reads its worker's copy of the mutated file and
    # ends its own process when the mutant asks it to -- as [Environment]::Exit in a mutant, or a
    # stack overflow, would.
    BeforeAll {
        $script:crashPrimary = Join-Path $TestDrive 'crash-primary'
        $script:crashSecond = Join-Path $TestDrive 'crash-second'
        foreach ($r in $script:crashPrimary, $script:crashSecond) {
            New-Item -ItemType Directory -Path (Join-Path $r 'src') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $r 'src/a.ps1') -Value 'function F { 1 }' -NoNewline
        }
    }
    AfterEach { Close-PSMutationWarmRunspacePool }

    It 'is scored Killed, its file is put back, and the run goes on in a new worker' {
        Mock Get-PSMutationWarmPesterScript {
            'param($tests, $recordAllKillers, $sandboxRoot) if ((Get-Content -Raw -LiteralPath (Join-Path $sandboxRoot "src/a.ps1")) -match "EXIT") { [System.Environment]::Exit(3) }; [pscustomobject]@{ Result = "Passed"; Ran = 1; Killers = @() }'
        }
        $file = Join-Path $script:crashPrimary 'src/a.ps1'
        $cands = @(1, 2, 3) | ForEach-Object {
            [pscustomobject]@{ Id = $_; Function = 'F'; File = $file; Line = 1; Operator = 'NumberLiteral'
                Description = "m$_"; StartOffset = 13; EndOffset = 14; Mutated = (($_ -eq 2) ? 'EXIT' : '2') }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) `
            -Candidates $cands -TestsByFile @{} -AllTests @((Join-Path $script:crashPrimary 'a.Tests.ps1')) -TimeoutSeconds 60 `
            -SandboxRoot $script:crashPrimary -WorkerSandbox @($script:crashSecond) -Quiet
        @($rows | ForEach-Object { $_.Status }) | Should-BeCollection @('Survived', 'Killed', 'Survived')
        @($rows[1].KilledBy).Count | Should-Be 0
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 30
        foreach ($r in $script:crashPrimary, $script:crashSecond) {
            Get-Content -Raw -LiteralPath (Join-Path $r 'src/a.ps1') | Should-Be 'function F { 1 }'
        }
    }
}

Describe 'Get-PSMutationReloadFault (#249)' {
    # Two things PowerShell keeps for the life of the PROCESS, measured: a module loaded with
    # `using module <path>` (stale even in a fresh runspace) and a type compiled by Add-Type.
    # Every mutant runs in this one process, so their mutants would be judged on code that did
    # not run. The rest -- Import-Module with or without -Force -- is unloaded per mutant.
    BeforeEach {
        $script:box = Join-Path $TestDrive "box-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:box 'src'), (Join-Path $script:box 'tests') -Force | Out-Null
        $script:mod = Join-Path $script:box 'src/M.psm1'
        'class K { }' | Set-Content -LiteralPath $script:mod
        function script:Put { param([string]$Rel, [string]$Text)
            $p = Join-Path $script:box $Rel; Set-Content -LiteralPath $p -Value $Text; return $p }
    }

    It 'says nothing when nothing is loaded that way' {
        $t = Put 'tests/a.Tests.ps1' "BeforeAll { Import-Module `$PSScriptRoot/../src/M.psm1 }"
        Should-BeNull -Actual (Get-PSMutationReloadFault -MutateFiles @($script:mod) -TestFiles @($t) -Candidates @() -SandboxRoot $script:box)
    }

    It 'refuses `using module` of a path inside the sandbox, naming file, line and statement' -ForEach @(
        @{ Spelling = '../src/M.psm1' }
        @{ Spelling = '..\src\M.psm1' }
    ) {
        $t = Put 'tests/a.Tests.ps1' "# header`nusing module $Spelling`nDescribe 'a' { }"
        $f = Get-PSMutationReloadFault -MutateFiles @($script:mod) -TestFiles @($t) -Candidates @() -SandboxRoot $script:box
        $f | Should-BeLikeString 'PSMutant evaluates many mutants in each PowerShell process, and PowerShell keeps these for a process''s whole life*'
        # ? for each backtick: in a -like pattern a backtick is the escape character. And ${Spelling}
        # braced, because PowerShell 7 allows ? in a variable name: "$Spelling?" names another variable.
        $f | Should-BeLikeString "*`n  tests/a.Tests.ps1:2 loads the code under test with ?using module ${Spelling}?, which the process keeps*Import it with Import-Module, or dot-source it, in a BeforeAll."
    }

    It 'refuses a manifest by path too' {
        $psd = Put 'src/M.psd1' "@{ RootModule = 'M.psm1'; ModuleVersion = '1.0' }"
        $t = Put 'tests/a.Tests.ps1' "using module ./../src/M.psd1"
        (Get-PSMutationReloadFault -MutateFiles @($script:mod) -TestFiles @($t) -Candidates @() -SandboxRoot $script:box) |
            Should-BeLikeString '*tests/a.Tests.ps1:1 loads*'
        Test-Path $psd | Should-BeTrue
    }

    It 'leaves alone <Name>' -ForEach @(
        @{ Name = 'a module by bare name, which is installed and never mutated'; Code = 'using module Pester' }
        @{ Name = 'a path that resolves outside the sandbox'; Code = 'using module ../../elsewhere/Other.psm1' }
        @{ Name = 'using namespace, which loads nothing'; Code = 'using namespace System.Text' }
    ) {
        $t = Put 'tests/a.Tests.ps1' $Code
        Should-BeNull -Actual (Get-PSMutationReloadFault -MutateFiles @($script:mod) -TestFiles @($t) -Candidates @() -SandboxRoot $script:box)
    }

    It 'checks the mutate files as well as the tests' {
        $m = Put 'src/user.ps1' 'using module ./M.psm1'
        (Get-PSMutationReloadFault -MutateFiles @($m) -TestFiles @() -Candidates @() -SandboxRoot $script:box) |
            Should-BeLikeString '*src/user.ps1:1 loads*'
    }

    It 'refuses a mutant INSIDE an Add-Type call, and only that one' {
        $src = "function Get-T { 1 }`nAdd-Type -TypeDefinition 'public class T249 { }'`n`$x = 'after'"
        $m = Put 'src/t.ps1' $src
        $inside = $src.IndexOf("'public")
        $after = $src.IndexOf("'after'")
        $cands = @(
            [pscustomobject]@{ File = $m; Line = 2; StartOffset = $inside; EndOffset = $inside + 5; Description = 'inside' }
            [pscustomobject]@{ File = $m; Line = 3; StartOffset = $after; EndOffset = $after + 7; Description = 'outside' }
        )
        $f = Get-PSMutationReloadFault -MutateFiles @($m) -TestFiles @() -Candidates $cands -SandboxRoot $script:box
        $f | Should-BeLikeString "*`n  src/t.ps1:2 has a mutant inside an Add-Type call (inside), and a compiled type cannot be compiled again in the process. Leave StringLiteral out of 'operators' for this file's run."
        $f | Should-NotBeLikeString '*(outside)*'
    }

    It 'finds an Add-Type call inside a function body, where it usually lives' {
        # Nested script blocks are searched: a function body is one, and a search of the top level
        # alone would miss every Add-Type that is not at the top of the file.
        $src = "function Initialize-T {`n    Add-Type -TypeDefinition 'public class T249n { }'`n}"
        $m = Put 'src/nested.ps1' $src
        $at = $src.IndexOf("'public")
        $c = [pscustomobject]@{ File = $m; Line = 2; StartOffset = $at; EndOffset = $at + 5; Description = 'nested' }
        (Get-PSMutationReloadFault -MutateFiles @($m) -TestFiles @() -Candidates @($c) -SandboxRoot $script:box) |
            Should-BeLikeString '*src/nested.ps1:2 has a mutant inside an Add-Type call (nested)*'
    }

    It 'counts a mutant at either edge of the Add-Type call as inside' {
        # The two comparisons are inclusive: a mutant spanning the whole call still changes it.
        $src = "Add-Type -TypeDefinition 'x'"
        $m = Put 'src/edge.ps1' $src
        $whole = [pscustomobject]@{ File = $m; Line = 1; StartOffset = 0; EndOffset = $src.Length; Description = 'whole' }
        (Get-PSMutationReloadFault -MutateFiles @($m) -TestFiles @() -Candidates @($whole) -SandboxRoot $script:box) |
            Should-BeLikeString '*(whole)*'
        $past = [pscustomobject]@{ File = $m; Line = 1; StartOffset = 0; EndOffset = $src.Length + 1; Description = 'past' }
        Should-BeNull -Actual (Get-PSMutationReloadFault -MutateFiles @($m) -TestFiles @() -Candidates @($past) -SandboxRoot $script:box)
    }

    It 'lists every fault, one per line' {
        $t1 = Put 'tests/a.Tests.ps1' 'using module ../src/M.psm1'
        $t2 = Put 'tests/b.Tests.ps1' 'using module ../src/M.psm1'
        $f = Get-PSMutationReloadFault -MutateFiles @($script:mod) -TestFiles @($t1, $t2) -Candidates @() -SandboxRoot $script:box
        @($f -split "`n" | Where-Object { $_ -like '  tests/*' }).Count | Should-Be 2
    }
}

Describe 'a mutant that does not parse (#252)' {
    # Parsed before it is written. One that does not parse fails its tests for a reason that has
    # nothing to do with them, and was scored a kill; now it is recorded CompileError without a
    # test run, through the same retirement as every other mutant.
    BeforeEach {
        $script:brokenFile = Join-Path $TestDrive "broken-$([System.Guid]::NewGuid().ToString('N')).ps1"
        $script:brokenText = 'function F { if ($x) { 1 } }'
        Set-Content -LiteralPath $script:brokenFile -Value $script:brokenText -NoNewline
        # Removes the closing brace of the function: what a statement-deletion operator gone
        # wrong would leave.
        $at = $script:brokenText.LastIndexOf('}')
        $script:brokenCand = [pscustomobject]@{
            Id = 1; File = $script:brokenFile; Line = 1; Operator = 'BinaryOperator'; Function = 'F'
            Description = '} -> '; StartOffset = $at; EndOffset = $at + 1; Mutated = ''
        }
    }

    It 'is recorded CompileError, with no test run and the file never written' {
        Mock Start-PSMutantEvaluation { throw 'a mutant that does not parse must not be run' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($script:brokenCand) `
            -TestsByFile @{} -AllTests @('t.ps1') -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        $r[0].Status | Should-Be 'CompileError'
        # Collected AT ONCE, not when its 5s budget runs out: a decided job is complete when it is
        # made. A job left incomplete, or a handle never set, would be found only by the clock.
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 2
        @($r[0].KilledBy).Count | Should-Be 0
        Should-Invoke Start-PSMutantEvaluation -Exactly 0
        [System.IO.File]::ReadAllText($script:brokenFile) | Should-Be $script:brokenText
    }

    It 'still runs a mutant that DOES parse' {
        # The pairing: a guard that refused everything would satisfy the case above.
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $ok = $script:brokenCand.PSObject.Copy()
        $ok.Mutated = ' }'
        $r = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($ok) `
            -TestsByFile @{} -AllTests @('t.ps1') -TimeoutSeconds 5 -SandboxRoot ([System.IO.Path]::GetTempPath()) -Quiet
        $r[0].Status | Should-Be 'Killed'
        Should-Invoke Start-PSMutantEvaluation -Exactly 1
    }

    It 'is collected by its verdict, without asking a runspace' {
        Mock Receive-PSMutationJob { throw 'must not be asked' }
        Mock Stop-PSMutationJob { throw 'must not be asked' }
        $job = New-PSMutationDecidedJob -Candidate $script:brokenCand -Source $script:brokenCand -Index 0 -WorkerId 0 `
            -OriginalContent $script:brokenText -Status 'CompileError'
        $job.Async.IsCompleted | Should-BeTrue
        $job.Async.AsyncWaitHandle.WaitOne(0) | Should-BeTrue
        Should-BeNull -Actual $job.Shell
        (Complete-PSMutantEvaluation -Job $job).Status | Should-Be 'CompileError'
        # Expired or not, a decided job's verdict stands: there is nothing running to stop.
        (Complete-PSMutantEvaluation -Job $job -Expired).Status | Should-Be 'CompileError'
    }
}

Describe 'each mutant runs under its own file''s deadline (#253)' {
    BeforeEach {
        $script:dlFile = Join-Path $TestDrive "dl-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $script:dlFile -Value 'function F { 1 -eq 1 }' -NoNewline
        $script:dlCand = [pscustomobject]@{ Id = 1; File = $script:dlFile; Line = 1; Operator = 'BinaryOperator'; Function = 'F'
            Description = '-eq -> -ne'; StartOffset = 15; EndOffset = 18; Mutated = '-ne' }
        function script:New-DeadlineContext { param([hashtable]$ByFile)
            [pscustomobject]@{ Candidates = @($script:dlCand); Originals = @{}; Roots = @($TestDrive); SandboxRoot = $TestDrive
                TestsByFile = @{}; AllTests = @('t.ps1'); TimeoutSeconds = 3600; TimeoutByFile = $ByFile; RecordAllKillers = $false
                Killers = New-PSMutationKillerMemory }
        }
    }

    It 'gives a dispatched mutant <Name>' -ForEach @(
        @{ Name = 'its file''s measured deadline'; ByFile = 'own'; Expected = 7 }
        @{ Name = 'the run-wide deadline when its file was not measured'; ByFile = 'none'; Expected = 3600 }
    ) {
        Mock Start-PSMutantEvaluation { StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        $map = ($ByFile -eq 'own') ? @{ $script:dlFile = 7 } : @{}
        $job = Start-PSMutationWorkerJob -Schedule ([pscustomobject]@{ Next = 0 }) -Context (New-DeadlineContext -ByFile $map) -WorkerId 0
        $job.TimeoutSeconds | Should-Be $Expected
    }

    It 'gives a mutant that does not parse a deadline too, so the sweep can read one' {
        $broken = $script:dlCand.PSObject.Copy()
        $broken.Mutated = '-ne ('
        $ctx = New-DeadlineContext -ByFile @{ $script:dlFile = 7 }
        $ctx.Candidates = @($broken)
        (Start-PSMutationWorkerJob -Schedule ([pscustomobject]@{ Next = 0 }) -Context $ctx -WorkerId 0).TimeoutSeconds | Should-Be 7
    }

    It 'expires a mutant on ITS deadline, not the run-wide one' {
        # 6 seconds in, under a 5-second deadline of its own and a run-wide one of an hour.
        $job = StubJob -Source $script:dlCand -Index 0 -Completed $false -Seconds 6 -TimeoutSeconds 5
        $sched = [pscustomobject]@{ InFlight = [object[]]@($job); Parked = @{}; Next = 1; Retired = 0 }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'TimedOut'; Killers = @() } }
        Complete-PSMutationSweep -Schedule $sched -Context ([pscustomobject]@{ TimeoutSeconds = 3600; SandboxRoot = $TestDrive })
        $sched.Parked.ContainsKey(0) | Should-BeTrue
        Should-Invoke Complete-PSMutantEvaluation -Exactly 1 -ParameterFilter { $Expired }
    }

    It 'carries the deadline a finished mutant ran under, for the stall check' {
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $job = StubJob -Source $script:dlCand -Index 0 -TimeoutSeconds 9
        (Get-PSMutationFinishedMutant -Job $job -State 'Complete' -SandboxRoot $TestDrive).TimeoutSeconds | Should-Be 9
    }
}

Describe 'Get-PSMutationFileSecond (#253)' {
    It 'gives each file its covering suite''s time, shared where files share a suite' {
        $c = @([pscustomobject]@{ File = 'a.ps1' }, [pscustomobject]@{ File = 'b.ps1' }, [pscustomobject]@{ File = 'c.ps1' })
        $map = @{ 'a.ps1' = @('x.Tests.ps1'); 'b.ps1' = @('x.Tests.ps1') }
        $by = Get-PSMutationFileSecond -Candidates $c -TestsByFile $map -AllTests @('all.Tests.ps1', 'x.Tests.ps1') `
            -SuiteSeconds @{ 'x.Tests.ps1' = 2.5; "all.Tests.ps1`nx.Tests.ps1" = 9.0 }
        "$($by['a.ps1'])/$($by['b.ps1'])/$($by['c.ps1'])" | Should-Be '2.5/2.5/9'
    }
}

Describe 'Wait-PSMutationWorker wakes for the soonest OWN deadline (#253)' {
    It 'looks again when a mutant''s own deadline runs out, not after the run-wide one' {
        # 0.9s into a 1s deadline of its own, under a run-wide one of 30s, and still running: the
        # scheduler must be back within a fraction of a second to cut it off, not 30 -- or 1.9,
        # which is what reading the deadline the wrong way round would give.
        $cand = [pscustomobject]@{ File = $script:stubFile }
        $job = StubJob -Source $cand -Completed $false -Seconds 0.9 -TimeoutSeconds 1
        $sched = [pscustomobject]@{ InFlight = [object[]]@($job) }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-PSMutationWorker -Schedule $sched -Context ([pscustomobject]@{ TimeoutSeconds = 30 })
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 0.8
    }

    It 'waits out the soonest deadline when its one worker runs in this process' {
        $job = StubJob -Source ([pscustomobject]@{ File = $script:stubFile }) -Completed $false -Seconds 0.5 -TimeoutSeconds 2
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-PSMutationWorker -Schedule ([pscustomobject]@{ InFlight = [object[]]@($job) }) `
            -Context ([pscustomobject]@{ TimeoutSeconds = 30; Process = $false })
        $sw.Elapsed.TotalSeconds | Should-BeGreaterThan 1.3
    }

    It 'looks again within a second when its workers are processes, whose death signals nothing (#256)' {
        $job = StubJob -Source ([pscustomobject]@{ File = $script:stubFile }) -Completed $false -Seconds 0 -TimeoutSeconds 5
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-PSMutationWorker -Schedule ([pscustomobject]@{ InFlight = [object[]]@($job) }) `
            -Context ([pscustomobject]@{ TimeoutSeconds = 30; Process = $true })
        $sw.Elapsed.TotalSeconds | Should-BeGreaterThan 0.9
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 2
    }
}

Describe 'covering tests marked per mutant where a class is under test (#270)' {
    # PowerShell caches a compiled script by its TEXT, and a type literal in it stays bound to the
    # first class it saw. Marking each covering test file per mutant changes the text, so the test
    # is recompiled against the class that mutant defines.
    BeforeEach {
        $script:mk = Join-Path $TestDrive "mk-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:mk | Out-Null
        function script:Put { param([string]$Name, [string]$Text)
            $p = Join-Path $script:mk $Name; [System.IO.File]::WriteAllText($p, $Text); return $p }
    }

    It 'knows a run that defines <Name>' -ForEach @(
        @{ Name = 'a class'; Code = 'class K { }'; Expected = $true }
        @{ Name = 'an enum'; Code = 'enum E { A }'; Expected = $true }
        @{ Name = 'a class inside a function body'; Code = 'function F { class N { } }'; Expected = $true }
        @{ Name = 'functions only'; Code = 'function F { 1 }'; Expected = $false }
    ) {
        $f = Put 'm.ps1' $Code
        Test-PSMutationDefinesType -Path @((Put 'other.ps1' 'function G { 2 }'), $f) | Should-Be $Expected
    }

    It 'is false for no files, and for a file that is not there' {
        Test-PSMutationDefinesType -Path @() | Should-BeFalse
        Test-PSMutationDefinesType -Path @((Join-Path $script:mk 'missing.ps1')) | Should-BeFalse
    }

    It 'appends the marker at the END, on its own line, and keeps the original bytes' {
        $t = Put 'a.Tests.ps1' "Describe 'a' {`n  It 'x' { 1 }`n}"
        $kept = Set-PSMutationTestMarker -Tests @($t) -Id '42'
        $now = [System.IO.File]::ReadAllText($t)
        $now | Should-BeLikeString "Describe 'a' {*  It 'x' { 1 }*}*# psmutant mutant 42 -- appended so PowerShell recompiles this file*"
        # Every original line is where it was, so no failure message points at another line.
        ($now -split "`n")[0..2] -join "`n" | Should-Be "Describe 'a' {`n  It 'x' { 1 }`n}"
        @($kept).Count | Should-Be 1
        $kept[0].Path | Should-Be $t
        [System.Text.Encoding]::UTF8.GetString($kept[0].Bytes) | Should-Be "Describe 'a' {`n  It 'x' { 1 }`n}"
    }

    It 'marks every covering file, each with the mutant''s own id' {
        $one = Put 'one.Tests.ps1' 'x'
        $two = Put 'two.Tests.ps1' 'y'
        $kept = Set-PSMutationTestMarker -Tests @($one, $two) -Id '7'
        @($kept).Count | Should-Be 2
        foreach ($p in $one, $two) { [System.IO.File]::ReadAllText($p) | Should-BeLikeString '*# psmutant mutant 7 *' }
    }

    It 'restores a marked test file byte for byte when the mutant is collected, even if it threw' {
        # A byte-order mark and no final newline: what ReadAllText/WriteAllText would not round-trip.
        $t = Join-Path $script:mk 'bom.Tests.ps1'
        $orig = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes("Describe 'b' { }"))
        [System.IO.File]::WriteAllBytes($t, $orig)
        $kept = Set-PSMutationTestMarker -Tests @($t) -Id '1'
        $src = Put 'src.ps1' 'function F { 1 }'
        $job = [pscustomobject]@{ WorkerId = 0; Shell = $null; Async = $null
            Candidate = [pscustomobject]@{ File = $src }; Source = $null; Index = 0; OriginalContent = 'function F { 1 }'
            Clock = $null; TestOriginals = @($kept) }
        Mock Receive-PSMutationJob { throw 'child exploded' }
        { Complete-PSMutantEvaluation -Job $job } | Should-Throw
        ([System.IO.File]::ReadAllBytes($t) -join ',') | Should-Be ($orig -join ',')
    }

    It 'marks the tests a dispatched mutant runs only when the run asks for it' -ForEach @(
        @{ Mark = $true }
        @{ Mark = $false }
    ) {
        $t = Put 'c.Tests.ps1' 'Describe c { }'
        $f = Put 'c.ps1' 'function F { 1 -eq 1 }'
        $cand = [pscustomobject]@{ Id = 3; File = $f; Line = 1; Operator = 'BinaryOperator'; Function = 'F'
            Description = '-eq -> -ne'; StartOffset = 15; EndOffset = 18; Mutated = '-ne' }
        $script:seenTest = $null
        Mock Start-PSMutantEvaluation { $script:seenTest = [System.IO.File]::ReadAllText($CoveringTests[0]); StubJob -Source $Source -Index $Index -WorkerId $WorkerId }
        $ctx = [pscustomobject]@{ Candidates = @($cand); Originals = @{}; Roots = @($script:mk); SandboxRoot = $script:mk
            TestsByFile = @{ $f = @($t) }; AllTests = @($t); TimeoutSeconds = 30; TimeoutByFile = @{}; RecordAllKillers = $false; MarkTests = $Mark
            Killers = New-PSMutationKillerMemory }
        $job = Start-PSMutationWorkerJob -Schedule ([pscustomobject]@{ Next = 0 }) -Context $ctx -WorkerId 0
        if ($Mark) {
            $script:seenTest | Should-BeLikeString '*# psmutant mutant 3 *'
            @($job.TestOriginals).Count | Should-Be 1
        }
        else {
            $script:seenTest | Should-Be 'Describe c { }'
            @($job.TestOriginals).Count | Should-Be 0
        }
    }

    It 'decides to mark from the candidates the loop is given' {
        $cls = Put 'cls.ps1' 'class Q { [int] V() { return 1 -eq 1 } }'
        $cand = [pscustomobject]@{ Id = 1; File = $cls; Line = 1; Operator = 'BinaryOperator'; Function = 'V'
            Description = 'x'; StartOffset = 0; EndOffset = 1; Mutated = 'c' }
        Mock Start-PSMutationWorkerJob { $script:ctxSeen = $Context; StubJob -Source $cand -Index 0 }
        Mock Complete-PSMutantEvaluation { [pscustomobject]@{ Status = 'Killed'; Killers = @() } }
        $null = Invoke-PSMutationLoop -TimeoutRule ([pscustomobject]@{ Factor = 4; Floor = 15 }) -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates @($cand) `
            -TestsByFile @{} -AllTests @('t.ps1') -TimeoutSeconds 5 -SandboxRoot $script:mk -Quiet
        $script:ctxSeen.MarkTests | Should-BeTrue
    }
}

Describe 'the tests that killed a neighbour run first (#254)' {
    # Real worker runspaces running a stub child. The stub logs whether every killer was asked for
    # ('all' -- a proof, here), the names it was told to run, and the source it saw; and answers by
    # name: 'D.alone' passes alone, 'D.needs' fails alone (it depends on another test), a mutant
    # spelled with a K is killed by both in a whole run and by any name tried first, one with an H
    # hangs a first pass, and one with a Q is killed by 'D.alone' alone.
    BeforeEach {
        $script:kfSrc = Join-Path $TestDrive "kf-$([System.Guid]::NewGuid().ToString('N')).ps1"
        $script:kfLog = "$script:kfSrc.log"
        Set-Content -LiteralPath $script:kfSrc -Value 'x' -NoNewline
        $script:kfStub = @"
param(`$tests, `$recordAllKillers, `$sandboxRoot, `$filter)
`$src = [System.IO.File]::ReadAllText('$script:kfSrc')
`$named = @(`$filter).Count -gt 0
Add-Content -LiteralPath '$script:kfLog' -Value ('{0}|{1}|{2}' -f (`$recordAllKillers ? 'all' : 'one'), (@(`$filter) -join ','), `$src)
if (`$named -and `$recordAllKillers) {
    if (`$src -eq 'slow') { Start-Sleep -Seconds 30 }
    return [pscustomobject]@{ Result = 'Failed'; Ran = 2; Killers = @(); FailedPath = @('D.needs'); PassedPath = @('D.alone') }
}
if (`$named -and `$src -like '*H*') { Start-Sleep -Seconds 30 }
if (`$named -and `$src -like '*K*') {
    return [pscustomobject]@{ Result = 'Failed'; Ran = 1; Killers = @('alone'); FailedPath = @(`$filter)[0]; PassedPath = @() }
}
if (`$named) { return [pscustomobject]@{ Result = 'Passed'; Ran = 1; Killers = @(); FailedPath = @(); PassedPath = @(`$filter) } }
if (`$src -like '*Q*') {
    return [pscustomobject]@{ Result = 'Failed'; Ran = 1; Killers = @('alone'); FailedPath = @('D.alone'); PassedPath = @() }
}
if (`$src -like '*K*') {
    return [pscustomobject]@{ Result = 'Failed'; Ran = 2; Killers = @('alone', 'needs'); FailedPath = @('D.alone', 'D.needs'); PassedPath = @() }
}
[pscustomobject]@{ Result = 'Passed'; Ran = 2; Killers = @(); FailedPath = @(); PassedPath = @('D.alone', 'D.needs') }
"@
        Mock Get-PSMutationWarmPesterScript { $script:kfStub }
        function script:KfCand { param([int]$Id, [string]$Text, [string]$Function = 'F')
            [pscustomobject]@{ Id = $Id; Function = $Function; File = $script:kfSrc; Line = 1; Operator = 'BinaryOperator'
                Description = "x -> $Text"; StartOffset = 0; EndOffset = 1; Mutated = $Text }
        }
        function script:KfLoop { param([object[]]$Cands, [int]$Timeout = 30, [switch]$All, [bool]$On = $true, $Rule = [pscustomobject]@{ Factor = 4; Floor = 15 })
            Invoke-PSMutationLoop -Sink ([System.Collections.Generic.List[object]]::new()) -Candidates $Cands `
                -TestsByFile @{} -AllTests @((Join-Path $TestDrive 'all.Tests.ps1')) -TimeoutSeconds $Timeout `
                -SandboxRoot $TestDrive -Quiet -RecordAllKillers:$All -KillersFirst $On -TimeoutRule $Rule
        }
        function script:KfLog { @(Get-Content -LiteralPath $script:kfLog) }
    }
    AfterEach { Close-PSMutationWarmRunspacePool }

    It 'proves what a kill taught on unmutated source, then tries only the proven test first' {
        $r = KfLoop @((KfCand 1 'K1'), (KfCand 2 'K2'), (KfCand 3 'S'))
        @($r | ForEach-Object Status) | Should-BeCollection @('Killed', 'Killed', 'Survived')
        # The second kill came from the first test alone, and is named by it.
        @($r[1].KilledBy) | Should-BeCollection @('alone')
        # Proved between mutants, against the source as it was before any of them; 'D.needs' failed
        # alone and is never tried; the survivor's first test passed, so its whole files ran after.
        KfLog | Should-BeCollection @('one||K1', 'all|D.alone,D.needs|x', 'one|D.alone|K2', 'one|D.alone|S', 'one||S')
    }

    It 'proves a single learned name too' {
        # One killer is one name waiting, and a proof starts for it.
        $null = KfLoop @((KfCand 1 'Q1'), (KfCand 2 'K2'))
        KfLog | Should-BeCollection @('one||Q1', 'all|D.alone|x', 'one|D.alone|K2')
    }

    It 'proves a name once, however many mutants it kills' {
        $null = KfLoop @((KfCand 1 'K1'), (KfCand 2 'K2'), (KfCand 3 'K3'))
        @(KfLog | Where-Object { $_ -like 'all*' }).Count | Should-Be 1
    }

    It 'does none of it when <Why>' -ForEach @(
        @{ Why = 'every killer is recorded'; All = $true; On = $true; Kind = 'all' }
        @{ Why = 'the config turns it off'; All = $false; On = $false; Kind = 'one' }
    ) {
        $r = KfLoop @((KfCand 1 'K1'), (KfCand 2 'K2')) -All:$All -On $On
        @($r | ForEach-Object Status) | Should-BeCollection @('Killed', 'Killed')
        KfLog | Should-BeCollection @("$Kind||K1", "$Kind||K2")
    }

    It 'trusts nothing from a proof that ran out of time, and still finishes the run' {
        # The source reads 'slow' between mutants here, so the proof hangs and is cut off.
        Set-Content -LiteralPath $script:kfSrc -Value 'slow' -NoNewline
        $c1 = KfCand 1 'K1'; $c1.EndOffset = 4
        $c2 = KfCand 2 'K2'; $c2.EndOffset = 4
        $r = KfLoop @($c1, $c2) -Timeout 2
        @($r | ForEach-Object Status) | Should-BeCollection @('Killed', 'Killed')
        KfLog | Should-BeCollection @('one||K1', 'all|D.alone,D.needs|slow', 'one||K2')
    }

    It 'cuts off a first pass that hangs, on its own short deadline, and lets the whole files decide' {
        # The first pass is sized from the proof -- here the floor, one second -- not from the
        # mutant's own deadline, and its expiry is not a TimedOut verdict: the whole run kills it.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = KfLoop @((KfCand 1 'K1'), (KfCand 2 'KH2')) -Rule ([pscustomobject]@{ Factor = 1; Floor = 1 })
        $sw.Elapsed.TotalSeconds | Should-BeLessThan 20
        @($r | ForEach-Object Status) | Should-BeCollection @('Killed', 'Killed')
        KfLog | Should-BeCollection @('one||K1', 'all|D.alone,D.needs|x', 'one|D.alone|KH2', 'one||KH2')
    }

    It 'stops proving once every mutant has been dispatched' {
        # The last mutant's kill teaches something nobody is left to use.
        $null = KfLoop @((KfCand 1 'K1'))
        KfLog | Should-BeCollection @('one||K1')
    }
}
