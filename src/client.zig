const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const redraw = @import("redraw.zig");
const posix = std.posix;
const vaxis = @import("vaxis");
const Surface = @import("Surface.zig");
const UI = @import("ui.zig").UI;
const lua_event = @import("lua_event.zig");
const widget = @import("widget.zig");

pub const MsgId = enum(u16) {
    spawn_pty = 1,
    attach_pty = 2,
};

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

pub const ClientState = struct {
    pty_id: ?i64 = null,
    response_received: bool = false,
    attached: bool = false,
    should_quit: bool = false,
    connection_refused: bool = false,
    next_msgid: u32 = 1,

    pub fn init() ClientState {
        return .{};
    }
};

pub const ServerAction = union(enum) {
    none,
    send_attach: i64,
    redraw: msgpack.Value,
    attached,
};

pub const PipeAction = union(enum) {
    none,
    send_key: msgpack.Value, // key map
    send_resize: struct { rows: u16, cols: u16 },
    quit,
};

pub const ClientLogic = struct {
    pub fn processServerMessage(state: *ClientState, msg: rpc.Message) !ServerAction {
        switch (msg) {
            .response => |resp| {
                state.response_received = true;
                if (resp.err) |err_val| {
                    _ = err_val;
                    std.log.err("Error in response", .{});
                    return .none;
                } else {
                    switch (resp.result) {
                        .integer => |i| {
                            if (state.pty_id == null) {
                                state.pty_id = i;
                                return ServerAction{ .send_attach = i };
                            } else if (!state.attached) {
                                state.attached = true;
                                std.log.info("Attached to session", .{});
                                return .attached;
                            }
                        },
                        .unsigned => |u| {
                            if (state.pty_id == null) {
                                state.pty_id = @intCast(u);
                                // We spawned with attach=true, so we're already attached
                                state.attached = true;
                                std.log.info("Spawned and attached to session {}", .{u});
                                return .attached;
                            } else if (!state.attached) {
                                state.attached = true;
                                std.log.info("Attached to session", .{});
                                return .attached;
                            }
                        },
                        .string => |s| {
                            std.log.info("{s}", .{s});
                            return .none;
                        },
                        else => {
                            std.log.info("Unknown result type", .{});
                            return .none;
                        },
                    }
                }
            },
            .request => {
                std.log.warn("Got unexpected request from server", .{});
                return .none;
            },
            .notification => |notif| {
                if (std.mem.eql(u8, notif.method, "redraw")) {
                    return ServerAction{ .redraw = notif.params };
                }
            },
        }
        return .none;
    }

    pub fn processPipeMessage(state: *ClientState, value: msgpack.Value) !PipeAction {
        if (value != .array or value.array.len < 1) return .none;

        const msg_type = value.array[0];
        if (msg_type != .string) return .none;

        if (std.mem.eql(u8, msg_type.string, "key")) {
            if (value.array.len < 2 or value.array[1] != .map) return .none;
            const key_map = value.array[1];
            if (state.attached and state.pty_id != null) {
                return PipeAction{ .send_key = key_map };
            }
        } else if (std.mem.eql(u8, msg_type.string, "resize")) {
            if (value.array.len < 3) return .none;
            const rows = switch (value.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            const cols = switch (value.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            return PipeAction{ .send_resize = .{ .rows = rows, .cols = cols } };
        } else if (std.mem.eql(u8, msg_type.string, "quit")) {
            state.should_quit = true;
            return .quit;
        }
        return .none;
    }

    pub fn shouldFlush(params: msgpack.Value) bool {
        if (params != .array) return false;
        for (params.array) |event_val| {
            if (event_val != .array or event_val.array.len < 1) continue;
            const event_name = event_val.array[0];
            if (event_name == .string and std.mem.eql(u8, event_name.string, "flush")) {
                return true;
            }
        }
        return false;
    }

    pub fn encodeEvent(allocator: std.mem.Allocator, event: vaxis.Event) !?[]u8 {
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    return try msgpack.encode(allocator, .{"quit"});
                }

                // Build key map in JavaScript KeyboardEvent format
                const key_str = try vaxisKeyToString(allocator, key);
                defer allocator.free(key_str);

                var key_map_kv = try allocator.alloc(msgpack.Value.KeyValue, 5);
                key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = key_str } };
                key_map_kv[1] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = key.mods.shift } };
                key_map_kv[2] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = key.mods.ctrl } };
                key_map_kv[3] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = key.mods.alt } };
                key_map_kv[4] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = key.mods.super } };

                const key_map_val = msgpack.Value{ .map = key_map_kv };
                var arr = try allocator.alloc(msgpack.Value, 2);
                arr[0] = .{ .string = "key" };
                arr[1] = key_map_val;

                const result = try msgpack.encodeFromValue(allocator, msgpack.Value{ .array = arr });

                // Clean up temporary allocations
                allocator.free(arr);
                allocator.free(key_map_kv);

                return result;
            },
            .winsize => |ws| {
                return try msgpack.encode(allocator, .{ "resize", ws.rows, ws.cols });
            },
            else => return null,
        }
    }

    pub fn vaxisKeyToString(allocator: std.mem.Allocator, key: vaxis.Key) ![]u8 {
        // Check for named keys by codepoint matching
        if (key.codepoint == vaxis.Key.enter) return try allocator.dupe(u8, "Enter");
        if (key.codepoint == vaxis.Key.tab) return try allocator.dupe(u8, "Tab");
        if (key.codepoint == vaxis.Key.backspace) return try allocator.dupe(u8, "Backspace");
        if (key.codepoint == vaxis.Key.escape) return try allocator.dupe(u8, "Escape");
        if (key.codepoint == vaxis.Key.space) return try allocator.dupe(u8, " ");
        if (key.codepoint == vaxis.Key.delete) return try allocator.dupe(u8, "Delete");
        if (key.codepoint == vaxis.Key.insert) return try allocator.dupe(u8, "Insert");
        if (key.codepoint == vaxis.Key.home) return try allocator.dupe(u8, "Home");
        if (key.codepoint == vaxis.Key.end) return try allocator.dupe(u8, "End");
        if (key.codepoint == vaxis.Key.page_up) return try allocator.dupe(u8, "PageUp");
        if (key.codepoint == vaxis.Key.page_down) return try allocator.dupe(u8, "PageDown");
        if (key.codepoint == vaxis.Key.up) return try allocator.dupe(u8, "ArrowUp");
        if (key.codepoint == vaxis.Key.down) return try allocator.dupe(u8, "ArrowDown");
        if (key.codepoint == vaxis.Key.left) return try allocator.dupe(u8, "ArrowLeft");
        if (key.codepoint == vaxis.Key.right) return try allocator.dupe(u8, "ArrowRight");
        if (key.codepoint == vaxis.Key.f1) return try allocator.dupe(u8, "F1");
        if (key.codepoint == vaxis.Key.f2) return try allocator.dupe(u8, "F2");
        if (key.codepoint == vaxis.Key.f3) return try allocator.dupe(u8, "F3");
        if (key.codepoint == vaxis.Key.f4) return try allocator.dupe(u8, "F4");
        if (key.codepoint == vaxis.Key.f5) return try allocator.dupe(u8, "F5");
        if (key.codepoint == vaxis.Key.f6) return try allocator.dupe(u8, "F6");
        if (key.codepoint == vaxis.Key.f7) return try allocator.dupe(u8, "F7");
        if (key.codepoint == vaxis.Key.f8) return try allocator.dupe(u8, "F8");
        if (key.codepoint == vaxis.Key.f9) return try allocator.dupe(u8, "F9");
        if (key.codepoint == vaxis.Key.f10) return try allocator.dupe(u8, "F10");
        if (key.codepoint == vaxis.Key.f11) return try allocator.dupe(u8, "F11");
        if (key.codepoint == vaxis.Key.f12) return try allocator.dupe(u8, "F12");

        // For regular keys, use the text
        if (key.text) |text| {
            return try allocator.dupe(u8, text);
        }

        // Fallback to codepoint
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &buf) catch return try allocator.dupe(u8, "Unidentified");
        return try allocator.dupe(u8, buf[0..len]);
    }
};

