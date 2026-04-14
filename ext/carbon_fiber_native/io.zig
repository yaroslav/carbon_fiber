//! Low-level non-blocking I/O helpers used by the selector's fast path.
//! All functions operate directly on file descriptors without
//! touching the event loop.

// Please note that Zig code is heavily AI-assisted.

const std = @import("std");

/// Non-blocking recv on a pre-computed buffer slice. Returns
/// bytes read (≥0) or negated errno.
/// Used by ioRead's fast path to avoid fiber lookup when data is
/// already available.
pub fn recvOnce(fd: std.posix.fd_t, buf: []u8) isize {
    while (true) {
        const rc = std.c.recv(fd, @ptrCast(buf.ptr), buf.len, std.posix.MSG.DONTWAIT);
        if (rc >= 0) return @intCast(rc);
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return -@as(isize, @intCast(@intFromEnum(err)));
    }
}

/// Non-blocking send on a pre-computed buffer slice. Returns
/// bytes written (≥0) or negated errno.
pub fn sendOnce(fd: std.posix.fd_t, buf: []const u8) isize {
    while (true) {
        const rc = std.c.send(fd, @ptrCast(buf.ptr), buf.len, std.posix.MSG.DONTWAIT);
        if (rc >= 0) return @intCast(rc);
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return -@as(isize, @intCast(@intFromEnum(err)));
    }
}

/// After an initial recv returned `initial` bytes, try to fill the
/// rest of the buffer without blocking. Returns total bytes read
/// (always >= initial).
pub fn drainRecv(fd: std.posix.fd_t, buf: [*]u8, total_len: usize, initial: usize) usize {
    var got = initial;
    while (got < total_len) {
        const rc = recvOnce(fd, (buf + got)[0 .. total_len - got]);
        if (rc <= 0) break;
        got += @intCast(rc);
    }
    return got;
}

/// After an initial send returned `initial` bytes, try to push the
/// rest of the buffer without blocking. Returns total
/// bytes written (always >= initial).
pub fn drainSend(fd: std.posix.fd_t, buf: [*]const u8, total_len: usize, initial: usize) usize {
    var sent = initial;
    while (sent < total_len) {
        const rc = sendOnce(fd, (buf + sent)[0 .. total_len - sent]);
        if (rc <= 0) break;
        sent += @intCast(rc);
    }
    return sent;
}

/// Returns true if the negated errno indicates the operation would block.
/// Checks both EAGAIN and EWOULDBLOCK (which are the same on Linux but
/// are distinct constants on some other platforms).
pub fn wouldBlockErrno(errno_value: isize) bool {
    const again = @intFromEnum(std.posix.E.AGAIN);
    const would_block = if (@hasField(std.posix.E, "WOULDBLOCK"))
        @intFromEnum(@field(std.posix.E, "WOULDBLOCK"))
    else
        again;
    return errno_value == again or errno_value == would_block;
}

pub fn isEnotsock(errno_value: isize) bool {
    return errno_value == @intFromEnum(std.posix.E.NOTSOCK);
}

/// Non-blocking read(2) for non-socket fds (pipes, files). Returns
/// bytes read or negated errno.
pub fn readOnce(fd: std.posix.fd_t, buf: []u8) isize {
    while (true) {
        const rc = std.c.read(fd, @ptrCast(buf.ptr), buf.len);
        if (rc >= 0) return @intCast(rc);
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return -@as(isize, @intCast(@intFromEnum(err)));
    }
}

/// Non-blocking write(2) for non-socket fds (pipes, files). Returns
/// bytes written or negated errno.
pub fn writeOnce(fd: std.posix.fd_t, buf: []const u8) isize {
    while (true) {
        const rc = std.c.write(fd, @ptrCast(buf.ptr), buf.len);
        if (rc >= 0) return @intCast(rc);
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return -@as(isize, @intCast(@intFromEnum(err)));
    }
}

/// Non-destructively checks whether `fd` has data available to read right now.
/// Uses MSG_PEEK so no bytes are consumed. Returns false on
/// any error (including ENOTSOCK: callers check this separately
///via isEnotsock before reaching here).
pub fn pollReadableNow(fd: i32) bool {
    while (true) {
        var byte: u8 = 0;
        const rc = std.c.recv(fd, @ptrCast(&byte), 1, std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT);
        if (rc >= 0) return true;
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return false;
    }
}
