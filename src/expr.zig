const std = @import("std");

//Did not check for memory leak when going through all the reduction steps
//I wrote it quickly and it was sloppy so i'm pretty sure it's either wrong
//or has a massive memory leak or at the very least a memory problem
//Even if it doesn't it's innefficient as shit and don't know how to fix that
//I guess I could give each expr it's own arena but that would have it's own problems
//this is just bad code I'm pretty sure

const Error = error{CycleDetected} || std.mem.Allocator.Error;

pub const Expr = union(enum) {
    Var: u32,
    Lam: *Expr,
    App: struct {
        func: *Expr,
        arg: *Expr,
    },
    //Might want to change all of these to expect a allocator and dynamically crate but this is fine
    //for now and still workable in either solution just means have to allocate elsewhere
    pub fn initVar(v: u32) Expr {
        return .{ .Var = v };
    }
    pub fn initLam(l: *Expr) Expr {
        return .{ .Lam = l };
    }
    pub fn initArg(f: *Expr, a: *Expr) Expr {
        return .{ .App = .{ .func = f, .arg = a } };
    }

    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        self.deinitChecked(allocator) catch @panic("cycle detected while deinitializing Expr");
    }

    pub fn deepCopy(expr: *const Expr, allocator: std.mem.Allocator) !*Expr {
        return expr.deepCopyChecked(allocator);
    }

    pub fn deepCopyChecked(expr: *const Expr, allocator: std.mem.Allocator) Error!*Expr {
        const new = try allocator.create(Expr);
        errdefer allocator.destroy(new);
        new.* = try expr.deepCopyImpl(allocator, null);
        return new;
    }

    pub fn size(self: *const Expr) u32 {
        return self.sizeChecked() catch @panic("cycle detected while computing Expr.size");
    }

    pub fn sizeChecked(self: *const Expr) Error!u32 {
        return self.sizeImpl(null);
    }

    pub fn isValid(self: *const Expr) bool {
        return self.isValidAtDepth(0);
    }

    pub fn isAcyclic(self: *const Expr) bool {
        return self.checkAcyclic(null) catch false;
    }

    fn isValidAtDepth(self: *const Expr, depth: u32) bool {
        return switch (self.*) {
            .Lam => |expr| expr.isValidAtDepth(depth + 1),
            .App => |app| app.func.isValidAtDepth(depth) and app.arg.isValidAtDepth(depth),
            .Var => |v| v < depth,
        };
    }

    pub fn hash(self: *const Expr) u64 {
        return self.hashChecked() catch @panic("cycle detected while hashing Expr");
    }

    pub fn hashChecked(self: *const Expr) Error!u64 {
        var hasher = std.hash.Wyhash.init(0);
        try self.hashInto(&hasher, null);
        return hasher.final();
    }

    const Visit = struct {
        expr: *const Expr,
        parent: ?*const Visit,

        fn contains(visit: *const Visit, expr: *const Expr) bool {
            var current: ?*const Visit = visit;
            while (current) |node| {
                if (node.expr == expr) return true;
                current = node.parent;
            }
            return false;
        }
    };

    fn pushVisit(expr: *const Expr, parent: ?*const Visit) Error!Visit {
        if (parent) |visit| {
            if (visit.contains(expr)) return error.CycleDetected;
        }
        return .{
            .expr = expr,
            .parent = parent,
        };
    }

    fn deinitChecked(self: *Expr, allocator: std.mem.Allocator) Error!void {
        try self.deinitImpl(allocator, null);
    }

    fn deinitImpl(self: *Expr, allocator: std.mem.Allocator, parent: ?*const Visit) Error!void {
        const visit = try pushVisit(self, parent);
        switch (self.*) {
            .Var => allocator.destroy(self),
            .Lam => |expr| {
                try expr.deinitImpl(allocator, &visit);
                allocator.destroy(self);
            },
            .App => |app| {
                try app.func.deinitImpl(allocator, &visit);
                try app.arg.deinitImpl(allocator, &visit);
                allocator.destroy(self);
            },
        }
    }

    fn deepCopyImpl(expr: *const Expr, allocator: std.mem.Allocator, parent: ?*const Visit) Error!Expr {
        const visit = try pushVisit(expr, parent);
        return switch (expr.*) {
            .Var => |v| .{ .Var = v },
            .Lam => |body| .{
                .Lam = blk: {
                    const copied = try allocator.create(Expr);
                    errdefer allocator.destroy(copied);
                    copied.* = try body.deepCopyImpl(allocator, &visit);
                    break :blk copied;
                },
            },
            .App => |app| .{
                .App = .{
                    .func = blk: {
                        const copied = try allocator.create(Expr);
                        errdefer allocator.destroy(copied);
                        copied.* = try app.func.deepCopyImpl(allocator, &visit);
                        break :blk copied;
                    },
                    .arg = blk: {
                        const copied = try allocator.create(Expr);
                        errdefer allocator.destroy(copied);
                        copied.* = try app.arg.deepCopyImpl(allocator, &visit);
                        break :blk copied;
                    },
                },
            },
        };
    }

    fn sizeImpl(self: *const Expr, parent: ?*const Visit) Error!u32 {
        const visit = try pushVisit(self, parent);
        return switch (self.*) {
            .Var => 1,
            .Lam => |expr| 1 + try expr.sizeImpl(&visit),
            .App => |app| 1 + try app.func.sizeImpl(&visit) + try app.arg.sizeImpl(&visit),
        };
    }

    fn checkAcyclic(self: *const Expr, parent: ?*const Visit) Error!bool {
        const visit = try pushVisit(self, parent);
        return switch (self.*) {
            .Var => true,
            .Lam => |expr| try expr.checkAcyclic(&visit),
            .App => |app| try app.func.checkAcyclic(&visit) and try app.arg.checkAcyclic(&visit),
        };
    }

    fn hashInto(self: *const Expr, hasher: *std.hash.Wyhash, parent: ?*const Visit) Error!void {
        const visit = try pushVisit(self, parent);
        switch (self.*) {
            .Var => |v| {
                hasher.update(&[_]u8{0}); // tag
                hasher.update(std.mem.asBytes(&v));
            },
            .Lam => |body| {
                hasher.update(&[_]u8{1}); // tag
                try body.hashInto(hasher, &visit);
            },
            .App => |app| {
                hasher.update(&[_]u8{2}); // tag
                try app.func.hashInto(hasher, &visit);
                try app.arg.hashInto(hasher, &visit);
            },
        }
    }
};

