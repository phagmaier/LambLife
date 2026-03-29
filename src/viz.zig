const std = @import("std");
const rl = @import("raylib");
const Simulation = @import("simulation.zig").Simulation;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;
const ResourceKind = grid_mod.ResourceKind;
const Organism = grid_mod.Organism;
const metrics = @import("metrics.zig");
const TickMetrics = metrics.TickMetrics;
const interaction = @import("interaction.zig");
const BirthRecorder = interaction.BirthRecorder;
const TickProcessor = interaction.TickProcessor;
const TickStats = interaction.TickStats;
const Expr = @import("expr.zig").Expr;

const WINDOW_W = 1400;
const WINDOW_H = 900;
const INSPECTOR_W = 300;
const GRAPH_H = 200;
const HUD_H = 40;

const METRIC_HISTORY_LEN = 2000;

// Time budget for simulation per frame (nanoseconds).
// 12ms leaves ~4ms for rendering at 60fps target.
const SIM_BUDGET_NS: i128 = 12_000_000;

const SpeedLevel = struct {
    steps: u32,
    label: [:0]const u8,
};

const speed_levels = [_]SpeedLevel{
    .{ .steps = 1, .label = "1x" },
    .{ .steps = 5, .label = "5x" },
    .{ .steps = 25, .label = "25x" },
    .{ .steps = 100, .label = "100x" },
    .{ .steps = 10000, .label = "Max" },
};

const MetricHistory = struct {
    population: [METRIC_HISTORY_LEN]f32,
    diversity: [METRIC_HISTORY_LEN]f32,
    mean_energy: [METRIC_HISTORY_LEN]f32,
    mean_size: [METRIC_HISTORY_LEN]f32,
    max_generation: [METRIC_HISTORY_LEN]f32,
    births: [METRIC_HISTORY_LEN]f32,
    deaths: [METRIC_HISTORY_LEN]f32,
    count: usize,
    write_idx: usize,

    fn init() MetricHistory {
        return .{
            .population = [_]f32{0} ** METRIC_HISTORY_LEN,
            .diversity = [_]f32{0} ** METRIC_HISTORY_LEN,
            .mean_energy = [_]f32{0} ** METRIC_HISTORY_LEN,
            .mean_size = [_]f32{0} ** METRIC_HISTORY_LEN,
            .max_generation = [_]f32{0} ** METRIC_HISTORY_LEN,
            .births = [_]f32{0} ** METRIC_HISTORY_LEN,
            .deaths = [_]f32{0} ** METRIC_HISTORY_LEN,
            .count = 0,
            .write_idx = 0,
        };
    }

    fn push(self: *MetricHistory, m: TickMetrics) void {
        self.population[self.write_idx] = @floatFromInt(m.population_count);
        self.diversity[self.write_idx] = @floatFromInt(m.unique_structures);
        self.mean_energy[self.write_idx] = @floatCast(m.mean_energy);
        self.mean_size[self.write_idx] = @floatCast(m.mean_size);
        self.max_generation[self.write_idx] = @floatFromInt(m.max_generation);
        self.births[self.write_idx] = @floatFromInt(m.births);
        self.deaths[self.write_idx] = @floatFromInt(m.deaths_energy);
        self.write_idx = (self.write_idx + 1) % METRIC_HISTORY_LEN;
        if (self.count < METRIC_HISTORY_LEN) self.count += 1;
    }

    fn get(self: *const MetricHistory, buf: []const f32, i: usize) f32 {
        if (self.count < METRIC_HISTORY_LEN) {
            return buf[i];
        }
        return buf[(self.write_idx + i) % METRIC_HISTORY_LEN];
    }
};

const Viewport = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const HudAction = enum {
    none,
    toggle_pause,
    step_once,
    slower,
    faster,
    reset_view,
};

const HudButton = struct {
    rect: rl.Rectangle,
    label: [:0]const u8,
    action: HudAction,
};

const VizState = struct {
    paused: bool = true,
    speed_idx: usize = 0,
    show_graphs: bool = true,
    show_inspector: bool = true,
    show_biomes: bool = false,
    cam_scale: f32 = 1.0,
    cam_offset_x: f32 = 0,
    cam_offset_y: f32 = 0,
    selected_cell: ?u32 = null,
    steps_this_second: u32 = 0,
    steps_per_sec: u32 = 0,
    last_sec_time: i128 = 0,
    inspector_refresh: u32 = 0,
    requested_steps: u32 = 0,
};

const PendingTickPhase = enum {
    idle,
    interacting,
    death_energy,
    death_age,
};

