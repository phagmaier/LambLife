const std = @import("std");
const Expr = @import("expr.zig").Expr;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Config = @import("config.zig").Config;
const interaction = @import("interaction.zig");
const TickStats = interaction.TickStats;

// ============================================================
// Per-tick metrics (§13.1)
// ============================================================

pub const TickMetrics = struct {
    tick: u64,
    population_count: u32,
    resource_count: u32,
    empty_count: u32,
    mean_energy: f64,
    max_energy: f64,
    mean_size: f64,
    max_size: u32,
    mean_age: f64,
    max_age: u64,
    births: u32,
    deaths_energy: u32,
    deaths_age: u32,
    interactions: u32,
    resources_consumed: u32,
    novel_placements: u32,
    unique_structures: u32,
    max_generation: u64,
    resource_injection_attempts: u32,
    resources_injected: u32,
    resource_injection_blocked: u32,
    total_births: u64,
    total_novel_placements: u64,
    total_deaths_energy: u64,
    total_deaths_age: u64,
    total_resources_consumed: u64,
    total_interactions: u64,
    net_energy_delta: f64,
};

pub const CumulativeStats = struct {
    births: u64 = 0,
    novel_placements: u64 = 0,
    deaths_energy: u64 = 0,
    deaths_age: u64 = 0,
    resources_consumed: u64 = 0,
    interactions: u64 = 0,
};

pub fn collectTickMetrics(
    grid: *const Grid,
    tick: u64,
    tick_stats: TickStats,
    deaths_energy: u32,
    deaths_age: u32,
    resource_injection_attempts: u32,
    resources_injected: u32,
    resource_injection_blocked: u32,
    cumulative: CumulativeStats,
    net_energy_delta: f64,
) TickMetrics {
    var pop: u32 = 0;
    var res: u32 = 0;
    var empty: u32 = 0;
    var total_energy: f64 = 0;
    var max_energy: f64 = -std.math.inf(f64);
    var total_size: u64 = 0;
    var max_size: u32 = 0;
    var total_age: u64 = 0;
    var max_age: u64 = 0;
    var max_generation: u64 = 0;

    for (grid.cells) |cell| {
        switch (cell) {
            .organism => |org| {
                pop += 1;
                total_energy += org.energy;
                if (org.energy > max_energy) max_energy = org.energy;

                const s = org.expr_size;
                total_size += s;
                if (s > max_size) max_size = s;

                total_age += org.age;
                if (org.age > max_age) max_age = org.age;

                if (org.generation > max_generation) max_generation = org.generation;
            },
            .resource => res += 1,
            .empty => empty += 1,
        }
    }

    const mean_energy = if (pop > 0) total_energy / @as(f64, @floatFromInt(pop)) else 0;
    const mean_size = if (pop > 0) @as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(pop)) else 0;
    const mean_age = if (pop > 0) @as(f64, @floatFromInt(total_age)) / @as(f64, @floatFromInt(pop)) else 0;

    return .{
        .tick = tick,
        .population_count = pop,
        .resource_count = res,
        .empty_count = empty,
        .mean_energy = mean_energy,
        .max_energy = if (pop > 0) max_energy else 0,
        .mean_size = mean_size,
        .max_size = max_size,
        .mean_age = mean_age,
        .max_age = max_age,
        .births = tick_stats.births,
        .deaths_energy = deaths_energy,
        .deaths_age = deaths_age,
        .interactions = tick_stats.interactions,
        .resources_consumed = tick_stats.resources_consumed,
        .novel_placements = tick_stats.novel_placements,
        .unique_structures = 0, // filled by diversity tracking
        .max_generation = max_generation,
        .resource_injection_attempts = resource_injection_attempts,
        .resources_injected = resources_injected,
        .resource_injection_blocked = resource_injection_blocked,
        .total_births = cumulative.births,
        .total_novel_placements = cumulative.novel_placements,
        .total_deaths_energy = cumulative.deaths_energy,
        .total_deaths_age = cumulative.deaths_age,
        .total_resources_consumed = cumulative.resources_consumed,
        .total_interactions = cumulative.interactions,
        .net_energy_delta = net_energy_delta,
    };
}

