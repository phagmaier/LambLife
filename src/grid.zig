const std = @import("std");
const Expr = @import("expr.zig").Expr;
const Config = @import("config.zig").Config;
const mutation = @import("mutation.zig");

pub const ResourceKind = enum(u3) {
    identity,
    true_,
    false_,
    self_apply,
    pair,
    zero,

    pub const COUNT: u32 = 6;
};

pub const Resource = struct {
    kind: ResourceKind,
    age: u16,
};

pub const ResourceInjectionStats = struct {
    attempts: u32 = 0,
    injected: u32 = 0,
    blocked: u32 = 0,
};

pub const Organism = struct {
    expr: *Expr,
    energy: f64,
    age: u64,
    lineage_id: u64,
    parent_lineage: ?u64,
    generation: u64,
};

pub const Cell = union(enum) {
    empty,
    resource: Resource,
    organism: Organism,
};

pub const Grid = struct {
    cells: []Cell,
    biome_map: []u8,
    /// Flat slice of length num_biomes * ResourceKind.COUNT.
    /// Index as: biome * ResourceKind.COUNT + resource_index
    biome_distributions: []f32,
    resource_exprs: [ResourceKind.COUNT]*Expr,
    next_lineage_id: u64,
    rng: std.Random,
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, rng: std.Random, seed: u64, config: Config) !Grid {
        const grid_size = config.gridSize();
        const num_biomes = config.num_biomes;

        var grid = Grid{
            .cells = try allocator.alloc(Cell, grid_size),
            .biome_map = try allocator.alloc(u8, grid_size),
            .biome_distributions = try allocator.alloc(f32, num_biomes * ResourceKind.COUNT),
            .resource_exprs = undefined,
            .next_lineage_id = 0,
            .rng = rng,
            .allocator = allocator,
            .config = config,
        };
        errdefer allocator.free(grid.cells);
        errdefer allocator.free(grid.biome_map);
        errdefer allocator.free(grid.biome_distributions);

        @memset(grid.cells, .empty);

        try grid.buildResourceExprs();
        grid.generateBiomes(seed);
        try grid.populateGrid();

        return grid;
    }

    pub fn deinit(self: *Grid) void {
        for (self.cells) |*cell| {
            switch (cell.*) {
                .organism => |*org| org.expr.deinit(self.allocator),
                else => {},
            }
        }
        for (&self.resource_exprs) |expr| {
            expr.deinit(self.allocator);
        }
        self.allocator.free(self.biome_distributions);
        self.allocator.free(self.biome_map);
        self.allocator.free(self.cells);
    }

    fn buildResourceExprs(self: *Grid) !void {
        // Identity: Lam(Var(0))
        self.resource_exprs[@intFromEnum(ResourceKind.identity)] = try buildLamVar(self.allocator, 0);

        // True: Lam(Lam(Var(1)))
        self.resource_exprs[@intFromEnum(ResourceKind.true_)] = try buildLamLamVar(self.allocator, 1);

        // False: Lam(Lam(Var(0)))
        self.resource_exprs[@intFromEnum(ResourceKind.false_)] = try buildLamLamVar(self.allocator, 0);

        // Self-Apply: Lam(App(Var(0), Var(0)))
        self.resource_exprs[@intFromEnum(ResourceKind.self_apply)] = blk: {
            const v0a = try self.allocator.create(Expr);
            v0a.* = Expr.initVar(0);
            errdefer v0a.deinit(self.allocator);
            const v0b = try self.allocator.create(Expr);
            v0b.* = Expr.initVar(0);
            errdefer v0b.deinit(self.allocator);
            const app = try self.allocator.create(Expr);
            app.* = Expr.initArg(v0a, v0b);
            errdefer app.deinit(self.allocator);
            const lam = try self.allocator.create(Expr);
            lam.* = Expr.initLam(app);
            break :blk lam;
        };

        // Pair: Lam(Lam(Lam(App(App(Var(0), Var(2)), Var(1)))))
        self.resource_exprs[@intFromEnum(ResourceKind.pair)] = blk: {
            const v0 = try self.allocator.create(Expr);
            v0.* = Expr.initVar(0);
            errdefer v0.deinit(self.allocator);
            const v2 = try self.allocator.create(Expr);
            v2.* = Expr.initVar(2);
            errdefer v2.deinit(self.allocator);
            const v1 = try self.allocator.create(Expr);
            v1.* = Expr.initVar(1);
            errdefer v1.deinit(self.allocator);
            const app_inner = try self.allocator.create(Expr);
            app_inner.* = Expr.initArg(v0, v2);
            errdefer app_inner.deinit(self.allocator);
            const app_outer = try self.allocator.create(Expr);
            app_outer.* = Expr.initArg(app_inner, v1);
            errdefer app_outer.deinit(self.allocator);
            const lam3 = try self.allocator.create(Expr);
            lam3.* = Expr.initLam(app_outer);
            errdefer lam3.deinit(self.allocator);
            const lam2 = try self.allocator.create(Expr);
            lam2.* = Expr.initLam(lam3);
            errdefer lam2.deinit(self.allocator);
            const lam1 = try self.allocator.create(Expr);
            lam1.* = Expr.initLam(lam2);
            break :blk lam1;
        };

        // Zero: Lam(Lam(Var(0))) — same structure as False
        self.resource_exprs[@intFromEnum(ResourceKind.zero)] = try buildLamLamVar(self.allocator, 0);
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

    fn generateBiomes(self: *Grid, seed: u64) void {
        const num_biomes = self.config.num_biomes;
        const width = self.config.width;
        const height = self.config.height;
        const grid_size = self.config.gridSize();

        var biome_rng = std.Random.DefaultPrng.init(seed);
        const rng = biome_rng.random();

        // Generate random seed points for Voronoi (max 16 biomes supported)
        var seeds: [16][2]u32 = undefined;
        for (0..num_biomes) |i| {
            seeds[i][0] = rng.intRangeAtMost(u32, 0, width - 1);
            seeds[i][1] = rng.intRangeAtMost(u32, 0, height - 1);
        }

        // Assign each cell to nearest seed (toroidal distance)
        for (0..grid_size) |i| {
            const x = @as(u32, @intCast(i % width));
            const y = @as(u32, @intCast(i / width));

            var best_biome: u8 = 0;
            var best_dist: u32 = std.math.maxInt(u32);

            for (0..num_biomes) |bi| {
                const dist = toroidalDistSq(x, y, seeds[bi][0], seeds[bi][1], width, height);
                if (dist < best_dist) {
                    best_dist = dist;
                    best_biome = @intCast(bi);
                }
            }
            self.biome_map[i] = best_biome;
        }

        // Generate distribution over resource types for each biome.
        for (0..num_biomes) |bi| {
            const dominant = rng.intRangeAtMost(u32, 0, ResourceKind.COUNT - 1);
            var secondary = rng.intRangeAtMost(u32, 0, ResourceKind.COUNT - 2);
            if (secondary >= dominant) secondary += 1;

            const others_weight: f32 = 0.20 / @as(f32, @floatFromInt(ResourceKind.COUNT - 2));
            for (0..ResourceKind.COUNT) |ri| {
                const idx = bi * ResourceKind.COUNT + ri;
                if (ri == dominant) {
                    self.biome_distributions[idx] = 0.50;
                } else if (ri == secondary) {
                    self.biome_distributions[idx] = 0.30;
                } else {
                    self.biome_distributions[idx] = others_weight;
                }
            }
        }
    }

    fn toroidalDistSq(x1: u32, y1: u32, x2: u32, y2: u32, width: u32, height: u32) u32 {
        const dx_raw = if (x1 > x2) x1 - x2 else x2 - x1;
        const dx = @min(dx_raw, width - dx_raw);
        const dy_raw = if (y1 > y2) y1 - y2 else y2 - y1;
        const dy = @min(dy_raw, height - dy_raw);
        return dx * dx + dy * dy;
    }

    fn populateGrid(self: *Grid) !void {
        const grid_size = self.config.gridSize();

        // Heap-allocate the shuffled index array
        const indices = try self.allocator.alloc(u32, grid_size);
        defer self.allocator.free(indices);

        for (0..grid_size) |i| {
            indices[i] = @intCast(i);
        }
        self.rng.shuffle(u32, indices);

        const num_organisms: u32 = @intFromFloat(@as(f32, @floatFromInt(grid_size)) * self.config.initial_organism_fraction);
        const num_resources: u32 = @intFromFloat(@as(f32, @floatFromInt(grid_size)) * self.config.initial_resource_fraction);
        const num_replicators = @min(self.config.seed_replicator_count, num_organisms);

        // Place seed replicators first (within the organism slots)
        for (indices[0..num_replicators]) |idx| {
            const expr = try buildSeedReplicator(self.allocator, self.rng);
            // Apply a slight mutation to each seeded replicator for diversity
            try mutation.mutate(expr, self.allocator, self.rng, self.config);
            self.cells[idx] = .{ .organism = .{
                .expr = expr,
                .energy = self.config.initial_organism_energy,
                .age = 0,
                .lineage_id = self.nextLineageId(),
                .parent_lineage = null,
                .generation = 0,
            } };
        }

        // Place remaining random organisms
        for (indices[num_replicators..num_organisms]) |idx| {
            const depth = self.rng.intRangeAtMost(u32, self.config.initial_expr_min_depth, self.config.initial_expr_max_depth);
            const expr = try Expr.initRandom(depth, 0, 0, self.allocator, self.rng);
            self.cells[idx] = .{ .organism = .{
                .expr = expr,
                .energy = self.config.initial_organism_energy,
                .age = 0,
                .lineage_id = self.nextLineageId(),
                .parent_lineage = null,
                .generation = 0,
            } };
        }

        // Place resources
        for (indices[num_organisms .. num_organisms + num_resources]) |idx| {
            const kind = self.sampleResourceKind(self.biome_map[idx]);
            self.cells[idx] = .{ .resource = .{
                .kind = kind,
                .age = 0,
            } };
        }
    }

    /// Build a known self-replicator expression. Randomly picks from:
    /// - Omega/Mockingbird: Lam(App(Var(0), Var(0)))
    /// - Guarded Replicator: Lam(Lam(App(Var(1), App(Var(1), Var(0)))))
    fn buildSeedReplicator(allocator: std.mem.Allocator, rng: std.Random) !*Expr {
        const choice = rng.intRangeLessThan(u32, 0, 3);
        return switch (choice) {
            // Omega: Lam(App(Var(0), Var(0)))
            0, 1 => {
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
                return lam;
            },
            // Guarded Replicator: Lam(Lam(App(Var(1), App(Var(1), Var(0)))))
            2 => {
                const v0 = try allocator.create(Expr);
                v0.* = Expr.initVar(0);
                errdefer v0.deinit(allocator);
                const v1a = try allocator.create(Expr);
                v1a.* = Expr.initVar(1);
                errdefer v1a.deinit(allocator);
                const v1b = try allocator.create(Expr);
                v1b.* = Expr.initVar(1);
                errdefer v1b.deinit(allocator);
                const inner_app = try allocator.create(Expr);
                inner_app.* = Expr.initArg(v1b, v0);
                errdefer inner_app.deinit(allocator);
                const outer_app = try allocator.create(Expr);
                outer_app.* = Expr.initArg(v1a, inner_app);
                errdefer outer_app.deinit(allocator);
                const inner_lam = try allocator.create(Expr);
                inner_lam.* = Expr.initLam(outer_app);
                errdefer inner_lam.deinit(allocator);
                const outer_lam = try allocator.create(Expr);
                outer_lam.* = Expr.initLam(inner_lam);
                return outer_lam;
            },
            else => unreachable,
        };
    }

    pub fn nextLineageId(self: *Grid) u64 {
        const id = self.next_lineage_id;
        self.next_lineage_id += 1;
        return id;
    }

    fn sampleResourceKind(self: *Grid, biome: u8) ResourceKind {
        const base = @as(u32, biome) * ResourceKind.COUNT;
        const roll = self.rng.float(f32);
        var cumulative: f32 = 0.0;
        for (0..ResourceKind.COUNT) |i| {
            cumulative += self.biome_distributions[base + i];
            if (roll < cumulative) {
                return @enumFromInt(i);
            }
        }
        return @enumFromInt(ResourceKind.COUNT - 1);
    }

    pub fn injectResources(self: *Grid) ResourceInjectionStats {
        const grid_size = self.config.gridSize();
        const num_to_inject: u32 = @intFromFloat(@as(f32, @floatFromInt(grid_size)) * self.config.resource_injection_rate);
        var stats: ResourceInjectionStats = .{ .attempts = num_to_inject };

        for (0..num_to_inject) |_| {
            const idx = self.rng.intRangeAtMost(u32, 0, grid_size - 1);
            if (self.cells[idx] == .empty) {
                const kind = self.sampleResourceKind(self.biome_map[idx]);
                self.cells[idx] = .{ .resource = .{
                    .kind = kind,
                    .age = 0,
                } };
                stats.injected += 1;
            } else {
                stats.blocked += 1;
            }
        }
        return stats;
    }

    pub fn decayResources(self: *Grid) void {
        for (self.cells) |*cell| {
            switch (cell.*) {
                .resource => |*res| {
                    res.age += 1;
                    if (res.age >= self.config.resource_max_age) {
                        cell.* = .empty;
                    }
                },
                else => {},
            }
        }
    }

    pub fn getNeighborIndices(self: *const Grid, idx: u32) [8]u32 {
        const width = self.config.width;
        const height = self.config.height;
        const x: i32 = @intCast(idx % width);
        const y: i32 = @intCast(idx / width);
        const w: i32 = @intCast(width);
        const h: i32 = @intCast(height);
        const offsets = [8][2]i2{
            .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
            .{ -1, 0 },  .{ 1, 0 },  .{ -1, 1 },
            .{ 0, 1 },   .{ 1, 1 },
        };
        var result: [8]u32 = undefined;
        for (offsets, 0..) |off, i| {
            const nx: u32 = @intCast(@mod(x + @as(i32, off[0]), w));
            const ny: u32 = @intCast(@mod(y + @as(i32, off[1]), h));
            result[i] = ny * @as(u32, @intCast(w)) + nx;
        }
        return result;
    }

    pub fn countCells(self: *const Grid) struct { organisms: u32, resources: u32, empty: u32 } {
        var organisms: u32 = 0;
        var resources: u32 = 0;
        var empty: u32 = 0;
        for (self.cells) |cell| {
            switch (cell) {
                .organism => organisms += 1,
                .resource => resources += 1,
                .empty => empty += 1,
            }
        }
        return .{ .organisms = organisms, .resources = resources, .empty = empty };
    }
};