const PendingTick = struct {
    phase: PendingTickPhase = .idle,
    processor: ?TickProcessor = null,
    birth_recorder: BirthRecorder = undefined,
    has_birth_recorder: bool = false,
    scan_index: usize = 0,
    tick_stats: TickStats = .{},
    deaths_energy: u32 = 0,
    deaths_age: u32 = 0,
    resource_injection_attempts: u32 = 0,
    resources_injected: u32 = 0,
    resource_injection_blocked: u32 = 0,
    energy_before: f64 = 0,

    fn deinit(self: *PendingTick) void {
        if (self.processor) |*processor| {
            processor.deinit();
            self.processor = null;
        }
        if (self.has_birth_recorder) {
            self.birth_recorder.deinit();
            self.has_birth_recorder = false;
        }
        self.phase = .idle;
        self.scan_index = 0;
        self.tick_stats = .{};
        self.deaths_energy = 0;
        self.deaths_age = 0;
        self.resource_injection_attempts = 0;
        self.resources_injected = 0;
        self.resource_injection_blocked = 0;
        self.energy_before = 0;
    }
};

/// Helper: format into a stack-allocated null-terminated buffer and call drawText.
fn drawTextFmt(comptime fmt: []const u8, args: anytype, x: i32, y: i32, font_size: i32, color: rl.Color) void {
    var buf: [512:0]u8 = [_:0]u8{0} ** 512;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    buf[slice.len] = 0;
    const z: [:0]const u8 = buf[0..slice.len :0];
    rl.drawText(z, x, y, font_size, color);
}

pub fn runVisualization(sim: *Simulation, allocator: std.mem.Allocator) !void {
    rl.initWindow(WINDOW_W, WINDOW_H, "LambLife - Lambda Calculus Artificial Life");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var history = MetricHistory.init();
    var state = VizState{
        .last_sec_time = std.time.nanoTimestamp(),
    };
    var pending_tick = PendingTick{};
    defer pending_tick.deinit();
    resetCamera(sim, &state);

    // Expression string buffers for inspector
    var expr_pretty_buf: ?[]u8 = null;
    defer if (expr_pretty_buf) |buf| allocator.free(buf);
    var expr_debruijn_buf: ?[]u8 = null;
    defer if (expr_debruijn_buf) |buf| allocator.free(buf);

    while (!rl.windowShouldClose()) {
        if (handleInput(sim, &state, &pending_tick, &history, &expr_pretty_buf, &expr_debruijn_buf, allocator)) break;
        refreshInspectorIfNeeded(sim, &state, &expr_pretty_buf, &expr_debruijn_buf, allocator);

        // --- Render (before sim step so first frame shows immediately) ---
        rl.beginDrawing();
        rl.clearBackground(rl.Color.init(20, 20, 20, 255));

        renderGrid(sim, &state);

        if (state.show_inspector) {
            renderInspector(sim, state.selected_cell, expr_pretty_buf, expr_debruijn_buf, state.show_graphs);
        }

        if (state.show_graphs) {
            renderGraphs(&history, state.show_inspector);
        }

        renderHUD(sim, &state);

        rl.endDrawing();

        runSimulationFrame(sim, &state, &pending_tick, &history, &expr_pretty_buf, &expr_debruijn_buf, allocator);
        updateStepsPerSecond(&state);
    }
}

fn gridViewport(show_inspector: bool, show_graphs: bool) Viewport {
    return .{
        .x = 0,
        .y = HUD_H,
        .w = if (show_inspector) WINDOW_W - INSPECTOR_W else WINDOW_W,
        .h = if (show_graphs) WINDOW_H - HUD_H - GRAPH_H else WINDOW_H - HUD_H,
    };
}

fn computeDefaultScale(sim: *Simulation, show_inspector: bool, show_graphs: bool) f32 {
    const viewport = gridViewport(show_inspector, show_graphs);
    const area_w: f32 = @floatFromInt(viewport.w);
    const area_h: f32 = @floatFromInt(viewport.h);
    const grid_w: f32 = @floatFromInt(sim.config.width);
    const grid_h: f32 = @floatFromInt(sim.config.height);
    return @min(area_w / grid_w, area_h / grid_h);
}

fn computeCenterOffsetX(sim: *Simulation, scale: f32, show_inspector: bool, show_graphs: bool) f32 {
    const viewport = gridViewport(show_inspector, show_graphs);
    const area_w: f32 = @floatFromInt(viewport.w);
    const grid_px: f32 = @as(f32, @floatFromInt(sim.config.width)) * scale;
    return @as(f32, @floatFromInt(viewport.x)) + (area_w - grid_px) / 2.0;
}

fn computeCenterOffsetY(sim: *Simulation, scale: f32, show_inspector: bool, show_graphs: bool) f32 {
    const viewport = gridViewport(show_inspector, show_graphs);
    const area_h: f32 = @floatFromInt(viewport.h);
    const grid_px: f32 = @as(f32, @floatFromInt(sim.config.height)) * scale;
    return @as(f32, @floatFromInt(viewport.y)) + (area_h - grid_px) / 2.0;
}

