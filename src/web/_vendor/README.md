# `src/web/_vendor`: third-party browser libraries

Web panels (ARCHITECTURE ADR-6.4) may use third-party JavaScript and CSS only
from this directory. The libraries are committed as prebuilt files, so building
wmux needs Zig and nothing else: there is no npm, bundler or Node step in
`zig build`. Pages load them by relative URL from the same origin, for example
`import { marked } from "../_vendor/marked@<version>/marked.esm.js";`. Nothing
is ever loaded from a CDN or the network; the panel CSP forbids it.

## License policy

wmux is MIT-licensed. Vendored code must be under one of these licenses, for
the library **and** for everything bundled into it:

| Allowed (SPDX) | Notes |
|---|---|
| `MIT` | |
| `BSD-2-Clause`, `BSD-3-Clause` | |
| `Apache-2.0` | keep the upstream `NOTICE` file next to `LICENSE` |
| `ISC` | |

A dual-licensed library qualifies when one of its options is on the list
(DOMPurify is `MPL-2.0 OR Apache-2.0`: use it under Apache-2.0 and record that
choice in `SOURCE.md`).

Not allowed: GPL, LGPL, AGPL, MPL-only, EPL, CC-BY-SA and other copyleft
licenses, "source available" or non-commercial licenses, and code without a
license. In particular nothing from cmux (GPL-3.0-or-later) may be copied,
adapted or vendored (ground rule G1). Any other license needs the lead
architect's written approval before the files land.

## Layout

One directory per library and exact version:

```
_vendor/
  README.md                this file (policy and inventory)
  <lib>@<version>/         e.g. marked@15.0.7, codemirror@6.0.1-bundle.1
    <files>                prebuilt bundles exactly as produced (ESM preferred)
    LICENSE                verbatim upstream license text(s), including the
                           licenses of every bundled dependency
    NOTICE                 only when upstream ships one (Apache-2.0)
    SOURCE.md              provenance, see below
    SHA256SUMS             sha256 of every other file in the directory
```

- `<lib>` is the upstream package name in lowercase with `/` replaced by `-`
  (`@codemirror/view` becomes `codemirror-view`). A bundle that combines several
  packages is named after its purpose and gets its own version suffix
  (`codemirror@6.0.1-bundle.1`).
- Prefer ES modules (`*.esm.js`, `*.mjs` renamed to `.js`; WebView2 serves
  `.js` with a JavaScript MIME type). UMD builds that only set a global are
  acceptable when no ESM build exists.
- Strip `//# sourceMappingURL=` comments (and do not ship source maps); keep
  license banners.
- Never edit vendored code. If a patch is unavoidable, add `PATCHES.md` with
  the diff and the reason, and say so in the inventory.
- `SHA256SUMS` uses the `sha256sum --text` format: `<64 lowercase hex>  <file>`
  (two spaces), one line per file, sorted by path, paths relative to the
  library directory. Pass `--text`: Git Bash's `sha256sum` otherwise writes
  binary-mode lines (`<hex> *<file>`).

`SOURCE.md` records: upstream project URL; package name and exact version;
upstream tag or commit; where the files came from (the npm tarball URL plus its
`dist.integrity`, or the exact build command with tool versions); the SPDX
license expression and the option chosen for dual licenses; the date; the WP
that added it.

## Requirements for libraries

- Works under the panel CSP: no `eval`, `new Function` or string timers
  (`unsafe-eval` is not allowed), no inline `<script>`. Libraries that inject
  `<style>` elements or `style="…"` attributes are blocked (styles fall under
  `default-src 'self'`, without `'unsafe-inline'`); prefer builds that use
  constructable stylesheets or a CSP nonce option, or document the CSP change
  in the owning panel. For vega, use the CSP-safe expression interpreter
  (`vega-interpreter`).
- Pages that enable Trusted Types need libraries that accept a policy
  (DOMPurify `RETURN_TRUSTED_TYPE`) or that avoid HTML sinks.
- No network access, telemetry, service workers or remote fonts.
- Large libraries (mermaid, vega) are imported lazily with `import()` from the
  panel that needs them.

## Adding or updating a library

1. Check the license of the exact version and of every dependency that ends up
   in the bundle (the bundle's license banner, `package.json` `license` fields,
   `npm ls --all` in the build directory). Stop if anything is outside the
   policy.
2. Produce the files offline in WSL or any machine with Node, from the pinned
   version: either copy the prebuilt ESM file from the npm tarball
   (`npm pack <pkg>@<version>`, then compare `dist.integrity` with
   `npm view <pkg>@<version> dist.integrity`), or bundle with a pinned esbuild:
   `npx esbuild@<ver> entry.js --bundle --format=esm --minify --legal-comments=inline --outfile=<lib>.js`.
3. Create a **new** directory `_vendor/<lib>@<new-version>/`; never change
   files of an existing version in place. Add the files, `LICENSE` (plus
   `NOTICE`), `SOURCE.md`, then generate `SHA256SUMS`:

   ```sh
   cd src/web/_vendor/<lib>@<version>
   find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum --text > SHA256SUMS
   ```

4. Point the panels at the new path and delete the old version directory in the
   same change once nothing imports it.
5. Update the inventory below.
6. Verify inside the library directory: `sha256sum -c SHA256SUMS` (Git Bash or
   WSL) or, in PowerShell,

   ```powershell
   Get-Content SHA256SUMS | ForEach-Object {
     $hash, $file = $_ -split '\s+\*?', 2
     if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLower() -ne $hash) { "MISMATCH $file" }
   }
   ```

   then open every panel that uses the library with `WMUX_WEB_DEVTOOLS=1`,
   check the console for CSP violations and errors, and run the panels' e2e
   suites.
7. Commit one library per commit, for example
   `build(web): vendor marked@15.0.7 [W4-1]`, with the license and the source
   in the commit body.

## Third-party notices

The About panel shows the bundled third-party notices
(`panel.about.notices`). Every `LICENSE` and `NOTICE` file under this
directory must be part of them; the native side collects them from the
installed `SHARE\wmux\web\_vendor\*\` directories together with the notices of
the native dependencies.

## Inventory

| Directory | License (SPDX) | Upstream | Entry file(s) | Used by | Added |
|---|---|---|---|---|---|
| none yet | | | | | |

Planned by ADR-6.4 (verify each license again when vendoring): marked (MIT),
DOMPurify (Apache-2.0 option), highlight.js (BSD-3-Clause), github-markdown-css
(MIT), mermaid (MIT, lazy), vega and vega-lite (BSD-3-Clause), CodeMirror 6
(MIT, prebuilt ESM bundle), and a permissively licensed diff renderer.
