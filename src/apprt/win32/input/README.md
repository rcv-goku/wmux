# input/ (layer)

KeyRouter, contexts, chords, AltGr handling, the actions registry and the
Ghostty binding interop. Populated by W0-A3 (`actions.zig`) and W1-5
(ARCHITECTURE.md ADR-1.1, ADR-8).

Dependency rule (ADR-1.2): features use the public types of this layer;
the layer never imports feature internals except through registries.
