const std = @import("std");
const Config = @import("config.zig").Config;
const Simulation = @import("simulation.zig").Simulation;
const viz = @import("viz.zig");

fn printUsage() void {
    const usage =
        \\Usage: lamblife [OPTIONS]
        \\
        \\Options:
        \\  --seed=N            RNG seed (default: current timestamp)
        \\  --ticks=N           Number of ticks to run (default: 10000)
        \\  --metrics=FILE      Metrics CSV output path (default: metrics.csv)
        \\  --lineage=FILE      Lineage CSV output path (default: lineage.csv)
        \\  --snapshot-dir=DIR  Directory for snapshots (default: snapshots)
        \\  --resume=FILE       Resume from a snapshot file
        \\  --viz               Run with real-time visualization (raylib)
        \\  --help              Show this help message
        \\
        \\Config overrides (--name=value):
        \\
    ;
    std.debug.print("{s}", .{usage});

    // Print all Config fields with their defaults
    const info = @typeInfo(Config);
    inline for (info.@"struct".fields) |field| {
        if (field.default_value_ptr) |ptr| {
            const default = @as(*align(1) const field.type, @ptrCast(ptr)).*;
            switch (@typeInfo(field.type)) {
                .int, .comptime_int => std.debug.print("  --{s}={d}\n", .{ field.name, default }),
                .float, .comptime_float => std.debug.print("  --{s}={d:.4}\n", .{ field.name, default }),
                else => {},
            }
        }
    }
    std.debug.print("\n", .{});
}

fn parseConfigFromArgs(args: []const [:0]const u8) !struct { config: Config, seed: ?u64, ticks: u64, metrics_path: []const u8, lineage_path: []const u8, snapshot_dir: []const u8, resume_path: ?[]const u8, viz_mode: bool } {
    var config = Config{};
    var seed: ?u64 = null;
    var ticks: u64 = 10_000;
    var metrics_path: []const u8 = "metrics.csv";
    var lineage_path: []const u8 = "lineage.csv";
    var snapshot_dir: []const u8 = "snapshots";
    var resume_path: ?[]const u8 = null;
    var viz_mode: bool = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--viz")) {
            viz_mode = true;
            continue;
        }

        if (!std.mem.startsWith(u8, arg, "--")) continue;

        const without_prefix = arg[2..];
        const eq_pos = std.mem.indexOf(u8, without_prefix, "=") orelse {
            std.debug.print("Invalid argument (missing '='): {s}\n", .{arg});
            return error.InvalidArgument;
        };
        const key = without_prefix[0..eq_pos];
        const value = without_prefix[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "seed")) {
            seed = std.fmt.parseInt(u64, value, 10) catch {
                std.debug.print("Invalid seed value: {s}\n", .{value});
                return error.InvalidArgument;
            };
            continue;
        }
        if (std.mem.eql(u8, key, "ticks")) {
            ticks = std.fmt.parseInt(u64, value, 10) catch {
                std.debug.print("Invalid ticks value: {s}\n", .{value});
                return error.InvalidArgument;
            };
            continue;
        }
        if (std.mem.eql(u8, key, "metrics")) {
            metrics_path = value;
            continue;
        }
        if (std.mem.eql(u8, key, "lineage")) {
            lineage_path = value;
            continue;
        }
        if (std.mem.eql(u8, key, "snapshot-dir")) {
            snapshot_dir = value;
            continue;
        }
        if (std.mem.eql(u8, key, "resume")) {
            resume_path = value;
            continue;
        }

        // Try to match against Config fields
        if (!setConfigField(&config, key, value)) {
            std.debug.print("Unknown option: --{s}\n", .{key});
            return error.InvalidArgument;
        }
    }

    return .{
        .config = config,
        .seed = seed,
        .ticks = ticks,
        .metrics_path = metrics_path,
        .lineage_path = lineage_path,
        .snapshot_dir = snapshot_dir,
        .resume_path = resume_path,
        .viz_mode = viz_mode,
    };
}

fn setConfigField(config: *Config, key: []const u8, value: []const u8) bool {
    const info = @typeInfo(Config);
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(config, field.name) = std.fmt.parseInt(field.type, value, 10) catch {
                        std.debug.print("Invalid integer for --{s}: {s}\n", .{ field.name, value });
                        return false;
                    };
                },
                .float => {
                    @field(config, field.name) = std.fmt.parseFloat(field.type, value) catch {
                        std.debug.print("Invalid float for --{s}: {s}\n", .{ field.name, value });
                        return false;
                    };
                },
                else => {
                    std.debug.print("Unsupported field type for --{s}\n", .{field.name});
                    return false;
                },
            }
            return true;
        }
    }
    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = parseConfigFromArgs(args[1..]) catch {
        std.debug.print("\nRun with --help for usage.\n", .{});
        std.process.exit(1);
    };

    // Ensure snapshot directory exists
    std.fs.cwd().makePath(parsed.snapshot_dir) catch |err| {
        std.debug.print("Warning: could not create snapshot dir '{s}': {}\n", .{ parsed.snapshot_dir, err });
    };

    var sim: Simulation = undefined;

    if (parsed.resume_path) |resume_path| {
        sim = Simulation.loadFromSnapshot(allocator, resume_path, parsed.metrics_path) catch |err| {
            std.debug.print("Failed to load snapshot '{s}': {}\n", .{ resume_path, err });
            std.process.exit(1);
        };
        std.debug.print("LambLife resuming from {s}: {d}x{d} grid, tick={d}, running {d} more ticks\n", .{
            resume_path,
            sim.config.width,
            sim.config.height,
            sim.tick,
            parsed.ticks,
        });
    } else {
        const config = parsed.config;
        const seed: u64 = parsed.seed orelse @intCast(std.time.timestamp());
        std.debug.print("LambLife starting: {d}x{d} grid, seed={d}, ticks={d}\n", .{ config.width, config.height, seed, parsed.ticks });
        sim = try Simulation.init(allocator, config, seed, parsed.metrics_path);
    }
    defer sim.deinit();

    // Re-wire grid rng to point at the now-settled prng
    sim.rewireRng();
    sim.snapshot_dir = parsed.snapshot_dir;

    if (parsed.viz_mode) {
        try viz.runVisualization(&sim, allocator);
    } else {
        try sim.run(parsed.ticks);
    }

    sim.lineage_log.writeCsv(parsed.lineage_path) catch |err| {
        std.debug.print("Warning: could not write {s}: {}\n", .{ parsed.lineage_path, err });
    };

    std.debug.print("Simulation complete. Metrics written to {s}, lineage to {s}\n", .{ parsed.metrics_path, parsed.lineage_path });
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
    _ = @import("metrics.zig");
    _ = @import("snapshot.zig");
    _ = @import("viz.zig");
}