// ============================================================
// Tests
// ============================================================

const DEFAULT_CONFIG = Config{ .width = 20, .height = 20 };

test "toroidal distance wraps correctly" {
    const width: u32 = 150;
    const height: u32 = 150;

    // Adjacent across the left-right boundary
    const dist = Grid.toroidalDistSq(0, 0, width - 1, 0, width, height);
    try std.testing.expectEqual(@as(u32, 1), dist);

    // Adjacent across the top-bottom boundary
    const dist2 = Grid.toroidalDistSq(0, 0, 0, height - 1, width, height);
    try std.testing.expectEqual(@as(u32, 1), dist2);

    // Same cell
    const dist3 = Grid.toroidalDistSq(50, 50, 50, 50, width, height);
    try std.testing.expectEqual(@as(u32, 0), dist3);
}

test "getNeighborIndices wraps at corners" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = DEFAULT_CONFIG;

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Top-left corner (index 0)
    const neighbors = grid.getNeighborIndices(0);

    // Should include bottom-right wrap (WIDTH-1, HEIGHT-1)
    var found_bottom_right = false;
    const expected_br = (config.height - 1) * config.width + (config.width - 1);
    for (neighbors) |n| {
        if (n == expected_br) found_bottom_right = true;
    }
    try std.testing.expect(found_bottom_right);

    // Middle cell should have straightforward neighbors
    const mid_idx: u32 = 10 * config.width + 10;
    const mid_neighbors = grid.getNeighborIndices(mid_idx);
    var found_above = false;
    const expected_above = 9 * config.width + 10;
    for (mid_neighbors) |n| {
        if (n == expected_above) found_above = true;
    }
    try std.testing.expect(found_above);
}

