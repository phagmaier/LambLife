const std = @import("std");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const interaction = @import("interaction.zig");
const TickStats = interaction.TickStats;
const Config = @import("config.zig").Config;
const metrics = @import("metrics.zig");
const snapshot = @import("snapshot.zig");

pub const StepResult = struct {
    tick_stats: TickStats,
    deaths_energy: u32,
    deaths_age: u32,
};

pub const Simulation = struct {
    prng: std.Random.DefaultPrng,
    grid: Grid,
    tick: u64,
    config: Config,
    allocator: std.mem.Allocator,
    metric_logger: metrics.MetricLogger,
    lineage_log: metrics.LineageLog,
    snapshot_dir: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config, seed: u64, csv_path: ?[]const u8) !Simulation {
        var sim = Simulation{
            .prng = std.Random.DefaultPrng.init(seed),
            .grid = undefined,
            .tick = 0,
            .config = config,
            .allocator = allocator,
            .metric_logger = try metrics.MetricLogger.init(csv_path),
            .lineage_log = metrics.LineageLog.init(allocator),
            .snapshot_dir = null,
        };
        sim.grid = try Grid.init(allocator, sim.prng.random(), seed, config);
        return sim;
    }

    pub fn loadFromSnapshot(allocator: std.mem.Allocator, path: []const u8, csv_path: ?[]const u8) !Simulation {
        var sim = try snapshot.load(allocator, path, csv_path);
        sim.snapshot_dir = null;
        return sim;
    }

    /// Re-wire grid.rng to point at this simulation's prng.
    /// Must be called after the Simulation is in its final memory location
    /// (e.g. after assignment from init/load, before calling step/run).
    pub fn rewireRng(self: *Simulation) void {
        self.grid.rng = self.prng.random();
    }

    pub fn deinit(self: *Simulation) void {
        self.lineage_log.deinit();
        self.metric_logger.deinit();
        self.grid.deinit();
    }

    /// Run one simulation tick: inject -> decay -> interact -> death sweep -> age increment.
    pub fn step(self: *Simulation) !StepResult {
        // 1. Inject resources
        self.grid.injectResources();

        // 2. Decay resources
        self.grid.decayResources();

        // 3. Organism interactions
        const tick_stats = try interaction.processTick(&self.grid);

        // 4. Death sweep
        var deaths_energy: u32 = 0;
        var deaths_age: u32 = 0;
        for (self.grid.cells) |*cell| {
            switch (cell.*) {
                .organism => |*org| {
                    if (org.energy <= 0) {
                        org.expr.deinit(self.allocator);
                        cell.* = .empty;
                        deaths_energy += 1;
                    }
                },
                else => {},
            }
        }

        // 5. Age increment + age death
        for (self.grid.cells) |*cell| {
            switch (cell.*) {
                .organism => |*org| {
                    org.age += 1;
                    if (org.age > self.config.max_organism_age) {
                        org.expr.deinit(self.allocator);
                        cell.* = .empty;
                        deaths_age += 1;
                    }
                },
                else => {},
            }
        }

        self.tick += 1;

        return .{
            .tick_stats = tick_stats,
            .deaths_energy = deaths_energy,
            .deaths_age = deaths_age,
        };
    }

    /// Run multiple ticks with full metric collection and logging.
    pub fn run(self: *Simulation, num_ticks: u64) !void {
        const diversity_interval: u64 = 1000;

        for (0..num_ticks) |_| {
            const result = try self.step();

            // Record lineage for births that happened this tick
            // (scan for organisms born this tick = age 0 with a parent)
            for (self.grid.cells) |cell| {
                switch (cell) {
                    .organism => |org| {
                        if (org.age == 0 and org.parent_lineage != null) {
                            try self.lineage_log.record(
                                self.tick,
                                org.lineage_id,
                                org.parent_lineage.?,
                                org.generation,
                                org.expr.hash(),
                            );
                        }
                    },
                    else => {},
                }
            }

            if (self.tick % self.config.log_interval == 0) {
                var m = metrics.collectTickMetrics(&self.grid, self.tick, result.tick_stats, result.deaths_energy, result.deaths_age);

                // Attach unique structure count from diversity if at diversity interval
                if (self.tick % diversity_interval == 0) {
                    var report = try metrics.collectDiversity(&self.grid, self.allocator);
                    defer report.deinit();
                    m.unique_structures = report.unique_count;
                    metrics.printDiversityReport(report, self.tick);
                }

                metrics.printTickMetrics(m);
                try self.metric_logger.log(m);
            }

            // Save snapshot at configured interval
            if (self.snapshot_dir != null and self.config.snapshot_interval > 0 and self.tick % self.config.snapshot_interval == 0) {
                const path = try snapshot.snapshotPath(self.allocator, self.snapshot_dir.?, self.tick);
                defer self.allocator.free(path);
                snapshot.save(self, path) catch |err| {
                    std.debug.print("Warning: snapshot save failed at tick {d}: {}\n", .{ self.tick, err });
                };
                std.debug.print("Snapshot saved: {s}\n", .{path});
            }
        }
    }
};

// ============================================================
// Tests
// ============================================================

test "simulation runs one step without crashing" {
    const allocator = std.testing.allocator;
    const config = Config{ .width = 10, .height = 10 };

    var sim = try Simulation.init(allocator, config, 42, null);
    defer sim.deinit();

    const result = try sim.step();
    try std.testing.expectEqual(@as(u64, 1), sim.tick);
    // Just verify it returns something reasonable
    _ = result;
}

test "simulation death sweep removes zero-energy organisms" {
    const allocator = std.testing.allocator;
    // Use a tiny grid with no resources so interactions can't create new organisms
    const config = Config{ .width = 10, .height = 10, .initial_resource_fraction = 0, .resource_injection_rate = 0 };

    var sim = try Simulation.init(allocator, config, 42, null);
    defer sim.deinit();

    // Set all organisms to very negative energy so even offspring die
    for (sim.grid.cells) |*cell| {
        switch (cell.*) {
            .organism => |*org| org.energy = -9999,
            else => {},
        }
    }

    const result = try sim.step();
    try std.testing.expect(result.deaths_energy > 0);
}

test "simulation age death removes old organisms" {
    const allocator = std.testing.allocator;
    const config = Config{ .width = 10, .height = 10, .max_organism_age = 5 };

    var sim = try Simulation.init(allocator, config, 42, null);
    defer sim.deinit();

    // Set all organisms to max age and high energy so they don't die from energy
    for (sim.grid.cells) |*cell| {
        switch (cell.*) {
            .organism => |*org| {
                org.age = 5;
                org.energy = 99999;
            },
            else => {},
        }
    }

    const result = try sim.step();
    try std.testing.expect(result.deaths_age > 0);
}