fn refreshInspectorStrings(sim: *Simulation, idx: u32, pretty: *?[]u8, debruijn: *?[]u8, allocator: std.mem.Allocator) void {
    if (pretty.*) |buf| allocator.free(buf);
    pretty.* = null;
    if (debruijn.*) |buf| allocator.free(buf);
    debruijn.* = null;

    switch (sim.grid.cells[idx]) {
        .organism => |org| {
            pretty.* = org.expr.toStringPretty(allocator) catch null;
            debruijn.* = org.expr.toStringDeBruijn(allocator) catch null;
        },
        else => {},
    }
}

fn resetCamera(sim: *Simulation, state: *VizState) void {
    state.cam_scale = computeDefaultScale(sim, state.show_inspector, state.show_graphs);
    state.cam_offset_x = computeCenterOffsetX(sim, state.cam_scale, state.show_inspector, state.show_graphs);
    state.cam_offset_y = computeCenterOffsetY(sim, state.cam_scale, state.show_inspector, state.show_graphs);
}

fn handleInput(sim: *Simulation, state: *VizState, pending_tick: *PendingTick, history: *MetricHistory, expr_pretty: *?[]u8, expr_debruijn: *?[]u8, allocator: std.mem.Allocator) bool {
    if (rl.isKeyPressed(.escape)) return true;
    if (rl.isKeyPressed(.space)) state.paused = !state.paused;
    if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) {
        if (state.speed_idx < speed_levels.len - 1) state.speed_idx += 1;
    }
    if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) {
        if (state.speed_idx > 0) state.speed_idx -= 1;
    }
    if (rl.isKeyPressed(.n) and state.paused) {
        state.requested_steps += 1;
    }
    if (rl.isKeyPressed(.r)) resetCamera(sim, state);
    if (rl.isKeyPressed(.b)) state.show_biomes = !state.show_biomes;
    if (rl.isKeyPressed(.g)) {
        state.show_graphs = !state.show_graphs;
        resetCamera(sim, state);
    }
    if (rl.isKeyPressed(.i)) {
        state.show_inspector = !state.show_inspector;
        resetCamera(sim, state);
    }

    const viewport = gridViewport(state.show_inspector, state.show_graphs);
    const mouse = rl.getMousePosition();

    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and pointInViewport(mouse, viewport)) {
        const world_x = (mouse.x - state.cam_offset_x) / state.cam_scale;
        const world_y = (mouse.y - state.cam_offset_y) / state.cam_scale;
        const zoom_factor: f32 = if (wheel > 0) 1.1 else 0.9;
        state.cam_scale = std.math.clamp(state.cam_scale * zoom_factor, 1.0, 24.0);
        state.cam_offset_x = mouse.x - world_x * state.cam_scale;
        state.cam_offset_y = mouse.y - world_y * state.cam_scale;
    }

    if (rl.isMouseButtonDown(.right) and pointInViewport(mouse, viewport)) {
        const delta = rl.getMouseDelta();
        state.cam_offset_x += delta.x;
        state.cam_offset_y += delta.y;
    }

    if (rl.isMouseButtonPressed(.left)) {
        const hud_action = actionForHudClick(mouse, state);
        if (hud_action != .none) {
            applyHudAction(hud_action, sim, state, pending_tick, history, expr_pretty, expr_debruijn, allocator);
            return false;
        }

        if (cellIndexAtPoint(sim, state, mouse)) |idx| {
            state.selected_cell = idx;
            refreshInspectorStrings(sim, idx, expr_pretty, expr_debruijn, allocator);
        }
    }

    return false;
}

fn applyHudAction(action: HudAction, sim: *Simulation, state: *VizState, pending_tick: *PendingTick, history: *MetricHistory, expr_pretty: *?[]u8, expr_debruijn: *?[]u8, allocator: std.mem.Allocator) void {
    switch (action) {
        .none => {},
        .toggle_pause => state.paused = !state.paused,
        .step_once => {
            state.requested_steps += 1;
        },
        .slower => {
            if (state.speed_idx > 0) state.speed_idx -= 1;
        },
        .faster => {
            if (state.speed_idx < speed_levels.len - 1) state.speed_idx += 1;
        },
        .reset_view => resetCamera(sim, state),
    }
    _ = pending_tick;
    _ = history;
    _ = expr_pretty;
    _ = expr_debruijn;
    _ = allocator;
}

fn refreshInspectorIfNeeded(sim: *Simulation, state: *VizState, expr_pretty: *?[]u8, expr_debruijn: *?[]u8, allocator: std.mem.Allocator) void {
    if (!state.paused and state.selected_cell != null) {
        state.inspector_refresh += 1;
        if (state.inspector_refresh >= 15) {
            state.inspector_refresh = 0;
            refreshInspectorStrings(sim, state.selected_cell.?, expr_pretty, expr_debruijn, allocator);
        }
    }
}

fn refreshSelectedCell(sim: *Simulation, state: *const VizState, expr_pretty: *?[]u8, expr_debruijn: *?[]u8, allocator: std.mem.Allocator) void {
    if (state.selected_cell) |idx| {
        refreshInspectorStrings(sim, idx, expr_pretty, expr_debruijn, allocator);
    }
}

