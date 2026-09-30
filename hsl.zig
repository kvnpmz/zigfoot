const std = @import("std");

export fn hsl_to_rgb(hue: c_int, sat: c_int, lum: c_int) callconv(.c) u32 {
    const L: f64 = @as(f64, @floatFromInt(lum)) / 100.0;
    const S: f64 = @as(f64, @floatFromInt(sat)) / 100.0;
    const C: f64 = (1.0 - @abs(2.0 * L - 1.0)) * S;

    const hue_f: f64 = @floatFromInt(hue);
    const X: f64 = C * (1.0 - @abs(@mod(hue_f / 60.0, 2.0) - 1.0));
    const m: f64 = L - C / 2.0;

    var r: f64 = 0.0;
    var g: f64 = 0.0;
    var b: f64 = 0.0;

    if (hue >= 0 and hue <= 60) {
        r = C;
        g = X;
        b = 0.0;
    } else if (hue >= 60 and hue <= 120) {
        r = X;
        g = C;
        b = 0.0;
    } else if (hue >= 120 and hue <= 180) {
        r = 0.0;
        g = C;
        b = X;
    } else if (hue >= 180 and hue <= 240) {
        r = 0.0;
        g = X;
        b = C;
    } else if (hue >= 240 and hue <= 300) {
        r = X;
        g = 0.0;
        b = C;
    } else if (hue >= 300 and hue <= 360) {
        r = C;
        g = 0.0;
        b = X;
    } else {
        r = 0.0;
        g = 0.0;
        b = 0.0;
    }

    r += m;
    g += m;
    b += m;

    const r_byte: u32 = @intFromFloat(@round(r * 255.0));
    const g_byte: u32 = @intFromFloat(@round(g * 255.0));
    const b_byte: u32 = @intFromFloat(@round(b * 255.0));

    return (r_byte << 16) | (g_byte << 8) | b_byte;
}
