# Spike S4: agent shims (PATH precedence, Ctrl+C through the wrapper, Claude Code teams over a tmux shim)

| | |
|---|---|
| Spike | S4 (ARCHITECTURE ADR-14.7), branch `wp/W0-D-S4-agent-shims` |
| Consumers | W3-2 (wrappers, ADR-10.6), W3-6 (tmux compat + team launchers, ADR-10.8); side findings for W1-3 (terminal env/jobs), W1-2/S6 (CLI layout), W0-B (e2e harness) |
| Date | 2026-10-15 |
| Decision | **Adopt with changes** (details in "Decision") |
| Prototype | `docs/arch/spikes/proto/S4/` (Zig 0.15.2 programs + PowerShell drivers + raw logs in `results/`) |

## Question

1. If a directory containing `claude.exe` is **prepended** to PATH, does it win over an npm-installed `claude.cmd` / `claude.ps1` / `claude` (sh) or a native `claude.exe` later in PATH, in cmd.exe, PowerShell 7, Windows PowerShell 5.1, Git Bash, and when another program spawns `claude` through `CreateProcess`, `cmd /c` or .NET?
2. Does Ctrl+C work through a wrapper exe that runs the real agent in the same console (console control events, process groups, kill-on-close job, console close), and are exit codes propagated?
3. Can Claude Code's agent-teams split-pane mode use a `tmux` binary on native Windows, and which tmux subcommands/flags does it invoke (what a `tmux.exe` compat shim must emulate)?
4. Is Claude Code installed on this machine, and which version?

## Setup

**Machine.** Windows 11 Enterprise 10.0.26200 (UBR 9448), cmd.exe / conhost.exe / where.exe 10.0.26100.1, PowerShell 7.6.6 (.NET 10.0.12), Windows PowerShell 5.1.26100.9444, Git for Windows 2.53.0.windows.2 (GNU bash 5.2.37(1)-release x86_64-pc-msys) at `C:\Program Files\Git`, Zig 0.15.2. The machine was heavily loaded by parallel builds of other agents during the whole spike (a trivial process start+exit took 0.3-1.6 s), which matters for the timing numbers only.

**Installed Claude Code.** `where.exe claude` -> `%USERPROFILE%\.local\bin\claude.exe` (native installer; 270,863,520 bytes; FileVersion 2.1.300.0, ProductName "Claude Code", CompanyName "Anthropic PBC"); `claude --version` -> `2.1.300 (Claude Code)`. The directory also holds `claude.exe.old.<timestamp>.<pid>` files left by the self-updater (rename-then-replace). No npm install, no `node`, no `bun`, no `tmux` on this machine. Nothing else from Claude Code was executed.

**Prototype programs** (Zig, `zig build-exe -target x86_64-windows-gnu -O ReleaseSafe`, Win32 externs in `w32.zig`):

