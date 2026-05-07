//! Standalone native test harness for live mosh-server validation.
//!
//! Usage:
//!   1. SSH to your host and run: `mosh-server new -s -c 256 -l LC_ALL=en_US.UTF-8`
//!   2. Note the `MOSH CONNECT <port> <key>` line.
//!   3. Run this program:
//!      zig build test-live && ./zig-out/bin/mosh_live_test <host> <port> <key> [cols] [rows]
//!
//! The program connects via UDP, prints host bytes, and sends a few
//! keystrokes automatically. It runs until the session fails or a
//! timeout is reached.

const std = @import("std");
const mosh = @import("root.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print(
            \\nUsage: {s} <host> <port> <key> [cols] [rows] [duration_sec]
            \\n  host          : IP or hostname of the mosh-server
            \\n  port          : UDP port from MOSH CONNECT line
            \\n  key           : 22-char base64 key from MOSH CONNECT line
            \\n  cols          : terminal columns (default 80)
            \\n  rows          : terminal rows    (default 24)
            \\n  duration_sec  : max test duration  (default 30)
            \\n
        , .{args[0]});
        std.process.exit(1);
    }

    const host = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const key = args[3];
    const cols: i32 = if (args.len > 4) try std.fmt.parseInt(i32, args[4], 10) else 80;
    const rows: i32 = if (args.len > 5) try std.fmt.parseInt(i32, args[5], 10) else 24;
    const duration_sec: u64 = if (args.len > 6) try std.fmt.parseInt(u64, args[6], 10) else 30;

    std.debug.print("Connecting to mosh-server at {s}:{d} with key {s}\n", .{ host, port, key });
    std.debug.print("Terminal size: {d}x{d}\n", .{ cols, rows });
    std.debug.print("Max duration: {d}s\n\n", .{duration_sec});

    const endpoint: mosh.types.MoshEndpoint = .{
        .host = host,
        .port = port,
        .key_base64_22 = key,
    };

    var client = try mosh.core.Client.init(allocator, endpoint, .{
        .use_network_crypto = true,
        .initial_rto_ms = 50,
        .max_rto_ms = 4000,
        .network_timeout_ms = 30_000,
        .ack_delay_ms = 5,
        .ack_interval_ms = 3000,
    });
    defer client.deinit();

    const start_time_ms: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
    try client.start(start_time_ms);
    try client.resize(cols, rows, start_time_ms);

    std.debug.print("Session started. Waiting for host bytes...\n", .{});

    var buf: [4096]u8 = undefined;
    var last_tick_ms: u64 = start_time_ms;
    var keystroke_sent = false;

    while (true) {
        const now_ms: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
        const elapsed_sec = (now_ms - start_time_ms) / 1000;

        if (elapsed_sec >= duration_sec) {
            std.debug.print("\n[TIMEOUT] Test duration ({d}s) reached.\n", .{duration_sec});
            break;
        }

        // Pump network (send + recv)
        client.pumpNetwork(now_ms) catch |err| {
            std.debug.print("\n[NETWORK ERROR] {s}\n", .{@errorName(err)});
            break;
        };

        // Maintenance tick every 50ms
        if (now_ms >= last_tick_ms + 50) {
            client.maintenanceTick(now_ms) catch |err| {
                std.debug.print("\n[MAINTENANCE ERROR] {s}\n", .{@errorName(err)});
                break;
            };
            last_tick_ms = now_ms;
        }

        // Drain output events
        while (true) {
            const event = client.pollOutput(&buf) catch |err| {
                std.debug.print("\n[POLL ERROR] {s}\n", .{@errorName(err)});
                break;
            };
            if (event.event_type == .none) break;

            switch (event.event_type) {
                .host_bytes => {
                    const text = buf[0..event.written];
                    std.debug.print("{s}", .{text});
                },
                .resize => std.debug.print("\n[RESIZE] {d}x{d}\n", .{ event.cols, event.rows }),
                .echo_ack => std.debug.print("\n[ECHO_ACK] {d}\n", .{event.echo_ack}),
                .state_changed => {
                    const text = buf[0..event.written];
                    std.debug.print("\n[STATE] {s}\n", .{text});
                },
                .diagnostic => {
                    const text = buf[0..event.written];
                    std.debug.print("\n[DIAG] {s}\n", .{text});
                },
                .none => {},
            }
        }

        // Auto-send a keystroke after 2 seconds to trigger echo
        if (!keystroke_sent and elapsed_sec >= 2) {
            std.debug.print("\n[SENDING] keystroke 'ls\\n'\n", .{});
            client.sendInput("ls\n", now_ms) catch |err| {
                std.debug.print("[SEND ERROR] {s}\n", .{@errorName(err)});
            };
            keystroke_sent = true;
        }

        // Check session state
        const state = client.runtimeState();
        if (state.state == @intFromEnum(mosh.types.SessionState.failed)) {
            std.debug.print("\n[SESSION FAILED] code={d}\n", .{state.last_failure_code});
            break;
        }
        if (state.state == @intFromEnum(mosh.types.SessionState.stopped)) {
            std.debug.print("\n[SESSION STOPPED]\n", .{});
            break;
        }

        std.Thread.sleep(2_000_000); // 2ms
    }

    const runtime = client.runtimeState();
    std.debug.print("\n--- Final state ---\n", .{});
    std.debug.print("  state            : {d}\n", .{runtime.state});
    std.debug.print("  last_failure     : {d}\n", .{runtime.last_failure_code});
    std.debug.print("  sent_state_num   : {d}\n", .{runtime.last_state_num_sent});
    std.debug.print("  recv_state_num   : {d}\n", .{runtime.last_state_num_received});
    std.debug.print("  pending_outbound : {d}\n", .{runtime.pending_outbound});
    std.debug.print("  pending_host_ops : {d}\n", .{runtime.pending_host_ops});
    std.debug.print("  rto_ms           : {d}\n", .{runtime.current_rto_ms});
    std.debug.print("-------------------\n", .{});
}
