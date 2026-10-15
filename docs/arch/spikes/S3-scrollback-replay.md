# Spike S3: scrollback replay at restore (terminal-side injection vs ConPTY)

Status: decided, 2026-10-15. Spike W0-D-S3 (ARCHITECTURE ADR-14.7). Consumer: W1-7 (ADR-9.5).
Branch: `wp/W0-D-S3-scrollback-replay`. Reference code: `docs/arch/spikes/proto/S3/`.

**Decision: adopt with changes.** Terminal-side replay before the PTY read thread works for cmd, pwsh and WSL. ADR-9.5 needs these changes:

- Change the byte sequence: sanitize the input, reset SGR before the line feeds, and add `ESC[H` after them.
- Fix one edge case in Ghostty's column reflow through a CCR.
- Read the file off the UI thread and chunk the replay (SHOULD).

Shell-side replay is not needed as a fallback.

## 1. Question

ADR-9.5 replays saved scrollback when a session is restored. The saved VT text is fed into the new terminal before the PTY read thread starts. It is followed by `\r\n` × rows, which scrolls it into history, and an SGR reset. Three questions:

1. Does ConPTY's start-up clear or redraw wipe the injected text?
2. Does the prompt appear after the injected lines for cmd.exe, pwsh and `wsl.exe -d Ubuntu-24.04`?
3. What does ConPTY send at start (`ESC[2J`, `ESC[3J`, redraw)?

We also evaluated the fallback: an env file plus `cat`/`Get-Content` in the shell, with no replay for cmd.

## 2. Setup

| Item | Value |
|---|---|
| OS | Windows 11 Enterprise 10.0.26200.9448 (25H2). In-box ConPTY (`kernel32!CreatePseudoConsole`, conhost 10.0.26100.x), flags `0`, same as `src/pty.zig` |
| Shells | cmd.exe 10.0.26100.9278. PowerShell 7.6.6, both with the user's oh-my-posh profile and with `-NoProfile`; wmux PowerShell shell integration on. WSL 2 Ubuntu-24.04 (bash with an oh-my-posh prompt; the VM was already running) |
| wmux | `master` @ `aa1f532` plus the spike patch `proto/S3/s3-spike.patch` (reverted on the branch). Zig 0.15.2, `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`. Debug build for function tests, ReleaseFast for timing |
| Raw probe | `proto/S3/conpty_probe.zig`: creates the pseudoconsole and spawns exactly like `src/pty.zig` + `src/Command.zig`. Records every output chunk with a ms timestamp and can resize, type input or use `PSEUDOCONSOLE_INHERIT_CURSOR`. Driver: `proto/S3/run-probe.ps1`. Build: `zig build-exe conpty_probe.zig -target x86_64-windows-gnu -O ReleaseSafe` |
| In-app harness | `proto/S3/run-wmux-replay.ps1` + `S3Native.cs`. Launches wmux with `ProcessStartInfo{UseShellExecute=false, CreateNoWindow=true}` and `WMUX_TEST_HIDDEN=1` (off-screen at -32000,-32000, `WS_EX_NOACTIVATE\|WS_EX_TOOLWINDOW`, `SW_SHOWNOACTIVATE`, no `SetFocus`, 1600×1000 px at 144 DPI, which gives 88×29 cells). Sandboxed `LOCALAPPDATA`/`APPDATA`/`XDG_CONFIG_HOME` with a future `update_check_at`. A foreground sampler checks every 100 ms (`GetForegroundWindow` + `GetWindowThreadProcessId`) and aborts the run on a violation. Verification: legacy pipe `\\.\pipe\wmux-ipc-<pid>`, `{"cmd":"read-screen","args":{"scrollback":true}}` plus the visible screen. The process tree is killed at the end |
| Test history | 100 numbered lines `S3-LINE-NNN …`. Includes 24-bit SGR, Unicode on line 33, a 213-char wrapped line (77), an unclosed background (45), and a hostile line 50 with `OSC 0`, `OSC 52`, `ESC[6n`, `ESC[c`, `ESC[?1049h`, `ESC[2J`, `ESC[3J`. Plus 4000 lines × ~106 chars (425 KB, the ADR-9.2 cap) for timing |
| Spike glue | `WMUX_SPIKE_RESTORE_FILE` (read in core `Surface.init`) and `WMUX_SPIKE_RESTORE_MODE` = `none` \| `crlf` (ADR as written) \| `crlf_home` (recommended). The termio read thread logs the first 6 ConPTY chunks |

