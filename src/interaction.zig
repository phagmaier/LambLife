const std = @import("std");
const Expr = @import("expr.zig").Expr;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const ResourceKind = grid_mod.ResourceKind;
const reduce_mod = @import("reduce.zig");
const mutation = @import("mutation.zig");
const Config = @import("config.zig").Config;

// ============================================================
// Public types
// ============================================================

pub const TickStats = struct {
    interactions: u32 = 0,
    births: u32 = 0,
    novel_placements: u32 = 0,
    resources_consumed: u32 = 0,
    organisms_processed: u32 = 0,
    reductions_attempted: u32 = 0,
    beta_steps: u64 = 0,
    size_limit_hits: u32 = 0,
    step_limit_hits: u32 = 0,
};

pub const BirthKind = enum {
    reproduction,
    novel,
};

pub const BirthRecord = struct {
    child_lineage: u64,
    parent_lineage: ?u64,
    generation: u64,
    expr_hash: u64,
    kind: BirthKind,
};

pub const BirthRecorder = struct {
    records: std.ArrayList(BirthRecord) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BirthRecorder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BirthRecorder) void {
        self.records.deinit(self.allocator);
    }

    pub fn record(self: *BirthRecorder, rec: BirthRecord) !void {
        try self.records.append(self.allocator, rec);
    }
};

pub const TickProcessor = struct {
    grid: *Grid,
    birth_recorder: *BirthRecorder,
    indices: []u32,
    next_idx: usize,
    stats: TickStats,

    pub fn init(grid: *Grid, birth_recorder: *BirthRecorder) !TickProcessor {
        var org_count: u32 = 0;
        for (grid.cells) |cell| {
            if (cell == .organism) org_count += 1;
        }

        const indices = try grid.allocator.alloc(u32, org_count);
        errdefer grid.allocator.free(indices);

        var idx: u32 = 0;
        for (grid.cells, 0..) |cell, i| {
            if (cell == .organism) {
                indices[idx] = @intCast(i);
                idx += 1;
            }
        }

        grid.rng.shuffle(u32, indices);

        return .{
            .grid = grid,
            .birth_recorder = birth_recorder,
            .indices = indices,
            .next_idx = 0,
            .stats = .{},
        };
    }

    pub fn deinit(self: *TickProcessor) void {
        self.grid.allocator.free(self.indices);
        self.indices = &.{};
        self.next_idx = 0;
    }

    pub fn advance(self: *TickProcessor, max_organisms: u32) !bool {
        if (self.next_idx >= self.indices.len) return true;

        const end_idx = @min(self.indices.len, self.next_idx + max_organisms);
        while (self.next_idx < end_idx) : (self.next_idx += 1) {
            try processOrganism(self.grid, self.birth_recorder, self.indices[self.next_idx], &self.stats);
        }

        return self.next_idx >= self.indices.len;
    }
};

const NeighborInfo = struct {
    index: u32,
    is_organism: bool,
};

// ============================================================
// Public API
// ============================================================

/// Process one full tick of organism interactions.
/// Call this once per simulation tick after resource injection/decay.
pub fn processTick(grid: *Grid, birth_recorder: *BirthRecorder) !TickStats {
    var processor = try TickProcessor.init(grid, birth_recorder);
    defer processor.deinit();

    _ = try processor.advance(@intCast(processor.indices.len));
    return processor.stats;
}

/// Compute structural similarity between two expressions.
/// Returns a value in [0.0, 1.0].
pub fn computeSimilarity(a: *const Expr, b: *const Expr, hash_depth_limit: u32) f64 {
    // Fast reject: if top-level hashes differ, not similar
    if (hashTopLevels(a, hash_depth_limit) != hashTopLevels(b, hash_depth_limit)) {
        return 0.0;
    }
    // Full structural comparison
    const shared = countSharedNodes(a, b);
    const size_a = a.size();
    const size_b = b.size();
    const min_size = @min(size_a, size_b);
    if (min_size == 0) return 0.0;
    return @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(min_size));
}

// ============================================================
// Per-organism processing
// ============================================================

