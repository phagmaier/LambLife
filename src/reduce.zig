const std = @import("std");
const Expr = @import("expr.zig").Expr;

pub const ReductionResult = struct {
    expr: *Expr,
    steps: u32,
    hit_size_limit: bool = false,
    hit_step_limit: bool = false,
};

/// Shift all free variables in `expr` by `amount`.
/// Free variables are those with index >= cutoff.
/// Returns a newly allocated expression tree — caller owns it.
pub fn shift(expr: *const Expr, amount: i32, cutoff: u32, allocator: std.mem.Allocator) !*Expr {
    const result = try allocator.create(Expr);
    errdefer allocator.destroy(result);

    result.* = switch (expr.*) {
        .Var => |n| blk: {
            if (n >= cutoff) {
                // Cast to i32, add amount, cast back. The caller must ensure this doesn't underflow.
                const shifted: i32 = @as(i32, @intCast(n)) + amount;
                break :blk Expr.initVar(@intCast(shifted));
            } else {
                break :blk Expr.initVar(n);
            }
        },
        .Lam => |body| blk: {
            const new_body = try shift(body, amount, cutoff + 1, allocator);
            break :blk Expr.initLam(new_body);
        },
        .App => |app| blk: {
            const new_func = try shift(app.func, amount, cutoff, allocator);
            errdefer new_func.deinit(allocator);
            const new_arg = try shift(app.arg, amount, cutoff, allocator);
            break :blk Expr.initArg(new_func, new_arg);
        },
    };
    return result;
}

/// Substitute `replacement` for Var(target) in `expr`.
/// Returns a newly allocated expression tree — caller owns it.
/// The `replacement` is NOT consumed; it is deep-copied where needed.
pub fn substitute(expr: *const Expr, target: u32, replacement: *const Expr, allocator: std.mem.Allocator) !*Expr {
    return substituteWithShift(expr, target, replacement, 0, 0, allocator);
}

fn substituteWithShift(
    expr: *const Expr,
    target: u32,
    replacement: *const Expr,
    depth: u32,
    replacement_base_shift: i32,
    allocator: std.mem.Allocator,
) !*Expr {
    const result = try allocator.create(Expr);
    errdefer allocator.destroy(result);

    result.* = switch (expr.*) {
        .Var => |n| blk: {
            if (n == target + depth) {
                const total_shift: i32 = replacement_base_shift + @as(i32, @intCast(depth));
                const shifted = try shift(replacement, total_shift, 0, allocator);
                const val = shifted.*;
                allocator.destroy(shifted);
                break :blk val;
            } else {
                break :blk Expr.initVar(n);
            }
        },
        .Lam => |body| blk: {
            const new_body = try substituteWithShift(body, target, replacement, depth + 1, replacement_base_shift, allocator);
            break :blk Expr.initLam(new_body);
        },
        .App => |app| blk: {
            const new_func = try substituteWithShift(app.func, target, replacement, depth, replacement_base_shift, allocator);
            errdefer new_func.deinit(allocator);
            const new_arg = try substituteWithShift(app.arg, target, replacement, depth, replacement_base_shift, allocator);
            break :blk Expr.initArg(new_func, new_arg);
        },
    };
    return result;
}

/// Perform a single beta reduction step on a top-level redex: App(Lam(body), arg).
/// Returns a newly allocated result. Caller owns it. The input is NOT freed.
pub fn betaStep(func_body: *const Expr, arg: *const Expr, allocator: std.mem.Allocator) !*Expr {
    // Substitute the argument as if it had already been shifted up by 1 when
    // moving under the removed binder, without materializing that shifted tree.
    const substituted = try substituteWithShift(func_body, 0, arg, 0, 1, allocator);
    defer substituted.deinit(allocator);

    // Shift result down by 1 (the outer binder is gone)
    return shift(substituted, -1, 0, allocator);
}

