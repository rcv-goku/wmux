# Spike S6: CLI forwarders in `%LOCALAPPDATA%\Microsoft\WindowsApps`

| | |
|---|---|
| Spike | S6 (ARCHITECTURE ADR-14.7), W0-D |
| Consumers | W7 `install_cli` (ADR-4.2). Notes for W1-2/W1-3 (ADR-4.1 CLI layout) and W3-1/W3-2 (agent spawns) |
| Date | 2026-10-15 |
| Branch | `wp/W0-D-S6-cli-forwarders` (adds files under `docs/arch/spikes/` only; no wmux sources changed) |
| Decision | **Adopt with changes**: a tiny forwarder **`.exe`** (`cmux.exe` and `wmux.exe`, not `wmux.com`) that `CreateProcess`es `cli\cmux.exe`. Reject `.cmd` shims, hard links, symlinks and App Paths. The documented manual PATH step stays as the fallback |

## 1. Question

ADR-4.2 says the installer never touches PATH. Outside wmux terminals, `cmux install-cli` copies small forwarders into a directory that is already on PATH (default `%LOCALAPPDATA%\Microsoft\WindowsApps`). The forwarders find the real CLI through `HKCU\Software\wmux\InstallDir`. This spike answers:

1. Do forwarders placed in WindowsApps run from cmd.exe, pwsh and Git Bash? Are they still found in new shell sessions?
2. Do argv, stdin, stdout, stderr and exit codes reach `cli\cmux.exe` unchanged?
3. Which mechanism works best: a tiny forwarder exe that `CreateProcess`es the CLI, a `.cmd` shim, or hard links? Symlinks and App Paths were tested too.
4. How do Windows Defender, SmartScreen and the installed EDR behave (blocking, delays)?
5. Do App Execution Aliases interfere?
6. What changes on ARM64 compared with x64?

## 2. Setup

**Machine.** Windows 11 Enterprise 25H2 (build 26200.9448), x64 (AMD64), 14 logical CPUs. The CPU was at 100 % for most of the run because other agents were running parallel `zig` builds; see §3.15.

- **Security products.**
  - CrowdStrike Falcon Sensor is the active AV/EDR (SecurityCenter2 `productState 266240`).
  - Microsoft Defender Antivirus is not running: `Get-MpComputerStatus` shows `AMRunningMode: Not running` and the `WinDefend` service is stopped.
  - Smart App Control is off (`VerifiedAndReputablePolicyState=0`).
  - WDAC enforces kernel-mode code integrity only (user-mode CI off, `UsermodeCodeIntegrityPolicyEnforcementStatus=0`).
  - The AppLocker policy is empty. Developer Mode is off.
- **PATH.** The user PATH (`HKCU\Environment\Path`, REG_EXPAND_SZ) contains `%USERPROFILE%\AppData\Local\Microsoft\WindowsApps` as its 2nd of 5 entries. In the process PATH it comes after all 11 machine entries. PATHEXT is the default (`.COM;.EXE;.BAT;.CMD;...`).
- **WindowsApps.** ACL: SYSTEM, Administrators and the user have Full control (no deny ACEs). The folder already holds 36 App Execution Aliases (0-byte reparse points) and 21 subfolders.
- **Shells.**
  - cmd.exe 10.0.26200.9448.
  - pwsh 7.6.6 (`$PSNativeCommandArgumentPassing = Windows`).
  - Windows PowerShell 5.1.26100.9444.
  - Git Bash: GNU bash 5.2.37 (x86_64-pc-msys), Git 2.53.0.windows.2.
  - WSL: Ubuntu 24.04. Its `/etc/wsl.conf` sets `appendWindowsPath = false`.
- **Toolchain.** Zig 0.15.2 (`zig build-exe`). No full wmux build was needed.

**Prototype** (all under `docs/arch/spikes/proto/S6/`):

| File | What it is |
|---|---|
| `fwd.zig` | The forwarder. ReleaseSmall and stripped: **16,384 B x64, 12,800 B arm64**; imports only KERNEL32 and ADVAPI32. It reads `HKCU\Software\wmuxspikefwd\InstallDir` (the stand-in for `HKCU\Software\wmux\InstallDir`) and runs `<InstallDir>\cli\wmuxspikefwd-target.exe` (stand-in for `cli\cmux.exe`). Test switches via env `WMUXSPIKEFWD_MODE`: `nojob`, `nullhandler`, `nohandler`, `nodetach` |
| `target.zig` | Fake `cmux.exe`. Modes: `argv` prints a JSON report (raw command line, argv, own path, std handle kinds, console window, inherited Ctrl+C-ignore flag, job). Other modes: `exit N`, `cat`, `sha`, `emit N`, `stderr`, `ctrlc`, `sleep`, `spawn-grandchild` |
| `build.ps1` | Builds both programs into `zig-out\spike-s6\bin` (gitignored) |
| `s6-matrix.ps1` | Main matrix across cmd, pwsh, Windows PowerShell, Git Bash, the Process API and WSL. Installs the files, runs the test groups, then always runs cleanup |
| `s6-conpty.ps1` | Interactive console and Ctrl+C tests under a pseudoconsole (no window) |
| `s6-detached.ps1` | Forwarder started by a parent with no console or with a window-less console. Runs on a private desktop that is never shown |
| `s6-timing.ps1` | Launch overhead (interleaved, paired) and the cost of the first launch of never-seen binaries |
| `s6-regflags.ps1` | `RegGetValueW` flag behavior for REG_SZ and REG_EXPAND_SZ values |
| `s6-native.ps1`, `s6-common.ps1` | P/Invoke and shell-driver helpers |
| `s6-fgsampler.ps1` | Foreground sampler: `GetForegroundWindow` and `GetWindowThreadProcessId` every 100 ms |
| `s6-cleanup.ps1` | Removes every spike artifact and verifies the removal |
| `results/*.json` | Raw results of the final runs. The profile path is replaced by `%USERPROFILE%` |