fn processOrganism(grid: *Grid, birth_recorder: *BirthRecorder, org_idx: u32, stats: *TickStats) !void {
    const config = grid.config;

    // Guard: cell must still be an organism
    if (grid.cells[org_idx] != .organism) return;
    stats.organisms_processed += 1;

    // Apply maintenance cost
    {
        const s = grid.cells[org_idx].organism.expr_size;
        const sf: f64 = @floatFromInt(s);
        grid.cells[org_idx].organism.energy -= config.maintenance_base + config.maintenance_per_node * sf;
        if (s > config.size_penalty_threshold) {
            const excess: f64 = @floatFromInt(s - config.size_penalty_threshold);
            grid.cells[org_idx].organism.energy -= config.size_penalty_per_node * excess;
        }
    }

    // Find an occupied neighbor
    const neighbor = findOccupiedNeighbor(grid, org_idx) orelse return;
    stats.interactions += 1;

    // Use a per-interaction arena for temporary reduction trees.
    var arena = std.heap.ArenaAllocator.init(grid.allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    // Read the live expressions directly; reduction will clone into the arena.
    const neighbor_is_resource = !neighbor.is_organism;
    const neighbor_expr: *Expr = if (neighbor_is_resource) blk: {
        const kind = grid.cells[neighbor.index].resource.kind;
        break :blk grid.resource_exprs[@intFromEnum(kind)];
    } else blk: {
        break :blk grid.cells[neighbor.index].organism.expr;
    };
    const org_live_expr = grid.cells[org_idx].organism.expr;
    const neighbor_size: u32 = if (neighbor_is_resource)
        grid.resource_expr_sizes[@intFromEnum(grid.cells[neighbor.index].resource.kind)]
    else
        grid.cells[neighbor.index].organism.expr_size;
    const neighbor_hash: u64 = if (neighbor_is_resource)
        grid.resource_expr_hashes[@intFromEnum(grid.cells[neighbor.index].resource.kind)]
    else
        grid.cells[neighbor.index].organism.expr_hash;

    // Build stack application nodes and let reduction copy them into the arena.
    var app_ab = Expr.initArg(org_live_expr, neighbor_expr);
    const result_ab = try reduce_mod.reduceShared(&app_ab, config.max_reduction_steps, config.max_expression_size, temp_allocator);
    stats.reductions_attempted += 1;
    stats.beta_steps += result_ab.steps;
    if (result_ab.hit_step_limit) stats.step_limit_hits += 1;
    if (result_ab.hit_size_limit) stats.size_limit_hits += 1;

    var app_ba = Expr.initArg(neighbor_expr, org_live_expr);
    const result_ba = try reduce_mod.reduceShared(&app_ba, config.max_reduction_steps, config.max_expression_size, temp_allocator);
    stats.reductions_attempted += 1;
    stats.beta_steps += result_ba.steps;
    if (result_ba.hit_step_limit) stats.step_limit_hits += 1;
    if (result_ba.hit_size_limit) stats.size_limit_hits += 1;

    // Deduct interaction and reduction costs from organism A
    grid.cells[org_idx].organism.energy -= config.interaction_base_cost;
    const total_steps: f64 = @floatFromInt(result_ab.steps + result_ba.steps);
    grid.cells[org_idx].organism.energy -= config.reduction_step_cost * total_steps;

    // Charge neighbor B if it's an organism
    if (neighbor.is_organism and grid.cells[neighbor.index] == .organism) {
        grid.cells[neighbor.index].organism.energy -= config.neighbor_interaction_cost;
    }

    // Handle outputs
    var already_reproduced = false;
    var resource_consumed = false;

    handleOutput(
        grid,
        birth_recorder,
        org_idx,
        neighbor.index,
        result_ab.expr,
        org_live_expr,
        neighbor_expr,
        neighbor_size,
        neighbor_hash,
        neighbor_is_resource,
        &already_reproduced,
        &resource_consumed,
        stats,
    );
    handleOutput(
        grid,
        birth_recorder,
        org_idx,
        neighbor.index,
        result_ba.expr,
        org_live_expr,
        neighbor_expr,
        neighbor_size,
        neighbor_hash,
        neighbor_is_resource,
        &already_reproduced,
        &resource_consumed,
        stats,
    );
}

// ============================================================
// Output handler
// ============================================================

fn handleOutput(
    grid: *Grid,
    birth_recorder: *BirthRecorder,
    org_idx: u32,
    neighbor_idx: u32,
    result: *const Expr,
    org_expr: *const Expr,
    neighbor_expr: *const Expr,
    neighbor_size: u32,
    neighbor_hash: u64,
    neighbor_is_resource: bool,
    already_reproduced: *bool,
    resource_consumed: *bool,
    stats: *TickStats,
) void {
    const config = grid.config;

    // Guard: organism might have been overwritten
    if (grid.cells[org_idx] != .organism) return;

    // 1. Discard if too large or bare variable
    const result_size = result.size();
    if (result_size > config.max_expression_size) return;
    if (result.* == .Var) return;

    // 2. Simplification bonus
    const org_size = grid.cells[org_idx].organism.expr_size;
    const input_total: u32 = org_size + neighbor_size;
    if (result_size < input_total) {
        const reduction: f64 = @floatFromInt(input_total - result_size);
        grid.cells[org_idx].organism.energy += config.simplification_bonus_per_node * reduction;
    }

    // 3. Self-similarity check
    const sim_to_parent = computeSimilarity(result, org_expr, config.hash_depth_limit);
    if (sim_to_parent >= config.similarity_threshold) {
        grid.cells[org_idx].organism.energy += config.self_similarity_bonus;
        if (!already_reproduced.*) {
            if (tryReproduce(grid, birth_recorder, org_idx, result, stats)) {
                already_reproduced.* = true;
            }
        }
    } else {
        // 4. Novel output — check not similar to either input
        const sim_to_neighbor = computeSimilarity(result, neighbor_expr, config.hash_depth_limit);
        if (sim_to_neighbor < config.similarity_threshold) {
            tryPlaceNovel(grid, birth_recorder, org_idx, result, stats);
        }
    }

    // 5. Resource consumption
    if (neighbor_is_resource and !resource_consumed.* and grid.cells[neighbor_idx] == .resource) {
        const result_hash = result.hash();
        if (result_hash != neighbor_hash) {
            grid.cells[neighbor_idx] = .empty;
            grid.cells[org_idx].organism.energy += config.resource_consumption_bonus;
            resource_consumed.* = true;
            stats.resources_consumed += 1;
        }
    }
}

// ============================================================
// Reproduction & novel placement
// ============================================================

fn tryReproduce(grid: *Grid, birth_recorder: *BirthRecorder, parent_idx: u32, child_expr: *const Expr, stats: *TickStats) bool {
    const config = grid.config;
    if (grid.cells[parent_idx] != .organism) return false;

    const empty_idx = findEmptyNeighbor(grid, parent_idx) orelse return false;

    // Deep-copy and mutate
    const child_copy = Expr.deepCopy(child_expr, grid.allocator) catch return false;
    mutation.mutate(child_copy, grid.allocator, grid.rng, config) catch {
        child_copy.deinit(grid.allocator);
        return false;
    };

    // Transfer energy
    const parent_energy = grid.cells[parent_idx].organism.energy;
    const child_energy = parent_energy * config.reproduction_energy_fraction;
    grid.cells[parent_idx].organism.energy -= child_energy;

    const parent_lineage = grid.cells[parent_idx].organism.lineage_id;
    const generation = grid.cells[parent_idx].organism.generation + 1;
    const child_lineage = grid.nextLineageId();

    grid.cells[empty_idx] = .{ .organism = grid_mod.Organism.fromExpr(
        child_copy,
        child_energy,
        0,
        child_lineage,
        parent_lineage,
        generation,
    ) };
    stats.births += 1;
    birth_recorder.record(.{
        .child_lineage = child_lineage,
        .parent_lineage = parent_lineage,
        .generation = generation,
        .expr_hash = grid.cells[empty_idx].organism.expr_hash,
        .kind = .reproduction,
    }) catch {};
    return true;
}

fn tryPlaceNovel(grid: *Grid, birth_recorder: *BirthRecorder, near_idx: u32, result_expr: *const Expr, stats: *TickStats) void {
    const empty_idx = findEmptyNeighbor(grid, near_idx) orelse return;

    const copy = Expr.deepCopy(result_expr, grid.allocator) catch return;
    const child_lineage = grid.nextLineageId();

    grid.cells[empty_idx] = .{ .organism = grid_mod.Organism.fromExpr(
        copy,
        grid.config.novel_offspring_initial_energy,
        0,
        child_lineage,
        null,
        0,
    ) };
    stats.novel_placements += 1;
    birth_recorder.record(.{
        .child_lineage = child_lineage,
        .parent_lineage = null,
        .generation = 0,
        .expr_hash = grid.cells[empty_idx].organism.expr_hash,
        .kind = .novel,
    }) catch {};
}

// ============================================================
// Neighbor finding
// ============================================================

fn findOccupiedNeighbor(grid: *Grid, idx: u32) ?NeighborInfo {
    const neighbors = grid.getNeighborIndices(idx);
    var occupied: [8]NeighborInfo = undefined;
    var count: u32 = 0;

    for (neighbors) |n| {
        switch (grid.cells[n]) {
            .organism => {
                occupied[count] = .{ .index = n, .is_organism = true };
                count += 1;
            },
            .resource => {
                occupied[count] = .{ .index = n, .is_organism = false };
                count += 1;
            },
            .empty => {},
        }
    }

    if (count == 0) return null;
    const pick = grid.rng.intRangeLessThan(u32, 0, count);
    return occupied[pick];
}

fn findEmptyNeighbor(grid: *Grid, idx: u32) ?u32 {
    const neighbors = grid.getNeighborIndices(idx);
    var empty: [8]u32 = undefined;
    var count: u32 = 0;

    for (neighbors) |n| {
        if (grid.cells[n] == .empty) {
            empty[count] = n;
            count += 1;
        }
    }

    if (count == 0) return null;
    return empty[grid.rng.intRangeLessThan(u32, 0, count)];
}

// ============================================================
// Self-similarity detection
// ============================================================

fn hashTopLevels(expr: *const Expr, max_depth: u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashTopLevelsInto(expr, &hasher, max_depth, 0);
    return hasher.final();
}

fn hashTopLevelsInto(expr: *const Expr, hasher: *std.hash.Wyhash, max_depth: u32, depth: u32) void {
    if (depth >= max_depth) {
        hasher.update(&[_]u8{0xFF}); // sentinel for "subtree below cutoff"
        return;
    }
    switch (expr.*) {
        .Var => |v| {
            hasher.update(&[_]u8{0});
            hasher.update(std.mem.asBytes(&v));
        },
        .Lam => |body| {
            hasher.update(&[_]u8{1});
            hashTopLevelsInto(body, hasher, max_depth, depth + 1);
        },
        .App => |app| {
            hasher.update(&[_]u8{2});
            hashTopLevelsInto(app.func, hasher, max_depth, depth + 1);
            hashTopLevelsInto(app.arg, hasher, max_depth, depth + 1);
        },
    }
}

fn countSharedNodes(a: *const Expr, b: *const Expr) u32 {
    return switch (a.*) {
        .Var => |va| switch (b.*) {
            .Var => |vb| if (va == vb) @as(u32, 1) else @as(u32, 0),
            else => 0,
        },
        .Lam => |la| switch (b.*) {
            .Lam => |lb| 1 + countSharedNodes(la, lb),
            else => 0,
        },
        .App => |aa| switch (b.*) {
            .App => |ab| 1 + countSharedNodes(aa.func, ab.func) + countSharedNodes(aa.arg, ab.arg),
            else => 0,
        },
    };
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

const DEFAULT_HASH_DEPTH: u32 = 3;

test "computeSimilarity — identical expressions return 1.0" {
    const allocator = std.testing.allocator;

    // Lam(App(Var(0), Var(0)))
    const v0a = try makeVar(allocator, 0);
    const v0b = try makeVar(allocator, 0);
    const app = try makeApp(allocator, v0a, v0b);
    const expr = try makeLam(allocator, app);
    defer expr.deinit(allocator);

    const sim = computeSimilarity(expr, expr, DEFAULT_HASH_DEPTH);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sim, 0.001);
}

test "computeSimilarity — completely different expressions return 0.0" {
    const allocator = std.testing.allocator;

    // Lam(Var(0))
    const v0 = try makeVar(allocator, 0);
    const a = try makeLam(allocator, v0);
    defer a.deinit(allocator);

    // App(Lam(Lam(Var(1))), Lam(Var(0)))  — different top-level structure
    const v1 = try makeVar(allocator, 1);
    const inner = try makeLam(allocator, v1);
    const outer = try makeLam(allocator, inner);
    const v0b = try makeVar(allocator, 0);
    const arg = try makeLam(allocator, v0b);
    const b = try makeApp(allocator, outer, arg);
    defer b.deinit(allocator);

    const sim = computeSimilarity(a, b, DEFAULT_HASH_DEPTH);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), sim, 0.001);
}