/// Try to reduce one redex in normal order (leftmost-outermost first).
/// Returns a newly allocated expression if a reduction occurred, or null if
/// the expression is already in normal form.
/// The input expression is NOT freed.
pub fn reduceOne(expr: *const Expr, allocator: std.mem.Allocator) !?*Expr {
    switch (expr.*) {
        .App => |app| {
            // Check for top-level redex: App(Lam(body), arg)
            if (app.func.* == .Lam) {
                const body = app.func.*.Lam;
                return try betaStep(body, app.arg, allocator);
            }

            // Try reducing the function position first (leftmost-outermost)
            if (try reduceOne(app.func, allocator)) |reduced_func| {
                errdefer reduced_func.deinit(allocator);
                const new_arg = try Expr.deepCopy(app.arg, allocator);
                const result = try allocator.create(Expr);
                result.* = Expr.initArg(reduced_func, new_arg);
                return result;
            }

            // Then try reducing the argument
            if (try reduceOne(app.arg, allocator)) |reduced_arg| {
                errdefer reduced_arg.deinit(allocator);
                const new_func = try Expr.deepCopy(app.func, allocator);
                const result = try allocator.create(Expr);
                result.* = Expr.initArg(new_func, reduced_arg);
                return result;
            }

            // No redex found anywhere
            return null;
        },
        .Lam => |body| {
            // Reduce under the lambda
            if (try reduceOne(body, allocator)) |reduced_body| {
                const result = try allocator.create(Expr);
                result.* = Expr.initLam(reduced_body);
                return result;
            }
            return null;
        },
        .Var => return null,
    }
}

/// Check if an expression is in normal form (no beta-redex exists anywhere).
pub fn isNormalForm(expr: *const Expr) bool {
    switch (expr.*) {
        .App => |app| {
            // Top-level redex?
            if (app.func.* == .Lam) return false;
            // Redex nested in func or arg?
            return isNormalForm(app.func) and isNormalForm(app.arg);
        },
        .Lam => |body| return isNormalForm(body),
        .Var => return true,
    }
}

/// Fully reduce an expression with step and size limits.
/// Returns the (possibly partially) reduced expression and number of steps taken.
/// The returned expression is always newly allocated. The input is NOT freed.
pub fn reduce(expr: *const Expr, max_steps: u32, max_size: u32, allocator: std.mem.Allocator) !ReductionResult {
    var current = try Expr.deepCopy(expr, allocator);
    var steps_taken: u32 = 0;

    while (steps_taken < max_steps) {
        const maybe_next = try reduceOne(current, allocator);

        if (maybe_next) |next| {
            // Check size limit before accepting the reduction
            const next_size = next.size();
            if (next_size > max_size) {
                // Size limit hit — discard the new expression, return current
                next.deinit(allocator);
                return .{ .expr = current, .steps = steps_taken, .hit_size_limit = true };
            }

            // Accept the reduction
            current.deinit(allocator);
            current = next;
            steps_taken += 1;
        } else {
            // Normal form reached
            break;
        }
    }

    return .{
        .expr = current,
        .steps = steps_taken,
        .hit_step_limit = steps_taken == max_steps,
    };
}

/// Reduce using shared untouched subtrees instead of fully-owned copies.
/// This is intended for short-lived arena-backed evaluation where the result
/// does not outlive the input expressions and all temporary memory can be
/// released in bulk.
pub fn reduceShared(expr: *Expr, max_steps: u32, max_size: u32, allocator: std.mem.Allocator) !ReductionResult {
    var current = expr;
    var steps_taken: u32 = 0;

    while (steps_taken < max_steps) {
        const maybe_next = try reduceOneShared(current, allocator);

        if (maybe_next) |next| {
            const next_size = next.size();
            if (next_size > max_size) {
                return .{
                    .expr = current,
                    .steps = steps_taken,
                    .hit_size_limit = true,
                };
            }

            current = next;
            steps_taken += 1;
        } else {
            break;
        }
    }

    return .{
        .expr = current,
        .steps = steps_taken,
        .hit_step_limit = steps_taken == max_steps,
    };
}

