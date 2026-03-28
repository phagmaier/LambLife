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
const TickStats = interaction.TickStats;
const Expr = @import("expr.zig").Expr;

const WINDOW_W = 1400;
const WINDOW_H = 900;
const INSPECTOR_W = 300;
const GRAPH_H = 200;
const HUD_H = 24;

const METRIC_HISTORY_LEN = 2000;

const SpeedLevel = struct {
    steps: u32,
    label: [:0]const u8,
};

const speed_levels = [_]SpeedLevel{
    .{ .steps = 1, .label = "1x" },
    .{ .steps = 5, .label = "5x" },
    .{ .steps = 10, .label = "10x" },
    .{ .steps = 50, .label = "50x" },
    .{ .steps = 100, .label = "100x" },
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
    var paused = false;
    var speed_idx: usize = 2; // start at 10x
    var show_graphs = true;
    var show_inspector = true;
    var show_biomes = false;

    // Camera for grid pan/zoom
    var cam_offset_x: f32 = 0;
    var cam_offset_y: f32 = 0;
    var cam_scale: f32 = computeDefaultScale(sim, show_inspector, show_graphs);

    // Selected cell
    var selected_cell: ?u32 = null;

    // Expression string buffers for inspector (allocated, null-terminated)
    var expr_pretty_buf: ?[]u8 = null;
    defer if (expr_pretty_buf) |buf| allocator.free(buf);
    var expr_debruijn_buf: ?[]u8 = null;
    defer if (expr_debruijn_buf) |buf| allocator.free(buf);

    while (!rl.windowShouldClose()) {
        // --- Input ---
        if (rl.isKeyPressed(.space)) paused = !paused;
        if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) {
            if (speed_idx < speed_levels.len - 1) speed_idx += 1;
        }
        if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) {
            if (speed_idx > 0) speed_idx -= 1;
        }
        if (rl.isKeyPressed(.r)) {
            cam_offset_x = 0;
            cam_offset_y = 0;
            cam_scale = computeDefaultScale(sim, show_inspector, show_graphs);
        }
        if (rl.isKeyPressed(.b)) show_biomes = !show_biomes;
        if (rl.isKeyPressed(.g)) {
            show_graphs = !show_graphs;
            cam_scale = computeDefaultScale(sim, show_inspector, show_graphs);
        }
        if (rl.isKeyPressed(.i)) {
            show_inspector = !show_inspector;
            cam_scale = computeDefaultScale(sim, show_inspector, show_graphs);
        }

        // Mouse wheel zoom
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            cam_scale *= if (wheel > 0) 1.1 else 0.9;
            cam_scale = std.math.clamp(cam_scale, 1.0, 20.0);
        }

        // Mouse drag pan (right button)
        if (rl.isMouseButtonDown(.right)) {
            const delta = rl.getMouseDelta();
            cam_offset_x += delta.x;
            cam_offset_y += delta.y;
        }

        // Mouse click select cell (left button)
        if (rl.isMouseButtonPressed(.left)) {
            const mouse = rl.getMousePosition();
            const grid_area_w = gridAreaWidth(show_inspector);
            const grid_area_h = gridAreaHeight(show_graphs);

            if (mouse.x < @as(f32, @floatFromInt(grid_area_w)) and mouse.y < @as(f32, @floatFromInt(grid_area_h))) {
                const gx_f = (mouse.x - cam_offset_x) / cam_scale;
                const gy_f = (mouse.y - cam_offset_y) / cam_scale;
                const gx: i32 = @intFromFloat(gx_f);
                const gy: i32 = @intFromFloat(gy_f);
                const w: i32 = @intCast(sim.config.width);
                const h: i32 = @intCast(sim.config.height);
                if (gx >= 0 and gx < w and gy >= 0 and gy < h) {
                    const idx: u32 = @intCast(gy * w + gx);
                    selected_cell = idx;

                    // Update expression strings
                    if (expr_pretty_buf) |buf| allocator.free(buf);
                    expr_pretty_buf = null;
                    if (expr_debruijn_buf) |buf| allocator.free(buf);
                    expr_debruijn_buf = null;

                    switch (sim.grid.cells[idx]) {
                        .organism => |org| {
                            expr_pretty_buf = org.expr.toStringPretty(allocator) catch null;
                            expr_debruijn_buf = org.expr.toStringDeBruijn(allocator) catch null;
                        },
                        else => {},
                    }
                }
            }
        }

        // --- Simulation step ---
        if (!paused) {
            const steps = speed_levels[speed_idx].steps;
            for (0..steps) |_| {
                const result = sim.step() catch break;

                // Record lineage
                for (sim.grid.cells) |cell| {
                    switch (cell) {
                        .organism => |org| {
                            if (org.age == 0 and org.parent_lineage != null) {
                                sim.lineage_log.record(
                                    sim.tick,
                                    org.lineage_id,
                                    org.parent_lineage.?,
                                    org.generation,
                                    org.expr.hash(),
                                ) catch {};
                            }
                        },
                        else => {},
                    }
                }

                // Collect metrics periodically
                if (sim.tick % sim.config.log_interval == 0) {
                    var m = metrics.collectTickMetrics(&sim.grid, sim.tick, result.tick_stats, result.deaths_energy, result.deaths_age);

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
        }

        // --- Render ---
        rl.beginDrawing();
        rl.clearBackground(rl.Color.init(20, 20, 20, 255));

        // Grid
        renderGrid(sim, cam_offset_x, cam_offset_y, cam_scale, show_biomes, selected_cell, show_inspector, show_graphs);

        // Inspector panel
        if (show_inspector) {
            renderInspector(sim, selected_cell, expr_pretty_buf, expr_debruijn_buf, show_graphs);
        }

        // Graphs
        if (show_graphs) {
            renderGraphs(&history, show_inspector);
        }

        // HUD
        renderHUD(sim, paused, speed_idx);

        rl.endDrawing();
    }
}

