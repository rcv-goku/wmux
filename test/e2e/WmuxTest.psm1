#Requires -Version 7.0
<#
.SYNOPSIS
    wmux end-to-end test harness (ARCHITECTURE.md ADR-12.3 to ADR-12.5, Appendix D).

.DESCRIPTION
    PowerShell 7 module. No external modules, no Pester. It launches isolated, hidden wmux
    instances and drives them over the control pipe (cmux v2 envelope), raw protocol lines,
    the CLI and the events stream. It exports exactly the functions of Appendix D.3.

    Isolation per instance (Appendix D.2): unique channel test-<8hex>, private state/config/xdg
    directories under $env:RUNNER_TEMP or $env:TEMP\wmux-e2e\<id>, a generated ghostty.conf
    with a deterministic cmd prompt (WMUX>), a toast sink, and a child environment from which
    inherited CMUX_*, WMUX_* and GHOSTTY_* variables (plus agent markers and credentials) are
    removed. A focus sampler (spike S2) watches the whole process tree of every instance (wmux,
    conhost, shells, msedgewebview2; descendants refreshed every 250 ms, exited PIDs kept) and
    fails the current Test-Case with "focus stolen by test instance" when a window of the tree
    becomes foreground; its visibility guard fails it with "visible test window" when a
    top-level window of the tree is visible, not cloaked and on a monitor (cloaked windows and
    the (-32000,-32000) placement are accepted; the placement seen is reported as hidden_mode).
    A violating tree is killed at once. Stop-WmuxInstance kills orphaned tree members (WebView2
    outlives its host), waits until none is listed, and deletes the root in the background when
    files are still locked; run.ps1 sweeps stale roots of dead runs.

    Transitional behavior until W1-1a lands the v2 server and the new pipe names:
      * Start-WmuxInstance detects the protocol. When the legacy pipe \\.\pipe\wmux-ipc-<pid>
        appears and answers a {"id":<n>,"cmd":"workspace-list"} request with ok, the instance gets
        Protocol = 'legacy' and Pipe points at that pipe. Otherwise the v2 control pipe named
        by state\run\instance.json (or computed with the D.2.6 algorithm) is used and readiness
        is wmux.debug.ready returning {ready:true}. A v2 pipe always wins when both exist.
      * v2-only helpers (Invoke-WmuxRpc, the events helpers, Get-WmuxDialogs) throw
        [WmuxRpcError] with Code 'harness_legacy_protocol' for a legacy instance. Use
        Invoke-WmuxRawLine with legacy JSON lines instead.
      * Start-WmuxInstance refuses to launch a wmux.exe that does not contain WMUX_TEST_HIDDEN
        support (W0-A1): it throws [WmuxSkipException] so the Test-Case is reported as skipped
        instead of opening a visible window. -Visible bypasses the check for local debugging.

    Harness error codes (never sent by the server): harness_legacy_protocol, harness_timeout,
    harness_eof, harness_transport, harness_bad_reply, harness_id_mismatch,
    harness_stream_closed, harness_cli_missing, harness_cli_timeout, harness_instance_stopped.

    Environment knobs read by the harness itself (all optional):
      WMUX_E2E_EXE                default wmux.exe when neither -Exe nor -Build is given
      WMUX_E2E_RESULTS            JSONL file that Test-Case appends results to (set by run.ps1)
      WMUX_E2E_ARTIFACTS          directory for failure artifacts (set by run.ps1)
      WMUX_E2E_FILE               suite-relative path of the running file (set by run.ps1)
      WMUX_E2E_ATTEMPT            1 or 2 (set by run.ps1 on retry)
      WMUX_E2E_FILTER             only Test-Cases whose name or file matches (set by run.ps1)
      WMUX_E2E_TEST_TIMEOUT_SEC   per-Test-Case watchdog, default 120
      WMUX_E2E_CLI_TIMEOUT_SEC    Invoke-WmuxCli timeout, default 60
      WMUX_E2E_KEEP_LOCALAPPDATA  1 = do not redirect LOCALAPPDATA for the instance
      WMUX_E2E_NO_TYPE_CACHE      1 = compile the helper types in memory, no DLL cache
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper types (C#). Compiled once per source hash and cached as a DLL under
# %TEMP%\wmux-e2e\typecache so every test process does not pay the Roslyn cost.
# Public API types live in the global namespace so tests can write
# `catch [WmuxRpcError]`; helpers live in the WmuxTestHarness namespace.
# ---------------------------------------------------------------------------

$script:HarnessTypesVersion = '5'

$script:HarnessTypeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Management.Automation;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

/// Error reply of a v2 request ({"ok":false,"error":{code,message,data}}) or a harness
/// transport failure (codes prefixed harness_).
public class WmuxRpcError : Exception
{
    private readonly string _message;
    public string Code { get; private set; }
    public new object Data { get; private set; }
    public string Method { get; private set; }
    public object RequestId { get; private set; }
    public string Reply { get; private set; }
    public object ErrorObject { get; private set; }

    public WmuxRpcError(string code, string message, object data, string method, object requestId, string reply, object errorObject, Exception inner)
        : base(message ?? code, inner)
    {
        Code = code;
        _message = message;
        Data = data;
        Method = method;
        RequestId = requestId;
        Reply = reply;
        ErrorObject = errorObject;
    }

    public WmuxRpcError(string code, string message) : this(code, message, null, null, null, null, null, null) { }

    public override string Message { get { return _message ?? Code ?? "rpc error"; } }

    public override string ToString()
    {
        return "WmuxRpcError " + Code + ": " + Message + (Method != null ? " (method " + Method + ")" : "");
    }
}

/// Assertion or wait failure raised by the Assert-* and Wait-* helpers.
public class WmuxAssertionError : Exception
{
    public WmuxAssertionError(string message) : base(message) { }
    public WmuxAssertionError(string message, Exception inner) : base(message, inner) { }
}

/// Thrown to report the current Test-Case as skipped (for example when wmux.exe cannot run hidden).
public class WmuxSkipException : Exception
{
    public WmuxSkipException(string reason) : base(reason) { }
}

/// A running test instance. The first block of fields is the Appendix D.3 contract;
/// the rest is harness bookkeeping.
public class WmuxInstance
{
    public int Pid;
    public string Channel;
    public string Root;
    public string StateDir;
    public string ConfigDir;
    public string Pipe;
    public string LaunchPipe;
    public string Exe;
    public string CliExe;
    public string ToastSink;
    public string ArtifactsDir;
    public bool Failed;

    public string Id;
    public string Protocol;
    public string LegacyPipe;
    public string XdgDir;
    public string LogDir;
    public string WorkDir;
    public string LocalAppData;
    public bool Visible;
    public bool KeepArtifacts;
    public bool Stopped;
    public bool Cleaned;
    public int? ExitCode;
    public DateTime StartedAt;
    public string TestName;
    public Process Process;
    public IntPtr JobHandle;
    public List<object> Streams = new List<object>();
    /// Placement of the hidden windows seen by the visibility guard (FocusSampler.PlacementOf):
    /// "cloaked" (S2 / W0-A4), "offscreen" ((-32000,-32000), W0-A1), "none", ... Set at stop.
    public string HiddenMode;
    /// Processes of the instance tree recorded by the sampler (set at stop).
    public object[] Tree;
    /// Tree members still listed after the stop wait; deletion mode of the root ("sync",
    /// "async" or "kept").
    public string[] Survivors;
    public string RootDeletion;
    /// Ids ("n:<number>" / "s:<string>") of requests whose reply has not arrived yet.
    public HashSet<string> OutstandingIds = new HashSet<string>();

    public override string ToString()
    {
        return "WmuxInstance(pid=" + Pid + ", channel=" + Channel + ", protocol=" + Protocol + (Stopped ? ", stopped" : "") + ")";
    }
}

/// Background reader for one events.stream connection. Frames are kept as raw lines;
/// the module parses them.
public sealed class WmuxEventStream : IDisposable
{
    public int Pid;
    public string Channel;
    public string Pipe;
    public string Request;
    public string LogPath;
    public int Index;
    public object Instance;
    public object Ack;
    public string Error;

    private readonly object _gate = new object();
    private readonly Queue<string> _pending = new Queue<string>();
    private readonly List<string> _all = new List<string>();
    private readonly ManualResetEventSlim _firstArrived = new ManualResetEventSlim(false);
    private readonly ManualResetEventSlim _dataAvailable = new ManualResetEventSlim(false);
    private readonly CancellationTokenSource _cts = new CancellationTokenSource();
    private NamedPipeClientStream _pipe;
    private Thread _thread;
    private StreamWriter _log;
    private string _firstLine;
    private volatile bool _closedByClient;
    private volatile bool _endOfStream;

    public string FirstLine { get { lock (_gate) { return _firstLine; } } }
    public bool ClosedByClient { get { return _closedByClient; } }
    public bool EndOfStream { get { return _endOfStream; } }
    public bool Closed { get { return _closedByClient || _endOfStream; } }
    public int FrameCount { get { lock (_gate) { return _all.Count; } } }

    public static WmuxEventStream Open(string pipe, string requestLine, string logPath, int timeoutMs)
    {
        var s = new WmuxEventStream();
        s.Pipe = pipe;
        s.Request = requestLine;
        s.LogPath = logPath;
        var sw = Stopwatch.StartNew();
        try
        {
            s._pipe = WmuxTestHarness.PipeIO.Connect(pipe, timeoutMs);
            if (!string.IsNullOrEmpty(logPath))
            {
                var fs = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                s._log = new StreamWriter(fs, new UTF8Encoding(false));
                s._log.AutoFlush = true;
            }
            WmuxTestHarness.PipeIO.WriteLine(s._pipe, requestLine, WmuxTestHarness.PipeIO.Remaining(sw, timeoutMs));
            s._thread = new Thread(s.ReadLoop);
            s._thread.IsBackground = true;
            s._thread.Name = "wmux-e2e-events";
            s._thread.Start();
            if (!s._firstArrived.Wait(WmuxTestHarness.PipeIO.Remaining(sw, timeoutMs)))
                throw new TimeoutException("events.stream: no frame received within " + timeoutMs + " ms");
            if (s.FirstLine == null)
                throw new EndOfStreamException("events.stream: connection closed before the first frame" + (s.Error != null ? " (" + s.Error + ")" : ""));
            return s;
        }
        catch
        {
            s.Close();
            throw;
        }
    }

    private void ReadLoop()
    {
        var buf = new byte[65536];
        var acc = new MemoryStream();
        try
        {
            while (!_closedByClient)
            {
                int n = _pipe.ReadAsync(buf, 0, buf.Length, _cts.Token).GetAwaiter().GetResult();
                if (n <= 0) break;
                int start = 0;
                for (int i = 0; i < n; i++)
                {
                    if (buf[i] == 10)
                    {
                        acc.Write(buf, start, i - start);
                        EmitLine(acc);
                        acc.SetLength(0);
                        start = i + 1;
                    }
                }
                if (start < n) acc.Write(buf, start, n - start);
                if (acc.Length > (64L << 20)) throw new InvalidDataException("event frame exceeds 64 MiB");
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex)
        {
            if (!_closedByClient) Error = ex.GetType().Name + ": " + ex.Message;
        }
        finally
        {
            lock (_gate)
            {
                _endOfStream = true;
                _dataAvailable.Set();
            }
            _firstArrived.Set();
        }
    }

    private void EmitLine(MemoryStream acc)
    {
        byte[] bytes = acc.ToArray();
        int len = bytes.Length;
        if (len > 0 && bytes[len - 1] == 13) len--;
        if (len == 0) return;
        string line = Encoding.UTF8.GetString(bytes, 0, len);
        lock (_gate)
        {
            _all.Add(line);
            if (_firstLine == null)
            {
                _firstLine = line;
            }
            else
            {
                _pending.Enqueue(line);
                _dataAvailable.Set();
            }
        }
        StreamWriter log = _log;
        if (log != null)
        {
            try { lock (log) { log.WriteLine(line); } } catch { }
        }
        _firstArrived.Set();
    }

    /// Returns the frames queued since the last call. Waits up to waitMs when none are queued.
    public string[] Drain(int waitMs)
    {
        lock (_gate)
        {
            if (_pending.Count > 0 || _endOfStream || _closedByClient) return TakeAll();
        }
        if (waitMs > 0) _dataAvailable.Wait(waitMs);
        lock (_gate) { return TakeAll(); }
    }

    private string[] TakeAll()
    {
        string[] items = _pending.ToArray();
        _pending.Clear();
        if (!_endOfStream && !_closedByClient) _dataAvailable.Reset();
        return items;
    }

    public string[] AllLines()
    {
        lock (_gate) { return _all.ToArray(); }
    }

    public void Close()
    {
        if (_closedByClient) return;
        _closedByClient = true;
        try { _cts.Cancel(); } catch { }
        try { if (_pipe != null) _pipe.Dispose(); } catch { }
        if (_thread != null && _thread != Thread.CurrentThread)
        {
            try { _thread.Join(2000); } catch { }
        }
        lock (_gate) { _dataAvailable.Set(); }
        StreamWriter log = _log;
        if (log != null)
        {
            try { lock (log) { log.Dispose(); } } catch { }
        }
    }

    public void Dispose() { Close(); }

    public override string ToString()
    {
        return "WmuxEventStream(pid=" + Pid + ", frames=" + FrameCount + (Closed ? ", closed" : "") + ")";
    }
}

namespace WmuxTestHarness
{
    public static class Native
    {
        public const string Version = "5";

        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hWnd, StringBuilder buf, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder buf, int max);
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        /// True when the window's thread has not pumped messages for 5 s (PrintWindow would block).
        [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W
        {
            public uint dwSize, cntUsage, th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID, cntThreads, th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }

        public const int DWMWA_CLOAKED = 14;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        /// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: physical pixels for GetWindowRect and PrintWindow.
        public static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);

        /// One Toolhelp process entry.
        public sealed class ProcEntry
        {
            public int Pid;
            public int ParentPid;
            public string Name;
        }

        /// Every process of the session (Toolhelp snapshot), by PID.
        public static Dictionary<int, ProcEntry> SnapshotProcesses()
        {
            var map = new Dictionary<int, ProcEntry>();
            IntPtr snap = CreateToolhelp32Snapshot(0x2 /* TH32CS_SNAPPROCESS */, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return map;
            try
            {
                var pe = new PROCESSENTRY32W();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snap, ref pe))
                {
                    do
                    {
                        var e = new ProcEntry();
                        e.Pid = (int)pe.th32ProcessID;
                        e.ParentPid = (int)pe.th32ParentProcessID;
                        e.Name = pe.szExeFile;
                        map[e.Pid] = e;
                    } while (Process32NextW(snap, ref pe));
                }
            }
            finally { CloseHandle(snap); }
            return map;
        }

        /// Creation time (FILETIME ticks) of a live or exiting process; 0 when it cannot be opened.
        public static long ProcessCreationTime(int pid)
        {
            if (pid <= 0) return 0;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
            if (h == IntPtr.Zero) return 0;
            try
            {
                long c, e, k, u;
                return GetProcessTimes(h, out c, out e, out k, out u) ? c : 0;
            }
            finally { CloseHandle(h); }
        }

        /// Terminates pid only when its creation time still equals creationTime (never a recycled PID).
        public static bool TerminateIfSame(int pid, long creationTime)
        {
            if (pid <= 0 || creationTime == 0) return false;
            IntPtr h = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
            if (h == IntPtr.Zero) return false;
            try
            {
                long c, e, k, u;
                if (!GetProcessTimes(h, out c, out e, out k, out u) || c != creationTime) return false;
                return TerminateProcess(h, 1);
            }
            finally { CloseHandle(h); }
        }

        /// DWMWA_CLOAKED of a window: null when the query fails (window being destroyed).
        public static int? Cloaked(IntPtr hWnd)
        {
            int v;
            if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out v, 4) != 0) return null;
            return v;
        }

        /// True when the window rectangle intersects a monitor (MONITOR_DEFAULTTONULL).
        public static bool OnAnyMonitor(IntPtr hWnd)
        {
            RECT r;
            if (!GetWindowRect(hWnd, out r) || r.Right <= r.Left || r.Bottom <= r.Top) return false;
            return MonitorFromRect(ref r, 0) != IntPtr.Zero;
        }

        /// Child windows (any depth) of parent whose class equals className (null = all).
        public static IntPtr[] ChildWindows(IntPtr parent, string className)
        {
            var list = new List<IntPtr>();
            EnumWindowsProc cb = delegate (IntPtr h, IntPtr l)
            {
                if (className == null || ClassName(h) == className) list.Add(h);
                return true;
            };
            EnumChildWindows(parent, cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return list.ToArray();
        }

        /// Every top-level window of the desktop.
        public static IntPtr[] AllTopLevelWindows()
        {
            var list = new List<IntPtr>();
            EnumWindowsProc cb = delegate (IntPtr h, IntPtr l) { list.Add(h); return true; };
            EnumWindows(cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return list.ToArray();
        }

        public static int ForegroundProcessId()
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return 0;
            uint pid;
            GetWindowThreadProcessId(fg, out pid);
            return (int)pid;
        }

        public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }

        public static int WindowProcessId(IntPtr hWnd)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            return (int)pid;
        }

        public static string ClassName(IntPtr hWnd)
        {
            var sb = new StringBuilder(256);
            GetClassNameW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string Title(IntPtr hWnd)
        {
            var sb = new StringBuilder(512);
            GetWindowTextW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static IntPtr[] TopLevelWindows(int pid, string className)
        {
            var list = new List<IntPtr>();
            EnumWindowsProc cb = delegate (IntPtr h, IntPtr l)
            {
                uint p;
                GetWindowThreadProcessId(h, out p);
                if (p == (uint)pid && (className == null || ClassName(h) == className)) list.Add(h);
                return true;
            };
            EnumWindows(cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return list.ToArray();
        }

        /// Bare names of the named pipes whose name starts with prefix (directory enumeration;
        /// never connects to a pipe, so it cannot consume a single-instance server).
        public static string[] ListPipes(string prefix)
        {
            var result = new List<string>();
            try
            {
                foreach (string f in Directory.GetFiles(PipeIO.Prefix))
                {
                    string name = f.StartsWith(PipeIO.Prefix, StringComparison.OrdinalIgnoreCase) ? f.Substring(PipeIO.Prefix.Length) : Path.GetFileName(f);
                    if (string.IsNullOrEmpty(prefix) || name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) result.Add(name);
                }
            }
            catch { }
            return result.ToArray();
        }

        public static bool PipeExists(string name)
        {
            string bare = PipeIO.BareName(name);
            foreach (string n in ListPipes(bare))
            {
                if (string.Equals(n, bare, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        public static string LongPath(string path)
        {
            var sb = new StringBuilder(1024);
            uint n = GetLongPathNameW(path, sb, (uint)sb.Capacity);
            if (n == 0) return path;
            if (n > sb.Capacity)
            {
                sb = new StringBuilder((int)n + 1);
                n = GetLongPathNameW(path, sb, (uint)sb.Capacity);
                if (n == 0) return path;
            }
            return sb.ToString();
        }

        /// True when the file contains the ASCII text either as single-byte or as UTF-16LE bytes.
        public static bool FileContains(string path, string text)
        {
            byte[] a = Encoding.ASCII.GetBytes(text);
            byte[] w = Encoding.Unicode.GetBytes(text);
            int keep = Math.Max(a.Length, w.Length) - 1;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16))
            {
                byte[] buf = new byte[(4 << 20) + keep + 1];
                int carry = 0;
                while (true)
                {
                    int n = fs.Read(buf, carry, buf.Length - carry);
                    if (n <= 0) break;
                    int len = carry + n;
                    var span = new ReadOnlySpan<byte>(buf, 0, len);
                    if (span.IndexOf(new ReadOnlySpan<byte>(a)) >= 0) return true;
                    if (span.IndexOf(new ReadOnlySpan<byte>(w)) >= 0) return true;
                    carry = Math.Min(keep, len);
                    Buffer.BlockCopy(buf, len - carry, buf, 0, carry);
                }
            }
            return false;
        }
    }

    public static class PipeIO
    {
        public const string Prefix = @"\\.\pipe\";
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        public static string BareName(string pipe)
        {
            if (pipe == null) throw new ArgumentNullException("pipe");
            return pipe.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) ? pipe.Substring(Prefix.Length) : pipe;
        }

        public static string FullName(string pipe) { return Prefix + BareName(pipe); }

        public static int Remaining(Stopwatch sw, int timeoutMs)
        {
            long r = timeoutMs - sw.ElapsedMilliseconds;
            return r < 1 ? 1 : (int)r;
        }

        public static NamedPipeClientStream Connect(string pipe, int timeoutMs)
        {
            var c = new NamedPipeClientStream(".", BareName(pipe), PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                c.Connect(Math.Max(1, timeoutMs));
                return c;
            }
            catch
            {
                c.Dispose();
                throw;
            }
        }

        internal static void WaitOrThrow(Task t, int ms, CancellationTokenSource cts, string what)
        {
            bool done;
            try
            {
                done = t.Wait(Math.Max(1, ms));
            }
            catch (AggregateException ae)
            {
                ExceptionDispatchInfo.Capture(ae.InnerException ?? ae).Throw();
                throw;
            }
            if (!done)
            {
                try { cts.Cancel(); } catch { }
                try { t.Wait(1000); } catch { }
                throw new TimeoutException(what + " timed out after " + ms + " ms");
            }
        }

        public static void WriteLine(Stream s, string line, int timeoutMs)
        {
            if (!line.EndsWith("\n")) line += "\n";
            byte[] bytes = Utf8.GetBytes(line);
            using (var cts = new CancellationTokenSource())
            {
                Task t = s.WriteAsync(bytes, 0, bytes.Length, cts.Token);
                WaitOrThrow(t, timeoutMs, cts, "writing the request line");
                s.Flush();
            }
        }

        public static string ReadLine(Stream s, int timeoutMs)
        {
            return new LineReader(s).ReadLine(timeoutMs);
        }

        internal static string Decode(byte[] b)
        {
            int len = b.Length;
            if (len > 0 && b[len - 1] == 13) len--;
            return Encoding.UTF8.GetString(b, 0, len);
        }

        /// "n:<number>" or "s:<string>" for the "id" of a JSON object line; null otherwise.
        public static string JsonId(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            int i = 0;
            while (i < text.Length && char.IsWhiteSpace(text[i])) i++;
            if (i >= text.Length || text[i] != '{') return null;
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(text))
                {
                    JsonElement id;
                    if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("id", out id)) return null;
                    if (id.ValueKind == JsonValueKind.Number) return "n:" + id.GetRawText();
                    if (id.ValueKind == JsonValueKind.String) return "s:" + id.GetString();
                }
            }
            catch (JsonException) { }
            return null;
        }

        /// Connect, write one line, read one reply line, disconnect.
        public static string RoundTrip(string pipe, string line, int timeoutMs)
        {
            return RoundTrip(pipe, line, timeoutMs, null);
        }

        /// Connect, write one line, read the reply line, disconnect. outstanding holds the ids
        /// of earlier requests to the same instance whose reply never arrived: the legacy server
        /// (one pipe instance, replies written by the UI thread to whatever connection is open
        /// when it answers) delivers those late replies to a later connection, ahead of the reply
        /// to this request. They are skipped here so request and reply never drift apart.
        public static string RoundTrip(string pipe, string line, int timeoutMs, ISet<string> outstanding)
        {
            string myId = outstanding != null ? JsonId(line) : null;
            var sw = Stopwatch.StartNew();
            using (var c = Connect(pipe, timeoutMs))
            {
                if (myId != null) outstanding.Add(myId);
                WriteLine(c, line, Remaining(sw, timeoutMs));
                var reader = new LineReader(c);
                while (true)
                {
                    string reply = reader.ReadLine(Remaining(sw, timeoutMs));
                    if (myId == null) return reply;
                    bool others = outstanding.Count > (outstanding.Contains(myId) ? 1 : 0);
                    if (others)
                    {
                        string id = JsonId(reply);
                        if (id != null && id != myId && outstanding.Remove(id)) continue;
                    }
                    outstanding.Remove(myId);
                    return reply;
                }
            }
        }
    }

    /// Newline-delimited reader that keeps the bytes after a newline for the next line.
    public sealed class LineReader
    {
        private readonly Stream _s;
        private readonly byte[] _buf = new byte[65536];
        private readonly MemoryStream _acc = new MemoryStream();
        private int _pos, _len;

        public LineReader(Stream s) { _s = s; }

        public string ReadLine(int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            while (true)
            {
                if (_pos < _len)
                {
                    int nl = Array.IndexOf(_buf, (byte)10, _pos, _len - _pos);
                    if (nl >= 0)
                    {
                        _acc.Write(_buf, _pos, nl - _pos);
                        _pos = nl + 1;
                        return Take();
                    }
                    _acc.Write(_buf, _pos, _len - _pos);
                    _pos = _len = 0;
                    if (_acc.Length > (256L << 20)) throw new InvalidDataException("reply line exceeds 256 MiB");
                }
                using (var cts = new CancellationTokenSource())
                {
                    Task<int> t = _s.ReadAsync(_buf, 0, _buf.Length, cts.Token);
                    PipeIO.WaitOrThrow(t, PipeIO.Remaining(sw, timeoutMs), cts, "waiting for a reply line");
                    int n = t.Result;
                    if (n <= 0)
                    {
                        if (_acc.Length > 0) return Take();
                        throw new EndOfStreamException("pipe closed by the server before a reply line was received");
                    }
                    _pos = 0;
                    _len = n;
                }
            }
        }

        private string Take()
        {
            string line = PipeIO.Decode(_acc.ToArray());
            _acc.SetLength(0);
            return line;
        }
    }

    /// JSON text to PowerShell values: objects become PSObjects (ordered note properties),
    /// arrays object[], integers long (ulong beyond Int64), other numbers double. Strings are
    /// never converted to dates (unlike ConvertFrom-Json) and single-element arrays survive.
    public static class Json
    {
        public static object Parse(string text)
        {
            if (text == null) throw new ArgumentNullException("text");
            var options = new JsonDocumentOptions();
            options.MaxDepth = 512;
            using (JsonDocument doc = JsonDocument.Parse(text, options))
            {
                return Convert(doc.RootElement);
            }
        }

        public static bool TryParse(string text, out object value)
        {
            try
            {
                value = Parse(text);
                return true;
            }
            catch (Exception)
            {
                value = null;
                return false;
            }
        }

        private static object Convert(JsonElement e)
        {
            switch (e.ValueKind)
            {
                case JsonValueKind.Object:
                    {
                        var o = new PSObject();
                        foreach (JsonProperty p in e.EnumerateObject())
                        {
                            string name = p.Name.Length == 0 ? "(empty)" : p.Name;
                            object v = Convert(p.Value);
                            PSPropertyInfo existing = o.Properties[name];
                            if (existing != null) existing.Value = v;
                            else o.Properties.Add(new PSNoteProperty(name, v));
                        }
                        return o;
                    }
                case JsonValueKind.Array:
                    {
                        var list = new List<object>();
                        foreach (JsonElement item in e.EnumerateArray()) list.Add(Convert(item));
                        return list.ToArray();
                    }
                case JsonValueKind.String:
                    return e.GetString();
                case JsonValueKind.Number:
                    {
                        long l;
                        if (e.TryGetInt64(out l)) return l;
                        ulong u;
                        if (e.TryGetUInt64(out u)) return u;
                        double d;
                        if (e.TryGetDouble(out d)) return d;
                        return e.GetRawText();
                    }
                case JsonValueKind.True:
                    return true;
                case JsonValueKind.False:
                    return false;
                default:
                    return null;
            }
        }
    }

    public sealed class FocusViolation
    {
        public DateTime At;
        /// "focus" (a window of a watched tree became foreground) or "visible" (visibility guard).
        public string Kind = "focus";
        public int Pid;
        public int Root;
        public long Hwnd;
        public string Process;
        public string Class;
        public string Title;
        public string Detail;

        public override string ToString()
        {
            string s = At.ToString("HH:mm:ss.fff") + " pid=" + Pid;
            if (Root != 0 && Root != Pid) s += " (tree of " + Root + ")";
            if (!string.IsNullOrEmpty(Process)) s += " proc=" + Process;
            s += " hwnd=0x" + Hwnd.ToString("X") + " class=" + Class + " title=\"" + Title + "\"";
            if (!string.IsNullOrEmpty(Detail)) s += " " + Detail;
            return s;
        }
    }

    /// A process of a watched tree. Exited members stay (no PID is reused against a run).
    public sealed class TreeMember
    {
        public int Pid;
        public int ParentPid;
        public string Name;
        public long CreationTime;
        public DateTime AddedAt;

        public override string ToString() { return Name + "(" + Pid + ")"; }
    }

    /// Focus sampler and visibility guard (Appendix D.2 step 7, spike S2 section 6.2).
    /// A background thread, made per-monitor-v2 DPI aware first, samples
    /// GetWindowThreadProcessId(GetForegroundWindow()) every IntervalMs and records a "focus"
    /// violation each time the foreground window starts belonging to a watched process tree:
    /// the root PID plus every descendant (Toolhelp parent links, refreshed every TreeRefreshMs,
    /// exited PIDs kept, creation times checked so a recycled PID never counts). Every
    /// VisibleScanMs it also enumerates the top-level windows of guarded trees and records a
    /// "visible" violation for a window that is visible, not minimized, not cloaked (only a
    /// successful DWMWA_CLOAKED query of 0 counts) and on a monitor. Cloaked windows and windows
    /// on no monitor (the (-32000,-32000) placement) are accepted; the placement seen is kept
    /// per root (PlacementOf). Trees registered with killOnViolation are terminated at once.
    public static class FocusSampler
    {
        private sealed class Root
        {
            public int Pid;
            public bool GuardVisible;
            public bool Kill;
            public bool Teardown;
            public readonly Dictionary<int, TreeMember> Members = new Dictionary<int, TreeMember>();
            public readonly HashSet<long> ReportedVisible = new HashSet<long>();
            public readonly HashSet<string> Placements = new HashSet<string>();
        }

        private static readonly object Gate = new object();
        private static readonly Dictionary<int, Root> Roots = new Dictionary<int, Root>();
        private static readonly List<FocusViolation> Violations = new List<FocusViolation>();
        private static readonly List<FocusViolation> Visible = new List<FocusViolation>();
        private static Thread _thread;
        private static long _samples;
        private static long _scans;
        private static IntPtr _lastHwnd = IntPtr.Zero;
        public static int IntervalMs = 100;
        public static int TreeRefreshMs = 250;
        public static int VisibleScanMs = 200;
        public static volatile bool DpiAware;

        /// Watches one process tree for focus only (no visibility guard, never kills).
        public static void Watch(int pid) { WatchTree(pid, false, false); }

        /// Watches the process tree rooted at pid. guardVisible enables the visibility guard;
        /// killOnViolation terminates the tree on the first violation.
        public static void WatchTree(int pid, bool guardVisible, bool killOnViolation)
        {
            lock (Gate)
            {
                Root r;
                if (!Roots.TryGetValue(pid, out r))
                {
                    r = new Root();
                    r.Pid = pid;
                    Roots[pid] = r;
                    var m = new TreeMember();
                    m.Pid = pid;
                    m.CreationTime = Native.ProcessCreationTime(pid);
                    m.AddedAt = DateTime.UtcNow;
                    try { m.Name = System.Diagnostics.Process.GetProcessById(pid).ProcessName + ".exe"; } catch { m.Name = "?"; }
                    r.Members[pid] = m;
                }
                r.GuardVisible = guardVisible;
                r.Kill = killOnViolation;
                r.Teardown = false;
                if (_thread == null)
                {
                    _thread = new Thread(Loop);
                    _thread.IsBackground = true;
                    _thread.Name = "wmux-e2e-focus-sampler";
                    _thread.Start();
                }
            }
            RefreshTrees();
        }

        public static void Unwatch(int pid)
        {
            lock (Gate) { Roots.Remove(pid); }
        }

        public static bool IsWatching(int pid)
        {
            lock (Gate) { return Roots.ContainsKey(pid); }
        }

        /// Stops the visibility guard and the kill for a tree that is being shut down on purpose
        /// (windows being destroyed answer DWM queries unreliably); focus is still sampled.
        public static void BeginTeardown(int pid)
        {
            lock (Gate)
            {
                Root r;
                if (Roots.TryGetValue(pid, out r)) { r.Teardown = true; r.Kill = false; }
            }
        }

        public static int ViolationCount { get { lock (Gate) { return Violations.Count; } } }
        public static int VisibleCount { get { lock (Gate) { return Visible.Count; } } }
        public static long Samples { get { return Interlocked.Read(ref _samples); } }
        public static long Scans { get { return Interlocked.Read(ref _scans); } }
        public static bool Running { get { lock (Gate) { return _thread != null; } } }

        public static FocusViolation[] Since(int index)
        {
            lock (Gate) { return Slice(Violations, index); }
        }

        public static FocusViolation[] VisibleSince(int index)
        {
            lock (Gate) { return Slice(Visible, index); }
        }

        private static FocusViolation[] Slice(List<FocusViolation> list, int index)
        {
            if (index < 0) index = 0;
            if (index >= list.Count) return new FocusViolation[0];
            return list.GetRange(index, list.Count - index).ToArray();
        }

        /// Focus violations whose window belonged to pid itself.
        public static FocusViolation[] ForPid(int pid)
        {
            lock (Gate) { return Violations.FindAll(v => v.Pid == pid).ToArray(); }
        }

        /// Focus and visibility violations of the tree rooted at root.
        public static FocusViolation[] ForRoot(int root)
        {
            lock (Gate)
            {
                var all = Violations.FindAll(v => v.Root == root || v.Pid == root);
                all.AddRange(Visible.FindAll(v => v.Root == root));
                return all.ToArray();
            }
        }

        /// Members of the tree (live and exited) in the order they were found.
        public static TreeMember[] TreeOf(int root)
        {
            lock (Gate)
            {
                Root r;
                if (!Roots.TryGetValue(root, out r)) return new TreeMember[0];
                var list = new List<TreeMember>(r.Members.Values);
                list.Sort((a, b) => a.AddedAt.CompareTo(b.AddedAt));
                return list.ToArray();
            }
        }

        /// Placement of the visible top-level windows seen so far: "cloaked", "offscreen"
        /// (visible but on no monitor, the (-32000,-32000) placement), combinations joined with
        /// "+", "onscreen" when the guard fired, or "none" when no visible window was seen.
        public static string PlacementOf(int root)
        {
            lock (Gate)
            {
                Root r;
                if (!Roots.TryGetValue(root, out r) || r.Placements.Count == 0) return "none";
                var p = new List<string>(r.Placements);
                p.Sort(StringComparer.Ordinal);
                return string.Join("+", p);
            }
        }

        private static void Loop()
        {
            try { DpiAware = Native.SetThreadDpiAwarenessContext(Native.PerMonitorAwareV2) != IntPtr.Zero; } catch { }
            var clock = Stopwatch.StartNew();
            long lastTree = 0, lastScan = 0;
            while (true)
            {
                long now = clock.ElapsedMilliseconds;
                try { if (now - lastTree >= TreeRefreshMs) { RefreshTrees(); lastTree = now; } } catch { }
                try { if (now - lastScan >= VisibleScanMs) { ScanVisibleOnce(); lastScan = now; } } catch { }
                try { SampleOnce(); } catch { }
                Thread.Sleep(Math.Max(10, IntervalMs));
            }
        }

        /// Adds the live descendants of every watched root (public for deterministic tests).
        public static void RefreshTrees()
        {
            Root[] roots;
            lock (Gate)
            {
                if (Roots.Count == 0) return;
                roots = new Root[Roots.Count];
                Roots.Values.CopyTo(roots, 0);
            }
            Dictionary<int, Native.ProcEntry> snap = Native.SnapshotProcesses();
            foreach (Root r in roots)
            {
                bool grew = true;
                while (grew)
                {
                    grew = false;
                    foreach (Native.ProcEntry e in snap.Values)
                    {
                        if (e.Pid == e.ParentPid || e.Pid <= 4) continue;
                        TreeMember parent;
                        lock (Gate)
                        {
                            if (r.Members.ContainsKey(e.Pid) || !r.Members.TryGetValue(e.ParentPid, out parent)) continue;
                        }
                        // The parent entry must be the process we recorded, not a recycled PID.
                        long parentNow = Native.ProcessCreationTime(e.ParentPid);
                        if (parent.CreationTime != 0 && parentNow != 0 && parentNow != parent.CreationTime) continue;
                        long ct = Native.ProcessCreationTime(e.Pid);
                        if (ct != 0 && parent.CreationTime != 0 && ct < parent.CreationTime) continue;
                        var m = new TreeMember();
                        m.Pid = e.Pid;
                        m.ParentPid = e.ParentPid;
                        m.Name = e.Name;
                        m.CreationTime = ct;
                        m.AddedAt = DateTime.UtcNow;
                        lock (Gate) { if (!r.Members.ContainsKey(e.Pid)) { r.Members[e.Pid] = m; grew = true; } }
                    }
                }
            }
        }

        /// The root whose tree contains pid (creation time checked), or 0.
        private static int RootOf(int pid, out TreeMember member, out bool kill)
        {
            member = null;
            kill = false;
            Root hit = null;
            lock (Gate)
            {
                foreach (Root r in Roots.Values)
                {
                    TreeMember m;
                    if (r.Members.TryGetValue(pid, out m)) { hit = r; member = m; kill = r.Kill; break; }
                }
            }
            if (hit == null) return 0;
            if (member.CreationTime != 0)
            {
                long now = Native.ProcessCreationTime(pid);
                if (now != 0 && now != member.CreationTime) { member = null; kill = false; return 0; }
            }
            return hit.Pid;
        }

        /// One synchronous foreground sample; public so self-tests can drive the detector.
        public static bool SampleOnce()
        {
            return SampleWindow(Native.ForegroundWindow());
        }

        /// Evaluates fg as if it were the foreground window (the sampler's decision without a
        /// real focus change; self-tests use it so they never take focus from the user).
        public static bool SampleWindow(IntPtr fg)
        {
            Interlocked.Increment(ref _samples);
            if (fg == IntPtr.Zero)
            {
                lock (Gate) { _lastHwnd = IntPtr.Zero; }
                return false;
            }
            int pid = Native.WindowProcessId(fg);
            TreeMember member;
            bool kill;
            int root = RootOf(pid, out member, out kill);
            if (root == 0)
            {
                lock (Gate) { _lastHwnd = IntPtr.Zero; }
                return false;
            }
            bool fresh;
            lock (Gate)
            {
                fresh = fg != _lastHwnd;
                if (fresh)
                {
                    var v = new FocusViolation();
                    v.At = DateTime.UtcNow;
                    v.Kind = "focus";
                    v.Pid = pid;
                    v.Root = root;
                    v.Hwnd = fg.ToInt64();
                    v.Process = member.Name;
                    try { v.Class = Native.ClassName(fg); v.Title = Native.Title(fg); } catch { }
                    Violations.Add(v);
                    _lastHwnd = fg;
                }
            }
            if (fresh && kill) KillTree(root);
            return true;
        }

        /// One synchronous visibility scan over the guarded trees; true when a new visible
        /// window was found. Public so self-tests can drive the guard.
        public static bool ScanVisibleOnce()
        {
            var owner = new Dictionary<int, Root>();
            lock (Gate)
            {
                foreach (Root r in Roots.Values)
                {
                    if (!r.GuardVisible || r.Teardown) continue;
                    foreach (int p in r.Members.Keys) owner[p] = r;
                }
            }
            Interlocked.Increment(ref _scans);
            if (owner.Count == 0) return false;
            bool found = false;
            var kills = new List<int>();
            foreach (IntPtr h in Native.AllTopLevelWindows())
            {
                int pid = Native.WindowProcessId(h);
                Root r;
                if (!owner.TryGetValue(pid, out r)) continue;
                if (!Native.IsWindowVisible(h) || Native.IsIconic(h)) continue;
                Native.RECT rect;
                if (!Native.GetWindowRect(h, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) continue;
                int? cloaked = Native.Cloaked(h);
                if (cloaked == null) continue;
                if (cloaked.Value != 0) { bool on = Native.OnAnyMonitor(h); lock (Gate) { r.Placements.Add(on ? "cloaked" : "cloaked-offscreen"); } continue; }
                if (!Native.OnAnyMonitor(h)) { lock (Gate) { r.Placements.Add("offscreen"); } continue; }
                // Re-check after the slower calls: a window hidden meanwhile is not a hit.
                if (!Native.IsWindowVisible(h)) continue;
                TreeMember m;
                bool kill;
                if (RootOf(pid, out m, out kill) != r.Pid) continue;
                lock (Gate)
                {
                    if (r.Teardown) continue;
                    r.Placements.Add("onscreen");
                    if (!r.ReportedVisible.Add(h.ToInt64())) continue;
                    var v = new FocusViolation();
                    v.At = DateTime.UtcNow;
                    v.Kind = "visible";
                    v.Pid = pid;
                    v.Root = r.Pid;
                    v.Hwnd = h.ToInt64();
                    v.Process = m != null ? m.Name : null;
                    try { v.Class = Native.ClassName(h); v.Title = Native.Title(h); } catch { }
                    v.Detail = "rect=(" + rect.Left + "," + rect.Top + ")-(" + rect.Right + "," + rect.Bottom + ") cloaked=0";
                    Visible.Add(v);
                    found = true;
                    if (r.Kill) kills.Add(r.Pid);
                }
            }
            foreach (int k in kills) KillTree(k);
            return found;
        }

        /// Terminates every live member of the tree whose creation time still matches.
        public static int KillTree(int root)
        {
            return KillMembers(TreeOf(root));
        }

        public static int KillMembers(TreeMember[] members)
        {
            int n = 0;
            if (members == null) return 0;
            foreach (TreeMember m in members)
            {
                try { if (Native.TerminateIfSame(m.Pid, m.CreationTime)) n++; } catch { }
            }
            return n;
        }

        /// Members that still exist (listed by Toolhelp with the same image name and, when it
        /// can be read, the same creation time). Includes processes still in teardown.
        public static TreeMember[] AliveMembers(TreeMember[] members)
        {
            var alive = new List<TreeMember>();
            if (members == null) return alive.ToArray();
            var snap = Native.SnapshotProcesses();
            foreach (TreeMember m in members)
            {
                Native.ProcEntry e;
                if (!snap.TryGetValue(m.Pid, out e)) continue;
                if (m.Name != null && m.Name != "?" && !string.Equals(e.Name, m.Name, StringComparison.OrdinalIgnoreCase)) continue;
                long ct = Native.ProcessCreationTime(m.Pid);
                if (ct != 0 && m.CreationTime != 0 && ct != m.CreationTime) continue;
                alive.Add(m);
            }
            return alive.ToArray();
        }
    }

    /// PrintWindow capture into a 32bpp DIB (no System.Drawing), region statistics and a
    /// minimal PNG writer (spike S2, S2Native.PrintWindowCapture and SavePng).
    public sealed class Capture
    {
        [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
        [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] private static extern bool GdiFlush();
        [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

        [StructLayout(LayoutKind.Sequential)]
        private struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight;
            public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }

        public bool Ok;
        public int Error;
        public int Left, Top, Width, Height;
        public int[] Pixels;

        /// PrintWindow(hWnd, PW_RENDERFULLCONTENT) of the whole window, with the calling thread
        /// switched to per-monitor-v2 DPI awareness for the duration (physical pixels).
        public static Capture Window(IntPtr hWnd)
        {
            IntPtr old = IntPtr.Zero;
            try { old = Native.SetThreadDpiAwarenessContext(Native.PerMonitorAwareV2); } catch { }
            try
            {
                Native.RECT r;
                Native.GetWindowRect(hWnd, out r);
                var cap = new Capture();
                cap.Left = r.Left;
                cap.Top = r.Top;
                cap.Width = r.Right - r.Left;
                cap.Height = r.Bottom - r.Top;
                if (cap.Width <= 0 || cap.Height <= 0) return cap;
                IntPtr screen = GetDC(IntPtr.Zero);
                IntPtr mem = CreateCompatibleDC(screen);
                var bmi = new BITMAPINFOHEADER();
                bmi.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
                bmi.biWidth = cap.Width;
                bmi.biHeight = -cap.Height;
                bmi.biPlanes = 1;
                bmi.biBitCount = 32;
                IntPtr bits;
                IntPtr dib = CreateDIBSection(mem, ref bmi, 0, out bits, IntPtr.Zero, 0);
                IntPtr prev = SelectObject(mem, dib);
                try
                {
                    cap.Ok = Native.PrintWindow(hWnd, mem, 2 /* PW_RENDERFULLCONTENT */);
                    cap.Error = cap.Ok ? 0 : Marshal.GetLastWin32Error();
                    GdiFlush();
                    cap.Pixels = new int[cap.Width * cap.Height];
                    if (bits != IntPtr.Zero) Marshal.Copy(bits, cap.Pixels, 0, cap.Pixels.Length);
                }
                finally
                {
                    SelectObject(mem, prev);
                    DeleteObject(dib);
                    DeleteDC(mem);
                    ReleaseDC(IntPtr.Zero, screen);
                }
                return cap;
            }
            finally
            {
                if (old != IntPtr.Zero) { try { Native.SetThreadDpiAwarenessContext(old); } catch { } }
            }
        }

        /// Window() on a background thread: null when PrintWindow does not return within
        /// timeoutMs (a hung UI thread never answers WM_PRINT; the thread is abandoned).
        public static Capture WindowWithTimeout(IntPtr hWnd, int timeoutMs)
        {
            Capture result = null;
            Exception error = null;
            var t = new Thread(() => { try { result = Window(hWnd); } catch (Exception ex) { error = ex; } });
            t.IsBackground = true;
            t.Name = "wmux-e2e-capture";
            t.Start();
            if (!t.Join(Math.Max(1, timeoutMs))) return null;
            if (error != null) throw new InvalidOperationException("capture failed: " + error.Message, error);
            return result;
        }

        /// Screen rectangle of a window in the same (per-monitor-v2) coordinates as Window().
        public static Native.RECT ScreenRect(IntPtr hWnd)
        {
            IntPtr old = IntPtr.Zero;
            try { old = Native.SetThreadDpiAwarenessContext(Native.PerMonitorAwareV2); } catch { }
            try
            {
                Native.RECT r;
                Native.GetWindowRect(hWnd, out r);
                return r;
            }
            finally
            {
                if (old != IntPtr.Zero) { try { Native.SetThreadDpiAwarenessContext(old); } catch { } }
            }
        }

        /// Distinct RGB colours and the dominant colour fraction of a region (window coordinates).
        public RegionStats Stats(int x, int y, int w, int h)
        {
            var s = new RegionStats();
            if (Pixels == null) return s;
            int x0 = Math.Max(0, x), y0 = Math.Max(0, y);
            int x1 = Math.Min(Width, x + w), y1 = Math.Min(Height, y + h);
            if (x1 <= x0 || y1 <= y0) return s;
            var counts = new Dictionary<int, int>();
            long total = 0;
            for (int yy = y0; yy < y1; yy++)
            {
                int row = yy * Width;
                for (int xx = x0; xx < x1; xx++)
                {
                    int rgb = Pixels[row + xx] & 0xFFFFFF;
                    int n;
                    counts.TryGetValue(rgb, out n);
                    counts[rgb] = n + 1;
                    total++;
                }
            }
            int best = 0;
            foreach (var kv in counts) if (kv.Value > best) { best = kv.Value; s.Dominant = kv.Key; }
            s.Pixels = total;
            s.Distinct = counts.Count;
            s.DominantFraction = total > 0 ? (double)best / total : 1.0;
            return s;
        }

        /// Minimal PNG writer (RGB8, filter 0, zlib).
        public void SavePng(string path)
        {
            int w = Width, h = Height;
            var raw = new byte[h * (1 + w * 3)];
            int o = 0;
            for (int y = 0; y < h; y++)
            {
                raw[o++] = 0;
                for (int x = 0; x < w; x++)
                {
                    int p = Pixels[y * w + x];
                    raw[o++] = (byte)((p >> 16) & 0xFF);
                    raw[o++] = (byte)((p >> 8) & 0xFF);
                    raw[o++] = (byte)(p & 0xFF);
                }
            }
            byte[] idat;
            using (var ms = new MemoryStream())
            {
                using (var z = new System.IO.Compression.ZLibStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) z.Write(raw, 0, raw.Length);
                idat = ms.ToArray();
            }
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                fs.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, 0, 8);
                var ihdr = new byte[13];
                WriteBE(ihdr, 0, (uint)w);
                WriteBE(ihdr, 4, (uint)h);
                ihdr[8] = 8;
                ihdr[9] = 2;
                WriteChunk(fs, "IHDR", ihdr);
                WriteChunk(fs, "IDAT", idat);
                WriteChunk(fs, "IEND", new byte[0]);
            }
        }

        private static void WriteBE(byte[] b, int off, uint v) { b[off] = (byte)(v >> 24); b[off + 1] = (byte)(v >> 16); b[off + 2] = (byte)(v >> 8); b[off + 3] = (byte)v; }

        private static uint[] _crc;
        private static uint Crc(byte[] type, byte[] data)
        {
            if (_crc == null)
            {
                var t = new uint[256];
                for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[n] = c; }
                _crc = t;
            }
            uint crc = 0xFFFFFFFFu;
            foreach (byte x in type) crc = _crc[(crc ^ x) & 0xFF] ^ (crc >> 8);
            foreach (byte x in data) crc = _crc[(crc ^ x) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }

        private static void WriteChunk(Stream s, string type, byte[] data)
        {
            var len = new byte[4];
            WriteBE(len, 0, (uint)data.Length);
            s.Write(len, 0, 4);
            var t = Encoding.ASCII.GetBytes(type);
            s.Write(t, 0, 4);
            s.Write(data, 0, data.Length);
            var crc = new byte[4];
            WriteBE(crc, 0, Crc(t, data));
            s.Write(crc, 0, 4);
        }
    }

    public sealed class RegionStats
    {
        public long Pixels;
        public int Distinct;
        public int Dominant;
        public double DominantFraction = 1.0;

        /// S2 rule for a rendered terminal: at least 3 colours and no colour above 99.9 %.
        public bool NotBlank { get { return Pixels > 0 && Distinct >= 3 && DominantFraction < 0.999; } }

        public override string ToString()
        {
            return "pixels=" + Pixels + " colors=" + Distinct + " dominant=0x" + (Dominant & 0xFFFFFF).ToString("X6") + " (" + (DominantFraction * 100).ToString("F2") + "%)";
        }
    }

    /// Self-test fixtures: a tiny no-activate tool window in a chosen placement. It never takes
    /// focus (WS_EX_NOACTIVATE, SW_SHOWNOACTIVATE), lets clicks through (WS_EX_TRANSPARENT) and
    /// is nearly transparent (layered, alpha 1), so the on-screen variant cannot disturb the user.
    public static class Fixtures
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowExW(uint exStyle, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] private static extern bool PeekMessageW(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll")] private static extern IntPtr DispatchMessageW(ref MSG msg);
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO info);

        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int cbSize; public Native.RECT rcMonitor, rcWork; public uint dwFlags; }

        /// Shows the window ("onscreen", "offscreen" or "cloaked"), pumps messages for holdMs,
        /// then destroys it. Returns 0; 2 when cloaking was requested but did not take effect
        /// (the window is then never shown); 3 when the window could not be created.
        public static int ShowProbeWindow(string placement, int holdMs)
        {
            const uint WS_POPUP = 0x80000000;
            const uint WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
            int x = -32000, y = -32000;
            if (placement != "offscreen" && placement != "hung")
            {
                var mi = new MONITORINFO();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                IntPtr mon = MonitorFromPoint(new POINT(), 1 /* MONITOR_DEFAULTTOPRIMARY */);
                if (GetMonitorInfoW(mon, ref mi)) { x = mi.rcWork.Right - 40; y = mi.rcWork.Bottom - 40; } else { x = 0; y = 0; }
            }
            IntPtr h = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOPMOST,
                "STATIC", "wmux-e2e-probe-" + placement, WS_POPUP, x, y, 24, 24, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (h == IntPtr.Zero) return 3;
            try
            {
                SetLayeredWindowAttributes(h, 0, 1, 0x2 /* LWA_ALPHA */);
                if (placement == "cloaked")
                {
                    int on = 1;
                    DwmSetWindowAttribute(h, 13 /* DWMWA_CLOAK */, ref on, 4);
                    int? c = Native.Cloaked(h);
                    if (c == null || c.Value == 0) return 2;
                }
                ShowWindow(h, 4 /* SW_SHOWNOACTIVATE */);
                if (placement == "hung")
                {
                    // Off-screen window whose thread stops pumping messages: IsHungAppWindow turns
                    // true after 5 s and PrintWindow would block (harness hang self-test, W0-ST).
                    MSG first;
                    while (PeekMessageW(out first, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref first); DispatchMessageW(ref first); }
                    Thread.Sleep(holdMs);
                    return 0;
                }
                var sw = Stopwatch.StartNew();
                while (sw.ElapsedMilliseconds < holdMs)
                {
                    MSG msg;
                    while (PeekMessageW(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
                    Thread.Sleep(20);
                }
                return 0;
            }
            finally { DestroyWindow(h); }
        }
    }

    /// Per-Test-Case watchdog: when it fires it kills the process trees of the instances
    /// registered for the running test so blocked pipe calls fail fast. Targets are Process
    /// objects (handle-based), and stopped instances are removed, so a recycled PID is never hit.
    public static class Watchdog
    {
        private static readonly object Gate = new object();
        private static readonly Dictionary<int, Process> Targets = new Dictionary<int, Process>();
        private static Timer _timer;
        private static long _generation;
        private static volatile bool _fired;

        public static void Arm(int timeoutMs)
        {
            lock (Gate)
            {
                if (_timer != null) { _timer.Dispose(); _timer = null; }
                Targets.Clear();
                _fired = false;
                long gen = ++_generation;
                _timer = new Timer(delegate (object state) { Fire(gen); }, null, Math.Max(1, timeoutMs), Timeout.Infinite);
            }
        }

        public static void Add(Process process)
        {
            if (process == null) return;
            lock (Gate) { Targets[process.Id] = process; }
        }

        public static void Remove(int pid)
        {
            lock (Gate) { Targets.Remove(pid); }
        }

        public static bool Disarm()
        {
            lock (Gate)
            {
                if (_timer != null) { _timer.Dispose(); _timer = null; }
                _generation++;
                return _fired;
            }
        }

        public static bool Fired { get { return _fired; } }

        private static void Fire(long gen)
        {
            Process[] targets;
            lock (Gate)
            {
                if (gen != _generation || _timer == null) return;
                _fired = true;
                targets = new Process[Targets.Count];
                Targets.Values.CopyTo(targets, 0);
            }
            foreach (Process p in targets)
            {
                try { if (!p.HasExited) p.Kill(true); } catch { }
            }
        }
    }

    /// Copies a redirected process stream to a file without involving a PowerShell runspace.
    public static class ProcessLog
    {
        public static Task Pump(Stream source, string path)
        {
            var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 1);
            return Task.Run(async () =>
            {
                try { await source.CopyToAsync(fs).ConfigureAwait(false); }
                catch { }
                finally { fs.Dispose(); }
            });
        }
    }

    /// Kill-on-close job objects: every instance is assigned to its own job so that the whole
    /// tree dies when the harness process exits, even if a test forgot to stop it.
    public static class JobObject
    {
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
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
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

        private const int JobObjectExtendedLimitInformation = 9;
        private const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr Create()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
            {
                CloseHandle(job);
                return IntPtr.Zero;
            }
            return job;
        }

        public static bool Assign(IntPtr job, IntPtr process)
        {
            if (job == IntPtr.Zero) return false;
            return AssignProcessToJobObject(job, process);
        }

        /// Closing the last handle kills every process still in the job.
        public static void Close(IntPtr job)
        {
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }
}
'@

