const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const pty = @import("pty.zig");
const key_parse = @import("key_parse.zig");
const key_encode = @import("key_encode.zig");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const vt_handler = @import("vt_handler.zig");

const Pty = struct {
    id: usize,
    process: pty.Process,
    clients: std.ArrayList(*Client),
    read_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    keep_alive: bool = false,
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,

    // Synchronization for terminal access
    terminal_mutex: std.Thread.Mutex = .{},
    // Dirty signaling
    pipe_fds: [2]posix.fd_t,
    dirty_signal_buf: [1]u8 = undefined,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,

    // Pointer to server for callbacks (opaque to avoid circular type dependency)
    server_ptr: *anyopaque = undefined,

    fn init(allocator: std.mem.Allocator, id: usize, process_instance: pty.Process, size: pty.winsize) !*Pty {
        const instance = try allocator.create(Pty);
        const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

        instance.* = .{
            .id = id,
            .process = process_instance,
            .clients = std.ArrayList(*Client).empty,
            .running = std.atomic.Value(bool).init(true),
            .terminal = try ghostty_vt.Terminal.init(allocator, .{
                .cols = size.ws_col,
                .rows = size.ws_row,
            }),
            .allocator = allocator,
            .pipe_fds = pipe_fds,
        };
        return instance;
    }

    fn deinit(self: *Pty, allocator: std.mem.Allocator, loop: *io.Loop) void {
        self.running.store(false, .seq_cst);

        // Kill the PTY process
        _ = posix.kill(self.process.pid, posix.SIG.HUP) catch {};

        if (self.read_thread) |thread| {
            thread.join();
        }
        self.process.close();

        // Cancel any pending render timer
        if (self.render_timer) |*task| {
            task.cancel(loop) catch {};
            self.render_timer = null;
        }

        posix.close(self.pipe_fds[0]);
        posix.close(self.pipe_fds[1]);
        self.terminal.deinit(allocator);
        self.clients.deinit(allocator);
        allocator.destroy(self);
    }

    fn addClient(self: *Pty, allocator: std.mem.Allocator, client: *Client) !void {
        try self.clients.append(allocator, client);
    }

    fn removeClient(self: *Pty, client: *Client) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    // Removed broadcast - we'll send msgpack-RPC redraw notifications instead

    fn readThread(self: *Pty, server: *Server) void {
        _ = server;
        var buffer: [4096]u8 = undefined;

        var handler = vt_handler.Handler.init(&self.terminal);
        defer handler.deinit();

        // Set up the write callback so the handler can respond to queries
        handler.setWriteCallback(self, struct {
            fn writeToPty(ctx: ?*anyopaque, data: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                _ = posix.write(pty_inst.process.master, data) catch |err| {
                    std.log.err("Failed to write to PTY: {}", .{err});
                    return err;
                };
            }
        }.writeToPty);

        var stream = vt_handler.Stream.initAlloc(self.allocator, handler);
        defer stream.deinit();

        while (self.running.load(.seq_cst)) {
            const n = posix.read(self.process.master, &buffer) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("PTY read error: {}", .{err});
                break;
            };
            if (n == 0) break;

            // Lock mutex and update terminal state
            self.terminal_mutex.lock();
            defer self.terminal_mutex.unlock();

            // Parse the data through ghostty-vt to update terminal state
            stream.nextSlice(buffer[0..n]) catch |err| {
                std.log.err("Failed to parse VT sequences: {}", .{err});
                continue;
            };

            // Notify main thread by writing to pipe
            // Ignore EAGAIN (pipe full means already dirty)
            if (!self.terminal.modes.get(.synchronized_output)) {
                _ = posix.write(self.pipe_fds[1], "x") catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.err("Failed to signal dirty: {}", .{err});
                    }
                };
            }
        }
        std.log.info("PTY read thread exiting for session {}", .{self.id});

        // Reap the child process
        const result = posix.waitpid(self.process.pid, 0);
        std.log.info("Session {} PTY process {} exited with status {}", .{ self.id, self.process.pid, result.status });
    }
};