fn runSimulationFrame(sim: *Simulation, state: *VizState, pending_tick: *PendingTick, history: *MetricHistory, expr_pretty: *?[]u8, expr_debruijn: *?[]u8, allocator: std.mem.Allocator) void {
    if (state.paused and state.requested_steps == 0 and pending_tick.phase == .idle) return;

    const frame_start = std.time.nanoTimestamp();
    var completed_ticks: u32 = 0;
    const target_ticks = if (state.paused) state.requested_steps else speed_levels[state.speed_idx].steps;

    while (completed_ticks < target_ticks or pending_tick.phase != .idle) {
        const result = advancePendingTick(sim, pending_tick, allocator) catch break;
        if (result) |step_result| {
            completed_ticks += 1;
            finishCompletedTick(sim, state, history, allocator, step_result);
            refreshSelectedCell(sim, state, expr_pretty, expr_debruijn, allocator);

            if (state.paused and state.requested_steps > 0) {
                state.requested_steps -= 1;
                if (state.requested_steps == 0 and pending_tick.phase == .idle) break;
            }
        }

        if (std.time.nanoTimestamp() - frame_start > SIM_BUDGET_NS) break;
    }

    state.steps_this_second += completed_ticks;
}

fn advancePendingTick(sim: *Simulation, pending_tick: *PendingTick, allocator: std.mem.Allocator) !?@import("simulation.zig").StepResult {
    const interaction_chunk = 1;
    const sweep_chunk = 512;

    if (pending_tick.phase == .idle) {
        const injection_stats = sim.grid.injectResources();
        sim.grid.decayResources();
        pending_tick.deinit();
        pending_tick.resource_injection_attempts = injection_stats.attempts;
        pending_tick.resources_injected = injection_stats.injected;
        pending_tick.resource_injection_blocked = injection_stats.blocked;
        pending_tick.energy_before = totalOrganismEnergy(&sim.grid);
        pending_tick.birth_recorder = BirthRecorder.init(allocator);
        pending_tick.has_birth_recorder = true;
        pending_tick.processor = try TickProcessor.init(&sim.grid, &pending_tick.birth_recorder);
        pending_tick.phase = .interacting;
    }

    switch (pending_tick.phase) {
        .idle => return null,
        .interacting => {
            var processor = &pending_tick.processor.?;
            if (try processor.advance(interaction_chunk)) {
                pending_tick.tick_stats = processor.stats;
                processor.deinit();
                pending_tick.processor = null;
                pending_tick.phase = .death_energy;
                pending_tick.scan_index = 0;
            }
            return null;
        },
        .death_energy => {
            const end = @min(sim.grid.cells.len, pending_tick.scan_index + sweep_chunk);
            while (pending_tick.scan_index < end) : (pending_tick.scan_index += 1) {
                const cell = &sim.grid.cells[pending_tick.scan_index];
                switch (cell.*) {
                    .organism => |*org| {
                        if (org.energy <= 0) {
                            org.expr.deinit(allocator);
                            cell.* = .empty;
                            pending_tick.deaths_energy += 1;
                        }
                    },
                    else => {},
                }
            }
            if (pending_tick.scan_index >= sim.grid.cells.len) {
                pending_tick.phase = .death_age;
                pending_tick.scan_index = 0;
            }
            return null;
        },
        .death_age => {
            const end = @min(sim.grid.cells.len, pending_tick.scan_index + sweep_chunk);
            while (pending_tick.scan_index < end) : (pending_tick.scan_index += 1) {
                const cell = &sim.grid.cells[pending_tick.scan_index];
                switch (cell.*) {
                    .organism => |*org| {
                        org.age += 1;
                        if (org.age > sim.config.max_organism_age) {
                            org.expr.deinit(allocator);
                            cell.* = .empty;
                            pending_tick.deaths_age += 1;
                        }
                    },
                    else => {},
                }
            }
            if (pending_tick.scan_index >= sim.grid.cells.len) {
                sim.tick += 1;
                for (pending_tick.birth_recorder.records.items) |rec| {
                    sim.lineage_log.record(
                        sim.tick,
                        rec.child_lineage,
                        rec.parent_lineage,
                        rec.generation,
                        rec.expr_hash,
                        @tagName(rec.kind),
                    ) catch {};
                }
                sim.cumulative_stats.births += pending_tick.tick_stats.births;
                sim.cumulative_stats.novel_placements += pending_tick.tick_stats.novel_placements;
                sim.cumulative_stats.deaths_energy += pending_tick.deaths_energy;
                sim.cumulative_stats.deaths_age += pending_tick.deaths_age;
                sim.cumulative_stats.resources_consumed += pending_tick.tick_stats.resources_consumed;
                sim.cumulative_stats.interactions += pending_tick.tick_stats.interactions;
                const result: @import("simulation.zig").StepResult = .{
                    .tick_stats = pending_tick.tick_stats,
                    .deaths_energy = pending_tick.deaths_energy,
                    .deaths_age = pending_tick.deaths_age,
                    .resource_injection_attempts = pending_tick.resource_injection_attempts,
                    .resources_injected = pending_tick.resources_injected,
                    .resource_injection_blocked = pending_tick.resource_injection_blocked,
                    .net_energy_delta = totalOrganismEnergy(&sim.grid) - pending_tick.energy_before,
                    .inject_ns = 0,
                    .decay_ns = 0,
                    .interactions_ns = 0,
                    .death_sweep_ns = 0,
                };
                pending_tick.deinit();
                return result;
            }
            return null;
        },
    }
}