**Fake install.** The CLI was installed at `...\zig-out\spike-s6\Programs X\wmux spike\cli\wmuxspikefwd-target.exe` (the path contains spaces). A second copy sits under a non-ASCII path, `...\Prógrams é\wmux\cli\`.

**Files in WindowsApps** (all named `wmuxspikefwd*`):

| File | Kind |
|---|---|
| `wmuxspikefwd.exe` | forwarder |
| `wmuxspikefwdc.com` | byte copy of the forwarder named `.com` (the ADR's `wmux.com` idea) |
| `wmuxspikefwdcmd.cmd` | `.cmd` shim: `@"<target>" %*` |
| `wmuxspikefwdhl.exe` | hard link to the target |
| `wmuxspikefwdsh` | extensionless LF sh launcher: `exec "$(dirname "$0")/wmuxspikefwd.exe" "$@"` |

Some groups added files temporarily and deleted them: `wmuxspikefwdlate.exe`, `wmuxspikefwdp.{com,exe,cmd}` and an extensionless `wmuxspikefwdp`, `wmuxspikefwdu8.cmd`, `wmuxspikefwdoem.cmd`, `wmuxspikefwdmotw.exe`, `wmuxspikefwdhlu.exe` (plus a `.old` rename), and `wmuxspikefwdnew1..8.exe`.

**Focus safety.**
- Every process was started with `UseShellExecute=false, CreateNoWindow=true`, or under a pseudoconsole, or on a private desktop.
- Extensionless names were never run from cmd or PowerShell (see §3.7).
- The foreground sampler ran during the matrix, ConPTY and private-desktop runs. It logged only the user's own changes (WindowsTerminal, Idle, LockApp). No spike process ever became foreground.
- The timing runs start children only inside one hidden console, so they cannot create windows.

**Reproduce** (PowerShell 7, from the worktree root). Every script is self-cleaning; run `s6-cleanup.ps1` after an interrupted run.

```powershell
pwsh -File docs/arch/spikes/proto/S6/build.ps1
pwsh -File docs/arch/spikes/proto/S6/s6-matrix.ps1        # all groups; ~20 min on a loaded machine
pwsh -File docs/arch/spikes/proto/S6/s6-conpty.ps1
pwsh -File docs/arch/spikes/proto/S6/s6-detached.ps1
pwsh -File docs/arch/spikes/proto/S6/s6-timing.ps1
pwsh -File docs/arch/spikes/proto/S6/s6-regflags.ps1
pwsh -File docs/arch/spikes/proto/S6/s6-cleanup.ps1
```

## 3. Results

### 3.1 Resolution by bare name (`results/resolution.json`, `barename.json`, `spawn.json`)

| Typed name → file | cmd | pwsh 7.6 | WinPS 5.1 | Git Bash | `CreateProcessW(NULL, …)` / .NET `Process.Start` (no shell) |
|---|---|---|---|---|---|
| `wmuxspikefwd` → `.exe` forwarder | runs | runs | runs | runs | runs |
| `wmuxspikefwdc` → `.com` forwarder | runs | runs | runs | **not found** (127) | **not found** (`ERROR_FILE_NOT_FOUND` 2) |
| `wmuxspikefwdcmd` → `.cmd` shim | runs | runs | runs | **not found** (127) | **not found** (2) |
| `wmuxspikefwdhl` → `.exe` hard link | runs | runs | runs | runs | runs |
| `wmuxspikefwdsh` → extensionless | not run (see §3.7); listed by `where` | not run; **`Get-Command` lists it as `Application`** | not run; same as pwsh | runs | n/a |

- With the extension typed (`wmuxspikefwdc.com`, `wmuxspikefwdcmd.cmd`), Git Bash and `CreateProcessW` both work.
- Git Bash only appends `.exe` when it searches PATH.
- `CreateProcessW` and .NET append `.exe` only. Any runtime that hands the bare name to `CreateProcessW` behaves the same; only runtimes with their own PATHEXT search would find `.com`.

**argv[0] as the CLI sees it** through the forwarder (needed for cmux/wmux branding):
- From cmd it is the typed name, with no path and no extension (`wmuxspikefwd`).
- From pwsh, Windows PowerShell and Git Bash it is the full path `...\WindowsApps\wmuxspikefwd.exe`.
- Through the `.cmd` shim it is the target's own path, so the branding is lost.
- Through the hard link it is the link name. `GetModuleFileNameW` in the CLI then returns the **WindowsApps path**, not the install directory.

### 3.2 argv fidelity (`results/argv.json`)

**Method.**
- Three argument vectors were passed with each shell's native quoting:
  - **basic**: empty string, space, embedded `"`, trailing `\`, `\\"`, lone `"`, lone `\`, `--`, `--help`, `+verb`, tab.
  - **unicode**: `héllo`, `日本語`, an emoji, `Ünïcödé spaced`.
  - **special**: `&`, `|`, `^`, `%`, `%PATH%`, `!`, `<`, `>`, `(`, `)`, `;`, a backtick, `$`, `'`, `*`, `~`, `/slash-opt`, `C:/fwd/slash`.
