//! Shared-appendable unit-test index of the CLI (AF-15, `merge=union`):
//! WPs add one sorted `_ = @import("...");` line per test file in the test
//! block (logic files here, and family test files such as
//! `../commands/config/tests.zig` that no WP-owned root imports). Name the
//! tests "unit: cli: <behavior>" (or "unit: cli-<family>: ..."). Imported by
//! the CLI test root (main.zig) since the W1 kickoff interface commit
//! (W1-IF).

test {}
