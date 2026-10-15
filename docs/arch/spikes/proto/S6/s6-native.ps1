# wmux spike S6: small P/Invoke helpers (dot-source after s6-common.ps1).
if (-not ('S6Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class S6Native {
    [DllImport("userenv.dll", SetLastError = true)] static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    // The environment a new logon session would get (HKLM + HKCU\Environment), not ours.
    public static Dictionary<string, string> FreshEnvironment() {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0002, out tok)) throw new Win32Exception();
        IntPtr env;
        if (!CreateEnvironmentBlock(out env, tok, false)) { CloseHandle(tok); throw new Win32Exception(); }
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        IntPtr p = env;
        while (true) {
            string s = Marshal.PtrToStringUni(p);
            if (string.IsNullOrEmpty(s)) break;
            int eq = s.IndexOf('=', 1);
            if (eq > 0) d[s.Substring(0, eq)] = s.Substring(eq + 1);
            p = IntPtr.Add(p, (s.Length + 1) * 2);
        }
        DestroyEnvironmentBlock(env);
        CloseHandle(tok);
        return d;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BHFI { public uint attrs; public long ctime, atime, wtime; public uint vol, sizeHigh, sizeLow, links, idxHigh, idxLow; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(IntPtr h, out BHFI info);

    // "vol:index links=N" for a path (FILE_READ_ATTRIBUTES, share all).
    public static string FileId(string path) {
        IntPtr h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) return "error " + Marshal.GetLastWin32Error();
        BHFI i;
        bool ok = GetFileInformationByHandle(h, out i);
        CloseHandle(h);
        if (!ok) return "error " + Marshal.GetLastWin32Error();
        return string.Format("{0:X8}:{1:X8}{2:X8} links={3}", i.vol, i.idxHigh, i.idxLow, i.links);
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.I1)] static extern bool CreateSymbolicLinkW(string link, string target, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateHardLinkW(string link, string existing, IntPtr sa);

    // 0 on success, else the Win32 error. flags 0x2 = ALLOW_UNPRIVILEGED_CREATE.
    public static int TrySymlink(string link, string target, uint flags) { return CreateSymbolicLinkW(link, target, flags) ? 0 : Marshal.GetLastWin32Error(); }
    public static int TryHardLink(string link, string existing) { return CreateHardLinkW(link, existing, IntPtr.Zero) ? 0 : Marshal.GetLastWin32Error(); }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    // What a program that spawns "name args" without a shell gets: CreateProcessW with
    // lpApplicationName = NULL (CREATE_NO_WINDOW). "exit N" or "error <win32>".
    public static string SpawnNoShell(string commandLine) {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new System.Text.StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref si, out pi))
            return "error " + Marshal.GetLastWin32Error();
        WaitForSingleObject(pi.hProcess, 15000);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return "exit " + code;
    }
}
'@
}
