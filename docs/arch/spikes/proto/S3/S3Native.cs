// S3 spike reference prototype (not shipped): native helpers for the
// PowerShell harness (run-wmux-replay.ps1). Loaded with Add-Type.
//  * FgSampler: samples GetForegroundWindow every 100 ms and records a
//    violation if the foreground window belongs to the watched process.
//  * TopWindowsOf / SetSize: find the hidden test window and resize it
//    with SWP_NOACTIVATE (no focus change).
//  * PipeRequest: one request/response on the legacy wmux-ipc-<pid> pipe.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class S3Native
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    const uint SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

    public sealed class FgSampler
    {
        volatile bool stop;
        Thread thread;
        public volatile bool Violated;
        public volatile int Samples;
        public volatile int WatchedPid;
        public string Detail = "";
        public void Start(int pid)
        {
            WatchedPid = pid;
            thread = new Thread(() =>
            {
                while (!stop)
                {
                    IntPtr fg = GetForegroundWindow();
                    uint owner = 0;
                    if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out owner);
                    Samples++;
                    if (owner != 0 && owner == (uint)WatchedPid)
                    {
                        Violated = true;
                        Detail = "foreground hwnd 0x" + fg.ToString("X") + " owned by pid " + owner;
                    }
                    Thread.Sleep(100);
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }
        public void Stop() { stop = true; if (thread != null) thread.Join(1000); }
    }

    public static List<IntPtr> TopWindowsOf(int pid, string className)
    {
        var list = new List<IntPtr>();
        EnumWindows((h, l) =>
        {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner == (uint)pid)
            {
                var sb = new StringBuilder(256);
                GetClassNameW(h, sb, sb.Capacity);
                if (className == null || sb.ToString() == className) list.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // Physical pixels: make this thread per-monitor-v2 DPI aware around the
    // calls so the window rect is not DPI-virtualized.
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    static readonly IntPtr PMv2 = new IntPtr(-4);

    public static string Rect(IntPtr h)
    {
        var old = SetThreadDpiAwarenessContext(PMv2);
        try
        {
            RECT r;
            GetWindowRect(h, out r);
            return string.Format("{0},{1} {2}x{3} visible={4}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, IsWindowVisible(h));
        }
        finally { SetThreadDpiAwarenessContext(old); }
    }

    public static bool SetSize(IntPtr h, int w, int hgt)
    {
        var old = SetThreadDpiAwarenessContext(PMv2);
        try { return SetWindowPos(h, IntPtr.Zero, 0, 0, w, hgt, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE); }
        finally { SetThreadDpiAwarenessContext(old); }
    }

    /// Spin until the process has a top-level window of the class, then
    /// resize it immediately. Returns a description or null on timeout.
    public static string ResizeAsap(int pid, string className, int w, int hgt, int timeoutMs)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            var list = TopWindowsOf(pid, className);
            if (list.Count > 0)
            {
                string before = Rect(list[0]);
                bool ok = SetSize(list[0], w, hgt);
                return string.Format("at {0} ms: {1} -> {2} ok={3}", sw.ElapsedMilliseconds, before, Rect(list[0]), ok);
            }
            Thread.Sleep(2);
        }
        return null;
    }

    public static string PipeRequest(string pipeName, string jsonLine, int timeoutMs)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (true)
        {
            try
            {
                using (var c = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
                {
                    c.Connect(Math.Max(100, (int)(deadline - DateTime.UtcNow).TotalMilliseconds));
                    c.ReadMode = PipeTransmissionMode.Message;
                    var req = Encoding.UTF8.GetBytes(jsonLine + "\n");
                    c.Write(req, 0, req.Length);
                    c.Flush();
                    var ms = new MemoryStream();
                    var buf = new byte[65536];
                    while (true)
                    {
                        int n = c.Read(buf, 0, buf.Length);
                        if (n <= 0) break;
                        ms.Write(buf, 0, n);
                        if (buf[n - 1] == (byte)'\n') break;
                    }
                    return Encoding.UTF8.GetString(ms.ToArray());
                }
            }
            catch (Exception) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(100);
            }
        }
    }
}
