const std = @import("std");
const builtin = @import("builtin");
const Expr = @import("expr.zig").Expr;

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) da.allocator() else std.heap.smp_allocator;
    defer _ = da.deinit();
    const body = try allocator.create(Expr);
    body.* = Expr.initVar(0);

    const lambda = try allocator.create(Expr);
    lambda.* = Expr.initLam(body);
    defer lambda.deinit(allocator);

    const size = try lambda.sizeChecked();
    const hash = try lambda.hashChecked();

    std.debug.print("size={d} hash={d} valid={} acyclic={}\n", .{
        size,
        hash,
        lambda.isValid(),
        lambda.isAcyclic(),
    });
}