fn reduceOneShared(expr: *const Expr, allocator: std.mem.Allocator) !?*Expr {
    switch (expr.*) {
        .App => |app| {
            if (app.func.* == .Lam) {
                const body = app.func.*.Lam;
                return try betaStep(body, app.arg, allocator);
            }

            if (try reduceOneShared(app.func, allocator)) |reduced_func| {
                const result = try allocator.create(Expr);
                result.* = Expr.initArg(reduced_func, app.arg);
                return result;
            }

            if (try reduceOneShared(app.arg, allocator)) |reduced_arg| {
                const result = try allocator.create(Expr);
                result.* = Expr.initArg(app.func, reduced_arg);
                return result;
            }

            return null;
        },
        .Lam => |body| {
            if (try reduceOneShared(body, allocator)) |reduced_body| {
                const result = try allocator.create(Expr);
                result.* = Expr.initLam(reduced_body);
                return result;
            }
            return null;
        },
        .Var => return null,
    }
}

// ============================================================
// Tests
// ============================================================

fn makeVar(allocator: std.mem.Allocator, n: u32) !*Expr {
    const e = try allocator.create(Expr);
    e.* = Expr.initVar(n);
    return e;
}

fn makeLam(allocator: std.mem.Allocator, body: *Expr) !*Expr {
    const e = try allocator.create(Expr);
    e.* = Expr.initLam(body);
    return e;
}

fn makeApp(allocator: std.mem.Allocator, func: *Expr, arg: *Expr) !*Expr {
    const e = try allocator.create(Expr);
    e.* = Expr.initArg(func, arg);
    return e;
}

/// Helper: check structural equality of two expressions.
fn exprEqual(a: *const Expr, b: *const Expr) bool {
    return switch (a.*) {
        .Var => |va| switch (b.*) {
            .Var => |vb| va == vb,
            else => false,
        },
        .Lam => |la| switch (b.*) {
            .Lam => |lb| exprEqual(la, lb),
            else => false,
        },
        .App => |aa| switch (b.*) {
            .App => |ab| exprEqual(aa.func, ab.func) and exprEqual(aa.arg, ab.arg),
            else => false,
        },
    };
}

test "shift — free variables shifted, bound variables left alone" {
    const allocator = std.testing.allocator;

    // Lam(App(Var(0), Var(1)))  — Var(0) is bound, Var(1) is free
    const v0 = try makeVar(allocator, 0);
    const v1 = try makeVar(allocator, 1);
    const app = try makeApp(allocator, v0, v1);
    const lam = try makeLam(allocator, app);
    defer lam.deinit(allocator);

    // shift by +1, cutoff 0: free vars (≥0 at top level, but we're looking through binders)
    const shifted = try shift(lam, 1, 0, allocator);
    defer shifted.deinit(allocator);

    // Expected: Lam(App(Var(0), Var(2)))  — bound var unchanged, free var incremented
    const ev0 = try makeVar(allocator, 0);
    const ev2 = try makeVar(allocator, 2);
    const eapp = try makeApp(allocator, ev0, ev2);
    const expected = try makeLam(allocator, eapp);
    defer expected.deinit(allocator);

    try std.testing.expect(exprEqual(shifted, expected));
}

test "beta — identity applied to argument" {
    const allocator = std.testing.allocator;

    // (λx.x) y  =>  y
    // App(Lam(Var(0)), Var(0))  =>  Var(0)
    const body = try makeVar(allocator, 0);
    const id = try makeLam(allocator, body);
    const arg = try makeVar(allocator, 0);
    const app = try makeApp(allocator, id, arg);
    defer app.deinit(allocator);

    const result = try reduceOne(app, allocator);
    try std.testing.expect(result != null);
    defer result.?.deinit(allocator);

    const expected = try makeVar(allocator, 0);
    defer expected.deinit(allocator);
    try std.testing.expect(exprEqual(result.?, expected));
}