- That makes 4 shells × 3 vectors × 5 variants (direct, forwarder `.exe`, forwarder `.com`, `.cmd`, hard link).

**Results.**
- **The forwarder (`.exe` and `.com`) and the hard link deliver exactly what direct invocation delivers in all 12 shell/vector cases.** The forwarder passes `GetCommandLineW()` through verbatim, so no bytes are re-quoted.
- **The `.cmd` shim differs from direct in 5 of 12 cases:**
  - Any argument containing `&` is split when cmd re-parses `%*` inside the batch file. Only `a` reaches the CLI, `b` runs as a command (`'b' is not recognized…`), and the exit code becomes 255. This happens from **cmd, pwsh, Windows PowerShell and Git Bash** alike. It is an argument-injection hole in the BatBadBut class.
  - pwsh 7.6 uses legacy argument passing for `.cmd` files. The empty argument and embedded quotes collapse (`["a","b c","xy C:\dir\ …"]`).
- Shell quirks that affect direct and forwarded calls alike (not caused by forwarding):
  - cmd expands `%PATH%`.
  - Windows PowerShell 5.1 mangles empty and quoted arguments.
  - MSYS rewrites `/slash-opt` to `C:/Program Files/Git/slash-opt`.

### 3.3 Long command lines (`results/long.json`)

| Case | Result |
|---|---|
| Process API, 32,000 / 32,760 / **32,766**-char command line | Forwarder and direct both deliver it intact (the target sees the same length) |
| Process API, 32,767 chars | Both fail: "The filename or extension is too long" (`ERROR_FILENAME_EXCED_RANGE`) |
| pwsh and Git Bash, 292 arguments (~29,100 chars) | Intact |
| cmd, 80 arguments (7,818 chars) | Intact; cmd's own limit is 8,191 |

Reusing the original command line costs **zero** extra length. A forwarder that prepended the target path would overflow near the limit.

### 3.4 stdin, stdout and stderr (`results/stdio.json`)

**What was tested:**
- 4,194,560 bytes of random stdin covering every byte value.
- 3,000,000 bytes of patterned stdout.
- Through a file redirect (`<`, `>`) and pipes in both directions.
- In cmd, pwsh 7.6 (native byte pipes), Git Bash and the Process API.

**Results:**
- The SHA-256 is identical for direct, forwarder, `.cmd` and hard link.
- stderr stays separate (`OUT-LINE` on stdout, `ERR-LINE` on stderr, exit 3).
- The forwarder inherits the handles and does not copy data, so it adds no throughput cost.
- Windows PowerShell 5.1 text pipes turn `é` into `?` for every variant, including direct. That is a 5.1 limitation.

### 3.5 Exit codes (`results/exit.json`)

| Context | 0 | 1 | 2 | 42 | 255 | 256 | 9009 | -1 | 0xC000013A | 0x7FFFFFFF |
|---|---|---|---|---|---|---|---|---|---|---|
| Process API / cmd / pwsh / WinPS (all variants) | 0 | 1 | 2 | 42 | 255 | 256 | 9009 | -1 | -1073741510 | 2147483647 |
| Git Bash (all variants) | 0 | 1 | 2 | 42 | 255 | 0 | 49 | 127 | 130 | 255 |

- Direct, forwarder `.exe`, `.com`, `.cmd` and hard link give identical results in every context.
- The forwarder passes all 32 bits through. Git Bash folds codes the MSYS way.
- The `.cmd` shim also propagates codes, except after Ctrl+C (see §3.8).

### 3.6 Sessions (`results/fresh.json`, `running.json`)

**New logon session.** `CreateEnvironmentBlock(token, bInherit=FALSE)` builds the environment Explorer gives a new logon. Its PATH contains WindowsApps as the 13th of 16 entries. cmd, pwsh, Windows PowerShell and Git Bash started with that block all resolve and run `wmuxspikefwd`.

**Shells that were already running.**
- Each shell checked that the name did not exist, then the file was copied into WindowsApps from inside that same shell.
- cmd, pwsh, Windows PowerShell and Git Bash all ran it on the next line.
- Install needs no new shell, no PATH change and no `WM_SETTINGCHANGE`.

**Uninstall while a shell is running.**
- After deletion, cmd says "not recognized" and pwsh throws `CommandNotFoundException`.
- Git Bash still has the old path hashed. It reports `…/WindowsApps/wmuxspikefwdlate: No such file or directory` until `hash -r`, after which it reports "command not found".
- The stale hash only matters if `install-cli --dir` moves the forwarders to another directory.

### 3.7 Same-name precedence inside one directory (`results/precedence.json`)

| Present in WindowsApps | cmd | pwsh | WinPS | Git Bash |
|---|---|---|---|---|
| `.com` + `.exe` + `.cmd` | `.com` | `.com` | `.com` | `.exe` |
| `.exe` + `.cmd` | `.exe` | `.exe` | `.exe` | `.exe` |
| `.cmd` only | `.cmd` | `.cmd` | `.cmd` | not found |
| extensionless + `.exe` | (not run) `where` lists the extensionless file first | `Get-Command` picks `.exe` | picks `.exe` | **extensionless** |
| extensionless + `.com` | (not run) | (not run) | (not run) | extensionless |

**Extensionless files are a hazard.**
- PowerShell resolves an extensionless file on PATH as an `Application`.
- If such a file were the only match, pwsh would try to start it as a document, which opens a foreground "Open with" dialog. The spike therefore never executed one from cmd or PowerShell.
- An extensionless launcher is safe only next to a same-named `.exe`, because PowerShell tries the PATHEXT names first within a directory.

