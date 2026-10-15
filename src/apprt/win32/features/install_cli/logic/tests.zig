//! Unit-test index of feature `install_cli` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: install_cli: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {}