fn finishCompletedTick(sim: *Simulation, state: *VizState, history: *MetricHistory, allocator: std.mem.Allocator, result: @import("simulation.zig").StepResult) void {
    _ = state;
    if (sim.tick % sim.config.log_interval == 0) {
        var m = metrics.collectTickMetrics(
            &sim.grid,
            sim.tick,
            result.tick_stats,
            result.deaths_energy,
            result.deaths_age,
            result.resource_injection_attempts,
            result.resources_injected,
            result.resource_injection_blocked,
            sim.cumulative_stats,
            result.net_energy_delta,
        );

        if (sim.tick % 1000 == 0) {
            var report = metrics.collectDiversity(&sim.grid, allocator) catch null;
            if (report) |*r| {
                m.unique_structures = r.unique_count;
                r.deinit();
            }
        }

        history.push(m);
        sim.metric_logger.log(m) catch {};
    }
}

fn updateStepsPerSecond(state: *VizState) void {
    const now = std.time.nanoTimestamp();
    if (now - state.last_sec_time >= 1_000_000_000) {
        state.steps_per_sec = state.steps_this_second;
        state.steps_this_second = 0;
        state.last_sec_time = now;
    }
}

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

fn pointInViewport(point: rl.Vector2, viewport: Viewport) bool {
    return point.x >= @as(f32, @floatFromInt(viewport.x)) and
        point.x < @as(f32, @floatFromInt(viewport.x + viewport.w)) and
        point.y >= @as(f32, @floatFromInt(viewport.y)) and
        point.y < @as(f32, @floatFromInt(viewport.y + viewport.h));
}

fn cellIndexAtPoint(sim: *Simulation, state: *const VizState, point: rl.Vector2) ?u32 {
    const viewport = gridViewport(state.show_inspector, state.show_graphs);
    if (!pointInViewport(point, viewport)) return null;

    const gx_f = (point.x - state.cam_offset_x) / state.cam_scale;
    const gy_f = (point.y - state.cam_offset_y) / state.cam_scale;
    const gx: i32 = @intFromFloat(gx_f);
    const gy: i32 = @intFromFloat(gy_f);
    const w: i32 = @intCast(sim.config.width);
    const h: i32 = @intCast(sim.config.height);
    if (gx < 0 or gx >= w or gy < 0 or gy >= h) return null;
    return @intCast(gy * w + gx);
}

fn hudButtons(paused: bool) [5]HudButton {
    const y: f32 = 8;
    const h: f32 = 24;
    return .{
        .{ .rect = .{ .x = 960, .y = y, .width = 74, .height = h }, .label = if (paused) "Play" else "Pause", .action = .toggle_pause },
        .{ .rect = .{ .x = 1042, .y = y, .width = 62, .height = h }, .label = "Step", .action = .step_once },
        .{ .rect = .{ .x = 1112, .y = y, .width = 28, .height = h }, .label = "-", .action = .slower },
        .{ .rect = .{ .x = 1148, .y = y, .width = 28, .height = h }, .label = "+", .action = .faster },
        .{ .rect = .{ .x = 1184, .y = y, .width = 86, .height = h }, .label = "Recenter", .action = .reset_view },
    };
}

fn actionForHudClick(mouse: rl.Vector2, state: *const VizState) HudAction {
    if (mouse.y >= @as(f32, @floatFromInt(HUD_H))) return .none;
    const buttons = hudButtons(state.paused);
    for (buttons) |button| {
        if (rl.checkCollisionPointRec(mouse, button.rect)) return button.action;
    }
    return .none;
}

