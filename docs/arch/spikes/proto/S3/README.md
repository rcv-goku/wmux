# S3 prototype files (reference only, not built by `zig build`)

Decision note: `../../S3-scrollback-replay.md`.

| File | What |
|---|---|
| `conpty_probe.zig` | Standalone raw ConPTY recorder. Uses the same API sequence and flags as `src/pty.zig` + `src/Command.zig`. Build with `zig build-exe conpty_probe.zig -target x86_64-windows-gnu -O ReleaseSafe` into `zig-out/s3/` |
| `run-probe.ps1` | Runs the probe for cmd, pwsh and WSL with a hidden console (`CreateNoWindow`) |
| `replay.zig` | Pure replay builder: `sanitize` + `buildReplay` (`ESC[0m`, `\r\n`×rows, `ESC[H`). Run with `zig test replay.zig` (8 tests) |
| `s3-spike.patch` | All spike source changes, reverted on the branch: `termio.Options.restore_history`, replay in `Termio.threadEnter`, `WMUX_SPIKE_RESTORE_FILE`/`_MODE` glue in core `Surface.init`, the in-situ ConPTY chunk log in `Exec.zig`, `WMUX_TEST_HIDDEN` hidden window (off-screen, `WS_EX_NOACTIVATE\|WS_EX_TOOLWINDOW`, `SW_SHOWNOACTIVATE`, no `SetFocus`, no exit dialog), the PageList fix and the Terminal-level test |
| `pagelist-resizecols-fix.patch` | Just the CCR candidate: `PageList.resizeCols` preserved-cursor wrap count + the `S3 spike: replay placement vs early resize` test |
| `run-wmux-replay.ps1`, `S3Native.cs` | Hidden, sandboxed wmux run with a foreground sampler and verification through legacy pipe `read-screen` |
| `out/` | Raw probe reports and in-app results (user, host and WSL user names redacted) |

To reproduce the in-app runs:

```powershell
git apply docs/arch/spikes/proto/S3/s3-spike.patch
& $Z build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
pwsh docs/arch/spikes/proto/S3/run-wmux-replay.ps1 -Shell wsl -Mode crlf_home -ResizeAfterMs 0 -ResizeWidth 1000 -ResizeHeight 1000
git apply -R docs/arch/spikes/proto/S3/s3-spike.patch
```

The pure-logic test runs with `& $Z build test-lib-vt -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu "-Dtest-filter=S3 spike"` after `git apply pagelist-resizecols-fix.patch`. Without the fix, the test fails for `home` + `narrow` (29/30) and `narrow_grow` (28/30).