function Initialize-WmuxHarnessType {
    $loaded = 'WmuxTestHarness.Native' -as [type]
    if ($loaded) {
        $version = $loaded::Version
        if ($version -ne $script:HarnessTypesVersion) {
            Write-Warning ("WmuxTest: helper types version {0} are already loaded in this process but the module expects {1}; start a new pwsh session." -f $version, $script:HarnessTypesVersion)
        }
        return
    }
    if ($env:WMUX_E2E_NO_TYPE_CACHE -ne '1') {
        try {
            $hashInput = [Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}' -f $script:HarnessTypeSource, $PSVersionTable.PSVersion, [Environment]::Version))
            $hash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hashInput))).Substring(0, 16).ToLowerInvariant()
            $cacheDir = Join-Path ([IO.Path]::GetTempPath()) 'wmux-e2e\typecache'
            $dll = Join-Path $cacheDir "WmuxTestHarness.$hash.dll"
            if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
                $null = New-Item -ItemType Directory -Force -Path $cacheDir
                $tmp = Join-Path $cacheDir ('WmuxTestHarness.{0}.{1}-{2}.dll' -f $hash, $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
                Add-Type -TypeDefinition $script:HarnessTypeSource -Language CSharp -OutputAssembly $tmp -OutputType Library -ErrorAction Stop
                try {
                    [IO.File]::Move($tmp, $dll)
                } catch {
                    # Another process published the same hash first; ours was never loaded.
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            Add-Type -Path $dll -ErrorAction Stop
            return
        } catch {
            Write-Verbose "WmuxTest: helper type cache unavailable, compiling in memory: $($_.Exception.Message)"
        }
    }
    if (-not ('WmuxTestHarness.Native' -as [type])) {
        Add-Type -TypeDefinition $script:HarnessTypeSource -Language CSharp -ErrorAction Stop
    }
}

