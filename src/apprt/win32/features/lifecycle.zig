//! Feature lifecycle fan-out [frozen] (ADR-1.3, ADR-1.4): calls the optional
//! `init`, `deinit`, `onEvent` and `onSettingsChanged` hooks of every feature
//! in manifest order (`deinit` in reverse). Parameters are `anytype` so this
//! file does not import App.zig; features declare the ADR-1.3 signatures:
//!
//!     pub fn init(app: *App) !void
//!     pub fn deinit(app: *App) void
//!     pub fn onEvent(app: *App, ev: *const model.Event) void
//!     pub fn onSettingsChanged(app: *App, diff: *const settings.Diff) void
const std = @import("std");
const ext = @import("ext.zig");
const manifest = @import("manifest.zig");

/// Initializes every feature in manifest order. When an `init` fails, the
/// features before it are deinitialized in reverse order and the error is
/// returned.
pub fn init(app: anytype) !void {
    return initModules(manifest.modules, app);
}

/// Deinitializes every feature in reverse manifest order.
pub fn deinit(app: anytype) void {
    deinitModules(manifest.modules, manifest.modules.len, app);
}

/// Forwards a model event to every feature (UI thread, after the mutation).
pub fn onEvent(app: anytype, ev: anytype) void {
    onEventModules(manifest.modules, app, ev);
}

/// Forwards a settings diff to every feature after a settings reload.
pub fn onSettingsChanged(app: anytype, diff: anytype) void {
    onSettingsChangedModules(manifest.modules, app, diff);
}

fn initModules(comptime modules: anytype, app: anytype) !void {
    inline for (modules, 0..) |m, i| {
        if (comptime @hasDecl(m, "init")) {
            m.init(app) catch |err| {
                deinitModules(modules, i, app);
                return err;
            };
        }
    }
}

/// Deinitializes the first `count` modules, last one first.
fn deinitModules(comptime modules: anytype, comptime count: usize, app: anytype) void {
    comptime var i: usize = count;
    inline while (i > 0) {
        i -= 1;
        const m = modules[i];
        if (comptime @hasDecl(m, "deinit")) m.deinit(app);
    }
}

fn onEventModules(comptime modules: anytype, app: anytype, ev: anytype) void {
    inline for (modules) |m| {
        if (comptime @hasDecl(m, "onEvent")) m.onEvent(app, ev);
    }
}

fn onSettingsChangedModules(comptime modules: anytype, app: anytype, diff: anytype) void {
    inline for (modules) |m| {
        if (comptime @hasDecl(m, "onSettingsChanged")) m.onSettingsChanged(app, diff);
    }
}

// The manifest and every ext struct must list the same feature ids: the
// manifest rejects duplicates, so equal counts plus one field per id make
// them a bijection.
comptime {
    @setEvalBranchQuota(1_000_000);
    for ([_]type{ ext.AppExt, ext.WindowExt, ext.WorkspaceExt, ext.PaneExt, ext.TabExt }) |Ext| {
        const fields = @typeInfo(Ext).@"struct".fields;
        if (fields.len != manifest.modules.len) @compileError(std.fmt.comptimePrint(
            "features/ext.zig: {s} has {d} fields but features/manifest.zig lists {d} modules",
            .{ @typeName(Ext), fields.len, manifest.modules.len },
        ));
        for (0..manifest.modules.len) |i| {
            const id = manifest.modules[i].id;
            if (!@hasField(Ext, id)) {
                @compileError("features/ext.zig: " ++ @typeName(Ext) ++ " has no field for feature '" ++ id ++ "'");
            }
        }
    }
}

const Trace = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    fn add(self: *Trace, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn str(self: *const Trace) []const u8 {
        return self.buf[0..self.len];
    }
};

test "unit: features: lifecycle runs declared hooks in order and deinit in reverse" {
    const A = struct {
        pub fn init(t: *Trace) !void {
            t.add('a');
        }
        pub fn deinit(t: *Trace) void {
            t.add('A');
        }
    };
    const B = struct {};
    const C = struct {
        pub fn init(t: *Trace) !void {
            t.add('c');
        }
        pub fn deinit(t: *Trace) void {
            t.add('C');
        }
    };
    const modules = .{ A, B, C };

    var t: Trace = .{};
    try initModules(modules, &t);
    deinitModules(modules, modules.len, &t);
    try std.testing.expectEqualStrings("acCA", t.str());
}

test "unit: features: lifecycle init failure deinitializes earlier features in reverse" {
    const A = struct {
        pub fn init(t: *Trace) !void {
            t.add('a');
        }
        pub fn deinit(t: *Trace) void {
            t.add('A');
        }
    };
    const B = struct {
        pub fn deinit(t: *Trace) void {
            t.add('B');
        }
    };
    const Failing = struct {
        pub fn init(t: *Trace) !void {
            t.add('f');
            return error.InitFailed;
        }
        pub fn deinit(t: *Trace) void {
            t.add('F');
        }
    };
    const D = struct {
        pub fn init(t: *Trace) !void {
            t.add('d');
        }
    };

    var t: Trace = .{};
    try std.testing.expectError(error.InitFailed, initModules(.{ A, B, Failing, D }, &t));
    try std.testing.expectEqualStrings("afBA", t.str());
}

test "unit: features: lifecycle forwards events and settings diffs in order" {
    const A = struct {
        pub fn onEvent(t: *Trace, ev: u8) void {
            t.add(ev);
        }
    };
    const B = struct {
        pub fn onEvent(t: *Trace, ev: u8) void {
            t.add(ev + 1);
        }
        pub fn onSettingsChanged(t: *Trace, diff: u8) void {
            t.add(diff);
        }
    };
    const modules = .{ A, B };

    var t: Trace = .{};
    onEventModules(modules, &t, 'x');
    onSettingsChangedModules(modules, &t, 's');
    try std.testing.expectEqualStrings("xys", t.str());
}
