const std = @import("std");
const Expr = @import("expr.zig").Expr;
const Config = @import("config.zig").Config;

const NodeInfo = struct {
    node: *Expr,
    binding_depth: u32,
};

/// Apply 1-3 random mutation operators to expr (in-place).
/// Ensures the result is always a valid expression.
pub fn mutate(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random, config: Config) !void {
    const num = rng.intRangeAtMost(u32, config.mutations_min, config.mutations_max);
    for (0..num) |_| {
        try mutateOnce(expr, allocator, rng, config);
    }
}

fn mutateOnce(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random, config: Config) !void {
    const roll = rng.intRangeLessThan(u32, 0, 100);
    if (roll < 25) {
        changeVarIndex(expr, rng);
    } else if (roll < 40) {
        try changeNodeType(expr, allocator, rng);
    } else if (roll < 55) {
        try subtreeReplace(expr, allocator, rng, config);
    } else if (roll < 70) {
        try lambdaWrap(expr, allocator, rng);
    } else if (roll < 80) {
        try appWrap(expr, allocator, rng);
    } else if (roll < 90) {
        try subtreeDup(expr, allocator, rng);
    } else {
        subtreeDelete(expr, allocator, rng);
    }
    try clampIndices(expr, 0, allocator);
}

// ============================================================
// Mutation operators
// ============================================================

/// Select a random Var node and change its index to a random valid value.
fn changeVarIndex(expr: *Expr, rng: std.Random) void {
    const var_count = countVars(expr);
    if (var_count == 0) return;
    var target = rng.intRangeLessThan(u32, 0, var_count);
    const info = findNthVar(expr, &target, 0) orelse return;
    if (info.binding_depth == 0) return;
    info.node.* = Expr.initVar(rng.intRangeLessThan(u32, 0, info.binding_depth));
}

/// Replace a Var with Lam(Var(0)), a Lam with its body, or an App with one of its children.
fn changeNodeType(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random) !void {
    const node_count = expr.size();
    var target = rng.intRangeLessThan(u32, 0, node_count);
    const info = findNthNode(expr, &target, 0) orelse return;
    const node = info.node;

    switch (node.*) {
        .Var => {
            const body = try allocator.create(Expr);
            body.* = Expr.initVar(0);
            node.* = Expr.initLam(body);
        },
        .Lam => |body| {
            const body_val = body.*;
            allocator.destroy(body);
            node.* = body_val;
        },
        .App => |app| {
            if (rng.boolean()) {
                const keep = app.func.*;
                allocator.destroy(app.func);
                app.arg.deinit(allocator);
                node.* = keep;
            } else {
                const keep = app.arg.*;
                allocator.destroy(app.arg);
                app.func.deinit(allocator);
                node.* = keep;
            }
        },
    }
}

/// Replace a random subtree with a freshly generated expression of depth 1-3.
fn subtreeReplace(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random, config: Config) !void {
    const node_count = expr.size();
    var target = rng.intRangeLessThan(u32, 0, node_count);
    const info = findNthNode(expr, &target, 0) orelse return;
    const node = info.node;

    freeChildren(node, allocator);
    const depth = rng.intRangeAtMost(u32, 1, config.random_expr_max_depth);
    const new_expr = try Expr.initRandom(depth, 0, info.binding_depth, allocator, rng);
    node.* = new_expr.*;
    allocator.destroy(new_expr);
}

/// Wrap a random subtree S with Lam(S), shifting free variables in S up by 1.
fn lambdaWrap(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random) !void {
    const node_count = expr.size();
    var target = rng.intRangeLessThan(u32, 0, node_count);
    const info = findNthNode(expr, &target, 0) orelse return;
    const node = info.node;

    const inner = try allocator.create(Expr);
    inner.* = node.*;
    shiftInPlace(inner, 1, 0);
    node.* = Expr.initLam(inner);
}