fn renderGrid(sim: *Simulation, state: *const VizState) void {
    const w = sim.config.width;
    const viewport = gridViewport(state.show_inspector, state.show_graphs);
    rl.beginScissorMode(viewport.x, viewport.y, viewport.w, viewport.h);
    defer rl.endScissorMode();

    rl.drawRectangle(viewport.x, viewport.y, viewport.w, viewport.h, rl.Color.init(10, 12, 16, 255));

    // Visible cell range for culling
    const start_x = @max(0, @as(i32, @intFromFloat((@as(f32, @floatFromInt(viewport.x)) - state.cam_offset_x) / state.cam_scale)));
    const start_y = @max(0, @as(i32, @intFromFloat((@as(f32, @floatFromInt(viewport.y)) - state.cam_offset_y) / state.cam_scale)));
    const end_x = @min(@as(i32, @intCast(w)), @as(i32, @intFromFloat((@as(f32, @floatFromInt(viewport.x + viewport.w)) - state.cam_offset_x) / state.cam_scale)) + 1);
    const end_y = @min(@as(i32, @intCast(sim.config.height)), @as(i32, @intFromFloat((@as(f32, @floatFromInt(viewport.y + viewport.h)) - state.cam_offset_y) / state.cam_scale)) + 1);

    if (start_x >= end_x or start_y >= end_y) return;

    // Use ceil so cells slightly overlap — no black gaps between cells
    const cell_px: i32 = @max(1, @as(i32, @intFromFloat(@ceil(state.cam_scale))));

    var y: i32 = start_y;
    while (y < end_y) : (y += 1) {
        var x: i32 = start_x;
        while (x < end_x) : (x += 1) {
            const idx: u32 = @intCast(@as(u32, @intCast(y)) * w + @as(u32, @intCast(x)));
            const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) * state.cam_scale + state.cam_offset_x));
            const py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y)) * state.cam_scale + state.cam_offset_y));

            const color = if (state.show_biomes)
                biomeColor(sim.grid.biome_map[idx])
            else
                cellColor(sim.grid.cells[idx]);

            rl.drawRectangle(px, py, cell_px, cell_px, color);
        }
    }

    // Selection highlight
    if (state.selected_cell) |sel| {
        const sx: i32 = @intCast(sel % w);
        const sy: i32 = @intCast(sel / w);
        const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(sx)) * state.cam_scale + state.cam_offset_x));
        const py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(sy)) * state.cam_scale + state.cam_offset_y));
        rl.drawRectangleLinesEx(.{
            .x = @floatFromInt(px - 2),
            .y = @floatFromInt(py - 2),
            .width = @floatFromInt(cell_px + 4),
            .height = @floatFromInt(cell_px + 4),
        }, 2, rl.Color.init(255, 250, 210, 255));
    }
}

fn cellColor(cell: Cell) rl.Color {
    return switch (cell) {
        .empty => rl.Color.init(16, 18, 24, 255),
        .resource => |res| resourceColor(res.kind),
        .organism => |org| organismColor(org),
    };
}

fn resourceColor(kind: ResourceKind) rl.Color {
    return switch (kind) {
        .identity => rl.Color.init(0, 210, 255, 255),
        .true_ => rl.Color.init(70, 130, 255, 255),
        .false_ => rl.Color.init(140, 70, 255, 255),
        .self_apply => rl.Color.init(0, 230, 200, 255),
        .pair => rl.Color.init(120, 200, 255, 255),
        .zero => rl.Color.init(50, 50, 180, 255),
    };
}

fn organismColor(org: Organism) rl.Color {
    const h = org.expr_hash;
    const hue: f32 = @mod(@as(f32, @floatFromInt(h % 2048)) * 0.618033988 * 360.0, 360.0);
    const energy = std.math.clamp(@as(f32, @floatCast(org.energy)) / 120.0, 0.0, 1.0);
    const value = 0.35 + energy * 0.65;
    const saturation = 0.45 + @min(0.45, @as(f32, @floatFromInt(org.generation % 10)) * 0.04);
    return hsvToRgb(hue, saturation, value);
}

fn biomeColor(biome_id: u8) rl.Color {
    const colors = [_]rl.Color{
        rl.Color.init(50, 25, 25, 255),
        rl.Color.init(25, 50, 25, 255),
        rl.Color.init(25, 25, 50, 255),
        rl.Color.init(50, 50, 25, 255),
        rl.Color.init(50, 25, 50, 255),
        rl.Color.init(25, 50, 50, 255),
        rl.Color.init(40, 40, 40, 255),
        rl.Color.init(45, 30, 30, 255),
    };
    return colors[biome_id % colors.len];
}

fn hsvToRgb(h: f32, s: f32, v: f32) rl.Color {
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(h / 60.0, 2.0) - 1.0));
    const m = v - c;

    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;

    if (h < 60) {
        r1 = c;
        g1 = x;
    } else if (h < 120) {
        r1 = x;
        g1 = c;
    } else if (h < 180) {
        g1 = c;
        b1 = x;
    } else if (h < 240) {
        g1 = x;
        b1 = c;
    } else if (h < 300) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    return rl.Color.init(
        @intFromFloat((r1 + m) * 255.0),
        @intFromFloat((g1 + m) * 255.0),
        @intFromFloat((b1 + m) * 255.0),
        255,
    );
}

