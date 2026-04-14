//! Ruby C-extension bindings: converts between raw C VALUEs and typed Zig calls.
//! All wrappers follow the same pattern: unpack args → call InstanceMethods → return raw VALUE.
//!
//! Note: zig.rb's TypedDataClass.defineMethods would eliminate these wrappers, but has a
//! @ptrCast/@alignCast bug that prevents use. Upstream fix needed before adopting it.

// Please note that Zig code is heavily AI-assisted.

const rb = @import("rb");
const Value = rb.Value;
const crb = rb.crb;
const Selector = @import("selector.zig").Selector;

pub fn register(native_raw: crb.VALUE) void {
    const selector_class = crb.rb_define_class_under(native_raw, "Selector", crb.rb_cObject);
    crb.rb_define_alloc_func(selector_class, Selector.RubyType.alloc_func);

    define(selector_class, "initialize", selectorInitializeWrapper, 1);
    define(selector_class, "destroy", selectorDestroyWrapper, 0);
    define(selector_class, "pending?", selectorPendingWrapper, 0);
    define(selector_class, "push", selectorPushWrapper, 1);
    define(selector_class, "resume", selectorResumeWrapper, 2);
    define(selector_class, "raise", selectorRaiseWrapper, 2);
    define(selector_class, "wakeup", selectorWakeupWrapper, 0);
    define(selector_class, "transfer", selectorTransferWrapper, 0);
    define(selector_class, "yield", selectorYieldWrapper, 0);
    define(selector_class, "select", selectorSelectWrapper, 1);
    define(selector_class, "block", selectorBlockWrapper, 2);
    define(selector_class, "unblock", selectorUnblockWrapper, 1);
    define(selector_class, "raise_after", selectorRaiseAfterWrapper, 3);
    define(selector_class, "cancel_timer", selectorCancelTimerWrapper, 1);
    define(selector_class, "io_wait", selectorIoWaitWrapper, 3);
    define(selector_class, "io_wait_with_timeout", selectorIoWaitWithTimeoutWrapper, 4);
    define(selector_class, "io_wait_object", selectorIoWaitObjectWrapper, 3);
    define(selector_class, "io_close", selectorIoCloseWrapper, 2);
    define(selector_class, "io_read", selectorIoReadWrapper, 4);
    define(selector_class, "io_read_object", selectorIoReadObjectWrapper, 4);
    define(selector_class, "io_write", selectorIoWriteWrapper, 4);
    define(selector_class, "io_write_object", selectorIoWriteObjectWrapper, 4);
    define(selector_class, "process_wait", selectorProcessWaitWrapper, 3);
    define(selector_class, "poll_readable_now", selectorPollReadableNowWrapper, 1);
    define(selector_class, "cancel_block_timer", selectorCancelBlockTimerWrapper, 1);

    // Aliases for subclass use: Ruby overrides of push/io_wait/etc. can call
    // these to reach the native implementation without conflicting with their
    // own method names. E.g. the Async adapter overrides `push` to handle
    // non-Fiber objects but calls `native_push` for the fast Fiber path.
    define(selector_class, "native_push", selectorPushWrapper, 1);
    define(selector_class, "native_io_wait", selectorIoWaitWrapper, 3);
    define(selector_class, "native_io_wait_with_timeout", selectorIoWaitWithTimeoutWrapper, 4);
    define(selector_class, "native_io_read", selectorIoReadWrapper, 4);
    define(selector_class, "native_io_write", selectorIoWriteWrapper, 4);
}

fn define(class_value: crb.VALUE, name: [*:0]const u8, comptime func: anytype, argc: c_int) void {
    crb.rb_define_method(class_value, name, @as(?*const fn (...) callconv(.c) crb.VALUE, @ptrCast(&func)), argc);
}

fn unwrap(rb_self: crb.VALUE) *Selector {
    return Selector.RubyType.unwrap(rb_self);
}

fn selectorInitializeWrapper(rb_self: crb.VALUE, loop_fiber_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.initialize(unwrap(rb_self), Value.fromRaw(loop_fiber_raw)).toRaw();
}

fn selectorDestroyWrapper(rb_self: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.destroy(unwrap(rb_self)).toRaw();
}

fn selectorPendingWrapper(rb_self: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.pending(unwrap(rb_self)).toRaw();
}

fn selectorPushWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.push(unwrap(rb_self), Value.fromRaw(fiber_raw)).toRaw();
}

fn selectorResumeWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, value_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.@"resume"(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(value_raw)).toRaw();
}

