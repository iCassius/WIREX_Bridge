$ErrorActionPreference = 'Stop'

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "ASSERT FAILED: $message" }
}

function Wait-Until([scriptblock]$predicate, [int]$timeoutMilliseconds, [string]$message) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        if (& $predicate) { return }
        Start-Sleep -Milliseconds 20
    }
    throw "Timed out: $message"
}

function Assert-OwnedHandlesClosed($supervisor) {
    foreach ($name in @('processHandle', 'threadHandle', 'jobHandle', 'standardInputWrite', 'standardOutputRead', 'standardErrorRead')) {
        $field = $supervisor.GetType().GetField($name, [Reflection.BindingFlags]'Instance,NonPublic')
        Assert-True ($null -ne $field) "expected private field $name"
        Assert-True ($field.GetValue($supervisor) -eq [IntPtr]::Zero) "$name must be zero after Dispose"
    }
    foreach ($name in @('standardOutputPump', 'standardErrorPump')) {
        $field = $supervisor.GetType().GetField($name, [Reflection.BindingFlags]'Instance,NonPublic')
        Assert-True ($null -ne $field) "expected private field $name"
        Assert-True ($null -eq $field.GetValue($supervisor)) "$name must be released after Dispose"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'ui\windows\BridgeSupervisor.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing source: $source" }
$supervisorSource = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)

$raceFixtureSource = @'
public static class SupervisorRaceFixture
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GetProcessHandleCount(System.IntPtr process, out uint count);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern System.IntPtr GetCurrentProcess();

    public static uint CurrentHandleCount()
    {
        uint count;
        if (!GetProcessHandleCount(GetCurrentProcess(), out count))
            throw new System.InvalidOperationException("GetProcessHandleCount failed.");
        return count;
    }

    public static string RaceStartAndDispose(WirexBridge.Ui.BridgeSupervisor supervisor, string executable,
        string[] arguments, string workingDirectory)
    {
        System.Threading.ManualResetEvent ready = new System.Threading.ManualResetEvent(false);
        System.Threading.ManualResetEvent go = new System.Threading.ManualResetEvent(false);
        System.Exception startFailure = null;
        System.Exception disposeFailure = null;
        System.Threading.Thread startThread = new System.Threading.Thread(delegate()
        {
            ready.Set();
            go.WaitOne();
            try { supervisor.Start(executable, arguments, workingDirectory); }
            catch (System.Exception ex) { startFailure = ex; }
        });
        System.Threading.Thread disposeThread = new System.Threading.Thread(delegate()
        {
            ready.WaitOne();
            go.WaitOne();
            try { supervisor.Dispose(); }
            catch (System.Exception ex) { disposeFailure = ex; }
        });
        startThread.IsBackground = true;
        disposeThread.IsBackground = true;
        startThread.Start();
        disposeThread.Start();
        if (!ready.WaitOne(3000)) throw new System.TimeoutException("Race threads did not become ready.");
        go.Set();
        if (!startThread.Join(10000)) throw new System.TimeoutException("Start did not finish in race fixture.");
        if (!disposeThread.Join(10000)) throw new System.TimeoutException("Dispose did not finish in race fixture.");
        ready.Dispose();
        go.Dispose();
        if (disposeFailure != null) throw new System.InvalidOperationException("Dispose failed in race fixture.", disposeFailure);
        if (startFailure != null && !(startFailure is System.ObjectDisposedException))
            throw new System.InvalidOperationException("Start failed unexpectedly in race fixture.", startFailure);
        return startFailure == null ? "started" : "disposed-first";
    }

    public static void DisposeConcurrently(WirexBridge.Ui.BridgeSupervisor supervisor)
    {
        System.Exception failure = null;
        System.Threading.Thread thread = new System.Threading.Thread(delegate()
        {
            try { supervisor.Dispose(); }
            catch (System.Exception ex) { failure = ex; }
        });
        thread.IsBackground = true;
        thread.Start();
        if (!thread.Join(7000)) throw new System.TimeoutException("Concurrent Dispose did not finish.");
        if (failure != null) throw new System.InvalidOperationException("Concurrent Dispose failed.", failure);
    }

    public static void ReadStatusWhileDispose(WirexBridge.Ui.BridgeSupervisor supervisor)
    {
        System.Threading.ManualResetEvent done = new System.Threading.ManualResetEvent(false);
        System.Exception failure = null;
        System.Threading.Thread reader = new System.Threading.Thread(delegate()
        {
            try
            {
                while (!done.WaitOne(0))
                {
                    bool started = supervisor.IsStarted;
                    bool exited = supervisor.HasExited;
                    int processId = supervisor.ProcessId;
                    int exitCode;
                    supervisor.TryGetExitCode(out exitCode);
                }
            }
            catch (System.Exception ex) { failure = ex; }
        });
        reader.IsBackground = true;
        reader.Start();
        supervisor.Dispose();
        done.Set();
        if (!reader.Join(3000)) throw new System.TimeoutException("Status reader did not finish.");
        done.Dispose();
        if (failure != null) throw new System.InvalidOperationException("Status read raced Dispose unsafely.", failure);
    }
}
'@
Add-Type -TypeDefinition ($supervisorSource + "`r`n" + $raceFixtureSource)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('wirex-supervisor-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $fixturePath = Join-Path $tempRoot 'child-fixture.ps1'
    $fixtureText = @'
$line = [Console]::In.ReadLine()
if ($null -eq $line) { [Console]::Out.WriteLine('FIXTURE-EOF'); exit 17 }
if ($line -eq 'Q') { [Console]::Out.WriteLine('FIXTURE-Q'); exit 23 }
while ($null -ne $line) { $line = [Console]::In.ReadLine() }
[Console]::Out.WriteLine('FIXTURE-EOF')
exit 17
'@
    [IO.File]::WriteAllText($fixturePath, $fixtureText, (New-Object System.Text.UTF8Encoding($false)))

    $hangFixturePath = Join-Path $tempRoot 'child-hang.ps1'
    $hangText = @'
[Console]::Out.WriteLine('FIXTURE-READY')
Start-Sleep -Seconds 60
'@
    [IO.File]::WriteAllText($hangFixturePath, $hangText, (New-Object System.Text.UTF8Encoding($false)))

    $unicodeFixturePath = Join-Path $tempRoot 'child-unicode.ps1'
    $unicodeText = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$glyph = [string][char]0x754c
[Console]::Out.Write(($glyph * 6000) + 'TAIL-END-' + [char]0x4e2d + [char]0x6587)
$line = [Console]::In.ReadLine()
if ($line -eq 'Q') { exit 23 }
exit 17
'@
    [IO.File]::WriteAllText($unicodeFixturePath, $unicodeText, (New-Object System.Text.UTF8Encoding($false)))

    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw "Missing Windows PowerShell executable: $powershell" }
    $fixtureArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fixturePath)
    $hangArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $hangFixturePath)
    $unicodeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $unicodeFixturePath)

    # A stop request permanently closes this single-use supervisor to future starts.
    $stoppedBeforeStart = New-Object WirexBridge.Ui.BridgeSupervisor
    $stoppedBeforeStart.StopAsync(0).GetAwaiter().GetResult() | Out-Null
    $startAfterStopRejected = $false
    try { $stoppedBeforeStart.Start($powershell, $fixtureArgs, $tempRoot) }
    catch [InvalidOperationException] { $startAfterStopRejected = $true }
    Assert-True $startAfterStopRejected 'Start after a stop request must be rejected'
    $stoppedBeforeStart.Dispose()
    Assert-OwnedHandlesClosed $stoppedBeforeStart

    # Graceful Q: child exits with its distinct fixture status and its output reaches the bounded tail.
    $graceful = New-Object WirexBridge.Ui.BridgeSupervisor
    $graceful.Start($powershell, $fixtureArgs, $tempRoot)
    Assert-True $graceful.IsStarted 'Start must publish the owned process handle'
    $gracefulExit = $graceful.StopAsync(4000).GetAwaiter().GetResult()
    Assert-True ($gracefulExit -eq 23) 'Q must reach the fixture and preserve its exit code'
    Wait-Until { $graceful.DiagnosticTail.Contains('FIXTURE-Q') } 3000 'graceful output drain'
    Assert-True ($graceful.DiagnosticTail.Length -le 16384) 'diagnostic tail must remain bounded'
    $graceful.Dispose()
    Assert-OwnedHandlesClosed $graceful
    $graceful.Dispose()

    # EOF: closing stdin is itself a valid orderly shutdown path.
    $eof = New-Object WirexBridge.Ui.BridgeSupervisor
    $eof.Start($powershell, $fixtureArgs, $tempRoot)
    $eof.CloseControlInput()
    $eofExit = $eof.StopAsync(4000).GetAwaiter().GetResult()
    Assert-True ($eofExit -eq 17) 'closing control input must deliver EOF to the fixture'
    Wait-Until { $eof.DiagnosticTail.Contains('FIXTURE-EOF') } 3000 'EOF output drain'
    $eof.Dispose()
    Assert-OwnedHandlesClosed $eof

    # The output pump must preserve UTF-8 code points split across native pipe reads.
    $unicode = New-Object WirexBridge.Ui.BridgeSupervisor
    $unicode.Start($powershell, $unicodeArgs, $tempRoot)
    $unicodeMarker = 'TAIL-END-' + [string][char]0x4e2d + [char]0x6587
    Wait-Until { $unicode.DiagnosticTail.Contains($unicodeMarker) } 4000 'unicode output tail'
    Assert-True (-not $unicode.DiagnosticTail.Contains([string][char]0xfffd)) 'chunked UTF-8 diagnostics must not contain replacement characters'
    Assert-True ($unicode.DiagnosticTail.Length -le 16384) 'unicode diagnostic tail must remain bounded'
    $unicode.StopAsync(4000).GetAwaiter().GetResult() | Out-Null
    $unicode.Dispose()
    Assert-OwnedHandlesClosed $unicode

    # Force path: the fixture ignores stdin; job close must terminate it within a bounded interval.
    $forced = New-Object WirexBridge.Ui.BridgeSupervisor
    $forced.Start($powershell, $hangArgs, $tempRoot)
    Wait-Until { $forced.DiagnosticTail.Contains('FIXTURE-READY') } 4000 'force fixture ready'
    $forceWatch = [Diagnostics.Stopwatch]::StartNew()
    $forceTask = $forced.StopAsync(100)
    Assert-True $forceTask.Wait(5000) 'force stop task must finish within its bounded waits'
    Assert-True $forced.HasExited 'force stop must leave the child exited'
    Assert-True ($forceWatch.ElapsedMilliseconds -lt 5000) 'force stop must remain bounded'
    $forced.Dispose()
    Assert-OwnedHandlesClosed $forced

    # Repeated stop calls share one task and stay nonblocking while the first stop waits.
    $concurrent = New-Object WirexBridge.Ui.BridgeSupervisor
    $concurrent.Start($powershell, $hangArgs, $tempRoot)
    Wait-Until { $concurrent.DiagnosticTail.Contains('FIXTURE-READY') } 4000 'concurrent fixture ready'
    $firstStop = $concurrent.StopAsync(1200)
    $repeatWatch = [Diagnostics.Stopwatch]::StartNew()
    $secondStop = $concurrent.StopAsync(0)
    Assert-True ([Object]::ReferenceEquals($firstStop, $secondStop)) 'concurrent StopAsync calls must share one task'
    Assert-True ($repeatWatch.ElapsedMilliseconds -lt 500) 'repeated StopAsync must not wait for the grace period'
    [SupervisorRaceFixture]::DisposeConcurrently($concurrent)
    Assert-True $firstStop.Wait(5000) 'concurrent stop must finish'
    Assert-OwnedHandlesClosed $concurrent

    # Dispose racing Start either wins before process creation or waits and kills the created child.
    for ($index = 0; $index -lt 6; $index++) {
        $raced = New-Object WirexBridge.Ui.BridgeSupervisor
        $outcome = [SupervisorRaceFixture]::RaceStartAndDispose($raced, $powershell, $hangArgs, $tempRoot)
        Assert-OwnedHandlesClosed $raced
        Assert-True ($outcome -eq 'started' -or $outcome -eq 'disposed-first') 'Start/Dispose race must have one serialized outcome'
    }

    $statusRace = New-Object WirexBridge.Ui.BridgeSupervisor
    $statusRace.Start($powershell, $hangArgs, $tempRoot)
    Wait-Until { $statusRace.DiagnosticTail.Contains('FIXTURE-READY') } 4000 'status race fixture ready'
    [SupervisorRaceFixture]::ReadStatusWhileDispose($statusRace)
    Assert-OwnedHandlesClosed $statusRace

    # Multiple independent runs must return owned native handles to the process baseline.
    $warm = New-Object WirexBridge.Ui.BridgeSupervisor
    $warm.Start($powershell, $fixtureArgs, $tempRoot)
    $warm.StopAsync(4000).GetAwaiter().GetResult() | Out-Null
    $warm.Dispose()
    Start-Sleep -Milliseconds 250
    $handleBaseline = [SupervisorRaceFixture]::CurrentHandleCount()
    for ($index = 0; $index -lt 8; $index++) {
        $cycle = New-Object WirexBridge.Ui.BridgeSupervisor
        $cycle.Start($powershell, $fixtureArgs, $tempRoot)
        $cycle.StopAsync(4000).GetAwaiter().GetResult() | Out-Null
        $cycle.Dispose()
        Assert-OwnedHandlesClosed $cycle
    }
    Start-Sleep -Milliseconds 500
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $handleAfterCycles = [SupervisorRaceFixture]::CurrentHandleCount()
    Assert-True ($handleAfterCycles -le ($handleBaseline + 4)) "native handle count grew from $handleBaseline to $handleAfterCycles across repeated runs"

    Write-Output 'PASS ui supervisor lifecycle: graceful Q, EOF, timeout force, concurrent stop/dispose, start/dispose race, repeated handle count'
    Write-Output ("handle-count baseline={0}, after={1}" -f $handleBaseline, $handleAfterCycles)
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
