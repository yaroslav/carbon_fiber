// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");

pub const crb = rb.crb;

pub extern fn rb_io_buffer_get_bytes_for_writing(buffer: crb.VALUE, base: *?*anyopaque, size: *usize) void;
pub extern fn rb_io_buffer_get_bytes_for_reading(buffer: crb.VALUE, base: *?*const anyopaque, size: *usize) void;

pub extern fn rb_thread_call_without_gvl(
    func: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    data1: ?*anyopaque,
    ubf: ?*const fn (?*anyopaque) callconv(.c) void,
    data2: ?*anyopaque,
) ?*anyopaque;

pub extern fn rb_gc_mark_movable(value: crb.VALUE) void;
pub extern fn rb_gc_location(value: crb.VALUE) crb.VALUE;
pub extern fn rb_fiber_current() crb.VALUE;
pub extern fn rb_thread_current() crb.VALUE;
pub extern fn rb_fiber_alive_p(fiber: crb.VALUE) crb.VALUE;
pub extern fn rb_fiber_transfer(fiber: crb.VALUE, argc: c_int, argv: ?[*]const crb.VALUE) crb.VALUE;
pub extern fn rb_fiber_raise(fiber: crb.VALUE, argc: c_int, argv: ?[*]const crb.VALUE) crb.VALUE;
pub extern fn rb_io_descriptor(io: crb.VALUE) c_int;

pub fn monotonicSeconds() f64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch unreachable;
    return @as(f64, @floatFromInt(ts.sec)) +
        (@as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0);
}

pub fn busySpinUntil(deadline: f64) void {
    while (monotonicSeconds() < deadline) {
        std.atomic.spinLoopHint();
    }
}

pub fn fiberAlive(fiber: crb.VALUE) bool {
    return rb_fiber_alive_p(fiber) == crb.Qtrue;
}

pub fn markValue(value: crb.VALUE) void {
    if (value != crb.Qnil) rb_gc_mark_movable(value);
}

pub fn compactValue(value: crb.VALUE) crb.VALUE {
    if (value == crb.Qnil) return value;
    return rb_gc_location(value);
}
