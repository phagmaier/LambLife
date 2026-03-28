const std = @import("std");
const Expr = @import("expr.zig").Expr;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;
const Organism = grid_mod.Organism;
const Resource = grid_mod.Resource;
const ResourceKind = grid_mod.ResourceKind;
const Config = @import("config.zig").Config;
const Simulation = @import("simulation.zig").Simulation;
const metrics_mod = @import("metrics.zig");

const MAGIC = [4]u8{ 'L', 'A', 'M', 'B' };
const VERSION: u32 = 1;

// =============================================================
// Binary serialization helpers (append to ArrayList(u8))
// =============================================================

fn writeByte(buf: *std.array_list.Managed(u8), byte: u8) !void {
    try buf.append(byte);
}

fn writeBytes(buf: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try buf.appendSlice(bytes);
}

fn writeU16(buf: *std.array_list.Managed(u8), val: u16) !void {
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
}

fn writeU32(buf: *std.array_list.Managed(u8), val: u32) !void {
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
}

fn writeU64(buf: *std.array_list.Managed(u8), val: u64) !void {
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u64, val)));
}

fn writeF32(buf: *std.array_list.Managed(u8), val: f32) !void {
    try buf.appendSlice(std.mem.asBytes(&val));
}

fn writeF64(buf: *std.array_list.Managed(u8), val: f64) !void {
    try buf.appendSlice(std.mem.asBytes(&val));
}

// =============================================================
// Binary deserialization helpers (read from slice with cursor)
// =============================================================

const Cursor = struct {
    data: []const u8,
    pos: usize,

    fn readByte(self: *Cursor) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readU16(self: *Cursor) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.littleToNative(u16, @bitCast(bytes[0..2].*));
    }

    fn readU32(self: *Cursor) !u32 {
        const bytes = try self.readBytes(4);
        return std.mem.littleToNative(u32, @bitCast(bytes[0..4].*));
    }

    fn readU64(self: *Cursor) !u64 {
        const bytes = try self.readBytes(8);
        return std.mem.littleToNative(u64, @bitCast(bytes[0..8].*));
    }

    fn readF32(self: *Cursor) !f32 {
        const bytes = try self.readBytes(4);
        return @bitCast(bytes[0..4].*);
    }

    fn readF64(self: *Cursor) !f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(bytes[0..8].*);
    }
};

// =============================================================
// Expression serialization
// =============================================================

fn writeExpr(buf: *std.array_list.Managed(u8), expr: *const Expr) !void {
    switch (expr.*) {
        .Var => |v| {
            try writeByte(buf, 0);
            try writeU32(buf, v);
        },
        .Lam => |body| {
            try writeByte(buf, 1);
            try writeExpr(buf, body);
        },
        .App => |app| {
            try writeByte(buf, 2);
            try writeExpr(buf, app.func);
            try writeExpr(buf, app.arg);
        },
    }
}

fn readExpr(cur: *Cursor, allocator: std.mem.Allocator) !*Expr {
    const tag = try cur.readByte();
    const node = try allocator.create(Expr);
    errdefer allocator.destroy(node);

    switch (tag) {
        0 => { // Var
            const v = try cur.readU32();
            node.* = Expr.initVar(v);
        },
        1 => { // Lam
            const body = try readExpr(cur, allocator);
            node.* = Expr.initLam(body);
        },
        2 => { // App
            const func = try readExpr(cur, allocator);
            errdefer func.deinit(allocator);
            const arg = try readExpr(cur, allocator);
            node.* = Expr.initArg(func, arg);
        },
        else => return error.InvalidSnapshot,
    }
    return node;
}

// =============================================================
// Config serialization (field-by-field)
// =============================================================

fn writeConfig(buf: *std.array_list.Managed(u8), config: Config) !void {
    const info = @typeInfo(Config);
    inline for (info.@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .int => try writeBytes(buf, std.mem.asBytes(&@field(config, field.name))),
            .float => try writeBytes(buf, std.mem.asBytes(&@field(config, field.name))),
            else => {},
        }
    }
}

fn readConfig(cur: *Cursor) !Config {
    var config = Config{};
    const info = @typeInfo(Config);
    inline for (info.@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .int, .float => {
                const bytes = try cur.readBytes(@sizeOf(field.type));
                @field(config, field.name) = @bitCast(bytes[0..@sizeOf(field.type)].*);
            },
            else => {},
        }
    }
    return config;
}

// =============================================================
// Snapshot save
// =============================================================