fn computeDefaultScale(sim: *Simulation, show_inspector: bool, show_graphs: bool) f32 {
    const area_w: f32 = @floatFromInt(gridAreaWidth(show_inspector));
    const area_h: f32 = @floatFromInt(gridAreaHeight(show_graphs));
    const grid_w: f32 = @floatFromInt(sim.config.width);
    const grid_h: f32 = @floatFromInt(sim.config.height);
    return @min(area_w / grid_w, area_h / grid_h);
}

fn gridAreaWidth(show_inspector: bool) i32 {
    return if (show_inspector) WINDOW_W - INSPECTOR_W else WINDOW_W;
}

fn gridAreaHeight(show_graphs: bool) i32 {
    return if (show_graphs) WINDOW_H - GRAPH_H else WINDOW_H;
}

fn renderGrid(sim: *Simulation, offset_x: f32, offset_y: f32, scale: f32, show_biomes: bool, selected_cell: ?u32, show_inspector: bool, show_graphs: bool) void {
    const w = sim.config.width;
    const h = sim.config.height;

    // Clip to grid area
    const area_w = gridAreaWidth(show_inspector);
    const area_h = gridAreaHeight(show_graphs);
    rl.beginScissorMode(0, 0, area_w, area_h);
    defer rl.endScissorMode();

    // Determine visible cell range for culling
    const start_x = @max(0, @as(i32, @intFromFloat(-offset_x / scale)));
    const start_y = @max(0, @as(i32, @intFromFloat(-offset_y / scale)));
    const end_x = @min(@as(i32, @intCast(w)), @as(i32, @intFromFloat((@as(f32, @floatFromInt(area_w)) - offset_x) / scale)) + 1);
    const end_y = @min(@as(i32, @intCast(h)), @as(i32, @intFromFloat((@as(f32, @floatFromInt(area_h)) - offset_y) / scale)) + 1);

    if (start_x >= end_x or start_y >= end_y) return;

    const cell_px: i32 = @max(1, @as(i32, @intFromFloat(scale)));

    var y: i32 = start_y;
    while (y < end_y) : (y += 1) {
        var x: i32 = start_x;
        while (x < end_x) : (x += 1) {
            const idx: u32 = @intCast(@as(u32, @intCast(y)) * w + @as(u32, @intCast(x)));
            const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) * scale + offset_x));
            const py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y)) * scale + offset_y));

            const color = if (show_biomes)
                biomeColor(sim.grid.biome_map[idx])
            else
                cellColor(sim.grid.cells[idx]);

            rl.drawRectangle(px, py, cell_px, cell_px, color);
        }
    }

    // Draw selection highlight
    if (selected_cell) |sel| {
        const sx: i32 = @intCast(sel % w);
        const sy: i32 = @intCast(sel / w);
        const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(sx)) * scale + offset_x));
        const py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(sy)) * scale + offset_y));
        rl.drawRectangleLines(px - 1, py - 1, cell_px + 2, cell_px + 2, rl.Color.white);
    }
}

fn cellColor(cell: Cell) rl.Color {
    return switch (cell) {
        .empty => rl.Color.init(0, 0, 0, 255),
        .resource => |res| resourceColor(res.kind),
        .organism => |org| organismColor(org),
    };
}

fn resourceColor(kind: ResourceKind) rl.Color {
    return switch (kind) {
        .identity => rl.Color.init(0, 180, 220, 255),
        .true_ => rl.Color.init(50, 100, 255, 255),
        .false_ => rl.Color.init(100, 50, 200, 255),
        .self_apply => rl.Color.init(0, 200, 180, 255),
        .pair => rl.Color.init(100, 180, 255, 255),
        .zero => rl.Color.init(30, 30, 150, 255),
    };
}

