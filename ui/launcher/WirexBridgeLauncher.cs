using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("WIREX Bridge")]
[assembly: AssemblyProduct("WIREX Bridge")]
[assembly: AssemblyCompany("iCassius")]
[assembly: AssemblyDescription("Portable WIREX Bridge launcher")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]
[assembly: AssemblyInformationalVersion("0.1.0")]

internal static class WirexBridgeLauncher
{
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint CreateUnicodeEnvironment = 0x00000400;
    private const uint JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const uint WaitObject0 = 0;
    private const uint WaitTimeout = 258;
    private const uint Infinite = 0xffffffff;
    private const uint MessageBoxOk = 0x00000000;
    private const uint MessageBoxIconError = 0x00000010;

    private static int Main(string[] args)
    {
        bool noConnect = args != null && args.Length == 1 && String.Equals(args[0], "--no-connect", StringComparison.Ordinal);
        bool validateConfig = args != null && args.Length == 1 && String.Equals(args[0], "--validate-config", StringComparison.Ordinal);
        bool routingDiagnostic = args != null && args.Length == 2 &&
            String.Equals(args[0], "--routing-diagnostic", StringComparison.Ordinal);
        if (args != null && args.Length != 0 && !noConnect && !validateConfig && !routingDiagnostic)
        {
            return ReportDiagnostic("Usage: WirexBridge.exe [--no-connect | --validate-config | --routing-diagnostic <absolute-isolated-directory>].", 64);
        }

        string diagnosticDirectory = routingDiagnostic ? args[1] : null;
        if (routingDiagnostic && !Path.IsPathRooted(diagnosticDirectory))
        {
            return ReportDiagnostic("--routing-diagnostic requires an existing absolute isolated directory.", 64);
        }

        try
        {
            return Run(noConnect, validateConfig, diagnosticDirectory);
        }
        catch
        {
            if (!validateConfig && !routingDiagnostic)
            {
                ShowMessage("WIREX Bridge 启动失败。请确认 runtime 文件完整，并检查 exe 目录下的 config.json。", true);
            }
            else
            {
                ReportDiagnostic("Config validation or isolated routing diagnostic could not start. Check runtime files and permissions.", 1);
            }
            return 1;
        }
    }

    private static int Run(bool noConnect, bool validateConfig, string diagnosticDirectory)
    {
        string executablePath = Assembly.GetExecutingAssembly().Location;
        string executableRoot = Path.GetFullPath(Path.GetDirectoryName(executablePath));
        string runtimeRoot = Path.Combine(executableRoot, "runtime");
        string powerShell = FindWindowsPowerShell();
        string uiLauncher = Path.Combine(runtimeRoot, "start-ui.ps1");
        string uiScript = Path.Combine(runtimeRoot, "ui", "windows", "bridge-ui.ps1");
        string configModule = Path.Combine(runtimeRoot, "ui", "windows", "PortableConfig.psm1");
        string nativeExecutable = Path.Combine(runtimeRoot, "wirex_bridge.exe");

        RequireFile(powerShell);
        RequireFile(uiLauncher);
        RequireFile(uiScript);
        RequireFile(configModule);
        RequireFile(nativeExecutable);

        string[] arguments;
        if (!String.IsNullOrWhiteSpace(diagnosticDirectory))
        {
            string isolatedDirectory = Path.GetFullPath(diagnosticDirectory);
            if (!Directory.Exists(isolatedDirectory) || IsWithin(isolatedDirectory, executableRoot) ||
                IsWithin(isolatedDirectory, runtimeRoot))
                throw new InvalidOperationException();
            arguments = new string[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden", "-File", uiLauncher,
                "-PackageDirectory", runtimeRoot, "-UserConfigDirectory", isolatedDirectory,
                "-PortableDirectory", executableRoot, "-RoutingDiagnostic", "-RoutingDiagnosticAutoTest", "-NoAutoConnect" };
        }
        else if (validateConfig)
        {
            arguments = new string[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden", "-File", uiLauncher,
                "-PackageDirectory", runtimeRoot, "-PortableDirectory", executableRoot, "-ValidateConfigOnly" };
        }
        else
        {
            arguments = new string[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden", "-File", uiLauncher,
                "-PackageDirectory", runtimeRoot, "-PortableDirectory", executableRoot };
            if (noConnect)
            {
                Array.Resize(ref arguments, arguments.Length + 1);
                arguments[arguments.Length - 1] = "-NoAutoConnect";
            }
        }
        string commandLine = BuildCommandLine(powerShell, arguments);
        int exitCode = RunInOwnedJob(powerShell, commandLine, executableRoot);
        if (exitCode != 0 && (validateConfig || !String.IsNullOrWhiteSpace(diagnosticDirectory)))
        {
            string mode = validateConfig ? "Config validation" : "Isolated routing diagnostic";
            ReportDiagnostic(mode + " failed (exit code " + exitCode.ToString() + "). Check runtime files and directory permissions.", exitCode);
        }
        else if (exitCode != 0)
        {
            ShowMessage("WIREX Bridge 启动失败（退出代码 " + exitCode.ToString() + "）。请检查 runtime 文件和 config.json。", true);
        }
        return exitCode;
    }

