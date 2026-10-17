# Legacy wmux JSON reply shapes

Golden reply shapes for `test/e2e/suites/legacy/legacy-compat.e2e.ps1` (W0-B2, ADR-3.7, AF-11).

- One file per legacy command of `\\.\pipe\wmux-ipc-<pid>` (the 37 names of the `Command` enum
  in `src/apprt/win32/rpc/compat/legacy_json.zig`), plus `_protocol.json` for framing and
  validation errors. The suite fails when the file list and the enum differ.
- Each file maps a case name (`ok`, `unknown_workspace`, `next_jumped`, ...) to the shape of the
  whole reply envelope, in `Assert-JsonShape` syntax (`test/e2e/README.md`): `"<strict>": true`
  pins the key set, `"<int>"`, `"<string>"`, `"<bool>"`, `"<any>"` and `["<each>", shape]` are
  wildcards, everything else is literal (error strings, `"ok"` from click and fill).
- Every case is exercised by the suite; its last Test-Case fails when a pinned case never ran.
- The shapes describe the behavior of master at the W0 skeleton (moved verbatim from `aa1f532`
  in W0-A1). A feature WP that re-points a command to its v2 implementation (ADR-3.7) must keep
  these replies; a deliberate change (for example legacy `log` no longer creating notifications)
  updates the fixture in the same commit and names the Appendix E row.