Initialize-WmuxHarnessType

# ---------------------------------------------------------------------------
# Module state and constants
# ---------------------------------------------------------------------------

$script:ModuleRoot = $PSScriptRoot
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

$script:State = @{
    Instances     = [System.Collections.Generic.List[object]]::new()
    CurrentTest   = $null
    FailMark      = $false
    StreamCounter = 0
    # Ids of harness-generated legacy requests; far above the small ids tests pick themselves.
    LegacyId      = 1000000
    HiddenSupport = @{}
}

# Default terminal command (D.2.3). Single quotes: $G is the cmd prompt code for '>'.
$script:DefaultShell = 'cmd.exe /d /k prompt WMUX$G'

# Child environment scrubbing (D.2.4 plus agent markers and credentials).
$script:EnvKeepNames = @('WMUX_WEB_DIR', 'WMUX_WEB_DEVTOOLS')
$script:EnvStripPrefixes = @('CMUX_', 'CMUXTERM_', 'GHOSTTY_', 'WMUX_', 'CLAUDE_CODE_', 'ANTHROPIC_', 'CODEX_', 'OPENCODE_')
$script:EnvStripNames = @(
    'CLAUDECODE', 'CLAUDE_CODE', 'OPENCODE', 'AI_AGENT',
    'OPENAI_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN',
    # Ghostty's crash and cache dirs then fall back to the (redirected) LOCALAPPDATA.
    'XDG_STATE_HOME', 'XDG_CACHE_HOME'
)

# Legacy +verbs that Invoke-WmuxCli relays to wmux.exe for a legacy instance (before W1-1a).
# Anything else could start a second, unmanaged GUI, so it is refused.
$script:LegacyCliVerbs = @(
    '+workspace', '+tab', '+send', '+notify', '+surface', '+split', '+status', '+log',
    '+read-screen', '+capture-pane', '+session', '+browser', '+version', '+help'
)

$script:UuidPattern = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
$script:UuidSeqPattern = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-\d+$'
$script:RefPattern = '^([a-z][a-z_]*):(\d+)$'
$script:TimestampPattern = '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$'
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------------------
# Small internal helpers
# ---------------------------------------------------------------------------

function Get-WmuxProp {
    # Property or key value; arrays are returned intact (the leading comma stops unrolling).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return , $p.Value
}

function Test-WmuxHasProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-WmuxInnerException {
    param([Exception]$Exception)
    $e = $Exception
    while ($null -ne $e.InnerException -and (
            $e -is [System.Management.Automation.MethodInvocationException] -or
            $e -is [System.Management.Automation.GetValueInvocationException] -or
            $e -is [System.Management.Automation.SetValueInvocationException] -or
            $e -is [System.Reflection.TargetInvocationException] -or
            $e -is [AggregateException] -or
            ($e.GetType() -eq [System.Management.Automation.RuntimeException])
        )) {
        $e = $e.InnerException
    }
    return $e
}

function Find-WmuxException {
    # Walks the InnerException chain for an exception of the given type.
    param([Exception]$Exception, [type]$Type)
    $e = $Exception
    while ($null -ne $e) {
        if ($Type.IsInstanceOfType($e)) { return $e }
        $e = $e.InnerException
    }
    return $null
}

function New-WmuxHarnessError {
    param([string]$Code, [string]$Message, [string]$Method, [Exception]$Inner)
    return [WmuxRpcError]::new($Code, $Message, $null, $Method, $null, $null, $null, $Inner)
}

