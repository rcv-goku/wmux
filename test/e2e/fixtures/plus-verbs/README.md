# Legacy +verb goldens

`goldens.json` holds the expected output of every legacy wmux `+verb` for
`test/e2e/suites/legacy/plus-verbs.e2e.ps1` (W0-B2, AF-11, AF-19): per group and step, the argv,
the exit code, stdout and stderr, with volatile parts masked.

## Source

Captured on 2026-10-17 (UTC) with the `wmux.exe` CLI of master `aa1f532` ("chore: bump PE version to
1.1.0.0", debug build from a temporary worktree outside the repository, deleted afterwards).
`aa1f532` predates `WMUX_TEST_HIDDEN`, so its GUI was never started: its `+verbs` (CLI clients
of the legacy pipe) ran against hidden instances of the W0 master build. The server side of the
legacy pipe was moved verbatim in W0-A1, and `src/cli` differs from `aa1f532` only by a
double-free fix, so the outputs are those of `aa1f532`. Two consecutive captures were identical.

## Masks

| Mask | Replaces |
|---|---|
| `<ROOT>` | the instance root under `%TEMP%\wmux-e2e\<id>` (raw, JSON-escaped or with `/`) |
| `<PID>` | the pid in `wmux-ipc-<pid>` |
| `<ID>` | integers of 7+ digits (64-bit surface ids) |
| `<V>` | the Windows build in cmd's banner (`[Version <V>]`) |
| `<REF>` | CDP node refs in `"ref":<n>` |

CRLF is normalized to LF. The argv of `+browser click` and `+browser fill` carries the node refs
of that run; argv is informational and never compared.

## Regenerating

Only when the legacy output changes on purpose (record the reason in the commit):

```powershell
git -C <repo> worktree add --detach $env:TEMP\wmux-golden <commit>
# build it: zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu (in that worktree)
$env:WMUX_E2E_PLUSVERBS_CAPTURE = "$env:TEMP\wmux-golden\zig-out\bin\wmux.exe"
$env:WMUX_E2E_PLUSVERBS_SOURCE = '<commit> (<subject>), debug build, CLI against a hidden master instance'
$env:WMUX_E2E_TEST_TIMEOUT_SEC = '900'
pwsh -NoProfile -File test/e2e/suites/legacy/plus-verbs.e2e.ps1   # with zig-out\bin\wmux.exe of the tree under test
git -C <repo> worktree remove --force $env:TEMP\wmux-golden
```
