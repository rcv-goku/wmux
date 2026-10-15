# ui/ (layer)

Top-level window chrome: `Window.zig`, tab bars, sidebars, overlays, menus,
rename, placement. Populated by W0-A2 (ARCHITECTURE.md ADR-1.1, ADR-1.8).

Dependency rule (ADR-1.2): features use the public types of this layer;
the layer never imports feature internals except through registries.