function Set-WmuxFailMark {
    $script:State.FailMark = $true
}

function ConvertTo-WmuxJsonText {
    param([AllowNull()]$Value)
    return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction SilentlyContinue)
}

function ConvertFrom-WmuxJsonText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [WmuxTestHarness.Json]::Parse($Text)
}

function Format-WmuxValue {
    param([AllowNull()]$Value, [int]$Max = 400)
    if ($null -eq $Value) { return 'null' }
    try {
        $text = if ($Value -is [string]) { ConvertTo-Json -InputObject $Value -Compress } else { ConvertTo-WmuxJsonText $Value }
    } catch {
        $text = [string]$Value
    }
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) + '...(' + $text.Length + ' chars)' }
    return $text
}

function Get-WmuxSlug {
    param([string]$Text, [int]$Max = 48)
    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt $Max) { $slug = $slug.Substring(0, $Max).Trim('-') }
    if (-not $slug) { $slug = 'x' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 6).ToLowerInvariant()
    return "$slug-$hash"
}

function Test-WmuxIsNumber {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [uint64] -or $Value -is [uint32] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [single] -or $Value -is [System.Numerics.BigInteger])
}

function Test-WmuxIsIntegral {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint64] -or $Value -is [uint32] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [System.Numerics.BigInteger]) { return $true }
    if ($Value -is [double] -or $Value -is [single]) { return ([double]$Value -eq [Math]::Floor([double]$Value)) -and -not [double]::IsInfinity([double]$Value) }
    if ($Value -is [decimal]) { return $Value -eq [decimal]::Truncate($Value) }
    return $false
}

function Get-WmuxValueKind {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool]) { return 'bool' }
    if (Test-WmuxIsNumber $Value) { return 'number' }
    if ($Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) { return 'array' }
    return 'other'
}

function Test-WmuxIsIntegerType {
    param([AllowNull()]$Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [uint64] -or $Value -is [uint32] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [System.Numerics.BigInteger])
}

function Test-WmuxNumberEqual {
    # Exact for integers of any width (u64 surface ids survive), decimal-aware, else double.
    param($A, $B)
    if ((Test-WmuxIsIntegerType $A) -and (Test-WmuxIsIntegerType $B)) {
        return ([System.Numerics.BigInteger]$A -eq [System.Numerics.BigInteger]$B)
    }
    if ($A -is [decimal] -or $B -is [decimal]) {
        try { return ([decimal]$A -eq [decimal]$B) } catch { }
    }
    return ([double]$A -eq [double]$B)
}

function ConvertTo-WmuxNormalizedJson {
    # Any value (hashtable, PSCustomObject, JSON text, scalar) to the canonical value tree
    # produced by [WmuxTestHarness.Json]::Parse.
    param([AllowNull()]$Value, [switch]$ParseStrings)
    if ($Value -is [string]) {
        if ($ParseStrings) {
            $t = $Value.Trim()
            if ($t.StartsWith('{') -or $t.StartsWith('[')) {
                $parsed = $null
                if ([WmuxTestHarness.Json]::TryParse($t, [ref]$parsed)) { return , $parsed }
            }
        }
        return $Value
    }
    if ($null -eq $Value) { return $null }
    return , ([WmuxTestHarness.Json]::Parse((ConvertTo-WmuxJsonText $Value)))
}

function ConvertTo-WmuxCanonicalJson {
    # Normalized value to JSON text with object keys sorted (ordinal), for deep equality.
    param([AllowNull()]$Value)
    $kind = Get-WmuxValueKind $Value
    switch ($kind) {
        'null' { return 'null' }
        'string' { return (ConvertTo-Json -InputObject $Value -Compress) }
        'bool' { return $(if ($Value) { 'true' } else { 'false' }) }
        'number' { return (ConvertTo-Json -InputObject $Value -Compress) }
        'array' {
            $parts = foreach ($item in $Value) { ConvertTo-WmuxCanonicalJson $item }
            return '[' + (@($parts) -join ',') + ']'
        }
        'object' {
            $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [string]$_ }) } else { @($Value.PSObject.Properties.Name) }
            $sorted = [string[]]$names
            [Array]::Sort($sorted, [StringComparer]::Ordinal)
            $parts = foreach ($n in $sorted) { (ConvertTo-Json -InputObject $n -Compress) + ':' + (ConvertTo-WmuxCanonicalJson (Get-WmuxProp $Value $n)) }
            return '{' + (@($parts) -join ',') + '}'
        }
        default { return (ConvertTo-Json -InputObject ([string]$Value) -Compress) }
    }
}

function Test-WmuxValueEqual {
    param([AllowNull()]$Expected, [AllowNull()]$Actual)
    $ek = Get-WmuxValueKind $Expected
    $ak = Get-WmuxValueKind $Actual
    if ($ek -eq 'other' -or $ak -eq 'other') {
        if ($null -eq $Expected -or $null -eq $Actual) { return ($null -eq $Expected -and $null -eq $Actual) }
        return [bool]($Expected -eq $Actual)
    }
    if ($ek -ne $ak) { return $false }
    switch ($ek) {
        'null' { return $true }
        'string' { return [string]::Equals($Expected, $Actual, [StringComparison]::Ordinal) }
        'bool' { return ([bool]$Expected -eq [bool]$Actual) }
        'number' { return (Test-WmuxNumberEqual $Expected $Actual) }
        'array' {
            if ($Expected.Count -ne $Actual.Count) { return $false }
            for ($i = 0; $i -lt $Expected.Count; $i++) {
                if (-not (Test-WmuxValueEqual $Expected[$i] $Actual[$i])) { return $false }
            }
            return $true
        }
        'object' {
            $e = ConvertTo-WmuxCanonicalJson (ConvertTo-WmuxNormalizedJson $Expected)
            $a = ConvertTo-WmuxCanonicalJson (ConvertTo-WmuxNormalizedJson $Actual)
            return [string]::Equals($e, $a, [StringComparison]::Ordinal)
        }
    }
    return $false
}

function Get-WmuxCallerLocation {
    # "file.e2e.ps1:42" for the innermost frame outside this module.
    $frames = Get-PSCallStack
    foreach ($f in $frames) {
        if ($f.ScriptName -and $f.ScriptName -ne $PSCommandPath) {
            return ('{0}:{1}' -f (Split-Path -Leaf $f.ScriptName), $f.ScriptLineNumber)
        }
    }
    return $null
}

function Throw-WmuxAssertion {
    param([string]$Text, [string]$Message)
    $full = $Text
    if ($Message) { $full = "$Message -- $Text" }
    $where = Get-WmuxCallerLocation
    if ($where) { $full = "$full (at $where)" }
    Set-WmuxFailMark
    throw [WmuxAssertionError]::new($full)
}

# ---------------------------------------------------------------------------
# Naming: channel, sidhash8, session, pipe names (ADR-3.1, D.2.6)
# ---------------------------------------------------------------------------

function ConvertTo-WmuxChannel {
    # Lowercase, every byte outside [a-z0-9-] becomes '-', at most 40 characters (ADR-3.1).
    # Keep in sync with src/wmux_proto/pipe_name.zig once W1-1a lands it.
    param([Parameter(Mandatory)][string]$Name)
    $lower = $Name.ToLowerInvariant()
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $lower.ToCharArray()) {
        if (($ch -ge [char]'a' -and $ch -le [char]'z') -or ($ch -ge [char]'0' -and $ch -le [char]'9') -or $ch -eq [char]'-') {
            $null = $sb.Append($ch)
        } else {
            $null = $sb.Append([char]'-')
        }
    }
    $channel = $sb.ToString()
    if ($channel.Length -gt 40) { $channel = $channel.Substring(0, 40) }
    if ($channel.Length -eq 0) { throw [ArgumentException]::new('channel name is empty') }
    return $channel
}

function Get-WmuxCurrentUserSid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-WmuxSidHash8 {
    # Lowercase hex of the first 4 bytes of SHA-256(UTF-8 user SID string).
    param([string]$Sid = (Get-WmuxCurrentUserSid))
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Sid))
    return ([Convert]::ToHexString($bytes, 0, 4)).ToLowerInvariant()
}

function Get-WmuxSessionId {
    return [System.Diagnostics.Process]::GetCurrentProcess().SessionId
}

function Get-WmuxPipeName {
    # Bare control pipe name wmux-<channel>-<sidhash8>-s<session>; -Launch appends -launch.
    param(
        [Parameter(Mandatory)][string]$Channel,
        [string]$SidHash8,
        [Nullable[int]]$Session,
        [switch]$Launch
    )
    $ch = ConvertTo-WmuxChannel $Channel
    if (-not $SidHash8) { $SidHash8 = Get-WmuxSidHash8 }
    if ($null -eq $Session) { $Session = Get-WmuxSessionId }
    $name = 'wmux-{0}-{1}-s{2}' -f $ch, $SidHash8, $Session
    if ($Launch) { $name += '-launch' }
    return $name
}

function ConvertTo-WmuxFullPipePath {
    param([Parameter(Mandatory)][string]$Name)
    return [WmuxTestHarness.PipeIO]::FullName($Name)
}

# ---------------------------------------------------------------------------
# Envelope encoding and decoding (ADR-3.4)
# ---------------------------------------------------------------------------

function New-WmuxRpcRequestLine {
    param(
        [Parameter(Mandatory)][string]$Method,
        [AllowNull()]$Params,
        [AllowNull()]$Id = ([guid]::NewGuid().ToString())
    )
    if ($null -eq $Params) {
        $p = [ordered]@{}
    } elseif ($Params -is [System.Collections.IDictionary] -or $Params -is [System.Management.Automation.PSCustomObject]) {
        $p = $Params
    } else {
        throw [ArgumentException]::new("params for '$Method' must be a hashtable or object, got $($Params.GetType().FullName)")
    }
    $envelope = [ordered]@{ id = $Id; method = $Method; params = $p }
    return (ConvertTo-WmuxJsonText $envelope)
}

function ConvertFrom-WmuxRpcReply {
    # Decodes one v2 reply line. Returns result (or the whole envelope with -Raw); throws
    # [WmuxRpcError] for ok:false and for malformed or mismatched replies.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [AllowNull()]$RequestId,
        [string]$Method,
        [switch]$Raw
    )
    $reply = $null
    if (-not [WmuxTestHarness.Json]::TryParse($Line, [ref]$reply) -or (Get-WmuxValueKind $reply) -ne 'object') {
        throw [WmuxRpcError]::new('harness_bad_reply', "reply to '$Method' is not a JSON object: $(Format-WmuxValue $Line)", $null, $Method, $RequestId, $Line, $null, $null)
    }
    $ok = Get-WmuxProp $reply 'ok'
    $err = Get-WmuxProp $reply 'error'
    # Legacy wmux JSON answers {"ok","data"} or {"ok","error":"<string>"} (id 0 when it could
    # not parse a v2 request); detect it before the id check so the cause is reported.
    $legacyShape = ($err -is [string]) -or ((Test-WmuxHasProp $reply 'data') -and -not (Test-WmuxHasProp $reply 'result'))
    if ($ok -isnot [bool] -and -not $legacyShape) {
        throw [WmuxRpcError]::new('harness_bad_reply', "reply to '$Method' has no boolean 'ok': $(Format-WmuxValue $Line)", $null, $Method, $RequestId, $Line, $null, $null)
    }
    if ($legacyShape) {
        if ($Raw) { return , $reply }
        throw [WmuxRpcError]::new('harness_legacy_protocol', "reply to '$Method' uses the legacy wmux JSON shape: $(Format-WmuxValue $Line)", $null, $Method, $RequestId, $Line, $err, $null)
    }
    $replyId = Get-WmuxProp $reply 'id'
    $idMatches = ($null -eq $RequestId) -or (Test-WmuxValueEqual $RequestId $replyId)
    if ($ok) {
        if (-not $idMatches) {
            throw [WmuxRpcError]::new('harness_id_mismatch', "reply id $(Format-WmuxValue $replyId) does not match request id $(Format-WmuxValue $RequestId) for '$Method'", $null, $Method, $RequestId, $Line, $null, $null)
        }
        if ($Raw) { return , $reply }
        return , (Get-WmuxProp $reply 'result')
    }
    if (-not $idMatches -and $null -ne $replyId) {
        throw [WmuxRpcError]::new('harness_id_mismatch', "error reply id $(Format-WmuxValue $replyId) does not match request id $(Format-WmuxValue $RequestId) for '$Method'", $null, $Method, $RequestId, $Line, $null, $null)
    }
    if ($Raw) { return , $reply }
    $code = [string](Get-WmuxProp $err 'code')
    if (-not $code) { $code = 'harness_bad_reply' }
    $message = Get-WmuxProp $err 'message'
    $data = Get-WmuxProp $err 'data'
    throw [WmuxRpcError]::new($code, [string]$message, $data, $Method, $RequestId, $Line, $err, $null)
}

function ConvertFrom-WmuxLegacyReply {
    # Legacy wmux JSON reply {"id":N,"ok":true,"data":...} / {"id":N,"ok":false,"error":"..."}.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $reply = $null
    if (-not [WmuxTestHarness.Json]::TryParse($Line, [ref]$reply) -or (Get-WmuxValueKind $reply) -ne 'object' -or (Get-WmuxProp $reply 'ok') -isnot [bool]) {
        throw [WmuxRpcError]::new('harness_bad_reply', "not a legacy wmux JSON reply: $(Format-WmuxValue $Line)")
    }
    return , $reply
}

# ---------------------------------------------------------------------------
# Instance setup helpers (D.2)
# ---------------------------------------------------------------------------

function ConvertTo-WmuxSettingsDocument {
    # { "automation": { "socketControlMode": "automation" } } deep-merged with -Settings.
    # Dotted keys expand into nested objects: @{ 'sidebar.showPorts' = $false }.
    param([System.Collections.IDictionary]$Settings)
    $doc = [ordered]@{ automation = [ordered]@{ socketControlMode = 'automation' } }
    if ($null -eq $Settings) { return , $doc }
    foreach ($key in $Settings.Keys) {
        $parts = ([string]$key).Split('.')
        if ($parts | Where-Object { $_ -eq '' }) { throw [ArgumentException]::new("invalid settings key '$key'") }
        $node = $doc
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $part = $parts[$i]
            if (-not $node.Contains($part)) {
                $node[$part] = [ordered]@{}
            } elseif ($node[$part] -isnot [System.Collections.IDictionary]) {
                throw [ArgumentException]::new("settings key '$key' conflicts with the non-object value at '$(($parts[0..$i]) -join '.')'")
            }
            $node = $node[$part]
        }
        Merge-WmuxSettingValue -Target $node -Key $parts[-1] -Value $Settings[$key] -FullKey ([string]$key)
    }
    return , $doc
}

function Merge-WmuxSettingValue {
    param([System.Collections.IDictionary]$Target, [string]$Key, $Value, [string]$FullKey)
    if ($Value -is [System.Collections.IDictionary]) {
        if (-not $Target.Contains($Key)) {
            $Target[$Key] = [ordered]@{}
        } elseif ($Target[$Key] -isnot [System.Collections.IDictionary]) {
            throw [ArgumentException]::new("settings key '$FullKey' conflicts with a non-object value")
        }
        foreach ($k in $Value.Keys) {
            Merge-WmuxSettingValue -Target $Target[$Key] -Key ([string]$k) -Value $Value[$k] -FullKey "$FullKey.$k"
        }
        return
    }
    if ($Target.Contains($Key) -and $Target[$Key] -is [System.Collections.IDictionary]) {
        throw [ArgumentException]::new("settings key '$FullKey' would replace an object with a scalar")
    }
    $Target[$Key] = $Value
}

function New-WmuxGhosttyConfText {
    # ghostty.conf = command = <shell> plus the -Ghostty lines (later lines win in Ghostty).
    param([string]$Shell, [string[]]$Ghostty, [string]$Id)
    if (-not $Shell) { $Shell = $script:DefaultShell }
    if ($Shell -match '[\r\n]') { throw [ArgumentException]::new('-Shell must be a single line') }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Generated by test/e2e/WmuxTest.psm1 for e2e instance $Id. Do not edit.")
    # No close confirmation dialogs: a modal box could appear on screen during a test.
    $lines.Add('confirm-close-surface = false')
    $lines.Add("command = $Shell")
    foreach ($l in @($Ghostty)) {
        if ($null -eq $l) { continue }
        foreach ($part in ([string]$l -split "`r?`n")) { $lines.Add($part) }
    }
    return (($lines -join "`n") + "`n")
}

