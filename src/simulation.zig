const std = @import("std");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const interaction = @import("interaction.zig");
const TickStats = interaction.TickStats;
const Config = @import("config.zig").Config;

pub const StepResult = struct {
    tick_stats: TickStats,
    deaths_energy: u32,
    deaths_age: u32,
};

pub const Simulation = struct {
    grid: Grid,
    tick: u64,
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config, seed: u64) !Simulation {
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .grid = try Grid.init(allocator, prng.random(), seed, config),
            .tick = 0,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Simulation) void {
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

    /// Run multiple ticks, printing stats at each log interval.
    pub fn run(self: *Simulation, num_ticks: u64) !void {
        for (0..num_ticks) |_| {
            const result = try self.step();

            if (self.tick % self.config.log_interval == 0) {
                const counts = self.grid.countCells();
                const mean_energy = self.computeMeanEnergy();

                std.debug.print("tick={d} pop={d} res={d} empty={d} births={d} deaths_e={d} deaths_a={d} interactions={d} mean_energy={d:.1}\n", .{
                    self.tick,
                    counts.organisms,
                    counts.resources,
                    counts.empty,
                    result.tick_stats.births,
                    result.deaths_energy,
                    result.deaths_age,
                    result.tick_stats.interactions,
                    mean_energy,
                });
            }
        }
    }

    fn computeMeanEnergy(self: *const Simulation) f64 {
        var total: f64 = 0;
        var count: u32 = 0;
        for (self.grid.cells) |cell| {
            switch (cell) {
                .organism => |org| {
                    total += org.energy;
                    count += 1;
                },
                else => {},
            }
        }
        if (count == 0) return 0;
        return total / @as(f64, @floatFromInt(count));
    }
};

// ============================================================
// Tests
// ============================================================

test "simulation runs one step without crashing" {
    const allocator = std.testing.allocator;
    const config = Config{ .width = 10, .height = 10 };

    var sim = try Simulation.init(allocator, config, 42);
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

    var sim = try Simulation.init(allocator, config, 42);
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

    var sim = try Simulation.init(allocator, config, 42);
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
