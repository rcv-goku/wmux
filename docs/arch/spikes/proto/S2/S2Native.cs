// S2 hidden-instance spike (W0-D-S2): native helpers for the PowerShell
// drivers (Add-Type -Path S2Native.cs). Reference material for W0-B's
// test/e2e/WmuxTest.psm1: focus sampler over a process tree, top-level
// window inventory with an Alt-Tab eligibility check, PrintWindow capture
// to PNG without System.Drawing, GUI-thread focus state, and process launch
// onto an alternate desktop (fallback evaluation only).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class S2Native
{
    // ------------------------------------------------------------ user32
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool AllowSetForegroundWindow(uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr hWnd, int idx);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetLastActivePopup(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr devmode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);

    /// PID owning the window a user click at the centre of `hwnd` would hit.
    public static uint HitTestCenterPid(IntPtr hwnd)
    {
        RECT r; GetWindowRect(hwnd, out r);
        var hit = WindowFromPoint(new POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 });
        uint pid; GetWindowThreadProcessId(hit, out pid);
        return pid;
    }

    /// A window of the watched tree that the user could see: visible, not
    /// minimized, not cloaked, non-empty and intersecting a monitor.
    public static bool IsUserVisible(IntPtr h)
    {
        if (!IsWindowVisible(h) || IsIconic(h)) return false;
        RECT r; if (!GetWindowRect(h, out r) || r.Right <= r.Left || r.Bottom <= r.Top) return false;
        // A failing DWM query means the window is being destroyed (seen once
        // during Kill teardown); only a successful "not cloaked" counts.
        int cloaked; if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) != 0 || cloaked != 0) return false;
        return MonitorFromRect(ref r, 0 /*MONITOR_DEFAULTTONULL*/) != IntPtr.Zero && IsWindowVisible(h);
    }

    // -------------------------------------------------------------- gdi32
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool GdiFlush();
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    // ----------------------------------------------------------- kernel32
    [DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOW si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32W
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFOW
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }

    public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    public const int WS_CHILD = 0x40000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000, WS_EX_NOACTIVATE = 0x08000000;
    public const int DWMWA_CLOAKED = 14;

    // -------------------------------------------------- process tree helpers
    public static Dictionary<uint, Tuple<uint, string>> SnapshotProcesses()
    {
        var map = new Dictionary<uint, Tuple<uint, string>>();
        IntPtr snap = CreateToolhelp32Snapshot(0x2 /*TH32CS_SNAPPROCESS*/, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return map;
        try
        {
            var pe = new PROCESSENTRY32W { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32W>() };
            if (Process32FirstW(snap, ref pe))
            {
                do { map[pe.th32ProcessID] = Tuple.Create(pe.th32ParentProcessID, pe.szExeFile); }
                while (Process32NextW(snap, ref pe));
            }
        }
        finally { CloseHandle(snap); }
        return map;
    }

    /// Root PID plus every live descendant (parent links from a Toolhelp snapshot).
    public static HashSet<uint> ProcessTree(uint root)
    {
        var map = SnapshotProcesses();
        var set = new HashSet<uint> { root };
        bool grew = true;
        while (grew)
        {
            grew = false;
            foreach (var kv in map)
                if (!set.Contains(kv.Key) && set.Contains(kv.Value.Item1) && kv.Key != kv.Value.Item1) { set.Add(kv.Key); grew = true; }
        }
        return set;
    }

    public static string ProcessName(uint pid)
    {
        try { return Process.GetProcessById((int)pid).ProcessName; } catch { return "?"; }
    }

    // ----------------------------------------------------- window inventory
    public sealed class WinInfo
    {
        public long Hwnd; public uint Pid; public uint Tid; public string Class; public string Title;
        public uint Style; public uint ExStyle; public bool Visible; public bool Iconic; public int Cloaked;
        public long Owner; public RECT Rect; public RECT Client; public bool AltTab; public bool Child;
        public override string ToString()
        {
            return string.Format("hwnd=0x{0:X} pid={1} tid={2} class={3} title=\"{4}\" style=0x{5:X8} ex=0x{6:X8} visible={7} iconic={8} cloaked={9} owner=0x{10:X} rect=({11},{12})-({13},{14}) client={15}x{16} alttab={17}",
                Hwnd, Pid, Tid, Class, Title, Style, ExStyle, Visible, Iconic, Cloaked, Owner, Rect.Left, Rect.Top, Rect.Right, Rect.Bottom, Client.Right, Client.Bottom, AltTab);
        }
    }

    static WinInfo Describe(IntPtr h, uint pid, uint tid)
    {
        var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
        var title = new StringBuilder(512); GetWindowTextW(h, title, 512);
        RECT r, c; GetWindowRect(h, out r); GetClientRect(h, out c);
        int cloaked; if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) != 0) cloaked = -1;
        return new WinInfo
        {
            Hwnd = h.ToInt64(), Pid = pid, Tid = tid, Class = cls.ToString(), Title = title.ToString(),
            Style = (uint)GetWindowLongW(h, GWL_STYLE), ExStyle = (uint)GetWindowLongW(h, GWL_EXSTYLE),
            Visible = IsWindowVisible(h), Iconic = IsIconic(h), Cloaked = cloaked,
            Owner = GetWindow(h, 4 /*GW_OWNER*/).ToInt64(), Rect = r, Client = c, AltTab = IsAltTabCandidate(h),
        };
    }

    /// Top-level windows (EnumWindows, current desktop) owned by any PID in `pids`.
    public static List<WinInfo> TopLevelWindows(HashSet<uint> pids)
    {
        var list = new List<WinInfo>();
        EnumWindows((h, l) =>
        {
            uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
            if (pids.Contains(pid)) list.Add(Describe(h, pid, tid));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// Child windows of `parent` (any process), e.g. the WebView2 HWNDs.
    public static List<WinInfo> ChildWindows(IntPtr parent)
    {
        var list = new List<WinInfo>();
        EnumChildWindows(parent, (h, l) =>
        {
            uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
            var wi = Describe(h, pid, tid); wi.Child = true; list.Add(wi);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// Alt-Tab eligibility: visible, is the "last active popup" of its root
    /// owner chain, not a tool window unless WS_EX_APPWINDOW, not cloaked.
    /// (Written from the documented shell rules; the taskbar check in the
    /// driver uses UI Automation as the empirical cross-check.)
    public static bool IsAltTabCandidate(IntPtr h)
    {
        if (!IsWindowVisible(h)) return false;
        IntPtr walk = IntPtr.Zero, tryH = GetAncestor(h, 3 /*GA_ROOTOWNER*/);
        while (tryH != walk)
        {
            walk = tryH;
            tryH = GetLastActivePopup(walk);
            if (IsWindowVisible(tryH)) break;
        }
        if (walk != h) return false;
        int ex = GetWindowLongW(h, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_APPWINDOW) == 0) return false;
        if ((ex & WS_EX_NOACTIVATE) != 0 && (ex & WS_EX_APPWINDOW) == 0) return false;
        int cloaked; if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return false;
        return true;
    }

    public static string GuiThreadInfo(uint tid)
    {
        var gi = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (!GetGUIThreadInfo(tid, ref gi)) return "GetGUIThreadInfo failed err=" + Marshal.GetLastWin32Error();
        return string.Format("flags=0x{0:X} active=0x{1:X} focus=0x{2:X} capture=0x{3:X} caret=0x{4:X}",
            gi.flags, gi.hwndActive.ToInt64(), gi.hwndFocus.ToInt64(), gi.hwndCapture.ToInt64(), gi.hwndCaret.ToInt64());
    }

    /// True when this process may currently set the foreground window
    /// (AllowSetForegroundWindow requires that right; granting it to our
    /// own PID is a no-op when we already hold it).
    public static string ForegroundRightsProbe()
    {
        bool ok = AllowSetForegroundWindow(GetCurrentProcessId());
        return ok ? "can_set_foreground=1" : "can_set_foreground=0 err=" + Marshal.GetLastWin32Error();
    }

    // ------------------------------------------------------------- capture
    public sealed class Capture
    {
        public bool Ok; public int Error; public int Width; public int Height; public int[] Pixels;
        public int Distinct; public double DominantFraction; public int Dominant; public long NonBlack;
        public override string ToString()
        {
            return string.Format("ok={0} err={1} size={2}x{3} distinct_colors={4} dominant=0x{5:X6} dominant_fraction={6:F4} nonblack_pixels={7}",
                Ok, Error, Width, Height, Distinct, Dominant & 0xFFFFFF, DominantFraction, NonBlack);
        }
    }

    /// PrintWindow(hwnd) into a top-down 32bpp DIB. flags: 1 = PW_CLIENTONLY,
    /// 2 = PW_RENDERFULLCONTENT.
    public static Capture PrintWindowCapture(IntPtr hwnd, uint flags)
    {
        RECT r; if ((flags & 1) != 0) GetClientRect(hwnd, out r); else GetWindowRect(hwnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        var cap = new Capture { Width = w, Height = h };
        if (w <= 0 || h <= 0) return cap;
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(screen);
        var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        IntPtr bits; IntPtr dib = CreateDIBSection(mem, ref bmi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = SelectObject(mem, dib);
        cap.Ok = PrintWindow(hwnd, mem, flags);
        cap.Error = cap.Ok ? 0 : Marshal.GetLastWin32Error();
        GdiFlush();
        cap.Pixels = new int[w * h];
        Marshal.Copy(bits, cap.Pixels, 0, w * h);
        SelectObject(mem, old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        var counts = new Dictionary<int, int>();
        foreach (int p in cap.Pixels)
        {
            int rgb = p & 0xFFFFFF;
            int n; counts.TryGetValue(rgb, out n); counts[rgb] = n + 1;
            if (rgb != 0) cap.NonBlack++;
        }
        cap.Distinct = counts.Count;
        int best = 0; foreach (var kv in counts) if (kv.Value > best) { best = kv.Value; cap.Dominant = kv.Key; }
        cap.DominantFraction = (double)best / (w * h);
        return cap;
    }

    /// Minimal PNG writer (RGB8, filter 0, zlib via ZLibStream).
    public static void SavePng(Capture cap, string path)
    {
        int w = cap.Width, h = cap.Height;
        var raw = new byte[h * (1 + w * 3)];
        int o = 0;
        for (int y = 0; y < h; y++)
        {
            raw[o++] = 0;
            for (int x = 0; x < w; x++)
            {
                int p = cap.Pixels[y * w + x];
                raw[o++] = (byte)((p >> 16) & 0xFF); raw[o++] = (byte)((p >> 8) & 0xFF); raw[o++] = (byte)(p & 0xFF);
            }
        }
        byte[] idat;
        using (var ms = new MemoryStream())
        {
            using (var z = new ZLibStream(ms, CompressionLevel.Optimal, true)) z.Write(raw, 0, raw.Length);
            idat = ms.ToArray();
        }
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            fs.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, 0, 8);
            var ihdr = new byte[13];
            WriteBE(ihdr, 0, (uint)w); WriteBE(ihdr, 4, (uint)h);
            ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
            WriteChunk(fs, "IHDR", ihdr); WriteChunk(fs, "IDAT", idat); WriteChunk(fs, "IEND", new byte[0]);
        }
    }

    static void WriteBE(byte[] b, int off, uint v) { b[off] = (byte)(v >> 24); b[off + 1] = (byte)(v >> 16); b[off + 2] = (byte)(v >> 8); b[off + 3] = (byte)v; }

    static uint[] crcTable;
    static uint Crc(byte[] type, byte[] data)
    {
        if (crcTable == null)
        {
            crcTable = new uint[256];
            for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; crcTable[n] = c; }
        }
        uint crc = 0xFFFFFFFFu;
        foreach (byte x in type) crc = crcTable[(crc ^ x) & 0xFF] ^ (crc >> 8);
        foreach (byte x in data) crc = crcTable[(crc ^ x) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    static void WriteChunk(Stream s, string type, byte[] data)
    {
        var len = new byte[4]; WriteBE(len, 0, (uint)data.Length); s.Write(len, 0, 4);
        var t = Encoding.ASCII.GetBytes(type); s.Write(t, 0, 4); s.Write(data, 0, data.Length);
        var crc = new byte[4]; WriteBE(crc, 0, Crc(t, data)); s.Write(crc, 0, 4);
    }

    // ------------------------------------------- alternate desktop launch
    /// Creates (or opens) desktop `name` in the current window station. The
    /// desktop object disappears when the last handle closes and no thread
    /// uses it. NEVER call SwitchDesktop: that would switch the user's screen.
    public static IntPtr CreateHiddenDesktop(string name)
    {
        IntPtr h = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /*GENERIC_ALL*/, IntPtr.Zero);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktopW");
        return h;
    }

    /// CreateProcessW with STARTUPINFO.lpDesktop, stdout+stderr to `logPath`,
    /// CREATE_NO_WINDOW, and a custom environment. Returns PROCESS_INFORMATION
    /// (caller closes handles).
    public static PROCESS_INFORMATION LaunchOnDesktop(string desktop, string commandLine, string cwd, IDictionary<string, string> env, string logPath)
    {
        var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(), bInheritHandle = true };
        IntPtr log = CreateFileW(logPath, 0x40000000 /*GENERIC_WRITE*/, 0x3, ref sa, 2 /*CREATE_ALWAYS*/, 0x80, IntPtr.Zero);
        if (log == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW");
        var sb = new StringBuilder();
        var keys = new List<string>(env.Keys); keys.Sort(StringComparer.OrdinalIgnoreCase);
        foreach (var k in keys) sb.Append(k).Append('=').Append(env[k]).Append('\0');
        sb.Append('\0');
        IntPtr block = Marshal.StringToHGlobalUni(sb.ToString());
        try
        {
            var si = new STARTUPINFOW { cb = Marshal.SizeOf<STARTUPINFOW>(), lpDesktop = desktop, dwFlags = 0x100 /*STARTF_USESTDHANDLES*/, hStdOutput = log, hStdError = log };
            PROCESS_INFORMATION pi;
            bool ok = CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true,
                0x08000000 /*CREATE_NO_WINDOW*/ | 0x400 /*CREATE_UNICODE_ENVIRONMENT*/, block, cwd, ref si, out pi);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW");
            return pi;
        }
        finally { Marshal.FreeHGlobal(block); CloseHandle(log); }
    }
}

/// Samples the OS foreground window every `IntervalMs` and records every
/// transition. A sample whose foreground PID belongs to the watched process
/// tree (root PID + descendants, refreshed every 250 ms) is a violation:
/// it is recorded and the tree is killed at once.
public sealed class FgSampler
{
    public int IntervalMs = 100;
    public volatile uint RootPid;
    public readonly List<string> Transitions = new List<string>();
    public int Samples, Violations;
    public string FirstViolation;
    public IntPtr InitialFg, LastFg;
    public uint InitialFgPid;
    public bool KillOnViolation = true;
    HashSet<uint> watched = new HashSet<uint>();
    readonly object gate = new object();
    Thread thread; volatile bool stop;
    readonly Stopwatch clock = Stopwatch.StartNew();

    public void Start()
    {
        InitialFg = S2Native.GetForegroundWindow();
        S2Native.GetWindowThreadProcessId(InitialFg, out InitialFgPid);
        LastFg = InitialFg;
        lock (gate) Transitions.Add(Describe(0, InitialFg, InitialFgPid, "initial"));
        thread = new Thread(Loop) { IsBackground = true, Name = "S2FgSampler" };
        thread.Start();
    }

    public void Stop() { stop = true; if (thread != null) thread.Join(2000); }

    /// Also fail (and kill) when any window of the tree is user-visible.
    public bool CheckVisibility = true;
    public int VisibleViolations;
    public string FirstVisible;

    void ScanVisible(long now, uint root)
    {
        HashSet<uint> w; lock (gate) w = new HashSet<uint>(watched);
        string hit = null;
        S2Native.EnumWindows((h, l) =>
        {
            uint p; S2Native.GetWindowThreadProcessId(h, out p);
            if (w.Contains(p) && S2Native.IsUserVisible(h)) { hit = Describe(now, h, p, "VISIBLE_ON_SCREEN"); return false; }
            return true;
        }, IntPtr.Zero);
        if (hit == null) return;
        Interlocked.Increment(ref VisibleViolations);
        if (FirstVisible == null) FirstVisible = hit;
        lock (gate) Transitions.Add(hit);
        if (KillOnViolation) { try { Process.GetProcessById((int)root).Kill(true); } catch { } }
    }

    public HashSet<uint> Watched { get { lock (gate) return new HashSet<uint>(watched); } }

    public string[] GetTransitions() { lock (gate) return Transitions.ToArray(); }

    string Describe(long ms, IntPtr h, uint pid, string tag)
    {
        // Privacy: titles of the user's own windows never reach test artifacts.
        bool ours; lock (gate) ours = watched.Contains(pid);
        var title = new StringBuilder(256); if (ours) S2Native.GetWindowTextW(h, title, 256);
        var cls = new StringBuilder(128); S2Native.GetClassNameW(h, cls, 128);
        return string.Format("t={0}ms {1} hwnd=0x{2:X} pid={3} proc={4} class={5} title=\"{6}\"", ms, tag, h.ToInt64(), pid, S2Native.ProcessName(pid), cls, ours ? title.ToString() : "<user window>");
    }

    void Loop()
    {
        long lastTree = -1000;
        while (!stop)
        {
            long now = clock.ElapsedMilliseconds;
            uint root = RootPid;
            if (root != 0 && now - lastTree >= 250)
            {
                var tree = S2Native.ProcessTree(root);
                lock (gate) watched.UnionWith(tree); // keep exited PIDs: no reuse within a run
                lastTree = now;
            }
            if (root != 0 && CheckVisibility) ScanVisible(now, root);
            IntPtr fg = S2Native.GetForegroundWindow();
            uint pid; S2Native.GetWindowThreadProcessId(fg, out pid);
            Interlocked.Increment(ref Samples);
            bool bad;
            lock (gate) bad = pid != 0 && watched.Contains(pid);
            if (fg != LastFg || bad)
            {
                string d = Describe(now, fg, pid, bad ? "VIOLATION" : "transition");
                lock (gate) Transitions.Add(d);
                LastFg = fg;
                if (bad)
                {
                    Interlocked.Increment(ref Violations);
                    if (FirstViolation == null) FirstViolation = d;
                    if (KillOnViolation && root != 0)
                    {
                        try { Process.GetProcessById((int)root).Kill(true); } catch { }
                    }
                }
            }
            Thread.Sleep(IntervalMs);
        }
    }
}