function Test-WmuxEnvStripped {
    param([string]$Name)
    foreach ($keep in $script:EnvKeepNames) {
        if ([string]::Equals($keep, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    foreach ($prefix in $script:EnvStripPrefixes) {
        if ($Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($n in $script:EnvStripNames) {
        if ([string]::Equals($n, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-WmuxProcessEnvironment {
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $vars = [Environment]::GetEnvironmentVariables()
    foreach ($k in $vars.Keys) { $map[[string]$k] = [string]$vars[$k] }
    return , $map
}

function New-WmuxChildEnvironment {
    # Pure: the environment for a test instance derived from BaseEnvironment (D.2.4).
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$BaseEnvironment,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Visible,
        [switch]$Restore,
        [switch]$KeepLocalAppData
    )
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $BaseEnvironment.Keys) {
        $name = [string]$key
        if (Test-WmuxEnvStripped $name) { continue }
        $map[$name] = [string]$BaseEnvironment[$key]
    }
    $map['WMUX_TEST_MODE'] = '1'
    if (-not $Visible) { $map['WMUX_TEST_HIDDEN'] = '1' }
    $map['WMUX_CHANNEL'] = "test-$Id"
    $map['WMUX_STATE_DIR'] = Join-Path $Root 'state'
    $map['WMUX_CONFIG_DIR'] = Join-Path $Root 'config'
    $map['XDG_CONFIG_HOME'] = Join-Path $Root 'xdg'
    $map['WMUX_SOCKET_MODE'] = 'automation'
    if ($Restore) {
        $map['WMUX_TEST_SESSION_RESTORE'] = '1'
    } else {
        $map['WMUX_DISABLE_SESSION_RESTORE'] = '1'
    }
    $map['WMUX_TEST_TOAST_SINK'] = Join-Path $Root 'toasts.jsonl'
    if (-not $KeepLocalAppData) {
        # Transitional isolation: the legacy app keeps session-state.json, window-state and
        # WebView2 data under %LOCALAPPDATA%\ghostty; never let a test touch the user's copy.
        $map['LOCALAPPDATA'] = Join-Path $Root 'localappdata'
    }
    return , $map
}

function Initialize-WmuxLocalAppData {
    # Seeds the redirected LOCALAPPDATA of a legacy instance: a fresh update_check_at makes the
    # app skip its startup update check (a network fetch that can end in a tray balloon on the
    # user's screen). Remove once WMUX_TEST_MODE turns the update check off (ADR-12.3).
    param([Parameter(Mandatory)][string]$LocalAppData)
    $dir = Join-Path $LocalAppData 'ghostty'
    $null = New-Item -ItemType Directory -Force -Path $dir
    [IO.File]::WriteAllText((Join-Path $dir 'update_check_at'), [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $script:Utf8NoBom)
}

function Get-WmuxCliEnvironment {
    # Environment for Invoke-WmuxCli: the instance environment plus the socket pointers.
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [System.Collections.IDictionary]$Env)
    $map = New-WmuxChildEnvironment -BaseEnvironment (Get-WmuxProcessEnvironment) -Root $Instance.Root -Id $Instance.Id `
        -Visible:$Instance.Visible -KeepLocalAppData:([string]::IsNullOrEmpty($Instance.LocalAppData))
    $map['WMUX_SOCKET_PATH'] = $Instance.Pipe
    $map['CMUX_SOCKET_PATH'] = $Instance.Pipe
    # Legacy +verb discovery uses GHOSTTY_PID; point it at the test instance, never the user's.
    $map['GHOSTTY_PID'] = [string]$Instance.Pid
    if ($null -ne $Env) {
        foreach ($k in $Env.Keys) {
            $v = $Env[$k]
            if ($null -eq $v) { $null = $map.Remove([string]$k) } else { $map[[string]$k] = [string]$v }
        }
    }
    return , $map
}

function Resolve-WmuxExe {
    param([string]$Build, [string]$Exe)
    if ($Exe) {
        $path = $Exe
    } elseif ($Build -eq 'Release') {
        $path = Join-Path $script:RepoRoot 'zig-out\release\bin\wmux.exe'
    } elseif ($Build -eq 'Debug') {
        $path = Join-Path $script:RepoRoot 'zig-out\bin\wmux.exe'
    } elseif ($env:WMUX_E2E_EXE) {
        $path = $env:WMUX_E2E_EXE
    } else {
        $path = Join-Path $script:RepoRoot 'zig-out\bin\wmux.exe'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw [WmuxAssertionError]::new("wmux.exe not found at '$path'. Build it (zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu), run 'pwsh test/e2e/run.ps1 -Build Debug', or pass -Exe.")
    }
    return (Resolve-Path -LiteralPath $path).ProviderPath
}

function Test-WmuxHiddenSupport {
    # True when the executable contains the WMUX_TEST_HIDDEN switch (W0-A1). Cached per file state.
    param([Parameter(Mandatory)][string]$Exe)
    $item = Get-Item -LiteralPath $Exe
    $key = '{0}|{1}|{2}' -f $item.FullName.ToLowerInvariant(), $item.Length, $item.LastWriteTimeUtc.Ticks
    if (-not $script:State.HiddenSupport.ContainsKey($key)) {
        $script:State.HiddenSupport[$key] = [WmuxTestHarness.Native]::FileContains($item.FullName, 'WMUX_TEST_HIDDEN')
    }
    return [bool]$script:State.HiddenSupport[$key]
}

function Get-WmuxTempBase {
    # D.2.1: $env:RUNNER_TEMP, else $env:TEMP (8.3 short names are expanded).
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $base = [IO.Path]::GetFullPath($base)
    if (Test-Path -LiteralPath $base) { $base = [WmuxTestHarness.Native]::LongPath($base) }
    return $base
}

function Get-WmuxTail {
    param([string]$Path, [int]$Lines = 20)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $reader = [IO.StreamReader]::new($fs, $script:Utf8NoBom)
            $all = $reader.ReadToEnd()
        } finally { $fs.Dispose() }
        $parts = $all -split "`r?`n"
        return (($parts | Select-Object -Last $Lines) -join "`n")
    } catch {
        return ''
    }
}

function Invoke-WmuxPipeLine {
    # One request line over the instance pipe; transport failures become [WmuxRpcError].
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [Parameter(Mandatory)][string]$Line, [double]$TimeoutSec = 15, [string]$Method = 'line', [string]$Pipe)
    if (-not $Pipe) { $Pipe = $Instance.Pipe }
    try {
        # OutstandingIds: late replies to earlier timed-out requests are skipped (see PipeIO.RoundTrip).
        return [WmuxTestHarness.PipeIO]::RoundTrip($Pipe, $Line, [int]([Math]::Max(1, $TimeoutSec * 1000)), $Instance.OutstandingIds)
    } catch {
        $ex = Get-WmuxInnerException $_.Exception
        $code = 'harness_transport'
        if ($ex -is [TimeoutException]) { $code = 'harness_timeout' }
        elseif ($ex -is [IO.EndOfStreamException]) { $code = 'harness_eof' }
        $msg = "$Method over ${Pipe}: $($ex.Message)"
        if ($null -ne $Instance.Process) {
            try {
                if ($Instance.Process.HasExited) { $msg += " (wmux pid $($Instance.Pid) exited with code $($Instance.Process.ExitCode))" }
            } catch { }
        }
        throw (New-WmuxHarnessError -Code $code -Message $msg -Method $Method -Inner $ex)
    }
}

function Assert-WmuxInstanceUsable {
    param([WmuxInstance]$Instance, [string]$What)
    if ($Instance.Stopped) {
        throw (New-WmuxHarnessError -Code 'harness_instance_stopped' -Message "${What}: instance pid $($Instance.Pid) was already stopped" -Method $What)
    }
}

function Assert-WmuxV2 {
    param([WmuxInstance]$Instance, [string]$What)
    if ($Instance.Protocol -ne 'v2') {
        throw (New-WmuxHarnessError -Code 'harness_legacy_protocol' -Message "${What}: instance pid $($Instance.Pid) speaks the legacy wmux JSON protocol (the v2 server lands in W1-1a); use Invoke-WmuxRawLine" -Method $What)
    }
}

function Invoke-WmuxLegacyCommand {
    # Legacy JSON command; returns data or throws [WmuxRpcError] code 'legacy_error'.
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [Parameter(Mandatory)][string]$Cmd, [System.Collections.IDictionary]$Arguments, [double]$TimeoutSec = 15)
    $script:State.LegacyId++
    $id = $script:State.LegacyId
    $req = [ordered]@{ id = $id; cmd = $Cmd }
    if ($null -ne $Arguments) { $req.args = $Arguments }
    $line = ConvertTo-WmuxJsonText $req
    $replyLine = Invoke-WmuxPipeLine -Instance $Instance -Line $line -TimeoutSec $TimeoutSec -Method $Cmd -Pipe $(if ($Instance.LegacyPipe) { $Instance.LegacyPipe } else { $Instance.Pipe })
    $reply = ConvertFrom-WmuxLegacyReply $replyLine
    $replyId = Get-WmuxProp $reply 'id'
    if (-not (Test-WmuxValueEqual ([long]$id) $replyId)) {
        throw [WmuxRpcError]::new('harness_id_mismatch', "legacy '$Cmd' (id $id) was answered with id $(Format-WmuxValue $replyId): $(Format-WmuxValue $replyLine)", $null, $Cmd, $id, $replyLine, $null, $null)
    }
    if (-not $reply.ok) {
        throw [WmuxRpcError]::new('legacy_error', [string](Get-WmuxProp $reply 'error'), $null, $Cmd, $id, $replyLine, (Get-WmuxProp $reply 'error'), $null)
    }
    return , (Get-WmuxProp $reply 'data')
}

function Wait-WmuxInstanceReady {
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [double]$TimeoutSec = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $legacyName = "wmux-ipc-$($Instance.Pid)"
    $v2Name = Get-WmuxPipeName -Channel $Instance.Channel
    $marker = Join-Path $Instance.StateDir 'run\instance.json'
    $last = 'no pipe yet'
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($Instance.Process.HasExited) {
            $tail = Get-WmuxTail (Join-Path $Instance.LogDir 'wmux.stderr.log') 30
            throw [WmuxAssertionError]::new("wmux exited during startup with code $($Instance.Process.ExitCode) (pid $($Instance.Pid)). stderr tail:`n$tail")
        }
        $v2Pipe = $null
        $launchPipe = $null
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            try {
                $m = ConvertFrom-WmuxJsonText ([IO.File]::ReadAllText($marker))
                $markerPid = Get-WmuxProp $m 'pid'
                if ((Get-WmuxProp $m 'pipe') -and ($null -eq $markerPid -or [long]$markerPid -eq $Instance.Pid)) {
                    $v2Pipe = ConvertTo-WmuxFullPipePath ([string](Get-WmuxProp $m 'pipe'))
                    if (Get-WmuxProp $m 'launch_pipe') { $launchPipe = ConvertTo-WmuxFullPipePath ([string](Get-WmuxProp $m 'launch_pipe')) }
                }
            } catch {
                $last = "unreadable marker: $($_.Exception.Message)"
            }
        }
        $pipes = [WmuxTestHarness.Native]::ListPipes('wmux-')
        if (-not $v2Pipe -and ($pipes -contains $v2Name)) { $v2Pipe = ConvertTo-WmuxFullPipePath $v2Name }
        if ($v2Pipe) {
            try {
                $id = [guid]::NewGuid().ToString()
                $line = New-WmuxRpcRequestLine -Method 'wmux.debug.ready' -Params $null -Id $id
                $reply = [WmuxTestHarness.PipeIO]::RoundTrip($v2Pipe, $line, 2000, $Instance.OutstandingIds)
                $result = ConvertFrom-WmuxRpcReply -Line $reply -RequestId $id -Method 'wmux.debug.ready'
                if ((Get-WmuxProp $result 'ready') -eq $true) {
                    $Instance.Protocol = 'v2'
                    $Instance.Pipe = $v2Pipe
                    $Instance.LaunchPipe = if ($launchPipe) { $launchPipe } else { ConvertTo-WmuxFullPipePath (Get-WmuxPipeName -Channel $Instance.Channel -Launch) }
                    if ($pipes -contains $legacyName) { $Instance.LegacyPipe = ConvertTo-WmuxFullPipePath $legacyName }
                    return
                }
                $last = "wmux.debug.ready answered $(Format-WmuxValue $result)"
            } catch {
                $last = "v2 pipe $v2Pipe not ready: $((Get-WmuxInnerException $_.Exception).Message)"
            }
        } elseif ($pipes -contains $legacyName) {
            try {
                # The legacy app creates its pipe before the window and the message loop exist, so
                # early probes time out and their replies arrive later on another connection: every
                # probe gets its own id and late replies are skipped (OutstandingIds).
                $script:State.LegacyId++
                $probeId = $script:State.LegacyId
                $reply = [WmuxTestHarness.PipeIO]::RoundTrip($legacyName, ('{"id":' + $probeId + ',"cmd":"workspace-list"}'), 2000, $Instance.OutstandingIds)
                $parsed = ConvertFrom-WmuxLegacyReply $reply
                if ($parsed.ok -eq $true -and (Test-WmuxValueEqual ([long]$probeId) (Get-WmuxProp $parsed 'id'))) {
                    $Instance.Protocol = 'legacy'
                    $Instance.Pipe = ConvertTo-WmuxFullPipePath $legacyName
                    $Instance.LegacyPipe = $Instance.Pipe
                    # [NullString]: a plain $null would be stored as "" in a .NET string field.
                    $Instance.LaunchPipe = [NullString]::Value
                    return
                }
                $last = "legacy workspace-list answered $(Format-WmuxValue $reply)"
            } catch {
                $last = "legacy pipe not ready: $((Get-WmuxInnerException $_.Exception).Message)"
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw [WmuxAssertionError]::new("wmux instance pid $($Instance.Pid) not ready after ${TimeoutSec}s (looked for $v2Name, the marker $marker and $legacyName): $last")
}

function Get-WmuxArtifactBase {
    if ($env:WMUX_E2E_ARTIFACTS) { return $env:WMUX_E2E_ARTIFACTS }
    $file = if ($script:State.CurrentTest) { $script:State.CurrentTest.File } else { 'adhoc' }
    $leaf = if ($file) { [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($file)) } else { 'adhoc' }
    return (Join-Path $script:RepoRoot ('test-results\artifacts\' + (Get-WmuxSlug $leaf)))
}

function Get-WmuxWindowPlacement {
    # Where a top-level window is, as the user would see it: 'cloaked' (DWMWA_CLOAKED != 0, on a
    # monitor: the S2 placement, GL capturable), 'cloaked-offscreen' (cloaked and on no
    # monitor), 'offscreen' (visible but on no monitor, the (-32000,-32000) placement),
    # 'onscreen', 'hidden' (not visible) or 'unknown' (the DWM query failed).
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    if (-not [WmuxTestHarness.Native]::IsWindowVisible($Hwnd)) { return 'hidden' }
    $cloaked = [WmuxTestHarness.Native]::Cloaked($Hwnd)
    if ($null -eq $cloaked) { return 'unknown' }
    if ($cloaked -ne 0) { if ([WmuxTestHarness.Native]::OnAnyMonitor($Hwnd)) { return 'cloaked' } else { return 'cloaked-offscreen' } }
    if (-not [WmuxTestHarness.Native]::OnAnyMonitor($Hwnd)) { return 'offscreen' }
    return 'onscreen'
}

function Get-WmuxTerminalCheck {
    # DWMWA_CLOAKED-aware "terminal rendered" check of a capture (spike S2 section 6.2): the
    # WmuxTerminal children must show at least 3 colours and no colour above 99.9 %. GL output
    # reaches PrintWindow only for a window on a monitor, so the check is 'inconclusive' unless
    # the window is cloaked; 'ok' or 'blank' otherwise, 'none' without a terminal child.
    param([Parameter(Mandatory)][IntPtr]$Hwnd, [Parameter(Mandatory)]$Capture, [Parameter(Mandatory)][string]$Placement)
    $terminals = @([WmuxTestHarness.Native]::ChildWindows($Hwnd, 'WmuxTerminal') | Where-Object { [WmuxTestHarness.Native]::IsWindowVisible($_) })
    $result = [ordered]@{ check = 'none'; stats = $null; reason = 'no visible WmuxTerminal child window' }
    if ($terminals.Count -eq 0) { return $result }
    $best = $null
    foreach ($t in $terminals) {
        $r = [WmuxTestHarness.Capture]::ScreenRect($t)
        $stats = $Capture.Stats($r.Left - $Capture.Left, $r.Top - $Capture.Top, $r.Right - $r.Left, $r.Bottom - $r.Top)
        if ($null -eq $best -or $stats.Pixels -gt $best.Pixels) { $best = $stats }
    }
    $result.stats = $best.ToString()
    if ($Placement -ne 'cloaked') {
        $result.check = 'inconclusive'
        $result.reason = "window is $Placement, not cloaked on a monitor: GL output is not capturable there (spike S2)"
    } elseif ($best.NotBlank) {
        $result.check = 'ok'
        $result.reason = $null
    } else {
        $result.check = 'blank'
        $result.reason = "terminal area looks blank: $($best.ToString())"
    }
    return $result
}

function Save-WmuxWindowCapture {
    # PrintWindow(PW_RENDERFULLCONTENT) of a top-level WmuxWindow on a per-monitor-v2 DPI aware
    # thread; works off-screen and cloaked, never changes focus. A window whose UI thread is hung
    # (IsHungAppWindow) is not captured at all, since PrintWindow would block on it; otherwise the
    # capture gives up after -TimeoutMs (default 10 s) and abandons its thread. Returns the
    # placement and the terminal check (Get-WmuxTerminalCheck).
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [Parameter(Mandatory)][string]$Path, $Window, [ValidateRange(100, 600000)][int]$TimeoutMs = 10000)
    $hwnds = @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, 'WmuxWindow'))
    if ($hwnds.Count -eq 0) { $hwnds = @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, [NullString]::Value) | Where-Object { [WmuxTestHarness.Native]::IsWindowVisible($_) }) }
    if ($hwnds.Count -eq 0) { throw (New-WmuxHarnessError -Code 'harness_transport' -Message "no top-level window found for pid $($Instance.Pid)" -Method 'screenshot') }
    $index = 0
    if ($null -ne $Window -and (Test-WmuxIsNumber $Window)) { $index = [int]$Window }
    if ($index -ge $hwnds.Count) { throw (New-WmuxHarnessError -Code 'harness_transport' -Message "window index $index out of range ($($hwnds.Count) windows)" -Method 'screenshot') }
    $hwnd = $hwnds[$index]
    if ([WmuxTestHarness.Native]::IsHungAppWindow($hwnd)) { throw (New-WmuxHarnessError -Code 'harness_timeout' -Message "window of pid $($Instance.Pid) is not responding (IsHungAppWindow): not captured" -Method 'screenshot') }
    $cap = [WmuxTestHarness.Capture]::WindowWithTimeout($hwnd, $TimeoutMs)
    if ($null -eq $cap) { throw (New-WmuxHarnessError -Code 'harness_timeout' -Message "PrintWindow did not return within $([Math]::Round($TimeoutMs / 1000.0, 1)) s (wmux UI thread of pid $($Instance.Pid) not responding)" -Method 'screenshot') }
    if ($cap.Width -le 0 -or $cap.Height -le 0) { throw (New-WmuxHarnessError -Code 'harness_transport' -Message "window has an empty rect $($cap.Width)x$($cap.Height)" -Method 'screenshot') }
    $cap.SavePng($Path)
    $placement = Get-WmuxWindowPlacement -Hwnd $hwnd
    $check = Get-WmuxTerminalCheck -Hwnd $hwnd -Capture $cap -Placement $placement
    return [pscustomobject]@{
        Placement      = $placement
        Cloaked        = [WmuxTestHarness.Native]::Cloaked($hwnd)
        TerminalCheck  = $check.check
        TerminalStats  = $check.stats
        TerminalReason = $check.reason
        Width          = $cap.Width
        Height         = $cap.Height
    }
}

function Save-WmuxFailureSnapshot {
    # Best effort, instance still alive: screenshot, dialogs, toasts into <root>\artifacts. Never
    # blocks on a hung UI thread (W0-ST): a window that IsHungAppWindow reports is not captured
    # and the reason goes to artifacts\failure-snapshot.txt; any other capture is bounded to 5 s
    # (the abandoned capture thread returns once Stop-WmuxInstance kills the tree).
    param([Parameter(Mandatory)][WmuxInstance]$Instance)
    $saved = $script:State.FailMark
    try {
        $notes = [Collections.Generic.List[string]]::new()
        $hung = @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, [NullString]::Value) | Where-Object { [WmuxTestHarness.Native]::IsHungAppWindow($_) })
        if ($hung.Count -gt 0) {
            $notes.Add("screenshot skipped: $($hung.Count) top-level window(s) of pid $($Instance.Pid) are not responding (IsHungAppWindow)")
        } elseif ($Instance.Protocol -eq 'v2') {
            # Straight RPC with a 5 s limit (Get-WmuxScreenshot would wait the default 15 s); the app
            # writes the PNG to the given path itself.
            try {
                $null = New-Item -ItemType Directory -Force -Path $Instance.ArtifactsDir
                $null = Invoke-WmuxRpc $Instance 'wmux.debug.window.screenshot' ([ordered]@{ path = (Join-Path $Instance.ArtifactsDir 'failure.png') }) -TimeoutSec 5
            } catch { $notes.Add("screenshot failed: $($_.Exception.Message)") }
        } else {
            try { $null = Save-WmuxWindowCapture -Instance $Instance -Path (Join-Path $Instance.ArtifactsDir 'failure.png') -TimeoutMs 5000 } catch { $notes.Add("screenshot failed: $($_.Exception.Message)") }
        }
        if ($notes.Count -gt 0) {
            try {
                $null = New-Item -ItemType Directory -Force -Path $Instance.ArtifactsDir
                [IO.File]::WriteAllLines((Join-Path $Instance.ArtifactsDir 'failure-snapshot.txt'), $notes, $script:Utf8NoBom)
            } catch { }
        }
        if ($hung.Count -eq 0 -and $Instance.Protocol -eq 'v2') {
            try {
                $d = Invoke-WmuxRpc $Instance 'wmux.debug.dialogs.list' -TimeoutSec 3
                [IO.File]::WriteAllText((Join-Path $Instance.ArtifactsDir 'dialogs.json'), (ConvertTo-Json -InputObject $d -Depth 50), $script:Utf8NoBom)
            } catch { }
        }
    } finally {
        $script:State.FailMark = $saved
    }
}

function Copy-WmuxArtifacts {
    # Copies the useful, small files of an instance root (never the WebView2 profile).
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [Parameter(Mandatory)][string]$Destination)
    $null = New-Item -ItemType Directory -Force -Path $Destination
    $root = $Instance.Root
    $patterns = @(
        'ghostty.conf', 'toasts.jsonl', 'config\wmux.json', 'logs\*', 'artifacts\*',
        'state\run\instance.json', 'state\events\events.jsonl', 'state\events\events.jsonl.1',
        'state\logs\*', 'state\session\*.json', 'localappdata\ghostty\session-state.json'
    )
    $budget = 64MB
    $copied = 0L
    foreach ($pattern in $patterns) {
        $items = @(Get-ChildItem -Path (Join-Path $root $pattern) -File -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if ($copied + $item.Length -gt $budget) { continue }
            $rel = [IO.Path]::GetRelativePath($root, $item.FullName)
            $target = Join-Path $Destination $rel
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
            try {
                $src = [IO.FileStream]::new($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
                try {
                    $dst = [IO.File]::Create($target)
                    try { $src.CopyTo($dst) } finally { $dst.Dispose() }
                } finally { $src.Dispose() }
                $copied += $item.Length
            } catch { }
        }
    }
    $summary = [ordered]@{
        pid = $Instance.Pid; channel = $Instance.Channel; protocol = $Instance.Protocol; exe = $Instance.Exe
        pipe = $Instance.Pipe; exit_code = $Instance.ExitCode; root = $Instance.Root; test = $Instance.TestName
        hidden_mode = $Instance.HiddenMode
        focus_violations = @([WmuxTestHarness.FocusSampler]::ForRoot($Instance.Pid) | ForEach-Object { "$($_.Kind): $($_.ToString())" })
        tree = @($Instance.Tree | ForEach-Object { [string]$_ })
        survivors = @($Instance.Survivors)
    }
    [IO.File]::WriteAllText((Join-Path $Destination 'instance.json'), (ConvertTo-Json -InputObject $summary -Depth 5), $script:Utf8NoBom)
}