test "countSharedNodes — partial overlap" {
    const allocator = std.testing.allocator;

    // Lam(App(Var(0), Var(0)))
    const a_v0a = try makeVar(allocator, 0);
    const a_v0b = try makeVar(allocator, 0);
    const a_app = try makeApp(allocator, a_v0a, a_v0b);
    const a = try makeLam(allocator, a_app);
    defer a.deinit(allocator);

    // Lam(App(Var(0), Var(1)))  — differs only in last var
    const b_v0 = try makeVar(allocator, 0);
    const b_v1 = try makeVar(allocator, 1);
    const b_app = try makeApp(allocator, b_v0, b_v1);
    const b = try makeLam(allocator, b_app);
    defer b.deinit(allocator);

    const shared = countSharedNodes(a, b);
    // Shared: Lam(1) + App(1) + Var(0)(1) = 3, not Var(0) vs Var(1) = 0
    try std.testing.expectEqual(@as(u32, 3), shared);
}

test "hashTopLevels — identical expressions have same hash" {
    const allocator = std.testing.allocator;

    const v0a = try makeVar(allocator, 0);
    const a = try makeLam(allocator, v0a);
    defer a.deinit(allocator);

    const v0b = try makeVar(allocator, 0);
    const b = try makeLam(allocator, v0b);
    defer b.deinit(allocator);

    try std.testing.expectEqual(hashTopLevels(a, 3), hashTopLevels(b, 3));
}