test "size counts every node" {
    const allocator = std.testing.allocator;

    const func = try allocator.create(Expr);
    func.* = Expr.initLam(blk: {
        const body = try allocator.create(Expr);
        body.* = Expr.initVar(0);
        break :blk body;
    });

    const arg = try allocator.create(Expr);
    arg.* = Expr.initVar(0);

    const app = try allocator.create(Expr);
    app.* = Expr.initArg(func, arg);
    defer app.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), app.size());
}

test "validity is checked from the root scope" {
    const allocator = std.testing.allocator;

    const valid_body = try allocator.create(Expr);
    valid_body.* = Expr.initVar(0);

    const valid = try allocator.create(Expr);
    valid.* = Expr.initLam(valid_body);
    defer valid.deinit(allocator);

    try std.testing.expect(valid.isValid());

    const invalid = try allocator.create(Expr);
    invalid.* = Expr.initVar(0);
    defer invalid.deinit(allocator);

    try std.testing.expect(!invalid.isValid());
}

test "cyclic expressions are rejected by checked operations" {
    const allocator = std.testing.allocator;

    const expr = try allocator.create(Expr);
    expr.* = Expr.initLam(expr);
    defer allocator.destroy(expr);

    try std.testing.expect(!expr.isAcyclic());
    try std.testing.expectError(error.CycleDetected, expr.sizeChecked());
    try std.testing.expectError(error.CycleDetected, expr.hashChecked());
    try std.testing.expectError(error.CycleDetected, expr.deepCopyChecked(allocator));
}