# Background root deleter (spike S2: the WebView2 user-data folder stays locked for 25-60 s
# after the instance is gone). Runs detached from the test, retries until the root is gone or
# the deadline passes, and only ever deletes a directory directly under a 'wmux-e2e' folder.
$script:RootDeleterScript = @'
param([Parameter(Mandatory)][string]$Root, [int]$DeadlineSec = 90)
$ErrorActionPreference = 'SilentlyContinue'
if ((Split-Path -Leaf (Split-Path -Parent $Root)) -ne 'wmux-e2e') { exit 2 }
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $DeadlineSec) {
    if (-not (Test-Path -LiteralPath $Root)) { exit 0 }
    try { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop; exit 0 } catch { }
    [Threading.Thread]::Sleep(500)
}
exit 1
'@

function Get-WmuxRootDeleterPath {
    $dir = Join-Path (Join-Path (Get-WmuxTempBase) 'wmux-e2e') 'typecache'
    $hash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:RootDeleterScript)))).Substring(0, 12).ToLowerInvariant()
    $path = Join-Path $dir "Remove-WmuxRoot.$hash.ps1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
        $tmp = "$path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, $script:RootDeleterScript, $script:Utf8NoBom)
        try { [IO.File]::Move($tmp, $path) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

function Start-WmuxRootDeleter {
    # Deletes the root asynchronously in a hidden, detached pwsh (never blocks or fails a test).
    param([Parameter(Mandatory)][string]$Root, [int]$DeadlineSec = 90)
    $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Get-WmuxRootDeleterPath), '-Root', $Root, '-DeadlineSec', [string]$DeadlineSec)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.Dispose()
}

function Remove-WmuxInstanceRoot {
    # One synchronous attempt; when files are still locked (WebView2), a background deleter
    # retries for up to 90 s. Returns 'sync', 'async', 'none' (nothing to delete) or 'refused'.
    param([Parameter(Mandatory)][WmuxInstance]$Instance)
    $root = $Instance.Root
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return 'none' }
    # Guard: only ever delete a harness root.
    if ((Split-Path -Leaf (Split-Path -Parent $root)) -ne 'wmux-e2e') { return 'refused' }
    try {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        return 'sync'
    } catch { }
    if (-not (Test-Path -LiteralPath $root)) { return 'sync' }
    try {
        Start-WmuxRootDeleter -Root $root
        return 'async'
    } catch {
        Write-Warning "WmuxTest: could not start the background deleter for $root ($($_.Exception.Message)); the next run.ps1 sweep removes it"
        return 'refused'
    }
}

function Write-WmuxRootOwner {
    # <root>\owner.json lets run.ps1's stale-root sweep tell live roots (their harness process
    # still runs) from leftovers of killed runs.
    param([Parameter(Mandatory)][string]$Root)
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $owner = [ordered]@{
        harness_pid      = $me.Id
        harness_started  = $me.StartTime.ToUniversalTime().ToString('o')
        created_at       = [DateTime]::UtcNow.ToString('o')
        worktree         = $script:RepoRoot
    }
    [IO.File]::WriteAllText((Join-Path $Root 'owner.json'), (ConvertTo-Json -InputObject $owner), $script:Utf8NoBom)
}

function Complete-WmuxInstanceCleanup {
    # After the process is gone: collect artifacts for failed instances, then delete the root.
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [string]$ArtifactDir)
    if ($Instance.Cleaned) { return $null }
    $Instance.Cleaned = $true
    $dest = $null
    if ($Instance.Failed) {
        if (-not $ArtifactDir) { $ArtifactDir = Join-Path (Get-WmuxArtifactBase) "instance-$($Instance.Id)" }
        $dest = $ArtifactDir
        try { Copy-WmuxArtifacts -Instance $Instance -Destination $dest } catch { Write-Warning "WmuxTest: artifact copy failed: $($_.Exception.Message)" }
    }
    if ($Instance.KeepArtifacts) {
        Write-Host "WmuxTest: keeping instance root $($Instance.Root)" -ForegroundColor DarkYellow
        $Instance.RootDeletion = 'kept'
    } else {
        $Instance.RootDeletion = Remove-WmuxInstanceRoot -Instance $Instance
    }
    $null = $script:State.Instances.Remove($Instance)
    return $dest
}

function Stop-WmuxProcessTree {
    param([Parameter(Mandatory)][WmuxInstance]$Instance)
    $p = $Instance.Process
    if ($null -ne $p) {
        try {
            if (-not $p.HasExited) { $p.Kill($true) }
        } catch {
            # By PID only while our handle says the process is still alive (no recycled PID).
            try { if (-not $p.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $Instance.Pid /T /F *> $null } } catch { }
        }
    }
    if ($Instance.JobHandle -ne [IntPtr]::Zero) {
        [WmuxTestHarness.JobObject]::Close($Instance.JobHandle)
        $Instance.JobHandle = [IntPtr]::Zero
    }
    if ($null -ne $p) {
        try { $null = $p.WaitForExit(5000) } catch { }
    }
}

function Stop-WmuxOrphans {
    # After the root process is gone: terminate every recorded member of the tree that still
    # runs (msedgewebview2 outlives a graceful exit by 30-60 s and Kill(true) cannot reach it
    # once wmux has exited; spike S2), then wait up to -WaitSec until none of them is listed
    # any more (killed processes stay listed while they tear down). Never fails the test;
    # leftovers are recorded in $Instance.Survivors.
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [AllowNull()][object[]]$Members, [double]$WaitSec = 15)
    $list = [WmuxTestHarness.TreeMember[]]@($Members | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { $Instance.Survivors = @(); return }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $alive = [WmuxTestHarness.FocusSampler]::AliveMembers($list)
    if ($alive.Count -gt 0) { $null = [WmuxTestHarness.FocusSampler]::KillMembers($alive) }
    while ($alive.Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt $WaitSec) {
        Start-Sleep -Milliseconds 100
        $alive = [WmuxTestHarness.FocusSampler]::AliveMembers($alive)
    }
    $Instance.Survivors = @($alive | ForEach-Object { $_.ToString() })
    if ($alive.Count -gt 0) {
        Write-Host "       WmuxTest: processes of instance pid $($Instance.Pid) still listed $([int]$WaitSec) s after the stop: $($Instance.Survivors -join ', ')" -ForegroundColor DarkYellow
    }
}

function Get-WmuxScreenText {
    # Current screen text of a surface: v2 surface.read_text, or legacy read-screen.
    param([Parameter(Mandatory)][WmuxInstance]$Instance, [Parameter(Mandatory)]$Surface, [double]$TimeoutSec = 5)
    if ($Instance.Protocol -eq 'v2') {
        if ($Surface -is [System.Collections.IDictionary]) { $params = $Surface } else { $params = [ordered]@{ surface_id = [string]$Surface } }
        $r = Invoke-WmuxRpc $Instance 'surface.read_text' $params -TimeoutSec $TimeoutSec
        if ($r -is [string]) { return $r }
        return [string](Get-WmuxProp $r 'text')
    }
    $args2 = [ordered]@{}
    if ($Surface -is [System.Collections.IDictionary] -or $Surface -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in @('workspace', 'pane', 'tab', 'lines', 'scrollback')) {
            if (Test-WmuxHasProp $Surface $k) { $args2[$k] = Get-WmuxProp $Surface $k }
        }
    } elseif ((Test-WmuxIsNumber $Surface) -or ([string]$Surface -match '^\d+$')) {
        $target = [System.Numerics.BigInteger]::Parse([string]$Surface)
        $found = $null
        $workspaces = Invoke-WmuxLegacyCommand -Instance $Instance -Cmd 'workspace-list' -TimeoutSec $TimeoutSec
        foreach ($ws in @($workspaces)) {
            $wsIndex = Get-WmuxProp $ws 'index'
            $surfaces = Invoke-WmuxLegacyCommand -Instance $Instance -Cmd 'surface-list' -Arguments ([ordered]@{ workspace = $wsIndex }) -TimeoutSec $TimeoutSec
            foreach ($s in @($surfaces)) {
                if ([System.Numerics.BigInteger]::Parse([string](Get-WmuxProp $s 'id')) -eq $target) {
                    $found = [ordered]@{ workspace = $wsIndex; pane = (Get-WmuxProp $s 'pane'); tab = (Get-WmuxProp $s 'tab') }
                    break
                }
            }
            if ($found) { break }
        }
        if (-not $found) { throw [WmuxRpcError]::new('legacy_error', "UnknownSurface: legacy surface id $Surface not found") }
        $args2 = $found
    } else {
        throw [ArgumentException]::new("legacy instances address surfaces by @{workspace=;pane=;tab=} or by numeric surface id, got '$Surface'")
    }
    return [string](Invoke-WmuxLegacyCommand -Instance $Instance -Cmd 'read-screen' -Arguments $args2 -TimeoutSec $TimeoutSec)
}

# ---------------------------------------------------------------------------
# JSON shape comparison (Assert-JsonShape)
# ---------------------------------------------------------------------------

function Format-WmuxJsonPath {
    param([string]$Base, [string]$Key)
    if ($Key -match '^[A-Za-z_][A-Za-z0-9_]*$') { return "$Base.$Key" }
    return "$Base[" + (ConvertTo-Json -InputObject $Key -Compress) + ']'
}

function Test-WmuxShapeToken {
    # Returns $null when $Token is not a wildcard token, else $true/$false for the match.
    param([string]$Token, $Actual, [string]$Kind)
    if (-not ($Token.Length -ge 3 -and $Token.StartsWith('<') -and $Token.EndsWith('>'))) { return $null }
    $inner = $Token.Substring(1, $Token.Length - 2)
    switch -CaseSensitive -Regex ($inner) {
        '^any$' { return $true }
        '^string$' { return ($Kind -eq 'string') }
        '^nonempty$' { return ($Kind -eq 'string' -and $Actual.Length -gt 0) }
        '^number$' { return ($Kind -eq 'number') }
        '^int$' { return ($Kind -eq 'number' -and (Test-WmuxIsIntegral $Actual)) }
        '^bool$' { return ($Kind -eq 'bool') }
        '^null$' { return ($Kind -eq 'null') }
        '^object$' { return ($Kind -eq 'object') }
        '^array$' { return ($Kind -eq 'array') }
        '^uuid$' { return ($Kind -eq 'string' -and $Actual -match $script:UuidPattern) }
        '^ref$' { return ($Kind -eq 'string' -and $Actual -cmatch $script:RefPattern) }
        '^ref:([a-z][a-z_]*)$' { return ($Kind -eq 'string' -and $Actual -cmatch ('^' + $Matches[1] + ':\d+$')) }
        '^timestamp$' {
            if ($Kind -eq 'string') { return ($Actual -match $script:TimestampPattern) }
            return ($Kind -eq 'number' -and [double]$Actual -ge 1e9)
        }
        '^re:(.+)$' { return ($Kind -eq 'string' -and [regex]::IsMatch($Actual, $Matches[1])) }
    }
    return $null
}

function Compare-WmuxJsonShape {
    # Returns the list of mismatches between a normalized actual value and a shape.
    # Rules: objects need every shape key (key? = optional, "<strict>": true = no extra keys);
    # arrays match element-wise with the same length, or ["<each>", shape] for any length;
    # wildcard tokens <any> <string> <nonempty> <number> <int> <bool> <null> <object> <array>
    # <uuid> <ref> <ref:kind> <timestamp> <re:regex>; shape strings that look like a UUID,
    # a UUID-seq event id, an ISO-8601 timestamp or a kind:N ref match any value of that form.
    param([AllowNull()]$Actual, [AllowNull()]$Shape, [string]$Path = '$', [System.Collections.Generic.List[string]]$Mismatches)
    $top = $false
    if ($null -eq $Mismatches) {
        $Mismatches = [System.Collections.Generic.List[string]]::new()
        $top = $true
    }
    $sk = Get-WmuxValueKind $Shape
    $ak = Get-WmuxValueKind $Actual
    switch ($sk) {
        'string' {
            $tok = Test-WmuxShapeToken -Token $Shape -Actual $Actual -Kind $ak
            if ($null -ne $tok) {
                if (-not $tok) { $Mismatches.Add("${Path}: expected $Shape, got $(Format-WmuxValue $Actual 120)") }
                break
            }
            if ($Shape -match $script:UuidPattern) {
                if ($ak -ne 'string' -or $Actual -notmatch $script:UuidPattern) { $Mismatches.Add("${Path}: expected a UUID, got $(Format-WmuxValue $Actual 120)") }
                break
            }
            if ($Shape -match $script:UuidSeqPattern) {
                if ($ak -ne 'string' -or $Actual -notmatch $script:UuidSeqPattern) { $Mismatches.Add("${Path}: expected a <uuid>-<seq> id, got $(Format-WmuxValue $Actual 120)") }
                break
            }
            if ($Shape -match $script:TimestampPattern) {
                if ($ak -ne 'string' -or $Actual -notmatch $script:TimestampPattern) { $Mismatches.Add("${Path}: expected an ISO-8601 timestamp, got $(Format-WmuxValue $Actual 120)") }
                break
            }
            if ($Shape -cmatch $script:RefPattern) {
                $refKind = $Matches[1]
                if ($ak -ne 'string' -or $Actual -cnotmatch ('^' + $refKind + ':\d+$')) { $Mismatches.Add("${Path}: expected a ${refKind}:N ref, got $(Format-WmuxValue $Actual 120)") }
                break
            }
            if ($ak -ne 'string' -or -not [string]::Equals($Shape, $Actual, [StringComparison]::Ordinal)) {
                $Mismatches.Add("${Path}: expected $(Format-WmuxValue $Shape 120), got $(Format-WmuxValue $Actual 120)")
            }
        }
        'number' {
            if ($ak -ne 'number' -or -not (Test-WmuxNumberEqual $Shape $Actual)) { $Mismatches.Add("${Path}: expected $Shape, got $(Format-WmuxValue $Actual 120)") }
        }
        'bool' {
            if ($ak -ne 'bool' -or [bool]$Shape -ne [bool]$Actual) { $Mismatches.Add("${Path}: expected $(Format-WmuxValue $Shape), got $(Format-WmuxValue $Actual 120)") }
        }
        'null' {
            if ($ak -ne 'null') { $Mismatches.Add("${Path}: expected null, got $(Format-WmuxValue $Actual 120)") }
        }
        'array' {
            if ($Shape.Count -eq 2 -and $Shape[0] -is [string] -and [string]::Equals($Shape[0], '<each>', [StringComparison]::Ordinal)) {
                if ($ak -ne 'array') {
                    $Mismatches.Add("${Path}: expected an array, got $(Format-WmuxValue $Actual 120)")
                } else {
                    for ($i = 0; $i -lt $Actual.Count; $i++) {
                        Compare-WmuxJsonShape -Actual $Actual[$i] -Shape $Shape[1] -Path "$Path[$i]" -Mismatches $Mismatches
                    }
                }
                break
            }
            if ($ak -ne 'array') {
                $Mismatches.Add("${Path}: expected an array of $($Shape.Count), got $(Format-WmuxValue $Actual 120)")
                break
            }
            if ($Actual.Count -ne $Shape.Count) {
                $Mismatches.Add("${Path}: expected $($Shape.Count) elements, got $($Actual.Count)")
            }
            $n = [Math]::Min($Actual.Count, $Shape.Count)
            for ($i = 0; $i -lt $n; $i++) {
                Compare-WmuxJsonShape -Actual $Actual[$i] -Shape $Shape[$i] -Path "$Path[$i]" -Mismatches $Mismatches
            }
        }
        'object' {
            if ($ak -ne 'object') {
                $Mismatches.Add("${Path}: expected an object, got $(Format-WmuxValue $Actual 120)")
                break
            }
            $strict = $false
            $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($p in $Shape.PSObject.Properties) {
                $key = $p.Name
                if ([string]::Equals($key, '<strict>', [StringComparison]::Ordinal)) { $strict = [bool]$p.Value; continue }
                $optional = $key.Length -gt 1 -and $key.EndsWith('?')
                $name = if ($optional) { $key.Substring(0, $key.Length - 1) } else { $key }
                $null = $known.Add($name)
                $ap = $Actual.PSObject.Properties[$name]
                $childPath = Format-WmuxJsonPath $Path $name
                if ($null -eq $ap) {
                    if (-not $optional) { $Mismatches.Add("${childPath}: missing") }
                    continue
                }
                if (-not [string]::Equals($ap.Name, $name, [StringComparison]::Ordinal)) {
                    $Mismatches.Add("${childPath}: key case differs (got '$($ap.Name)')")
                    continue
                }
                Compare-WmuxJsonShape -Actual $ap.Value -Shape $p.Value -Path $childPath -Mismatches $Mismatches
            }
            if ($strict) {
                foreach ($ap in $Actual.PSObject.Properties) {
                    if (-not $known.Contains($ap.Name)) { $Mismatches.Add("$(Format-WmuxJsonPath $Path $ap.Name): unexpected key") }
                }
            }
        }
        default {
            $Mismatches.Add("${Path}: unsupported shape value of type $($Shape.GetType().FullName)")
        }
    }
    if ($top) { return , $Mismatches }
}

function Resolve-WmuxShapeInput {
    # Shape argument to a normalized value: JSON text, a .json file path, or a value.
    param([AllowNull()]$Shape, [string]$CallerDir)
    if ($Shape -is [string]) {
        $t = $Shape.Trim()
        if ($t.StartsWith('{') -or $t.StartsWith('[') -or $t.StartsWith('"')) {
            return , (ConvertFrom-WmuxJsonText $t)
        }
        if ($t -match '\.json$') {
            $here = (Get-Location).ProviderPath
            $candidates = @([IO.Path]::GetFullPath($t, $here))
            if ($CallerDir) { $candidates += [IO.Path]::GetFullPath($t, $CallerDir) }
            $candidates += [IO.Path]::GetFullPath($t, $script:ModuleRoot)
            $candidates += [IO.Path]::GetFullPath($t, (Join-Path $script:ModuleRoot 'fixtures'))
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c -PathType Leaf) { return , (ConvertFrom-WmuxJsonText ([IO.File]::ReadAllText($c))) }
            }
        }
        return $Shape
    }
    return , (ConvertTo-WmuxNormalizedJson $Shape)
}

# ---------------------------------------------------------------------------
# Test results
# ---------------------------------------------------------------------------

function Get-WmuxRelativeTestFile {
    param([string]$File)
    if ($env:WMUX_E2E_FILE) { return $env:WMUX_E2E_FILE }
    if (-not $File) { return $null }
    $rel = [IO.Path]::GetRelativePath($script:RepoRoot, $File)
    return ($rel -replace '\\', '/')
}

function Write-WmuxTestResult {
    param([System.Collections.IDictionary]$Result)
    if ($env:WMUX_E2E_RESULTS) {
        $line = ConvertTo-Json -InputObject $Result -Depth 10 -Compress
        $dir = Split-Path -Parent $env:WMUX_E2E_RESULTS
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
        [IO.File]::AppendAllText($env:WMUX_E2E_RESULTS, $line + "`n", $script:Utf8NoBom)
    }
    $color = switch ($Result.status) { 'passed' { 'Green' } 'skipped' { 'Yellow' } default { 'Red' } }
    $tag = switch ($Result.status) { 'passed' { 'PASS' } 'skipped' { 'SKIP' } default { 'FAIL' } }
    Write-Host ("[{0}] {1} ({2} ms)" -f $tag, $Result.name, $Result.duration_ms) -ForegroundColor $color
    if ($Result.message) { Write-Host ('       ' + (($Result.message -split "`n") -join "`n       ")) -ForegroundColor $color }
    if ($Result.artifacts) { Write-Host "       artifacts: $($Result.artifacts)" -ForegroundColor DarkGray }
}

# ===========================================================================
# Exported functions (Appendix D.3)
# ===========================================================================

