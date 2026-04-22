const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

// Braille charts are redrawn frequently, so we keep a static UTF-8 lookup
// table for U+2800..U+28FF instead of encoding and duplicating a grapheme
// for every rendered cell on each draw.
const braille_utf8_table = initBrailleUtf8Table();

fn initBrailleUtf8Table() [256][3]u8 {
    var table: [256][3]u8 = undefined;
    for (0..table.len) |i| {
        const cp: u21 = 0x2800 + @as(u21, @intCast(i));
        // The braille block always encodes to three UTF-8 bytes. Assemble
        // them directly so comptime table generation stays simple and avoids
        // hitting std.unicode's branch quota during builds.
        table[i] = .{
            @as(u8, 0xe0) | @as(u8, @intCast(cp >> 12)),
            @as(u8, 0x80) | @as(u8, @intCast((cp >> 6) & 0x3f)),
            @as(u8, 0x80) | @as(u8, @intCast(cp & 0x3f)),
        };
    }
    return table;
}

fn brailleGrapheme(cp: u21) []const u8 {
    const idx: usize = @intCast(cp - 0x2800);
    return braille_utf8_table[idx][0..];
}

fn sampleInterpolatedValue(trend: []const f32, sample_x: f32) f32 {
    if (trend.len == 0) return 0;
    if (trend.len == 1) return trend[0];

    const max_x = @as(f32, @floatFromInt(trend.len - 1));
    const clamped_x = std.math.clamp(sample_x, 0.0, max_x);
    const left_x = @floor(clamped_x);
    const left_idx: usize = @intFromFloat(left_x);
    const right_idx = @min(left_idx + 1, trend.len - 1);
    const t = clamped_x - left_x;

    return trend[left_idx] * (1.0 - t) + trend[right_idx] * t;
}

const ChartScale = struct {
    min_val: f32,
    max_val: f32,
};

fn transformChartValue(value: f32) f32 {
    return @sqrt(@max(value, 0.0));
}

fn quantileSorted(values: []const f32, q: f32) f32 {
    if (values.len == 0) return 0;
    if (values.len == 1) return values[0];

    const clamped_q = std.math.clamp(q, 0.0, 1.0);
    const scaled_idx = clamped_q * @as(f32, @floatFromInt(values.len - 1));
    const left_idx: usize = @intFromFloat(@floor(scaled_idx));
    const right_idx = @min(left_idx + 1, values.len - 1);
    const t = scaled_idx - @as(f32, @floatFromInt(left_idx));

    return values[left_idx] * (1.0 - t) + values[right_idx] * t;
}

fn resolveChartScale(trend: []const f32) ChartScale {
    if (trend.len == 0) return .{ .min_val = 0, .max_val = 1 };

    var sorted_samples: [256]f32 = undefined;
    const sample_count = @min(trend.len, sorted_samples.len);
    if (sample_count == 0) return .{ .min_val = 0, .max_val = 1 };

    for (0..sample_count) |i| {
        const src_idx = if (sample_count == trend.len or sample_count == 1)
            i
        else
            i * (trend.len - 1) / (sample_count - 1);
        sorted_samples[i] = transformChartValue(trend[src_idx]);
    }

    std.mem.sort(f32, sorted_samples[0..sample_count], {}, struct {
        fn lessThan(_: void, a: f32, b: f32) bool {
            return a < b;
        }
    }.lessThan);

    const min_sample = sorted_samples[0];
    const max_sample = sorted_samples[sample_count - 1];
    const lower_q = quantileSorted(sorted_samples[0..sample_count], 0.12);
    const upper_q = quantileSorted(sorted_samples[0..sample_count], 0.88);
    const center = (lower_q + upper_q) * 0.5;
    const robust_span = @max(upper_q - lower_q, 0.35);

    // Use a robust band instead of raw min/max so one burst does not flatten
    // the rest of the minute, while still leaving some headroom for spikes.
    const lower_pad = @max(robust_span * 0.35, (lower_q - min_sample) * 0.5, 0.12);
    const upper_pad = @max(robust_span * 0.45, (max_sample - upper_q) * 0.4, 0.25);

    var min_val = @max(lower_q - lower_pad, 0.0);
    var max_val = upper_q + upper_pad;

    const min_display_span = @max(robust_span * 1.4, 0.9);
    if (max_val - min_val < min_display_span) {
        const half_span = min_display_span * 0.5;
        min_val = @max(center - half_span, 0.0);
        max_val = center + half_span;
    }

    if (max_val - min_val < 0.1) {
        max_val = min_val + 0.1;
    }

    return .{ .min_val = min_val, .max_val = max_val };
}

fn chartDotY(value: f32, min_val: f32, max_val: f32, rows: u32) u32 {
    const span = @max(max_val - min_val, 0.001);
    const ratio = std.math.clamp((value - min_val) / span, 0.0, 1.0);
    const max_row = @as(f32, @floatFromInt(rows - 1));
    return @intFromFloat(@round((1.0 - ratio) * max_row));
}