test "beta — constant function" {
    const allocator = std.testing.allocator;

    // (λx.λy.x) z  =>  λy.z
    // App(Lam(Lam(Var(1))), Var(0))  =>  Lam(Var(0))
    // Note: after substitution Var(0)->Var(0) for x in Lam(Var(1)), we get Lam(Var(0))
    // Wait let me think more carefully...
    // body = Lam(Var(1))  (x is Var(1) inside the inner lambda since there's one binder above)
    // arg = Var(0)
    // beta_step(Lam(Var(1)), Var(0)):
    //   shifted_arg = shift(Var(0), 1, 0) = Var(1)
    //   substituted = substitute(Lam(Var(1)), 0, Var(1))
    //     = Lam(substitute(Var(1), 1, shift(Var(1), 1, 0)))
    //     = Lam(substitute(Var(1), 1, Var(2)))
    //     Var(1) == target 1? yes => Var(2)
    //     = Lam(Var(2))
    //   result = shift(Lam(Var(2)), -1, 0) = Lam(Var(1))
    // Hmm, that gives Lam(Var(1)) which is λy.x where x is a free variable.
    // Actually if arg=Var(0) refers to a free variable in the outer context,
    // then (λx.λy.x) free_0 = λy.free_0 = Lam(Var(1)) — Var(1) is free, pointing past the λy binder.
    // That's correct! Var(1) inside one lambda means "one past the binder" = free var 0.

    const inner_body = try makeVar(allocator, 1);
    const inner_lam = try makeLam(allocator, inner_body);
    const outer_lam = try makeLam(allocator, inner_lam);
    const arg = try makeVar(allocator, 0);
    const app = try makeApp(allocator, outer_lam, arg);
    defer app.deinit(allocator);

    const result = try reduceOne(app, allocator);
    try std.testing.expect(result != null);
    defer result.?.deinit(allocator);

    // Expected: Lam(Var(1))
    const ev1 = try makeVar(allocator, 1);
    const expected = try makeLam(allocator, ev1);
    defer expected.deinit(allocator);
    try std.testing.expect(exprEqual(result.?, expected));
}

test "reduce — identity is already normal form" {
    const allocator = std.testing.allocator;

    // Lam(Var(0)) is already in normal form
    const body = try makeVar(allocator, 0);
    const id = try makeLam(allocator, body);
    defer id.deinit(allocator);

    const result = try reduce(id, 200, 500, allocator);
    defer result.expr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.steps);
    try std.testing.expect(exprEqual(result.expr, id));
}

test "reduce — (λx.x)(λy.y) reduces to λy.y in one step" {
    const allocator = std.testing.allocator;

    const body1 = try makeVar(allocator, 0);
    const id1 = try makeLam(allocator, body1);
    const body2 = try makeVar(allocator, 0);
    const id2 = try makeLam(allocator, body2);
    const app = try makeApp(allocator, id1, id2);
    defer app.deinit(allocator);

    const result = try reduce(app, 200, 500, allocator);
    defer result.expr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.steps);

    const expected_body = try makeVar(allocator, 0);
    const expected = try makeLam(allocator, expected_body);
    defer expected.deinit(allocator);
    try std.testing.expect(exprEqual(result.expr, expected));
}

test "reduce — omega combinator hits step limit" {
    const allocator = std.testing.allocator;

    // ω = λx. x x = Lam(App(Var(0), Var(0)))
    // Ω = ω ω = App(ω, ω) — reduces to itself forever
    const v0a = try makeVar(allocator, 0);
    const v0b = try makeVar(allocator, 0);
    const self_app = try makeApp(allocator, v0a, v0b);
    const omega = try makeLam(allocator, self_app);

    const omega2 = try Expr.deepCopy(omega, allocator);
    const big_omega = try makeApp(allocator, omega, omega2);
    defer big_omega.deinit(allocator);

    const result = try reduce(big_omega, 10, 500, allocator);
    defer result.expr.deinit(allocator);

    // Should hit the step limit
    try std.testing.expectEqual(@as(u32, 10), result.steps);
}