### 3.8 Interactive console and Ctrl+C under ConPTY (`results/conpty.json`)

**Console detection.** Through the forwarder (started from cmd, pwsh and Git Bash), the CLI sees stdin, stdout and stderr as **console** (`GetConsoleMode` succeeds) and the inherited Ctrl+C-ignore flag is clear. The ADR-4.6 "interactive" detection therefore works through forwarders.

| Scenario (Ctrl+C written to the pseudoconsole after `READY`) | CLI output | Shell exit code |
|---|---|---|
| cmd → direct | `GOT_CTRL_C` | 130 |
| cmd → forwarder (handler routine) | `GOT_CTRL_C` | **130** |
| cmd → forwarder using `SetConsoleCtrlHandler(NULL, TRUE)` | `READY ignore_flag=1`, `TIMEOUT`: **the CLI never sees Ctrl+C** (the flag is inherited) | 124 |
| cmd → forwarder with no handler | the forwarder dies and the job kills the CLI (which may print `GOT_CTRL_C` first) | 0xC000013A: the CLI's code is lost |
| pwsh → direct / forwarder | `GOT_CTRL_C` | 1 / 1 (pwsh stops its script on Ctrl+C; same for both) |
| Git Bash → direct / forwarder | `GOT_CTRL_C` | identical for both; bash's own reaction varied between runs (`RC=130` vs exit 512) |
| cmd → `.cmd` shim | `GOT_CTRL_C`, then **`Terminate batch job (Y/N)?`** | `n` → 130; `y` → **255** (code lost) |

### 3.9 Parent without a console (`results/detached.json`)

These cases ran on a private desktop, so no window could reach the user.

| Parent starts the forwarder with | Result |
|---|---|
| `DETACHED_PROCESS` (GUIs, services, "detached" spawns), final forwarder | The CLI runs without a console and its output reaches the caller's pipe; same as direct |
| `DETACHED_PROCESS`, forwarder without the fix (`nodetach`) | **Windows gave the CLI a new console with a window** (`console_window=true`), and its output went into that window instead of the caller. On a real desktop this pops up a window |
| `CREATE_NO_WINDOW` (e.g. Node `windowsHide`) | The CLI inherits the window-less console; stdout pipe works |

**The fix.** When `GetConsoleCP() == 0`, add `DETACHED_PROCESS` and pass the std handles explicitly with `STARTF_USESTDHANDLES`. A first attempt that added only `DETACHED_PROCESS` lost all output, because a detached child does not inherit the std handles implicitly.

### 3.10 Process lifetime (`results/job.json`)

| Test | Result |
|---|---|
| Kill only the forwarder (default: kill-on-close job) | The CLI process is gone within 0.5 s |
| Same with `nojob` | The CLI keeps running, orphaned |
| CLI starts a detached grandchild (stands in for launching the GUI), then exits | The grandchild **survives** (`JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`) |

The forwarder nested its job inside the job the test harness already ran in. `AssignProcessToJobObject` succeeded (Windows 8+ nested jobs).

### 3.11 Non-ASCII install path (`results/unicode.json`)

| Launcher (target under `Prógrams é\…`) | cmd `chcp 437` | cmd `chcp 65001` | pwsh |
|---|---|---|---|
| `.cmd` saved as UTF-8 | fails: "The system cannot find the path specified." | **fails** | fails |
| `.cmd` saved as OEM 437 | works | works | works |
| exe forwarder (InstallDir in the UTF-16 registry) | works | works | works (Git Bash too) |

A `.cmd` shim only works if it is written in a code page that matches how cmd happens to decode it. That is fragile for non-ASCII user names (`%LOCALAPPDATA%\Programs\wmux` contains the user name).

### 3.12 Hard links, symlinks and file locks (`results/links.json`)

**Hard links.**
- `CreateHardLinkW` from WindowsApps to the install dir works on the same volume. This machine has only `C:`, so `ERROR_NOT_SAME_DEVICE` (17) for other volumes could not be tested.
- The CLI started through the link reports `GetModuleFileNameW` = `...\WindowsApps\wmuxspikefwdhlu.exe`. It cannot find `..\wmux.exe` from there.
- **Update in place** (CopyFile onto the existing name): the link sees the new version (same file ID).
- **Update by write-temp-then-`MoveFileEx(REPLACE_EXISTING)`** (how installers usually replace files): **the link keeps the old version** (different file IDs). This is permanent version skew.
- While a CLI runs through the link: overwriting the install copy fails with a sharing violation, but **deleting the install copy succeeds**. The link is then the only name left for the old version, so an updater can install a new CLI beside it without noticing.

**Symlinks.** `CreateSymbolicLinkW` fails with `ERROR_PRIVILEGE_NOT_HELD` (1314), both with and without `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`, because Developer Mode is off.

**A running forwarder in WindowsApps:**
- Overwriting it fails ("being used by another process").
- Renaming it to `.old` works, and copying the new forwarder under the old name then works.
- Deleting the `.old` copy is denied while it runs and works after it exits.

### 3.13 App Paths (`results/apppaths.json`)

The test key was `HKCU\…\App Paths\wmuxspikefwdap.exe`, with its default value set to the target. It does not help a CLI:

| Caller | Result |
|---|---|
| cmd | "not recognized" |
| pwsh, Windows PowerShell | `CommandNotFoundException` |
| Git Bash | 127 |
| `Start-Process -NoNewWindow` | "cannot find the file" |
| `ShellExecuteEx` (hidden, `SEE_MASK_NO_CONSOLE`) | resolves it (exit 7) |

