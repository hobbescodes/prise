const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const redraw = @import("redraw.zig");
const key_notation = @import("key_notation.zig");
const posix = std.posix;
const vaxis = @import("vaxis");
const Surface = @import("Surface.zig");

pub const UnixSocketClient = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    ctx: io.Context,
    addr: posix.sockaddr.un,

    const Msg = enum {
        socket,
        connect,
    };

    fn handleMsg(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(UnixSocketClient);

        switch (completion.msgToEnum(Msg)) {
            .socket => {
                switch (completion.result) {
                    .socket => |fd| {
                        self.fd = fd;
                        _ = try loop.connect(
                            fd,
                            @ptrCast(&self.addr),
                            @sizeOf(posix.sockaddr.un),
                            .{
                                .ptr = self,
                                .msg = @intFromEnum(Msg.connect),
                                .cb = UnixSocketClient.handleMsg,
                            },
                        );
                    },
                    .err => |err| {
                        defer self.allocator.destroy(self);
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                    },
                    else => unreachable,
                }
            },

            .connect => {
                defer self.allocator.destroy(self);

                switch (completion.result) {
                    .connect => {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .socket = self.fd.? },
                        });
                    },
                    .err => |err| {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                        if (self.fd) |fd| {
                            _ = try loop.close(fd, .{
                                .ptr = null,
                                .cb = struct {
                                    fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                                }.noop,
                            });
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
};

pub fn connectUnixSocket(
    loop: *io.Loop,
    socket_path: []const u8,
    ctx: io.Context,
) !*UnixSocketClient {
    const client = try loop.allocator.create(UnixSocketClient);
    errdefer loop.allocator.destroy(client);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    client.* = .{
        .allocator = loop.allocator,
        .ctx = ctx,
        .addr = addr,
        .fd = null,
    };

    _ = try loop.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
        .{
            .ptr = client,
            .msg = @intFromEnum(UnixSocketClient.Msg.socket),
            .cb = UnixSocketClient.handleMsg,
        },
    );

    return client;
}

pub const App = struct {
    connected: bool = false,
    connection_refused: bool = false,
    fd: posix.fd_t = undefined,
    allocator: std.mem.Allocator,
    recv_buffer: [4096]u8 = undefined,
    msg_buffer: std.ArrayList(u8),
    send_buffer: ?[]u8 = null,
    send_task: ?io.Task = null,
    pty_id: ?i64 = null,
    response_received: bool = false,
    attached: bool = false,
    vx: vaxis.Vaxis = undefined,
    tty: vaxis.Tty = undefined,
    loop: vaxis.Loop(vaxis.Event) = undefined,
    should_quit: bool = false,
    tty_thread: ?std.Thread = null,
    io_loop: ?*io.Loop = null,
    tty_buffer: [4096]u8 = undefined,
    surface: ?Surface = null,

    pipe_read_fd: posix.fd_t = undefined,
    pipe_write_fd: posix.fd_t = undefined,
    pipe_buffer: std.ArrayList(u8),
    pipe_recv_buffer: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !App {
        var app: App = .{
            .allocator = allocator,
            .vx = try vaxis.init(allocator, .{}),
            .tty = undefined,
            .tty_buffer = undefined,
            .loop = undefined,
            .msg_buffer = .empty,
            .pipe_buffer = .empty,
        };
        app.tty = try vaxis.Tty.init(&app.tty_buffer);
        app.loop = .{ .tty = &app.tty, .vaxis = &app.vx };
        try app.loop.init();
        std.log.info("Vaxis loop initialized", .{});

        // Create pipe for TTY thread -> Main thread communication
        const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        app.pipe_read_fd = fds[0];
        app.pipe_write_fd = fds[1];
        std.log.info("Pipe created: read_fd={} write_fd={}", .{ app.pipe_read_fd, app.pipe_write_fd });

        return app;
    }

    pub fn deinit(self: *App) void {
        self.should_quit = true;
        self.loop.stop();
        if (self.tty_thread) |thread| {
            thread.join();
        }
        if (self.surface) |*surface| {
            surface.deinit();
        }
        self.pipe_buffer.deinit(self.allocator);
        self.msg_buffer.deinit(self.allocator);
        posix.close(self.pipe_read_fd);
        posix.close(self.pipe_write_fd);
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn setup(self: *App, loop: *io.Loop) !void {
        self.io_loop = loop;

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        // Initialize surface with current terminal size
        const win = self.vx.window();
        self.surface = try Surface.init(self.allocator, win.height, win.width);

        try self.render();

        // Register pipe read end with io.Loop
        _ = try loop.read(self.pipe_read_fd, &self.pipe_recv_buffer, .{
            .ptr = self,
            .cb = onPipeRead,
        });

        // Spawn TTY thread to handle vaxis events and forward via pipe
        std.log.info("Spawning TTY thread...", .{});
        self.tty_thread = try std.Thread.spawn(.{}, ttyThreadFn, .{self});
        std.log.info("TTY thread spawned", .{});
    }

    fn ttyThreadFn(self: *App) void {
        std.log.info("TTY thread started", .{});

        // Start the vaxis loop (spawns TTY reader thread)
        self.loop.start() catch |err| {
            std.log.err("Failed to start vaxis loop: {}", .{err});
            return;
        };
        std.log.info("Vaxis loop started in TTY thread", .{});

        while (!self.should_quit) {
            std.log.debug("Waiting for next event...", .{});
            const event = self.loop.nextEvent();
            std.log.info("Received vaxis event: {s}", .{@tagName(event)});
            self.forwardEventToPipe(event) catch |err| {
                std.log.err("Error forwarding event: {}", .{err});
            };
        }
        std.log.info("TTY thread exiting", .{});
    }

    fn forwardEventToPipe(self: *App, event: vaxis.Event) !void {
        switch (event) {
            .key_press => |key| {
                // Check for Ctrl+C to quit
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    std.log.info("Ctrl+C detected, sending quit and stopping vaxis loop", .{});
                    const msg = try msgpack.encode(self.allocator, .{"quit"});
                    defer self.allocator.free(msg);
                    try self.writePipeFrame(msg);
                    // Stop vaxis loop so TTY thread can exit
                    self.loop.stop();
                    return;
                }

                // Convert to notation
                var notation_buf: [32]u8 = undefined;
                const notation = try key_notation.fromVaxisKey(key, &notation_buf);

                // Encode as msgpack: ["key", notation]
                const msg = try msgpack.encode(self.allocator, .{ "key", notation });
                defer self.allocator.free(msg);

                try self.writePipeFrame(msg);
            },
            .winsize => |ws| {
                // Encode as msgpack: ["resize", rows, cols]
                const msg = try msgpack.encode(self.allocator, .{ "resize", ws.rows, ws.cols });
                defer self.allocator.free(msg);

                try self.writePipeFrame(msg);
            },
            else => {},
        }
    }

    fn writePipeFrame(self: *App, payload: []const u8) !void {
        // Write length-prefixed frame: [u32_le length][payload]
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);

        // Write length
        var index: usize = 0;
        while (index < 4) {
            const n = posix.write(self.pipe_write_fd, len_buf[index..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            index += n;
        }

        // Write payload
        index = 0;
        while (index < payload.len) {
            const n = posix.write(self.pipe_write_fd, payload[index..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            index += n;
        }
    }

    fn onPipeRead(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .read => |bytes_read| {
                if (bytes_read == 0) {
                    std.log.warn("Pipe closed", .{});
                    return;
                }

                // Append to pipe buffer
                try app.pipe_buffer.appendSlice(app.allocator, app.pipe_recv_buffer[0..bytes_read]);

                // Process complete frames
                while (app.pipe_buffer.items.len >= 4) {
                    const frame_len = std.mem.readInt(u32, app.pipe_buffer.items[0..4], .little);

                    if (app.pipe_buffer.items.len < 4 + frame_len) {
                        // Partial frame, wait for more data
                        break;
                    }

                    // Decode msgpack payload
                    const payload = app.pipe_buffer.items[4 .. 4 + frame_len];
                    const value = msgpack.decode(app.allocator, payload) catch |err| {
                        std.log.err("Failed to decode pipe message: {}", .{err});
                        // Skip this frame
                        try app.pipe_buffer.replaceRange(app.allocator, 0, 4 + frame_len, &.{});
                        continue;
                    };
                    defer value.deinit(app.allocator);

                    // Handle the message
                    try app.handlePipeMessage(value);

                    // Remove consumed bytes
                    try app.pipe_buffer.replaceRange(app.allocator, 0, 4 + frame_len, &.{});
                }

                // Keep reading unless we're quitting
                if (!app.should_quit) {
                    std.log.debug("Resubmitting pipe read", .{});
                    _ = try l.read(app.pipe_read_fd, &app.pipe_recv_buffer, .{
                        .ptr = app,
                        .cb = onPipeRead,
                    });
                } else {
                    std.log.info("NOT resubmitting pipe read (should_quit=true)", .{});
                }
            },
            .err => |err| {
                std.log.err("Pipe recv failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn handlePipeMessage(self: *App, value: msgpack.Value) !void {
        if (value != .array or value.array.len < 1) return;

        const msg_type = value.array[0];
        if (msg_type != .string) return;

        if (std.mem.eql(u8, msg_type.string, "key")) {
            if (value.array.len < 2 or value.array[1] != .string) return;

            const notation = value.array[1].string;

            // Send to server
            if (self.attached and self.pty_id != null) {
                const msg = try msgpack.encode(self.allocator, .{
                    2, // notification
                    "key_input",
                    .{ self.pty_id.?, notation },
                });
                defer self.allocator.free(msg);

                try self.sendDirect(msg);
            }
        } else if (std.mem.eql(u8, msg_type.string, "resize")) {
            if (value.array.len < 3) return;

            const rows = switch (value.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return,
            };
            const cols = switch (value.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return,
            };

            // Send to server
            if (self.attached and self.pty_id != null) {
                const msg = try msgpack.encode(self.allocator, .{
                    2, // notification
                    "resize_pty",
                    .{ self.pty_id.?, rows, cols },
                });
                defer self.allocator.free(msg);

                try self.sendDirect(msg);
            }
        } else if (std.mem.eql(u8, msg_type.string, "quit")) {
            std.log.info("Quit message received", .{});
            self.should_quit = true;

            // Normal quit: cancel all pending operations and exit
            // (detach_pty is only for when you want to keep the session alive)
            if (self.io_loop) |l| {
                std.log.info("io.Loop pending count before cancel: {}", .{l.pending.count()});

                // Cancel all pending operations
                var it = l.pending.iterator();
                while (it.next()) |entry| {
                    const id = entry.key_ptr.*;
                    std.log.info("Cancelling operation id={}", .{id});
                    l.cancel(id) catch |err| {
                        std.log.err("Failed to cancel id={}: {}", .{ id, err });
                    };
                }

                std.log.info("io.Loop pending count after cancel: {}", .{l.pending.count()});
            }
        }
    }

    pub fn handleRedraw(self: *App, params: msgpack.Value) !void {
        if (self.surface) |*surface| {
            try surface.applyRedraw(params);

            // Check if we got a flush event - if so, swap and render
            if (params == .array) {
                for (params.array) |event_val| {
                    if (event_val != .array or event_val.array.len < 1) continue;
                    const event_name = event_val.array[0];
                    if (event_name == .string and std.mem.eql(u8, event_name.string, "flush")) {
                        surface.swap();
                        try self.render();
                        return;
                    }
                }
            }
        }
    }

    pub fn render(self: *App) !void {
        if (self.surface) |*surface| {
            const win = self.vx.window();
            surface.render(win);
        }
        try self.vx.render(self.tty.writer());
    }

    pub fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .socket => |fd| {
                app.fd = fd;
                app.connected = true;
                std.log.info("Connected! fd={}", .{app.fd});

                if (!app.should_quit) {
                    app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 1, "spawn_pty", .{} });

                    app.send_task = try l.send(fd, app.send_buffer.?, .{
                        .ptr = app,
                        .cb = onSendComplete,
                    });
                } else {
                    std.log.info("Connected but should_quit=true, not sending spawn_pty", .{});
                }
            },
            .err => |err| {
                if (err == error.ConnectionRefused) {
                    app.connection_refused = true;
                } else {
                    std.log.err("Connection failed: {}", .{err});
                }
            },
            else => unreachable,
        }
    }

    fn onSendComplete(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());
        std.log.info("onSendComplete called, result type: {s}", .{@tagName(completion.result)});

        if (app.send_buffer) |buf| {
            app.allocator.free(buf);
            app.send_buffer = null;
        }

        switch (completion.result) {
            .send => |bytes_sent| {
                std.log.info("Sent {} bytes, should_quit={}", .{ bytes_sent, app.should_quit });

                if (!app.should_quit) {
                    std.log.debug("Resubmitting recv after send", .{});
                    _ = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
                } else {
                    std.log.info("NOT resubmitting recv after send (should_quit=true)", .{});
                }
            },
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
                std.log.info("NOT resubmitting recv after send error", .{});
            },
            else => unreachable,
        }
    }

    fn onRecv(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());
        std.log.info("onRecv called, result type: {s}", .{@tagName(completion.result)});

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    std.log.info("Server closed connection", .{});
                    return;
                }

                // Append new data to message buffer
                try app.msg_buffer.appendSlice(app.allocator, app.recv_buffer[0..bytes_read]);

                // Try to decode as many complete messages as possible
                while (app.msg_buffer.items.len > 0) {
                    const result = rpc.decodeMessageWithSize(app.allocator, app.msg_buffer.items) catch |err| {
                        if (err == error.UnexpectedEndOfInput) {
                            // Partial message, wait for more data
                            std.log.debug("Partial message, waiting for more data ({} bytes buffered)", .{app.msg_buffer.items.len});
                            break;
                        }
                        return err;
                    };
                    defer result.message.deinit(app.allocator);

                    const msg = result.message;
                    const bytes_consumed = result.bytes_consumed;

                    switch (msg) {
                        .response => |resp| {
                            std.log.info("Got response: msgid={}", .{resp.msgid});

                            if (resp.err) |err| {
                                std.log.err("Error: {}", .{err});
                            } else {
                                switch (resp.result) {
                                    .integer => |i| {
                                        if (app.pty_id == null) {
                                            app.pty_id = i;
                                            std.log.info("PTY spawned with ID: {}", .{i});

                                            // Attach to the session
                                            app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 2, "attach_pty", .{i} });
                                            _ = try l.send(app.fd, app.send_buffer.?, .{
                                                .ptr = app,
                                                .cb = onSendComplete,
                                            });
                                        } else if (!app.attached) {
                                            std.log.info("Attached to session {}", .{i});
                                            app.attached = true;
                                        }
                                    },
                                    .unsigned => |u| {
                                        if (app.pty_id == null) {
                                            app.pty_id = @intCast(u);
                                            std.log.info("PTY spawned with ID: {}", .{u});

                                            // Attach to the session
                                            app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 2, "attach_pty", .{u} });
                                            _ = try l.send(app.fd, app.send_buffer.?, .{
                                                .ptr = app,
                                                .cb = onSendComplete,
                                            });
                                        } else if (!app.attached) {
                                            std.log.info("Attached to session {}", .{u});
                                            app.attached = true;
                                        }
                                    },
                                    .string => |s| {
                                        std.log.info("Result: {s}", .{s});
                                    },
                                    else => {
                                        std.log.info("Result: {}", .{resp.result});
                                    },
                                }
                            }
                            app.response_received = true;
                        },
                        .request => {
                            std.log.warn("Got unexpected request from server", .{});
                        },
                        .notification => |notif| {
                            if (std.mem.eql(u8, notif.method, "redraw")) {
                                std.log.debug("Handling redraw notification", .{});
                                app.handleRedraw(notif.params) catch |err| {
                                    std.log.err("Failed to handle redraw: {}", .{err});
                                };
                                std.log.debug("Redraw handled, rendering", .{});
                                app.render() catch |err| {
                                    std.log.err("Failed to render: {}", .{err});
                                };
                                std.log.debug("Render complete", .{});
                            }
                        },
                    }

                    // Remove consumed bytes from buffer
                    if (bytes_consumed > 0) {
                        try app.msg_buffer.replaceRange(app.allocator, 0, bytes_consumed, &.{});
                    }
                }

                // Keep receiving unless we're quitting
                if (!app.should_quit) {
                    std.log.debug("Resubmitting server recv", .{});
                    _ = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
                } else {
                    std.log.info("NOT resubmitting server recv (should_quit=true)", .{});
                }
            },
            .err => |err| {
                std.log.err("Recv failed: {}", .{err});
                std.log.info("NOT resubmitting recv after error", .{});
                // Don't resubmit on error - let it drain
            },
            else => unreachable,
        }
    }

    fn sendDirect(self: *App, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const n = try posix.write(self.fd, data[index..]);
            index += n;
        }
    }
};

test "UnixSocketClient - successful connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var connected = false;
    var fd: posix.socket_t = undefined;

    const State = struct {
        connected: *bool,
        fd: *posix.socket_t,
    };

    var state = State{
        .connected = &connected,
        .fd = &fd,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => |socket_fd| {
                    s.fd.* = socket_fd;
                    s.connected.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);
    try testing.expect(!connected);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeConnect(socket_fd);
    try loop.run(.once);
    try testing.expect(connected);
    try testing.expectEqual(socket_fd, fd);
}

test "UnixSocketClient - connection refused" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var got_error = false;
    var err_value: ?anyerror = null;

    const State = struct {
        got_error: *bool,
        err_value: *?anyerror,
    };

    var state = State{
        .got_error = &got_error,
        .err_value = &err_value,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => {},
                .err => |err| {
                    s.got_error.* = true;
                    s.err_value.* = err;
                },
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeWithError(socket_fd, error.ConnectionRefused);
    try loop.run(.until_done);
    try testing.expect(got_error);
    try testing.expectEqual(error.ConnectionRefused, err_value.?);
}
