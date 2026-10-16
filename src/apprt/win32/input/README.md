# input/ (layer)

KeyRouter, contexts, chords, AltGr handling, the actions registry and the
Ghostty binding interop (ARCHITECTURE.md ADR-1.1, ADR-8). Populated by
W0-A3 (`actions.zig`) and W1-5.

- `actions.zig` (frozen): joins `wmux_proto/actions_catalog.zig` with the
  `action_handlers` every feature declares (`features/<id>/actions.zig`,
  `[]const ActionHandler`); an unknown id, an alias or two handlers for
  one action fail the build. `invoke` runs the action of a Ghostty
  `wmux:<id>[:<arg>]` binding (the apprt `wmux_action`, forwarded by
  app/perform_action.zig) and reports whether it ran.

Dependency rule (ADR-1.2): features use the public types of this layer;
the layer never imports feature internals except through registries.
