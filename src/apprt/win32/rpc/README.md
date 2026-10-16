# rpc/ (layer)

The control plane (ARCHITECTURE.md ADR-3). Populated by W0-A1 (the legacy
server and protocol), W0-A3 (types, registry, facade) and W1-1 (the v2
server, router, dispatch, auth).

- `types.zig` (frozen): `Method`, `Ctx`, `Lane`, `Access`, `Origin`,
  `Deferred`, `LegacyCommand`, `TextVerb` (ADR-3.6). W1-1 owns the `Ctx`
  bodies. ADR-3.6 names both a field and a method of `Ctx` `params`; the
  raw object is `raw_params` (CCR W0-A3-1).
- `registry.zig` (frozen): aggregates every feature's `rpc_methods`,
  `legacy_commands` and `text_verbs` (features/manifest.zig order) with
  comptime duplicate checks; `legacyCommand` maps a parsed legacy command
  to its handler.
- `server/mod.zig`: the server facade App calls (`start`/`stop`); today
  it runs `server/legacy_pipe.zig` (`\.\pipe\wmux-ipc-<pid>`).
- `compat/legacy_json.zig`, `compat/legacy_targets.zig`: the legacy
  wmux-v1 JSON protocol and its target resolution (kept until wmux 2.0,
  ADR-3.7).

A test must never instantiate the app registries (`registry.app`, the
handler tables): the feature handlers reach the terminal teardown graph,
which pulls the GTK apprt into the test binary. Test the generic
`Registry(modules)` over test modules instead.