## 3. Results

### 3.1 What in-box ConPTY sends to the terminal (raw probe, `proto/S3/out/`)

| Shell | First chunk | First frame (contains the clear) | First frame arrives at |
|---|---|---|---|
| cmd | `ESC[?9001h ESC[?1004h` (+114 ms) | `ESC[?25l ESC[2J ESC[m ESC[H` banner… `ESC]0;…BEL ESC[?25h` | +185 ms |
| pwsh -NoProfile | same | `ESC[?25l ESC[2J ESC[m ESC[H` `PS C:\…>` | +6.1 s |
| pwsh + oh-my-posh | same | `ESC[?25l ESC[2J ESC[m ESC[H` title only; prompt at +18.4 s | +15.4 s |
| WSL | same, then `ESC[?2004h` passed through **before** the frame | `ESC[?25l ESC[2J ESC[m … ESC[H` prompt | +3.2 s |

- **ConPTY sends `ESC[2J` exactly once, as the first frame. It never sends `ESC[3J`** at start-up, on resize or on close. `ESC[3J` comes only from the user: `cls`, `clear` and `Clear-Host` each produce `ESC[3J` (measured).
- The first frame is lazy. It comes with the client's first output or right after the first `ResizePseudoConsole` (even a same-size one), whichever is first. If a resize comes before the first frame, the frame is `ESC[2J ESC[m ESC[H` + (rows−1) × `\r\n` + `ESC[H`.
- After the first frame, a resize repaints the whole screen with no `ESC[2J`/`ESC[3J`: `ESC[?25l ESC[8;R;Ct ESC[H` then each line + `ESC[K` + `\r\n`.
- `PSEUDOCONSOLE_INHERIT_CURSOR` (flag 1): ConPTY first asks `ESC[6n` and never sends `ESC[2J`. **Rejected**:
  - The WSL prompt stalled until a resize (6 s, against 3.2 s without the flag).
  - The original close order hung the probe: `ClosePseudoConsole`, then wait 5 s and terminate the client. It was killed after 25 s; terminating the client first fixed it.
  - On resize, ConPTY repaints its whole buffer starting at the inherited row (`ESC[10;1H` … 39 × `ESC[K\r\n` for 40 rows). This scrolls the terminal, and ConPTY's buffer knows nothing about the restored lines.

Inside wmux the same sequence was confirmed in situ (stderr log `S3 conpty chunk#…`, `out/inapp-conpty-chunks.txt`). The log order shows that the replay always comes before the spawn:

- In all 30 Debug runs, `S3 replay: …` is logged before `starting command`, which is where the subprocess and ConPTY are created.
- In all 38 replay runs, `S3 replay: …` is logged before the first ConPTY chunk. `starting command` is a debug-level log and is not printed in ReleaseFast.

wmux always resizes once just after spawn (layout: 29 → 27 rows), so the first frame comes at +0.1–0.5 s for every shell.

### 3.2 Replay inside wmux (Debug build, 100 lines, no forced resize)

| Mode | cmd | pwsh -NoProfile | pwsh + profile | WSL |
|---|---|---|---|---|
| `none`: text only (control) | 76/100, lines 77–100 erased by `ESC[2J` | 76/100 | n/a | 76/100 |
| `crlf`: ADR-9.5 as written | 100/100, **2 blank lines** before the prompt | 100/100, 2 blank | n/a | 100/100, 2 blank |
| `crlf_home`: sanitize + `ESC[0m` + `\r\n`×rows + `ESC[H` | **100/100, 0 blank**, prompt on the top row | **100/100, 0 blank** | **100/100, 0 blank** | **100/100, 0 blank** |
| fallback: env file + `type` / `Get-Content` / `cat` | 100/100, **UTF-8 mangled** (`h├⌐llo`) | 100/100, **CJK → `???`, `✓` → `√`** | 100/100, mangled, history only at **+17.9 s** | 100/100, Unicode OK |

