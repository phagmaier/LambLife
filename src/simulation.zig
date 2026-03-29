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
    resource_injection_attempts: u32,
    resources_injected: u32,
    resource_injection_blocked: u32,
    net_energy_delta: f64,
    inject_ns: u64,
    decay_ns: u64,
    interactions_ns: u64,
    death_sweep_ns: u64,
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
    cumulative_stats: metrics.CumulativeStats,

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
            .cumulative_stats = .{},
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
        const tick_number = self.tick + 1;
        const energy_before = totalOrganismEnergy(&self.grid);

        // 1. Inject resources
        const inject_start = std.time.nanoTimestamp();
        const injection_stats = self.grid.injectResources();
        const inject_ns = durationNsSince(inject_start);

        // 2. Decay resources
        const decay_start = std.time.nanoTimestamp();
        self.grid.decayResources();
        const decay_ns = durationNsSince(decay_start);

        // 3. Organism interactions
        const interactions_start = std.time.nanoTimestamp();
        var birth_recorder = interaction.BirthRecorder.init(self.allocator);
        defer birth_recorder.deinit();
        const tick_stats = try interaction.processTick(&self.grid, &birth_recorder);
        const interactions_ns = durationNsSince(interactions_start);

        for (birth_recorder.records.items) |rec| {
            try self.lineage_log.record(
                tick_number,
                rec.child_lineage,
                rec.parent_lineage,
                rec.generation,
                rec.expr_hash,
                @tagName(rec.kind),
            );
        }

        // 4. Death sweep
        const death_sweep_start = std.time.nanoTimestamp();
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
        const death_sweep_ns = durationNsSince(death_sweep_start);

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
        self.cumulative_stats.births += tick_stats.births;
        self.cumulative_stats.novel_placements += tick_stats.novel_placements;
        self.cumulative_stats.deaths_energy += deaths_energy;
        self.cumulative_stats.deaths_age += deaths_age;
        self.cumulative_stats.resources_consumed += tick_stats.resources_consumed;
        self.cumulative_stats.interactions += tick_stats.interactions;
        const net_energy_delta = totalOrganismEnergy(&self.grid) - energy_before;

        return .{
            .tick_stats = tick_stats,
            .deaths_energy = deaths_energy,
            .deaths_age = deaths_age,
            .resource_injection_attempts = injection_stats.attempts,
            .resources_injected = injection_stats.injected,
            .resource_injection_blocked = injection_stats.blocked,
            .net_energy_delta = net_energy_delta,
            .inject_ns = inject_ns,
            .decay_ns = decay_ns,
            .interactions_ns = interactions_ns,
            .death_sweep_ns = death_sweep_ns,
        };
    }

    /// Run multiple ticks with full metric collection and logging.
    pub fn run(self: *Simulation, num_ticks: u64) !void {
        const diversity_interval: u64 = 1000;

        for (0..num_ticks) |_| {
            const result = try self.step();
            var metrics_ns: u64 = 0;
            var snapshot_ns: u64 = 0;

            if (self.tick % self.config.log_interval == 0) {
                const metrics_start = std.time.nanoTimestamp();
                var m = metrics.collectTickMetrics(
                    &self.grid,
                    self.tick,
                    result.tick_stats,
                    result.deaths_energy,
                    result.deaths_age,
                    result.resource_injection_attempts,
                    result.resources_injected,
                    result.resource_injection_blocked,
                    self.cumulative_stats,
                    result.net_energy_delta,
                );

                // Attach unique structure count from diversity if at diversity interval
                if (self.tick % diversity_interval == 0) {
                    var report = try metrics.collectDiversity(&self.grid, self.allocator);
                    defer report.deinit();
                    m.unique_structures = report.unique_count;
                    metrics.printDiversityReport(report, self.tick);
                }

                metrics.printTickMetrics(m);
                try self.metric_logger.log(m);
                metrics_ns = durationNsSince(metrics_start);
                printProfiling(self.tick, result, metrics_ns, snapshot_ns);
            }

            // Save snapshot at configured interval
            if (self.snapshot_dir != null and self.config.snapshot_interval > 0 and self.tick % self.config.snapshot_interval == 0) {
                const snapshot_start = std.time.nanoTimestamp();
                const path = try snapshot.snapshotPath(self.allocator, self.snapshot_dir.?, self.tick);
                defer self.allocator.free(path);
                snapshot.save(self, path) catch |err| {
                    std.debug.print("Warning: snapshot save failed at tick {d}: {}\n", .{ self.tick, err });
                };
                snapshot_ns = durationNsSince(snapshot_start);
                std.debug.print("Snapshot saved: {s}\n", .{path});
            }
        }
    }
};

fn totalOrganismEnergy(grid: *const Grid) f64 {
    var total: f64 = 0;
    for (grid.cells) |cell| {
        switch (cell) {
            .organism => |org| total += org.energy,
            else => {},
        }
    }
    return total;
}

fn durationNsSince(start_ns: i128) u64 {
    const elapsed = std.time.nanoTimestamp() - start_ns;
    return @intCast(@max(elapsed, 0));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn printProfiling(tick: u64, result: StepResult, metrics_ns: u64, snapshot_ns: u64) void {
    std.debug.print(
        "profile tick={d} orgs={d} reductions={d} beta_steps={d} size_hits={d} step_hits={d} " ++
            "t_inject={d:.2}ms t_decay={d:.2}ms t_interact={d:.2}ms t_death={d:.2}ms t_metrics={d:.2}ms t_snapshot={d:.2}ms\n",
        .{
            tick,
            result.tick_stats.organisms_processed,
            result.tick_stats.reductions_attempted,
            result.tick_stats.beta_steps,
            result.tick_stats.size_limit_hits,
            result.tick_stats.step_limit_hits,
            nsToMs(result.inject_ns),
            nsToMs(result.decay_ns),
            nsToMs(result.interactions_ns),
            nsToMs(result.death_sweep_ns),
            nsToMs(metrics_ns),
            nsToMs(snapshot_ns),
        },
    );
}

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