/// Wrap a random subtree S with App(S, Var(0)) or App(Var(0), S).
fn appWrap(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random) !void {
    const node_count = expr.size();
    var target = rng.intRangeLessThan(u32, 0, node_count);
    const info = findNthNode(expr, &target, 0) orelse return;
    const node = info.node;

    const inner = try allocator.create(Expr);
    inner.* = node.*;

    const var0 = try allocator.create(Expr);
    errdefer allocator.destroy(var0);
    var0.* = Expr.initVar(0);

    if (rng.boolean()) {
        node.* = Expr.initArg(inner, var0);
    } else {
        node.* = Expr.initArg(var0, inner);
    }
}

/// Copy a random subtree and use it to replace a different random subtree.
fn subtreeDup(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random) !void {
    const node_count = expr.size();
    if (node_count < 2) return;

    // Pick source and deep copy it before modifying anything
    var src_idx = rng.intRangeLessThan(u32, 0, node_count);
    const src_info = findNthNode(expr, &src_idx, 0) orelse return;
    const copy = try Expr.deepCopy(src_info.node, allocator);
    errdefer copy.deinit(allocator);

    // Pick a different target
    var dst_idx = rng.intRangeLessThan(u32, 0, node_count - 1);
    const dst_info = findNthNode(expr, &dst_idx, 0) orelse {
        copy.deinit(allocator);
        return;
    };

    freeChildren(dst_info.node, allocator);
    dst_info.node.* = copy.*;
    allocator.destroy(copy);
}

/// Replace a random non-root subtree with Var(0).
fn subtreeDelete(expr: *Expr, allocator: std.mem.Allocator, rng: std.Random) void {
    const node_count = expr.size();
    if (node_count < 2) return;

    // Pick a non-root node (index 1..node_count-1)
    var target = rng.intRangeAtMost(u32, 1, node_count - 1);
    const info = findNthNode(expr, &target, 0) orelse return;

    freeChildren(info.node, allocator);
    info.node.* = Expr.initVar(0);
}

// ============================================================
// Helpers
// ============================================================

/// Find the Nth node in pre-order traversal, returning a mutable pointer and binding depth.
fn findNthNode(expr: *Expr, counter: *u32, depth: u32) ?NodeInfo {
    if (counter.* == 0) return .{ .node = expr, .binding_depth = depth };
    counter.* -= 1;
    return switch (expr.*) {
        .Var => null,
        .Lam => |body| findNthNode(body, counter, depth + 1),
        .App => |app| findNthNode(app.func, counter, depth) orelse
            findNthNode(app.arg, counter, depth),
    };
}

/// Find the Nth Var node in pre-order traversal.
fn findNthVar(expr: *Expr, counter: *u32, depth: u32) ?NodeInfo {
    switch (expr.*) {
        .Var => {
            if (counter.* == 0) return .{ .node = expr, .binding_depth = depth };
            counter.* -= 1;
            return null;
        },
        .Lam => |body| return findNthVar(body, counter, depth + 1),
        .App => |app| return findNthVar(app.func, counter, depth) orelse
            findNthVar(app.arg, counter, depth),
    }
}

fn countVars(expr: *const Expr) u32 {
    return switch (expr.*) {
        .Var => 1,
        .Lam => |body| countVars(body),
        .App => |app| countVars(app.func) + countVars(app.arg),
    };
}

/// Free an expression's children without freeing the node itself.
fn freeChildren(node: *Expr, allocator: std.mem.Allocator) void {
    switch (node.*) {
        .Var => {},
        .Lam => |body| body.deinit(allocator),
        .App => |app| {
            app.func.deinit(allocator);
            app.arg.deinit(allocator);
        },
    }
}

/// Shift free variable indices in-place. Free vars are those with index >= cutoff.
fn shiftInPlace(expr: *Expr, amount: i32, cutoff: u32) void {
    switch (expr.*) {
        .Var => |*v| {
            if (v.* >= cutoff) {
                const shifted = @as(i32, @intCast(v.*)) + amount;
                v.* = if (shifted >= 0) @intCast(shifted) else 0;
            }
        },
        .Lam => |body| shiftInPlace(body, amount, cutoff + 1),
        .App => |app| {
            shiftInPlace(app.func, amount, cutoff);
            shiftInPlace(app.arg, amount, cutoff);
        },
    }
}

