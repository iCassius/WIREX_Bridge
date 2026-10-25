using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace WirexBridge.Ui
{
    public sealed class BridgeSupervisor : IDisposable
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const uint WaitObject0 = 0;
        private const uint WaitTimeout = 258;
        private const uint Infinite = 0xffffffff;
        private const int DiagnosticLimit = 16 * 1024;

        private readonly object gate = new object();
        private readonly object lifecycleGate = new object();
        private readonly StringBuilder diagnosticTail = new StringBuilder();
        private IntPtr processHandle = IntPtr.Zero;
        private IntPtr threadHandle = IntPtr.Zero;
        private IntPtr jobHandle = IntPtr.Zero;
        private IntPtr standardInputWrite = IntPtr.Zero;
        private IntPtr standardOutputRead = IntPtr.Zero;
        private IntPtr standardErrorRead = IntPtr.Zero;
        private Thread standardOutputPump;
        private Thread standardErrorPump;
        private int processId;
        private bool disposed;
        private Task<int> stopTask;

        public int ProcessId { get { lock (gate) { return processId; } } }
        public bool IsStarted { get { lock (gate) { return processHandle != IntPtr.Zero; } } }

        public string DiagnosticTail
        {
            get { lock (gate) { return diagnosticTail.ToString(); } }
        }

        public void Start(string executable, string[] arguments, string workingDirectory)
        {
            lock (lifecycleGate) StartCore(executable, arguments, workingDirectory);
        }

        private void StartCore(string executable, string[] arguments, string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(executable)) throw new ArgumentException("Executable path is required.", "executable");
            if (arguments == null) throw new ArgumentNullException("arguments");
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("BridgeSupervisor");
                if (stopTask != null) throw new InvalidOperationException("A stop request has already been issued for this supervisor.");
                if (processHandle != IntPtr.Zero) throw new InvalidOperationException("This supervisor already owns a child process.");
            }

            IntPtr childInputRead = IntPtr.Zero;
            IntPtr childOutputWrite = IntPtr.Zero;
            IntPtr childErrorWrite = IntPtr.Zero;
            IntPtr parentInputWrite = IntPtr.Zero;
            IntPtr parentOutputRead = IntPtr.Zero;
            IntPtr parentErrorRead = IntPtr.Zero;
            IntPtr localJob = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            try
            {
                SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
                security.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                security.bInheritHandle = true;

                if (!CreatePipe(out childInputRead, out parentInputWrite, ref security, 0)) ThrowLastError("CreatePipe(stdin)");
                if (!SetHandleInformation(parentInputWrite, HandleFlagInherit, 0)) ThrowLastError("SetHandleInformation(stdin)");
                if (!CreatePipe(out parentOutputRead, out childOutputWrite, ref security, 0)) ThrowLastError("CreatePipe(stdout)");
                if (!SetHandleInformation(parentOutputRead, HandleFlagInherit, 0)) ThrowLastError("SetHandleInformation(stdout)");
                if (!CreatePipe(out parentErrorRead, out childErrorWrite, ref security, 0)) ThrowLastError("CreatePipe(stderr)");
                if (!SetHandleInformation(parentErrorRead, HandleFlagInherit, 0)) ThrowLastError("SetHandleInformation(stderr)");

                localJob = CreateJobObject(IntPtr.Zero, null);
                if (localJob == IntPtr.Zero) ThrowLastError("CreateJobObject");
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                int limitsSize = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr limitsBuffer = Marshal.AllocHGlobal(limitsSize);
                try
                {
                    Marshal.StructureToPtr(limits, limitsBuffer, false);
                    if (!SetInformationJobObject(localJob, JobObjectExtendedLimitInformation, limitsBuffer, (uint)limitsSize)) {
                        ThrowLastError("SetInformationJobObject");
                    }
                }
                finally { Marshal.FreeHGlobal(limitsBuffer); }

                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = StartfUseStdHandles;
                startup.hStdInput = childInputRead;
                startup.hStdOutput = childOutputWrite;
                startup.hStdError = childErrorWrite;
                StringBuilder commandLine = new StringBuilder(BuildCommandLine(executable, arguments));
                string currentDirectory = String.IsNullOrWhiteSpace(workingDirectory) ? null : workingDirectory;
                if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                                   CreateSuspended | CreateNoWindow, IntPtr.Zero, currentDirectory,
                                   ref startup, out process)) {
                    ThrowLastError("CreateProcessW");
                }
                CloseHandleIfValid(childInputRead);
                childInputRead = IntPtr.Zero;
                CloseHandleIfValid(childOutputWrite);
                childOutputWrite = IntPtr.Zero;
                CloseHandleIfValid(childErrorWrite);
                childErrorWrite = IntPtr.Zero;
                if (!AssignProcessToJobObject(localJob, process.hProcess)) ThrowLastError("AssignProcessToJobObject");
                if (ResumeThread(process.hThread) == UInt32.MaxValue) ThrowLastError("ResumeThread");

                lock (gate)
                {
                    processHandle = process.hProcess;
                    threadHandle = process.hThread;
                    jobHandle = localJob;
                    standardInputWrite = parentInputWrite;
                    standardOutputRead = parentOutputRead;
                    standardErrorRead = parentErrorRead;
                    processId = unchecked((int)process.dwProcessId);
                }
                process.hProcess = IntPtr.Zero;
                process.hThread = IntPtr.Zero;
                localJob = IntPtr.Zero;
                parentInputWrite = IntPtr.Zero;
                parentOutputRead = IntPtr.Zero;
                parentErrorRead = IntPtr.Zero;
                StartPumpThreads();
            }
            catch
            {
                if (process.hProcess != IntPtr.Zero) TerminateProcess(process.hProcess, 2);
                if (localJob != IntPtr.Zero) { CloseHandle(localJob); localJob = IntPtr.Zero; }
                else if (IsStarted) Dispose();
                CloseHandleIfValid(process.hThread);
                CloseHandleIfValid(process.hProcess);
                throw;
            }
            finally
            {
                CloseHandleIfValid(childInputRead);
                CloseHandleIfValid(childOutputWrite);
                CloseHandleIfValid(childErrorWrite);
                CloseHandleIfValid(parentInputWrite);
                CloseHandleIfValid(parentOutputRead);
                CloseHandleIfValid(parentErrorRead);
                if (localJob != IntPtr.Zero) CloseHandle(localJob);
            }
        }

        public bool HasExited
        {
            get
            {
                lock (gate)
                {
                    return processHandle == IntPtr.Zero || WaitForSingleObject(processHandle, 0) == WaitObject0;
                }
            }
        }

        public bool TryGetExitCode(out int exitCode)
        {
            exitCode = -1;
            lock (gate)
            {
                if (processHandle == IntPtr.Zero || WaitForSingleObject(processHandle, 0) != WaitObject0) return false;
                uint code;
                if (!GetExitCodeProcess(processHandle, out code)) return false;
                exitCode = unchecked((int)code);
                return true;
            }
        }

        public Task<int> StopAsync(int graceMilliseconds)
        {
            if (graceMilliseconds < 0) throw new ArgumentOutOfRangeException("graceMilliseconds");
            lock (gate)
            {
                Task<int> existing = GetReusableStopTaskLocked();
                if (existing != null) return existing;
                if (disposed) return Task.FromResult(0);
            }

            // Serialize the first stop request with Start/Dispose. Later callers only
            // observe the already-created task and never wait for the grace period.
            lock (lifecycleGate)
            {
                lock (gate)
                {
                    Task<int> existing = GetReusableStopTaskLocked();
                    if (existing != null) return existing;
                    if (disposed) return Task.FromResult(0);
                    stopTask = Task.Run(delegate { return StopCore(graceMilliseconds); });
                    return stopTask;
                }
            }
        }

        // Share an in-flight stop. If a completed attempt left the process alive,
        // clear its task so a later user request can try the bounded stop again.
        private Task<int> GetReusableStopTaskLocked()
        {
            if (stopTask == null) return null;
            if (!stopTask.IsCompleted) return stopTask;
            if (processHandle == IntPtr.Zero || WaitForSingleObject(processHandle, 0U) == WaitObject0) return stopTask;
            stopTask = null;
            return null;
        }

        public void CloseControlInput()
        {
            lock (lifecycleGate)
            {
                IntPtr input;
                lock (gate)
                {
                    input = standardInputWrite;
                    standardInputWrite = IntPtr.Zero;
                }
                CloseHandleIfValid(input);
            }
        }

        public void Dispose()
        {
            lock (lifecycleGate)
            {
                IntPtr job;
                lock (gate)
                {
                    if (disposed) return;
                    disposed = true;
                    job = jobHandle;
                    jobHandle = IntPtr.Zero;
                }
                if (job != IntPtr.Zero) CloseHandle(job); // KILL_ON_JOB_CLOSE 收拢本次启动的进程树。
                CloseOwnedHandles();
            }
        }

        private int StopCore(int graceMilliseconds)
        {
            lock (lifecycleGate)
            {
                IntPtr input;
                IntPtr process;
                IntPtr job;
                lock (gate)
                {
                    process = processHandle;
                    input = standardInputWrite;
                    standardInputWrite = IntPtr.Zero;
                    job = jobHandle;
                }
                if (input != IntPtr.Zero)
                {
                    if (process != IntPtr.Zero && WaitForSingleObject(process, 0U) != WaitObject0)
                    {
                        byte[] quit = new byte[] { (byte)'Q', (byte)'\r', (byte)'\n' };
                        uint written;
                        WriteFile(input, quit, (uint)quit.Length, out written, IntPtr.Zero);
                    }
                    CloseHandle(input);
                }
                if (process == IntPtr.Zero) return 0;

                if (WaitForSingleObject(process, 0U) == WaitObject0)
                {
                    uint existingCode;
                    return GetExitCodeProcess(process, out existingCode) ? unchecked((int)existingCode) : -1;
                }
                uint wait = WaitForSingleObject(process, (uint)graceMilliseconds);
                if (wait == WaitTimeout && job != IntPtr.Zero)
                {
                    lock (gate)
                    {
                        if (jobHandle == job) jobHandle = IntPtr.Zero;
                    }
                    CloseHandle(job);
                    wait = WaitForSingleObject(process, 1000U);
                }
                if (wait == WaitTimeout)
                {
                    // The job close is the normal force-stop path. TerminateProcess is
                    // a bounded fallback in case a child does not leave the job promptly.
                    TerminateProcess(process, 0xC000013AU);
                    wait = WaitForSingleObject(process, 1000U);
                }
                uint code;
                if (wait == WaitObject0 && GetExitCodeProcess(process, out code)) return unchecked((int)code);
                return -1;
            }
        }

        private void StartPumpThreads()
        {
            IntPtr stdout;
            IntPtr stderr;
            lock (gate)
            {
                stdout = standardOutputRead;
                stderr = standardErrorRead;
                standardOutputRead = IntPtr.Zero;
                standardErrorRead = IntPtr.Zero;
            }
            try
            {
                if (stdout != IntPtr.Zero) { StartPump(stdout, "stdout"); stdout = IntPtr.Zero; }
                if (stderr != IntPtr.Zero) { StartPump(stderr, "stderr"); stderr = IntPtr.Zero; }
            }
            finally
            {
                CloseHandleIfValid(stdout);
                CloseHandleIfValid(stderr);
            }
        }

        private void StartPump(IntPtr handle, string channel)
        {
            Thread thread = new Thread(new ThreadStart(delegate { Pump(handle, channel); }));
            thread.IsBackground = true;
            thread.Name = "WIREX Bridge " + channel + " drain";
            thread.Start();
            lock (gate)
            {
                if (channel == "stdout") standardOutputPump = thread;
                else standardErrorPump = thread;
            }
        }

        private void Pump(IntPtr handle, string channel)
        {
            byte[] bytes = new byte[4096];
            char[] characters = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
            Decoder decoder = Encoding.UTF8.GetDecoder();
            while (handle != IntPtr.Zero)
            {
                uint actual;
                if (!ReadFile(handle, bytes, (uint)bytes.Length, out actual, IntPtr.Zero) || actual == 0) break;
                int characterCount = decoder.GetChars(bytes, 0, unchecked((int)actual), characters, 0, false);
                AppendDiagnostic(channel, characters, characterCount);
            }
            int finalCharacterCount = decoder.GetChars(bytes, 0, 0, characters, 0, true);
            AppendDiagnostic(channel, characters, finalCharacterCount);
            CloseHandleIfValid(handle);
        }

        private void AppendDiagnostic(string channel, char[] characters, int characterCount)
        {
            if (characterCount == 0) return;
            string text = new string(characters, 0, characterCount);
            lock (gate)
            {
                diagnosticTail.Append('[').Append(channel).Append("] ").Append(text);
                if (diagnosticTail.Length > DiagnosticLimit) diagnosticTail.Remove(0, diagnosticTail.Length - DiagnosticLimit);
            }
        }

        private void CloseOwnedHandles()
        {
            IntPtr[] handles;
            Thread[] pumps;
            lock (gate)
            {
                handles = new IntPtr[] { standardInputWrite, standardOutputRead, standardErrorRead, threadHandle, processHandle };
                pumps = new Thread[] { standardOutputPump, standardErrorPump };
                standardInputWrite = IntPtr.Zero;
                standardOutputRead = IntPtr.Zero;
                standardErrorRead = IntPtr.Zero;
                threadHandle = IntPtr.Zero;
                processHandle = IntPtr.Zero;
                standardOutputPump = null;
                standardErrorPump = null;
            }
            foreach (IntPtr handle in handles) CloseHandleIfValid(handle);
            foreach (Thread pump in pumps)
            {
                if (pump != null && pump.IsAlive) pump.Join(1500);
            }
        }

        public static string BuildCommandLine(string executable, string[] arguments)
        {
            StringBuilder result = new StringBuilder();
            result.Append(QuoteArgument(executable));
            foreach (string argument in arguments)
            {
                result.Append(' ').Append(QuoteArgument(argument ?? String.Empty));
            }
            return result.ToString();
        }

        public static string QuoteArgument(string argument)
        {
            if (argument.Length != 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return argument;
            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int backslashes = 0;
            for (int index = 0; index < argument.Length; index++)
            {
                char value = argument[index];
                if (value == '\\') { backslashes++; continue; }
                if (value == '"')
                {
                    quoted.Append('\\', backslashes * 2 + 1).Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes != 0) quoted.Append('\\', backslashes);
                backslashes = 0;
                quoted.Append(value);
            }
            if (backslashes != 0) quoted.Append('\\', backslashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private static void ThrowLastError(string operation)
        {
            throw new InvalidOperationException(operation + " failed with Win32 error " + Marshal.GetLastWin32Error().ToString() + ".");
        }

        private static void CloseHandleIfValid(IntPtr handle)
        {
            if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public ushort wShowWindow;
            public ushort cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe,
            ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(IntPtr hJob, uint JobObjectInfoClass,
            IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
            uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
            out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
            out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);
    }
}
