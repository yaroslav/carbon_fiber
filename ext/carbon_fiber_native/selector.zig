//! Core event loop and I/O multiplexer for CarbonFiber.
//!
//! The Selector wraps a libxev event loop and implements the
//! Ruby Fiber Scheduler protocol at the native level. Each Ruby
//! scheduler instance owns one Selector.
//!
//! Threading model: the Selector runs on the Ruby scheduler
//! thread (the thread that called Fiber.set_scheduler). Operations
//! from other threads (resume, unblock) use the cross-thread path:
//! enqueue into cross_thread_entries under a mutex, then
//! notify via async_handle to wake the event loop.
//!
//! Descriptor lifetime: Descriptor structs are heap-allocated
//! and reference-counted implicitly via active poll completions.
//! When a fd is closed while a poll is in flight, the descriptor
//! moves to retired_descriptors and is freed once all pending
//! completions have fired (completion callbacks still hold
//! a raw pointer to it).

// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const xev = @import("xev");
const rb = @import("rb");
const Error = rb.Error;
const Value = rb.Value;
const crb = rb.crb;
const support = @import("support.zig");
const tq = @import("timer_queue.zig");
const io = @import("io.zig");

const ReadyKind = tq.ReadyKind;
const TimerEntry = tq.TimerEntry;
const TimerAction = tq.TimerAction;
const TimerQueue = tq.TimerQueue;

extern fn rb_process_status_wait(pid: std.posix.pid_t, flags: c_int) crb.VALUE;
extern fn rb_ensure(
    b_proc: *const fn (crb.VALUE) callconv(.c) crb.VALUE,
    data1: crb.VALUE,
    e_proc: *const fn (crb.VALUE) callconv(.c) crb.VALUE,
    data2: crb.VALUE,
) crb.VALUE;

const READABLE: i16 = 1; // IO::READABLE in Ruby
const WRITABLE: i16 = 4; // IO::WRITABLE in Ruby
// Number of consecutive EAGAIN probe misses before skipping the fast-path
// recvOnce in ioRead. Request/response workloads always miss once before the
// peer responds; skipping the probe eliminates a wasted syscall per read.
const PROBE_SKIP_THRESHOLD: u8 = 3;
// Below this deadline distance, busy-spin instead of releasing the GVL.
// GVL acquire/release has ~0.5-1ms overhead on macOS; 3ms avoids the cost
// for timers that would fire almost immediately anyway.
// This threshold also applies on Docker Desktop Linux: the Linux VM layer
// makes rb_thread_call_without_gvl similarly expensive (~76µs/release),
// so spinning is net positive in that environment too.
const SPIN_THRESHOLD: f64 = 0.003;
// Size of the small-fd descriptor cache — fds below this index are
// looked up via direct array indexing instead of the descriptors hashmap.
// 256 is enough for typical server workloads (ulimit nofile is usually
// 1024+, but active fd counts rarely exceed ~200 on a single scheduler).
const DESCRIPTOR_CACHE_SIZE: usize = 256;

const Direction = enum(u1) { read = 0, write = 1 };

const ReadyEntry = struct {
    kind: ReadyKind,
    fiber: crb.VALUE,
    payload: crb.VALUE = crb.Qnil,
};

// Per-direction (read/write) poll state for a descriptor.
// `armed` is true while a completion is queued in the event loop—the
// completion callback holds a raw pointer to the enclosing Descriptor,
// so the Descriptor must not be freed until armed drops to
// false on both directions.
const PollState = struct {
    completion: xev.Completion = .{},
    armed: bool = false,

    // fiber waiting for this direction; Qnil if none
    waiter: crb.VALUE = crb.Qnil,
};

const Descriptor = struct {
    selector: *Selector,
    fd: std.posix.fd_t,
    poll: [2]PollState = .{ .{}, .{} },
    read_timeout_token: ?u64 = null,
    in_map: bool = false,
    closed: bool = false,

    fn pollFor(self: *Descriptor, comptime dir: Direction) *PollState {
        return &self.poll[@intFromEnum(dir)];
    }

    fn anyPollArmed(self: *const Descriptor) bool {
        return self.poll[0].armed or self.poll[1].armed;
    }

    fn cancelReadTimeout(self: *Descriptor) void {
        if (self.read_timeout_token) |token| {
            _ = self.selector.timers.cancel(token);
            self.read_timeout_token = null;
        }
    }
};

const ProcessWait = struct {
    selector: *Selector,
    fiber: crb.VALUE,
    pid: std.posix.pid_t,
    flags: c_int,
    watcher: xev.Process,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    ready: bool = false,
    cancelled: bool = false,
    cancel_pending: bool = false,
    in_list: bool = false,
};

const ProcessWaitCall = struct {
    selector: *Selector,
    wait: *ProcessWait,
};