pub const App = struct {
    connected: bool = false,
    fd: posix.fd_t = undefined,
    allocator: std.mem.Allocator,
    recv_buffer: [4096]u8 = undefined,
    msg_buffer: std.ArrayList(u8),
    msg_arena: std.heap.ArenaAllocator,
    send_buffer: ?[]u8 = null,
    send_task: ?io.Task = null,
    recv_task: ?io.Task = null,
    pipe_read_task: ?io.Task = null,
    vx: vaxis.Vaxis = undefined,
    tty: vaxis.Tty = undefined,
    tty_thread: ?std.Thread = null,
    io_loop: ?*io.Loop = null,
    tty_buffer: [4096]u8 = undefined,
    surface: ?Surface = null,
    state: ClientState = ClientState.init(),
    ui: UI = undefined,
    first_resize_done: bool = false,
    socket_path: []const u8 = undefined,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,

    // Terminal metrics
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pipe_read_fd: posix.fd_t = undefined,
    pipe_write_fd: posix.fd_t = undefined,
    parser: vaxis.Parser = undefined,
    pipe_buf: std.ArrayList(u8),
    pipe_recv_buffer: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !App {
        var app: App = .{
            .allocator = allocator,
            .vx = try vaxis.init(allocator, .{}),
            .tty = undefined,
            .tty_buffer = undefined,
            .msg_buffer = .empty,
            .msg_arena = std.heap.ArenaAllocator.init(allocator),
            .pipe_buf = .empty,
        };
        app.tty = try vaxis.Tty.init(&app.tty_buffer);
        // parser doesn't need init? assuming default init is fine or init(&allocator)
        app.parser = .{};

        std.log.info("Vaxis initialized", .{});

        // Initialize Lua UI
        app.ui = try UI.init(allocator);
        std.log.info("Lua UI initialized", .{});

        // Create pipe for TTY thread -> Main thread communication
        const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        app.pipe_read_fd = fds[0];
        app.pipe_write_fd = fds[1];
        std.log.info("Pipe created: read_fd={} write_fd={}", .{ app.pipe_read_fd, app.pipe_write_fd });

        return app;
    }

    pub fn deinit(self: *App) void {
        self.ui.deinit();
        self.state.should_quit = true;

        // Wake up TTY thread by sending a Device Status Report request.
        // This causes the terminal to send a response, unblocking the read.
        self.vx.deviceStatusReport(self.tty.writer()) catch {};

        // Cancel pending recv task
        if (self.recv_task) |*task| {
            if (self.io_loop) |loop| {
                task.cancel(loop) catch |err| {
                    std.log.warn("Failed to cancel recv task: {}", .{err});
                };
            } else {
                std.log.warn("deinit: io_loop is null, cannot cancel recv task", .{});
            }
            self.recv_task = null;
        }

        if (self.render_timer) |*task| {
            if (self.io_loop) |loop| {
                task.cancel(loop) catch |err| {
                    std.log.warn("Failed to cancel render timer: {}", .{err});
                };
            }
            self.render_timer = null;
        }

        // Close the socket
        if (self.connected) {
            posix.close(self.fd);
        }

        // Wait for TTY thread to exit naturally (it checks should_quit)
        if (self.tty_thread) |thread| {
            thread.join();
        }
        if (self.surface) |*surface| {
            surface.deinit();
        }
        self.pipe_buf.deinit(self.allocator);
        self.msg_buffer.deinit(self.allocator);
        self.msg_arena.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn setup(self: *App, loop: *io.Loop) !void {
        self.io_loop = loop;
        self.ui.setLoop(loop);
        self.ui.setQuitCallback(self, struct {
            fn quit(ctx: *anyopaque) void {
                const app: *App = @ptrCast(@alignCast(ctx));
                app.state.should_quit = true;
                if (app.connected) {
                    posix.close(app.fd);
                    app.connected = false;
                }
                if (app.recv_task) |*task| {
                    if (app.io_loop) |l| task.cancel(l) catch {};
                    app.recv_task = null;
                }
                if (app.render_timer) |*task| {
                    if (app.io_loop) |l| task.cancel(l) catch {};
                    app.render_timer = null;
                }
            }
        }.quit);

        try self.vx.enterAltScreen(self.tty.writer());

        // Don't initialize surface yet - wait for first winsize event from TTY thread
        // The surface will be created when we get the window size

        // Register pipe read end with io.Loop
        self.pipe_read_task = try loop.read(self.pipe_read_fd, &self.pipe_recv_buffer, .{
            .ptr = self,
            .cb = onPipeRead,
        });

        // Spawn TTY thread to handle vaxis events and forward via pipe
        std.log.info("Spawning TTY thread...", .{});
        self.tty_thread = try std.Thread.spawn(.{}, ttyThreadFn, .{self});
        std.log.info("TTY thread spawned", .{});

        // Send terminal queries to detect capabilities
        try self.vx.queryTerminalSend(self.tty.writer());

        // Register spawn callback
        self.ui.setSpawnCallback(self, struct {
            fn spawnCb(ctx: *anyopaque, opts: UI.SpawnOptions) !void {
                const app_ptr: *App = @ptrCast(@alignCast(ctx));
                try app_ptr.spawnPty(opts);
            }
        }.spawnCb);

        // Register redraw callback
        self.ui.setRedrawCallback(self, struct {
            fn redrawCb(ctx: *anyopaque) void {
                const app_ptr: *App = @ptrCast(@alignCast(ctx));
                app_ptr.scheduleRender() catch |err| {
                    std.log.err("Failed to schedule render: {}", .{err});
                };
            }
        }.redrawCb);

        // Manually trigger initial resize to connect
        const ws = try vaxis.Tty.getWinsize(self.tty.fd);
        try self.handleVaxisEvent(.{ .winsize = ws });
    }

    fn ttyThreadFn(self: *App) void {
        std.log.info("TTY thread started", .{});

        var buf: [1024]u8 = undefined;
        while (!self.state.should_quit) {
            const n = posix.read(self.tty.fd, &buf) catch |err| {
                std.log.err("TTY read failed: {}", .{err});
                break;
            };
            if (n == 0) break; // EOF

            // Forward to pipe
            self.writePipeBytes(buf[0..n]) catch |err| {
                std.log.err("Failed to write to pipe: {}", .{err});
                break;
            };
        }
        std.log.info("TTY thread exiting", .{});
    }

    fn writePipeBytes(self: *App, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const n = posix.write(self.pipe_write_fd, data[index..]) catch |err| {
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
                try app.pipe_buf.appendSlice(app.allocator, app.pipe_recv_buffer[0..bytes_read]);

                // Parse events using vaxis parser
                var i: usize = 0;
                while (i < app.pipe_buf.items.len) {
                    // Guessing parser API: parse(bytes, allocator) -> Result { n, event }
                    const result = try app.parser.parse(app.pipe_buf.items[i..], app.allocator);
                    if (result.n == 0) {
                        // Incomplete sequence, wait for more data
                        break;
                    }
                    i += result.n;

                    if (result.event) |event| {
                        try app.handleVaxisEvent(event);
                    }
                }

                // Remove processed bytes
                if (i > 0) {
                    try app.pipe_buf.replaceRange(app.allocator, 0, i, &.{});
                }

                // Keep reading unless we're quitting
                if (!app.state.should_quit) {
                    app.pipe_read_task = try l.read(app.pipe_read_fd, &app.pipe_recv_buffer, .{
                        .ptr = app,
                        .cb = onPipeRead,
                    });
                }
            },
            .err => |err| {
                std.log.err("Pipe recv failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn handleVaxisEvent(self: *App, event: vaxis.Event) !void {
        std.log.debug("handleVaxisEvent: {s}", .{@tagName(event)});

        // Forward to Lua UI
        self.ui.update(.{ .vaxis = event }) catch |err| {
            // Ignore NoUpdateFunction, log others
            if (err != error.NoUpdateFunction) {
                std.log.err("Lua UI update failed: {}", .{err});
            }
        };

        switch (event) {
            .key_press => |key| {
                // Check for a cursor position response for our explicit width query. This will
                // always be an F3 key with shift = true, and we must be looking for queries
                if (key.codepoint == vaxis.Key.f3 and
                    key.mods.shift and
                    !self.vx.queries_done.load(.unordered))
                {
                    std.log.info("explicit width capability detected", .{});
                    self.vx.caps.explicit_width = true;
                    self.vx.caps.unicode = .unicode;
                    self.vx.screen.width_method = .unicode;
                    return;
                }
                // Check for a cursor position response for our scaled text query. This will
                // always be an F3 key with alt = true, and we must be looking for queries
                if (key.codepoint == vaxis.Key.f3 and
                    key.mods.alt and
                    !self.vx.queries_done.load(.unordered))
                {
                    std.log.info("scaled text capability detected", .{});
                    self.vx.caps.scaled_text = true;
                    return;
                }

                if (key.codepoint == 'c' and key.mods.ctrl) {
                    std.log.info("Ctrl+C detected, quitting", .{});
                    self.state.should_quit = true;
                    if (self.connected) {
                        posix.close(self.fd);
                        self.connected = false;
                    }
                    if (self.recv_task) |*task| {
                        if (self.io_loop) |loop| task.cancel(loop) catch {};
                        self.recv_task = null;
                    }
                    return;
                }
            },
            .winsize => |ws| {
                // Calculate and store cell metrics
                if (ws.cols > 0 and ws.rows > 0) {
                    self.cell_width_px = if (ws.x_pixel > 0) ws.x_pixel / ws.cols else 0;
                    self.cell_height_px = if (ws.y_pixel > 0) ws.y_pixel / ws.rows else 0;
                }
                self.vx.state.in_band_resize = true;
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
            },
            .cap_kitty_keyboard => {
                std.log.info("kitty keyboard capability detected", .{});
                self.vx.caps.kitty_keyboard = true;
            },
            .cap_kitty_graphics => {
                if (!self.vx.caps.kitty_graphics) {
                    std.log.info("kitty graphics capability detected", .{});
                    self.vx.caps.kitty_graphics = true;
                }
            },
            .cap_rgb => {
                std.log.info("rgb capability detected", .{});
                self.vx.caps.rgb = true;
            },
            .cap_unicode => {
                std.log.info("unicode capability detected", .{});
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
            },
            .cap_sgr_pixels => {
                std.log.info("pixel mouse capability detected", .{});
                self.vx.caps.sgr_pixels = true;
            },
            .cap_color_scheme_updates => {
                std.log.info("color_scheme_updates capability detected", .{});
                self.vx.caps.color_scheme_updates = true;
            },
            .cap_multi_cursor => {
                std.log.info("multi cursor capability detected", .{});
                self.vx.caps.multi_cursor = true;
            },
            .cap_da1 => {
                self.vx.queries_done.store(true, .unordered);
                try self.vx.enableDetectedFeatures(self.tty.writer());
                // Send init event
                self.ui.update(.init) catch |err| {
                    std.log.err("Failed to update UI with init: {}", .{err});
                };

                if (!self.connected) {
                    if (self.io_loop) |loop| {
                        std.log.info("Initiating connection to {s} (da1 received)", .{self.socket_path});
                        _ = try connectUnixSocket(loop, self.socket_path, .{
                            .ptr = self,
                            .cb = App.onConnected,
                        });
                    }
                }
            },
            else => {},
        }
    }

    fn updateSurfaceSize(self: *App, pty_id: u32, rows: u16, cols: u16) void {
        std.log.info("Updating surface size to {}x{}", .{ cols, rows });

        // Create or resize surface
        if (self.surface) |*surface| {
            surface.resize(rows, cols) catch |err| {
                std.log.err("Failed to resize surface: {}", .{err});
            };
        } else {
            self.surface = Surface.init(self.allocator, pty_id, rows, cols) catch |err| {
                std.log.err("Failed to create surface: {}", .{err});
                return;
            };
            std.log.info("Surface initialized: {}x{}", .{ cols, rows });
        }
    }

    pub fn sendResize(self: *App, pty_id: u32, rows: u16, cols: u16) !void {
        // Check if surface is already at correct size
        if (self.surface) |*surface| {
            // Only check if this is the active surface
            // Since we currently only have one surface, we assume it corresponds to the pty being resized?
            // Actually, we can't rely on self.surface unless we know pty_id matches.
            // But surface doesn't store pty_id (except indirectly via widget).
            // However, updateSurfaceSize relies on self.surface.
            if (surface.rows == rows and surface.cols == cols) return;

            // Update surface immediately
            try surface.resize(rows, cols);
        }

        const msgid = self.state.next_msgid;
        self.state.next_msgid += 1;

        const width_px = @as(u16, cols) * self.cell_width_px;
        const height_px = @as(u16, rows) * self.cell_height_px;

        const msg = try msgpack.encode(self.allocator, .{ 0, msgid, "resize_pty", .{ pty_id, rows, cols, width_px, height_px } });
        defer self.allocator.free(msg);

        try self.sendDirect(msg);
        std.log.info("Sent resize request id={} for pty={} to {}x{} ({}x{}px)", .{ msgid, pty_id, cols, rows, width_px, height_px });
    }

    pub fn handleRedraw(self: *App, params: msgpack.Value) !void {
        std.log.debug("handleRedraw: received redraw params", .{});
        if (self.surface) |*surface| {
            try surface.applyRedraw(params);

            // Check if we got a flush event - if so, swap and render
            if (params == .array) {
                const should_flush = ClientLogic.shouldFlush(params);
                std.log.debug("handleRedraw: params is array, shouldFlush={}", .{should_flush});
                if (should_flush) {
                    std.log.debug("handleRedraw: flush event received, rendering", .{});
                    try self.scheduleRender();
                    return;
                } else {
                    std.log.debug("handleRedraw: no flush event, not rendering yet", .{});
                }
            } else {
                std.log.debug("handleRedraw: params is not array", .{});
            }
        } else {
            std.log.warn("handleRedraw: no surface, ignoring redraw", .{});
        }
    }

    fn renderWidget(self: *App, w: widget.Widget, win: vaxis.Window) !void {
        switch (w.kind) {
            .surface => |surf| {
                if (self.surface) |*surface| {
                    // Check if we need to resize the PTY
                    if (surface.pty_id == surf.pty_id) {
                        if (w.width != surface.cols or w.height != surface.rows) {
                            self.sendResize(surf.pty_id, w.height, w.width) catch |err| {
                                std.log.err("Failed to send resize: {}", .{err});
                            };
                        }
                    }
                    surface.render(win);
                }
            },
            .text => |text| {
                // Use a temporary arena for rendering this frame
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                var iter = widget.Text.Iterator{
                    .text = text,
                    .max_width = w.width,
                    .allocator = alloc,
                };

                var row: usize = 0;
                while (iter.next() catch null) |line| {
                    var col: usize = 0;

                    // Handle alignment
                    const free_space = if (w.width > line.width) w.width - line.width else 0;
                    const start_col: u16 = switch (text.@"align") {
                        widget.Text.Align.left => 0,
                        widget.Text.Align.center => free_space / 2,
                        widget.Text.Align.right => free_space,
                    };

                    col = start_col;

                    for (line.segments) |seg| {
                        _ = win.printSegment(seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
                        col += vaxis.gwidth.gwidth(seg.text, .unicode);
                    }

                    // Fill remaining space with background from last segment
                    if (line.segments.len > 0 and col < w.width) {
                        const last_style = line.segments[line.segments.len - 1].style;
                        const spacer = vaxis.Segment{
                            .text = " ",
                            .style = last_style,
                        };
                        while (col < w.width) {
                            _ = win.printSegment(spacer, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
                            col += 1;
                        }
                    }

                    row += 1;
                }
            },
            .column => |col| {
                for (col.children) |child| {
                    const child_win = win.child(.{
                        .x_off = child.x,
                        .y_off = child.y,
                        .width = child.width,
                        .height = child.height,
                    });
                    try self.renderWidget(child, child_win);
                }
            },
        }
    }

    pub fn scheduleRender(self: *App) !void {
        if (self.io_loop) |loop| {
            const now = std.time.milliTimestamp();
            const FRAME_TIME = 8;

            if (now - self.last_render_time >= FRAME_TIME) {
                try self.render();
            } else if (self.render_timer == null) {
                const delay = FRAME_TIME - (now - self.last_render_time);
                // Make sure delay is positive
                const safe_delay = if (delay < 0) 0 else delay;
                self.render_timer = try loop.timeout(@as(u64, @intCast(safe_delay)) * std.time.ns_per_ms, .{
                    .ptr = self,
                    .cb = onRenderTimer,
                });
            }
        } else {
            // Fallback if no loop (e.g. during tests or init)
            try self.render();
        }
    }

    fn onRenderTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const app = completion.userdataCast(App);
        app.render() catch |err| {
            std.log.err("Failed to render frame: {}", .{err});
        };
        app.render_timer = null;
    }

    pub fn render(self: *App) !void {
        std.log.debug("render: starting render", .{});

        var root_widget = self.ui.view() catch |err| {
            std.log.err("Failed to get view from UI: {}", .{err});
            return;
        };
        defer root_widget.deinit(self.allocator);

        const win = self.vx.window();
        const screen = win.screen;

        const constraints = widget.BoxConstraints{
            .min_width = 0,
            .max_width = screen.width,
            .min_height = 0,
            .max_height = screen.height,
        };

        var w = root_widget;
        _ = w.layout(constraints);

        try self.renderWidget(w, win);

        std.log.debug("render: calling vx.render()", .{});
        if (self.surface) |*surface| {
            self.vx.setTitle(self.tty.writer(), surface.getTitle()) catch {};
        }
        try self.vx.render(self.tty.writer());
        std.log.debug("render: flushing tty", .{});
        try self.tty.tty_writer.interface.flush();
        std.log.debug("render: complete", .{});

        self.last_render_time = std.time.milliTimestamp();
    }

    pub fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .socket => |fd| {
                app.fd = fd;
                app.connected = true;
                std.log.info("Connected! fd={}", .{app.fd});

                if (!app.state.should_quit) {
                    // Start receiving from the server
                    app.recv_task = try l.recv(fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });

                    // Vaxis and surface are already initialized from first winsize event
                    const ws = try vaxis.Tty.getWinsize(app.tty.fd);

                    var params_kv = try app.allocator.alloc(msgpack.Value.KeyValue, 3);
                    defer app.allocator.free(params_kv);
                    std.log.info("Sending spawn_pty: rows={} cols={}", .{ ws.rows, ws.cols });
                    params_kv[0] = .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = ws.rows } };
                    params_kv[1] = .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = ws.cols } };
                    params_kv[2] = .{ .key = .{ .string = "attach" }, .value = .{ .boolean = true } };
                    const params_val = msgpack.Value{ .map = params_kv };
                    var arr = try app.allocator.alloc(msgpack.Value, 4);
                    defer app.allocator.free(arr);
                    arr[0] = .{ .unsigned = 0 };
                    arr[1] = .{ .unsigned = @intFromEnum(MsgId.spawn_pty) };
                    arr[2] = .{ .string = "spawn_pty" };
                    arr[3] = params_val;
                    app.send_buffer = try msgpack.encodeFromValue(app.allocator, msgpack.Value{ .array = arr });

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
                    app.state.connection_refused = true;
                } else {
                    std.log.err("Connection failed: {}", .{err});
                }
            },
            else => unreachable,
        }
    }

    fn onSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        if (app.send_buffer) |buf| {
            app.allocator.free(buf);
            app.send_buffer = null;
        }

        switch (completion.result) {
            .send => {},
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn onRecv(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());
        defer _ = app.msg_arena.reset(.retain_capacity);
        const arena = app.msg_arena.allocator();

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
                    const result = rpc.decodeMessageWithSize(arena, app.msg_buffer.items) catch |err| {
                        if (err == error.UnexpectedEndOfInput) {
                            // Partial message, wait for more data
                            break;
                        }
                        return err;
                    };
                    defer result.message.deinit(arena);

                    const msg = result.message;
                    const bytes_consumed = result.bytes_consumed;

                    // Process message via ClientLogic
                    const action = try ClientLogic.processServerMessage(&app.state, msg);

                    switch (action) {
                        .send_attach => |pty_id| {
                            std.log.info("Sending attach_pty for session {}", .{pty_id});
                            app.send_buffer = try msgpack.encode(app.allocator, .{ 0, @intFromEnum(MsgId.attach_pty), "attach_pty", .{pty_id} });
                            _ = try l.send(app.fd, app.send_buffer.?, .{
                                .ptr = app,
                                .cb = onSendComplete,
                            });
                        },
                        .redraw => |params| {
                            app.handleRedraw(params) catch |err| {
                                std.log.err("Failed to handle redraw: {}", .{err});
                            };
                        },
                        .attached => {
                            std.log.info("Attached to session, checking for resize", .{});

                            if (app.state.pty_id) |pty_id| {
                                // Ensure surface exists
                                if (app.surface == null) {
                                    const ws = try vaxis.Tty.getWinsize(app.tty.fd);
                                    std.log.info("Creating surface for attached session: {}x{}", .{ ws.rows, ws.cols });
                                    app.surface = Surface.init(app.allocator, @intCast(pty_id), ws.rows, ws.cols) catch |err| {
                                        std.log.err("Failed to create surface: {}", .{err});
                                        return error.SurfaceInitFailed;
                                    };
                                }

                                if (app.surface) |*surface| {
                                    // Send pty_attach event to Lua UI
                                    app.ui.update(.{
                                        .pty_attach = .{
                                            .id = @intCast(pty_id),
                                            .surface = surface,
                                            .app = app,
                                            .send_fn = struct {
                                                fn appSendDirect(ctx: *anyopaque, id: u32, key: lua_event.KeyData) anyerror!void {
                                                    const self: *App = @ptrCast(@alignCast(ctx));

                                                    var key_map_kv = try self.allocator.alloc(msgpack.Value.KeyValue, 5);
                                                    key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = key.key } };
                                                    key_map_kv[1] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = key.shift } };
                                                    key_map_kv[2] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = key.ctrl } };
                                                    key_map_kv[3] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = key.alt } };
                                                    key_map_kv[4] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = key.super } };

                                                    const key_map_val = msgpack.Value{ .map = key_map_kv };

                                                    var params = try self.allocator.alloc(msgpack.Value, 2);
                                                    params[0] = .{ .unsigned = @intCast(id) };
                                                    params[1] = key_map_val;

                                                    var arr = try self.allocator.alloc(msgpack.Value, 3);
                                                    arr[0] = .{ .unsigned = 2 }; // notification
                                                    arr[1] = .{ .string = "key_input" };
                                                    arr[2] = .{ .array = params };

                                                    const encoded_msg = try msgpack.encodeFromValue(self.allocator, .{ .array = arr });
                                                    defer self.allocator.free(encoded_msg);

                                                    // Clean up msgpack structures
                                                    self.allocator.free(arr);
                                                    self.allocator.free(params);
                                                    self.allocator.free(key_map_kv);

                                                    try self.sendDirect(encoded_msg);
                                                }
                                            }.appSendDirect,
                                        },
                                    }) catch |err| {
                                        std.log.err("Failed to update UI with pty_attach: {}", .{err});
                                    };

                                    std.log.info("Sending initial resize: {}x{}", .{ surface.rows, surface.cols });
                                    const width_px = @as(u16, surface.cols) * app.cell_width_px;
                                    const height_px = @as(u16, surface.rows) * app.cell_height_px;
                                    const resize_msg = try msgpack.encode(app.allocator, .{
                                        2, // notification
                                        "resize_pty",
                                        .{ pty_id, surface.rows, surface.cols, width_px, height_px },
                                    });
                                    defer app.allocator.free(resize_msg);
                                    try app.sendDirect(resize_msg);
                                }
                            }
                        },
                        .none => {},
                    }

                    // Remove consumed bytes from buffer
                    if (bytes_consumed > 0) {
                        try app.msg_buffer.replaceRange(app.allocator, 0, bytes_consumed, &.{});
                    }
                }

                // Keep receiving unless we're quitting
                if (!app.state.should_quit) {
                    app.recv_task = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
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

    pub fn spawnPty(self: *App, opts: UI.SpawnOptions) !void {
        const msgid = self.state.next_msgid;
        self.state.next_msgid += 1;

        // Manually construct map for spawn params
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 3);
        defer self.allocator.free(map_items);

        map_items[0] = .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = opts.rows } };
        map_items[1] = .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = opts.cols } };
        map_items[2] = .{ .key = .{ .string = "attach" }, .value = .{ .boolean = opts.attach } };

        const params = msgpack.Value{ .map = map_items };
        const msg = try msgpack.encode(self.allocator, .{ 0, msgid, "spawn_pty", params });
        defer self.allocator.free(msg);

        try self.sendDirect(msg);
    }
};