pub fn save(sim: *const Simulation, path: []const u8) !void {
    var buf = std.array_list.Managed(u8).init(sim.allocator);
    defer buf.deinit();

    // Pre-allocate a reasonable size
    try buf.ensureTotalCapacity(1024 * 1024);

    // Header
    try writeBytes(&buf, &MAGIC);
    try writeU32(&buf, VERSION);

    // Tick
    try writeU64(&buf, sim.tick);

    // PRNG state: [4]u64
    for (sim.prng.s) |s| {
        try writeU64(&buf, s);
    }

    // Next lineage ID
    try writeU64(&buf, sim.grid.next_lineage_id);

    // Full config
    try writeConfig(&buf, sim.config);

    // Biome map (width * height bytes)
    const grid_size = sim.config.gridSize();
    try writeBytes(&buf, sim.grid.biome_map[0..grid_size]);

    // Biome distributions (num_biomes * 6 floats)
    const num_dist = sim.config.num_biomes * ResourceKind.COUNT;
    for (sim.grid.biome_distributions[0..num_dist]) |d| {
        try writeF32(&buf, d);
    }

    // Cells
    for (sim.grid.cells[0..grid_size]) |cell| {
        switch (cell) {
            .empty => try writeByte(&buf, 0),
            .resource => |res| {
                try writeByte(&buf, 1);
                try writeByte(&buf, @intFromEnum(res.kind));
                try writeU16(&buf, res.age);
            },
            .organism => |org| {
                try writeByte(&buf, 2);
                try writeExpr(&buf, org.expr);
                try writeF64(&buf, org.energy);
                try writeU64(&buf, org.age);
                try writeU64(&buf, org.lineage_id);
                if (org.parent_lineage) |pl| {
                    try writeByte(&buf, 1);
                    try writeU64(&buf, pl);
                } else {
                    try writeByte(&buf, 0);
                }
                try writeU64(&buf, org.generation);
            },
        }
    }

    // Write buffer to file
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// =============================================================
// Snapshot load
// =============================================================

pub fn load(allocator: std.mem.Allocator, path: []const u8, csv_path: ?[]const u8) !Simulation {
    // Read entire file into memory
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);
    var total_read: usize = 0;
    while (total_read < data.len) {
        const n = try file.read(data[total_read..]);
        if (n == 0) break;
        total_read += n;
    }

    var cur = Cursor{ .data = data[0..total_read], .pos = 0 };

    // Header
    const magic = try cur.readBytes(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;

    const version = try cur.readU32();
    if (version != VERSION) return error.UnsupportedVersion;

    // Tick
    const tick = try cur.readU64();

    // PRNG state
    var prng_state: [4]u64 = undefined;
    for (&prng_state) |*s| {
        s.* = try cur.readU64();
    }

    // Next lineage ID
    const next_lineage_id = try cur.readU64();

    // Config
    const config = try readConfig(&cur);
    const grid_size = config.gridSize();

    // Biome map
    const biome_map_bytes = try cur.readBytes(grid_size);
    const biome_map = try allocator.alloc(u8, grid_size);
    errdefer allocator.free(biome_map);
    @memcpy(biome_map, biome_map_bytes);

    // Biome distributions
    const num_dist = config.num_biomes * ResourceKind.COUNT;
    const biome_distributions = try allocator.alloc(f32, num_dist);
    errdefer allocator.free(biome_distributions);
    for (biome_distributions) |*d| {
        d.* = try cur.readF32();
    }

    // Cells
    const cells = try allocator.alloc(Cell, grid_size);
    errdefer {
        for (cells) |*cell| {
            switch (cell.*) {
                .organism => |*org| org.expr.deinit(allocator),
                else => {},
            }
        }
        allocator.free(cells);
    }

    for (cells) |*cell| {
        const tag = try cur.readByte();
        switch (tag) {
            0 => cell.* = .empty,
            1 => { // resource
                const kind_byte = try cur.readByte();
                const age = try cur.readU16();
                cell.* = .{ .resource = .{
                    .kind = @enumFromInt(kind_byte),
                    .age = age,
                } };
            },
            2 => { // organism
                const expr = try readExpr(&cur, allocator);
                errdefer expr.deinit(allocator);

                const energy = try cur.readF64();
                const age = try cur.readU64();
                const lineage_id = try cur.readU64();

                const has_parent = try cur.readByte();
                const parent_lineage: ?u64 = switch (has_parent) {
                    1 => try cur.readU64(),
                    0 => null,
                    else => return error.InvalidSnapshot,
                };

                const generation = try cur.readU64();

                cell.* = .{ .organism = .{
                    .expr = expr,
                    .energy = energy,
                    .age = age,
                    .lineage_id = lineage_id,
                    .parent_lineage = parent_lineage,
                    .generation = generation,
                } };
            },
            else => return error.InvalidSnapshot,
        }
    }

    // Build resource expressions (fixed, not serialized)
    var resource_exprs: [ResourceKind.COUNT]*Expr = undefined;
    try buildResourceExprs(allocator, &resource_exprs);

    // Reconstruct PRNG
    const prng = std.Random.DefaultPrng{ .s = prng_state };

    // Build the simulation
    var sim = Simulation{
        .prng = prng,
        .grid = Grid{
            .cells = cells,
            .biome_map = biome_map,
            .biome_distributions = biome_distributions,
            .resource_exprs = resource_exprs,
            .next_lineage_id = next_lineage_id,
            .rng = undefined, // will be set below
            .allocator = allocator,
            .config = config,
        },
        .tick = tick,
        .config = config,
        .allocator = allocator,
        .metric_logger = try metrics_mod.MetricLogger.init(csv_path),
        .lineage_log = metrics_mod.LineageLog.init(allocator),
        .snapshot_dir = null,
    };

    // Wire up the grid's rng to point at the simulation's prng
    sim.grid.rng = sim.prng.random();

    return sim;
}

/// Build the fixed resource expressions (same as Grid.buildResourceExprs but standalone).
fn buildResourceExprs(allocator: std.mem.Allocator, out: *[ResourceKind.COUNT]*Expr) !void {
    out[@intFromEnum(ResourceKind.identity)] = try buildLamVar(allocator, 0);
    errdefer out[@intFromEnum(ResourceKind.identity)].deinit(allocator);

    out[@intFromEnum(ResourceKind.true_)] = try buildLamLamVar(allocator, 1);
    errdefer out[@intFromEnum(ResourceKind.true_)].deinit(allocator);

    out[@intFromEnum(ResourceKind.false_)] = try buildLamLamVar(allocator, 0);
    errdefer out[@intFromEnum(ResourceKind.false_)].deinit(allocator);

    out[@intFromEnum(ResourceKind.self_apply)] = blk: {
        const v0a = try allocator.create(Expr);
        v0a.* = Expr.initVar(0);
        errdefer v0a.deinit(allocator);
        const v0b = try allocator.create(Expr);
        v0b.* = Expr.initVar(0);
        errdefer v0b.deinit(allocator);
        const app = try allocator.create(Expr);
        app.* = Expr.initArg(v0a, v0b);
        errdefer app.deinit(allocator);
        const lam = try allocator.create(Expr);
        lam.* = Expr.initLam(app);
        break :blk lam;
    };
    errdefer out[@intFromEnum(ResourceKind.self_apply)].deinit(allocator);

    out[@intFromEnum(ResourceKind.pair)] = blk: {
        const v0 = try allocator.create(Expr);
        v0.* = Expr.initVar(0);
        errdefer v0.deinit(allocator);
        const v2 = try allocator.create(Expr);
        v2.* = Expr.initVar(2);
        errdefer v2.deinit(allocator);
        const v1 = try allocator.create(Expr);
        v1.* = Expr.initVar(1);
        errdefer v1.deinit(allocator);
        const app_inner = try allocator.create(Expr);
        app_inner.* = Expr.initArg(v0, v2);
        errdefer app_inner.deinit(allocator);
        const app_outer = try allocator.create(Expr);
        app_outer.* = Expr.initArg(app_inner, v1);
        errdefer app_outer.deinit(allocator);
        const lam3 = try allocator.create(Expr);
        lam3.* = Expr.initLam(app_outer);
        errdefer lam3.deinit(allocator);
        const lam2 = try allocator.create(Expr);
        lam2.* = Expr.initLam(lam3);
        errdefer lam2.deinit(allocator);
        const lam1 = try allocator.create(Expr);
        lam1.* = Expr.initLam(lam2);
        break :blk lam1;
    };
    errdefer out[@intFromEnum(ResourceKind.pair)].deinit(allocator);

    out[@intFromEnum(ResourceKind.zero)] = try buildLamLamVar(allocator, 0);
}

fn buildLamVar(allocator: std.mem.Allocator, index: u32) !*Expr {
    const v = try allocator.create(Expr);
    v.* = Expr.initVar(index);
    errdefer v.deinit(allocator);
    const lam = try allocator.create(Expr);
    lam.* = Expr.initLam(v);
    return lam;
}

fn buildLamLamVar(allocator: std.mem.Allocator, index: u32) !*Expr {
    const v = try allocator.create(Expr);
    v.* = Expr.initVar(index);
    errdefer v.deinit(allocator);
    const inner = try allocator.create(Expr);
    inner.* = Expr.initLam(v);
    errdefer inner.deinit(allocator);
    const outer = try allocator.create(Expr);
    outer.* = Expr.initLam(inner);
    return outer;
}

/// Generate snapshot file path: {dir}/snapshot_{tick:0>8}.bin
pub fn snapshotPath(allocator: std.mem.Allocator, dir: []const u8, tick: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/snapshot_{d:0>8}.bin", .{ dir, tick });
}

// =============================================================
// Tests
// =============================================================

test "expr round-trip serialization" {
    const allocator = std.testing.allocator;

    // Build: Lam(App(Var(0), Var(0)))
    const v0a = try allocator.create(Expr);
    v0a.* = Expr.initVar(0);
    const v0b = try allocator.create(Expr);
    v0b.* = Expr.initVar(0);
    const app = try allocator.create(Expr);
    app.* = Expr.initArg(v0a, v0b);
    const lam = try allocator.create(Expr);
    lam.* = Expr.initLam(app);
    defer lam.deinit(allocator);

    // Serialize
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try writeExpr(&buf, lam);

    // Deserialize
    var cur = Cursor{ .data = buf.items, .pos = 0 };
    const restored = try readExpr(&cur, allocator);
    defer restored.deinit(allocator);

    try std.testing.expectEqual(lam.hash(), restored.hash());
    try std.testing.expectEqual(lam.size(), restored.size());
}

test "snapshot save and load round-trip" {
    const allocator = std.testing.allocator;
    const config = Config{ .width = 10, .height = 10 };
    const path = "/tmp/lamblife_test_snapshot.bin";

    // Create and run a simulation for 3 ticks
    var sim = try Simulation.init(allocator, config, 42, null);
    _ = try sim.step();
    _ = try sim.step();
    _ = try sim.step();

    const tick_before = sim.tick;
    const lineage_before = sim.grid.next_lineage_id;

    // Count organisms and capture hashes
    var org_count: u32 = 0;
    var hash_sum: u64 = 0;
    for (sim.grid.cells) |cell| {
        switch (cell) {
            .organism => |org| {
                org_count += 1;
                hash_sum +%= org.expr.hash();
            },
            else => {},
        }
    }

    // Save snapshot
    try save(&sim, path);
    sim.deinit();

    // Load snapshot
    var sim2 = try load(allocator, path, null);
    defer sim2.deinit();

    // Verify state matches
    try std.testing.expectEqual(tick_before, sim2.tick);
    try std.testing.expectEqual(lineage_before, sim2.grid.next_lineage_id);
    try std.testing.expectEqual(@as(u32, 10), sim2.config.width);

    var org_count2: u32 = 0;
    var hash_sum2: u64 = 0;
    for (sim2.grid.cells) |cell| {
        switch (cell) {
            .organism => |org| {
                org_count2 += 1;
                hash_sum2 +%= org.expr.hash();
            },
            else => {},
        }
    }
    try std.testing.expectEqual(org_count, org_count2);
    try std.testing.expectEqual(hash_sum, hash_sum2);

    // Clean up test file
    std.fs.cwd().deleteFile(path) catch {};
}

test "config round-trip serialization" {
    const allocator = std.testing.allocator;
    var config = Config{};
    config.width = 200;
    config.maintenance_base = 1.5;
    config.max_organism_age = 5000;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try writeConfig(&buf, config);

    var cur = Cursor{ .data = buf.items, .pos = 0 };
    const restored = try readConfig(&cur);

    try std.testing.expectEqual(config.width, restored.width);
    try std.testing.expectEqual(config.maintenance_base, restored.maintenance_base);
    try std.testing.expectEqual(config.max_organism_age, restored.max_organism_age);
    try std.testing.expectEqual(config.height, restored.height);
}

test "resumed simulation produces same results as continuous run" {
    const allocator = std.testing.allocator;
    const config = Config{ .width = 10, .height = 10 };
    const path = "/tmp/lamblife_test_determinism.bin";

    // Run continuous: 6 ticks
    var sim_continuous = try Simulation.init(allocator, config, 42, null);
    sim_continuous.rewireRng();
    for (0..6) |_| {
        _ = try sim_continuous.step();
    }

    // Run split: 3 ticks, save, load, 3 more ticks
    var sim_a = try Simulation.init(allocator, config, 42, null);
    sim_a.rewireRng();
    for (0..3) |_| {
        _ = try sim_a.step();
    }
    try save(&sim_a, path);
    sim_a.deinit();

    var sim_b = try load(allocator, path, null);
    sim_b.rewireRng();
    for (0..3) |_| {
        _ = try sim_b.step();
    }

    // Both should have same tick count
    try std.testing.expectEqual(sim_continuous.tick, sim_b.tick);

    // Compare organism hashes
    var hash_cont: u64 = 0;
    var hash_resumed: u64 = 0;
    for (sim_continuous.grid.cells, sim_b.grid.cells) |c1, c2| {
        switch (c1) {
            .organism => |org| hash_cont +%= org.expr.hash(),
            else => {},
        }
        switch (c2) {
            .organism => |org| hash_resumed +%= org.expr.hash(),
            else => {},
        }
    }
    try std.testing.expectEqual(hash_cont, hash_resumed);

    sim_continuous.deinit();
    sim_b.deinit();
    std.fs.cwd().deleteFile(path) catch {};
}
