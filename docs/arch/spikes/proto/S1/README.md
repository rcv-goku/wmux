# Spike S1 prototype (toasts)

Reference code for `docs/arch/spikes/S1-toasts.md`. It is not part of the wmux
build. It only uses the spike identities: AUMID `wmux.spike.s1`, protocol
`wmux-spike-s1`, CLSID `{F6731D70-24AA-4042-AAA9-4A386308A09B}` and pipe
`\\.\pipe\wmux-spike-s1-launch`.

| File | What it is |
|---|---|
| `s1.zig` | One Zig 0.15.2 source with hand-written WinRT/COM ABI: AUMID/protocol/COM registration, `ToastNotifier`, `ToastNotification` events, `ToastNotificationHistory`, `INotificationActivationCallback` server and client, protocol handler with launch-pipe forwarding and foreground-rights probes. |
| `fg-sampler.ps1` | Read-only external foreground sampler (100 ms). Flags any sample where `s1.exe`/`s1w.exe` owns the foreground. |
| `uia-observe.ps1` | Passive banner observer (Windows PowerShell 5.1): dumps the UI Automation tree of shell notification windows when they appear. Never invokes anything. |

## Build

```powershell
$Z = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe'
$B = '<scratch dir outside docs/>'   # never commit build output
& $Z build-exe s1.zig -target x86_64-windows-gnu -O ReleaseSafe --subsystem console --name s1  "-femit-bin=$B\s1.exe"
& $Z build-exe s1.zig -target x86_64-windows-gnu -O ReleaseSafe --subsystem windows --name s1w "-femit-bin=$B\s1w.exe"
& $Z test s1.zig -target x86_64-windows-gnu      # pinterface IIDs == SDK header values
```

`s1.exe` is the console driver. `s1w.exe` (GUI subsystem, no windows) is what
the shell and COM launch: the protocol handler (`s1w.exe "<uri>"`) and the
activator's LocalServer32 (`s1w.exe -ToastActivated`, COM appends `-Embedding`).
Both write JSON lines to `s1-log.jsonl` next to the exe. Only the console driver
also echoes to stdout.

## Commands (`s1.exe <command>`)

| Command | Effect |
|---|---|
| `env` | OS build, `SHQueryUserNotificationState`, foreground lock timeout, idle time, foreground process, own foreground-rights probe, proxy/stub and registry state. Read-only. |
| `selftest` | Recomputes the parameterized IIDs and prints struct sizes. |
| `register [--icon <png>] [--no-activator]` | Creates the three HKCU keys (AUMID, protocol, CLSID). |
| `unregister` | `ClearWithId`, then deletes the three keys plus `Notifications\Settings\wmux.spike.s1`. |
| `setting [--aumid X]` | `CreateToastNotifierWithId` + `get_Setting`. |
| `set-app-enabled --value 0\|1\|delete` | Writes or deletes `Notifications\Settings\wmux.spike.s1\Enabled` (spike AUMID only). |
| `show --variant A\|B\|C [--wait-ms N] [--long-ids] [--suppress-popup] [--remove-after-ms N --remove-mode tag\|group]` | Builds and shows a toast (A = protocol launch + Reply input + Show button; B/C = text only), subscribes to Dismissed/Activated/Failed and polls history. **Shows a real toast.** |
| `history` | Lists the AUMID's toasts in Action Center (tag, group, XML). |
| `remove --mode tag-group\|group\|tag-only\|clear --tag T --group G` | History removal variants. |
| `start-server` | `CoCreateInstance(CLSCTX_LOCAL_SERVER)`: COM (DcomLaunch) starts the server, so it inherits no foreground rights from the terminal. |
| `send-uri <uri>` | `AssocQueryStringW` (resolve without launching), then `ShellExecuteExW` with `SEE_MASK_FLAG_NO_UI`. |
| `spawn-via-server <uri>` | Asks the (rights-free) server to launch the handler itself. |
| `activate-sim [--args S] [--reply T] [--grant]` | Out-of-process `INotificationActivationCallback::Activate` with one input pair. `--grant` calls `CoAllowSetForegroundWindow` first. |
| `ping`, `quit` | Launch-pipe control. |

## Automated sequence used on 2026-10-15

```powershell
s1 setting; s1 setting --aumid wmux.spike.s1.never-registered   # before registration
s1 register; s1 setting
s1 activate-sim --args "action=reply&id=T1-COLD" --reply "T1 cold reply"   # COM cold start
s1 activate-sim --reply T2a; s1 activate-sim --reply T2b --grant            # warm
s1 start-server; s1 send-uri "wmux-spike-s1://notification/open?id=T4&ws=W1"
s1 spawn-via-server "wmux-spike-s1://notification/open?id=T5"; s1 quit
s1 send-uri "wmux-spike-s1://notification/open?id=T6"                      # no instance -> exit 3
s1 show --variant B --long-ids --wait-ms 15000                              # toast 1
s1 history; s1 remove --mode group --group <64-char group>; s1 history
s1 set-app-enabled --value 0; s1 setting; s1 set-app-enabled --value delete
s1 show --variant A --wait-ms 12000                                         # toast 2
s1 history; s1 remove --mode tag-group --tag <uuid> --group <uuid>; s1 history
s1 unregister
```

`fg-sampler.ps1` ran for the whole session, and `uia-observe.ps1` ran around
each toast.

## Manual verification (needs a person at an unlocked desktop)

Clicking a toast cannot be automated here. A tester confirms the click paths
like this (each step shows one toast):

1. Build, then `s1 register` and `s1 start-server` (the server starts through
   COM, so it holds no foreground right of its own). The server exits after
   3 minutes without activity. Run `s1 start-server` again if needed.
2. **Body click (protocol):** `s1 show --variant A --wait-ms 60000`, then click
   the banner body (or the entry in Action Center). Expected in `s1-log.jsonl`:
   - `handler_start` with `parent_exe` (the shell process that launched it) and
     `self_probe_ok:true`
   - `handler_done` with `grant_ok:true`
   - server `launch_received` with `server_pre_probe_ok:false` and
     `server_post_probe_ok:true`

   That is the evidence that the click gives the handler a foreground right and
   that `AllowSetForegroundWindow(server_pid)` passes it to the running instance.
   For a visible confirmation, start the server with
   `s1w.exe server --foreground-demo` instead. It then opens a small window and
   calls `SetForegroundWindow` after a successful grant. This is the only code
   path that ever takes the foreground, and it is opt-in.
3. **Show button (protocol):** same as step 2, but click "Show". The URI ends
   with `&button=show`.
4. **Reply (COM activator):** type text in the toast's box and press "Reply".
   Expected: `com_activate` with `args` = `action=reply&id=<uuid>`, a
   `com_activate_input` line with `key:"reply"` and the typed text, and
   `fg_probe_ok` (whether the platform passed a foreground right with the
   activation). If no server is running, COM starts `s1w.exe -ToastActivated
   -Embedding` first, which `server_start` shows as `cold_com_launch:true`.
5. **Per-app disable:** Settings > System > Notifications > "wmux spike S1" >
   Off, then `s1 setting` should report `DisabledForApplication` (1). Turn it
   back on afterwards.
6. Clean up with `s1 quit` and `s1 unregister`.
