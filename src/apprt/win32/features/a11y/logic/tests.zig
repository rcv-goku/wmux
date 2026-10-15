//! Unit-test index of feature `a11y` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: a11y: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {}
