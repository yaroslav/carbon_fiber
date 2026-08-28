// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");
const Value = rb.Value;
const crb = rb.crb;
const bindings = @import("bindings.zig");
const Selector = @import("selector.zig").Selector;

// Layout facts from abi.c, compiled against the target Ruby's real headers.
extern fn carbon_fiber_rb_data_type_sizeof() usize;
extern fn carbon_fiber_rb_data_type_offsetof_dmark() usize;
extern fn carbon_fiber_rb_data_type_offsetof_dfree() usize;
extern fn carbon_fiber_rb_data_type_offsetof_dsize() usize;
extern fn carbon_fiber_rb_data_type_offsetof_dcompact() usize;
extern fn carbon_fiber_rb_data_type_offsetof_parent() usize;
extern fn carbon_fiber_rb_data_type_offsetof_data() usize;
extern fn carbon_fiber_rb_data_type_offsetof_flags() usize;

// The Zig-side rb_data_type_t layout comes from pre-generated bindings
// plus a build-time version switch; neither is derived from the headers
// this Ruby was built with. Comparing against abi.c's header-derived
// facts turns a stale or mis-selected layout into a clean LoadError
// instead of undefined behavior.
fn verifyDataTypeLayout() void {
    const Layout = @TypeOf(Selector.RubyType.rb_data_type);
    const Function = @FieldType(Layout, "function");
    const function_base = @offsetOf(Layout, "function");

    const matches =
        carbon_fiber_rb_data_type_sizeof() == @sizeOf(Layout) and
        carbon_fiber_rb_data_type_offsetof_dmark() == function_base + @offsetOf(Function, "dmark") and
        carbon_fiber_rb_data_type_offsetof_dfree() == function_base + @offsetOf(Function, "dfree") and
        carbon_fiber_rb_data_type_offsetof_dsize() == function_base + @offsetOf(Function, "dsize") and
        carbon_fiber_rb_data_type_offsetof_dcompact() == function_base + @offsetOf(Function, "dcompact") and
        carbon_fiber_rb_data_type_offsetof_parent() == @offsetOf(Layout, "parent") and
        carbon_fiber_rb_data_type_offsetof_data() == @offsetOf(Layout, "data") and
        carbon_fiber_rb_data_type_offsetof_flags() == @offsetOf(Layout, "flags");

    if (!matches) {
        crb.rb_raise(crb.rb_eLoadError, "carbon_fiber: rb_data_type_t layout mismatch between the extension's bindings and this Ruby's headers; rebuild against bindings generated for this Ruby version");
    }
}

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
    verifyDataTypeLayout();

    const top = crb.rb_define_module("CarbonFiber");
    const native = crb.rb_define_module_under(top, "Native");
    bindings.register(native);

    defineModuleFunction(native, "available?", availableWrapper, 0);
    defineModuleFunction(native, "backend", backendWrapper, 0);
}