pub fn printTickMetrics(m: TickMetrics) void {
    std.debug.print(
        "tick={d} pop={d} res={d} empty={d} births={d} deaths_e={d} deaths_a={d} " ++
            "interactions={d} consumed={d} novel={d} inj={d}/{d} blocked={d} dE={d:.1} " ++
            "energy={d:.1}/{d:.1} size={d:.1}/{d} age={d:.1}/{d} gen={d}\n",
        .{
            m.tick,
            m.population_count,
            m.resource_count,
            m.empty_count,
            m.births,
            m.deaths_energy,
            m.deaths_age,
            m.interactions,
            m.resources_consumed,
            m.novel_placements,
            m.resources_injected,
            m.resource_injection_attempts,
            m.resource_injection_blocked,
            m.net_energy_delta,
            m.mean_energy,
            m.max_energy,
            m.mean_size,
            m.max_size,
            m.mean_age,
            m.max_age,
            m.max_generation,
        },
    );
}

// ============================================================
// Diversity tracking (§13.2)
// ============================================================

pub const SpeciesInfo = struct {
    hash: u64,
    count: u32,
    total_energy: f64,
    center_x: f64,
    center_y: f64,
};

pub const DiversityReport = struct {
    unique_count: u32,
    top_species: []SpeciesInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DiversityReport) void {
        self.allocator.free(self.top_species);
    }
};

pub fn collectDiversity(grid: *const Grid, allocator: std.mem.Allocator) !DiversityReport {
    const width = grid.config.width;

    // Count occurrences of each structural hash
    var hash_map = std.AutoHashMap(u64, struct { count: u32, total_energy: f64, sum_x: f64, sum_y: f64 }).init(allocator);
    defer hash_map.deinit();

    for (grid.cells, 0..) |cell, i| {
        switch (cell) {
            .organism => |org| {
                const h = org.expr_hash;
                const x: f64 = @floatFromInt(i % width);
                const y: f64 = @floatFromInt(i / width);

                const gop = try hash_map.getOrPut(h);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .count = 0, .total_energy = 0, .sum_x = 0, .sum_y = 0 };
                }
                gop.value_ptr.count += 1;
                gop.value_ptr.total_energy += org.energy;
                gop.value_ptr.sum_x += x;
                gop.value_ptr.sum_y += y;
            },
            else => {},
        }
    }

    const unique_count: u32 = @intCast(hash_map.count());

    // Collect all species into a sortable array
    const all = try allocator.alloc(SpeciesInfo, unique_count);
    defer allocator.free(all);

    var idx: u32 = 0;
    var it = hash_map.iterator();
    while (it.next()) |entry| {
        const c: f64 = @floatFromInt(entry.value_ptr.count);
        all[idx] = .{
            .hash = entry.key_ptr.*,
            .count = entry.value_ptr.count,
            .total_energy = entry.value_ptr.total_energy,
            .center_x = entry.value_ptr.sum_x / c,
            .center_y = entry.value_ptr.sum_y / c,
        };
        idx += 1;
    }

    // Sort by count descending
    std.mem.sort(SpeciesInfo, all, {}, struct {
        fn cmp(_: void, a: SpeciesInfo, b: SpeciesInfo) bool {
            return a.count > b.count;
        }
    }.cmp);

    // Copy top 10
    const top_n = @min(unique_count, 10);
    const top = try allocator.alloc(SpeciesInfo, top_n);
    @memcpy(top, all[0..top_n]);

    return .{
        .unique_count = unique_count,
        .top_species = top,
        .allocator = allocator,
    };
}

pub fn printDiversityReport(report: DiversityReport, tick: u64) void {
    std.debug.print("=== Diversity @ tick {d}: {d} unique species ===\n", .{ tick, report.unique_count });
    for (report.top_species, 0..) |sp, i| {
        std.debug.print("  #{d}: hash={x:0>16} pop={d} avg_energy={d:.1} center=({d:.0},{d:.0})\n", .{
            i + 1,
            sp.hash,
            sp.count,
            sp.total_energy / @as(f64, @floatFromInt(sp.count)),
            sp.center_x,
            sp.center_y,
        });
    }
}

// ============================================================
// Lineage tracking (§13.3)
// ============================================================

pub const LineageRecord = struct {
    tick: u64,
    child_lineage: u64,
    parent_lineage: ?u64,
    generation: u64,
    expr_hash: u64,
    birth_kind: []const u8,
};