fn selectorRaiseWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, exception_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.raise(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(exception_raw)).toRaw();
}

fn selectorWakeupWrapper(rb_self: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.wakeup(unwrap(rb_self)).toRaw();
}

fn selectorTransferWrapper(rb_self: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.transfer(unwrap(rb_self)).toRaw();
}

fn selectorYieldWrapper(rb_self: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.@"yield"(unwrap(rb_self)).toRaw();
}

fn selectorSelectWrapper(rb_self: crb.VALUE, timeout_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.select(unwrap(rb_self), Value.fromRaw(timeout_raw)).toRaw();
}

fn selectorBlockWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, timeout_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.block(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(timeout_raw)).toRaw();
}

fn selectorUnblockWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.unblock(unwrap(rb_self), Value.fromRaw(fiber_raw)).toRaw();
}

fn selectorRaiseAfterWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, exception_raw: crb.VALUE, duration_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.raise_after(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(exception_raw), Value.fromRaw(duration_raw)).toRaw();
}

fn selectorCancelTimerWrapper(rb_self: crb.VALUE, token_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.cancel_timer(unwrap(rb_self), Value.fromRaw(token_raw)).toRaw();
}

fn selectorIoWaitWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, fd_raw: crb.VALUE, events_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_wait(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(fd_raw), Value.fromRaw(events_raw)).toRaw();
}

fn selectorIoWaitWithTimeoutWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, fd_raw: crb.VALUE, events_raw: crb.VALUE, timeout_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_wait_with_timeout(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(fd_raw), Value.fromRaw(events_raw), Value.fromRaw(timeout_raw)).toRaw();
}

fn selectorIoWaitObjectWrapper(rb_self: crb.VALUE, io_raw: crb.VALUE, events_raw: crb.VALUE, timeout_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_wait_object(unwrap(rb_self), Value.fromRaw(io_raw), Value.fromRaw(events_raw), Value.fromRaw(timeout_raw)).toRaw();
}

fn selectorIoCloseWrapper(rb_self: crb.VALUE, fd_raw: crb.VALUE, exception_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_close(unwrap(rb_self), Value.fromRaw(fd_raw), Value.fromRaw(exception_raw)).toRaw();
}

fn selectorIoReadWrapper(rb_self: crb.VALUE, fd_raw: crb.VALUE, buffer_raw: crb.VALUE, length_raw: crb.VALUE, offset_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_read(unwrap(rb_self), Value.fromRaw(fd_raw), Value.fromRaw(buffer_raw), Value.fromRaw(length_raw), Value.fromRaw(offset_raw)).toRaw();
}

fn selectorIoReadObjectWrapper(rb_self: crb.VALUE, io_raw: crb.VALUE, buffer_raw: crb.VALUE, length_raw: crb.VALUE, offset_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_read_object(unwrap(rb_self), Value.fromRaw(io_raw), Value.fromRaw(buffer_raw), Value.fromRaw(length_raw), Value.fromRaw(offset_raw)).toRaw();
}

fn selectorIoWriteWrapper(rb_self: crb.VALUE, fd_raw: crb.VALUE, buffer_raw: crb.VALUE, length_raw: crb.VALUE, offset_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_write(unwrap(rb_self), Value.fromRaw(fd_raw), Value.fromRaw(buffer_raw), Value.fromRaw(length_raw), Value.fromRaw(offset_raw)).toRaw();
}

fn selectorIoWriteObjectWrapper(rb_self: crb.VALUE, io_raw: crb.VALUE, buffer_raw: crb.VALUE, length_raw: crb.VALUE, offset_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.io_write_object(unwrap(rb_self), Value.fromRaw(io_raw), Value.fromRaw(buffer_raw), Value.fromRaw(length_raw), Value.fromRaw(offset_raw)).toRaw();
}

fn selectorProcessWaitWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE, pid_raw: crb.VALUE, flags_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.process_wait(unwrap(rb_self), Value.fromRaw(fiber_raw), Value.fromRaw(pid_raw), Value.fromRaw(flags_raw)).toRaw();
}

fn selectorPollReadableNowWrapper(rb_self: crb.VALUE, fd_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.poll_readable_now(unwrap(rb_self), Value.fromRaw(fd_raw)).toRaw();
}

fn selectorCancelBlockTimerWrapper(rb_self: crb.VALUE, fiber_raw: crb.VALUE) callconv(.c) crb.VALUE {
    return Selector.InstanceMethods.cancel_block_timer(unwrap(rb_self), Value.fromRaw(fiber_raw)).toRaw();
}