test "ClientLogic - encodeEvent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Ctrl+C
    {
        const event = vaxis.Event{
            .key_press = .{
                .codepoint = 'c',
                .mods = .{ .ctrl = true },
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(1, val.array.len);
        try testing.expectEqualStrings("quit", val.array[0].string);
    }

    // Test Key Press
    {
        const event = vaxis.Event{
            .key_press = .{
                .codepoint = 'a',
                .mods = .{},
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(2, val.array.len);
        try testing.expectEqualStrings("key", val.array[0].string);
        try testing.expectEqual(std.meta.Tag(msgpack.Value).map, std.meta.activeTag(val.array[1]));
    }

    // Test Resize
    {
        const event = vaxis.Event{
            .winsize = .{
                .rows = 24,
                .cols = 80,
                .x_pixel = 0,
                .y_pixel = 0,
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(3, val.array.len);
        try testing.expectEqualStrings("resize", val.array[0].string);
        try testing.expectEqual(24, val.array[1].unsigned);
        try testing.expectEqual(80, val.array[2].unsigned);
    }
}

test "ClientLogic - processServerMessage" {
    const testing = std.testing;
    // const allocator = testing.allocator; // Unused in this test

    // Test PTY spawn response (integer)
    {
        var state = ClientState.init();
        const msg = rpc.Message{
            .response = .{
                .msgid = 1,
                .err = null,
                .result = .{ .integer = 123 },
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.response_received);
        try testing.expectEqual(123, state.pty_id.?);
        try testing.expectEqual(std.meta.Tag(ServerAction).send_attach, std.meta.activeTag(action));
        try testing.expectEqual(123, action.send_attach);
    }

    // Test Attach response (already have pty_id)
    {
        var state = ClientState.init();
        state.pty_id = 123;
        const msg = rpc.Message{
            .response = .{
                .msgid = 2,
                .err = null,
                .result = .{ .integer = 123 }, // Result of attach is typically success/pty_id
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.attached);
        try testing.expectEqual(std.meta.Tag(ServerAction).attached, std.meta.activeTag(action));
    }

    // Test Redraw Notification
    {
        var state = ClientState.init();
        // Params: [events...]
        const params = msgpack.Value{ .array = &[_]msgpack.Value{} };
        const msg = rpc.Message{
            .notification = .{
                .method = "redraw",
                .params = params,
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expectEqual(std.meta.Tag(ServerAction).redraw, std.meta.activeTag(action));
    }
}

test "ClientLogic - processPipeMessage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Quit
    {
        var state = ClientState.init();
        const encoded = try msgpack.encode(allocator, .{"quit"});
        defer allocator.free(encoded);

        const quit_val = try msgpack.decode(allocator, encoded);
        defer quit_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, quit_val);
        try testing.expect(state.should_quit);
        try testing.expectEqual(std.meta.Tag(PipeAction).quit, std.meta.activeTag(action));
    }

    // Test Key Input
    {
        var state = ClientState.init();
        state.attached = true;
        state.pty_id = 123;

        // Create a proper msgpack map value
        var key_map_kv = try allocator.alloc(msgpack.Value.KeyValue, 5);
        key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = "a" } };
        key_map_kv[1] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = false } };
        key_map_kv[2] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = false } };
        key_map_kv[3] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = false } };
        key_map_kv[4] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = false } };

        const key_map_val = msgpack.Value{ .map = key_map_kv };
        var arr = try allocator.alloc(msgpack.Value, 2);
        arr[0] = .{ .string = "key" };
        arr[1] = key_map_val;
        const encoded = try msgpack.encodeFromValue(allocator, msgpack.Value{ .array = arr });
        defer allocator.free(encoded);

        const key_val = try msgpack.decode(allocator, encoded);
        defer key_val.deinit(allocator);
        defer allocator.free(arr);
        defer allocator.free(key_map_kv);

        const action = try ClientLogic.processPipeMessage(&state, key_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_key, std.meta.activeTag(action));
        try testing.expect(action.send_key == .map);
    }

    // Test Resize
    {
        var state = ClientState.init();

        const encoded = try msgpack.encode(allocator, .{ "resize", 24, 80 });
        defer allocator.free(encoded);

        const resize_val = try msgpack.decode(allocator, encoded);
        defer resize_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, resize_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_resize, std.meta.activeTag(action));
        try testing.expectEqual(24, action.send_resize.rows);
        try testing.expectEqual(80, action.send_resize.cols);
    }
}

test "ClientLogic - shouldFlush" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with flush event
    {
        const flush_event = try msgpack.encode(allocator, .{"flush"});
        defer allocator.free(flush_event);

        const flush_val = try msgpack.decode(allocator, flush_event);
        defer flush_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = flush_val;

        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(ClientLogic.shouldFlush(params));
    }

    // Test without flush event
    {
        const other_event = try msgpack.encode(allocator, .{"other"});
        defer allocator.free(other_event);

        const other_val = try msgpack.decode(allocator, other_event);
        defer other_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = other_val;

        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }

    // Test empty events
    {
        const events = try allocator.alloc(msgpack.Value, 0);
        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }
}

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
