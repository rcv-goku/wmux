//! Unit-test index of feature `auto_naming` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: auto_naming: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {}
