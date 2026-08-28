/* Compiled against the target Ruby's real headers, unlike the pre-generated
 * Zig bindings, which can go stale when the headers change.
 *
 * Including <ruby.h> defines the weak ruby_abi_version() from
 * ruby/internal/abi.h on development Rubies, exactly as mkmf-built
 * extensions get it, so the ABI check compares genuine header values.
 *
 * The functions below export the real size and field offsets of
 * rb_data_type_t; main.zig verifies the layout the Zig side selected
 * against them at load time, turning silent binding staleness into a
 * clean LoadError. Only fields present on every supported Ruby (3.4+)
 * are referenced here.
 */
#include <ruby.h>
#include <stddef.h>

size_t carbon_fiber_rb_data_type_sizeof(void) { return sizeof(rb_data_type_t); }
size_t carbon_fiber_rb_data_type_offsetof_dmark(void) { return offsetof(rb_data_type_t, function.dmark); }
size_t carbon_fiber_rb_data_type_offsetof_dfree(void) { return offsetof(rb_data_type_t, function.dfree); }
size_t carbon_fiber_rb_data_type_offsetof_dsize(void) { return offsetof(rb_data_type_t, function.dsize); }
size_t carbon_fiber_rb_data_type_offsetof_dcompact(void) { return offsetof(rb_data_type_t, function.dcompact); }
size_t carbon_fiber_rb_data_type_offsetof_parent(void) { return offsetof(rb_data_type_t, parent); }
size_t carbon_fiber_rb_data_type_offsetof_data(void) { return offsetof(rb_data_type_t, data); }
size_t carbon_fiber_rb_data_type_offsetof_flags(void) { return offsetof(rb_data_type_t, flags); }