Only ShellExecute callers use App Paths: Win+R, Explorer, and `start`.

### 3.14 Windows Defender, SmartScreen, CrowdStrike, Mark-of-the-Web (`results/motw.json`, `timing-*.json`)

**Windows Defender.** It is not running on this machine (CrowdStrike is the registered AV), so **Defender's behavior could not be measured** (see §6).

**CrowdStrike Falcon.**
- No launch was blocked and no file was quarantined.
- All forwarder copies were still present when each run ended, including the 24 never-seen binaries of each timing run (8 of them in WindowsApps).
- First launch of a never-seen binary vs. its second launch. Unique bytes per copy, 8 samples per row, medians at 100 % CPU load. The final run (`results/timing-1522.json`) is shown, with an earlier run in parentheses:

  | Binary | First launch | Second launch |
  |---|---|---|
  | 16 KB forwarder in WindowsApps | 681 ms (789) | 355 ms (315) |
  | Same forwarder in a scratch dir | 680 ms (532) | 403 ms (355) |
  | 556 KB CLI | 758 ms (569) | 231 ms (158) |

- The first launch costs roughly +0.2–0.5 s, once per new binary.
- WindowsApps showed no consistent location effect (681 vs 680 ms in the final run), and nothing was blocked in either location.

**Mark-of-the-Web.**
- `Copy-Item` and `File.Copy` (CopyFile) **copy the `Zone.Identifier` stream** into WindowsApps. Writing the bytes yourself does not.
- A forwarder tagged `ZoneId=3` ran without any prompt from cmd, pwsh, Windows PowerShell and Git Bash. SmartScreen is a ShellExecute/Explorer check and does not apply to `CreateProcess` launches.

### 3.15 Launch overhead (`results/timing-*.json`)

Measured inside one hidden console with 60 interleaved rounds (`exit 0`), on a machine at 100 % CPU (6 parallel `zig` builds plus EDR). This is the final run with the final forwarder (`results/timing-1522.json`); an earlier run is in parentheses:

| Variant | Median | Min | Paired overhead vs direct (median) |
|---|---|---|---|
| direct CLI | 270 ms (186) | 115 ms (87) | – |
| forwarder `.exe` (job) | 657 ms (439) | 257 ms (222) | +389 ms (+247) |
| forwarder `.exe` (no job) | 661 ms (438) | 219 ms (219) | +400 ms (+248) |
| hard link | 237 ms (200) | 94 ms (88) | −14 ms (+4) |
| `.cmd` shim | 958 ms (609) | 304 ms (275) | +654 ms (+396) |

- In both runs the forwarder costs about one extra process creation (about 2.4× a direct launch under this load). The job object costs nothing measurable. A `.cmd` shim costs clearly more (`cmd.exe` plus batch parsing).
- The absolute numbers are inflated by the load. On an idle machine, process creation typically takes tens of milliseconds, but this spike could not measure that (see §6).
- **Install and uninstall are cheap:** copying the five test files took 130–210 ms.

### 3.16 App Execution Aliases

**What they are.**
- Aliases in WindowsApps are 0-byte files with reparse tag `0x8000001B` (`IO_REPARSE_TAG_APPEXECLINK`) and attributes `Archive, ReparsePoint`.
- Opening one as a file fails with `ERROR_CANT_ACCESS_FILE` (1920, HRESULT 0x80070780). install-cli must detect aliases with an attribute check instead of opening or overwriting them. Overwriting one was not attempted, because the alias belongs to an installed package.

**Interaction with the forwarders.**
- The forwarders are regular files. They coexist with aliases and are listed normally by `where`, `Get-Command` and `type -P`.
- They are not package aliases, so the Settings → Apps → Advanced app settings → App execution aliases page does not manage them. That page lists packaged aliases only; the Settings UI was not opened during the spike.
- No interference was observed for the test names.
- A collision is possible only if some package declares a `cmux.exe` or `wmux.exe` alias. One example is a future wmux MSIX, whose alias would then replace install-cli.

**The reverse also happens.**
- In this session, `python` and `python3` typed in Git Bash hit the Store-redirect alias stubs in WindowsApps.
- Aliases sit in the same late PATH position, and any `cmux`/`wmux` in an earlier PATH directory shadows the forwarders. Machine PATH entries always come first.

### 3.17 WSL (`results/wsl.json`)

**Default config here.** With this machine's `appendWindowsPath = false`, nothing in WindowsApps is visible from WSL. That is the user's configuration choice.

**With WindowsApps appended** (as the default `appendWindowsPath=true` would do):

| Command in WSL | Result |
|---|---|
| `wmuxspikefwd.exe` | works through interop: argv including `""` and `x"y` intact, stdin pipe intact, `exit 300` → 44 |
| `wmuxspikefwd` (bare name) | not found |
| extensionless sh launcher | works |

### 3.18 ARM64 and x64

- The forwarder cross-compiles with `-target aarch64-windows-gnu` (12,800 B, PE machine `0xAA64`) with no source changes. It could not be run here because no ARM64 device was available.
- The installer is `x64compatible`, so on Windows 11 ARM64 both an x64 forwarder and `cli\cmux.exe` would run under emulation.
- A native ARM64 forwarder gains nothing while the CLI stays x64. Ship the forwarder in the same architecture as the CLI build.
- None of the APIs used (registry, job objects, console control, `CreateProcessW`) behaves differently on ARM64. An x64 process is not subject to WOW64 registry redirection, and `HKCU\Software` is shared anyway.

## 4. Decision

