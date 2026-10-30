//! Cross-platform UDP socket wrapper for mosh transport.
//!
//! Uses libc sockets directly for Android/iOS compatibility. Zig 0.17 removed
//! the std.posix socket wrappers in favor of std.Io.net, whose blocking model
//! does not fit the non-blocking pump loop in core.zig.

const std = @import("std");
const c = std.c;

pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ResolveFailed,
    SendFailed,
    ReceiveFailed,
    WouldBlock,
    NotOpen,
    AlreadyOpen,
};

fn setFdFlags(sock: c.fd_t) SocketError!void {
    const status = c.fcntl(sock, c.F.GETFL, @as(c_int, 0));
    if (status < 0) return SocketError.CreateFailed;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    if (c.fcntl(sock, c.F.SETFL, status | nonblock) < 0) return SocketError.CreateFailed;
    if (c.fcntl(sock, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return SocketError.CreateFailed;
}

pub const MoshSocket = struct {
    const Self = @This();

    fd: ?c.fd_t = null,
    remote_addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in),
    local_port: u16 = 0,

    pub fn init() Self {
        return .{};
    }

    /// Open a non-blocking UDP socket and optionally bind to `local_port`.
    /// If `local_port` is 0 the OS assigns an ephemeral port.
    pub fn open(self: *Self, local_port: u16) SocketError!void {
        if (self.fd != null) return SocketError.AlreadyOpen;

        const rc = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (rc < 0) return SocketError.CreateFailed;
        const sock: c.fd_t = rc;
        errdefer _ = c.close(sock);
        // Darwin's socket() rejects SOCK_NONBLOCK/SOCK_CLOEXEC, so set both
        // with fcntl, which works on every platform we target.
        try setFdFlags(sock);

        const addr: c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, local_port),
            .addr = 0, // INADDR_ANY
        };
        if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return SocketError.BindFailed;

        self.fd = sock;
        self.local_port = local_port;

        // Resolve actual bound port if ephemeral
        if (local_port == 0) {
            var bound_addr: c.sockaddr.in = undefined;
            var bound_len: c.socklen_t = @sizeOf(c.sockaddr.in);
            if (c.getsockname(sock, @ptrCast(&bound_addr), &bound_len) == 0) {
                self.local_port = std.mem.bigToNative(u16, bound_addr.port);
            }
        }
    }

    /// Set the remote endpoint address. Call before send/receive.
    pub fn setRemote(self: *Self, host: []const u8, port: u16) SocketError!void {
        const parsed = std.Io.net.Ip4Address.parse(host, port) catch return SocketError.ResolveFailed;
        self.remote_addr = .{
            .port = std.mem.nativeToBig(u16, port),
            // `bytes` is already in network order, as sin_addr expects.
            .addr = @bitCast(parsed.bytes),
        };
    }

    /// Send a datagram to the configured remote endpoint.
    pub fn send(self: *Self, data: []const u8) SocketError!void {
        const sock = self.fd orelse return SocketError.NotOpen;
        const rc = c.sendto(
            sock,
            data.ptr,
            data.len,
            0,
            @ptrCast(&self.remote_addr),
            @sizeOf(c.sockaddr.in),
        );
        if (rc < 0) return switch (c.errno(rc)) {
            .AGAIN => SocketError.WouldBlock,
            else => SocketError.SendFailed,
        };
    }

    /// Receive a datagram. Returns `null` if no data is available (non-blocking).
    pub fn receive(self: *Self, buf: []u8) SocketError!?usize {
        const sock = self.fd orelse return SocketError.NotOpen;
        const rc = c.recvfrom(sock, buf.ptr, buf.len, 0, null, null);
        if (rc < 0) return switch (c.errno(rc)) {
            .AGAIN => null,
            .CONNREFUSED => null, // ICMP port unreachable on some platforms
            else => SocketError.ReceiveFailed,
        };
        return @intCast(rc);
    }

    pub fn close(self: *Self) void {
        if (self.fd) |sock| {
            _ = c.close(sock);
            self.fd = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.* = .{
            .fd = null,
            .remote_addr = std.mem.zeroes(c.sockaddr.in),
            .local_port = 0,
        };
    }
};

test "open bind send receive roundtrip" {
    var server = MoshSocket.init();
    defer server.deinit();
    try server.open(0);
    const server_port = server.local_port;
    try std.testing.expect(server_port > 0);

    var client = MoshSocket.init();
    defer client.deinit();
    try client.open(0);

    try client.setRemote("127.0.0.1", server_port);
    try client.send("ping");

    var buf: [64]u8 = undefined;
    var received: ?usize = null;
    // Retry a few times because non-blocking recv may race with send.
    for (0..100) |_| {
        received = try server.receive(&buf);
        if (received != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(received != null);
    try std.testing.expectEqualStrings("ping", buf[0..received.?]);
}

test "nonblocking receive returns null when empty" {
    var sock = MoshSocket.init();
    defer sock.deinit();
    try sock.open(0);

    var buf: [64]u8 = undefined;
    const received = try sock.receive(&buf);
    try std.testing.expect(received == null);
}

test "send without open fails" {
    var sock = MoshSocket.init();
    defer sock.deinit();
    try sock.setRemote("127.0.0.1", 12345);
    try std.testing.expectError(SocketError.NotOpen, sock.send("x"));
}