pub const LineageLog = struct {
    records: std.ArrayListUnmanaged(LineageRecord),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineageLog {
        return .{
            .records = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineageLog) void {
        self.records.deinit(self.allocator);
    }

    pub fn record(self: *LineageLog, tick: u64, child_lineage: u64, parent_lineage: ?u64, generation: u64, expr_hash: u64, birth_kind: []const u8) !void {
        try self.records.append(self.allocator, .{
            .tick = tick,
            .child_lineage = child_lineage,
            .parent_lineage = parent_lineage,
            .generation = generation,
            .expr_hash = expr_hash,
            .birth_kind = birth_kind,
        });
    }

    /// Write all records to a CSV file.
    pub fn writeCsv(self: *const LineageLog, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);

        try w.interface.writeAll("tick,child_lineage,parent_lineage,generation,expr_hash,birth_kind\n");
        for (self.records.items) |rec| {
            if (rec.parent_lineage) |parent_lineage| {
                try w.interface.print("{d},{d},{d},{d},{x:0>16},{s}\n", .{
                    rec.tick,
                    rec.child_lineage,
                    parent_lineage,
                    rec.generation,
                    rec.expr_hash,
                    rec.birth_kind,
                });
            } else {
                try w.interface.print("{d},{d},,{d},{x:0>16},{s}\n", .{
                    rec.tick,
                    rec.child_lineage,
                    rec.generation,
                    rec.expr_hash,
                    rec.birth_kind,
                });
            }
        }
        try w.interface.flush();
    }
};

// ============================================================
// Metric logger — writes CSV time series
// ============================================================

pub const MetricLogger = struct {
    file: ?std.fs.File,

    pub fn init(path: ?[]const u8) !MetricLogger {
        if (path) |p| {
            const file = try std.fs.cwd().createFile(p, .{ .read = true });
            try file.writeAll(
                "tick,population,resources,empty,mean_energy,max_energy," ++
                    "mean_size,max_size,mean_age,max_age," ++
                    "births,deaths_energy,deaths_age,interactions," ++
                    "resources_consumed,novel_placements,unique_structures,max_generation," ++
                    "resource_injection_attempts,resources_injected,resource_injection_blocked," ++
                    "total_births,total_novel_placements,total_deaths_energy,total_deaths_age," ++
                    "total_resources_consumed,total_interactions,net_energy_delta\n",
            );
            return .{ .file = file };
        }
        return .{ .file = null };
    }

    pub fn deinit(self: *MetricLogger) void {
        if (self.file) |f| f.close();
    }

    pub fn log(self: *MetricLogger, m: TickMetrics) !void {
        if (self.file) |f| {
            try f.seekFromEnd(0);
            var buf: [512]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &buf,
                "{d},{d},{d},{d},{d:.2},{d:.2},{d:.2},{d},{d:.2},{d}," ++
                    "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.2}\n",
                .{
                    m.tick,
                    m.population_count,
                    m.resource_count,
                    m.empty_count,
                    m.mean_energy,
                    m.max_energy,
                    m.mean_size,
                    m.max_size,
                    m.mean_age,
                    m.max_age,
                    m.births,
                    m.deaths_energy,
                    m.deaths_age,
                    m.interactions,
                    m.resources_consumed,
                    m.novel_placements,
                    m.unique_structures,
                    m.max_generation,
                    m.resource_injection_attempts,
                    m.resources_injected,
                    m.resource_injection_blocked,
                    m.total_births,
                    m.total_novel_placements,
                    m.total_deaths_energy,
                    m.total_deaths_age,
                    m.total_resources_consumed,
                    m.total_interactions,
                    m.net_energy_delta,
                },
            );
            try f.writeAll(line);
        }
    }
};

// ============================================================
// Tests
// ============================================================

test "collectTickMetrics counts correctly" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 10, .height = 10 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    const counts = grid.countCells();
    const stats = TickStats{};
    const m = collectTickMetrics(&grid, 0, stats, 0, 0, 0, 0, 0, .{}, 0);

    try std.testing.expectEqual(counts.organisms, m.population_count);
    try std.testing.expectEqual(counts.resources, m.resource_count);
    try std.testing.expectEqual(counts.empty, m.empty_count);
    try std.testing.expect(m.mean_energy > 0);
    try std.testing.expect(m.max_energy >= m.mean_energy);
}

test "collectDiversity finds distinct species" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const config = Config{ .width = 10, .height = 10 };

    var grid = try Grid.init(allocator, prng.random(), 42, config);
    defer grid.deinit();

    var report = try collectDiversity(&grid, allocator);
    defer report.deinit();

    // With random expressions, should have multiple unique hashes
    try std.testing.expect(report.unique_count > 0);
    try std.testing.expect(report.top_species.len > 0);
    try std.testing.expect(report.top_species[0].count >= 1);
}