**Adopt with changes.** WindowsApps is a viable install target.
- It is on the user PATH of every new session.
- Shells that are already open pick files up immediately.
- No PATH edit or broadcast is needed.
- No AV/EDR blocked anything on this machine.

The mechanism is a **tiny forwarder `.exe`** that passes its original command line verbatim to `cli\cmux.exe`. It was transparent in every measured dimension: argv bytes, 32,766-character lines, binary stdio, full 32-bit exit codes, console detection, and Ctrl+C.

Changes to ADR-4.2 as written:

1. **Install `cmux.exe` and `wmux.exe` (identical bytes), not `wmux.com`.**
   - `.com` is not found by Git Bash bare-name lookup, nor by `CreateProcessW`, .NET or other no-shell spawns (§3.1).
   - `.com` precedence only matters inside one directory, and WindowsApps contains no GUI `wmux.exe`.
   - Branding comes from argv[0].
2. **The forwarder is a separate program**, shipped as `INSTALL\cli\wmux-forwarder.exe` (about 16 KB, signed), with the behavior pinned in §5.1. Do not copy `cmux.exe` itself into WindowsApps: a copy goes stale and drifts from the installed version.
3. **install-cli behavior is pinned in §5.2:**
   - verify PATH membership and report shadowing;
   - refuse reparse points;
   - write bytes rather than CopyFile (avoids Mark-of-the-Web);
   - replace atomically, renaming away a running forwarder;
   - record `InstallDir`.
4. **Rejected alternatives:**

   | Alternative | Why it is rejected |
   |---|---|
   | `.cmd` shim | argument injection through `& \| < > ^` in all four shells; pwsh legacy quoting; `Terminate batch job (Y/N)?` and a lost exit code on Ctrl+C; invisible to Git Bash and no-shell spawns; breaks with non-ASCII paths depending on code page |
   | Hard links | same volume only; the CLI cannot locate its install; installer updates leave a stale CLI behind |
   | Symlinks | `ERROR_PRIVILEGE_NOT_HELD` without Developer Mode |
   | App Paths | ShellExecute only |
   | Extensionless launchers in WindowsApps | PowerShell treats them as Applications; only useful for WSL |

5. **Fallback.** When install-cli finds that WindowsApps (or `--dir`) is not on the persisted user or machine PATH, it prints the manual PATH step and exits 1. It never edits PATH.

## 5. Guidance for the consuming WPs

### 5.1 Forwarder (W7 `install_cli`; source e.g. `src/wmux_cli/forwarder/main.zig`, std + kernel32/advapi32 only)

API sequence. This is condensed from `proto/S6/fwd.zig`; production uses `HKCU\Software\wmux\InstallDir` and `cli\cmux.exe`.

```zig
// 1. InstallDir: RRF_RT_REG_SZ also accepts REG_EXPAND_SZ and expands it (verified);
//    RRF_RT_REG_EXPAND_SZ alone fails with ERROR_UNSUPPORTED_TYPE (1630).
rc = RegGetValueW(HKEY_CURRENT_USER, L("Software\\wmux"), L("InstallDir"), RRF_RT_REG_SZ, null, &path_buf, &cb);
// trim NULs and trailing '\', append "\cli\cmux.exe", check with GetFileAttributesW;
// on failure: one-line message on stderr, ExitProcess(1).

// 2. Command line: our own, verbatim (writable copy). argv[0] stays what the user
//    typed, so the CLI brands itself; no re-quoting, no extra length.
@memcpy(cmd_buf[0..len], GetCommandLineW()[0..len]);

// 3. Ctrl+C/Break: a handler routine that returns TRUE (the CLI gets the same event).
//    NEVER SetConsoleCtrlHandler(NULL, TRUE): children inherit that flag (§3.8).
//    CLOSE/LOGOFF/SHUTDOWN: wait up to ~4 s for the child, then return FALSE.
_ = SetConsoleCtrlHandler(ctrlHandler, TRUE);

// 4. Job: KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK (the CLI dies with us; the GUI it
//    launches does not). Best effort: if Assign fails, run unjobbed.
info.BasicLimitInformation.LimitFlags = 0x2000 | 0x1000;
_ = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info)));

// 5. Relay. No STARTF_USESTDHANDLES when we have a console (console and redirected
//    handles reach the CLI as-is); without a console, mirror it (§3.9).
var flags: DWORD = CREATE_SUSPENDED;
if (GetConsoleCP() == 0) {
    flags |= DETACHED_PROCESS;
    si.dwFlags |= STARTF_USESTDHANDLES; // + SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
    si.hStdInput = stdin_h; si.hStdOutput = stdout_h; si.hStdError = stderr_h;
}
CreateProcessW(target_path, cmd_buf, null, null, TRUE, flags, null, null, &si, &pi);
AssignProcessToJobObject(job, pi.hProcess); ResumeThread(pi.hThread);
WaitForSingleObject(pi.hProcess, INFINITE);
GetExitCodeProcess(pi.hProcess, &code);
ExitProcess(code);                         // all 32 bits
```

- Embed an identity marker (e.g. the constant string `wmux-cli-forwarder/1`) and a VERSIONINFO resource. install-cli recognizes its own files by the marker; AV reputation benefits from the version info.
- **Sign the forwarder** with the same certificate as `cmux.exe` (ADR-4.11 risks).
- Never parse or intercept arguments. Never print anything on success. The forwarder must stay invisible, so the CLI owns `--version`, help and every error path except "CLI not found".
- **Do not** set `WMUX_ARGV0`. argv[0] already carries the name; the variable is only for launchers that cannot control argv[0].
- Build x64 now and ARM64 when the CLI ships ARM64 (`-target aarch64-windows-gnu`, no code changes). Use ReleaseSmall and strip.