| File | Role |
|---|---|
| `ident.zig` | dummy agent: prints `GetModuleFileNameW`, raw `GetCommandLineW`, parsed argv, cwd, selected env; exit code from `S4_EXIT`. Hardlinked/copied as `claude.exe`, `node.exe`, `tmux.exe`. |
| `child.zig` | dummy "real agent" for console tests: `sleep` (default Ctrl+C), `handler` (exits 42 on CTRL_C/BREAK), `handler-continue` (swallows, exits 9 later), `raw` (console raw mode like a TUI; 0x03 key -> 43), `exit N`, `grandchild`, `daemon` (spawns a `DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP` child, i.e. libuv's "detached", then exits). |
| `wrapper.zig` | the ADR-10.6 wrapper prototype, hardlinked as `claude.exe`: resolution on PATH minus itself, npm cmd-shim bypass, BatBadBut-safe cmd.exe fallback, `.ps1` via pwsh, std-handle duplication + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, job via `PROC_THREAD_ATTRIBUTE_JOB_LIST`, console ctrl handling, exit-code propagation. Spike knobs `S4_WRAP_*` select the variants compared below. |
| `conpty_harness.zig` | runs a command line in a fresh **pseudoconsole** with the same `STARTUPINFOEX` recipe as `src/Command.zig`, writes 0x03 (what the terminal sends for Ctrl+C) or text on a timeline armed by output markers, optional outer "tab job" (`BREAKAWAY_OK` only, ADR-3.9) in the same attribute list as the pseudoconsole, `CREATE_NEW_PROCESS_GROUP`, `AttachConsole`+`GenerateConsoleCtrlEvent`, `ClosePseudoConsole`, `TerminateProcess(root)`; reports exit codes, survival and job membership; foreground sampler built in. |
| `spawner.zig` | `CreateProcessW(NULL, "<cmdline>")` (raw API search) and `SearchPathW`. |
| `setup-layout.ps1`, `common.ps1`, `run-*.ps1` | layout builder, hidden-process runner with a controlled PATH, drivers for each result section. |

**Layout** (temp root, deleted at the end): `shims\agents\claude.exe` (hardlink of ident), `shims\wrap\claude.exe` (hardlink of wrapper), `native\claude.exe` (stands in for `~\.local\bin\claude.exe`), `npm\{claude.cmd, claude.ps1, claude, node.exe, node_modules\@anthropic-ai\claude-code\cli.js}` (structure of npm's generated shims, `node.exe` = ident), `samedir\claude.{exe,cmd,ps1}` + `claude`, `cwdtest\claude.cmd`, `spawnerdir\{spawner.exe, claude.exe}`, `teams\tmux.exe`, `tmuxlater\{tmux.cmd, tmux}`.

**Method and safety.** Every process was started by `ProcessStartInfo{UseShellExecute=false, CreateNoWindow=true}` with an explicit PATH of `<test dirs>;C:\Windows\system32;C:\Windows;...\Wbem;...\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd` (the real `~\.local\bin` was never on it); console tests ran inside headless pseudoconsoles. A foreground sampler (`GetForegroundWindow` + `GetWindowThreadProcessId` every 100 ms, PowerShell job; plus one inside the harness) ran during all drivers: 0 violations (the foreground window never changed). The drivers remove two variables the parent Claude Code session exports into its children, `NoDefaultCurrentDirectoryInExePath=1` and `CLAUDECODE=1`, so launchers behave as in a plain user shell (scenario H re-adds the first one on purpose). No registry, PATH, scheduled-task or profile change was made.

Rerun: build the five programs into `<root>\bin`, then `setup-layout.ps1 -Root <root>` and `run-precedence.ps1`, `run-wrapper.ps1`, `run-ctrlc.ps1`, `run-shells-ctrlc.ps1`, `run-teams.ps1`, `run-misc.ps1` with `-Root <root>`.

## Results

### R1. PATH precedence across launchers (`run-precedence.ps1`, `results/precedence.txt`)

"shims" = the prepended directory holding only `claude.exe`. Every cell is the file that actually ran.

| Scenario | cmd /c | pwsh 7 | PS 5.1 | Git Bash -c / -lc | CreateProcess | .NET Process.Start | first `where.exe` hit |
|---|---|---|---|---|---|---|---|
| A shims; npm (cmd+ps1+sh) | shims\claude.exe | shims | shims | shims / shims | shims | shims | shims\claude.exe |
| B shims; native claude.exe | shims | shims | shims | shims / shims | shims | shims | shims\claude.exe |
| C control: npm; shims | npm\claude.cmd | npm\claude.ps1 | npm\claude.ps1 | npm\claude (sh) | shims | shims | npm\claude (extensionless) |
| D = A with `PATHEXT=.CMD;.BAT;.PS1;.EXE;.COM` | shims | shims | shims | shims | shims | shims | shims\claude.exe |
| E one dir with claude.exe + .cmd + .ps1 + sh | claude.exe | **claude.ps1** | **claude.ps1** | claude (sh) | claude.exe | claude.exe | claude (sh) |
| F = A, cwd contains claude.cmd | **cwd\claude.cmd** | shims | shims | shims | shims | shims | cwd\claude.cmd |
| G = A, cwd contains claude.exe | **cwd\claude.exe** | shims | shims | shims | **cwd\claude.exe** | **cwd\claude.exe** | cwd\claude.exe |
| H = G + `NoDefaultCurrentDirectoryInExePath=1` | shims | shims | shims | shims | shims | shims | cwd\claude.exe |
| I npm only | npm\claude.cmd | npm\claude.ps1 | npm\claude.ps1 | npm\claude (sh) | error 2 | error "cannot find the file" | npm\claude |
| J = A, spawner.exe sits next to its own claude.exe | | | | | **spawnerdir\claude.exe** | | |
| K = A in `bash -i` whose rc prepends `native` | | | | **native\claude.exe** | | | |

Three cells (A and F `bash -lc`, C PS 5.1) hit the driver's 30 s timeout once because of machine load (a Git Bash login shell took up to 36 s); rerun with a 120 s timeout they gave the values shown.

Facts behind the table:
- All launchers search **directory by directory**; the extension order (PATHEXT, `.ps1`) only breaks ties inside one directory. So a prepended directory that holds only `claude.exe` wins everywhere (A, B, D).
- Inside one directory PowerShell prefers `.ps1` over `.exe` (`Get-Command claude -All` in E: `claude.ps1 > claude.exe > claude.cmd > claude`). Irrelevant as long as the shim directory contains only `.exe` files.
- `CreateProcess` and .NET only consider `.exe`: they never run npm's shims (C, I) and pick the shim even when npm is earlier.
- The current directory beats PATH for cmd (`.cmd`/`.exe` in cwd) and for `CreateProcess`/.NET (`.exe` in cwd) unless `NoDefaultCurrentDirectoryInExePath` is set (F, G, H). PowerShell and bash never search cwd. The environment this spike's tools inherited from the Claude Code session carried `NoDefaultCurrentDirectoryInExePath=1` (it is not set in the user or machine environment), so processes started by Claude Code do not search cwd.
- `CreateProcess(NULL, "claude ...")` searches the calling program's own directory first (J).
- `where.exe` also lists **extensionless** files and orders hits inside a directory by directory enumeration (alphabetical), not PATHEXT: E listed `claude > claude.cmd > claude.exe`.
- Git Bash: `C:\Program Files\Git\bin\bash.exe` prepends `/mingw64/bin:/usr/bin:$HOME/bin` even for non-login shells (`-lc` adds `/usr/local/bin:/bin` too) before the inherited Windows PATH; MSYS resolves `claude` to `claude.exe` (`type -a claude` -> `shims/agents/claude`, `npm/claude`). A user rc that prepends a directory containing `claude.exe` beats the shim (K); the same holds for a PowerShell profile that prepends to `$env:PATH`.
- argv[0] seen by the program: cmd passes the typed word (`claude  --probe`), pwsh the full quoted path, bash the full path. `GetModuleFileNameW` of a hardlink returns the link's own path (`...\shims\agents\claude.exe`), so dispatch by module name works with hardlinks.

### R2. Wrapper end to end (`run-wrapper.ps1`, `run-misc.ps1`, `results/wrapper.txt`)

| Test | Result |
|---|---|
| typed `claude a "b c"` in cmd, pwsh 7, PS 5.1, Git Bash, real = native exe | argv `a`, `b c` arrived unchanged; child exit 42 seen by all four shells as 42 |
| same, real = npm `claude.cmd` (bypass: wrapper launches `npm\node.exe "<...>\cli.js" <tail>`) | identical argv and exit code in all four shells |
| argv fidelity, 14 hostile args (`with space`, `quote"inside`, `amp&echo INJECTED`, `pct%PATH%pct`, `caret^x`, `bang!x`, `paren(x)`, `trail\`, `back\\"slash`, empty, `pipe|x`, `lt<x>gt`, `uni-é`) | native exe (verbatim command-line tail): 14/14; npm bypass: 14/14; cmd.exe with safe quoting: 14/14; `.ps1` via `pwsh -File`: 14/14; **cmd.exe with the raw tail: 3/14**, cmd parsed `&`, `|`, `<` as operators (the run ended with cmd trying to open a redirection file `x`: "The system cannot find the file specified.") |
| explicit real path = the shim itself | loop stopped only by the depth guard (exit 126) |
| PATH holds the shim dir twice, once by its 8.3 alias (`C:\Users\<8.3 name>\...\WMUX-S~2\...`) | string comparison of directories: loop (depth guard); file-identity comparison: correct (1 hop) |
| a second wrapper **copy** later on PATH (stale build) | ping-pong wrapper -> copy -> wrapper; file identity cannot help (different files); stopped by the depth guard |
| stdin from a pipe / stdout to a pipe through the wrapper | OK with duplicated inheritable std handles + handle list, and with plain inheritance |
| exit codes 0, 1, 42, 255, 256, -1, 0xC000013A | wrapper exit code identical (`0xFFFFFFFF`, `0xC000013A` included); cmd and pwsh print the same signed value; bash shows its own 8-bit/NTSTATUS mapping (256 -> 0, 0xFFFFFFFF -> 127, 0xC000013A -> 130), same as without a wrapper |
| non-ASCII directory and args (`nativé dir ü\claude.exe`, `ünï`) | resolved and passed correctly |
| resolution cost on this machine's real PATH (15 directories before the hit, 5 extensions each, identity checks) | 3.3-17.6 ms, median 6 ms (first run 60 ms, cold cache) |
| launch overhead (median of 20 interleaved runs) | direct 837 ms, wrapper 1098 ms (ReleaseSafe, 576 KB) / 1354 ms (ReleaseSmall, 54 KB): one extra process creation, inflated by the load; must be re-measured on an idle machine |

Side finding: after rebuilding `wrapper.exe`, the hardlink `shims\wrap\claude.exe` silently kept the **old** binary (the linker wrote a new file, so the link pointed at the previous file data).

### R3. Ctrl+C, kill and console close through the wrapper, in a real ConPTY (`run-ctrlc.ps1`, `results/ctrlc*.txt`)

0x03 written into the pseudoconsole input = what a terminal sends for Ctrl+C. Every pseudoconsole emitted `CSI ?9001h` at startup (inbox conhost 10.0.26100), so in practice wmux sends keys in win32-input-mode; rows W1-W3 show that this encoding behaves the same. Timings are relative to the child announcing itself.

| # | Setup | Result |
|---|---|---|
| T1 | no wrapper, child with handler | child gets CTRL_C_EVENT, exits 42 |
| T2 | wrapper with a **handler routine** returning TRUE | both get CTRL_C_EVENT; wrapper survives and exits 42 (child's code) |
| T3 | wrapper calls `SetConsoleCtrlHandler(NULL, TRUE)` **before** `CreateProcess` (ADR-10.6 step 5 as written) | **child never receives Ctrl+C** (the ignore flag is inherited); child ran to its 8 s timeout (exit 7) |
| T4 | `SetConsoleCtrlHandler(NULL, TRUE)` **after** `CreateProcess` | child gets it (42); works but order-dependent |
| T5a | wrapper without ctrl handling, child swallows Ctrl+C and keeps running | wrapper dies (0xC000013A), the kill-on-close job then kills the child (exit 0) although it wanted to continue |
| T5b | same with the handler routine | child keeps running, exits 9 later; wrapper exits 9 |
| T6 | child with default handling | child dies 0xC000013A; wrapper exits 0xC000013A |
| T7 | child in console raw mode (how a TUI such as Claude Code reads keys) | Ctrl+C arrives as a 0x03 key; **no console event at all** (wrapper handler not called); child exits 43 |
| T8a | `TerminateProcess(wrapper)`, job `KILL_ON_JOB_CLOSE` | child and grandchild killed |
| T8b | same, job `KILL_ON_JOB_CLOSE \| SILENT_BREAKAWAY_OK` | child killed, grandchild survives (exec-like) |
| T8c | same, no job | child and grandchild orphaned and alive |
| T9 | `ClosePseudoConsole` while both run (child exits 44 on CTRL_CLOSE_EVENT) | `ClosePseudoConsole` returned at once; both got CTRL_CLOSE_EVENT; the wrapper's close handler waited for the child and exited 44, ~0.1 s after the close |
| T10a | root inside an outer tab job (`BREAKAWAY_OK` only, attribute list = pseudoconsole + job list) + wrapper job via `PROC_THREAD_ATTRIBUTE_JOB_LIST` | nested job accepted; wrapper, child, grandchild all `IsProcessInJob(outer)=1`; outer `JobObjectBasicProcessIdList` lists all three |
| T10b | same with `SILENT_BREAKAWAY_OK` on the wrapper job | grandchild still in the outer tab job (silent breakaway leaves only the inner job) |
| T10c | same with `CREATE_SUSPENDED` + `AssignProcessToJobObject` | also works |
| T11a | wrapper -> `cmd.exe /c claude.cmd` -> child, Ctrl+C | child dies; cmd shows `^CTerminate batch job (Y/N)?` and **blocks** until answered; after "n" the batch went on and the wrapper exited 0, losing 0xC000013A |
| T11b | same, child swallows Ctrl+C and exits normally | cmd **still** asks `Terminate batch job (Y/N)?` (cmd received the event itself) |
| T11c | same, child in raw mode | no prompt (no event) |
| T12 | wrapper bypasses the npm shim and starts `node.exe` directly | no prompt; exit 0xC000013A propagated |
| T13a | agent starts a daemon with libuv "detached" flags, then exits normally; wrapper job `KILL_ON_JOB_CLOSE` | **daemon killed** when the wrapper exits (job handle closed) |
| T13b | same, `KILL_ON_JOB_CLOSE \| SILENT_BREAKAWAY_OK` | daemon survives |
| T13c | same without wrapper (control) | daemon survives |
| W1 / W2 / W3 | Ctrl+C sent the way wmux sends it once ConPTY enabled win32-input-mode: `\e[17;29;0;1;8;1_\e[67;46;3;1;8;1_\e[67;46;0;0;8;1_\e[17;29;0;0;0;1_` (Ctrl down, C down with Uc=3, C up, Ctrl up; encoding of `Surface.sendWin32InputEvent`) | identical to 0x03: handler child 42, default child 0xC000013A, raw child gets the 0x03 key (43) |
| G1 | supervisor attached to the console: `GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)` | same as typed Ctrl+C (42) |
| G2a | root created with `CREATE_NEW_PROCESS_GROUP`; `CTRL_BREAK_EVENT` to that group | wrapper survives, child gets event 1, exits 42 |
| G2b | same group; `CTRL_C_EVENT` to that group | nothing delivered (child timed out) |
| G2c / G3 | root (wrapper, or the child itself) in a new process group; typed Ctrl+C | **nothing delivered**: `CREATE_NEW_PROCESS_GROUP` sets the inherited "ignore Ctrl+C" flag |

Harness note (W0-B): a supervisor that attaches to a console to generate events died with 0xC000013A on a group-0 CTRL_C_EVENT although it had registered a handler before `AttachConsole`; registering `SetConsoleCtrlHandler(NULL, TRUE)` + handler **after** `AttachConsole` fixed it.

### R4. The same chain typed into interactive shells in a ConPTY (`run-shells-ctrlc.ps1`, `results/shells-ctrlc.txt`)

`claude <mode>` (wrapper) and the agent typed directly (control), Ctrl+C 1.5 s after the agent started:

| Shell | handler | default | raw (TUI) |
|---|---|---|---|
| cmd, wrapper and direct | event 0, `%ERRORLEVEL%` 42 | killed, -1073741510 | 0x03 key, 43 |
| pwsh 7, wrapper and direct | event 0, `$LASTEXITCODE` 42 | killed, -1073741510 | 0x03 key, 43 |
| Git Bash, wrapper and direct | event 0, `$?` 130 | killed, 130 | 0x03 key, 43 |

The wrapper is transparent in all three shells (Git Bash reports 130 whenever SIGINT reached the foreground job, with or without the wrapper). Fixed-delay typing was unreliable on the loaded machine (PSReadLine and bash readline took seconds to hand the line over, so a 0x03 sent too early became a key at the prompt); the final runs type at the prompt marker and send Ctrl+C relative to the agent's own output.

### R5. Teammate launch line, bash discovery, tmux lookup (`run-teams.ps1`, `results/teams.txt`)

Teammate line shaped like the one Claude Code sends on Windows (public issue anthropics/claude-code#42848): `cd '<root>\proj dir with spaces' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 S4_MARK=teammate '<root>\native\claude.exe' --agent-id alice@team-x --agent-name alice --team-name team-x --agent-color blue --parent-session-id <uuid>`:

| Runner | Result |
|---|---|
| Git Bash, structured argv `[bash.exe, "-c", line]` | OK: cwd with spaces, env vars and all argv correct (4.3 s on the loaded machine) |
| Git Bash `-lc` | OK, but 14.4 s here (36 s in another run): the login profile is slow |
| `cmd /c` | `The filename, directory name, or volume label syntax is incorrect.` (the error reported in #42848) |
| `pwsh -c` | `env: The term 'env' is not recognized ...` |

Bash discovery on this machine: `where.exe bash` -> `C:\Windows\System32\bash.exe` ("Microsoft Bash Launcher", i.e. **WSL**) then `%LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe`; Git Bash is not on PATH. `HKLM\SOFTWARE\GitForWindows\InstallPath` = `C:\Program Files\Git` (has `bin\bash.exe`); `git.exe` on PATH is `C:\Program Files\Git\cmd\git.exe` (-> `..\bin\bash.exe` exists). `CLAUDE_CODE_GIT_BASH_PATH` and `SHELL` were unset.

tmux lookup with `teams\tmux.exe` first: cmd, pwsh, bash, `CreateProcess` and "spawn the first `where.exe` hit" all ran `tmux.exe`. With a directory holding `tmux` (sh) and `tmux.cmd` earlier on PATH: cmd/pwsh ran `tmux.cmd`, bash the sh script, `CreateProcess` still `tmux.exe`, and the first `where.exe` hit was the extensionless `tmux`, which `CreateProcess` rejects with **error 193** (`ERROR_BAD_EXE_FORMAT`).

argv a tmux shim receives (CreateProcess, no shell): a lone command string stays one argument (`<display-message -p #{pane_id}>`); global flags precede the verb (`-L claude-swarm has-session -t x`, `-S C:\tmp\sock split-window ... -- cat`).

MSYS argument conversion when bash starts a native exe: `/c/Users` -> `C:/Users`, `--settings=/tmp/x.json` -> `--settings=C:/Users/<8.3 name>/AppData/Local/Temp/x.json`, `/etc` -> `C:/Program Files/Git/etc`; `%1`, `#{pane_id}`, `C:/already/win` untouched; `MSYS2_ARG_CONV_EXCL=*` disables it.

### R6. Claude Code agent teams on native Windows (research; no agent was run)

Sources: Claude Code docs "Orchestrate teams of Claude Code sessions" (code.claude.com/docs/en/agent-teams), Claude Code CHANGELOG.md (raw.githubusercontent.com/anthropics/claude-code/main), issues anthropics/claude-code #26244, #34150, #42848, psmux docs/claude-code.md and psmux#173, gonnector/claude-psmux-team README, stanislc/zellij-claude-teams PR #8, manaflow-ai/cmux issue #8129, and interface facts (command/flag/env names only) from the cmux clone (`CLI/cmux.swift`, `CLI/CMUXCLI+TmuxCompatSupport.swift`, `CLI/CMUXCLI+ExecutableResolution.swift`, `cmuxTests/CLITmuxCompatRemoteSplitTests.swift`, `CHANGELOG.md`).

- **Enablement**: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`; display mode from `teammateMode` / hidden flag `--teammate-mode` (`in-process` default, `auto` = split panes when already inside tmux or iTerm2+it2, `tmux` = force split panes, `iterm2`). Teammates need an interactive session (`-p` never spawns them). Docs: split panes need tmux or iTerm2 and are "not supported in VS Code's integrated terminal, Windows Terminal, or Ghostty" (i.e. without tmux).
- **Detection**: "inside tmux" = `TMUX` non-empty (#34150). Launchers that fake tmux set `TMUX` + `TMUX_PANE` (cmux: `TMUX=/tmp/<prefix>/<workspace>,<window>,<pane>`, `TMUX_PANE=%<n>`, `TERM=screen-256color`, unset `TERM_PROGRAM`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, `--teammate-mode auto` prepended unless given).
- **Native Windows status**: Feb 2026, the Bun single-file build reported `process.stdout.isTTY` falsy on Windows, which forced in-process mode even with `teammateMode: "tmux"` (#26244, closed "not planned"). April 2026 reports show the tmux backend **driving a tmux-compatible multiplexer on native Windows** (psmux) with Claude Code 2.1.90-2.1.92 (#42848, psmux#173): teammates were launched, and failed only because the launch line was handed to cmd/PowerShell. Agents spawned with `isolation: "worktree"` stay in-process on Windows (psmux docs). **Not verified on the installed 2.1.300** (needs an authenticated interactive session; out of bounds for this spike).
- **Executable lookup**: the changelog says Claude Code on Windows uses `where.exe` lookups cached per process. Third-party shims report that Claude Code's spawn finds only `.exe` ("Node.js spawn only finds .exe files on Windows, so a compiled shim is required", gonnector) and that a non-exe tmux went through cmd.exe and got `%1` escaped as `"^%1"` (#26244). Together with R5: the shim must be a PE `tmux.exe`, first on PATH, with no extensionless `tmux` before or beside it, and PATH must be final before claude starts (lookup cache).
- **tmux surface used by Claude Code** (union over versions; the shim must accept all of it):
  - global flags before the verb: `-V` (expects `tmux <version>`; shims answer `tmux 3.4`), `-L <name>`, `-S <socket>` (2.1.268); accept `-f <file>` too (tmux syntax); a whole command in **one argument** (2.1.272: `tmux "display-message -p #{pane_id}"`; an older cmux shim failed this with Claude's error "Could not determine current tmux pane/window").
  - teammate spawn, 2.1.183+ (cmux tests) and 2.1.210/2.1.260/2.1.268 (cmux#8129, zellij PR #8): `split-window -d -t <leader-pane> -h -l 70% -P -F '#{pane_id}' -- cat` (placeholder pane), `select-pane -t %N -T <agent name>`, `set-option -p -t %N remain-on-exit failed`, `respawn-pane -k -t %N -- '<teammate line>'` (every step must exit 0 and the pane must keep its id; a silently dead respawned command leaves the lead waiting forever, cmux#8129).
  - also seen: `display-message -p [-t] [-F] <format>` (`#{pane_id}`, `#{session_name}`, `#{window_index}`, ...), `list-panes [-t] -F <format>` (error text "Could not determine pane count"), `list-windows`, `has-session -t`, `new-session -d -s <name> [-P -F ...] -- cat` and `new-window ... -P -F ...` (when not already inside tmux, with `-L`), `select-layout` (main-vertical, tiled), `resize-pane`, `show-options -p -t %N`, `kill-pane -t %N`, `kill-session -t`, older protocol `split-window -h|-v -c <dir> -P -F` + `send-keys -t %N '<cmd>' Enter`.
  - teammate line: POSIX `cd '<cwd>' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 [provider env] '<absolute path of the running claude.exe>' --agent-id <name>@<team> --agent-name <name> --team-name <team> --agent-color <color> --parent-session-id <uuid> [--model, --permission-mode, --effort, --setting-sources ...]`. It names claude by **absolute path**, so the PATH wrapper is not on the teammate path.
- **Side effects of a faked `TMUX`** (changelog): Claude Code adapts to tmux: synchronized output only for tmux versions it knows support it, OSC notifications through tmux passthrough when `allow-passthrough` is on, clipboard through tmux buffers.

## Decision

**Adopt with changes.** A `claude.exe` in a directory prepended to PATH reliably wins over npm `claude.cmd`/`claude.ps1`/`claude` and over a native `claude.exe` later in PATH, in cmd, PowerShell 7, Windows PowerShell 5.1, Git Bash (`-c`, `-lc`), `CreateProcess`, .NET `Process.Start` and `where.exe`-based resolvers (R1 A/B/D). A same-console wrapper is transparent for Ctrl+C, console close and exit codes **if** it is built as below (R3, R4). The tmux route for Claude teams is technically sound on native Windows (a PE `tmux.exe` is found; the teammate line runs correctly under Git Bash `-c`), but Claude Code 2.1.300's willingness to use it is unverified, so W3-6 keeps the WSL fallback and must pass the verification below. Changes against ADR-10.6/10.8 as written:

1. **Ctrl+C**: do not call `SetConsoleCtrlHandler(NULL, TRUE)` before creating the child (T3: the child inherits "ignore Ctrl+C"). Install a handler routine first thing in `main`: TRUE for CTRL_C/CTRL_BREAK (abandon the launch with 0xC000013A if the child does not exist yet); for CLOSE/LOGOFF/SHUTDOWN wait up to ~4.5 s for the child, then exit with its code (T9).
2. **Job**: `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`, assigned atomically with `PROC_THREAD_ATTRIBUTE_JOB_LIST`. Plain kill-on-close kills every background daemon/MCP server the agent starts when the agent exits (T13a) or the wrapper dies (T8a); silent breakaway binds only the agent process, which is exactly `exec` (T8b, T13b), and descendants stay in the wmux tab job (T10b).
3. **npm `.cmd` targets**: launch the program behind npm's cmd-shim directly (`node.exe <script> <tail>`, or the `.exe` it names) instead of `cmd.exe` (T12, R2). Fallback only for unrecognized batch files: `cmd.exe /d /e:ON /v:OFF /s /c ""<bat>" <args>"` with per-argument quoting (14/14), accepting the batch prompt and exit-code loss of T11. Never pass the raw tail through cmd (R2: 3/14 and operator injection).
4. **`.exe` targets**: pass the original command-line tail verbatim (UCRT argv[0] rule), not re-quoted argv.
5. **Self/loop detection**: skip PATH hits that are the same file as the wrapper (volume serial + file index), skip every directory that carries a wmux shim sentinel file, and keep a depth variable as backstop (R2: string compare fails on 8.3 aliases; identity fails on stale copies).
6. **Dispatch** by `GetModuleFileNameW` basename, never argv[0] (R1).
7. **Teams**: `tmux.exe` (PE) alone in `STATE\shims\<build-id>\teams`, prepended before claude starts; teammate lines run as `[<Git bash.exe>, "-c", <line>]` (not `-lc`); bash comes from `CLAUDE_CODE_GIT_BASH_PATH` -> `HKCU`/`HKLM\SOFTWARE\GitForWindows\InstallPath` + `\bin\bash.exe` -> `<git.exe dir>\..\bin\bash.exe` (-> `SHELL` only if it converts to an existing Git/MSYS `bash.exe`), never from `where bash` (it returned the WSL launcher here).

Fallbacks stay as listed in ADR-14.7, scoped: shell-integration functions only for shells whose rc/profile reorders PATH (R1 K), WSL for teams if the native verification fails.

## Guidance for the consuming WPs

### W3-2 wrapper (`src/wmux_cli/wrappers/`)

API sequence (all in `wrapper.zig`, which ran every test above):

1. `SetConsoleCtrlHandler(ctrlHandler, TRUE)` before anything else.
2. Pass-through checks of ADR-10.6 (outside wmux, disabled, ping timeout, non-session subcommand, depth >= 1).
3. Resolve the real binary: `automation.claudeBinaryPath`, else PATH directory by directory (relative entries via `GetFullPathNameW`, quotes stripped), extensions `.exe .com .cmd .bat .ps1`; skip directories that contain the shim sentinel (e.g. a zero-byte `.wmux-shims` written by the app into every `shims\<build-id>\{agents,teams}` directory; one `GetFileAttributesW` per PATH entry), skip candidates whose file identity (`GetFileInformationByHandle`: volume serial + file index) equals the wrapper's. Re-resolve on every launch (the native updater replaces `claude.exe` by rename; never cache).
4. Build the command line: `.exe` -> `"<real>" <tail>`; npm `.cmd` -> `"<node.exe>" "<script>" <tail>`; other `.cmd/.bat` -> quoted cmd.exe line; `.ps1` -> `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<real>" <tail>`. Then the ADR's injections (`--session-id`, `--settings <file>`; inject as separate quoted tokens after the program).
5. Set exported variables with `SetEnvironmentVariableW` (inherit the block: `lpEnvironment = NULL`), including the depth marker.
6. `CreateJobObjectW` + `SetInformationJobObject(JobObjectExtendedLimitInformation, KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK)`.
7. Duplicate each non-null std handle as inheritable, `STARTF_USESTDHANDLES`, attribute list with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (the duplicates) and `PROC_THREAD_ATTRIBUTE_JOB_LIST` (the job), `CreateProcessW(lpApplicationName = absolute path, ..., bInheritHandles = TRUE, CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT)`. Close the duplicates.
8. `WaitForSingleObject(child, INFINITE)`, `GetExitCodeProcess`, `ExitProcess(code)`.

```zig
fn ctrlHandler(ctrl: w.DWORD) callconv(.winapi) w.BOOL {
    switch (ctrl) {
        w.CTRL_C_EVENT, w.CTRL_BREAK_EVENT => {
            if (g_child == null) g_interrupted.store(true, .release); // launch is abandoned
            return w.TRUE; // the console delivers the event to the child too; it decides
        },
        else => { // CLOSE / LOGOFF / SHUTDOWN: let the child use its grace period first
            if (g_child) |h| {
                _ = w.WaitForSingleObject(h, 4500);
                var code: w.DWORD = 0xC000013A;
                _ = w.GetExitCodeProcess(h, &code);
                w.ExitProcess(code);
            }
            return w.FALSE;
        },
    }
}
```

```zig
var info: w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
info.BasicLimitInformation.LimitFlags =
    w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | w.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
_ = w.SetInformationJobObject(job, w.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info)));
// attribute list: JOB_LIST = &job, HANDLE_LIST = duplicated std handles (distinct values, no dedup needed)
```

```zig
/// argv[0] ends at the first unquoted space/tab; quotes toggle (UCRT rule). The rest is passed verbatim.
fn skipArgv0(cl: []const u16) []const u16 {
    var i: usize = 0;
    var inq = false;
    while (i < cl.len) : (i += 1) {
        if (cl[i] == '"') inq = !inq else if (!inq and (cl[i] == ' ' or cl[i] == '\t')) break;
    }
    while (i < cl.len and (cl[i] == ' ' or cl[i] == '\t')) i += 1;
    return cl[i..];
}
```

Batch-file argument rule (for `wmux_proto/win_argv.zig`, fallback path only): always wrap in quotes; `"` -> `""`; backslashes before a quote or the closing quote doubled; `%` -> `%%cd:~,%`; reject CR, LF, NUL; run as `cmd.exe /d /e:ON /v:OFF /s /c ""<bat>" <args>"`. npm cmd-shim recognition: the last `"%dp0%\<relative target>"` followed by `%*` in the file; program = `<shim dir>\node.exe` if present, else `node.exe` from PATH minus the shim dir; targets ending in `.exe` run directly.

Gotchas: hardlinks keep the old binary when the source is replaced (key the build-id directory on the binary, including dev builds, and recreate links on mismatch); a running hardlinked wrapper keeps that file's data in use; a wrapper started with `CREATE_NEW_PROCESS_GROUP` cuts typed Ctrl+C for the agent (G2c); agents running with a processed-mode console (`claude -p`, subcommands, startup before the TUI enables raw mode) are the T2/T5b/T6 cases, the interactive TUI is T7. Acceptance tests for W3-2 can reuse `conpty_harness` scenarios T2, T5b, T6, T7, T8b, T9, T10b, T12, T13b, W1-W3 and the argv list of R2. Re-measure overhead on an idle machine; target p50 < 50 ms extra.

### W3-6 tmux shim and team launchers (`src/wmux_cli/tmux/`)

- Ship only `tmux.exe` (hardlink of `cmux.exe`) in the teams directory; no extensionless `tmux`, no `tmux.cmd`. The launcher prepends it, sets `TMUX`/`TMUX_PANE`/`TERM`/marker before starting claude (lookup cache), and starts claude through the wrapper.
- Parser: global flags `-L <n>`, `-S <path>`, `-f <file>`, `-V`, `-v` before the verb; a lone argument containing whitespace is a whole command string (split shell-style, verb lowercased, flags keep case); `-P -F <format>` on `split-window`, `new-window`, `new-session`; `%N` targets. Claude Code passes `-S <socket>` presumably derived from `TMUX`'s first field, so keep that field a stable path the shim can map back to the workspace (ADR-10.8's `<STATE>\tmux\<workspace-uuid>` works; Windows backslashes reach the shim unchanged because no shell is involved).
- `split-window ... -- cat` (and `new-session ... -- cat`): create the split with no process or an inert placeholder; do not run `cat`. `respawn-pane -k -t %N -- <line>`: replace the placeholder in the same surface (`%N` unchanged), run `[<git bash.exe>, "-c", <line>]` with the teams environment re-supplied; exit 0 only if the command really started; exit non-zero otherwise. `remain-on-exit failed` -> keep the surface when the command fails. `select-pane -T` -> surface title. `show-options -g allow-passthrough` and similar queries should answer `off`; implement `set-buffer`/`load-buffer`/`show-buffer`.
- Teammate lines carry Windows paths in POSIX single quotes; do not convert them; set `MSYS2_ARG_CONV_EXCL` only if wmux itself passes POSIX-looking arguments through bash.
- Verification before W3-6 ships native teams (human-run, sandbox account with valid credentials, never by an agent): put a logging `tmux.exe` (records argv, cwd, selected env to a file and answers `-V` with `tmux 3.4`, `display-message -p #{pane_id}` with `%1`, `split-window ... -P -F ...` with `%2`, exits 0 otherwise) first on PATH inside a wmux terminal; run `claude --teammate-mode tmux` with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and `TMUX`/`TMUX_PANE` set; ask for two named teammates. Pass = log shows `split-window` + `respawn-pane` calls; fail (no split-window, teammates in the agent panel) = in-process gate still active on Windows -> keep WSL guidance and file the deviation. Also record whether the teammate line contains `--settings` (hooks for teammates, see risks).

### W1-3 terminal environment and jobs

- Prepending `STATE\shims\<build-id>\agents` is sufficient for cmd, pwsh, PS 5.1, Git Bash, `CreateProcess` and .NET (R1). Do not set `NoDefaultCurrentDirectoryInExePath` globally (it changes cmd semantics for users); document the cwd caveat instead.
- Confirmed: `PROC_THREAD_ATTRIBUTE_JOB_LIST` next to `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` in one attribute list works; a per-tab job with only `BREAKAWAY_OK` keeps all descendants, including those inside the wrapper's nested job (T10a/b), so job-based caller identification survives the wrapper.
- Never create the shell (or anything on the agent path) with `CREATE_NEW_PROCESS_GROUP` (G2c/G3).

### W1-2 / S6 CLI layout

`where.exe` returns extensionless files first within a directory (R1 E, R5), and Claude Code resolves tools through `where.exe`. The LF sh launchers `cmux`/`wmux` planned next to `cmux.exe`/`wmux.com` in `INSTALL\cli` would be the first hit for `where cmux` / `where wmux`; a resolver that spawns the first hit fails with error 193. Put the sh launchers in a separate directory placed after `INSTALL\cli` on PATH (bash finds `cmux.exe` by itself; only `wmux` and WSL need the sh form).

### W0-B e2e harness

A pseudoconsole plus writing 0x03 (or the win32-input-mode sequence wmux really sends) reproduces typed Ctrl+C exactly; arm actions on output markers instead of fixed delays (shell prompt handover took seconds under load); a supervisor that generates console events must set its ignore flag/handler after `AttachConsole`.

### ADR change requests (lead architect)

ADR-10.6 step 2 (sentinel + identity skip; npm shim bypass instead of cmd.exe as default) and step 5 (handler routine instead of `SetConsoleCtrlHandler(NULL, TRUE)`; job flags `KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK`); ADR-10.8 bash discovery order and `-c` instead of `-lc`; ADR-4.1 placement of the LF sh launchers; Appendix E D3 wording ("exec emulation binds only the agent process").

## Open risks

1. Claude Code 2.1.300 may still refuse split panes on native Windows (Bun TTY detection or explicit Windows gating); unverified here, verification procedure above, WSL fallback.
2. Teammates start the real `claude.exe` by absolute path, bypassing the wrapper: their hooks exist only if Claude Code forwards the lead's `--settings` to teammates (not established). Otherwise `respawn-pane` must inject the hook settings or route the line through the wrapper.
3. Faking `TMUX` changes the lead's terminal behaviour (synchronized output, notification passthrough, clipboard via tmux buffers); notifications in claude-teams sessions need an explicit check.
4. User rc files and PowerShell profiles that prepend PATH defeat the shim (R1 K); requires shell-integration assertion (function or re-prepend after rc), not yet designed for Git Bash/pwsh on Windows.
5. cwd precedence: a `claude.cmd`/`claude.exe` in the current directory wins in cmd, and `claude.exe` in cwd wins for `CreateProcess`/.NET (R1 F/G).
6. Node/libuv and Bun spawn rules were not exercised (neither is installed). libuv documents cwd then PATH, appending only `.com`/`.exe`; Claude Code's self-spawns use absolute paths, so precedence does not apply to them.
7. Overhead numbers were taken on a heavily loaded machine; AV/EDR reaction to hardlinked `claude.exe` copies under `%LOCALAPPDATA%` was not observed here but is environment-specific.
8. Claude Code caches `where.exe` results per process: PATH changes after start are invisible to it.

## Files

- `docs/arch/spikes/proto/S4/*.zig`: prototypes (build: `zig build-exe <file>.zig -target x86_64-windows-gnu -O ReleaseSafe`).
- `docs/arch/spikes/proto/S4/*.ps1`: layout and drivers.
- `docs/arch/spikes/proto/S4/results/*.txt`: raw logs of the final runs (temp root shown as `<R>`, user paths anonymized). `run-misc.ps1` output (resolution cost, non-ASCII paths, overhead) is quoted in R2 only.
- No wmux source was modified; no `.patch` is needed.