test "reduce — size limit prevents growth" {
    const allocator = std.testing.allocator;

    // Create an expression that grows when reduced.
    // (λx. x x)(λx. x x) — this stays same size actually (it's Omega).
    // Instead use: (λx. x x x)(λx. x x x) which grows.
    // App(Var(0), App(Var(0), Var(0))) for the body: x(x x)
    const v0a = try makeVar(allocator, 0);
    const v0b = try makeVar(allocator, 0);
    const v0c = try makeVar(allocator, 0);
    const inner = try makeApp(allocator, v0b, v0c);
    const body_app = try makeApp(allocator, v0a, inner);
    const lam1 = try makeLam(allocator, body_app);

    const v0d = try makeVar(allocator, 0);
    const v0e = try makeVar(allocator, 0);
    const v0f = try makeVar(allocator, 0);
    const inner2 = try makeApp(allocator, v0e, v0f);
    const body_app2 = try makeApp(allocator, v0d, inner2);
    const lam2 = try makeLam(allocator, body_app2);

    const app = try makeApp(allocator, lam1, lam2);
    defer app.deinit(allocator);

    // With a very tight size limit, it should stop growing
    const result = try reduce(app, 200, 15, allocator);
    defer result.expr.deinit(allocator);

    // Should have stopped before 200 steps due to size limit
    try std.testing.expect(result.steps < 200);
    try std.testing.expect(result.expr.size() <= 15);
}

test "reduce — Church numeral application" {
    const allocator = std.testing.allocator;

    // Church numeral 2 applied to identity should reduce to identity
    // 2 = λf.λx. f(f x) = Lam(Lam(App(Var(1), App(Var(1), Var(0)))))
    // 2 id = λx. id(id x) => λx. x

    // Build Church 2
    const c2_v0 = try makeVar(allocator, 0);
    const c2_v1a = try makeVar(allocator, 1);
    const c2_inner_app = try makeApp(allocator, c2_v1a, c2_v0);
    const c2_v1b = try makeVar(allocator, 1);
    const c2_outer_app = try makeApp(allocator, c2_v1b, c2_inner_app);
    const c2_inner_lam = try makeLam(allocator, c2_outer_app);
    const church2 = try makeLam(allocator, c2_inner_lam);

    // Build identity
    const id_body = try makeVar(allocator, 0);
    const identity = try makeLam(allocator, id_body);

    // App(church2, identity)
    const app = try makeApp(allocator, church2, identity);
    defer app.deinit(allocator);

    const result = try reduce(app, 200, 500, allocator);
    defer result.expr.deinit(allocator);

    // Expected: λx.x = Lam(Var(0))
    const expected_body = try makeVar(allocator, 0);
    const expected = try makeLam(allocator, expected_body);
    defer expected.deinit(allocator);

    try std.testing.expect(exprEqual(result.expr, expected));
}

test "isNormalForm" {
    const allocator = std.testing.allocator;

    // Var is normal form
    const v = try makeVar(allocator, 0);
    defer v.deinit(allocator);
    try std.testing.expect(isNormalForm(v));

    // Lam(Var(0)) is normal form
    const lv = try makeVar(allocator, 0);
    const lam = try makeLam(allocator, lv);
    defer lam.deinit(allocator);
    try std.testing.expect(isNormalForm(lam));

    // App(Lam(Var(0)), Var(0)) is NOT normal form (it's a redex)
    const b = try makeVar(allocator, 0);
    const l = try makeLam(allocator, b);
    const a = try makeVar(allocator, 0);
    const app = try makeApp(allocator, l, a);
    defer app.deinit(allocator);
    try std.testing.expect(!isNormalForm(app));

    // App(Var(0), Var(1)) IS normal form (func is not a lambda)
    const av0 = try makeVar(allocator, 0);
    const av1 = try makeVar(allocator, 1);
    const app2 = try makeApp(allocator, av0, av1);
    defer app2.deinit(allocator);
    try std.testing.expect(isNormalForm(app2));
}