test "hashTopLevels — different expressions have different hashes" {
    const allocator = std.testing.allocator;

    const v0 = try makeVar(allocator, 0);
    const a = try makeLam(allocator, v0);
    defer a.deinit(allocator);

    const v1 = try makeVar(allocator, 1);
    const inner = try makeLam(allocator, v1);
    const b = try makeLam(allocator, inner);
    defer b.deinit(allocator);

    try std.testing.expect(hashTopLevels(a, 3) != hashTopLevels(b, 3));
}

test "findOccupiedNeighbor — returns null when all neighbors empty" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Clear all cells around index 0
    const neighbors = grid.getNeighborIndices(0);
    for (neighbors) |n| {
        switch (grid.cells[n]) {
            .organism => |*org| org.expr.deinit(allocator),
            else => {},
        }
        grid.cells[n] = .empty;
    }

    try std.testing.expect(findOccupiedNeighbor(&grid, 0) == null);
}

test "findEmptyNeighbor — finds empty cell" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Ensure at least one neighbor of cell 0 is empty
    const neighbors = grid.getNeighborIndices(0);
    var has_empty = false;
    for (neighbors) |n| {
        if (grid.cells[n] == .empty) {
            has_empty = true;
            break;
        }
    }
    // If none are empty, make one empty
    if (!has_empty) {
        switch (grid.cells[neighbors[0]]) {
            .organism => |*org| org.expr.deinit(allocator),
            else => {},
        }
        grid.cells[neighbors[0]] = .empty;
    }

    try std.testing.expect(findEmptyNeighbor(&grid, 0) != null);
}