// Draw a braille area chart with gradient coloring (btop-style).
// Area is filled from the data line down to the bottom, creating
// a solid "mountain" shape. Gradient: ACCENT_SOFT (bottom) → OK (top).
pub fn drawBrailleAreaChart(surface: *vxfw.Surface, trend: []const f32, x: u16, y: u16, width: u16, height: u16) void {
    if (width == 0 or height == 0 or trend.len == 0) return;

    const scale = resolveChartScale(trend);

    const braille_h: u32 = @as(u32, height) * 4;
    const cols: u32 = @min(@as(u32, width) * 2, 512);
    const rows: u32 = @min(braille_h, 128);

    var dots: [512][128]bool = undefined;
    for (&dots) |*r| @memset(r, false);

    // Sample a continuous curve across the discrete buckets so the chart
    // reads as a local activity wave rather than a stack of isolated bars.
    for (0..cols) |col_idx| {
        const sample_x = if (cols > 1)
            @as(f32, @floatFromInt(col_idx)) *
                @as(f32, @floatFromInt(trend.len - 1)) /
                @as(f32, @floatFromInt(cols - 1))
        else
            0.0;
        const val = sampleInterpolatedValue(trend, sample_x);
        const dot_y = chartDotY(transformChartValue(val), scale.min_val, scale.max_val, rows);

        // Fill from dot_y down to bottom (area fill)
        var fill_y = dot_y;
        while (fill_y < rows) : (fill_y += 1) {
            dots[col_idx][fill_y] = true;
        }
    }

    // Render braille characters with vertical gradient
    const char_cols = (cols + 1) / 2;
    const char_rows = (rows + 3) / 4;

    for (0..char_rows) |cr| {
        for (0..char_cols) |cc| {
            var cp: u21 = 0x2800;
            const dx = cc * 2;
            const dy = cr * 4;

            if (dx < cols) {
                if (dy + 0 < rows and dots[dx][dy + 0]) cp |= 0x01;
                if (dy + 1 < rows and dots[dx][dy + 1]) cp |= 0x02;
                if (dy + 2 < rows and dots[dx][dy + 2]) cp |= 0x04;
                if (dy + 3 < rows and dots[dx][dy + 3]) cp |= 0x40;
            }
            if (dx + 1 < cols) {
                if (dy + 0 < rows and dots[dx + 1][dy + 0]) cp |= 0x08;
                if (dy + 1 < rows and dots[dx + 1][dy + 1]) cp |= 0x10;
                if (dy + 2 < rows and dots[dx + 1][dy + 2]) cp |= 0x20;
                if (dy + 3 < rows and dots[dx + 1][dy + 3]) cp |= 0x80;
            }

            if (cp == 0x2800) continue;

            // Vertical gradient: top rows = ACCENT (deep amber), bottom rows = ACCENT_SOFT (light amber)
            const vert_t: f32 = if (char_rows > 1) 1.0 - @as(f32, @floatFromInt(cr)) / @as(f32, @floatFromInt(char_rows - 1)) else 0.5;
            const color = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, vert_t);

            const col: u16 = x + @as(u16, @intCast(cc));
            const row: u16 = y + @as(u16, @intCast(cr));
            if (col < surface.size.width and row < surface.size.height) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = brailleGrapheme(cp), .width = 1 },
                    .style = .{ .fg = color, .bg = theme.PANEL },
                });
            }
        }
    }
}

test "brailleGrapheme uses stable utf8 lookups" {
    try std.testing.expectEqualStrings("\xe2\xa0\x81", brailleGrapheme(0x2801));
    try std.testing.expectEqualStrings("\xe2\xa3\xbf", brailleGrapheme(0x28ff));
}

test "sampleInterpolatedValue blends neighboring buckets" {
    const trend = [_]f32{ 0, 10, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), sampleInterpolatedValue(&trend, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), sampleInterpolatedValue(&trend, 1.5), 0.001);
}

test "resolveChartScale keeps steady low activity off the bottom edge" {
    const trend = [_]f32{ 1, 1, 1, 1, 1 };
    const scale = resolveChartScale(&trend);
    const dot_y = chartDotY(transformChartValue(1), scale.min_val, scale.max_val, 8);

    try std.testing.expect(dot_y > 1);
    try std.testing.expect(dot_y < 6);
}

test "resolveChartScale preserves low-band motion when a spike arrives" {
    const trend = [_]f32{ 1, 1, 1, 1, 100 };
    const scale = resolveChartScale(&trend);
    const low_dot_y = chartDotY(transformChartValue(1), scale.min_val, scale.max_val, 8);
    const spike_dot_y = chartDotY(transformChartValue(100), scale.min_val, scale.max_val, 8);

    try std.testing.expect(low_dot_y < 7);
    try std.testing.expectEqual(@as(u32, 0), spike_dot_y);
}

test "chartDotY maps higher values toward the top" {
    try std.testing.expectEqual(@as(u32, 7), chartDotY(0, 0, 10, 8));
    try std.testing.expectEqual(@as(u32, 0), chartDotY(10, 0, 10, 8));
}