    private static bool IsWithin(string path, string directory)
    {
        string fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string fullDirectory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (String.Equals(fullPath, fullDirectory, StringComparison.OrdinalIgnoreCase)) return true;
        return fullPath.StartsWith(fullDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string FindWindowsPowerShell()
    {
        string windows = Environment.GetEnvironmentVariable("WINDIR");
        if (String.IsNullOrWhiteSpace(windows)) throw new InvalidOperationException();
        return Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private static void RequireFile(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !File.Exists(path)) throw new FileNotFoundException();
    }

    private static string BuildCommandLine(string application, string[] arguments)
    {
        StringBuilder result = new StringBuilder();
        result.Append(QuoteWindowsArgument(application));
        for (int index = 0; index < arguments.Length; index++)
        {
            result.Append(' ');
            result.Append(QuoteWindowsArgument(arguments[index]));
        }
        return result.ToString();
    }

    private static string QuoteWindowsArgument(string value)
    {
        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;
        for (int index = 0; index < value.Length; index++)
        {
            char character = value[index];
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', (backslashes * 2) + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes != 0)
            {
                quoted.Append('\\', backslashes);
                backslashes = 0;
            }
            quoted.Append(character);
        }
        if (backslashes != 0) quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static int RunInOwnedJob(string application, string commandLine, string workingDirectory)
    {
        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        bool created = false;
        bool resumed = false;
        try
        {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new InvalidOperationException();
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr memory = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, memory, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, memory, (uint)size))
                    throw new InvalidOperationException();
            }
            finally { Marshal.FreeHGlobal(memory); }

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            StringBuilder mutableCommandLine = new StringBuilder(commandLine);
            if (!CreateProcess(application, mutableCommandLine, IntPtr.Zero, IntPtr.Zero, false,
                CreateSuspended | CreateNoWindow | CreateUnicodeEnvironment, IntPtr.Zero, workingDirectory,
                ref startup, out process))
                throw new InvalidOperationException();
            created = true;

            // 子进程加入关闭即终止的 job 前不会运行，因此不会提前创建后代进程。
            if (!AssignProcessToJobObject(job, process.hProcess)) throw new InvalidOperationException();
            if (ResumeThread(process.hThread) == 0xffffffff) throw new InvalidOperationException();
            resumed = true;

            uint waitResult = WaitForSingleObject(process.hProcess, Infinite);
            if (waitResult != WaitObject0) throw new InvalidOperationException();
            uint childExitCode;
            if (!GetExitCodeProcess(process.hProcess, out childExitCode)) throw new InvalidOperationException();
            return unchecked((int)childExitCode);
        }
        finally
        {
            if (created && !resumed && process.hProcess != IntPtr.Zero &&
                WaitForSingleObject(process.hProcess, 0) == WaitTimeout)
            {
                // 这里只终止本启动器刚创建的挂起进程。
                TerminateProcess(process.hProcess, 2);
                WaitForSingleObject(process.hProcess, 5000);
            }
            if (job != IntPtr.Zero)
            {
                CloseHandle(job); // KILL_ON_JOB_CLOSE 回收本启动器创建的进程树。
                job = IntPtr.Zero;
            }
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
        }
    }

    private static void ShowMessage(string message, bool error)
    {
        MessageBox(IntPtr.Zero, message, "WIREX Bridge", MessageBoxOk | (error ? MessageBoxIconError : 0));
    }

    private static int ReportDiagnostic(string message, int exitCode)
    {
        try
        {
            TextWriter error = Console.Error;
            if (error != null)
            {
                error.WriteLine(message);
                error.Flush();
            }
        }
        catch { }
        return exitCode;
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

    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, uint informationClass, IntPtr information, uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
        string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