function Start-WmuxInstance {
    <#
    .SYNOPSIS
        Launches an isolated, hidden wmux instance and waits until it is ready (Appendix D.2).
    .OUTPUTS
        [WmuxInstance]
    #>
    [CmdletBinding()]
    [OutputType([WmuxInstance])]
    param(
        [ValidateSet('Debug', 'Release')][string]$Build,
        [string]$Exe,
        [System.Collections.IDictionary]$Settings,
        [string[]]$Ghostty,
        [string]$Shell,
        [switch]$Restore,
        [switch]$Visible,
        [switch]$KeepArtifacts,
        [ValidateRange(1, 600)][double]$TimeoutSec = 30
    )
    $exePath = Resolve-WmuxExe -Build $Build -Exe $Exe
    if (-not $Visible -and -not (Test-WmuxHiddenSupport $exePath)) {
        throw [WmuxSkipException]::new("wmux.exe at '$exePath' has no WMUX_TEST_HIDDEN support yet (pending W0-A1); refusing to open a visible window. Use -Visible for local debugging.")
    }

    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Join-Path (Join-Path (Get-WmuxTempBase) 'wmux-e2e') $id
    $dirs = [ordered]@{
        state = Join-Path $root 'state'; config = Join-Path $root 'config'; xdg = Join-Path $root 'xdg'
        artifacts = Join-Path $root 'artifacts'; logs = Join-Path $root 'logs'; work = Join-Path $root 'work'
        localappdata = Join-Path $root 'localappdata'
    }
    foreach ($d in $dirs.Values) { $null = New-Item -ItemType Directory -Force -Path $d }
    Write-WmuxRootOwner -Root $root

    $settingsDoc = ConvertTo-WmuxSettingsDocument -Settings $Settings
    [IO.File]::WriteAllText((Join-Path $dirs.config 'wmux.json'), (ConvertTo-Json -InputObject $settingsDoc -Depth 64), $script:Utf8NoBom)
    $confPath = Join-Path $root 'ghostty.conf'
    [IO.File]::WriteAllText($confPath, (New-WmuxGhosttyConfText -Shell $Shell -Ghostty $Ghostty -Id $id), $script:Utf8NoBom)

    $keepLad = $env:WMUX_E2E_KEEP_LOCALAPPDATA -eq '1'
    if (-not $keepLad) { Initialize-WmuxLocalAppData -LocalAppData $dirs.localappdata }
    $childEnv = New-WmuxChildEnvironment -BaseEnvironment (Get-WmuxProcessEnvironment) -Root $root -Id $id `
        -Visible:$Visible -Restore:$Restore -KeepLocalAppData:$keepLad

    $psi = [System.Diagnostics.ProcessStartInfo]::new($exePath)
    $psi.ArgumentList.Add('--config-default-files=false')
    $psi.ArgumentList.Add("--config-file=$confPath")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $dirs.work
    $psi.Environment.Clear()
    foreach ($k in $childEnv.Keys) { $psi.Environment[$k] = $childEnv[$k] }

    $inst = [WmuxInstance]::new()
    $inst.Id = $id
    $inst.Channel = "test-$id"
    $inst.Root = $root
    $inst.StateDir = $dirs.state
    $inst.ConfigDir = $dirs.config
    $inst.XdgDir = $dirs.xdg
    $inst.ArtifactsDir = $dirs.artifacts
    $inst.LogDir = $dirs.logs
    $inst.WorkDir = $dirs.work
    $inst.LocalAppData = if ($keepLad) { [NullString]::Value } else { $dirs.localappdata }
    $inst.ToastSink = Join-Path $root 'toasts.jsonl'
    $inst.Exe = $exePath
    $inst.CliExe = Join-Path (Split-Path -Parent $exePath) 'cli\cmux.exe'
    $inst.Visible = [bool]$Visible
    $inst.KeepArtifacts = [bool]$KeepArtifacts
    $inst.StartedAt = [DateTime]::UtcNow
    $inst.JobHandle = [IntPtr]::Zero
    if ($script:State.CurrentTest) { $inst.TestName = $script:State.CurrentTest.Name }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $null = Remove-WmuxInstanceRoot -Instance $inst
        throw
    }
    $inst.Process = $proc
    $inst.Pid = $proc.Id
    $job = [WmuxTestHarness.JobObject]::Create()
    if ($job -ne [IntPtr]::Zero) {
        if ([WmuxTestHarness.JobObject]::Assign($job, $proc.Handle)) { $inst.JobHandle = $job } else { [WmuxTestHarness.JobObject]::Close($job) }
    }
    try { $proc.StandardInput.Close() } catch { }
    $null = [WmuxTestHarness.ProcessLog]::Pump($proc.StandardOutput.BaseStream, (Join-Path $dirs.logs 'wmux.stdout.log'))
    $null = [WmuxTestHarness.ProcessLog]::Pump($proc.StandardError.BaseStream, (Join-Path $dirs.logs 'wmux.stderr.log'))

    $script:State.Instances.Add($inst)
    if ($script:State.CurrentTest) {
        $script:State.CurrentTest.Instances.Add($inst)
        [WmuxTestHarness.Watchdog]::Add($proc)
    }
    # Whole process tree (wmux, conhost, shells, msedgewebview2): focus sampler, visibility guard
    # and kill on a violation (spike S2). -Visible instances are only focus-sampled.
    [WmuxTestHarness.FocusSampler]::WatchTree($inst.Pid, -not $Visible, -not $Visible)

    try {
        Wait-WmuxInstanceReady -Instance $inst -TimeoutSec $TimeoutSec
    } catch {
        $inst.Failed = $true
        Set-WmuxFailMark
        try { Stop-WmuxInstance $inst -TimeoutSec 2 } catch { }
        throw
    }
    return $inst
}

function Stop-WmuxInstance {
    <#
    .SYNOPSIS
        wmux.debug.app.quit, wait, then kill the tree; collect artifacts on failure; delete the root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][WmuxInstance]$Instance,
        [ValidateRange(0, 600)][double]$TimeoutSec = 5
    )
    if ($null -eq $Instance) { return }
    if ($Instance.Stopped) {
        if (-not $script:State.CurrentTest -and -not $Instance.Cleaned) { $null = Complete-WmuxInstanceCleanup -Instance $Instance }
        return
    }
    $p = $Instance.Process
    $alive = $false
    try { $alive = ($null -ne $p) -and -not $p.HasExited } catch { }

    if ($alive -and ($script:State.FailMark -or $Instance.Failed)) {
        $Instance.Failed = $true
        Save-WmuxFailureSnapshot -Instance $Instance
    }
    foreach ($s in @($Instance.Streams)) { try { $s.Close() } catch { } }

    # The tree goes away on purpose from here: no visibility guard or kill while windows are
    # destroyed; the members recorded so far are the orphan candidates.
    [WmuxTestHarness.FocusSampler]::BeginTeardown($Instance.Pid)
    try { [WmuxTestHarness.FocusSampler]::RefreshTrees() } catch { }
    $members = [WmuxTestHarness.FocusSampler]::TreeOf($Instance.Pid)

    if ($alive -and $Instance.Protocol -eq 'v2') {
        $saved = $script:State.FailMark
        try { $null = Invoke-WmuxRpc $Instance 'wmux.debug.app.quit' -TimeoutSec ([Math]::Max(1, [Math]::Min(5, $TimeoutSec))) } catch { } finally { $script:State.FailMark = $saved }
        try { $null = $p.WaitForExit([int]($TimeoutSec * 1000)) } catch { }
    }
    # Legacy instances are killed directly: a graceful WM_CLOSE would make the legacy app save
    # its session file, which must never happen from a test.
    Stop-WmuxProcessTree -Instance $Instance
    try { if ($p.HasExited) { $Instance.ExitCode = $p.ExitCode } } catch { }
    [WmuxTestHarness.Watchdog]::Remove($Instance.Pid)
    Stop-WmuxOrphans -Instance $Instance -Members $members

    if ([WmuxTestHarness.FocusSampler]::ForRoot($Instance.Pid).Count -gt 0) { $Instance.Failed = $true }
    $Instance.HiddenMode = [WmuxTestHarness.FocusSampler]::PlacementOf($Instance.Pid)
    $Instance.Tree = @($members | ForEach-Object { $_ })
    [WmuxTestHarness.FocusSampler]::Unwatch($Instance.Pid)
    $Instance.Stopped = $true

    if (-not $script:State.CurrentTest -or -not $script:State.CurrentTest.Instances.Contains($Instance)) {
        $null = Complete-WmuxInstanceCleanup -Instance $Instance
    }
}

function Invoke-WmuxRpc {
    <#
    .SYNOPSIS
        Sends one cmux v2 request ({"id","method","params"}) and returns result, or the whole
        envelope with -Raw. Throws [WmuxRpcError] (.Code, .Message, .Data) for error replies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Mandatory, Position = 1)][string]$Method,
        [Parameter(Position = 2)][AllowNull()][object]$Params,
        [ValidateRange(0.1, 3600)][double]$TimeoutSec = 15,
        [switch]$Raw
    )
    try {
        Assert-WmuxInstanceUsable $Instance $Method
        Assert-WmuxV2 $Instance "Invoke-WmuxRpc '$Method'"
        $id = [guid]::NewGuid().ToString()
        $line = New-WmuxRpcRequestLine -Method $Method -Params $Params -Id $id
        $reply = Invoke-WmuxPipeLine -Instance $Instance -Line $line -TimeoutSec $TimeoutSec -Method $Method
        $value = ConvertFrom-WmuxRpcReply -Line $reply -RequestId $id -Method $Method -Raw:$Raw
    } catch {
        Set-WmuxFailMark
        throw
    }
    # The comma keeps a JSON array result intact without wrapping scalars.
    return , $value
}

function Invoke-WmuxRawLine {
    <#
    .SYNOPSIS
        Sends one raw line (legacy wmux JSON, cmux text-v1 or v2 JSON) and returns the reply line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Mandatory, Position = 1)][string]$Line,
        [ValidateRange(0.1, 3600)][double]$TimeoutSec = 15
    )
    try {
        Assert-WmuxInstanceUsable $Instance 'Invoke-WmuxRawLine'
        if ($Line -match '[\r\n]') { throw [ArgumentException]::new('Invoke-WmuxRawLine sends exactly one line; remove embedded newlines') }
        return (Invoke-WmuxPipeLine -Instance $Instance -Line $Line -TimeoutSec $TimeoutSec -Method 'raw line')
    } catch {
        Set-WmuxFailMark
        throw
    }
}

function Invoke-WmuxCli {
    <#
    .SYNOPSIS
        Runs <install>\cli\cmux.exe (or wmux.com with -AsWmux) against the instance with
        WMUX_SOCKET_PATH set. Returns [pscustomobject]@{ ExitCode; Stdout; Stderr }.
    .NOTES
        Transitional: a legacy instance (before the W1-1a v2 server) accepts only the legacy
        +verbs (for example @('+workspace','list')), which always run through wmux.exe with
        GHOSTTY_PID pointing at the test instance, even when a cli\cmux.exe exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Arguments = @(),
        [AllowNull()][string]$Stdin,
        [System.Collections.IDictionary]$Env,
        [switch]$AsWmux
    )
    try {
        $exe = if ($AsWmux) { Join-Path (Split-Path -Parent $Instance.CliExe) 'wmux.com' } else { $Instance.CliExe }
        $first = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
        if ($Instance.Protocol -eq 'legacy' -and ($script:LegacyCliVerbs -ccontains $first)) {
            # A legacy instance only serves the legacy pipe, which only the +verbs of wmux.exe
            # speak; the W0-K skeleton cli\cmux.exe and wmux.com (only --version) cannot reach it.
            $exe = $Instance.Exe
        } elseif (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw (New-WmuxHarnessError -Code 'harness_cli_missing' -Message "CLI not found at '$exe' (cli\cmux.exe ships with W1-2); a legacy instance only relays these +verbs through wmux.exe: $($script:LegacyCliVerbs -join ' ')" -Method 'cli')
        }
        $timeoutSec = 60
        if ($env:WMUX_E2E_CLI_TIMEOUT_SEC) { $timeoutSec = [double]$env:WMUX_E2E_CLI_TIMEOUT_SEC }

        $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
        foreach ($a in $Arguments) { $psi.ArgumentList.Add([string]$a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:Utf8NoBom
        $psi.StandardErrorEncoding = $script:Utf8NoBom
        $psi.StandardInputEncoding = $script:Utf8NoBom
        $psi.WorkingDirectory = $(if ($Instance.WorkDir -and (Test-Path -LiteralPath $Instance.WorkDir)) { $Instance.WorkDir } else { (Get-Location).ProviderPath })
        $cliEnv = Get-WmuxCliEnvironment -Instance $Instance -Env $Env
        $psi.Environment.Clear()
        foreach ($k in $cliEnv.Keys) { $psi.Environment[$k] = $cliEnv[$k] }

        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            try {
                if ($null -ne $Stdin) { $proc.StandardInput.Write($Stdin) }
            } catch { }
            try { $proc.StandardInput.Close() } catch { }
            if (-not $proc.WaitForExit([int]($timeoutSec * 1000))) {
                try { $proc.Kill($true) } catch { }
                throw (New-WmuxHarnessError -Code 'harness_cli_timeout' -Message "CLI '$exe $($Arguments -join ' ')' did not exit within ${timeoutSec}s" -Method 'cli')
            }
            $proc.WaitForExit()
            $null = $outTask.Wait(5000)
            $null = $errTask.Wait(5000)
            return [pscustomobject]@{
                ExitCode = $proc.ExitCode
                Stdout   = $(if ($outTask.IsCompleted) { $outTask.Result } else { '' })
                Stderr   = $(if ($errTask.IsCompleted) { $errTask.Result } else { '' })
            }
        } finally {
            $proc.Dispose()
        }
    } catch {
        Set-WmuxFailMark
        throw
    }
}

function Open-WmuxEventStream {
    <#
    .SYNOPSIS
        Opens a dedicated events.stream connection read by a background thread; returns once
        the ack frame arrived, so no later event can be missed.
    .OUTPUTS
        [WmuxEventStream]
    #>
    [CmdletBinding()]
    [OutputType([WmuxEventStream])]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [string[]]$Category,
        [string[]]$Name,
        [long]$AfterSeq
    )
    try {
        Assert-WmuxInstanceUsable $Instance 'Open-WmuxEventStream'
        Assert-WmuxV2 $Instance 'Open-WmuxEventStream'
        $params = [ordered]@{}
        if ($PSBoundParameters.ContainsKey('AfterSeq')) { $params.after_seq = $AfterSeq }
        if ($Name) { $params.names = @($Name) }
        if ($Category) { $params.categories = @($Category) }
        $id = [guid]::NewGuid().ToString()
        $line = New-WmuxRpcRequestLine -Method 'events.stream' -Params $params -Id $id
        $script:State.StreamCounter++
        $n = $script:State.StreamCounter
        $log = Join-Path $Instance.ArtifactsDir ('events-stream-{0:D3}.jsonl' -f $n)
        try {
            $stream = [WmuxEventStream]::Open($Instance.Pipe, $line, $log, 10000)
        } catch {
            $ex = Get-WmuxInnerException $_.Exception
            $code = if ($ex -is [TimeoutException]) { 'harness_timeout' } elseif ($ex -is [IO.EndOfStreamException]) { 'harness_eof' } else { 'harness_transport' }
            throw (New-WmuxHarnessError -Code $code -Message "events.stream over $($Instance.Pipe): $($ex.Message)" -Method 'events.stream' -Inner $ex)
        }
        $first = $null
        if (-not [WmuxTestHarness.Json]::TryParse($stream.FirstLine, [ref]$first) -or (Get-WmuxValueKind $first) -ne 'object') {
            $stream.Close()
            throw [WmuxRpcError]::new('harness_bad_reply', "events.stream: first frame is not a JSON object: $(Format-WmuxValue $stream.FirstLine)", $null, 'events.stream', $id, $stream.FirstLine, $null, $null)
        }
        if ((Get-WmuxProp $first 'type') -eq 'ack') {
            $stream.Ack = $first
        } elseif ((Get-WmuxProp $first 'ok') -is [bool]) {
            if (-not $first.ok) {
                $stream.Close()
                $null = ConvertFrom-WmuxRpcReply -Line $stream.FirstLine -RequestId $id -Method 'events.stream'
            }
            $stream.Ack = $first
        } else {
            $stream.Close()
            throw [WmuxRpcError]::new('harness_bad_reply', "events.stream: expected an ack frame first, got $(Format-WmuxValue $stream.FirstLine)", $null, 'events.stream', $id, $stream.FirstLine, $null, $null)
        }
        $stream.Pid = $Instance.Pid
        $stream.Channel = $Instance.Channel
        $stream.Index = $n
        $stream.Instance = $Instance
        $Instance.Streams.Add($stream)
        if ($script:State.CurrentTest) { $script:State.CurrentTest.Streams.Add($stream) }
        return $stream
    } catch {
        Set-WmuxFailMark
        throw
    }
}

function Read-WmuxEvents {
    <#
    .SYNOPSIS
        Returns the event frames received since the previous call (heartbeats are only logged).
        Waits up to -TimeoutSec when nothing is queued; returns nothing on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxEventStream]$Stream,
        [ValidateRange(0, 3600)][double]$TimeoutSec = 5
    )
    $lines = $Stream.Drain([int]($TimeoutSec * 1000))
    if ($lines.Count -eq 0 -and $Stream.EndOfStream -and -not $Stream.ClosedByClient) {
        Set-WmuxFailMark
        throw (New-WmuxHarnessError -Code 'harness_stream_closed' -Message "events.stream closed by the server$(if ($Stream.Error) { ': ' + $Stream.Error })" -Method 'events.stream')
    }
    foreach ($l in $lines) {
        $frame = $null
        if (-not [WmuxTestHarness.Json]::TryParse($l, [ref]$frame)) { continue }
        if ((Get-WmuxProp $frame 'type') -eq 'event') { $frame }
    }
}

function Close-WmuxEventStream {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][WmuxEventStream]$Stream)
    if ($null -ne $Stream) { $Stream.Close() }
}

function Wait-WmuxEvent {
    <#
    .SYNOPSIS
        Waits for an event frame by name or category (optionally filtered by -Where, $_ = frame).
        Replays the retained events of the instance first (after_seq 0), so an event emitted
        before the call is found; use -Where to pick the right one.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Mandatory, ParameterSetName = 'ByName')][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'ByCategory')][string]$Category,
        [scriptblock]$Where,
        [ValidateRange(0.1, 3600)][double]$TimeoutSec = 10
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $open = @{ Instance = $Instance; AfterSeq = 0 }
    if ($PSCmdlet.ParameterSetName -eq 'ByName') { $open.Name = @($Name) } else { $open.Category = @($Category) }
    $stream = Open-WmuxEventStream @open
    $seen = [System.Collections.Generic.List[string]]::new()
    try {
        while ($true) {
            $remaining = [int]($TimeoutSec * 1000 - $sw.ElapsedMilliseconds)
            if ($remaining -le 0) { break }
            $lines = $stream.Drain([Math]::Min($remaining, 500))
            # Stop only once the stream has ended AND everything queued before the end was seen.
            if ($lines.Count -eq 0 -and $stream.EndOfStream) { break }
            foreach ($l in $lines) {
                $frame = $null
                if (-not [WmuxTestHarness.Json]::TryParse($l, [ref]$frame)) { continue }
                if ((Get-WmuxProp $frame 'type') -ne 'event') { continue }
                $fname = [string](Get-WmuxProp $frame 'name')
                if ($Name -and -not [string]::Equals($fname, $Name, [StringComparison]::Ordinal)) { $seen.Add($fname); continue }
                if ($Category -and -not [string]::Equals([string](Get-WmuxProp $frame 'category'), $Category, [StringComparison]::Ordinal)) { $seen.Add($fname); continue }
                if ($Where) {
                    $matched = @($frame | Where-Object -FilterScript $Where)
                    if ($matched.Count -eq 0) { $seen.Add("$fname(seq $(Get-WmuxProp $frame 'seq'))"); continue }
                }
                return $frame
            }
        }
    } finally {
        $stream.Close()
    }
    $what = if ($Name) { "name=$Name" } else { "category=$Category" }
    if ($Where) { $what += " where {$($Where.ToString().Trim())}" }
    $sample = if ($seen.Count) { ' Non-matching events: ' + (($seen | Select-Object -First 20) -join ', ') } else { ' No candidate events were received.' }
    $closed = if ($stream.EndOfStream -and $stream.Error) { " Stream error: $($stream.Error)." } else { '' }
    $reason = if ($stream.EndOfStream) { 'the events stream ended before a matching event arrived' } else { "timed out after ${TimeoutSec}s" }
    Throw-WmuxAssertion "Wait-WmuxEvent: $reason ($what).$sample$closed"
}

function Wait-WmuxCondition {
    <#
    .SYNOPSIS
        Polls the scriptblock until it returns a truthy value (returned) or throws on timeout.
        Exceptions inside the condition count as "not yet" and are reported on timeout.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0.01, 3600)][double]$TimeoutSec = 10,
        [ValidateRange(1, 60000)][int]$IntervalMs = 100,
        [Parameter(Mandatory, Position = 0)][scriptblock]$Condition
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastValue = $null
    $lastError = $null
    $attempts = 0
    $saved = $script:State.FailMark
    while ($true) {
        $attempts++
        try {
            $value = & $Condition
            $lastError = $null
            if ([System.Management.Automation.LanguagePrimitives]::IsTrue($value)) {
                $script:State.FailMark = $saved
                return , $value
            }
            $lastValue = $value
        } catch {
            if (Find-WmuxException $_.Exception ([WmuxSkipException])) { throw }
            $lastError = $_
        }
        $script:State.FailMark = $saved
        $remaining = $TimeoutSec * 1000 - $sw.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Min($IntervalMs, $remaining)))
    }
    $detail = "last value: $(Format-WmuxValue $lastValue 200)"
    if ($lastError) { $detail += "; last error: $((Get-WmuxInnerException $lastError.Exception).Message)" }
    Throw-WmuxAssertion "Wait-WmuxCondition timed out after ${TimeoutSec}s ($attempts attempts; $detail)"
}

function Wait-WmuxScreen {
    <#
    .SYNOPSIS
        Polls the surface text (surface.read_text, or legacy read-screen) until -Pattern matches;
        returns the matching screen text.
    .PARAMETER Surface
        v2: a surface UUID or ref (or a params hashtable for surface.read_text).
        legacy: @{ workspace = <i>; pane = <i>; tab = <i> } or a numeric legacy surface id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Mandatory)][object]$Surface,
        [Parameter(Mandatory)][string]$Pattern,
        [ValidateRange(0.1, 3600)][double]$TimeoutSec = 10
    )
    $regex = [regex]::new($Pattern)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastText = $null
    $lastError = $null
    $saved = $script:State.FailMark
    while ($true) {
        $delay = 150
        try {
            $text = Get-WmuxScreenText -Instance $Instance -Surface $Surface -TimeoutSec ([Math]::Max(1, [Math]::Min(5, $TimeoutSec)))
            $lastError = $null
            $lastText = $text
            if ($regex.IsMatch($text)) {
                $script:State.FailMark = $saved
                return $text
            }
        } catch {
            $lastError = Get-WmuxInnerException $_.Exception
            $rpc = Find-WmuxException $_.Exception ([WmuxRpcError])
            if ($rpc -and $rpc.Code -eq 'rate_limited') {
                $retry = Get-WmuxProp $rpc.Data 'retry_after_ms'
                if ($retry) { $delay = [int]$retry }
            }
            if ($rpc -and $rpc.Code -eq 'harness_instance_stopped') { $script:State.FailMark = $saved; throw }
        }
        $script:State.FailMark = $saved
        $remaining = $TimeoutSec * 1000 - $sw.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Min($delay, $remaining)))
    }
    $tail = if ($null -ne $lastText) { (($lastText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) -join "`n  ") } else { '(no screen text read)' }
    $err = if ($lastError) { "; last error: $($lastError.Message)" } else { '' }
    Throw-WmuxAssertion "Wait-WmuxScreen timed out after ${TimeoutSec}s waiting for /$Pattern/ on surface $(Format-WmuxValue $Surface 120)$err. Last screen lines:`n  $tail"
}