fn renderInspector(sim: *Simulation, selected_cell: ?u32, expr_pretty: ?[]u8, expr_debruijn: ?[]u8, show_graphs: bool) void {
    const panel_x: i32 = WINDOW_W - INSPECTOR_W;
    const panel_y: i32 = HUD_H;
    const panel_h: i32 = if (show_graphs) WINDOW_H - HUD_H - GRAPH_H else WINDOW_H - HUD_H;

    // Background
    rl.drawRectangle(panel_x, panel_y, INSPECTOR_W, panel_h, rl.Color.init(28, 28, 33, 255));
    rl.drawLine(panel_x, panel_y, panel_x, panel_y + panel_h, rl.Color.init(60, 60, 70, 255));

    var y: i32 = panel_y + 10;
    const x: i32 = panel_x + 10;
    const font_size: i32 = 16;
    const line_h: i32 = 20;

    rl.drawText("INSPECTOR", x, y, 18, rl.Color.init(200, 200, 220, 255));
    y += 28;

    const sel = selected_cell orelse {
        rl.drawText("Click a cell to inspect", x, y, font_size, rl.Color.gray);
        return;
    };

    const gx = sel % sim.config.width;
    const gy = sel / sim.config.width;

    drawTextFmt("Cell ({d}, {d})", .{ gx, gy }, x, y, font_size, rl.Color.init(180, 180, 200, 255));
    y += line_h;

    const biome_id = sim.grid.biome_map[sel];
    drawTextFmt("Biome: {d}", .{biome_id}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
    y += line_h + 6;

    switch (sim.grid.cells[sel]) {
        .empty => {
            rl.drawText("[ Empty ]", x, y, font_size, rl.Color.gray);
        },
        .resource => |res| {
            rl.drawText("[ Resource ]", x, y, font_size, resourceColor(res.kind));
            y += line_h;
            const kind_text: [:0]const u8 = switch (res.kind) {
                .identity => "Kind: Identity",
                .true_ => "Kind: True (K)",
                .false_ => "Kind: False (KI)",
                .self_apply => "Kind: Self-Apply",
                .pair => "Kind: Pair",
                .zero => "Kind: Zero",
            };
            rl.drawText(kind_text, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;
            drawTextFmt("Age: {d}/{d}", .{ res.age, sim.config.resource_max_age }, x, y, font_size, rl.Color.init(180, 180, 200, 255));
        },
        .organism => |org| {
            rl.drawText("[ Organism ]", x, y, font_size, organismColor(org));
            y += line_h + 6;

            const energy_color: rl.Color = if (org.energy > 50) rl.Color.green else if (org.energy > 20) rl.Color.yellow else rl.Color.red;
            drawTextFmt("Energy: {d:.1}", .{org.energy}, x, y, font_size, energy_color);
            y += line_h;

            drawTextFmt("Age: {d}", .{org.age}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            drawTextFmt("Generation: {d}", .{org.generation}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            drawTextFmt("Lineage: {d}", .{org.lineage_id}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
            y += line_h;

            if (org.parent_lineage) |pl| {
                drawTextFmt("Parent: {d}", .{pl}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
                y += line_h;
            }

            const sz = org.expr_size;
            drawTextFmt("Size: {d} nodes", .{sz}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            drawTextFmt("Hash: {x:0>16}", .{org.expr_hash}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
            y += line_h + 10;

            rl.drawText("Expression:", x, y, font_size, rl.Color.init(200, 200, 220, 255));
            y += line_h;

            if (expr_pretty) |pretty| {
                y = drawWrappedText(pretty, x, y, INSPECTOR_W - 20, font_size - 2, rl.Color.init(100, 220, 100, 255));
                y += 6;
            }

            if (expr_debruijn) |db| {
                rl.drawText("De Bruijn:", x, y, font_size, rl.Color.init(200, 200, 220, 255));
                y += line_h;
                _ = drawWrappedText(db, x, y, INSPECTOR_W - 20, font_size - 2, rl.Color.init(220, 180, 100, 255));
            }
        },
    }
}

/// Draw text with line-wrapping. Returns the Y position after the last line.
fn drawWrappedText(text: []const u8, start_x: i32, start_y: i32, max_width: i32, font_size: i32, color: rl.Color) i32 {
    if (text.len == 0) return start_y;

    const char_w = @divTrunc(font_size, 2) + 1;
    const chars_per_line: usize = @max(1, @as(usize, @intCast(@divTrunc(max_width, char_w))));
    var y = start_y;
    var offset: usize = 0;

    while (offset < text.len) {
        const remaining = text.len - offset;
        const line_len = @min(remaining, chars_per_line);

        var line_buf: [256:0]u8 = [_:0]u8{0} ** 256;
        const copy_len = @min(line_len, 255);
        @memcpy(line_buf[0..copy_len], text[offset .. offset + copy_len]);
        line_buf[copy_len] = 0;
        const z: [:0]const u8 = line_buf[0..copy_len :0];

        rl.drawText(z, start_x, y, font_size, color);
        y += font_size + 2;
        offset += chars_per_line;
    }

    return y;
}

fn renderGraphs(history: *const MetricHistory, show_inspector: bool) void {
    const panel_y: i32 = WINDOW_H - GRAPH_H;
    const total_w: i32 = if (show_inspector) WINDOW_W - INSPECTOR_W else WINDOW_W;

    // Background
    rl.drawRectangle(0, panel_y, total_w, GRAPH_H, rl.Color.init(22, 22, 28, 255));
    rl.drawLine(0, panel_y, total_w, panel_y, rl.Color.init(60, 60, 70, 255));

    if (history.count < 2) {
        rl.drawText("Waiting for data... (unpause with Space)", 10, panel_y + 90, 16, rl.Color.gray);
        return;
    }

    const num_graphs: i32 = 6;
    const graph_w = @divTrunc(total_w - 10, num_graphs);
    const graph_h: i32 = GRAPH_H - 30;
    const margin: i32 = 5;

    const GraphDef = struct {
        buf: []const f32,
        label: [:0]const u8,
        color: rl.Color,
    };

    const graphs = [_]GraphDef{
        .{ .buf = &history.population, .label = "Population", .color = rl.Color.green },
        .{ .buf = &history.diversity, .label = "Diversity", .color = rl.Color.init(180, 100, 255, 255) },
        .{ .buf = &history.mean_energy, .label = "Avg Energy", .color = rl.Color.yellow },
        .{ .buf = &history.mean_size, .label = "Avg Size", .color = rl.Color.orange },
        .{ .buf = &history.max_generation, .label = "Max Gen", .color = rl.Color.red },
        .{ .buf = &history.births, .label = "Births", .color = rl.Color.init(100, 200, 255, 255) },
    };

    for (graphs, 0..) |gdef, gi| {
        const gx = @as(i32, @intCast(gi)) * graph_w + margin;
        const gy = panel_y + 20;

        // Label
        rl.drawText(gdef.label, gx + 2, panel_y + 4, 12, gdef.color);

        // Auto-scale Y axis
        var min_val: f32 = std.math.inf(f32);
        var max_val: f32 = -std.math.inf(f32);
        for (0..history.count) |idx| {
            const val = history.get(gdef.buf, idx);
            if (val < min_val) min_val = val;
            if (val > max_val) max_val = val;
        }
        if (min_val >= max_val) {
            max_val = min_val + 1;
        }

        // Graph background
        rl.drawRectangle(gx, gy, graph_w - margin * 2, graph_h, rl.Color.init(12, 12, 18, 255));

        // Line plot
        const usable_w: f32 = @floatFromInt(graph_w - margin * 2);
        const usable_h: f32 = @floatFromInt(graph_h);
        const n: f32 = @floatFromInt(history.count);

        var i: usize = 1;
        while (i < history.count) : (i += 1) {
            const x1 = @as(f32, @floatFromInt(i - 1)) / n * usable_w;
            const x2 = @as(f32, @floatFromInt(i)) / n * usable_w;
            const v1 = history.get(gdef.buf, i - 1);
            const v2 = history.get(gdef.buf, i);
            const y1 = usable_h - (v1 - min_val) / (max_val - min_val) * usable_h;
            const y2 = usable_h - (v2 - min_val) / (max_val - min_val) * usable_h;

            rl.drawLine(
                gx + @as(i32, @intFromFloat(x1)),
                gy + @as(i32, @intFromFloat(y1)),
                gx + @as(i32, @intFromFloat(x2)),
                gy + @as(i32, @intFromFloat(y2)),
                gdef.color,
            );
        }
    }
}

fn renderHUD(sim: *Simulation, state: *const VizState) void {
    // Background
    rl.drawRectangle(0, 0, WINDOW_W, HUD_H, rl.Color.init(0, 0, 0, 200));

    const counts = sim.grid.countCells();

    // Line 1: Status
    drawTextFmt("Tick: {d}  Pop: {d}  Res: {d}  Empty: {d}  FPS: {d}", .{
        sim.tick,
        counts.organisms,
        counts.resources,
        counts.empty,
        rl.getFPS(),
    }, 8, 4, 16, rl.Color.init(220, 220, 220, 255));

    // Line 2: Controls and speed
    drawTextFmt("Speed: {s}  Effective: {d} ticks/s  Space:Pause  N:Step  +/-:Speed  R:Reset  B/G/I toggles", .{
        speed_levels[state.speed_idx].label,
        state.steps_per_sec,
    }, 8, 22, 14, rl.Color.init(140, 140, 160, 255));

    const buttons = hudButtons(state.paused);
    for (buttons) |button| {
        const active = rl.checkCollisionPointRec(rl.getMousePosition(), button.rect);
        const fill = if (active) rl.Color.init(70, 76, 96, 255) else rl.Color.init(46, 50, 63, 255);
        rl.drawRectangleRounded(button.rect, 0.22, 6, fill);
        rl.drawRectangleRoundedLinesEx(button.rect, 0.22, 6, 1.5, rl.Color.init(120, 130, 156, 255));
        rl.drawText(button.label, @as(i32, @intFromFloat(button.rect.x)) + 8, @as(i32, @intFromFloat(button.rect.y)) + 5, 14, rl.Color.init(235, 235, 245, 255));
    }

    if (state.paused) {
        rl.drawText("PAUSED", WINDOW_W - 120, 4, 20, rl.Color.init(255, 80, 80, 255));
    }
}