test "processOrganism — maintenance cost deducted" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Find an organism and clear its neighbors so it does nothing but pay maintenance
    var org_idx: u32 = 0;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            org_idx = @intCast(i);
            break;
        }
    }
    const neighbors = grid.getNeighborIndices(org_idx);
    for (neighbors) |n| {
        switch (grid.cells[n]) {
            .organism => |*org| org.expr.deinit(allocator),
            else => {},
        }
        grid.cells[n] = .empty;
    }

    const energy_before = grid.cells[org_idx].organism.energy;
    var stats = TickStats{};
    var birth_recorder = BirthRecorder.init(allocator);
    defer birth_recorder.deinit();
    try processOrganism(&grid, &birth_recorder, org_idx, &stats);

    // Should have paid maintenance but no interaction
    try std.testing.expect(grid.cells[org_idx].organism.energy < energy_before);
    try std.testing.expectEqual(@as(u32, 0), stats.interactions);
}

test "processOrganism — interaction with resource deducts costs" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Find an organism
    var org_idx: u32 = 0;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            org_idx = @intCast(i);
            break;
        }
    }

    // Clear neighbors and place exactly one resource
    const neighbors = grid.getNeighborIndices(org_idx);
    for (neighbors) |n| {
        switch (grid.cells[n]) {
            .organism => |*org| org.expr.deinit(allocator),
            else => {},
        }
        grid.cells[n] = .empty;
    }
    grid.cells[neighbors[0]] = .{ .resource = .{ .kind = .identity, .age = 0 } };

    // Give it a known energy to test deductions
    grid.cells[org_idx].organism.energy = 1000.0;
    const energy_before: f64 = 1000.0;
    var stats = TickStats{};
    var birth_recorder = BirthRecorder.init(allocator);
    defer birth_recorder.deinit();
    try processOrganism(&grid, &birth_recorder, org_idx, &stats);

    // Should have interacted
    try std.testing.expectEqual(@as(u32, 1), stats.interactions);
    try std.testing.expect(grid.cells[org_idx].organism.energy != energy_before);
}