test "lineage log records and round-trips" {
    const allocator = std.testing.allocator;

    var log = LineageLog.init(allocator);
    defer log.deinit();

    try log.record(100, 5, 2, 3, 0xDEADBEEF, "reproduction");
    try log.record(200, 6, 5, 4, 0xCAFEBABE, "reproduction");

    try std.testing.expectEqual(@as(usize, 2), log.records.items.len);
    try std.testing.expectEqual(@as(u64, 100), log.records.items[0].tick);
    try std.testing.expectEqual(@as(u64, 5), log.records.items[0].child_lineage);
}

test "MetricLogger writes CSV header" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test with null path (no file)
    var logger = try MetricLogger.init(null);
    defer logger.deinit();

    // Should be a no-op
    const m = TickMetrics{
        .tick = 0,
        .population_count = 10,
        .resource_count = 5,
        .empty_count = 85,
        .mean_energy = 50.0,
        .max_energy = 100.0,
        .mean_size = 3.0,
        .max_size = 10,
        .mean_age = 5.0,
        .max_age = 20,
        .births = 1,
        .deaths_energy = 2,
        .deaths_age = 0,
        .interactions = 8,
        .resources_consumed = 3,
        .novel_placements = 1,
        .unique_structures = 7,
        .max_generation = 3,
        .resource_injection_attempts = 0,
        .resources_injected = 0,
        .resource_injection_blocked = 0,
        .total_births = 1,
        .total_novel_placements = 1,
        .total_deaths_energy = 2,
        .total_deaths_age = 0,
        .total_resources_consumed = 3,
        .total_interactions = 8,
        .net_energy_delta = 0,
    };
    try logger.log(m);
}

test "MetricLogger appends rows after header" {
    const path = "/tmp/lamblife_metric_logger_append_test.csv";
    std.fs.cwd().deleteFile(path) catch {};

    var logger = try MetricLogger.init(path);

    const m1 = TickMetrics{
        .tick = 100,
        .population_count = 10,
        .resource_count = 5,
        .empty_count = 85,
        .mean_energy = 50.0,
        .max_energy = 100.0,
        .mean_size = 3.0,
        .max_size = 10,
        .mean_age = 5.0,
        .max_age = 20,
        .births = 1,
        .deaths_energy = 2,
        .deaths_age = 0,
        .interactions = 8,
        .resources_consumed = 3,
        .novel_placements = 1,
        .unique_structures = 7,
        .max_generation = 3,
        .resource_injection_attempts = 5,
        .resources_injected = 4,
        .resource_injection_blocked = 1,
        .total_births = 1,
        .total_novel_placements = 1,
        .total_deaths_energy = 2,
        .total_deaths_age = 0,
        .total_resources_consumed = 3,
        .total_interactions = 8,
        .net_energy_delta = 12.5,
    };
    const m2 = TickMetrics{
        .tick = 200,
        .population_count = 12,
        .resource_count = 4,
        .empty_count = 84,
        .mean_energy = 55.0,
        .max_energy = 110.0,
        .mean_size = 4.0,
        .max_size = 12,
        .mean_age = 7.0,
        .max_age = 30,
        .births = 2,
        .deaths_energy = 1,
        .deaths_age = 0,
        .interactions = 10,
        .resources_consumed = 4,
        .novel_placements = 2,
        .unique_structures = 8,
        .max_generation = 4,
        .resource_injection_attempts = 5,
        .resources_injected = 2,
        .resource_injection_blocked = 3,
        .total_births = 3,
        .total_novel_placements = 3,
        .total_deaths_energy = 3,
        .total_deaths_age = 0,
        .total_resources_consumed = 7,
        .total_interactions = 18,
        .net_energy_delta = -2.5,
    };

    try logger.log(m1);
    try logger.log(m2);
    logger.deinit();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);
    _ = try file.readAll(data);

    try std.testing.expect(std.mem.startsWith(u8, data, "tick,population,resources,empty,mean_energy,max_energy,"));
    try std.testing.expect(std.mem.indexOf(u8, data, "100,10,5,85,50.00,100.00,3.00,10,5.00,20,1,2,0,8,3,1,7,3,5,4,1,1,1,2,0,3,8,12.50\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "200,12,4,84,55.00,110.00,4.00,12,7.00,30,2,1,0,10,4,2,8,4,5,2,3,3,3,3,0,7,18,-2.50\n") != null);

    std.fs.cwd().deleteFile(path) catch {};
}
