// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");
const Value = rb.Value;
const crb = rb.crb;
const bindings = @import("bindings.zig");

fn defineModuleFunction(module_value: crb.VALUE, name: [*:0]const u8, comptime func: anytype, argc: c_int) void {
    crb.rb_define_module_function(module_value, name, @as(?*const fn (...) callconv(.c) crb.VALUE, @ptrCast(&func)), argc);
}

fn availableWrapper(_: crb.VALUE) callconv(.c) crb.VALUE {
    return Value.from(true).toRaw();
}

fn backendWrapper(_: crb.VALUE) callconv(.c) crb.VALUE {
    return Value.from("libxev").toRaw();
}

export fn Init_carbon_fiber_native() void {
    rb.init();

    const top = crb.rb_define_module("CarbonFiber");
    const native = crb.rb_define_module_under(top, "Native");
    bindings.register(native);

    defineModuleFunction(native, "available?", availableWrapper, 0);
    defineModuleFunction(native, "backend", backendWrapper, 0);
}