fn organismColor(org: Organism) rl.Color {
    const h = org.expr.hash();
    const hue: f32 = @floatFromInt(h % 360);
    const brightness = std.math.clamp(@as(f32, @floatCast(org.energy)) / 200.0, 0.2, 1.0);
    return hsvToRgb(hue, 0.8, brightness);
}

fn biomeColor(biome_id: u8) rl.Color {
    const colors = [_]rl.Color{
        rl.Color.init(40, 20, 20, 255),
        rl.Color.init(20, 40, 20, 255),
        rl.Color.init(20, 20, 40, 255),
        rl.Color.init(40, 40, 20, 255),
        rl.Color.init(40, 20, 40, 255),
        rl.Color.init(20, 40, 40, 255),
        rl.Color.init(30, 30, 30, 255),
        rl.Color.init(35, 25, 25, 255),
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
    const panel_h: i32 = if (show_graphs) WINDOW_H - GRAPH_H else WINDOW_H;

    // Background
    rl.drawRectangle(panel_x, 0, INSPECTOR_W, panel_h, rl.Color.init(30, 30, 35, 255));
    rl.drawLine(panel_x, 0, panel_x, panel_h, rl.Color.init(60, 60, 70, 255));

    var y: i32 = 10;
    const x: i32 = panel_x + 10;
    const font_size: i32 = 14;
    const line_h: i32 = 18;

    rl.drawText("INSPECTOR", x, y, 16, rl.Color.init(200, 200, 220, 255));
    y += 24;

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
    y += line_h + 4;

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
            y += line_h + 4;

            // Energy
            const energy_color: rl.Color = if (org.energy > 50) rl.Color.green else if (org.energy > 20) rl.Color.yellow else rl.Color.red;
            drawTextFmt("Energy: {d:.1}", .{org.energy}, x, y, font_size, energy_color);
            y += line_h;

            // Age
            drawTextFmt("Age: {d}", .{org.age}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            // Generation
            drawTextFmt("Generation: {d}", .{org.generation}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            // Lineage
            drawTextFmt("Lineage: {d}", .{org.lineage_id}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
            y += line_h;

            if (org.parent_lineage) |pl| {
                drawTextFmt("Parent: {d}", .{pl}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
                y += line_h;
            }

            // Size
            const sz = org.expr.size();
            drawTextFmt("Size: {d} nodes", .{sz}, x, y, font_size, rl.Color.init(180, 180, 200, 255));
            y += line_h;

            // Hash
            drawTextFmt("Hash: {x:0>16}", .{org.expr.hash()}, x, y, font_size, rl.Color.init(140, 140, 160, 255));
            y += line_h + 8;

            // Expression display
            rl.drawText("Expression:", x, y, font_size, rl.Color.init(200, 200, 220, 255));
            y += line_h;

            if (expr_pretty) |pretty| {
                y = drawWrappedText(pretty, x, y, INSPECTOR_W - 20, font_size - 2, rl.Color.init(100, 220, 100, 255));
                y += 4;
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

        // Copy into null-terminated buffer
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
    rl.drawRectangle(0, panel_y, total_w, GRAPH_H, rl.Color.init(25, 25, 30, 255));
    rl.drawLine(0, panel_y, total_w, panel_y, rl.Color.init(60, 60, 70, 255));

    if (history.count < 2) {
        rl.drawText("Collecting data...", 10, panel_y + 10, 14, rl.Color.gray);
        return;
    }

    // Draw 6 mini-graphs side by side
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

        // Find min/max for auto-scaling
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

        // Draw graph background
        rl.drawRectangle(gx, gy, graph_w - margin * 2, graph_h, rl.Color.init(15, 15, 20, 255));

        // Draw line
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

fn renderHUD(sim: *Simulation, paused: bool, speed_idx: usize) void {
    // Semi-transparent background strip
    rl.drawRectangle(0, 0, WINDOW_W, HUD_H, rl.Color.init(0, 0, 0, 180));

    const counts = sim.grid.countCells();

    drawTextFmt("Tick: {d}  |  Pop: {d}  Res: {d}  Empty: {d}  |  Speed: {s}  |  FPS: {d}", .{
        sim.tick,
        counts.organisms,
        counts.resources,
        counts.empty,
        speed_levels[speed_idx].label,
        rl.getFPS(),
    }, 8, 5, 14, rl.Color.init(220, 220, 220, 255));

    if (paused) {
        rl.drawText("|| PAUSED", WINDOW_W - 120, 5, 14, rl.Color.red);
    }

    // Controls hint at right side
    rl.drawText("Space:Pause +/-:Speed R:Reset B:Biomes G:Graphs I:Inspector", WINDOW_W - 500, 5, 12, rl.Color.init(120, 120, 140, 255));
}