/// Captured screen state for building redraw notifications
const ScreenState = struct {
    rows: usize,
    cols: usize,
    cursor_x: usize,
    cursor_y: usize,
    rows_data: []DirtyRow,
    allocator: std.mem.Allocator,

    pub const RenderMode = enum { full, incremental };

    pub const DirtyRow = struct {
        y: usize,
        cells: []CellData,
    };

    const CellData = struct {
        text: []const u8, // UTF-8 encoded
        style_id: u16,
        wide: bool, // true if this cell is wide (occupies 2 columns)
    };

    fn init(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, mutex: *std.Thread.Mutex, mode: RenderMode) !ScreenState {
        mutex.lock();
        defer mutex.unlock();

        const screen = terminal.screens.active;
        const page = &screen.cursor.page_pin.node.data;

        const rows = page.size.rows;
        const cols = page.size.cols;

        var rows_data = std.ArrayList(DirtyRow).empty;
        errdefer {
            for (rows_data.items) |row| {
                for (row.cells) |cell| {
                    allocator.free(cell.text);
                }
                allocator.free(row.cells);
            }
            rows_data.deinit(allocator);
        }

        var utf8_buf: [4]u8 = undefined;
        var grapheme_buf: [32]u21 = undefined;

        // Helper to capture a single row
        const capture_row = struct {
            fn call(
                alloc: std.mem.Allocator,
                p: anytype,
                y: usize,
                width: usize,
                u_buf: *[4]u8,
                g_buf: *[32]u21,
            ) ![]CellData {
                const row = p.getRow(y);
                const row_cells = p.getCells(row);
                var cells = try alloc.alloc(CellData, width);
                errdefer alloc.free(cells);

                var x: usize = 0;
                while (x < width) : (x += 1) {
                    const cell = &row_cells[x];

                    // Skip spacer tails (second half of wide chars)
                    if (cell.wide == .spacer_tail) {
                        cells[x] = .{
                            .text = try alloc.dupe(u8, ""),
                            .style_id = 0,
                            .wide = false,
                        };
                        continue;
                    }

                    // Extract text
                    var text: []const u8 = "";
                    var cluster: []const u21 = &[_]u21{};

                    switch (cell.content_tag) {
                        .codepoint => {
                            if (cell.content.codepoint != 0) {
                                cluster = g_buf[0..1];
                                g_buf[0] = cell.content.codepoint;
                            }
                        },
                        .codepoint_grapheme => {
                            g_buf[0] = cell.content.codepoint;
                            var len: usize = 1;
                            if (p.lookupGrapheme(cell)) |extra| {
                                for (extra) |cp| {
                                    if (len >= g_buf.len) break;
                                    g_buf[len] = cp;
                                    len += 1;
                                }
                            }
                            cluster = g_buf[0..len];
                        },
                        .bg_color_palette, .bg_color_rgb => {
                            cluster = &[_]u21{' '};
                        },
                    }

                    if (cluster.len > 0) {
                        var utf8_list = std.ArrayList(u8).empty;
                        defer utf8_list.deinit(alloc);
                        for (cluster) |cp| {
                            const len = std.unicode.utf8Encode(cp, u_buf) catch continue;
                            try utf8_list.appendSlice(alloc, u_buf[0..len]);
                        }
                        text = try utf8_list.toOwnedSlice(alloc);
                    } else {
                        text = try alloc.dupe(u8, " ");
                    }

                    cells[x] = .{
                        .text = text,
                        .style_id = cell.style_id,
                        .wide = cell.wide == .wide,
                    };
                }
                return cells;
            }
        };

        // Determine which rows to capture
        // If full mode or screen dirty, capture all.
        // Note: screen.dirty is a bitset of dirty flags (not rows)
        var capture_all = (mode == .full);

        // Check if we can access screen.dirty
        // Assuming screen.dirty is available and has typical bitset/struct methods.
        // If screen has changed (resize, scroll, etc), we should redraw all.
        if (!std.meta.eql(screen.dirty, .{})) {
            capture_all = true;
        }

        if (capture_all) {
            for (0..rows) |y| {
                const cells = try capture_row.call(allocator, page, y, cols, &utf8_buf, &grapheme_buf);
                try rows_data.append(allocator, .{ .y = y, .cells = cells });
            }

            if (mode == .incremental) {
                // Clear all dirty flags
                screen.dirty = .{};
                var ds = page.dirtyBitSet();
                ds.unsetAll();
            }
        } else {
            // Incremental update
            var ds = page.dirtyBitSet();
            var it = ds.iterator(.{});
            while (it.next()) |y| {
                if (y >= rows) continue;
                const cells = try capture_row.call(allocator, page, y, cols, &utf8_buf, &grapheme_buf);
                try rows_data.append(allocator, .{ .y = y, .cells = cells });
            }
            ds.unsetAll();
        }

        return .{
            .rows = rows,
            .cols = cols,
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .rows_data = try rows_data.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ScreenState) void {
        for (self.rows_data) |row| {
            for (row.cells) |cell| {
                self.allocator.free(cell.text);
            }
            self.allocator.free(row.cells);
        }
        self.allocator.free(self.rows_data);
    }
};

const Client = struct {
    fd: posix.fd_t,
    server: *Server,
    recv_buffer: [4096]u8 = undefined,
    send_buffer: ?[]u8 = null,
    attached_sessions: std.ArrayList(usize),
    seen_styles: std.AutoHashMap(u16, void),

    fn sendData(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const buf = try self.server.allocator.dupe(u8, data);
        self.send_buffer = buf;
        _ = try loop.send(self.fd, buf, .{
            .ptr = self,
            .cb = onSendComplete,
        });
    }

    fn onSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        // Free send buffer
        if (client.send_buffer) |buf| {
            client.server.allocator.free(buf);
            client.send_buffer = null;
        }

        switch (completion.result) {
            .send => {},
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn handleMessage(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const msg = try rpc.decodeMessage(self.server.allocator, data);
        defer msg.deinit(self.server.allocator);

        switch (msg) {
            .request => |req| {
                // std.log.info("Got request: msgid={} method={s}", .{ req.msgid, req.method });

                // Dispatch to handler
                const result = try self.server.handleRequest(self, req.method, req.params);
                defer result.deinit(self.server.allocator);

                // Send response: [1, msgid, error, result]
                // Build response array manually since we have a Value
                const response_arr = try self.server.allocator.alloc(msgpack.Value, 4);
                defer self.server.allocator.free(response_arr);
                response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type
                response_arr[1] = msgpack.Value{ .unsigned = req.msgid }; // msgid
                response_arr[2] = msgpack.Value.nil; // no error
                response_arr[3] = result; // result

                const response_value = msgpack.Value{ .array = response_arr };
                self.send_buffer = try msgpack.encodeFromValue(self.server.allocator, response_value);

                _ = try loop.send(self.fd, self.send_buffer.?, .{
                    .ptr = self,
                    .cb = onSendComplete,
                });
            },
            .notification => |notif| {
                // Handle notifications (no response needed)
                if (std.mem.eql(u8, notif.method, "write_pty")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("write_pty notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const input_data = if (notif.params.array[1] == .binary)
                            notif.params.array[1].binary
                        else if (notif.params.array[1] == .string)
                            notif.params.array[1].string
                        else {
                            std.log.warn("write_pty notification: invalid data type", .{});
                            return;
                        };

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            _ = posix.write(pty_instance.process.master, input_data) catch |err| {
                                std.log.err("Write to PTY failed: {}", .{err});
                            };
                        } else {
                            std.log.warn("write_pty notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("write_pty notification: invalid params", .{});
                    }
                } else if (std.mem.eql(u8, notif.method, "key_input")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("key_input notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const notation = if (notif.params.array[1] == .string)
                            notif.params.array[1].string
                        else {
                            std.log.warn("key_input notification: invalid notation type", .{});
                            return;
                        };

                        std.log.debug("Received key_input: session={} notation='{s}'", .{ session_id, notation });

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            // Parse Neovim key notation to ghostty key
                            const key = key_parse.parseKeyNotation(notation) catch |err| {
                                std.log.err("Failed to parse key notation '{s}': {}", .{ notation, err });
                                return;
                            };

                            std.log.debug("Parsed key: key={} mods=(shift={} ctrl={} alt={})", .{
                                key.key,
                                key.mods.shift,
                                key.mods.ctrl,
                                key.mods.alt,
                            });

                            // Encode key using terminal state
                            var encode_buf: [32]u8 = undefined;
                            var stream = std.io.fixedBufferStream(&encode_buf);
                            const writer = stream.writer();

                            pty_instance.terminal_mutex.lock();
                            key_encode.encode(writer, key, &pty_instance.terminal) catch |err| {
                                std.log.err("Failed to encode key: {}", .{err});
                                pty_instance.terminal_mutex.unlock();
                                return;
                            };
                            pty_instance.terminal_mutex.unlock();

                            const encoded = stream.getWritten();
                            std.log.debug("Encoded key to {} bytes: {any}", .{ encoded.len, encoded });

                            if (encoded.len > 0) {
                                _ = posix.write(pty_instance.process.master, encoded) catch |err| {
                                    std.log.err("Write to PTY failed: {}", .{err});
                                };
                            }
                        } else {
                            std.log.warn("key_input notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("key_input notification: invalid params", .{});
                    }
                } else if (std.mem.eql(u8, notif.method, "resize_pty")) {
                    if (notif.params == .array and notif.params.array.len >= 3) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const rows: u16 = switch (notif.params.array[1]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid rows type", .{});
                                return;
                            },
                        };
                        const cols: u16 = switch (notif.params.array[2]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid cols type", .{});
                                return;
                            },
                        };

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            const size: pty.winsize = .{
                                .ws_row = rows,
                                .ws_col = cols,
                                .ws_xpixel = 0,
                                .ws_ypixel = 0,
                            };
                            var pty_mut = pty_instance.process;
                            pty_mut.setSize(size) catch |err| {
                                std.log.err("Resize PTY failed: {}", .{err});
                            };

                            // Also resize the terminal state
                            pty_instance.terminal_mutex.lock();
                            pty_instance.terminal.resize(
                                pty_instance.allocator,
                                cols,
                                rows,
                            ) catch |err| {
                                std.log.err("Resize terminal failed: {}", .{err});
                            };
                            pty_instance.terminal_mutex.unlock();

                            std.log.info("Resized session {} to {}x{}", .{ session_id, rows, cols });
                        } else {
                            std.log.warn("resize_pty notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("resize_pty notification: invalid params", .{});
                    }
                }
            },
            .response => {
                // std.log.warn("Client sent response, ignoring", .{});
            },
        }
    }

    fn onRecv(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    // EOF - client disconnected
                    std.log.debug("Client fd={} disconnected (EOF)", .{client.fd});
                    client.server.removeClient(client);
                } else {
                    std.log.debug("Received {} bytes from client fd={}", .{ bytes_read, client.fd });
                    // Got data, try to parse as RPC message
                    const data = client.recv_buffer[0..bytes_read];
                    client.handleMessage(loop, data) catch |err| {
                        std.log.err("Failed to handle message: {}", .{err});
                    };

                    // Keep receiving
                    _ = try loop.recv(client.fd, &client.recv_buffer, .{
                        .ptr = client,
                        .cb = onRecv,
                    });
                }
            },
            .err => {
                std.log.debug("Client fd={} disconnected (error)", .{client.fd});
                client.server.removeClient(client);
            },
            else => unreachable,
        }
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    clients: std.ArrayList(*Client),
    ptys: std.AutoHashMap(usize, *Pty),
    next_session_id: usize = 0,
    accepting: bool = true,
    accept_task: ?io.Task = null,

    fn handleRequest(self: *Server, client: *Client, method: []const u8, params: msgpack.Value) !msgpack.Value {
        if (std.mem.eql(u8, method, "ping")) {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "pong") };
        } else if (std.mem.eql(u8, method, "spawn_pty")) {
            const size: pty.winsize = .{
                .ws_row = if (params == .array and params.array.len > 0 and params.array[0] == .unsigned)
                    @intCast(params.array[0].unsigned)
                else
                    24,
                .ws_col = if (params == .array and params.array.len > 1 and params.array[1] == .unsigned)
                    @intCast(params.array[1].unsigned)
                else
                    80,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const process = try pty.Process.spawn(self.allocator, size, &.{shell}, null);

            const session_id = self.next_session_id;
            self.next_session_id += 1;

            const pty_instance = try Pty.init(self.allocator, session_id, process, size);
            pty_instance.server_ptr = self;

            try self.ptys.put(session_id, pty_instance);

            pty_instance.read_thread = try std.Thread.spawn(.{}, Pty.readThread, .{ pty_instance, self });

            // Register dirty signal pipe
            _ = try self.loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
                .ptr = pty_instance,
                .cb = onPtyDirty,
            });

            std.log.info("Created session {} with PID {}", .{ session_id, process.pid });

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "attach_pty")) {
            std.log.info("attach_pty called with params: {}", .{params});
            if (params != .array or params.array.len < 1 or params.array[0] != .unsigned) {
                std.log.warn("attach_pty: invalid params", .{});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);

            std.log.info("attach_pty: session_id={} client_fd={}", .{ session_id, client.fd });

            const pty_instance = self.ptys.get(session_id) orelse {
                std.log.warn("attach_pty: session {} not found", .{session_id});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            try pty_instance.addClient(self.allocator, client);
            try client.attached_sessions.append(self.allocator, session_id);
            std.log.info("Client {} attached to session {}", .{ client.fd, session_id });

            // Send full redraw to the newly attached client
            var state = try ScreenState.init(
                self.allocator,
                &pty_instance.terminal,
                &pty_instance.terminal_mutex,
                .full,
            );
            defer state.deinit();

            try self.sendRedraw(self.loop, pty_instance, &state, client);

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "write_pty")) {
            if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .binary) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const data = params.array[1].binary;

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            _ = posix.write(pty_instance.process.master, data) catch |err| {
                std.log.err("Write to PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "write failed") };
            };

            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "resize_pty")) {
            if (params != .array or params.array.len < 3 or params.array[0] != .unsigned or params.array[1] != .unsigned or params.array[2] != .unsigned) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const rows: u16 = @intCast(params.array[1].unsigned);
            const cols: u16 = @intCast(params.array[2].unsigned);

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            const size: pty.winsize = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            var pty_mut = pty_instance.process;
            pty_mut.setSize(size) catch |err| {
                std.log.err("Resize PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "resize failed") };
            };

            // Also resize the terminal state
            pty_instance.terminal_mutex.lock();
            pty_instance.terminal.resize(
                pty_instance.allocator,
                cols,
                rows,
            ) catch |err| {
                std.log.err("Resize terminal failed: {}", .{err});
            };
            pty_instance.terminal_mutex.unlock();

            std.log.info("Resized session {} to {}x{}", .{ session_id, rows, cols });
            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "detach_pty")) {
            if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .unsigned) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const client_fd: posix.fd_t = @intCast(params.array[1].unsigned);

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            // Mark session as keep_alive since client explicitly detached
            pty_instance.keep_alive = true;

            // Find client by fd and detach
            for (self.clients.items) |c| {
                if (c.fd == client_fd) {
                    pty_instance.removeClient(c);
                    for (c.attached_sessions.items, 0..) |sid, i| {
                        if (sid == session_id) {
                            _ = c.attached_sessions.swapRemove(i);
                            break;
                        }
                    }
                    std.log.info("Client {} detached from session {} (marked keep_alive)", .{ c.fd, session_id });
                    break;
                }
            }

            return msgpack.Value.nil;
        } else {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "unknown method") };
        }
    }

    fn shouldExit(self: *Server) bool {
        _ = self;
        return false;
    }

    fn cleanupSessionsForClient(self: *Server, client: *Client) void {
        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.allocator);

        for (client.attached_sessions.items) |session_id| {
            if (self.ptys.get(session_id)) |pty_instance| {
                pty_instance.removeClient(client);
                std.log.info("Auto-removed client {} from session {}", .{ client.fd, session_id });

                // If no more clients attached and not marked keep_alive, kill the session
                if (pty_instance.clients.items.len == 0 and !pty_instance.keep_alive) {
                    to_remove.append(self.allocator, session_id) catch {};
                }
            }
        }

        // Also cleanup any orphaned sessions with no clients and not keep_alive
        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            const pty_instance = entry.value_ptr.*;
            if (pty_instance.clients.items.len == 0 and !pty_instance.keep_alive) {
                to_remove.append(self.allocator, pty_instance.id) catch {};
            }
        }

        for (to_remove.items) |session_id| {
            if (self.ptys.fetchRemove(session_id)) |kv| {
                std.log.info("Killing session {} (no clients, not keep_alive)", .{session_id});
                kv.value.deinit(self.allocator, self.loop);
            }
        }
    }

    fn checkExit(self: *Server) !void {
        if (self.shouldExit() and self.accepting) {
            self.accepting = false;
            if (self.accept_task) |*task| {
                try task.cancel(self.loop);
                self.accept_task = null;
            }
        }
    }

    fn onAccept(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .accept => |client_fd| {
                std.log.debug("Accepted client connection fd={}", .{client_fd});
                const client = try self.allocator.create(Client);
                client.* = .{
                    .fd = client_fd,
                    .server = self,
                    .attached_sessions = std.ArrayList(usize).empty,
                    .seen_styles = std.AutoHashMap(u16, void).init(self.allocator),
                };
                try self.clients.append(self.allocator, client);
                std.log.debug("Total clients: {}", .{self.clients.items.len});

                // Start recv to detect disconnect
                _ = try loop.recv(client_fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = Client.onRecv,
                });

                // Queue next accept if still accepting
                if (self.accepting) {
                    self.accept_task = try loop.accept(self.listen_fd, .{
                        .ptr = self,
                        .cb = onAccept,
                    });
                }
            },
            .err => |err| {
                std.log.err("Accept error: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        std.log.debug("Removing client fd={}", .{client.fd});
        // Cleanup sessions (kill if no clients remain and not keep_alive)
        self.cleanupSessionsForClient(client);
        client.attached_sessions.deinit(self.allocator);
        client.seen_styles.deinit();

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        _ = self.loop.close(client.fd, .{
            .ptr = null,
            .cb = struct {
                fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
            }.noop,
        }) catch {};
        self.allocator.destroy(client);
        std.log.debug("Total clients: {}", .{self.clients.items.len});
        self.checkExit() catch {};
    }

    /// Convert ghostty style to Neovim HlAttrs format
    fn convertStyle(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, style_id: u16) !@import("redraw.zig").UIEvent.HlAttrDefine.HlAttrs {
        _ = allocator;
        const redraw = @import("redraw.zig");

        if (style_id == 0) {
            // Default style - return empty attrs
            return .{};
        }

        const screen = terminal.screens.active;
        const page = &screen.cursor.page_pin.node.data;
        const style = page.styles.get(page.memory, style_id);

        var attrs: redraw.UIEvent.HlAttrDefine.HlAttrs = .{};

        // Convert foreground color
        switch (style.fg_color) {
            .none => {},
            .palette => |idx| {
                // Send palette index directly
                attrs.foreground = idx;
            },
            .rgb => |rgb| {
                attrs.foreground = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
            },
        }

        // Convert background color
        switch (style.bg_color) {
            .none => {},
            .palette => |idx| {
                attrs.background = idx;
            },
            .rgb => |rgb| {
                attrs.background = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
            },
        }

        // Convert underline color
        switch (style.underline_color) {
            .none => {},
            .palette => |idx| {
                _ = idx;
            },
            .rgb => |rgb| {
                attrs.special = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
            },
        }

        // Convert flags
        attrs.bold = style.flags.bold;
        attrs.italic = style.flags.italic;
        attrs.reverse = style.flags.inverse;
        attrs.strikethrough = style.flags.strikethrough;

        // Handle underline variants
        attrs.underline = switch (style.flags.underline) {
            .none => false,
            .single => true,
            else => true, // double, curly, dotted, dashed all map to underline=true
        };

        return attrs;
    }

    /// Build and send redraw notification for a session to attached clients
    fn sendRedraw(self: *Server, loop: *io.Loop, pty_instance: *Pty, state: *ScreenState, target_client: ?*Client) !void {
        const redraw = @import("redraw.zig");

        // Send to each client attached to this session
        for (self.clients.items) |client| {
            // If we have a target client, skip others
            if (target_client) |target| {
                if (client != target) continue;
            }

            // Check if client is attached to this session
            var attached = false;
            for (client.attached_sessions.items) |sid| {
                if (sid == pty_instance.id) {
                    attached = true;
                    break;
                }
            }
            if (!attached) {
                continue;
            }

            var builder = redraw.RedrawBuilder.init(self.allocator);
            defer builder.deinit();

            // Send grid_resize if needed (always send for simplicity now)
            try builder.gridResize(1, @intCast(state.cols), @intCast(state.rows));

            // Track which styles we need to define
            var styles_to_define = std.ArrayList(u16).empty;
            defer styles_to_define.deinit(self.allocator);

            // Scan all cells to find styles we haven't sent
            for (state.rows_data) |row| {
                for (row.cells) |cell| {
                    if (cell.style_id != 0 and !client.seen_styles.contains(cell.style_id)) {
                        try styles_to_define.append(self.allocator, cell.style_id);
                        try client.seen_styles.put(cell.style_id, {});
                    }
                }
            }

            // Define new styles
            for (styles_to_define.items) |style_id| {
                pty_instance.terminal_mutex.lock();
                const attrs = try convertStyle(self.allocator, &pty_instance.terminal, style_id);
                pty_instance.terminal_mutex.unlock();

                try builder.hlAttrDefine(style_id, attrs, attrs);
            }

            // Build grid_line events for each dirty row
            for (state.rows_data) |row| {
                var cells_buf = std.ArrayList(redraw.UIEvent.GridLine.Cell).empty;
                defer cells_buf.deinit(self.allocator);

                var x: usize = 0;
                while (x < state.cols) {
                    if (x >= row.cells.len) break;
                    const cell = &row.cells[x];

                    // Skip empty spacer tails
                    if (cell.text.len == 0) {
                        x += 1;
                        continue;
                    }

                    // Count consecutive cells with same style
                    var repeat: usize = 1;
                    var next_x = x + 1;
                    if (cell.wide) next_x += 1; // Skip spacer for wide char

                    while (next_x < state.cols and next_x < row.cells.len) {
                        const next_cell = &row.cells[next_x];
                        if (next_cell.style_id != cell.style_id) break;
                        if (!std.mem.eql(u8, next_cell.text, cell.text)) break;
                        if (next_cell.text.len == 0) break; // Skip spacers

                        repeat += 1;
                        next_x += 1;
                        if (next_cell.wide) next_x += 1;
                    }

                    try cells_buf.append(self.allocator, .{
                        .text = cell.text,
                        .hl_id = if (cell.style_id == 0) null else cell.style_id,
                        .repeat = if (repeat > 1) @intCast(repeat) else null,
                    });

                    x = next_x;
                }

                if (cells_buf.items.len > 0) {
                    try builder.gridLine(1, @intCast(row.y), 0, cells_buf.items, false);
                }
            }

            // Send cursor position
            try builder.gridCursorGoto(1, @intCast(state.cursor_y), @intCast(state.cursor_x));

            // Flush
            try builder.flush();

            // Build and send the notification
            const msg = try builder.build();
            defer self.allocator.free(msg);

            try client.sendData(loop, msg);
        }
    }

    fn renderFrame(self: *Server, pty_instance: *Pty) void {
        // Copy screen state under mutex
        var state = ScreenState.init(
            self.allocator,
            &pty_instance.terminal,
            &pty_instance.terminal_mutex,
            .incremental,
        ) catch |err| {
            std.log.err("Failed to copy screen state for session {}: {}", .{ pty_instance.id, err });
            return;
        };
        defer state.deinit();

        // Build and send redraw notifications
        self.sendRedraw(self.loop, pty_instance, &state, null) catch |err| {
            std.log.err("Failed to send redraw for session {}: {}", .{ pty_instance.id, err });
        };

        // Update timestamp
        pty_instance.last_render_time = std.time.milliTimestamp();
    }

    fn onRenderTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const pty_instance = completion.userdataCast(Pty);
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));
        server.renderFrame(pty_instance);
        pty_instance.render_timer = null;
    }

    fn onPtyDirty(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const pty_instance = completion.userdataCast(Pty);
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));

        switch (completion.result) {
            .read => |n| {
                if (n == 0) return;

                // Drain pipe
                var buf: [128]u8 = undefined;
                while (true) {
                    _ = posix.read(pty_instance.pipe_fds[0], &buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        break;
                    };
                }

                const now = std.time.milliTimestamp();
                const FRAME_TIME = 8;

                if (now - pty_instance.last_render_time >= FRAME_TIME) {
                    server.renderFrame(pty_instance);
                } else if (pty_instance.render_timer == null) {
                    const delay = FRAME_TIME - (now - pty_instance.last_render_time);
                    // Make sure delay is positive
                    const safe_delay = if (delay < 0) 0 else delay;
                    pty_instance.render_timer = try loop.timeout(@as(u64, @intCast(safe_delay)) * std.time.ns_per_ms, .{
                        .ptr = pty_instance,
                        .cb = onRenderTimer,
                    });
                }

                // Re-arm
                _ = try loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
                    .ptr = pty_instance,
                    .cb = onPtyDirty,
                });
            },
            .err => |err| {
                std.log.err("Pty dirty pipe error: {}", .{err});
            },
            else => {},
        }
    }
};

