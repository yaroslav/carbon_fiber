// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");
const Value = rb.Value;
const crb = rb.crb;
const bindings = @import("bindings.zig");

// See bindings.zig for the rationale on re-declaring this with an
// `*const anyopaque` slot.
extern fn rb_define_module_function(
    module: crb.VALUE,
    name: [*c]const u8,
    func: *const anyopaque,
    arity: c_int,
) void;

fn defineModuleFunction(module_value: crb.VALUE, name: [*:0]const u8, comptime func: anytype, argc: c_int) void {
    rb_define_module_function(module_value, name, &func, argc);
}

fn availableWrapper(_: crb.VALUE) callconv(.c) crb.VALUE {
    return Value.from(true).asRaw();
}

fn backendWrapper(_: crb.VALUE) callconv(.c) crb.VALUE {
    return Value.from("libxev").asRaw();
}

export fn Init_carbon_fiber_native() void {
    rb.init();

    const top = crb.rb_define_module("CarbonFiber");
    const native = crb.rb_define_module_under(top, "Native");
    bindings.register(native);

    defineModuleFunction(native, "available?", availableWrapper, 0);
    defineModuleFunction(native, "backend", backendWrapper, 0);
}
