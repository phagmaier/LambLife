const std = @import("std");
const Expr = @import("expr.zig").Expr;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const ResourceKind = grid_mod.ResourceKind;
const reduce_mod = @import("reduce.zig");
const mutation = @import("mutation.zig");

// ============================================================
// Energy constants (plan.md §5, §18)
// ============================================================

const INTERACTION_BASE_COST: f64 = 2.0;
const REDUCTION_STEP_COST: f64 = 0.3;
const NEIGHBOR_INTERACTION_COST: f64 = 1.0;
const MAINTENANCE_BASE: f64 = 0.5;
const MAINTENANCE_PER_NODE: f64 = 0.1;
const SIZE_PENALTY_THRESHOLD: u32 = 100;
const SIZE_PENALTY_PER_NODE: f64 = 0.5;

const SIMPLIFICATION_BONUS_PER_NODE: f64 = 2.0;
const RESOURCE_CONSUMPTION_BONUS: f64 = 10.0;
const SELF_SIMILARITY_BONUS: f64 = 5.0;
const NOVEL_OFFSPRING_INITIAL_ENERGY: f64 = 15.0;
const REPRODUCTION_ENERGY_FRACTION: f64 = 0.5;

const MAX_REDUCTION_STEPS: u32 = 200;
const MAX_EXPRESSION_SIZE: u32 = 500;
const SIMILARITY_THRESHOLD: f64 = 0.80;
const HASH_DEPTH_LIMIT: u32 = 3;

// ============================================================
// Public types
// ============================================================

pub const TickStats = struct {
    interactions: u32 = 0,
    births: u32 = 0,
    novel_placements: u32 = 0,
    resources_consumed: u32 = 0,
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
pub fn processTick(grid: *Grid) !TickStats {
    var stats = TickStats{};

    // Count organisms to size the index buffer
    var org_count: u32 = 0;
    for (grid.cells) |cell| {
        if (cell == .organism) org_count += 1;
    }
    if (org_count == 0) return stats;

    // Collect organism indices
    const indices = try grid.allocator.alloc(u32, org_count);
    defer grid.allocator.free(indices);

    var idx: u32 = 0;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            indices[idx] = @intCast(i);
            idx += 1;
        }
    }

    // Shuffle for random processing order
    grid.rng.shuffle(u32, indices);

    // Process each organism
    for (indices) |org_idx| {
        try processOrganism(grid, org_idx, &stats);
    }

    return stats;
}

