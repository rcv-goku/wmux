# S5 prototype (reference only)

Throwaway prototypes behind `docs/arch/spikes/S5-webview2-proxies.md`. They are
not part of the wmux build graph and are not maintained.

| File | What it is |
|---|---|
| `s5proto.zig` | Main probe: 8 WebView2 environments in one process, local SOCKS5 and HTTP proxies, a test origin with WebSocket echo, PID admission, the BasicAuthenticationRequested fallback, teardown. Prints `CHECK PASS/FAIL` lines. |
| `s5close.zig` | Teardown probe: how long a browser process and its user-data folder lock outlive `Controller::Close()` under several release strategies. |
| `run-s5.ps1` | Runner: launches either exe hidden (`UseShellExecute=false`, `CreateNoWindow=true`), samples the foreground window every 100 ms and kills the run if the prototype tree ever becomes foreground. During the hold phase it records the process table and runs `curl.exe` against the proxies from a foreign process. |

Both probes reuse wmux's bindings `src/apprt/win32/webview2.zig` as module
`wv2`. Interfaces that the bindings don't have yet are called through raw
vtable indices, verified against `WebView2.idl` from SDK 1.0.4022.49.

## Build (from the repository root, PowerShell)

```powershell
$Z = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe'
$O = "$PWD\.s5-scratch\build"          # untracked; deleted afterwards
New-Item -ItemType Directory -Force $O | Out-Null
# Quote the -M arguments: PowerShell splits an unquoted -opt=x.zig at the dot.
& $Z build-exe -target x86_64-windows-gnu -O Debug --dep wv2 `
    "-Mroot=docs\arch\spikes\proto\S5\s5proto.zig" "-Mwv2=src\apprt\win32\webview2.zig" `
    -lole32 -luser32 -lws2_32 -liphlpapi --name s5proto "-femit-bin=$O\s5proto.exe"
& $Z build-exe -target x86_64-windows-gnu -O Debug --dep wv2 `
    "-Mroot=docs\arch\spikes\proto\S5\s5close.zig" "-Mwv2=src\apprt\win32\webview2.zig" `
    -lole32 -luser32 --name s5close "-femit-bin=$O\s5close.exe"
# WebView2Loader.dll (x64, SDK 1.0.4022.49) must sit next to the exes.
```

## Run

```powershell
pwsh -File docs\arch\spikes\proto\S5\run-s5.ps1 -Exe $O\s5proto.exe -Scratch $PWD\.s5-scratch\run -TimeoutSec 540
pwsh -File docs\arch\spikes\proto\S5\run-s5.ps1 -Exe $O\s5close.exe -Scratch $PWD\.s5-scratch\close `
    -ExtraArgs '--only plain,reattach,keepenv --wait 240'
```

Outputs go to the scratch directory: `s5.log`, `summary.txt`, `processes.txt`
and `runner.txt` (or `s5close.log`). Delete the scratch directory afterwards.
The user-data folders can stay locked for minutes (see the decision note).