pub fn startServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Starting server on {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    // Check if socket exists and if a server is already running
    if (std.fs.accessAbsolute(socket_path, .{})) {
        // Socket exists - test if server is alive
        const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            std.log.err("Failed to create test socket: {}", .{err});
            return err;
        };
        defer posix.close(test_fd);

        var addr: posix.sockaddr.un = undefined;
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        addr.path[socket_path.len] = 0;

        if (posix.connect(test_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) {
            // Connection succeeded - server is already running
            std.log.err("Server is already running on {s}", .{socket_path});
            return error.AddressInUse;
        } else |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                // Stale socket
                std.log.info("Removing stale socket", .{});
                posix.unlink(socket_path) catch {};
            } else {
                std.log.err("Failed to test socket: {}", .{err});
                return err;
            }
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
        // Socket doesn't exist, continue
    }

    // Create socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(listen_fd);

    // Bind to socket path
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Listen
    try posix.listen(listen_fd, 128);

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
    };
    defer {
        for (server.clients.items) |client| {
            posix.close(client.fd);
            client.attached_sessions.deinit(allocator);
            client.seen_styles.deinit();
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        var it = server.ptys.valueIterator();
        while (it.next()) |pty_instance| {
            pty_instance.*.deinit(allocator, &loop);
        }
        server.ptys.deinit();
    }

    // Start accepting connections
    server.accept_task = try loop.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Run until server decides to exit
    try loop.run(.until_done);

    // Cleanup
    posix.close(listen_fd);
    posix.unlink(socket_path) catch {};
}

test "server lifecycle - shutdown when no clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
    };
    defer server.clients.deinit(testing.allocator);
    defer server.ptys.deinit();

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try testing.expect(server.accepting);
    try testing.expect(server.shouldExit());

    try server.checkExit();

    try testing.expect(!server.accepting);
    try testing.expect(server.accept_task == null);
}

test "server lifecycle - accept client connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    try testing.expect(server.accepting);
}

test "server lifecycle - client disconnect triggers shutdown" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeRecv(client_fd, "");
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - multiple clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 3), server.clients.items.len);

    const client1_fd = server.clients.items[0].fd;
    const client2_fd = server.clients.items[1].fd;
    const client3_fd = server.clients.items[2].fd;

    try loop.completeRecv(client2_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeRecv(client1_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeRecv(client3_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - recv error triggers disconnect" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeWithError(client_fd, error.ConnectionReset);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}