test "tryReproduce — child gets correct lineage and energy" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Find an organism with at least one empty neighbor
    var org_idx: ?u32 = null;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            const nbrs = grid.getNeighborIndices(@intCast(i));
            for (nbrs) |n| {
                if (grid.cells[n] == .empty) {
                    org_idx = @intCast(i);
                    break;
                }
            }
            if (org_idx != null) break;
        }
    }

    if (org_idx) |oi| {
        const parent_energy = grid.cells[oi].organism.energy;
        const parent_lineage = grid.cells[oi].organism.lineage_id;
        const parent_gen = grid.cells[oi].organism.generation;

        // Use the parent's own expression as the "child expression"
        var stats = TickStats{};
        var birth_recorder = BirthRecorder.init(allocator);
        defer birth_recorder.deinit();
        const success = tryReproduce(&grid, &birth_recorder, oi, grid.cells[oi].organism.expr, &stats);

        if (success) {
            try std.testing.expectEqual(@as(u32, 1), stats.births);
            // Parent lost energy
            const expected_parent_energy = parent_energy - parent_energy * config.reproduction_energy_fraction;
            try std.testing.expectApproxEqAbs(expected_parent_energy, grid.cells[oi].organism.energy, 0.01);

            // Find the child (scan neighbors for new organism)
            const nbrs = grid.getNeighborIndices(oi);
            for (nbrs) |n| {
                if (grid.cells[n] == .organism and grid.cells[n].organism.parent_lineage != null) {
                    if (grid.cells[n].organism.parent_lineage.? == parent_lineage) {
                        try std.testing.expectEqual(parent_gen + 1, grid.cells[n].organism.generation);
                        break;
                    }
                }
            }
        }
    }
}

test "bare Var result is discarded by handleOutput" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 20, .height = 20 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    // Find an organism
    var org_idx: u32 = 0;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            org_idx = @intCast(i);
            break;
        }
    }

    const energy_before = grid.cells[org_idx].organism.energy;

    // Create a bare Var(0) as result
    const bare_var = try makeVar(allocator, 0);
    defer bare_var.deinit(allocator);

    // Create a dummy neighbor expression
    const dummy = try makeVar(allocator, 0);
    const neighbor_expr = try makeLam(allocator, dummy);
    defer neighbor_expr.deinit(allocator);

    var already_reproduced = false;
    var resource_consumed = false;
    var stats = TickStats{};
    var birth_recorder = BirthRecorder.init(allocator);
    defer birth_recorder.deinit();

    handleOutput(
        &grid,
        &birth_recorder,
        org_idx,
        0,
        bare_var,
        grid.cells[org_idx].organism.expr,
        neighbor_expr,
        neighbor_expr.size(),
        neighbor_expr.hash(),
        false,
        &already_reproduced,
        &resource_consumed,
        &stats,
    );

    // Energy should not have changed (no bonuses for bare Var)
    try std.testing.expectApproxEqAbs(energy_before, grid.cells[org_idx].organism.energy, 0.001);
    try std.testing.expectEqual(@as(u32, 0), stats.births);
}
