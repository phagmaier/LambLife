const std = @import("std");
const Config = @import("config.zig").Config;
const Simulation = @import("simulation.zig").Simulation;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config{};
    const seed: u64 = @intCast(std.time.timestamp());

    std.debug.print("LambLife starting: {d}x{d} grid, seed={d}\n", .{ config.width, config.height, seed });

    var sim = try Simulation.init(allocator, config, seed);
    defer sim.deinit();

    try sim.run(10_000);

    std.debug.print("Simulation complete.\n", .{});
}

// Pull in tests from all modules
test {
    _ = @import("expr.zig");
    _ = @import("reduce.zig");
    _ = @import("mutation.zig");
    _ = @import("grid.zig");
    _ = @import("interaction.zig");
    _ = @import("simulation.zig");
    _ = @import("config.zig");
}