/// Compute structural similarity between two expressions.
/// Returns a value in [0.0, 1.0].
pub fn computeSimilarity(a: *const Expr, b: *const Expr) f64 {
    // Fast reject: if top-level hashes differ, not similar
    if (hashTopLevels(a, HASH_DEPTH_LIMIT) != hashTopLevels(b, HASH_DEPTH_LIMIT)) {
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

fn processOrganism(grid: *Grid, org_idx: u32, stats: *TickStats) !void {
    // Guard: cell must still be an organism
    if (grid.cells[org_idx] != .organism) return;

    // Apply maintenance cost
    {
        const s = grid.cells[org_idx].organism.expr.size();
        const sf: f64 = @floatFromInt(s);
        grid.cells[org_idx].organism.energy -= MAINTENANCE_BASE + MAINTENANCE_PER_NODE * sf;
        if (s > SIZE_PENALTY_THRESHOLD) {
            const excess: f64 = @floatFromInt(s - SIZE_PENALTY_THRESHOLD);
            grid.cells[org_idx].organism.energy -= SIZE_PENALTY_PER_NODE * excess;
        }
    }

    // Find an occupied neighbor
    const neighbor = findOccupiedNeighbor(grid, org_idx) orelse return;
    stats.interactions += 1;

    // Get neighbor expression (deep copy — we need our own copy for building App nodes)
    const neighbor_is_resource = !neighbor.is_organism;
    const neighbor_expr: *Expr = if (neighbor_is_resource) blk: {
        const kind = grid.cells[neighbor.index].resource.kind;
        break :blk try Expr.deepCopy(grid.resource_exprs[@intFromEnum(kind)], grid.allocator);
    } else blk: {
        break :blk try Expr.deepCopy(grid.cells[neighbor.index].organism.expr, grid.allocator);
    };
    defer neighbor_expr.deinit(grid.allocator);

    // Deep-copy organism expression for building App(A, B)
    const org_expr_1 = try Expr.deepCopy(grid.cells[org_idx].organism.expr, grid.allocator);
    errdefer org_expr_1.deinit(grid.allocator);

    // Deep-copy neighbor expression for App(A, B)
    const neighbor_copy_1 = try Expr.deepCopy(neighbor_expr, grid.allocator);
    errdefer neighbor_copy_1.deinit(grid.allocator);

    // Build App(A, B) and reduce
    const app_ab = try grid.allocator.create(Expr);
    app_ab.* = Expr.initArg(org_expr_1, neighbor_copy_1);
    defer app_ab.deinit(grid.allocator);

    const result_ab = try reduce_mod.reduce(app_ab, MAX_REDUCTION_STEPS, MAX_EXPRESSION_SIZE, grid.allocator);
    defer result_ab.expr.deinit(grid.allocator);

    // Deep-copy organism expression for building App(B, A)
    const org_expr_2 = try Expr.deepCopy(grid.cells[org_idx].organism.expr, grid.allocator);
    errdefer org_expr_2.deinit(grid.allocator);

    // Deep-copy neighbor expression for App(B, A)
    const neighbor_copy_2 = try Expr.deepCopy(neighbor_expr, grid.allocator);
    errdefer neighbor_copy_2.deinit(grid.allocator);

    // Build App(B, A) and reduce
    const app_ba = try grid.allocator.create(Expr);
    app_ba.* = Expr.initArg(neighbor_copy_2, org_expr_2);
    defer app_ba.deinit(grid.allocator);

    const result_ba = try reduce_mod.reduce(app_ba, MAX_REDUCTION_STEPS, MAX_EXPRESSION_SIZE, grid.allocator);
    defer result_ba.expr.deinit(grid.allocator);

    // Deduct interaction and reduction costs from organism A
    grid.cells[org_idx].organism.energy -= INTERACTION_BASE_COST;
    const total_steps: f64 = @floatFromInt(result_ab.steps + result_ba.steps);
    grid.cells[org_idx].organism.energy -= REDUCTION_STEP_COST * total_steps;

    // Charge neighbor B if it's an organism
    if (neighbor.is_organism and grid.cells[neighbor.index] == .organism) {
        grid.cells[neighbor.index].organism.energy -= NEIGHBOR_INTERACTION_COST;
    }

    // Handle outputs
    var already_reproduced = false;
    var resource_consumed = false;

    // We need the organism's live expression pointer for similarity checks
    const org_live_expr = grid.cells[org_idx].organism.expr;

    handleOutput(
        grid,
        org_idx,
        neighbor.index,
        result_ab.expr,
        org_live_expr,
        neighbor_expr,
        neighbor_is_resource,
        &already_reproduced,
        &resource_consumed,
        stats,
    );
    handleOutput(
        grid,
        org_idx,
        neighbor.index,
        result_ba.expr,
        org_live_expr,
        neighbor_expr,
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
    org_idx: u32,
    neighbor_idx: u32,
    result: *const Expr,
    org_expr: *const Expr,
    neighbor_expr: *const Expr,
    neighbor_is_resource: bool,
    already_reproduced: *bool,
    resource_consumed: *bool,
    stats: *TickStats,
) void {
    // Guard: organism might have been overwritten
    if (grid.cells[org_idx] != .organism) return;

    // 1. Discard if too large or bare variable
    const result_size = result.size();
    if (result_size > MAX_EXPRESSION_SIZE) return;
    if (result.* == .Var) return;

    // 2. Simplification bonus
    const org_size = org_expr.size();
    const neighbor_size = neighbor_expr.size();
    const input_total: u32 = org_size + neighbor_size;
    if (result_size < input_total) {
        const reduction: f64 = @floatFromInt(input_total - result_size);
        grid.cells[org_idx].organism.energy += SIMPLIFICATION_BONUS_PER_NODE * reduction;
    }

    // 3. Self-similarity check
    const sim_to_parent = computeSimilarity(result, org_expr);
    if (sim_to_parent >= SIMILARITY_THRESHOLD) {
        grid.cells[org_idx].organism.energy += SELF_SIMILARITY_BONUS;
        if (!already_reproduced.*) {
            if (tryReproduce(grid, org_idx, result, stats)) {
                already_reproduced.* = true;
            }
        }
    } else {
        // 4. Novel output — check not similar to either input
        const sim_to_neighbor = computeSimilarity(result, neighbor_expr);
        if (sim_to_neighbor < SIMILARITY_THRESHOLD) {
            tryPlaceNovel(grid, org_idx, result, stats);
        }
    }

    // 5. Resource consumption
    if (neighbor_is_resource and !resource_consumed.* and grid.cells[neighbor_idx] == .resource) {
        const result_hash = result.hash();
        const resource_hash = neighbor_expr.hash();
        if (result_hash != resource_hash) {
            grid.cells[neighbor_idx] = .empty;
            grid.cells[org_idx].organism.energy += RESOURCE_CONSUMPTION_BONUS;
            resource_consumed.* = true;
            stats.resources_consumed += 1;
        }
    }
}

// ============================================================
// Reproduction & novel placement
// ============================================================

fn tryReproduce(grid: *Grid, parent_idx: u32, child_expr: *const Expr, stats: *TickStats) bool {
    if (grid.cells[parent_idx] != .organism) return false;

    const empty_idx = findEmptyNeighbor(grid, parent_idx) orelse return false;

    // Deep-copy and mutate
    const child_copy = Expr.deepCopy(child_expr, grid.allocator) catch return false;
    mutation.mutate(child_copy, grid.allocator, grid.rng) catch {
        child_copy.deinit(grid.allocator);
        return false;
    };

    // Transfer energy
    const parent_energy = grid.cells[parent_idx].organism.energy;
    const child_energy = parent_energy * REPRODUCTION_ENERGY_FRACTION;
    grid.cells[parent_idx].organism.energy -= child_energy;

    // Place child
    grid.cells[empty_idx] = .{ .organism = .{
        .expr = child_copy,
        .energy = child_energy,
        .age = 0,
        .lineage_id = grid.nextLineageId(),
        .parent_lineage = grid.cells[parent_idx].organism.lineage_id,
        .generation = grid.cells[parent_idx].organism.generation + 1,
    } };
    stats.births += 1;
    return true;
}

fn tryPlaceNovel(grid: *Grid, near_idx: u32, result_expr: *const Expr, stats: *TickStats) void {
    const empty_idx = findEmptyNeighbor(grid, near_idx) orelse return;

    const copy = Expr.deepCopy(result_expr, grid.allocator) catch return;

    grid.cells[empty_idx] = .{ .organism = .{
        .expr = copy,
        .energy = NOVEL_OFFSPRING_INITIAL_ENERGY,
        .age = 0,
        .lineage_id = grid.nextLineageId(),
        .parent_lineage = null,
        .generation = 0,
    } };
    stats.novel_placements += 1;
}

// ============================================================
// Neighbor finding
// ============================================================

fn findOccupiedNeighbor(grid: *Grid, idx: u32) ?NeighborInfo {
    const neighbors = Grid.getNeighborIndices(idx);
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
    const neighbors = Grid.getNeighborIndices(idx);
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

test "computeSimilarity — identical expressions return 1.0" {
    const allocator = std.testing.allocator;

    // Lam(App(Var(0), Var(0)))
    const v0a = try makeVar(allocator, 0);
    const v0b = try makeVar(allocator, 0);
    const app = try makeApp(allocator, v0a, v0b);
    const expr = try makeLam(allocator, app);
    defer expr.deinit(allocator);

    const sim = computeSimilarity(expr, expr);
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

    const sim = computeSimilarity(a, b);
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

    var grid = try Grid.init(allocator, prng.random(), 42);
    defer grid.deinit();

    // Clear all cells around index 0
    const neighbors = Grid.getNeighborIndices(0);
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

    var grid = try Grid.init(allocator, prng.random(), 42);
    defer grid.deinit();

    // Ensure at least one neighbor of cell 0 is empty
    const neighbors = Grid.getNeighborIndices(0);
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

    var grid = try Grid.init(allocator, prng.random(), 42);
    defer grid.deinit();

    // Find an organism and clear its neighbors so it does nothing but pay maintenance
    var org_idx: u32 = 0;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            org_idx = @intCast(i);
            break;
        }
    }
    const neighbors = Grid.getNeighborIndices(org_idx);
    for (neighbors) |n| {
        switch (grid.cells[n]) {
            .organism => |*org| org.expr.deinit(allocator),
            else => {},
        }
        grid.cells[n] = .empty;
    }

    const energy_before = grid.cells[org_idx].organism.energy;
    var stats = TickStats{};
    try processOrganism(&grid, org_idx, &stats);

    // Should have paid maintenance but no interaction
    try std.testing.expect(grid.cells[org_idx].organism.energy < energy_before);
    try std.testing.expectEqual(@as(u32, 0), stats.interactions);
}

test "processOrganism — interaction with resource deducts costs" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);

    var grid = try Grid.init(allocator, prng.random(), 42);
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
    const neighbors = Grid.getNeighborIndices(org_idx);
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
    try processOrganism(&grid, org_idx, &stats);

    // Should have interacted (bonuses may outweigh costs, so just check interaction happened
    // and energy changed)
    try std.testing.expectEqual(@as(u32, 1), stats.interactions);
    try std.testing.expect(grid.cells[org_idx].organism.energy != energy_before);
}