test "grid init and deinit does not leak" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = DEFAULT_CONFIG;
    const grid_size = config.gridSize();

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    const counts = grid.countCells();
    const expected_organisms: u32 = @intFromFloat(@as(f32, @floatFromInt(grid_size)) * config.initial_organism_fraction);
    const expected_resources: u32 = @intFromFloat(@as(f32, @floatFromInt(grid_size)) * config.initial_resource_fraction);

    try std.testing.expectEqual(expected_organisms, counts.organisms);
    try std.testing.expectEqual(expected_resources, counts.resources);
    try std.testing.expectEqual(grid_size - expected_organisms - expected_resources, counts.empty);
}

test "resource injection only fills empty cells" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(123);
    const config = DEFAULT_CONFIG;

    var grid = try Grid.init(allocator, prng.random(), 123, config);
    defer grid.deinit();

    const before = grid.countCells();
    _ = grid.injectResources();
    const after = grid.countCells();

    // Organisms should not have changed
    try std.testing.expectEqual(before.organisms, after.organisms);
    // Resources should have increased (or stayed same if all targeted cells were occupied)
    try std.testing.expect(after.resources >= before.resources);
}

test "resource decay removes old resources" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const config = DEFAULT_CONFIG;

    var grid = try Grid.init(allocator, prng.random(), 7, config);
    defer grid.deinit();

    // Age all resources to just below max
    for (grid.cells) |*cell| {
        switch (cell.*) {
            .resource => |*res| res.age = config.resource_max_age - 1,
            else => {},
        }
    }

    const before = grid.countCells();
    try std.testing.expect(before.resources > 0);

    // One decay tick should remove them all
    grid.decayResources();
    const after = grid.countCells();
    try std.testing.expectEqual(@as(u32, 0), after.resources);
}

test "every biome distribution sums to ~1.0" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(55);
    const config = DEFAULT_CONFIG;

    var grid = try Grid.init(allocator, prng.random(), 55, config);
    defer grid.deinit();

    for (0..config.num_biomes) |bi| {
        var sum: f32 = 0.0;
        for (0..ResourceKind.COUNT) |ri| {
            sum += grid.biome_distributions[bi * ResourceKind.COUNT + ri];
        }
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.01);
    }
}

test "all biomes are represented in the biome map" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(88);
    const config = DEFAULT_CONFIG;

    var grid = try Grid.init(allocator, prng.random(), 88, config);
    defer grid.deinit();

    var seen = [_]bool{false} ** 16;
    for (grid.biome_map) |b| {
        seen[b] = true;
    }
    for (0..config.num_biomes) |i| {
        try std.testing.expect(seen[i]);
    }
}
