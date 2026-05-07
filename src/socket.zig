//! Cross-platform UDP socket wrapper for mosh transport.
//!
//! Uses POSIX sockets directly for Android/iOS compatibility.

const std = @import("std");

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

pub const MoshSocket = struct {
    const Self = @This();

    fd: ?std.posix.socket_t = null,
    remote_addr: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in),
    local_port: u16 = 0,

    pub fn init() Self {
        return .{};
    }

    /// Open a non-blocking UDP socket and optionally bind to `local_port`.
    /// If `local_port` is 0 the OS assigns an ephemeral port.
    pub fn open(self: *Self, local_port: u16) SocketError!void {
        if (self.fd != null) return SocketError.AlreadyOpen;

        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        ) catch return SocketError.CreateFailed;
        errdefer std.posix.close(sock);

        const addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, local_port),
            .addr = 0, // INADDR_ANY
        };
        std.posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) catch |err| {
            std.posix.close(sock);
            return switch (err) {
                error.AddressInUse => SocketError.BindFailed,
                else => SocketError.BindFailed,
            };
        };

        self.fd = sock;
        self.local_port = local_port;

        // Resolve actual bound port if ephemeral
        if (local_port == 0) {
            var bound_addr: std.posix.sockaddr = undefined;
            var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            if (std.posix.getsockname(sock, &bound_addr, &bound_len)) |_| {
                const in_addr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&bound_addr));
                self.local_port = std.mem.bigToNative(u16, in_addr.port);
            } else |_| {}
        }
    }

    /// Set the remote endpoint address. Call before send/receive.
    pub fn setRemote(self: *Self, host: []const u8, port: u16) SocketError!void {
        const parsed = std.net.Ip4Address.parse(host, port) catch {
            // Fallback: try to parse as raw octets
            return SocketError.ResolveFailed;
        };
        self.remote_addr = parsed.sa;
    }

    /// Send a datagram to the configured remote endpoint.
    pub fn send(self: *Self, data: []const u8) SocketError!void {
        const sock = self.fd orelse return SocketError.NotOpen;
        _ = std.posix.sendto(
            sock,
            data,
            0,
            @ptrCast(&self.remote_addr),
            @sizeOf(std.posix.sockaddr.in),
        ) catch |err| return switch (err) {
            error.WouldBlock => SocketError.WouldBlock,
            else => SocketError.SendFailed,
        };
    }

    /// Receive a datagram. Returns `null` if no data is available (non-blocking).
    pub fn receive(self: *Self, buf: []u8) SocketError!?usize {
        const sock = self.fd orelse return SocketError.NotOpen;
        const n = std.posix.recvfrom(sock, buf, 0, null, null) catch |err| return switch (err) {
            error.WouldBlock => null,
            error.ConnectionRefused => null, // ICMP port unreachable on some platforms
            else => SocketError.ReceiveFailed,
        };
        return n;
    }

    pub fn close(self: *Self) void {
        if (self.fd) |sock| {
            std.posix.close(sock);
            self.fd = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.* = .{
            .fd = null,
            .remote_addr = std.mem.zeroes(std.posix.sockaddr.in),
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
        std.Thread.sleep(1_000_000); // 1ms
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