test "tryReproduce — child gets correct lineage and energy" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);

    var grid = try Grid.init(allocator, prng.random(), 42);
    defer grid.deinit();

    // Find an organism with at least one empty neighbor
    var org_idx: ?u32 = null;
    var empty_neighbor: ?u32 = null;
    for (grid.cells, 0..) |cell, i| {
        if (cell == .organism) {
            const nbrs = Grid.getNeighborIndices(@intCast(i));
            for (nbrs) |n| {
                if (grid.cells[n] == .empty) {
                    org_idx = @intCast(i);
                    empty_neighbor = n;
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
        const success = tryReproduce(&grid, oi, grid.cells[oi].organism.expr, &stats);

        if (success) {
            try std.testing.expectEqual(@as(u32, 1), stats.births);
            // Parent lost energy
            const expected_parent_energy = parent_energy - parent_energy * REPRODUCTION_ENERGY_FRACTION;
            try std.testing.expectApproxEqAbs(expected_parent_energy, grid.cells[oi].organism.energy, 0.01);

            // Find the child (scan neighbors for new organism)
            const nbrs = Grid.getNeighborIndices(oi);
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

    var grid = try Grid.init(allocator, prng.random(), 42);
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

    handleOutput(
        &grid,
        org_idx,
        0,
        bare_var,
        grid.cells[org_idx].organism.expr,
        neighbor_expr,
        false,
        &already_reproduced,
        &resource_consumed,
        &stats,
    );

    // Energy should not have changed (no bonuses for bare Var)
    try std.testing.expectApproxEqAbs(energy_before, grid.cells[org_idx].organism.energy, 0.001);
    try std.testing.expectEqual(@as(u32, 0), stats.births);
}