/// Ensure all Var indices are valid (< binding_depth).
/// At depth 0, a bare Var is replaced with Lam(Var(0)).
fn clampIndices(node: *Expr, depth: u32, allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .Var => |*v| {
            if (depth == 0) {
                // No valid index exists; wrap in Lam(Var(0))
                const body = try allocator.create(Expr);
                body.* = Expr.initVar(0);
                node.* = Expr.initLam(body);
            } else if (v.* >= depth) {
                v.* = depth - 1;
            }
        },
        .Lam => |body| try clampIndices(body, depth + 1, allocator),
        .App => |app| {
            try clampIndices(app.func, depth, allocator);
            try clampIndices(app.arg, depth, allocator);
        },
    }
}

// ============================================================
// Tests
// ============================================================

const DEFAULT_CONFIG = Config{};

test "mutate always produces valid expressions" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    for (0..200) |_| {
        const expr = try Expr.initRandom(5, 0, 0, allocator, rng);
        defer expr.deinit(allocator);

        try mutate(expr, allocator, rng, DEFAULT_CONFIG);

        try std.testing.expect(expr.isValid());
        try std.testing.expect(expr.isAcyclic());
    }
}

test "mutate changes at least some expressions" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();

    var changed: u32 = 0;
    const trials: u32 = 100;

    for (0..trials) |_| {
        const expr = try Expr.initRandom(4, 0, 0, allocator, rng);
        const original_hash = expr.hash();

        try mutate(expr, allocator, rng, DEFAULT_CONFIG);
        const new_hash = expr.hash();

        if (original_hash != new_hash) changed += 1;

        expr.deinit(allocator);
    }

    // At least 50% should have changed
    try std.testing.expect(changed > trials / 2);
}

test "changeVarIndex produces valid expressions" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(77);
    const rng = prng.random();

    for (0..100) |_| {
        const expr = try Expr.initRandom(4, 0, 0, allocator, rng);
        defer expr.deinit(allocator);

        changeVarIndex(expr, rng);
        try clampIndices(expr, 0, allocator);
        try std.testing.expect(expr.isValid());
    }
}

test "lambdaWrap increases tree size" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(55);
    const rng = prng.random();

    const expr = try Expr.initRandom(3, 0, 0, allocator, rng);
    defer expr.deinit(allocator);

    const old_size = expr.size();
    try lambdaWrap(expr, allocator, rng);
    try clampIndices(expr, 0, allocator);

    try std.testing.expect(expr.size() > old_size);
    try std.testing.expect(expr.isValid());
}

test "subtreeDelete produces valid expressions" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(33);
    const rng = prng.random();

    for (0..100) |_| {
        const expr = try Expr.initRandom(5, 0, 0, allocator, rng);
        defer expr.deinit(allocator);

        subtreeDelete(expr, allocator, rng);
        try clampIndices(expr, 0, allocator);
        try std.testing.expect(expr.isValid());
    }
}

test "clampIndices fixes bare Var at depth 0" {
    const allocator = std.testing.allocator;

    // Create a bare Var(0) — invalid at root
    const expr = try allocator.create(Expr);
    expr.* = Expr.initVar(0);
    defer expr.deinit(allocator);

    try clampIndices(expr, 0, allocator);

    // Should now be Lam(Var(0))
    try std.testing.expect(expr.isValid());
    try std.testing.expect(expr.* == .Lam);
}

test "clampIndices clamps out-of-range index" {
    const allocator = std.testing.allocator;

    // Lam(Var(5)) — index 5 is out of range (max valid is 0)
    const body = try allocator.create(Expr);
    body.* = Expr.initVar(5);
    const expr = try allocator.create(Expr);
    expr.* = Expr.initLam(body);
    defer expr.deinit(allocator);

    try clampIndices(expr, 0, allocator);

    try std.testing.expect(expr.isValid());
    // Body should now be Var(0)
    try std.testing.expectEqual(@as(u32, 0), expr.*.Lam.*.Var);
}
