const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const MAX_SAFE_SURFACE_AREA: u32 = std.math.maxInt(u16);
const MAX_SAFE_SURFACE_DIM: u16 = 1024;

pub fn sanitize(raw: vxfw.Size) vxfw.Size {
    var size = raw;
    size.width = clampDimension(size.width);
    size.height = clampDimension(size.height);

    while (!fits(size) and size.height > 1) {
        size.height -= 1;
    }
    while (!fits(size) and size.width > 1) {
        size.width -= 1;
    }

    if (!fits(size)) return .{ .width = 1, .height = 1 };
    return size;
}

fn clampDimension(value: u16) u16 {
    if (value == 0) return 1;
    return @min(value, MAX_SAFE_SURFACE_DIM);
}

fn fits(size: vxfw.Size) bool {
    const area = std.math.mul(u32, size.width, size.height) catch return false;
    return area <= MAX_SAFE_SURFACE_AREA;
}
