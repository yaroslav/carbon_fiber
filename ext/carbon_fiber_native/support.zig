// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");

pub const crb = rb.crb;
const Value = rb.Value;

pub extern fn rb_io_buffer_get_bytes_for_writing(buffer: crb.VALUE, base: *?*anyopaque, size: *usize) void;
pub extern fn rb_io_buffer_get_bytes_for_reading(buffer: crb.VALUE, base: *?*const anyopaque, size: *usize) void;

pub extern fn rb_thread_call_without_gvl(
    func: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    data1: ?*anyopaque,
    ubf: ?*const fn (?*anyopaque) callconv(.c) void,
    data2: ?*anyopaque,
) ?*anyopaque;

pub extern fn rb_gc_mark_maybe(value: crb.VALUE) void;
pub extern fn rb_fiber_current() crb.VALUE;
pub extern fn rb_thread_current() crb.VALUE;
pub extern fn rb_fiber_alive_p(fiber: crb.VALUE) crb.VALUE;
pub extern fn rb_fiber_transfer(fiber: crb.VALUE, argc: c_int, argv: ?[*]const crb.VALUE) crb.VALUE;
pub extern fn rb_fiber_raise(fiber: crb.VALUE, argc: c_int, argv: ?[*]const crb.VALUE) crb.VALUE;
pub extern fn rb_io_descriptor(io: crb.VALUE) c_int;

pub fn monotonicSeconds() f64 {
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(std.posix.errno(rc) == .SUCCESS);
    return @as(f64, @floatFromInt(ts.sec)) +
        (@as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0);
}

// Encodes a Ruby Fixnum from a Zig integer. Replaces `Value.from(int)` which
// is now @compileError in zig.rb. Inlines the (n << 1) | 1 encoding directly
// rather than going through zig.rb's Fixnum.fromInt to keep the hot path as
// short as possible and to avoid generating extra code paths during LTO.
pub inline fn intValue(value: anytype) Value {
    const FixInt = std.meta.Int(.signed, @typeInfo(c_long).int.bits - 1);
    const v: FixInt = @intCast(value);
    const tagged: crb.VALUE = @bitCast((@as(isize, v) << 1) | 1);
    return Value.fromRaw(tagged);
}

// Decodes a Ruby Fixnum back to an isize. Caller must know `value` is a
// Fixnum: this skips zig.rb's Value.to(...) which dispatches on rb_type and
// otherwise costs an extra Ruby C-API call per byte-count return on the
// hot ioRead/ioWrite paths.
pub inline fn fixnumToIsize(value: Value) isize {
    return @as(isize, @bitCast(value.asRaw())) >> 1;
}

pub fn busySpinUntil(deadline: f64) void {
    while (monotonicSeconds() < deadline) {
        std.atomic.spinLoopHint();
    }
}

pub inline fn fiberAlive(fiber: crb.VALUE) bool {
    return rb_fiber_alive_p(fiber) == crb.Qtrue;
}

// Marks a queue-resident VALUE using Ruby's conservative marker.
// rb_gc_mark_maybe consults Ruby's heap-arena registry and silently
// ignores anything that isn't a live heap object: immediates skip out
// quickly (their tag bits or zero-LSB-mask fail the heap-pointer
// pre-check), and stale slots like the YJIT + error_highlight + Mutex
// pathology fail the arena lookup. Pre-filtering with
// RB_SPECIAL_CONST_P was tried and measurably regressed
// fan_out_gather: the bit tests have to run on every heap-VALUE path
// too, where they're pure overhead in front of the same arena lookup.
pub inline fn markValue(value: crb.VALUE) void {
    rb_gc_mark_maybe(value);
}