Across all runs:

- The ordering was correct, no line was duplicated, SGR was kept and wrapped lines survived.
- The hostile line leaked nothing. The title did not change, and no CPR or DA reply was typed into the shell.
- The foreground sampler never fired: 46 runs, 30–528 samples each, 4,323 in total (`out/inapp-results.csv`).
- With terminal-side replay the history is visible ~2.4 s after launch. With the pwsh profile the prompt comes at 23.7 s.
- The 2 blank lines in `crlf` come from the post-spawn layout shrink. With the cursor on the bottom row, Ghostty cannot trim the trailing blank rows, so the top rows of the active area are pushed into history.

### 3.3 Resize between replay and ConPTY's first frame

This was forced with `SetWindowPos(SWP_NOACTIVATE)` as soon as the window existed. The stderr log confirms that all resizes were processed before ConPTY's first frame.

| Resize before first frame | `crlf` (cursor on the last row) | `crlf_home` | `crlf_home` + PageList fix |
|---|---|---|---|
| none / layout shrink (29→27 rows) | 100, 2 blank | 100, 0 blank | 100, 0 blank (cmd, pwsh -NoProfile, WSL) |
| grow rows (1000→1500 px) | **87/100**, lines 88–100 lost (cmd and WSL) | 100 | 100 (cmd, WSL) |
| shrink rows (1000→700 px) | 100, **11 blank** | 100, 0 blank | n/a |
| narrow (1600→1000 px, 88→45 cols) | 100 | **94/100**, lines 95–100 lost | 100 (cmd, WSL) |
| narrow + grow | n/a | n/a | 100 (cmd, WSL) |

A pure-logic reproduction is in `Terminal.zig` (spike test `S3 spike: replay placement vs early resize`: 30 lines, 20×6, resize, then `eraseDisplay(.complete)`):

- bottom: grow 26/30, narrow+grow 29/30.
- home: narrow 29/30, narrow+grow 28/30.
- home + fix: **30/30 in every case**.
- The full `zig build test-lib-vt` suite passes with the fix (exit 0, 883 s).

Two root causes, both in `src/terminal/PageList.zig`:

1. **Grow** (`resizeWithoutReflow`): if the cursor is on the last row, Ghostty pulls scrollback down into the active area. ConPTY's `ESC[2J` then erases it. `ESC[H` after the line feeds avoids this.
2. **Narrow** (`resizeCols`):
   - Reflow never rewrites trailing blank rows. With the cursor at the top of a blank active area, the active window therefore slides up into history.
   - The preserved-cursor growth then subtracts every wrap continuation between the cursor and the new active top. Those continuations are history rows, not rows above the cursor, so the growth falls short and history stays in the active area, where ConPTY's `ESC[2J` erases it.
   - The fix (`proto/S3/pagelist-resizecols-fix.patch`, about 25 lines) tracks the pre-reflow active top and counts wraps only up to the lower of the old and new tops.

### 3.4 Cost

| History | Debug (contended machine) | ReleaseFast (`-p zig-out/rel`) |
|---|---|---|
| 6.2 KB / 100 lines | 58–150 ms | **0.5–1.4 ms** (3 runs) |
| 425 KB / 4000 lines (ADR cap) | 17.1 s | **18–28 ms** (5 runs: 19.5, 27.9, 18.4, 28.5, 22.5) |

- All 4000 lines survived in every ReleaseFast run (cmd, pwsh -NoProfile, WSL) with 0 blank lines.
- The spike holds `renderer_state.mutex` for the whole replay. The shell is spawned only after the replay, so the replay time is added to time-to-prompt.
- When the 425 KB history became visible (ReleaseFast, first successful read-screen after launch):

