# Dependency-aware task runner shared by Download-Sources.ps1 (download
# pipeline) and Build-Reproduce.ps1 (build pipeline).
#
# Every task body runs in its own thread job: same pwsh process, but its own
# runspace and working directory, so independent tasks can run concurrently
# without sharing state. The parent passes plain arguments in, and the body
# hands its result back through a file (see -Args / result files in the
# callers). The body is compiled from text inside the job, so it cannot see the
# caller's scope by accident; -Prelude is prepended to every body and normally
# dot-sources the shared helper scripts. Both the prelude and the bodies may
# reference $Shared, the single context object every job receives.
#
#   $graph = [ordered]@{
#       build-a = @{ Depends = @();        Body = { ... }; Args = @('a') }
#       build-b = @{ Depends = @('build-a'); Body = { ... }; Args = @('b') }
#   }
#   Invoke-TaskGraph -Tasks $graph -Prelude $prelude -Shared $shared -ThrottleLimit 4 `
#       -OnLine { param($task, $line) ... } -OnTaskEvent { param($task, $event, $detail) ... }
#
# A task starts as soon as every task in Depends has completed and a slot is
# free. The first failure stops scheduling, cancels the tasks still running and
# throws. Events: 'start', 'completed' ($detail = duration), 'failed'
# ($detail = error text); -OnLine receives every output line of a running task.

function Invoke-TaskGraph {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Tasks,
        [Parameter(Mandatory)][string]$Prelude,
        $Shared,
        [int]$ThrottleLimit = 2,
        [scriptblock]$OnLine,
        [scriptblock]$OnTaskEvent
    )
    $names = @($Tasks.Keys)
    if (!$names.Count) { throw 'Invoke-TaskGraph: no tasks.' }
    if ($ThrottleLimit -lt 1) { throw 'Invoke-TaskGraph: ThrottleLimit must be >= 1.' }
    foreach ($name in $names) {
        $depends = @($Tasks[$name].Depends)
        if ($name -in $depends) { throw "Invoke-TaskGraph: task '$name' depends on itself." }
        foreach ($dep in $depends) {
            if ($dep -notin $names) { throw "Invoke-TaskGraph: task '$name' depends on unknown task '$dep'." }
        }
    }
    # param() must lead the wrapper text (later it would run as a command
    # named "param"); the prelude follows it as plain statements.
    $wrapperText = @'
param([string]$BodyText, [object[]]$TaskArgs, $Shared)
'@ + $Prelude + @'

$__body = [scriptblock]::Create($BodyText)
& $__body @TaskArgs *>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.InformationRecord]) { "$($_.MessageData)" } else { "$_" }
}
'@
    $wrapper = [scriptblock]::Create($wrapperText)
    $pending = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) { $pending.Add($name) }
    $running = [ordered]@{}
    $results = [ordered]@{}
    $failure = $null
    # One line at a time: a single output record may span several lines, and
    # the log files must stay free of ANSI escapes and record decorations.
    function Send-TaskLine([string]$Task, $Record) {
        if (!$OnLine) { return }
        $text = if ($Record -is [System.Management.Automation.InformationRecord]) { "$($Record.MessageData)" } else { "$Record" }
        foreach ($line in ($text -split "`r?`n")) { & $OnLine $Task $line }
    }
    function Drain-TaskOutput($Entry, [string]$Task) {
        foreach ($record in @(Receive-Job -Job $Entry.Job -ErrorAction SilentlyContinue)) { Send-TaskLine $Task $record }
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (($pending.Count -or $running.Count) -and !$failure) {
        foreach ($name in @($pending)) {
            if ($running.Count -ge $ThrottleLimit) { break }
            $depends = @($Tasks[$name].Depends | Where-Object { $_ -notin $results.Keys })
            if ($depends.Count) { continue }
            $task = $Tasks[$name]
            $bodyText = if ($task.Body -is [scriptblock]) { $task.Body.ToString() } else { [string]$task.Body }
            $taskArgs = @($task.Args)
            if ($OnTaskEvent) { & $OnTaskEvent $name 'start' $null }
            $job = Start-ThreadJob -Name $name -ScriptBlock $wrapper -ArgumentList $bodyText, $taskArgs, $Shared
            $running[$name] = [pscustomobject]@{
                Job = $job
                Timer = [Diagnostics.Stopwatch]::StartNew()
                Failure = $null
            }
            $pending.Remove($name)
        }
        if (!$running.Count) {
            if ($pending.Count) { throw "Invoke-TaskGraph: cannot schedule $($pending -join ', ') (dependency cycle?)." }
            break
        }
        Start-Sleep -Milliseconds 200
        foreach ($name in @($running.Keys)) {
            $entry = $running[$name]
            Drain-TaskOutput $entry $name
            if ($entry.Job.State -in @('Completed', 'Failed', 'Stopped')) {
                Drain-TaskOutput $entry $name
                if ($entry.Job.State -ne 'Completed') {
                    # The exception lands on the top-level job, and the reason
                    # can still be empty; the error streams then carry it.
                    $reason = $entry.Job.JobStateInfo.Reason
                    if (!$reason) { $reason = $entry.Job.ChildJobs[0].JobStateInfo.Reason }
                    $text = if ($reason) { "$($reason.Message)".Trim() } else {
                        $records = @(foreach ($record in (@($entry.Job.Error) + @($entry.Job.ChildJobs[0].Error))) { "$record".Trim() })
                        (@($records | Where-Object { $_ }) -join '; ')
                    }
                    $entry.Failure = if ($text) { $text } else { "task ended in state $($entry.Job.State)" }
                }
                $entry.Timer.Stop()
                Remove-Job -Job $entry.Job -Force
                $running.Remove($name)
                $results[$name] = [pscustomobject]@{ Duration = $entry.Timer.Elapsed; Failure = $entry.Failure }
                if ($entry.Failure) {
                    $failure = "Task '$name' failed: $($entry.Failure)"
                    if ($OnTaskEvent) { & $OnTaskEvent $name 'failed' $entry.Failure }
                } elseif ($OnTaskEvent) {
                    & $OnTaskEvent $name 'completed' $entry.Timer.Elapsed
                }
            }
        }
    }
    if ($failure) {
        # Fail fast: cancel the tasks still running, but keep whatever output
        # they already produced so their logs stay complete.
        foreach ($name in @($running.Keys)) {
            $entry = $running[$name]
            Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
            Drain-TaskOutput $entry $name
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
            $running.Remove($name)
        }
        throw $failure
    }
    $stopwatch.Stop()
    return [pscustomobject]@{ Results = $results; Elapsed = $stopwatch.Elapsed }
}