### 5.2 `cmux install-cli [--dir D]` / `uninstall-cli` (W7, offline commands)

1. `self = GetModuleFileNameW()`, `install = parent(parent(self))`. Require `install\cli\cmux.exe` and `install\cli\wmux-forwarder.exe`.
2. `dir = D` or `<FOLDERID_LocalAppData>\Microsoft\WindowsApps`.
3. **PATH check.**
   - Read the persisted PATH, not the process PATH (inside wmux the process PATH has `INSTALL\cli` prepended).
   - Use `RegGetValueW(HKCU, "Environment", "Path", RRF_RT_REG_SZ)` and the same for `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`. Both come back expanded.
   - Split on `;`, trim spaces, quotes and trailing `\`, and compare case-insensitively with `dir`.
   - If `dir` is absent: print the manual PATH instructions and exit 1. Never write PATH (`installer.iss` rule).
4. **Shadowing check.** For `cmux` and `wmux`, walk the effective PATH entries *before* `dir` with PATHEXT. If one matches, warn: "`cmux` resolves to <file> first". Machine PATH comes first; on this machine `.local\bin` also precedes WindowsApps.
5. **For each name in `cmux.exe`, `wmux.exe`** (`dst = dir\name`):
   - If `dst` has `FILE_ATTRIBUTE_REPARSE_POINT` (an App Execution Alias; it cannot even be opened, error 1920), **refuse**: "owned by an installed app; disable it under App execution aliases or use `--dir`".
   - If `dst` exists without the forwarder marker, refuse unless `--force`.
   - Write the forwarder **bytes** to `dst.tmp-<pid>` (`CREATE_NEW`). Do not use CopyFile, which carries over `Zone.Identifier` from an extracted ZIP install (§3.14).
   - `MoveFileExW(tmp, dst, MOVEFILE_REPLACE_EXISTING)`. If that fails with `ERROR_ACCESS_DENIED` or `ERROR_SHARING_VIOLATION` (forwarder running), first `MoveFileExW(dst, dst.old-<n>)`, then move tmp into place.
   - Delete `*.old-*` opportunistically: now, on the next install-cli, and at app start. Each delete fails harmlessly while that old copy still runs.
6. `RegSetKeyValueW(HKCU, "Software\\wmux", "InstallDir", REG_SZ, install)`.
7. **Self-test.** Run `dst --version` hidden (`CREATE_NO_WINDOW`, pipes) and compare the output with the running version. This also pays the one-time EDR first-launch cost now (§3.14).
8. Report: "Installed `cmux` and `wmux` into <dir>; works in new and already-open terminals". Mention `hash -r` for open Git Bash shells only when `--dir` changed.

**Uninstall.** Delete `cmux.exe`, `wmux.exe` and `*.old-*` from the recorded dir, but only files carrying the marker. Remove `InstallDir` only if it points to this install.

**App start (feature `install_cli` `init`).** If forwarders are recorded as installed and `InstallDir` no longer contains `cli\cmux.exe` (reinstalled elsewhere), rewrite `InstallDir`. Never repoint it from a dev build (`zig-out`).

### 5.3 Requirements on `cmux.exe` (W1-2/W1-3)

- **Branding:** use the basename of argv[0] without its extension, compared case-insensitively. From cmd the value has no path and no extension (`wmux`); from pwsh and bash it is the full path (`...\WindowsApps\wmux.exe`).
- **Locate the install** with `GetModuleFileNameW` (`std.fs.selfExePath`), never argv[0]. Through the forwarder this is the real `cli\cmux.exe`.
- **Interactive detection** (ADR-4.6) works unchanged through the forwarder (console handles inherited, §3.8).
- Launching the GUI (`open`, `cmux <path>`) from under the forwarder needs nothing special. The silent-breakaway job leaves the GUI outside it (§3.10). The CLI must start the GUI detached and must not wait for it.

### 5.4 Findings for other WPs

- **ADR-4.1 `INSTALL\cli\wmux.com`** (W1-2):
  - A program inside a wmux terminal that spawns `wmux` without a shell (`CreateProcessW(NULL, "wmux …")`, .NET, many runtimes; agents do this) appends only `.exe`. It skips `cli\wmux.com` and lands on the GUI `INSTALL\wmux.exe` if INSTALL is on PATH, or on nothing.
  - Git Bash also skips `.com` and needs the extensionless launcher.
  - Recommendation: ship `cli\wmux.exe`, a byte copy of `cmux.exe`, instead of or next to `wmux.com`. `cli\` precedes `INSTALL` on PATH, so `.exe` wins there just as well.
  - The extensionless sh launchers in `cli\` are safe for PowerShell because `cmux.exe` and `wmux.com` sit in the same directory. Git Bash prefers them over `.exe`, which adds an `sh` hop; WSL needs them.
- **Agent shims (ADR-10.6, S4):** no-shell spawners find only `.exe` names, so the wrappers must stay `.exe` (as planned). Three rules from §5.1 apply to every wrapper that runs a child (`claude.exe`, `codex.exe`, `tmux.exe`):
  - relay `GetCommandLineW` verbatim;
  - use a handler routine, never the NULL Ctrl+C handler;
  - mirror a parent that has no console.
- **e2e for W7** (`test/e2e/suites/cli/W7-*.e2e.ps1`), reusing `proto/S6/s6-matrix.ps1` patterns:
  - install into a temporary `--dir` that is put on PATH for the test only;
  - assert bare-name resolution in cmd, pwsh and Git Bash;
  - check argv vectors, binary stdin/stdout, exit codes 0/1/2/255/0xC000013A, ConPTY Ctrl+C → 130, and uninstall;
  - never run an extensionless name from cmd or PowerShell.

### 5.5 Gotchas (all observed in this spike)

| Gotcha | Consequence | Where |
|---|---|---|
| `SetConsoleCtrlHandler(NULL, TRUE)` in a launcher | children inherit "ignore Ctrl+C" and never see it | §3.8 |
| No ctrl handler in the forwarder | Ctrl+C kills the forwarder, the CLI's exit code becomes 0xC000013A, and the job kills the CLI | §3.8 |
| Forwarder without a console calls `CreateProcess` with flags 0 | the CLI gets a new **visible console window** and its output is lost | §3.9 |
| `DETACHED_PROCESS` without `STARTF_USESTDHANDLES` | the CLI gets no std handles; output lost | §3.9 |
| CopyFile into WindowsApps | Mark-of-the-Web is copied along (harmless for CreateProcess, but avoidable) | §3.14 |
| Overwriting an in-use forwarder | sharing violation; rename it away first | §3.12 |
| Hard link to the CLI | `GetModuleFileNameW` points to WindowsApps; installer updates leave the old CLI behind | §3.12 |
| `.cmd` with `%*` | `&` in an argument runs a second command; pwsh legacy quoting; Y/N prompt on Ctrl+C | §3.2, §3.8 |
| Extensionless launcher alone in a PATH dir | PowerShell resolves it as an Application and would try to open it as a document | §3.7 |
| Existing App Execution Alias name | the file cannot be opened (1920); never overwrite a reparse point | §3.16 |
| `RRF_RT_REG_EXPAND_SZ` without `RRF_NOEXPAND` | `ERROR_UNSUPPORTED_TYPE` (1630); use `RRF_RT_REG_SZ`, which also reads expanded REG_EXPAND_SZ | `s6-regflags.ps1` |
| Open Git Bash after an uninstall or a `--dir` move | stale hash ("No such file or directory") until `hash -r` | §3.6 |

## 6. Open risks

- **Windows Defender untested.** Defender was in passive or disabled mode on this machine, so its real-time scan and first-launch cost for unsigned binaries in WindowsApps were not measured. Mitigations:
  - sign the forwarder;
  - have install-cli run the self-test launch;
  - re-measure on a Defender-only machine as part of W7, and on a machine with Smart App Control on (SAC would block unsigned binaries outright).
- **EDR and SOC perception.** Writing executables into WindowsApps is a known PATH-interception technique (MITRE ATT&CK T1574.007). CrowdStrike neither blocked nor quarantined anything here, but alerts raised on the SOC side cannot be seen from the endpoint. Mitigations:
  - signed, stable, version-stamped files with a clear product name;
  - only on explicit user action (`install-cli` or the Settings button);
  - document the `--dir` alternative.
- **Durability of WindowsApps.** It is a user-writable folder that the AppX deployment service manages for aliases. The spike could not reboot or re-register packages, so it is unproven that foreign files survive every kind of servicing. Mitigation: the app checks at start (§5.2) and offers a repair.
- **PATH may not contain WindowsApps.** Users, profile-repair tools and GPO can remove WindowsApps from the user PATH. install-cli detects this and falls back to the documented manual step. Directories earlier on PATH can also shadow the forwarders; install-cli warns.
- **Timing under load only.** The overhead numbers were taken at 100 % CPU. The structural result ("one extra process creation") is robust, but the idle-machine latency is unmeasured.
- **ARM64 untested.** Built but not executed. x64 forwarders under emulation pay emulator start-up costs.
- **Multiple channels.** A single `InstallDir` value means the last `install-cli` wins when two channels (e.g. stable and dev) are installed side by side. If needed, use a per-channel value or per-channel forwarder names (W7 decision).
- **Collision with packaged aliases.** If wmux ships as MSIX with `cmux.exe`/`wmux.exe` execution aliases, install-cli must detect the alias and step aside (it already refuses reparse points).
- **cmd and extensionless files.** cmd was never made to execute an extensionless file (focus safety). The recommendation does not depend on it, because no extensionless file is installed in WindowsApps.

## 7. System changes made and undone

**WindowsApps** (all deleted; `s6-cleanup.ps1` verified 0 remaining `wmuxspikefwd*` after every run). Files created there:

- `wmuxspikefwd.exe`, `wmuxspikefwdc.com`, `wmuxspikefwdcmd.cmd`, `wmuxspikefwdhl.exe`, `wmuxspikefwdsh`
- `wmuxspikefwdlate.exe`
- `wmuxspikefwdp.com`, `wmuxspikefwdp.exe`, `wmuxspikefwdp.cmd`, `wmuxspikefwdp`
- `wmuxspikefwdu8.cmd`, `wmuxspikefwdoem.cmd`
- `wmuxspikefwdmotw.exe`
- `wmuxspikefwdhlu.exe` and `wmuxspikefwd.exe.old`
- `wmuxspikefwdnew1..8.exe`

**Registry** (deleted):
- `HKCU\Software\wmuxspikefwd` (value `InstallDir`)
- `HKCU\Software\wmuxspikefwd-regtest`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\wmuxspikefwdap.exe`

**Other.**
- A private desktop `WinSta0\wmuxspikefwd-desk`, closed after use.
- Scratch files only under the gitignored `zig-out\spike-s6\` of this worktree.
- No PATH, environment, scheduled task or other machine state was touched.
