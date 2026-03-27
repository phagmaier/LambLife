const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "LambLife",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Also test reduce.zig (and any file it imports)
    const reduce_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reduce.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_reduce_tests = b.addRunArtifact(reduce_tests);
    test_step.dependOn(&run_reduce_tests.step);

    // Also test grid.zig
    const grid_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_grid_tests = b.addRunArtifact(grid_tests);
    test_step.dependOn(&run_grid_tests.step);

    // Also test mutation.zig
    const mutation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mutation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mutation_tests = b.addRunArtifact(mutation_tests);
    test_step.dependOn(&run_mutation_tests.step);

    // Also test interaction.zig
    const interaction_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interaction.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_interaction_tests = b.addRunArtifact(interaction_tests);
    test_step.dependOn(&run_interaction_tests.step);

    // Also test simulation.zig
    const simulation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simulation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_simulation_tests = b.addRunArtifact(simulation_tests);
    test_step.dependOn(&run_simulation_tests.step);

    // Also test metrics.zig
    const metrics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metrics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_metrics_tests = b.addRunArtifact(metrics_tests);
    test_step.dependOn(&run_metrics_tests.step);
}
