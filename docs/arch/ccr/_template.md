---
id: W2-7-1                   # <wp>-<n>; the file is docs/arch/ccr/<wp>-<n>.md (n = 1, 2, ... per WP)
wp: W2-7                     # requesting work package
title: Palette entry point in ui/Window.zig
status: proposed             # proposed | folded | scheduled | rejected | done
files:                       # frozen, layer or proto files outside the requesting WP's spec (ADR-1.7)
  - path: src/apprt/win32/ui/Window.zig
    class: frozen            # frozen | layer | proto
    owner: none              # this wave's owner of the file per the section 14 hot-file table, or none
stub: features/palette/api.zig open() is a no-op until the facade exists   # how the WP ships meanwhile
decision:                    # filled in by the integrator
  outcome: ""                # folded into <wp> | scheduled for wave <n> | rejected: <why>
  by: ""
  date: ""
---

## What
The exact change: files, declarations, call sites. One CCR per coherent change.

## Why
Which covered feature ids need it and why no owned file or extension point (registries,
`ext` state, events, `app.tasks`, `app.timers`, menu builder, hooks) can do the job (G8).

## Exact diff sketch
```diff
--- a/src/apprt/win32/ui/Window.zig
+++ b/src/apprt/win32/ui/Window.zig
@@
+    // CCR W2-7-1: one-line facade, body lives in the feature
+    pub fn openPalette(self: *Window) void {
+        features.palette.api.open(self);
+    }
```

## Stub until merged
What the WP ships behind the stub, and the follow-up once the change lands
(tests to enable, `# manual:` waivers to drop).

## Impact and risks
Other WPs or features affected, merge-order constraints, behavior change for users.
