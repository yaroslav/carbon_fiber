//! Min-heap timer queue for deadline-ordered fiber wakeups.
//!
//! Timers are keyed by a u64 token. Cancellation tombstones the action in the
//! hash map; stale heap entries (no matching action) are lazily discarded by
//! discardStale() before any peek or pop operation.

// Please note that Zig code is heavily AI-assisted.

const std = @import("std");
const rb = @import("rb");
const crb = rb.crb;
const support = @import("support.zig");

pub const ReadyKind = enum(u8) { resume_fiber, raise };

pub const TimerEntry = struct {
    deadline: f64,
    token: u64,
};

/// Action stored in the timer queue. `descriptor` is type-erased to
/// ?*anyopaque to avoid a circular dependency with selector.zig:
/// callers cast it back to *Descriptor when used.
pub const TimerAction = struct {
    kind: ReadyKind,
    fiber: crb.VALUE,
    payload: crb.VALUE = crb.Qnil,
    descriptor: ?*anyopaque = null,
};

pub const TimerQueue = struct {
    const Heap = std.PriorityQueue(TimerEntry, void, timerEntryCompare);

    allocator: std.mem.Allocator,
    entries: Heap,
    actions: std.AutoHashMapUnmanaged(u64, TimerAction) = .empty,
    next_token: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) TimerQueue {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *TimerQueue) void {
        self.entries.deinit(self.allocator);
        self.actions.deinit(self.allocator);
    }

    pub fn schedule(self: *TimerQueue, deadline: f64, action: TimerAction) !u64 {
        const token = self.next_token;
        self.next_token += 1;
        try self.actions.put(self.allocator, token, action);
        errdefer _ = self.actions.remove(token);
        try self.entries.push(self.allocator, .{ .deadline = deadline, .token = token });
        return token;
    }

    pub fn cancel(self: *TimerQueue, token: u64) bool {
        return self.actions.remove(token);
    }

    pub fn pending(self: *TimerQueue) bool {
        return self.actions.count() > 0;
    }

    pub fn nextDeadline(self: *TimerQueue) ?f64 {
        self.discardStale();
        if (self.entries.peek()) |entry| return entry.deadline;
        return null;
    }

    pub fn popExpired(self: *TimerQueue, now: f64) ?TimerAction {
        self.discardStale();

        while (self.entries.peek()) |entry| {
            if (entry.deadline > now) return null;

            _ = self.entries.pop();
            if (self.actions.fetchRemove(entry.token)) |removed| {
                return removed.value;
            }
        }

        return null;
    }

    pub fn mark(self: *TimerQueue) void {
        var it = self.actions.iterator();
        while (it.next()) |entry| {
            support.markValue(entry.value_ptr.fiber);
            support.markValue(entry.value_ptr.payload);
        }
    }

    fn discardStale(self: *TimerQueue) void {
        while (self.entries.peek()) |entry| {
            if (self.actions.contains(entry.token)) break;
            _ = self.entries.pop();
        }
    }
};

fn timerEntryCompare(_: void, left: TimerEntry, right: TimerEntry) std.math.Order {
    // Deadlines are always finite (scheduleTimer guards with isFinite),
    // so NaN is not a concern.
    const ord = std.math.order(left.deadline, right.deadline);
    if (ord != .eq) return ord;
    return std.math.order(left.token, right.token);
}