| | cmd | pwsh -NoProfile | WSL |
|---|---|---|---|
| Terminal-side replay | 0.86–0.89 s | 0.82 s | 1.42 s |
| Shell-side fallback | 1.72 s | 6.52 s | 4.45 s |

The fallback also delivered all 4000 lines through ConPTY, but only after the shell had started.

## 4. Decision

**Adopt ADR-9.5 with changes.**

1. **Keep:** replay in `Termio.threadEnter` before `backend.threadEnter`, so there is no subprocess and no read thread yet and nothing can interleave. One code path for cmd, pwsh, bash and WSL. Nothing is typed into the shell, and shell history and the title are untouched.
2. **Change the byte stream:** `sanitize(file) ++ ESC[0m ++ "\r\n" × rows ++ ESC[H`. The SGR reset goes before the line feeds: Ghostty applies the current background to rows scrolled in (`Screen.cursorDownScroll`). `ESC[H` prevents the grow loss and the blank rows left by a shrink.
3. **CCR to core:** apply `pagelist-resizecols-fix.patch` (with its unit test) so an early column shrink cannot lose rows.
   - Until it lands, the W1-7 spec should require that restored terminals are spawned only after the pane has its final size. ADR-9.4 already shows windows before the staggered spawn.
   - The remaining risk is a user narrowing the window before the first frame.
4. **Read the file off the UI thread.** The replay SHOULD be chunked at 64 KiB per mutex hold. It is cheap (≤ 28 ms at the cap in ReleaseFast), but a single hold also blocks the UI thread's `read-screen` and selection paths, and a Debug build takes seconds.
5. **Fallback rejected as primary.** It needs per-shell code and has no hook for cmd (`cmd /k type` only). `type` and pwsh `Console.Out` decode with the OEM code page inside ConPTY, which mangles UTF-8. The history is visible only after the profile loads. Do not run it together with terminal-side replay, or the history prints twice.

## 5. Guidance for W1-7 and its consumers

### 5.1 API sequence

```zig
// src/termio/Options.zig (ADR-9.5 name kept)
/// Saved scrollback (VT text) replayed before the PTY read thread starts.
/// Borrowed; Termio.init copies it. Untrusted: sanitized at replay.
restore_history: ?[]const u8 = null,

// src/termio/Termio.zig
restore_history: ?[]u8 = null, // owned copy, freed after replay or in deinit

// Termio.init, before `self.* = .{...}`:
const restore_history: ?[]u8 = if (opts.restore_history) |h| try alloc.dupe(u8, h) else null;
errdefer if (restore_history) |h| alloc.free(h);

// Termio.threadEnter, after `data.* = .{...}`, before `try self.backend.threadEnter(...)`:
if (self.restore_history) |h| {
    defer {
        self.alloc.free(h);
        self.restore_history = null;
    }
    self.replayRestoreHistory(h);
}

fn replayRestoreHistory(self: *Termio, saved: []const u8) void {
    // rows cannot change here: resizes are handled on this same IO thread,
    // after threadEnter returns.
    const bytes = scrollback_replay.buildReplay(self.alloc, saved, .{
        .rows = self.terminal.rows,
    }) catch |err| {
        log.warn("scrollback replay skipped err={}", .{err});
        return;
    };
    defer self.alloc.free(bytes);
    // The stream parser keeps state across calls, so any split is safe.
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, 64 * 1024);
        self.renderer_state.mutex.lock();
        self.processOutputLocked(rest[0..n]);
        self.renderer_state.mutex.unlock();
        rest = rest[n..];
    }
}
```

`scrollback_replay.buildReplay` and `sanitize` are in `proto/S3/replay.zig`, which is std-only and has 8 tests (`zig test replay.zig`). Move them to `src/termio/scrollback_replay.zig`. Name the tests `unit: session: …` and add the spike's Terminal-level test as a regression test.