function Get-WmuxScreenshot {
    <#
    .SYNOPSIS
        Saves a PNG of an instance window via wmux.debug.window.screenshot (v2). Legacy
        instances fall back to a harness-side PrintWindow capture of the WmuxWindow (DPI aware,
        10 s limit for a hung UI thread).
    .OUTPUTS
        [System.IO.FileInfo] with note properties (DWMWA_CLOAKED-aware, spike S2):
        Placement      cloaked | cloaked-offscreen | offscreen | onscreen | hidden | unknown
        Cloaked        DWMWA_CLOAKED value, $null when the query failed
        TerminalCheck  ok | blank | inconclusive | none: the WmuxTerminal area shows 3+ colours
                       and no colour above 99.9 %; GL output reaches PrintWindow only on a
                       monitor, so anything but a cloaked window is 'inconclusive'
        TerminalStats, TerminalReason  details for the message of an assertion or skip
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance,
        [Parameter(Mandatory)][string]$Path,
        [object]$Window
    )
    try {
        Assert-WmuxInstanceUsable $Instance 'Get-WmuxScreenshot'
        $full = [IO.Path]::GetFullPath($Path, (Get-Location).ProviderPath)
        $dir = Split-Path -Parent $full
        if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
        # A v2 app can predate the wmux.debug.window.screenshot hook (the v2 server lands in
        # W1-1a, the hook later): method_not_found falls back to the harness capture.
        $appShot = $Instance.Protocol -eq 'v2'
        $r = $null
        if ($appShot) {
            $params = [ordered]@{ path = $full }
            if ($PSBoundParameters.ContainsKey('Window')) { $params.window_id = $Window }
            $saved = $script:State.FailMark
            try {
                $r = Invoke-WmuxRpc $Instance 'wmux.debug.window.screenshot' $params
            } catch [WmuxRpcError] {
                if ($_.Exception.Code -ne 'method_not_found') { throw }
                $script:State.FailMark = $saved
                $appShot = $false
            }
        }
        if ($appShot) {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $b64 = @((Get-WmuxProp $r 'png_base64'), (Get-WmuxProp $r 'base64'), (Get-WmuxProp $r 'data')) | Where-Object { $_ -is [string] -and $_ } | Select-Object -First 1
                $rpath = Get-WmuxProp $r 'path'
                if ($b64) {
                    [IO.File]::WriteAllBytes($full, [Convert]::FromBase64String($b64))
                } elseif ($rpath -and (Test-Path -LiteralPath $rpath -PathType Leaf)) {
                    Copy-Item -LiteralPath $rpath -Destination $full -Force
                } else {
                    throw (New-WmuxHarnessError -Code 'harness_bad_reply' -Message "wmux.debug.window.screenshot produced no image: $(Format-WmuxValue $r)" -Method 'wmux.debug.window.screenshot')
                }
            }
            $info = [pscustomobject]@{ Placement = 'unknown'; Cloaked = $null; TerminalCheck = 'none'; TerminalStats = $null; TerminalReason = 'captured by the app (wmux.debug.window.screenshot)' }
            $main = @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, 'WmuxWindow'))
            if ($main.Count -gt 0) { $info.Placement = Get-WmuxWindowPlacement -Hwnd $main[0]; $info.Cloaked = [WmuxTestHarness.Native]::Cloaked($main[0]) }
        } else {
            $info = Save-WmuxWindowCapture -Instance $Instance -Path $full -Window $Window
        }
        # DWMWA_CLOAKED-aware result (spike S2): Placement cloaked|offscreen|onscreen|hidden|unknown;
        # TerminalCheck ok|blank|inconclusive|none (inconclusive whenever the window is not cloaked).
        $item = Get-Item -LiteralPath $full
        foreach ($p in 'Placement', 'Cloaked', 'TerminalCheck', 'TerminalStats', 'TerminalReason') {
            $item | Add-Member -NotePropertyName $p -NotePropertyValue $info.$p -Force
        }
        return $item
    } catch {
        Set-WmuxFailMark
        throw
    }
}

function Get-WmuxToasts {
    <#
    .SYNOPSIS
        Parsed toast sink (WMUX_TEST_TOAST_SINK, JSONL), one object per delivered toast.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance)
    $path = $Instance.ToastSink
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $fs = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $text = [IO.StreamReader]::new($fs, $script:Utf8NoBom).ReadToEnd()
    } finally { $fs.Dispose() }
    $lines = $text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].TrimEnd("`r")
        if (-not $l.Trim()) { continue }
        $value = $null
        if ([WmuxTestHarness.Json]::TryParse($l, [ref]$value)) {
            $value
        } elseif ($i -lt $lines.Count - 1) {
            # A torn last line is still being written; anything else is reported.
            [pscustomobject]@{ _invalid = $true; raw = $l }
        }
    }
}

function Get-WmuxDialogs {
    <#
    .SYNOPSIS
        Dialogs recorded by the test-mode MessageBox auto-answer (wmux.debug.dialogs.list).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][WmuxInstance]$Instance)
    $r = Invoke-WmuxRpc $Instance 'wmux.debug.dialogs.list'
    $list = Get-WmuxProp $r 'dialogs'
    if ($null -ne $list) { return $list }
    return $r
}

function Assert-Equal {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Expected,
        [Parameter(Position = 1)][AllowNull()][object]$Actual,
        [Parameter(Position = 2)][string]$Message
    )
    if (-not (Test-WmuxValueEqual $Expected $Actual)) {
        $text = "Assert-Equal: expected $(Format-WmuxValue $Expected), got $(Format-WmuxValue $Actual)"
        if ($Expected -is [string] -and $Actual -is [string]) {
            $n = [Math]::Min($Expected.Length, $Actual.Length)
            $i = 0
            while ($i -lt $n -and $Expected[$i] -ceq $Actual[$i]) { $i++ }
            $text += " (first difference at index $i)"
        }
        Throw-WmuxAssertion $text $Message
    }
}

function Assert-NotEqual {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Expected,
        [Parameter(Position = 1)][AllowNull()][object]$Actual,
        [Parameter(Position = 2)][string]$Message
    )
    if (Test-WmuxValueEqual $Expected $Actual) {
        Throw-WmuxAssertion "Assert-NotEqual: both values are $(Format-WmuxValue $Actual)" $Message
    }
}

function Assert-Match {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Pattern,
        [Parameter(Position = 1)][AllowNull()][object]$Actual,
        [Parameter(Position = 2)][string]$Message
    )
    if ($null -eq $Actual -or -not [regex]::IsMatch([string]$Actual, $Pattern)) {
        Throw-WmuxAssertion "Assert-Match: /$Pattern/ does not match $(Format-WmuxValue $Actual)" $Message
    }
}

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Condition,
        [Parameter(Position = 1)][string]$Message
    )
    if (-not [System.Management.Automation.LanguagePrimitives]::IsTrue($Condition)) {
        Throw-WmuxAssertion "Assert-True: condition is $(Format-WmuxValue $Condition)" $Message
    }
}

function Assert-Throws {
    <#
    .SYNOPSIS
        Runs the scriptblock and requires a [WmuxRpcError] with the given -Code (any exception
        when -Code is omitted). Returns the caught exception.
    #>
    [CmdletBinding()]
    param(
        [string]$Code,
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [string]$Message
    )
    $saved = $script:State.FailMark
    $caught = $null
    try {
        $null = & $ScriptBlock
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        Throw-WmuxAssertion "Assert-Throws: expected $(if ($Code) { "a WmuxRpcError with code '$Code'" } else { 'an exception' }) but nothing was thrown" $Message
    }
    if (Find-WmuxException $caught.Exception ([WmuxSkipException])) { throw $caught }
    if (-not $Code) {
        $script:State.FailMark = $saved
        return (Get-WmuxInnerException $caught.Exception)
    }
    $rpc = Find-WmuxException $caught.Exception ([WmuxRpcError])
    if ($null -eq $rpc) {
        $inner = Get-WmuxInnerException $caught.Exception
        Throw-WmuxAssertion "Assert-Throws: expected a WmuxRpcError with code '$Code', got $($inner.GetType().Name): $($inner.Message)" $Message
    }
    if (-not [string]::Equals($rpc.Code, $Code, [StringComparison]::Ordinal)) {
        Throw-WmuxAssertion "Assert-Throws: expected code '$Code', got '$($rpc.Code)': $($rpc.Message)" $Message
    }
    $script:State.FailMark = $saved
    return $rpc
}

function Assert-JsonShape {
    <#
    .SYNOPSIS
        Compares a value with a golden JSON shape (JSON text, a .json file under the test's
        directory or test/e2e/fixtures, or a hashtable). Extra keys are allowed unless the
        shape object has "<strict>": true. UUID, ref and timestamp values are wildcarded;
        see Compare-WmuxJsonShape for the token list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Actual,
        [Parameter(Mandatory, Position = 1)][AllowNull()][object]$Shape,
        [Parameter(Position = 2)][string]$Message
    )
    $callerDir = $PSCmdlet.MyInvocation.PSScriptRoot
    $shapeValue = Resolve-WmuxShapeInput -Shape $Shape -CallerDir $callerDir
    $actualValue = ConvertTo-WmuxNormalizedJson -Value $Actual -ParseStrings
    $mismatches = Compare-WmuxJsonShape -Actual $actualValue -Shape $shapeValue
    if ($mismatches.Count -gt 0) {
        $shown = @($mismatches | Select-Object -First 20)
        $more = if ($mismatches.Count -gt 20) { "`n  ... $($mismatches.Count - 20) more" } else { '' }
        Throw-WmuxAssertion ("Assert-JsonShape: $($mismatches.Count) mismatch(es):`n  " + ($shown -join "`n  ") + $more + "`n  actual: $(Format-WmuxValue $actualValue 1500)") $Message
    }
}

function Test-Case {
    <#
    .SYNOPSIS
        Runs one named test: timing, result capture (JSONL for run.ps1), failure artifacts,
        a per-test watchdog (WMUX_E2E_TEST_TIMEOUT_SEC, default 120 s) and the focus check.
        Failures never escape: the next Test-Case in the file still runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Body
    )
    if ($script:State.CurrentTest) {
        throw [WmuxAssertionError]::new("Test-Case '$Name' is nested inside '$($script:State.CurrentTest.Name)'; nesting is not supported")
    }
    $file = $MyInvocation.PSCommandPath
    $relFile = Get-WmuxRelativeTestFile $file
    $filter = $env:WMUX_E2E_FILTER
    if ($filter) {
        $pattern = if ($filter.Contains('*') -or $filter.Contains('?')) { $filter } else { "*$filter*" }
        if (-not ($Name -like $pattern -or ($relFile -and $relFile -like $pattern))) {
            Write-Host "[----] $Name (filtered out)" -ForegroundColor DarkGray
            return
        }
    }
    $timeoutSec = 120
    if ($env:WMUX_E2E_TEST_TIMEOUT_SEC) { $timeoutSec = [double]$env:WMUX_E2E_TEST_TIMEOUT_SEC }
    $test = @{
        Name      = $Name
        File      = $file
        Instances = [System.Collections.Generic.List[object]]::new()
        Streams   = [System.Collections.Generic.List[object]]::new()
    }
    $focusBase = [WmuxTestHarness.FocusSampler]::ViolationCount
    $visibleBase = [WmuxTestHarness.FocusSampler]::VisibleCount
    $started = [DateTime]::UtcNow
    $script:State.CurrentTest = $test
    $script:State.FailMark = $false
    $status = 'passed'
    $kind = $null
    $message = $null
    $details = $null
    $violations = @()
    $visible = @()
    $artifacts = $null
    $savedEap = $global:ErrorActionPreference
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [WmuxTestHarness.Watchdog]::Arm([int]($timeoutSec * 1000))
    try {
        # Non-terminating errors fail the test; body output is discarded (use Write-Host).
        $global:ErrorActionPreference = 'Stop'
        $null = & $Body
    } catch {
        $err = $_
        $skip = Find-WmuxException $err.Exception ([WmuxSkipException])
        if ($skip) {
            $status = 'skipped'
            $kind = 'skip'
            $message = $skip.Message
        } else {
            $status = 'failed'
            $assert = Find-WmuxException $err.Exception ([WmuxAssertionError])
            $rpc = Find-WmuxException $err.Exception ([WmuxRpcError])
            if ($assert) {
                $kind = 'assertion'
                $message = $assert.Message
            } elseif ($rpc) {
                $kind = 'rpc'
                $message = "rpc '$($rpc.Method)' failed: $($rpc.Code): $($rpc.Message)"
                if ($null -ne $rpc.Data) { $message += " data=$(Format-WmuxValue $rpc.Data 300)" }
            } else {
                $kind = 'error'
                $inner = Get-WmuxInnerException $err.Exception
                $message = "$($inner.GetType().Name): $($inner.Message)"
            }
            $details = $err.ScriptStackTrace
            if ($kind -ne 'assertion' -and $err.InvocationInfo -and $err.InvocationInfo.ScriptName) {
                $message += " (at $(Split-Path -Leaf $err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber))"
            }
        }
    } finally {
        $global:ErrorActionPreference = $savedEap
        $sw.Stop()
    }
    try {
        if ([WmuxTestHarness.Watchdog]::Disarm()) {
            $status = 'failed'
            $kind = 'timeout'
            $message = "test exceeded the ${timeoutSec}s per-test timeout; its wmux instances were killed" + $(if ($message) { ". First error: $message" } else { '' })
        }
        foreach ($s in $test.Streams) { try { $s.Close() } catch { } }
        foreach ($inst in $test.Instances) {
            if (-not $inst.Stopped) {
                if ($status -eq 'failed') { $inst.Failed = $true; $script:State.FailMark = $true }
                Write-Host "       WmuxTest: instance pid $($inst.Pid) was not stopped by the test; stopping it" -ForegroundColor DarkYellow
                try { Stop-WmuxInstance $inst } catch { }
            }
        }
        $violations = @([WmuxTestHarness.FocusSampler]::Since($focusBase))
        if ($violations.Count -gt 0) {
            $status = 'failed'
            $kind = 'focus'
            $first = $message
            $message = 'focus stolen by test instance: ' + (($violations | ForEach-Object { $_.ToString() }) -join '; ')
            if ($first -and $first -ne $message) { $message += ". Test error: $first" }
        }
        $visible = @([WmuxTestHarness.FocusSampler]::VisibleSince($visibleBase))
        if ($visible.Count -gt 0) {
            $first = $message
            $text = 'visible test window: ' + (($visible | ForEach-Object { $_.ToString() }) -join '; ')
            if ($kind -eq 'focus') {
                $message = "$first. $text"
            } else {
                $kind = 'visible'
                $message = $text
                if ($first -and $status -eq 'failed') { $message += ". Test error: $first" }
            }
            $status = 'failed'
        }
        if ($status -eq 'failed') {
            foreach ($inst in $test.Instances) { $inst.Failed = $true }
        }
        $testDir = Join-Path (Get-WmuxArtifactBase) (Get-WmuxSlug $Name)
        foreach ($inst in $test.Instances) {
            $dest = Complete-WmuxInstanceCleanup -Instance $inst -ArtifactDir (Join-Path $testDir $inst.Id)
            if ($dest) { $artifacts = $testDir }
        }
    } finally {
        $script:State.CurrentTest = $null
        $script:State.FailMark = $false
    }
    $attempt = 1
    if ($env:WMUX_E2E_ATTEMPT) { $attempt = [int]$env:WMUX_E2E_ATTEMPT }
    $result = [ordered]@{
        file             = $relFile
        name             = $Name
        status           = $status
        kind             = $kind
        duration_ms      = [long]$sw.ElapsedMilliseconds
        message          = $message
        details          = $details
        artifacts        = $artifacts
        attempt          = $attempt
        started_at       = $started.ToString('o')
        instances        = @($test.Instances | ForEach-Object { [ordered]@{ pid = $_.Pid; channel = $_.Channel; protocol = $_.Protocol; exit_code = $_.ExitCode; hidden_mode = $_.HiddenMode; root_deletion = $_.RootDeletion; survivors = @($_.Survivors) } })
        focus_violations = @($violations | ForEach-Object { $_.ToString() })
        visible_windows  = @($visible | ForEach-Object { $_.ToString() })
    }
    Write-WmuxTestResult -Result $result
}

# ---------------------------------------------------------------------------
# Leak protection: instances still running when the harness process exits are killed
# (the kill-on-close job object covers abnormal exits as well).
# ---------------------------------------------------------------------------

$ExecutionContext.SessionState.Module.OnRemove = {
    foreach ($inst in @($script:State.Instances)) {
        try { if (-not $inst.Stopped) { Stop-WmuxProcessTree -Instance $inst } } catch { }
    }
}

Export-ModuleMember -Function @(
    'Start-WmuxInstance', 'Stop-WmuxInstance',
    'Invoke-WmuxRpc', 'Invoke-WmuxRawLine', 'Invoke-WmuxCli',
    'Open-WmuxEventStream', 'Read-WmuxEvents', 'Close-WmuxEventStream',
    'Wait-WmuxEvent', 'Wait-WmuxCondition', 'Wait-WmuxScreen',
    'Get-WmuxScreenshot', 'Get-WmuxToasts', 'Get-WmuxDialogs',
    'Assert-Equal', 'Assert-NotEqual', 'Assert-Match', 'Assert-True', 'Assert-Throws', 'Assert-JsonShape',
    'Test-Case'
)