pub const Selector = struct {
    const Self = @This();

    // Alias required by zig.rb's method-wrapping machinery
    // (Data.ruby_type.unwrap).
    pub const ruby_type = RubyType;

    allocator: std.mem.Allocator = undefined,
    loop: xev.Loop = undefined,
    loop_fiber: crb.VALUE = crb.Qnil,

    async_handle: xev.Async = undefined,
    async_completion: xev.Completion = .{},
    deadline_timer: xev.Timer = undefined,
    deadline_completion: xev.Completion = .{},
    deadline_cancel_completion: xev.Completion = .{},

    timers: TimerQueue = undefined,

    descriptors: std.AutoHashMapUnmanaged(std.posix.fd_t, *Descriptor) = .{},
    retired_descriptors: std.ArrayListUnmanaged(*Descriptor) = .{},
    process_waits: std.ArrayListUnmanaged(*ProcessWait) = .{},
    retired_process_waits: std.ArrayListUnmanaged(*ProcessWait) = .{},
    active_waiters: usize = 0,

    ready_entries: std.ArrayListUnmanaged(ReadyEntry) = .{},
    ready_head: usize = 0,

    cross_thread_mutex: std.Thread.Mutex = .{},
    cross_thread_entries: std.ArrayListUnmanaged(ReadyEntry) = .{},
    cross_thread_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Tracks every fiber that is voluntarily parked via block() or an I/O wait
    // (waitForPoll / ioRecvUring). The value is the block-timer token when the
    // fiber was parked via block(timeout), or 0 (sentinel) otherwise.
    // Timer tokens are assigned sequentially starting at 1, so 0 is safe.
    //
    // Two purposes:
    //   1. flushReady uses it to detect fibers interrupted by rb_fiber_raise
    //      (Ruby 4.0 delivers the exception to the target and returns to
    //      loop_fiber instead of the caller, leaving the caller alive but
    //      stranded). Any alive fiber returned from rb_fiber_transfer that is
    //      NOT in this set needs to be re-queued.
    //   2. raise() reads the timer token to cancel any pending block timeout
    //      before enqueuing the exception — otherwise the longjmp bypasses
    //      block()'s cleanup and the dangling timer keeps hasPending() true.
    blocked_fibers: std.AutoHashMapUnmanaged(crb.VALUE, u64) = .{},

    // Per-fd consecutive EAGAIN miss counter for the recvOnce probe in ioRead.
    // Indexed by fd & 0xFF. When a probe misses PROBE_SKIP_THRESHOLD times in a
    // row, subsequent calls skip the syscall and go straight to
    // io_uring/kqueue.
    // Reset on probe hit and on fd close (to handle fd reuse safely).
    probe_misses: [256]u8 = std.mem.zeroes([256]u8),

    initialized: bool = false,
    // Set by deadlineTimerCallback so waitWithoutGVL can distinguish a genuine
    // deadline wakeup from a spurious GC-preemption notify.
    deadline_fired: bool = false,
    // True while the selector is blocked in waitWithoutGVL (GVL released,
    // waiting for I/O or timer events). Used by wakeup() to skip the
    // async_handle.notify() syscall when we're on the scheduler thread
    // and the selector is not actually blocked.
    blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Thread VALUE captured during initialize—used by push() to distinguish
    // same-thread (direct enqueue) from cross-thread (mutex + conditional notify).
    scheduler_thread: crb.VALUE = crb.Qnil,

    // Fast-path lookup array for small fds (< DESCRIPTOR_CACHE_SIZE).
    // Typical server workloads use a dense, small fd space—the array
    // lookup avoids the hashmap's hash + probe overhead on every io_wait /
    // ioRecvUring call. Kept consistent with `descriptors` via
    // ensureDescriptor and ioClose.  Placed at the end of the struct (large
    // 2 KiB field) so it doesn't push hot-path fields into colder cache lines.
    descriptor_cache: [DESCRIPTOR_CACHE_SIZE]?*Descriptor = [_]?*Descriptor{null} ** DESCRIPTOR_CACHE_SIZE,

    pub const RubyType = struct {
        pub const rb_data_type: crb.rb_data_type_t = .{
            .wrap_struct_name = "CarbonFiber::Native::Selector",
            .function = .{
                .dmark = &selectorMark,
                .dfree = &selectorFree,
                .dsize = null,
                .dcompact = &selectorCompact,
                .reserved = .{null},
            },
            .parent = null,
            .data = null,
            .flags = crb.RUBY_TYPED_FREE_IMMEDIATELY,
        };

        pub fn alloc_func(rb_class: crb.VALUE) callconv(.c) crb.VALUE {
            const selector = std.heap.c_allocator.create(Self) catch @panic("failed to allocate selector");
            selector.* = .{};
            return crb.rb_data_typed_object_wrap(rb_class, selector, &rb_data_type);
        }

        pub inline fn unwrap(rb_value: crb.VALUE) *Self {
            return @ptrCast(@alignCast(crb.rb_check_typeddata(rb_value, &rb_data_type)));
        }
    };

    /// Methods exposed to Ruby via bindings.zig. Each corresponds to a
    /// method on CarbonFiber::Native::Selector.
    pub const InstanceMethods = struct {
        /// Set up the event loop and ready queue. Called once per Selector.
        pub fn initialize(self: *Self, loop_fiber_val: Value) Value {
            if (!self.initialized) {
                self.setup(std.heap.c_allocator, loop_fiber_val.toRaw()) catch
                    Error.raiseRuntimeError("Failed to initialize CarbonFiber::Native::Selector");
            }
            return Value.nil;
        }

        /// Release all native resources (event loop, descriptors, timers).
        pub fn destroy(self: *Self) Value {
            self.release();
            return Value.from(true);
        }

        /// True if there are ready fibers, pending timers, or
        /// active I/O waiters.
        pub fn pending(self: *Self) Value {
            self.ensureInitialized();
            return Value.from(self.hasPending());
        }

        /// Enqueue a fiber into the ready queue (thread-safe).
        pub fn push(self: *Self, fiber_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            if (support.rb_thread_current() == self.scheduler_thread) {
                // Same thread: direct enqueue, no locking needed
                self.enqueue(.resume_fiber, fiber, crb.Qnil) catch
                    Error.raiseRuntimeError("Failed to enqueue fiber");
            } else {
                // Cross thread: mutex-protected enqueue + conditional notify
                self.enqueueCrossThread(.{
                    .kind = .resume_fiber,
                    .fiber = fiber,
                    .payload = Value.from(true).toRaw(),
                }) catch Error.raiseRuntimeError("Failed to enqueue fiber (cross-thread)");
                if (self.blocked.load(.acquire)) {
                    self.async_handle.notify() catch
                        Error.raiseRuntimeError("Failed to wake selector");
                }
            }
            return fiber_val;
        }

        /// Enqueue a fiber with a return value. Thread-safe: called from
        /// background threads via Scheduler#await_background_operation.
        pub fn @"resume"(self: *Self, fiber_val: Value, value_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            const payload = value_val.toRaw();
            if (support.rb_thread_current() == self.scheduler_thread) {
                self.enqueue(.resume_fiber, fiber, payload) catch
                    Error.raiseRuntimeError("Failed to enqueue resume");
            } else {
                self.enqueueCrossThread(.{
                    .kind = .resume_fiber,
                    .fiber = fiber,
                    .payload = payload,
                }) catch Error.raiseRuntimeError("Failed to enqueue resume (cross-thread)");
                if (self.blocked.load(.acquire)) {
                    self.async_handle.notify() catch
                        Error.raiseRuntimeError("Failed to wake selector");
                }
            }
            return fiber_val;
        }

        /// Deliver an exception to a suspended fiber.
        /// Cancels any pending block timeout.
        pub fn raise(self: *Self, fiber_val: Value, exception_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            // Cancel any pending block() timeout for this fiber. If we don't do
            // this, the longjmp that delivers the exception bypasses the cancel
            // call in block(), leaving a dangling timer that
            // keeps the scheduler alive until it naturally expires.
            // Clear the token in the map so the block() cleanup path
            // doesn't double-cancel.
            if (self.blocked_fibers.getPtr(fiber)) |token_ptr| {
                if (token_ptr.* != 0) {
                    _ = self.timers.cancel(token_ptr.*);
                    token_ptr.* = 0; // clear so block()'s cleanup doesn't double-cancel
                }
            }
            self.enqueue(.raise, fiber, exception_val.toRaw()) catch
                Error.raiseRuntimeError("Failed to enqueue raise");
            return fiber_val;
        }

        /// Wake the event loop from another thread via async_handle.
        pub fn wakeup(self: *Self) Value {
            self.ensureInitialized();
            if (self.blocked.load(.acquire)) {
                self.async_handle.notify() catch
                    Error.raiseRuntimeError("Failed to wake selector");
            }
            return Value.from(true);
        }

        /// Transfer to the next ready fiber, or to the loop fiber if none ready.
        pub fn transfer(self: *Self) Value {
            // Fast path: try chaining to the next ready fiber directly,
            // avoiding rb_fiber_current() overhead. Transfer is never
            // called from the loop fiber (Async only calls it from block()),
            // so we skip the loop_fiber identity check that doTransferToLoop does.
            while (self.ready_head < self.ready_entries.items.len) {
                const entry = self.ready_entries.items[self.ready_head];
                if (entry.kind != .resume_fiber) break;

                self.ready_head += 1;

                if (!support.fiberAlive(entry.fiber)) continue;

                var argv = [_]crb.VALUE{entry.payload};
                return Value.fromRaw(support.rb_fiber_transfer(entry.fiber, 1, &argv));
            }

            return Value.fromRaw(support.rb_fiber_transfer(self.loop_fiber, 0, null));
        }

        /// Re-enqueue the current fiber and transfer to the event loop.
        pub fn yield(self: *Self) Value {
            self.ensureInitialized();
            const current = support.rb_fiber_current();
            self.enqueue(.resume_fiber, current, crb.Qnil) catch
                Error.raiseRuntimeError("Failed to yield current fiber");
            return self.doTransferToLoop(current);
        }

        /// Run one event loop iteration. Flushes ready fibers, polls for I/O.
        pub fn select(self: *Self, timeout_val: Value) Value {
            self.ensureInitialized();
            const timeout = if (timeout_val.isNil()) null else floatFromValue(timeout_val, null);
            return Value.from(self.doSelect(timeout) catch
                Error.raiseRuntimeError("selector.select failed"));
        }

        /// Suspend the current fiber until unblocked or timed out.
        pub fn block(self: *Self, fiber_val: Value, timeout_val: Value) Value {
            self.ensureInitialized();

            const fiber = fiber_val.toRaw();
            const timeout = if (timeout_val.isNil()) null else floatFromValue(timeout_val, null);
            var timer_token: u64 = 0; // 0 = no timer

            if (timeout) |seconds| {
                if (seconds >= 0.0 and std.math.isFinite(seconds)) {
                    timer_token = self.scheduleTimer(.resume_fiber, fiber, Value.from(false).toRaw(), seconds, null) catch
                        Error.raiseRuntimeError("Failed to schedule block timeout");
                }
            }

            // Do NOT use doTransferToLoop() here — its chain optimization parks
            // this fiber inside a chained transfer to another fiber.  When Ruby
            // 4.0 raises on a sleeping fiber via rb_fiber_raise (which bypasses
            // all scheduler hooks), the raise-target fiber terminates
            // and control returns to the loop fiber, permanently stranding
            // the fiber that called rb_fiber_raise.
            // Parking directly at loop_fiber means
            // rb_fiber_raise returns control to its caller as expected.
            self.blocked_fibers.put(self.allocator, fiber, timer_token) catch
                Error.raiseRuntimeError("Failed to track blocked fiber");
            self.drainCrossThread();
            const result = Value.fromRaw(support.rb_fiber_transfer(self.loop_fiber, 0, null));

            // Normal wakeup path: remove the tracking entry and
            // cancel the timer (cancel is a no-op if it already fired
            // or raise() zeroed it).
            _ = self.blocked_fibers.remove(fiber);
            if (timer_token != 0) _ = self.timers.cancel(timer_token);

            return result;
        }

        /// Cancel any pending sleep timer for `fiber_val`.  Called from
        /// fiber_done (Ruby ensure block) so it runs even when the fiber exits
        /// via an unhandled exception or rb_fiber_raise, bypassing the normal
        /// block() return path.  Without this, the dangling timer keeps
        /// hasPending() true and the scheduler loops forever.
        pub fn cancel_block_timer(self: *Self, fiber_val: Value) Value {
            if (!self.initialized) return Value.nil;
            const fiber = fiber_val.toRaw();
            // Remove from blocked set (so flushReady doesn't mistake a dead
            // fiber for a live voluntarily-sleeping one) and cancel any
            // pending sleep timer if still armed.
            if (self.blocked_fibers.fetchRemove(fiber)) |kv| {
                if (kv.value != 0) _ = self.timers.cancel(kv.value);
            }
            return Value.nil;
        }

        /// Resume a fiber previously suspended by block() (thread-safe).
        pub fn unblock(self: *Self, fiber_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            if (support.rb_thread_current() == self.scheduler_thread) {
                // Same thread: direct enqueue, no locking or notify needed.
                // Thread::Queue#push, Mutex#unlock etc. call unblock from the
                // scheduler thread when both the unblocking and
                // the blocked fiber live in the same scheduler.
                // The GVL is held, so the scheduler will drain ready_entries
                // in its next flushReady before blocking.
                self.enqueue(.resume_fiber, fiber, Value.from(true).toRaw()) catch
                    Error.raiseRuntimeError("Failed to enqueue unblock");
            } else {
                self.enqueueCrossThread(.{
                    .kind = .resume_fiber,
                    .fiber = fiber,
                    .payload = Value.from(true).toRaw(),
                }) catch Error.raiseRuntimeError("Failed to enqueue unblock (cross-thread)");
                // Only notify when the selector is blocked in kevent/io_uring.
                // If not blocked, the scheduler thread holds the GVL and will
                // drain cross_thread_entries in the next flushReady before it
                // can enter a blocking wait — no lost wakeup possible.
                if (self.blocked.load(.acquire)) {
                    self.async_handle.notify() catch
                        Error.raiseRuntimeError("Failed to wake selector");
                }
            }
            return Value.from(true);
        }

        /// Schedule an exception to be raised on a fiber after `duration` seconds.
        pub fn raise_after(self: *Self, fiber_val: Value, exception_val: Value, duration_val: Value) Value {
            self.ensureInitialized();
            const duration = floatFromValue(duration_val, 0.0);
            const token = self.scheduleTimer(.raise, fiber_val.toRaw(), exception_val.toRaw(), duration, null) catch
                Error.raiseRuntimeError("Failed to schedule raise_after");
            return Value.from(token);
        }

        /// Cancel a pending timer by token. Returns true if cancelled,
        /// false if already fired.
        pub fn cancel_timer(self: *Self, token_val: Value) Value {
            self.ensureInitialized();
            const token = integerFromValue(u64, token_val, "expected timer token");
            return Value.from(self.timers.cancel(token));
        }

        /// Wait for I/O readiness on a file descriptor.
        /// Returns readiness bitmask or nil.
        pub fn io_wait(self: *Self, fiber_val: Value, fd_val: Value, events_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            const events = integerFromValue(i16, events_val, "expected io_wait events");
            return self.ioWait(fiber, fd, events, null) catch
                Error.raiseRuntimeError("selector.io_wait failed");
        }

        /// Like io_wait but with a timeout in seconds.
        /// Returns false on timeout.
        pub fn io_wait_with_timeout(self: *Self, fiber_val: Value, fd_val: Value, events_val: Value, timeout_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            const events = integerFromValue(i16, events_val, "expected io_wait events");
            const timeout = floatFromValue(timeout_val, null);
            return self.ioWait(fiber, fd, events, timeout) catch
                Error.raiseRuntimeError("selector.io_wait_with_timeout failed");
        }

        /// Native io_wait matching the Ruby fiber scheduler signature:
        /// accepts the IO object, events bitmask, and an optional nil /
        /// numeric timeout.  Calls `rb_io_descriptor` internally and gets
        /// `Fiber.current` in Zig, eliminating per-call Ruby dispatch +
        /// fileno extraction + timeout branch from `Scheduler#io_wait`.
        pub fn io_wait_object(self: *Self, io_val: Value, events_val: Value, timeout_val: Value) Value {
            self.ensureInitialized();
            const fiber = support.rb_fiber_current();
            const fd: i32 = @intCast(support.rb_io_descriptor(io_val.toRaw()));
            const events = integerFromValue(i16, events_val, "expected io_wait events");
            const timeout: ?f64 = if (timeout_val.isNil()) null else floatFromValue(timeout_val, null);
            return self.ioWait(fiber, fd, events, timeout) catch
                Error.raiseRuntimeError("selector.io_wait_object failed");
        }

        /// Cancel pending waiters on a fd and retire the descriptor.
        pub fn io_close(self: *Self, fd_val: Value, exception_val: Value) Value {
            self.ensureInitialized();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            self.ioClose(fd, exception_val.toRaw()) catch
                Error.raiseRuntimeError("selector.io_close failed");
            return Value.from(true);
        }

        /// Read from a socket fd into an IO::Buffer.
        /// Returns bytes read or nil for non-sockets.
        pub fn io_read(self: *Self, fd_val: Value, buffer_val: Value, length_val: Value, offset_val: Value) Value {
            self.ensureInitialized();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            const length = integerFromValue(usize, length_val, "expected read length");
            const offset = integerFromValue(usize, offset_val, "expected read offset");
            return self.ioRead(fd, buffer_val, length, offset) catch
                Error.raiseRuntimeError("selector.io_read failed");
        }

        /// Native io_read that accepts an IO object directly. Extracts the
        /// descriptor in Zig via `rb_io_descriptor`, skipping a Ruby
        /// `respond_to?(:fileno)` + `io.fileno` pair on every call from
        /// `Scheduler#io_read`.  Returns nil if `rb_io_descriptor` can't
        /// extract (non-IO object), letting the Ruby caller fall back.
        pub fn io_read_object(self: *Self, io_val: Value, buffer_val: Value, length_val: Value, offset_val: Value) Value {
            self.ensureInitialized();
            const fd: i32 = @intCast(support.rb_io_descriptor(io_val.toRaw()));
            const length = integerFromValue(usize, length_val, "expected read length");
            const offset = integerFromValue(usize, offset_val, "expected read offset");
            return self.ioRead(fd, buffer_val, length, offset) catch
                Error.raiseRuntimeError("selector.io_read_object failed");
        }

        /// Write from an IO::Buffer to a socket fd.
        /// Returns bytes written or nil for non-sockets.
        pub fn io_write(self: *Self, fd_val: Value, buffer_val: Value, length_val: Value, offset_val: Value) Value {
            self.ensureInitialized();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            const length = integerFromValue(usize, length_val, "expected write length");
            const offset = integerFromValue(usize, offset_val, "expected write offset");
            return self.ioWrite(fd, buffer_val, length, offset) catch
                Error.raiseRuntimeError("selector.io_write failed");
        }

        /// Native io_write that accepts an IO object directly. Same
        /// rationale as io_read_object — skip the Ruby-side fileno dance.
        pub fn io_write_object(self: *Self, io_val: Value, buffer_val: Value, length_val: Value, offset_val: Value) Value {
            self.ensureInitialized();
            const fd: i32 = @intCast(support.rb_io_descriptor(io_val.toRaw()));
            const length = integerFromValue(usize, length_val, "expected write length");
            const offset = integerFromValue(usize, offset_val, "expected write offset");
            return self.ioWrite(fd, buffer_val, length, offset) catch
                Error.raiseRuntimeError("selector.io_write_object failed");
        }

        /// Wait for a child process via pidfd/kqueue. Returns Process::Status.
        pub fn process_wait(self: *Self, fiber_val: Value, pid_val: Value, flags_val: Value) Value {
            self.ensureInitialized();
            const fiber = fiber_val.toRaw();
            const pid = integerFromValue(std.posix.pid_t, pid_val, "expected pid");
            const flags = integerFromValue(c_int, flags_val, "expected wait flags");
            return self.processWait(fiber, pid, flags) catch
                Error.raiseRuntimeError("selector.process_wait failed");
        }

        /// Non-blocking check if a socket fd has data available (MSG_PEEK).
        pub fn poll_readable_now(self: *Self, fd_val: Value) Value {
            self.ensureInitialized();
            const fd = integerFromValue(i32, fd_val, "expected fd");
            return Value.from(io.pollReadableNow(fd));
        }
    };

    fn setup(self: *Self, allocator: std.mem.Allocator, loop_fiber: crb.VALUE) !void {
        if (self.initialized) return;

        self.allocator = allocator;
        self.loop = try xev.Loop.init(.{});
        self.async_handle = try xev.Async.init();
        self.deadline_timer = try xev.Timer.init();
        self.timers = TimerQueue.init(allocator);
        self.loop_fiber = loop_fiber;

        self.async_handle.wait(&self.loop, &self.async_completion, Self, self, asyncCallback);

        // Pre-allocate ready queue to avoid early reallocs
        // in high-churn workloads.
        try self.ready_entries.ensureTotalCapacity(allocator, 256);

        self.scheduler_thread = support.rb_thread_current();
        self.initialized = true;
    }

    fn release(self: *Self) void {
        if (!self.initialized) return;

        var desc_it = self.descriptors.iterator();
        while (desc_it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        for (self.retired_descriptors.items) |descriptor| {
            self.allocator.destroy(descriptor);
        }
        for (self.process_waits.items) |wait| {
            wait.watcher.deinit();
            self.allocator.destroy(wait);
        }
        for (self.retired_process_waits.items) |wait| {
            wait.watcher.deinit();
            self.allocator.destroy(wait);
        }

        self.ready_entries.deinit(self.allocator);
        self.cross_thread_entries.deinit(self.allocator);
        self.blocked_fibers.deinit(self.allocator);
        self.timers.deinit();
        self.descriptors.deinit(self.allocator);
        self.retired_descriptors.deinit(self.allocator);
        self.process_waits.deinit(self.allocator);
        self.retired_process_waits.deinit(self.allocator);
        self.deadline_timer.deinit();
        self.async_handle.deinit();
        self.loop.deinit();
        self.loop_fiber = crb.Qnil;
        self.ready_head = 0;
        self.active_waiters = 0;
        self.descriptor_cache = [_]?*Descriptor{null} ** DESCRIPTOR_CACHE_SIZE;
        self.initialized = false;
    }

    inline fn ensureInitialized(self: *Self) void {
        if (!self.initialized) {
            Error.raiseRuntimeError("CarbonFiber::Native::Selector is not initialized");
        }
    }

    fn hasPending(self: *Self) bool {
        return (self.ready_head < self.ready_entries.items.len) or
            self.cross_thread_pending.load(.acquire) or
            self.timers.pending() or
            (self.active_waiters > 0);
    }

    fn ioWait(self: *Self, fiber: crb.VALUE, fd: std.posix.fd_t, events: i16, timeout: ?f64) !Value {
        if ((events & READABLE) != 0 and (events & WRITABLE) != 0) {
            // Combined R|W: poll for writable (covers connect
            // completion on both kqueue and io_uring).
            // Return full requested mask (hardcoded, not
            // the observed event): connect completion implies both ready.
            const ready = try self.waitForPoll(fiber, fd, .write, timeout);
            if (ready == null) return Value.nil;
            if (!ready.?) return Value.from(false);
            return Value.from(@as(i64, READABLE | WRITABLE));
        }
        if ((events & READABLE) != 0) {
            // Skip pollReadableNow: Ruby calls io_wait after EAGAIN, so the fd
            // is known not-ready. The peek syscall would almost always fail.
            const ready = try self.waitForPoll(fiber, fd, .read, timeout);
            if (ready == null) return Value.nil;
            if (!ready.?) return Value.from(false);
            return Value.from(@as(i64, READABLE));
        }
        if ((events & WRITABLE) != 0) {
            const ready = try self.waitForPoll(fiber, fd, .write, timeout);
            if (ready == null) return Value.nil;
            if (!ready.?) return Value.from(false);
            return Value.from(@as(i64, WRITABLE));
        }
        return Value.nil;
    }

    // Arm a poll on `fd` in direction `dir` and transfer to the loop fiber.
    // Returns:
    //   null  — fd is closed or already has a waiter (caller should
    //           return nil to Ruby)
    //   false — timed out (no readiness event before deadline)
    //   true  — fd became ready
    fn waitForPoll(self: *Self, fiber: crb.VALUE, fd: std.posix.fd_t, comptime dir: Direction, timeout: ?f64) !?bool {
        // kqueue EVFILT_WRITE is level-triggered and fires continuously
        // while the socket is writable. libxev's active counter is
        // decremented for EVERY event through the main kevent() loop:
        // including stale fires that arrive before EV_DELETE is processed.
        // This causes active to underflow, making loop.run(.once)
        // return immediately forever. Use the Ruby fallback path
        // (await_background_operation) for all WRITE direction polls on kqueue.
        if (comptime xev.backend == .kqueue) {
            if (dir == .write) return null;
        }

        const descriptor = try self.ensureDescriptor(fd);
        const state = descriptor.pollFor(dir);
        if (descriptor.closed or state.waiter != crb.Qnil) {
            return null;
        }

        state.waiter = fiber;
        self.active_waiters += 1;
        if (dir == .read) {
            if (timeout) |seconds| {
                if (seconds >= 0.0 and std.math.isFinite(seconds)) {
                    descriptor.read_timeout_token = try self.scheduleTimer(.resume_fiber, fiber, Value.from(false).toRaw(), seconds, descriptor);
                }
            }
        }
        try self.armPoll(descriptor, dir);

        self.blocked_fibers.put(self.allocator, fiber, 0) catch
            Error.raiseRuntimeError("Failed to track blocked fiber");
        const result = self.doTransferToLoop(fiber);
        _ = self.blocked_fibers.remove(fiber);

        if (dir == .read) descriptor.cancelReadTimeout();
        if (state.waiter == fiber) {
            state.waiter = crb.Qnil;
            if (self.active_waiters > 0) self.active_waiters -= 1;
        }
        // Poll completion resumes with the event mask (truthy integer).
        // Timeout / external resume (Async timer) transfers nil → not ready.
        // Poll error resumes with false → not ready.
        const raw = result.toRaw();
        return raw != crb.Qfalse and raw != crb.Qnil;
    }

    fn ioRead(self: *Self, fd: std.posix.fd_t, buffer: Value, length: usize, offset: usize) !Value {
        // Extract buffer pointer once: reused by both fast path and uring slow path
        var base: ?*anyopaque = null;
        var size: usize = 0;
        support.rb_io_buffer_get_bytes_for_writing(buffer.toRaw(), &base, &size);

        if (offset > size) return Value.from(@as(i64, -@as(isize, @intFromEnum(std.posix.E.INVAL))));
        const available = size - offset;
        if (available == 0) return Value.from(@as(i64, 0));
        const read_len = if (length == 0) available else @min(available, length);
        const ptr: [*]u8 = @ptrCast(base.?);

        // Fast path: try userspace recv, then drain kernel buffer.
        // Skip the probe after PROBE_SKIP_THRESHOLD consecutive EAGAIN
        // misses on this fd slot — request/response workloads (http*)
        // always miss before the kernel delivers the response,
        // saving a syscall per read on the hot path.
        const probe_idx = @as(usize, @intCast(fd)) & 0xFF;
        if (self.probe_misses[probe_idx] < PROBE_SKIP_THRESHOLD) {
            const rc = io.recvOnce(fd, (ptr + offset)[0..read_len]);
            if (rc > 0) {
                // Only reset on burst (>= 16 KiB) — matches the
                // slow-path logic.
                // Small hits (UDS request/response like db_query_mix,
                // or small HTTP responses) leave the counter intact so it
                // can saturate and let subsequent iterations skip
                // the probe entirely.
                if (rc >= 16 * 1024) {
                    self.probe_misses[probe_idx] = 0;
                }
                // Skip drainRecv for readpartial semantics (length == 0).  The
                // caller only wants whatever's immediately available; probing
                // for more data wastes a recvfrom EAGAIN when the kernel buffer
                // is empty (typical on UDS request/response pairs and small
                // HTTP responses).
                if (length == 0) {
                    return Value.from(@as(i64, @intCast(rc)));
                }
                return Value.from(@as(i64, @intCast(io.drainRecv(fd, ptr + offset, read_len, @intCast(rc)))));
            }
            if (rc == 0) return Value.from(@as(i64, 0));
            if (!io.wouldBlockErrno(-rc)) {
                // Non-socket fd (pipe, file): try read(2) instead of recv
                if (io.isEnotsock(-rc)) {
                    const rrc = io.readOnce(fd, (ptr + offset)[0..read_len]);
                    if (rrc > 0) return Value.from(@as(i64, rrc));
                    if (rrc == 0) return Value.from(@as(i64, 0));
                    // EAGAIN on pipe: need to wait, fall back to Ruby
                    return Value.nil;
                }
                return Value.from(@as(i64, rc));
            }
            self.probe_misses[probe_idx] +|= 1;
        }

        // Slow path: need to wait: get current fiber
        const fiber = support.rb_fiber_current();
        if (comptime xev.backend == .io_uring) {
            const uring_result = try self.ioRecvUring(fd, (ptr + offset)[0..read_len], fiber);
            if (uring_result.toRaw() == crb.Qnil) return uring_result;
            const n = uring_result.toInt(isize) catch return uring_result;
            if (n <= 0) return uring_result;
            // Only reset `probe_misses` if we received a burst—more data may be
            // sitting in the kernel buffer, so the next call's probe is
            // likely to hit the fast path. For small request/response packets
            // (http_server response = 77 bytes, http_client_api
            // header = ~300 bytes) leave the counter saturated so
            // subsequent calls skip the probe and save one
            // `recvfrom` EAGAIN per iteration.  Threshold chosen so tcp_echo's
            // 512-byte payloads and small HTTP responses stay saturated while
            // streaming downloads reset on every 16 KiB chunk.
            if (n >= 16 * 1024) {
                self.probe_misses[probe_idx] = 0;
            }
            // Skip drainRecv for readpartial semantics (length == 0) — every
            // drain probe on a freshly-delivered localhost response returns
            // EAGAIN and costs one syscall per read.  For sized reads
            // (length > 0) we still drain to fill the caller's buffer.
            if (length == 0) {
                return Value.from(@as(i64, @intCast(n)));
            }
            return Value.from(@as(i64, @intCast(io.drainRecv(fd, ptr + offset, read_len, @intCast(n)))));
        } else {
            return self.ioReadPoll(fd, ptr + offset, read_len, fiber);
        }
    }

    fn ioReadPoll(self: *Self, fd: std.posix.fd_t, buf: [*]u8, read_len: usize, fiber: crb.VALUE) !Value {
        // Note: reads MUST return after first successful recv (with drain).
        // Looping to fill the buffer would deadlock readpartial—the sender
        // may not produce more data until we process what we already received.
        while (true) {
            const wait_ready = try self.waitForPoll(fiber, fd, .read, null);
            if (wait_ready == null) return Value.nil;
            if (!wait_ready.?) return Value.from(@as(i64, -@as(isize, @intFromEnum(std.posix.E.AGAIN))));

            const rc = io.recvOnce(fd, buf[0..read_len]);
            if (rc > 0) return Value.from(@as(i64, @intCast(io.drainRecv(fd, buf, read_len, @intCast(rc)))));
            if (rc == 0) {
                return Value.from(@as(i64, 0));
            }
            if (!io.wouldBlockErrno(-rc)) return Value.from(@as(i64, rc));
        }
    }

    fn ioRecvUring(self: *Self, fd: std.posix.fd_t, buf_slice: []u8, fiber: crb.VALUE) !Value {
        const descriptor = try self.ensureDescriptor(fd);
        const state = descriptor.pollFor(.read);
        if (descriptor.closed or state.waiter != crb.Qnil) return Value.nil;

        state.waiter = fiber;
        self.active_waiters += 1;

        state.completion = .{
            .op = .{ .recv = .{
                .fd = descriptor.fd,
                .buffer = .{ .slice = buf_slice },
            } },
            .userdata = descriptor,
            .callback = ioRecvCallback,
        };
        self.loop.add(&state.completion);
        state.armed = true;

        self.blocked_fibers.put(self.allocator, fiber, 0) catch
            Error.raiseRuntimeError("Failed to track blocked fiber");
        const transfer_result = self.doTransferToLoop(fiber);
        _ = self.blocked_fibers.remove(fiber);

        if (state.waiter == fiber) {
            state.waiter = crb.Qnil;
            if (self.active_waiters > 0) self.active_waiters -= 1;
            return Value.nil;
        }
        return transfer_result;
    }

    fn ioWrite(self: *Self, fd: std.posix.fd_t, buffer: Value, length: usize, offset: usize) !Value {
        // Extract buffer pointer once for send + drain
        var base: ?*const anyopaque = null;
        var size: usize = 0;
        support.rb_io_buffer_get_bytes_for_reading(buffer.toRaw(), &base, &size);

        if (offset > size) return Value.from(@as(i64, -@as(isize, @intFromEnum(std.posix.E.INVAL))));
        const available = size - offset;
        if (available == 0) return Value.from(@as(i64, 0));
        const write_len = if (length == 0) available else @min(available, length);
        const ptr: [*]const u8 = @ptrCast(base.?);
        const buf = (ptr + offset)[0..write_len];

        // Fast path: try non-blocking send + drain
        var total_sent: usize = 0;
        var rc = io.sendOnce(fd, buf);
        if (rc > 0) {
            total_sent = io.drainSend(fd, buf.ptr, write_len, @intCast(rc));
            if (total_sent >= write_len) {
                return Value.from(@as(i64, @intCast(total_sent)));
            }
        } else if (rc == 0) {
            return Value.from(@as(i64, 0));
        } else if (!io.wouldBlockErrno(-rc)) {
            // Non-socket fd (pipe, file): try write(2) instead of send
            if (io.isEnotsock(-rc)) {
                const wrc = io.writeOnce(fd, buf);
                if (wrc > 0) return Value.from(@as(i64, wrc));
                if (wrc == 0) return Value.from(@as(i64, 0));
                return Value.nil;
            }
            return Value.from(@as(i64, rc));
        }

        // Slow path: wait for writability, then send+drain until complete
        const fiber = support.rb_fiber_current();
        while (total_sent < write_len) {
            const wait_ready = try self.waitForPoll(fiber, fd, .write, null);
            if (wait_ready == null) {
                // Native write polling unsupported (e.g., kqueue fallback).
                // If nothing was sent, return nil so Ruby
                // retries via background op.
                if (total_sent == 0) return Value.nil;
                break;
            }
            if (!wait_ready.?) break;

            rc = io.sendOnce(fd, buf[total_sent..]);
            if (rc <= 0) break;
            total_sent = io.drainSend(fd, buf.ptr, write_len, total_sent + @as(usize, @intCast(rc)));
        }

        if (total_sent > 0) {
            return Value.from(@as(i64, @intCast(total_sent)));
        }
        // Nothing sent at all—return error from last sendOnce
        if (rc == 0) return Value.from(@as(i64, 0));
        return Value.from(@as(i64, rc));
    }

    fn processWait(self: *Self, fiber: crb.VALUE, pid: std.posix.pid_t, flags: c_int) !Value {
        const immediate = rb_process_status_wait(pid, flags | @as(c_int, @intCast(std.posix.W.NOHANG)));
        if (immediate != crb.Qnil) return Value.fromRaw(immediate);

        const watcher = xev.Process.init(pid) catch return Value.nil;
        const wait = try self.allocator.create(ProcessWait);
        errdefer self.allocator.destroy(wait);

        wait.* = .{
            .selector = self,
            .fiber = fiber,
            .pid = pid,
            .flags = flags,
            .watcher = watcher,
            .in_list = true,
        };

        try self.process_waits.append(self.allocator, wait);
        self.active_waiters += 1;
        wait.watcher.wait(&self.loop, &wait.completion, ProcessWait, wait, processWaitCallback);

        var call = ProcessWaitCall{
            .selector = self,
            .wait = wait,
        };
        const result = rb_ensure(processWaitTransfer, ptrToValue(&call), processWaitEnsure, ptrToValue(&call));
        return Value.fromRaw(result);
    }

    fn ioClose(self: *Self, fd: std.posix.fd_t, exception: crb.VALUE) !void {
        // Reset probe-miss counter so a recycled fd starts fresh.
        self.probe_misses[@as(usize, @intCast(fd)) & 0xFF] = 0;
        // Evict from descriptor cache so a recycled fd doesn't return a stale
        // pointer after the hashmap entry is removed.
        const fd_usize = @as(usize, @intCast(fd));
        if (fd_usize < DESCRIPTOR_CACHE_SIZE) {
            self.descriptor_cache[fd_usize] = null;
        }
        const removed = self.descriptors.fetchRemove(fd) orelse return;
        const descriptor = removed.value;
        descriptor.in_map = false;
        descriptor.closed = true;
        descriptor.cancelReadTimeout();

        var woke = false;
        inline for ([_]Direction{ .read, .write }) |dir| {
            const state = descriptor.pollFor(dir);
            if (state.waiter != crb.Qnil) {
                const fiber = state.waiter;
                state.waiter = crb.Qnil;
                if (self.active_waiters > 0) self.active_waiters -= 1;
                try self.enqueue(.raise, fiber, exception);
                woke = true;
            }
        }

        if (descriptor.anyPollArmed()) {
            try self.retired_descriptors.append(self.allocator, descriptor);
        } else {
            self.allocator.destroy(descriptor);
        }

        if (woke) {
            self.async_handle.notify() catch {};
        }
    }

    fn enqueue(self: *Self, kind: ReadyKind, fiber: crb.VALUE, payload: crb.VALUE) !void {
        try self.ready_entries.append(self.allocator, .{ .kind = kind, .fiber = fiber, .payload = payload });
    }

    // Called from non-scheduler threads (e.g. Scheduler#unblock,
    // Scheduler#resume).
    // Uses a mutex-protected list plus an atomic flag.
    // The flag lets drainCrossThread skip the mutex entirely on the
    // hot path when nothing is pending.
    fn enqueueCrossThread(self: *Self, entry: ReadyEntry) !void {
        self.cross_thread_mutex.lock();
        defer self.cross_thread_mutex.unlock();
        try self.cross_thread_entries.append(self.allocator, entry);
        self.cross_thread_pending.store(true, .release);
    }

    fn drainCrossThread(self: *Self) void {
        if (!self.cross_thread_pending.load(.acquire)) return;
        self.cross_thread_mutex.lock();
        defer self.cross_thread_mutex.unlock();
        for (self.cross_thread_entries.items) |entry| {
            self.ready_entries.append(self.allocator, entry) catch {};
        }
        self.cross_thread_entries.clearRetainingCapacity();
        self.cross_thread_pending.store(false, .release);
    }

    fn scheduleTimer(self: *Self, kind: ReadyKind, fiber: crb.VALUE, payload: crb.VALUE, duration: f64, descriptor: ?*Descriptor) !u64 {
        const deadline = support.monotonicSeconds() + duration;
        return self.timers.schedule(deadline, .{
            .kind = kind,
            .fiber = fiber,
            .payload = payload,
            .descriptor = @ptrCast(descriptor),
        });
    }

    fn doTransferToLoop(self: *Self, current: crb.VALUE) Value {
        if (current == self.loop_fiber) return Value.nil;

        // Chain directly to the next ready fiber, avoiding root round-trip.
        // Only chain resume entries; stop at raise entries or self-references.
        // Cross-thread entries are drained in flushReady, not here—avoids
        // a mutex check on every fiber transfer in single-threaded workloads.
        while (self.ready_head < self.ready_entries.items.len) {
            const entry = self.ready_entries.items[self.ready_head];
            if (entry.kind != .resume_fiber) break;
            if (entry.fiber == current) break;

            self.ready_head += 1;

            if (!support.fiberAlive(entry.fiber)) continue;

            var argv = [_]crb.VALUE{entry.payload};
            return Value.fromRaw(support.rb_fiber_transfer(entry.fiber, 1, &argv));
        }

        // No ready fiber found from prior processing. On io_uring, peek at the
        // CQ before handing off to loop_fiber: on loopback, sendOnce delivers
        // data to the kernel synchronously so the peer's RECV CQE often lands
        // in the ring by the time we reach here. If we find one we can chain
        // without a loop_fiber round-trip. Only fires when we'd go
        // to loop_fiber anyway, so cost is bounded to one extra
        // io_uring_enter per unavoidable loop_fiber trip—not one per
        // every fiber park.
        // Gated on active_waiters > 0: pure-task workloads (no I/O) never have
        // pending completions so the syscall would always be wasted.
        if (comptime xev.backend == .io_uring) {
            if (self.active_waiters > 0) {
                self.loop.run(.no_wait) catch {};
                while (self.ready_head < self.ready_entries.items.len) {
                    const entry = self.ready_entries.items[self.ready_head];
                    if (entry.kind != .resume_fiber) break;
                    if (entry.fiber == current) break;
                    self.ready_head += 1;
                    if (!support.fiberAlive(entry.fiber)) continue;
                    var argv = [_]crb.VALUE{entry.payload};
                    return Value.fromRaw(support.rb_fiber_transfer(entry.fiber, 1, &argv));
                }
            }
        }

        return Value.fromRaw(support.rb_fiber_transfer(self.loop_fiber, 0, null));
    }

    fn doSelect(self: *Self, timeout: ?f64) !i64 {
        self.collectRetiredDescriptors();
        self.collectRetiredProcessWaits();
        if (self.timers.pending()) self.collectExpiredTimers();
        var flushed = self.flushReady();

        // Fast path: return immediately when we dispatched fibers, unless
        // deferred entries remain (from the batch snapshot) and there are
        // active I/O waiters that need polling to make progress. Without
        // active waiters, deferred entries are picked up next round.
        if (flushed > 0 and
            (self.ready_entries.items.len == 0 or self.active_waiters == 0))
            return @intCast(flushed);

        // Phase 1: poll xev and re-poll after flushes to catch
        // back-to-back IO (GVL held)
        if (self.active_waiters > 0) {
            var total_flushed: usize = 0;
            var spins: usize = 0;
            while (spins < 4) : (spins += 1) {
                self.loop.run(.no_wait) catch {};
                if (self.timers.pending()) self.collectExpiredTimers();
                flushed = self.flushReady();
                total_flushed += flushed;
                if (flushed == 0) break;
            }
            if (total_flushed > 0) return @intCast(total_flushed);
        }

        // Phase 2: blocking wait with GVL released
        const deadline = self.computeDeadline(timeout);

        // Near-deadline spin: avoid GVL release/reacquire cost when
        // timer is <3ms away
        if (deadline) |d| {
            const now = support.monotonicSeconds();
            if (d - now <= SPIN_THRESHOLD and self.active_waiters == 0) {
                support.busySpinUntil(d);
                self.collectExpiredTimers();
                flushed = self.flushReady();
                if (flushed > 0) return @intCast(flushed);
                // Deadline is past and no native timers remain—skip
                // the GVL round-trip.
                // The caller (e.g. Async) manages its own timer heap
                // and just needs us to return so it can fire its timers.
                // Avoids a redundant 0ms io_uring op.
                if (!self.timers.pending()) return 0;
            }
        }

        self.deadline_fired = false;
        self.armDeadlineTimer(deadline);
        self.blocked.store(true, .release);
        _ = support.rb_thread_call_without_gvl(waitWithoutGVL, self, waitUnblock, self);
        self.blocked.store(false, .release);

        self.collectExpiredTimers();
        flushed = self.flushReady();
        return @intCast(flushed);
    }

    fn computeDeadline(self: *Self, timeout: ?f64) ?f64 {
        const timer_dl = self.timers.nextDeadline();
        const timeout_dl: ?f64 = if (timeout) |s| support.monotonicSeconds() + @max(s, 0.0) else null;

        if (timer_dl) |t| {
            return if (timeout_dl) |u| @min(t, u) else t;
        }
        return timeout_dl;
    }

    fn armDeadlineTimer(self: *Self, deadline: ?f64) void {
        if (deadline) |d| {
            const now = support.monotonicSeconds();
            const remaining = d - now;
            const ms: u64 = if (remaining <= 0) 0 else @intFromFloat(remaining * 1000.0);

            self.deadline_timer.reset(
                &self.loop,
                &self.deadline_completion,
                &self.deadline_cancel_completion,
                ms,
                Self,
                self,
                deadlineTimerCallback,
            );
        }
    }

    fn collectExpiredTimers(self: *Self) void {
        const now = support.monotonicSeconds();
        while (self.timers.popExpired(now)) |action| {
            if (action.descriptor) |desc_ptr| {
                const descriptor: *Descriptor = @ptrCast(@alignCast(desc_ptr));
                const state = descriptor.pollFor(.read);
                if (state.waiter != action.fiber) continue;
                state.waiter = crb.Qnil;
                descriptor.read_timeout_token = null;
                if (self.active_waiters > 0) self.active_waiters -= 1;
            }
            self.enqueue(action.kind, action.fiber, action.payload) catch {};
        }
    }

    fn flushReady(self: *Self) usize {
        self.drainCrossThread();
        var dispatched: usize = 0;

        // Snapshot the batch boundary: only process entries that existed
        // before we started dispatching. Fibers transferred to during this
        // flush may enqueue *new* entries (via yield, push, or Async's
        // unblock); those land beyond batch_end and are preserved for the
        // next flushReady call. Without this snapshot the loop never
        // terminates when fibers re-enqueue, causing a hang + memory leak.
        const batch_end = self.ready_entries.items.len;

        while (self.ready_head < batch_end) {
            const entry = self.ready_entries.items[self.ready_head];
            self.ready_head += 1;

            if (!support.fiberAlive(entry.fiber)) continue;

            var argv = [_]crb.VALUE{entry.payload};
            switch (entry.kind) {
                .resume_fiber => {
                    _ = support.rb_fiber_transfer(entry.fiber, 1, &argv);
                    // In Ruby 4.0, calling Fiber#raise on a third fiber from
                    // within entry.fiber causes control to return here instead
                    // of back to entry.fiber. entry.fiber is still alive but
                    // suspended at the Fiber#raise call site. If it is not
                    // registered as voluntarily parked, re-queue it so it can
                    // complete normally. Also handles fibers that used
                    // transfer() (not yield()) and need to be re-enqueued to
                    // resume execution.
                    // Re-enqueue if the fiber is still running and did not
                    // voluntarily park itself (blocked_fibers entry means it
                    // called block() and is waiting for an event).
                    //
                    // Fast path 1: map empty (task_churn / pure-task
                    // workloads)—skip contains(), just check alive.
                    // Fast path 2: fiber IS in the map → it re-blocked itself,
                    // so it is guaranteed alive and does NOT need re-enqueuing.
                    // Skips the rb_fiber_alive_p() C call entirely.
                    if (self.blocked_fibers.count() == 0) {
                        if (support.fiberAlive(entry.fiber)) {
                            self.enqueue(.resume_fiber, entry.fiber, crb.Qnil) catch {};
                        }
                    } else if (!self.blocked_fibers.contains(entry.fiber)) {
                        if (support.fiberAlive(entry.fiber)) {
                            self.enqueue(.resume_fiber, entry.fiber, crb.Qnil) catch {};
                        }
                    }
                },
                .raise => {
                    _ = support.rb_fiber_raise(entry.fiber, 1, &argv);
                },
            }

            dispatched += 1;
        }

        // Compact: preserve only entries that were NOT consumed.
        // ready_head may have advanced past batch_end via the chain
        // optimization in doTransferToLoop, so use ready_head (the true
        // consumption frontier) as the compact source—not batch_end.
        const tail = self.ready_entries.items.len - self.ready_head;
        if (tail > 0) {
            std.mem.copyForwards(
                ReadyEntry,
                self.ready_entries.items[0..tail],
                self.ready_entries.items[self.ready_head..self.ready_entries.items.len],
            );
            self.ready_entries.shrinkRetainingCapacity(tail);
        } else {
            self.ready_entries.clearRetainingCapacity();
        }
        self.ready_head = 0;

        return dispatched;
    }

    fn ensureDescriptor(self: *Self, fd: std.posix.fd_t) !*Descriptor {
        // Fast path: small fd lookup via direct array index.
        const fd_usize = @as(usize, @intCast(fd));
        if (fd_usize < DESCRIPTOR_CACHE_SIZE) {
            if (self.descriptor_cache[fd_usize]) |cached| return cached;
        }

        const result = try self.descriptors.getOrPut(self.allocator, fd);
        if (!result.found_existing) {
            const descriptor = try self.allocator.create(Descriptor);
            descriptor.* = .{
                .selector = self,
                .fd = fd,
                .in_map = true,
            };
            result.value_ptr.* = descriptor;
        }

        const descriptor = result.value_ptr.*;
        if (fd_usize < DESCRIPTOR_CACHE_SIZE) {
            self.descriptor_cache[fd_usize] = descriptor;
        }
        return descriptor;
    }

    fn armPoll(self: *Self, descriptor: *Descriptor, comptime dir: Direction) !void {
        const state = descriptor.pollFor(dir);
        if (state.armed) return;

        // Match io-event's URing backend flags: include POLLHUP|POLLERR so
        // we wake on half-close / error events even if no data is available.
        // Necessary on streams where the peer closes mid-response.
        const read_flags: i16 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        const write_flags: i16 = std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR;

        state.completion = .{
            .op = switch (comptime xev.backend) {
                .io_uring => .{ .poll = .{
                    .fd = descriptor.fd,
                    .events = if (dir == .read) read_flags else write_flags,
                } },
                .kqueue => if (dir == .read)
                    .{ .read = .{ .fd = descriptor.fd, .buffer = .{ .slice = &.{} } } }
                else
                    .{ .write = .{ .fd = descriptor.fd, .buffer = .{ .slice = &.{} } } },
                else => @compileError("poll waits are not supported on this backend"),
            },
            .userdata = descriptor,
            .callback = pollRawCallback,
        };

        self.loop.add(&state.completion);
        state.armed = true;
    }

    fn cleanupProcessWait(self: *Self, wait: *ProcessWait) void {
        self.removeProcessWait(wait);
        if (wait.fiber != crb.Qnil) {
            wait.fiber = crb.Qnil;
            if (self.active_waiters > 0) self.active_waiters -= 1;
        }

        if (wait.completion.state() == .dead and self.processWaitCancelSettled(wait)) {
            wait.watcher.deinit();
            self.allocator.destroy(wait);
            return;
        }

        wait.cancelled = true;
        self.cancelProcessWait(wait);
        self.retired_process_waits.append(self.allocator, wait) catch {};
    }

    fn cancelProcessWait(self: *Self, wait: *ProcessWait) void {
        switch (comptime xev.backend) {
            .io_uring => {
                if (wait.cancel_pending or wait.completion.state() != .active) return;
                wait.cancel_pending = true;
                self.loop.cancel(&wait.completion, &wait.cancel_completion, ProcessWait, wait, processWaitCancelCallback);
            },
            .epoll => {
                if (wait.completion.state() == .active) {
                    self.loop.delete(&wait.completion);
                }
            },
            .kqueue => {
                if (wait.completion.state() != .active) return;
            },
            else => {},
        }
    }

    fn collectRetiredDescriptors(self: *Self) void {
        if (self.retired_descriptors.items.len == 0) return;
        var index: usize = 0;
        while (index < self.retired_descriptors.items.len) {
            const descriptor = self.retired_descriptors.items[index];
            if (descriptor.anyPollArmed()) {
                index += 1;
                continue;
            }
            self.allocator.destroy(descriptor);
            _ = self.retired_descriptors.swapRemove(index);
        }
    }

    fn collectRetiredProcessWaits(self: *Self) void {
        if (self.retired_process_waits.items.len == 0) return;
        var index: usize = 0;
        while (index < self.retired_process_waits.items.len) {
            const wait = self.retired_process_waits.items[index];
            const cancel_dead = self.processWaitCancelSettled(wait);
            if (wait.completion.state() != .dead or !cancel_dead) {
                index += 1;
                continue;
            }
            wait.watcher.deinit();
            self.allocator.destroy(wait);
            _ = self.retired_process_waits.swapRemove(index);
        }
    }

    fn removeProcessWait(self: *Self, wait: *ProcessWait) void {
        if (!wait.in_list) return;

        for (self.process_waits.items, 0..) |item, index| {
            if (item != wait) continue;
            _ = self.process_waits.swapRemove(index);
            wait.in_list = false;
            return;
        }
    }

    fn processWaitCancelSettled(_: *Self, wait: *ProcessWait) bool {
        return switch (comptime xev.backend) {
            .io_uring => wait.cancel_completion.state() == .dead,
            else => true,
        };
    }

};


const GcMode = enum { mark, compact };

/// Walk all GC-visible VALUE slots. Mark mode pins values in place;
/// compact mode updates moved references. Comptime dispatch eliminates
/// the duplication between selectorMark and selectorCompact.
fn gcWalkValues(self: *Selector, comptime mode: GcMode) void {
    const visit = struct {
        inline fn v(ptr: *crb.VALUE) void {
            if (mode == .compact) {
                ptr.* = support.compactValue(ptr.*);
            } else {
                support.markValue(ptr.*);
            }
        }
    }.v;

    visit(&self.loop_fiber);
    visit(&self.scheduler_thread);

    for (self.ready_entries.items) |*entry| {
        visit(&entry.fiber);
        visit(&entry.payload);
    }

    {
        self.cross_thread_mutex.lock();
        defer self.cross_thread_mutex.unlock();
        for (self.cross_thread_entries.items) |*entry| {
            visit(&entry.fiber);
            visit(&entry.payload);
        }
    }

    if (mode == .compact) self.timers.compact() else self.timers.mark();

    var it = self.descriptors.iterator();
    while (it.next()) |entry| {
        const descriptor = entry.value_ptr.*;
        for (&descriptor.poll) |*state| visit(&state.waiter);
    }

    for (self.process_waits.items) |wait| visit(&wait.fiber);

    for (self.retired_descriptors.items) |descriptor| {
        for (&descriptor.poll) |*state| visit(&state.waiter);
    }

    for (self.retired_process_waits.items) |wait| visit(&wait.fiber);
}

fn selectorMark(data: ?*anyopaque) callconv(.c) void {
    const self: *Selector = @ptrCast(@alignCast(data.?));
    gcWalkValues(self, .mark);
}

fn selectorCompact(data: ?*anyopaque) callconv(.c) void {
    const self: *Selector = @ptrCast(@alignCast(data.?));
    gcWalkValues(self, .compact);
}

fn selectorFree(data: ?*anyopaque) callconv(.c) void {
    const self: *Selector = @ptrCast(@alignCast(data.?));
    self.release();
    std.heap.c_allocator.destroy(self);
}


fn asyncCallback(
    _: ?*Selector,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Async.WaitError!void,
) xev.CallbackAction {
    return .rearm;
}

fn deadlineTimerCallback(
    self_maybe: ?*Selector,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Timer.RunError!void,
) xev.CallbackAction {
    if (self_maybe) |self| self.deadline_fired = true;
    return .disarm;
}

// Unified poll completion handler for both read and write directions.
// Direction is determined from which completion object was triggered.
fn completePoll(descriptor: ?*Descriptor, completion: *xev.Completion, ok: bool) xev.CallbackAction {
    const desc = descriptor orelse return .disarm;
    const self = desc.selector;

    // Determine direction from which completion was used
    const dir: Direction = if (completion == &desc.poll[0].completion) .read else .write;
    const state = &desc.poll[@intFromEnum(dir)];
    state.armed = false;

    if (dir == .read) desc.cancelReadTimeout();

    if (state.waiter != crb.Qnil) {
        const fiber = state.waiter;
        state.waiter = crb.Qnil;
        if (self.active_waiters > 0) self.active_waiters -= 1;
        const event: i16 = if (dir == .read) READABLE else WRITABLE;
        const payload = if (ok) Value.from(@as(i64, event)).toRaw() else Value.from(false).toRaw();
        self.enqueue(.resume_fiber, fiber, payload) catch {};
    }

    if (comptime xev.backend == .kqueue) {
        const filter: i16 = if (dir == .read) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
        var kev: [1]std.c.kevent64_s = .{.{
            .ident = @as(u64, @intCast(desc.fd)),
            .filter = filter,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
            .ext = .{ 0, 0 },
        }};
        _ = std.c.kevent64(self.loop.kqueue_fd, &kev, 1, &kev, 0, 0, null);
    }

    return .disarm;
}

fn pollRawCallback(
    descriptor_raw: ?*anyopaque,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Result,
) xev.CallbackAction {
    const descriptor: ?*Descriptor = if (descriptor_raw) |raw|
        @ptrCast(@alignCast(raw))
    else
        null;
    // Wake the fiber as "ready" for ANY result—success, EOF, or error.
    //
    // For io_uring/epoll the poll op only signals "ready" / "error" and
    // both cases need the fiber to retry the recv/send to surface the real
    // kernel state. For kqueue we use a zero-length `.read` / `.write`
    // op as a poll proxy, and libxev maps n == 0 (peer-closed FD) to
    // `error.EOF`. That is NOT a "not ready" signal—it means the FD IS
    // ready to be read (the next recv will return 0 = EOF). Treating EOF
    // as `ok = false` makes the fiber's `ioReadPoll` loop return EAGAIN →
    // Ruby retries `io_read` → we re-arm the poll → EOF fires again — an
    // infinite retry that shows up as a 100 % CPU hang when a client
    // fiber waits for a response after the server already closed.
    return completePoll(descriptor, completion, true);
}

fn ioRecvCallback(
    descriptor_raw: ?*anyopaque,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    const desc: *Descriptor = if (descriptor_raw) |raw| @ptrCast(@alignCast(raw)) else return .disarm;
    const self = desc.selector;
    const state = &desc.poll[@intFromEnum(Direction.read)];
    state.armed = false;

    // Convert result to isize: positive = bytes read, 0 = EOF, negative = errno
    const io_result: isize = if (result.recv) |n| @intCast(n) else |err| switch (err) {
        error.EOF => 0,
        error.ConnectionResetByPeer => -@as(isize, @intFromEnum(std.posix.E.CONNRESET)),
        error.Canceled => -@as(isize, @intFromEnum(std.posix.E.CANCELED)),
        error.Unexpected => -@as(isize, @intFromEnum(std.posix.E.IO)),
    };

    if (state.waiter != crb.Qnil) {
        const fiber = state.waiter;
        state.waiter = crb.Qnil;
        if (self.active_waiters > 0) self.active_waiters -= 1;
        // Pass io_result as a Ruby Fixnum through the fiber transfer payload
        self.enqueue(.resume_fiber, fiber, Value.from(@as(i64, io_result)).toRaw()) catch {};
    }

    return .disarm;
}

fn processWaitCallback(
    wait: ?*ProcessWait,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const process_wait = wait orelse return .disarm;
    process_wait.ready = if (result) |_| true else |_| false;

    if (process_wait.fiber != crb.Qnil and !process_wait.cancelled) {
        const fiber = process_wait.fiber;
        process_wait.fiber = crb.Qnil;
        if (process_wait.selector.active_waiters > 0) process_wait.selector.active_waiters -= 1;
        process_wait.selector.enqueue(.resume_fiber, fiber, Value.from(true).toRaw()) catch {};
    }

    return .disarm;
}

fn processWaitCancelCallback(
    wait: ?*ProcessWait,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.CancelError!void,
) xev.CallbackAction {
    if (wait) |process_wait| {
        process_wait.cancel_pending = false;
    }
    return .disarm;
}

fn waitWithoutGVL(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Selector = @ptrCast(@alignCast(data.?));
    while (true) {
        self.loop.run(.once) catch {};
        // Return when there is genuine work: a cross-thread entry
        // (background op completed, or unblock called with real work),
        // IO events queued in the ready list by a poll callback, or
        // the deadline timer firing.
        // Spurious wakeups from GC preemption (waitUnblock → notify) leave all
        // three false, so we re-block rather than thrashing through the
        // GVL acquire/release cycle of rb_thread_call_without_gvl.
        if (self.cross_thread_pending.load(.acquire)) return null;
        if (self.ready_head < self.ready_entries.items.len) return null;
        if (self.deadline_fired) return null;
    }
}

fn waitUnblock(data: ?*anyopaque) callconv(.c) void {
    const self: *Selector = @ptrCast(@alignCast(data.?));
    self.async_handle.notify() catch {};
}

fn floatFromValue(value: Value, fallback: ?f64) f64 {
    return value.toFloat(f64) catch fallback orelse Error.raiseArgumentError("expected numeric timeout");
}

fn integerFromValue(comptime T: type, value: Value, message: [:0]const u8) T {
    return value.toInt(T) catch Error.raiseArgumentError(message);
}

fn ptrToValue(ptr: anytype) crb.VALUE {
    return @as(crb.VALUE, @intCast(@intFromPtr(ptr)));
}

fn valueToPtr(comptime T: type, value: crb.VALUE) *T {
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn processWaitTransfer(raw: crb.VALUE) callconv(.c) crb.VALUE {
    const call = valueToPtr(ProcessWaitCall, raw);
    _ = call.selector.doTransferToLoop(support.rb_fiber_current());
    if (!call.wait.ready) return crb.Qfalse;

    const status = rb_process_status_wait(call.wait.pid, call.wait.flags | @as(c_int, @intCast(std.posix.W.NOHANG)));
    return if (status == crb.Qnil) crb.Qfalse else status;
}

fn processWaitEnsure(raw: crb.VALUE) callconv(.c) crb.VALUE {
    const call = valueToPtr(ProcessWaitCall, raw);
    call.selector.cleanupProcessWait(call.wait);
    return crb.Qnil;
}