### 5.2 Getting the bytes to Termio

- Core `Surface.init` has no per-surface parameter for this, so add an optional apprt hook to the win32 `Surface`: `pub fn takeRestoreHistory(self: *Surface) ?[]const u8`. Session restore sets it before `core_surface.init`.
- Call the hook from core with `if (@hasDecl(apprt.Surface, "takeRestoreHistory")) rt_surface.takeRestoreHistory() else null`. The guard keeps GTK and embedded builds compiling.
- Read `scrollback\<uuid>.vt` on the session worker, never on the UI thread (G3), capped per ADR-9.2.
- Alternative needing a CCR: a path field read in `threadEnter`. This keeps the bytes off the UI thread and avoids holding up to 512 × 400 KB during staggered spawn.

### 5.3 Gotchas

- Sanitize at replay even though the saver already strips. Replies to `ESC[6n`/`ESC[c` would be queued as PTY writes and typed into the new shell. The spike's sanitizer keeps only printable text, TAB, CRLF and `CSI … m`. It also drops UTF-8 C1 controls, turns lone LF into CRLF, drops lone CR and trims trailing line breaks. Without the trim you get one blank line before the prompt.
- Do not export `CMUX_RESTORE_SCROLLBACK_FILE`/`WMUX_RESTORE_SCROLLBACK_FILE` when terminal-side replay ran. cmux semantics (interface facts only) are that the shell integration reads it once, prints it between OSC 1337 boundary markers and unsets it, so it would print the history a second time. Export it only if a future setting turns terminal-side replay off.
- After restore the visible screen shows only the prompt on the top row, with history above it in scrollback. This is like `clear` and is not cmux's "history above the prompt on screen". Getting that would need `INHERIT_CURSOR`, which was rejected in 3.1.
- `cls`, `clear`, `Clear-Host`, or a profile or AutoRun that clears at start-up, sends `ESC[3J` and wipes the restored history. This is expected; document it in `docs/wmux/features/`.
- The replay delays the spawn by its own duration (3.4). Keep it on the IO thread so staggered spawns run in parallel.
- ConPTY's first frame can come up to ~15 s after spawn (slow pwsh profiles) when no resize happens. In that window `ESC[H` makes a grow or a shrink safe; a narrow is safe only with the PageList fix. A same-size `ResizePseudoConsole` right after spawn brings the frame forward to ~0.4–0.6 s (measured). This is optional; wmux's post-spawn layout resize does it today.
- e2e (ADR-9 risk line): use `run-wmux-replay.ps1` as the model for 100 numbered lines × {cmd, pwsh, WSL}. Assert all lines present, in order, 0 blank lines before the first shell output, and the first shell output on the top row. Add the early-grow and early-narrow variants (`-ResizeAfterMs 0`).
- Hidden instances (W0-B/S2): replay and read-screen work with the off-screen `WS_EX_NOACTIVATE` window. No focus change was seen in any run.

## 6. Open risks

- **The core CCR** touches upstream Ghostty reflow semantics for every terminal. The full lib-vt suite passes, but the fix should be raised upstream. Without it, a narrow resize before the first frame loses as many restored rows as there are wrapped continuation rows near the end of the history, up to one screenful.
- **A general ConPTY + Ghostty resize issue, not restore-specific:** after the first frame, a narrow can still slide history rows into the active area. ConPTY's full repaint (`ESC[H` + line + `ESC[K`) then overwrites them. The PageList fix addresses the same mechanism; measure it in W1-7's e2e.
- **Future ConPTY:** an inbox conhost update or a bundled OpenConsole may stop sending `ESC[2J`. The replay does not depend on it, because the active area is blank either way. If one ever sent `ESC[3J` at start-up, the replay would break; e2e will catch it.
- **The 425 KB replay** blocks the IO thread for 18–28 ms in ReleaseFast. Restore storms are bounded by the staggered spawn.
- **Measurement limits:** one machine, one ConPTY build, a heavily loaded machine (timings are indicative), and WSL with the VM already running.
