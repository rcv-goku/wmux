# model/ (layer)

Window-independent object model: `Workspace`, `Group`, `Pane`, `Tab`,
`TabContent`, handles/registry, layout, `ops/*` mutators and the event bus.
Populated by W0-A2/W0-A3 (ARCHITECTURE.md ADR-1.1, ADR-1.8).

Dependency rule (ADR-1.2): may import `platform/`, `features/ext.zig` and
`wmux_proto`; never `ui/`, `rpc/`, `web/` or feature internals.
