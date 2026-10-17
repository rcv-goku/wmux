# PB-platform: Win32 platform bindings (job objects, DPAPI, shell)

Internal pre-build for W1-3 (env/identity/jobs), the RPC auth and password store and the open/explorer features. No user-visible change yet.

- `platform/job.zig`: typed `Job` wrapper (create with limits, assign, `IsProcessInJob`, pid list with a growable buffer, terminate) and an owned `PROC_THREAD_ATTRIBUTE_LIST` with `PROC_THREAD_ATTRIBUTE_JOB_LIST`; presets `Limits.tab`/`instance` (BREAKAWAY_OK) and `Limits.wrapper` (KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK, spike S4).
- `platform/dpapi.zig`: current-user `CryptProtectData`/`CryptUnprotectData` with optional entropy and `CRYPTPROTECT_UI_FORBIDDEN`; outputs are LocalFree'd and owned plaintext is zeroed.
- `platform/shell.zig`: known folders as UTF-8, `ShellExecuteExW` open/explore, reveal in Explorer (`SHOpenFolderAndSelectItems`), default-app lookup (`AssocQueryStringW`).
- `platform/tests.zig`: pure `unit: platform:` tests for every OS plus live Windows tests (hidden `cmd.exe` children only).
