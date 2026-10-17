# Manual-check ledger (AF-19)

Some behaviors cannot be asserted by the hidden, focus-safe e2e harness: they need a real
person at a real desktop (IME composition, DPI changes over RDP, a real click on a toast,
OLE drags on screen, passkeys, UAC prompts, snap layouts, NVDA, the relay security
sign-off). Since AF-19 (Appendix F.2, 2026-10-16) these checks **never block a merge or a
wave tag**. Each one is a row in this ledger; the suite that would otherwise cover the
feature carries a waiver tag in its header:

```powershell
# wp: W5b-4
# covers: extra-terminal-mouse-reporting
# manual: extra-terminal-input-fidelity "IME composition needs a real keyboard layout switch"
```

Rules

- One row per waived feature id (the first column is the `matrix.csv` id, exactly as in the
  `# manual:` tag). `scripts/check-manifest.ps1` warns about a `# manual:` waiver whose id
  has no row here; `test/e2e/coverage.ps1` counts the id as waived, not covered.
- The WP that adds the waiver adds the row in the same change (any WP may append rows: one
  row per line, nothing else changed). The stabilization WP of each wave (N9) runs the open
  checks it can, fills in *last run* and records failures as follow-ups of the owning WP;
  a failed manual check is a follow-up, never a red gate.
- The lead architect (the human program owner, AF-19) signs off the security-relevant rows
  (relay, policy, elevation); SLA one working day.
- Remove a row only when an automated test covers the behavior and the waiver tag is gone.

Columns: **id** (matrix id) · **check** (what a person does and expects) · **why manual** ·
**owner** (WP that owns the feature) · **status** (`open`, `passed`, `failed`, `retired`) ·
**last run** (date, who, build).

## Ledger

| id | check | why manual | owner | status | last run |
|---|---|---|---|---|---|
| browser-webauthn-passkeys | Register and use a passkey on a WebAuthn demo page in a browser pane with Windows Hello | Windows Hello prompt needs a person | W5a-7e | open | - |
| extra-accessibility | Navigate sidebar, tabs and a terminal with NVDA; names and roles are announced | screen reader output is judged by ear | W7-2 | open | - |
| extra-terminal-input-fidelity | Compose CJK text with the Microsoft IME and dead keys in a terminal pane | IME candidate windows need a real keyboard session | W5b-4 | open | - |
| extra-terminal-local-file-drop | Drag files from Explorer onto a terminal pane; quoted paths are inserted | OLE drag and drop from another process on screen | W4-6b | open | - |
| panels-file-drag-into-workspace | Drag a file from the right sidebar into a pane; a preview tab opens | OLE drag on screen | W5b-10b | open | - |
| remote-cli-relay | Review the reverse CLI relay (auth, allowlist, socket permissions) before release | security sign-off by the program owner | W6-4a | open | - |
| w0-cloaked-gl-capture | On an UNLOCKED session (no `LogonUI.exe`), run `pwsh test/e2e/run.ps1 -Suite w0-regression -Filter "hidden window"` on Debug and ReleaseFast; the cloaked capture passes with a non-blank terminal child (3+ colours) instead of skipping | GL output of a cloaked window is blank while the workstation is locked; every W0-ST run on 2026-10-17 was locked (one colour, 0x282C34 at 100 %, reported as a skip); non-blocking | W0-ST | open | 2026-10-17, W0-ST part 2, Debug + ReleaseFast: inconclusive (session locked) |
| w0-ci-web-node-job | First GitHub Actions run of the CI job 'Web panels (Node, jsdom)' passes and runs every `test/web-node/**/*.test.mjs` | the job exists only on GitHub Actions; this host cannot run it; non-blocking | W0-ST | open | - |
| w0-ci-nightly-full-gate | First GitHub Actions run of the nightly 'full-gate' job (`scripts/gate.ps1 -Full`, artifact upload) completes and uploads its logs | scheduled job on GitHub Actions; this host cannot run it; non-blocking | W0-ST | open | - |

## Planned checks without a feature row yet

Added to the ledger by the WP that writes the corresponding waiver:

- Real click on a toast notification activates and focuses the right workspace (spike S1,
  AF-4: the foreground grant of a real click cannot be simulated) - W3-7a.
- Per-monitor DPI change while connected over RDP; window, sidebar and web panels re-layout
  without blur - W1-8c.
- UAC: elevated wmux and a non-elevated CLI (and the reverse) refuse or relay as specified -
  W7-7 (diagnostics and `cmux sudo`).
- Snap layouts flyout on the maximize button of the custom titlebar - W7-10a.
