const std = @import("std");
const vaxis = @import("vaxis");
const msgpack = @import("msgpack.zig");

const Surface = @This();

front: *vaxis.Screen,
back: *vaxis.Screen,
allocator: std.mem.Allocator,
rows: u16,
cols: u16,
dirty: bool = false,
hl_attrs: std.AutoHashMap(u32, vaxis.Style),
grapheme_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Surface {
    const front = try allocator.create(vaxis.Screen);
    errdefer allocator.destroy(front);

    const back = try allocator.create(vaxis.Screen);
    errdefer allocator.destroy(back);

    const winsize: vaxis.Winsize = .{
        .rows = rows,
        .cols = cols,
        .x_pixel = 0,
        .y_pixel = 0,
    };

    front.* = try vaxis.Screen.init(allocator, winsize);
    errdefer front.deinit(allocator);

    back.* = try vaxis.Screen.init(allocator, winsize);

    return .{
        .front = front,
        .back = back,
        .allocator = allocator,
        .rows = rows,
        .cols = cols,
        .hl_attrs = std.AutoHashMap(u32, vaxis.Style).init(allocator),
        .grapheme_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Surface) void {
    self.front.deinit(self.allocator);
    self.allocator.destroy(self.front);
    self.back.deinit(self.allocator);
    self.allocator.destroy(self.back);
    self.hl_attrs.deinit();
    self.grapheme_arena.deinit();
}

pub fn resize(self: *Surface, rows: u16, cols: u16) !void {
    // Deinit old screens
    self.front.deinit(self.allocator);
    self.back.deinit(self.allocator);

    const winsize: vaxis.Winsize = .{
        .rows = rows,
        .cols = cols,
        .x_pixel = 0,
        .y_pixel = 0,
    };

    // Reinit with new size
    self.front.* = try vaxis.Screen.init(self.allocator, winsize);
    self.back.* = try vaxis.Screen.init(self.allocator, winsize);

    self.rows = rows;
    self.cols = cols;
    self.dirty = true;
}

pub fn swap(self: *Surface) void {
    if (!self.dirty) return;

    const tmp = self.front;
    self.front = self.back;
    self.back = tmp;

    self.dirty = false;
}

pub fn applyRedraw(self: *Surface, params: msgpack.Value) !void {
    if (params != .array) return error.InvalidRedrawParams;

    // Reset grapheme arena for this frame
    _ = self.grapheme_arena.reset(.retain_capacity);

    for (params.array) |event_val| {
        if (event_val != .array or event_val.array.len < 2) continue;

        const event_name = event_val.array[0];
        if (event_name != .string) continue;

        const event_params = event_val.array[1];
        if (event_params != .array) continue;

        if (std.mem.eql(u8, event_name.string, "grid_resize")) {
            if (event_params.array.len < 3) continue;

            const width = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const height = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            try self.resize(height, width);
        } else if (std.mem.eql(u8, event_name.string, "grid_cursor_goto")) {
            if (event_params.array.len < 3) continue;

            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const col = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            self.back.cursor_row = row;
            self.back.cursor_col = col;
            self.back.cursor_vis = true;
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "grid_line")) {
            if (event_params.array.len < 4) continue;

            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };
            var col = switch (event_params.array[2]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };

            const cells = event_params.array[3];
            if (cells != .array) continue;

            var current_hl: u32 = 0;
            for (cells.array) |cell| {
                if (cell != .array or cell.array.len == 0) continue;

                const text = if (cell.array[0] == .string) cell.array[0].string else " ";

                if (cell.array.len > 1 and cell.array[1] != .nil) {
                    current_hl = switch (cell.array[1]) {
                        .unsigned => |u| @as(u32, @intCast(u)),
                        .integer => |i| @as(u32, @intCast(i)),
                        else => current_hl,
                    };
                }

                const repeat: usize = if (cell.array.len > 2 and cell.array[2] != .nil)
                    switch (cell.array[2]) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => 1,
                    }
                else
                    1;

                const style = self.hl_attrs.get(current_hl) orelse vaxis.Style{};

                var i: usize = 0;
                while (i < repeat) : (i += 1) {
                    if (col < self.cols and row < self.rows) {
                        const copy = self.grapheme_arena.allocator().dupe(u8, text) catch text;
                        self.back.writeCell(@intCast(col), @intCast(row), .{
                            .char = .{ .grapheme = copy },
                            .style = style,
                        });
                    }
                    col += 1;
                }
            }
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "grid_clear")) {
            self.back.clear();
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "hl_attr_define")) {
            if (event_params.array.len < 2) continue;

            const id = switch (event_params.array[0]) {
                .unsigned => |u| @as(u32, @intCast(u)),
                .integer => |i| @as(u32, @intCast(i)),
                else => continue,
            };

            const rgb_attrs = event_params.array[1];
            if (rgb_attrs != .map) continue;

            var style = vaxis.Style{};

            for (rgb_attrs.map) |kv| {
                if (kv.key != .string) continue;

                if (std.mem.eql(u8, kv.key.string, "foreground")) {
                    if (kv.value == .unsigned) {
                        const val = @as(u32, @intCast(kv.value.unsigned));
                        if (val < 256) {
                            style.fg = .{ .index = @intCast(val) };
                        } else {
                            style.fg = .{ .rgb = .{
                                @intCast((val >> 16) & 0xFF),
                                @intCast((val >> 8) & 0xFF),
                                @intCast(val & 0xFF),
                            } };
                        }
                    }
                } else if (std.mem.eql(u8, kv.key.string, "background")) {
                    if (kv.value == .unsigned) {
                        const val = @as(u32, @intCast(kv.value.unsigned));
                        if (val < 256) {
                            style.bg = .{ .index = @intCast(val) };
                        } else {
                            style.bg = .{ .rgb = .{
                                @intCast((val >> 16) & 0xFF),
                                @intCast((val >> 8) & 0xFF),
                                @intCast(val & 0xFF),
                            } };
                        }
                    }
                } else if (std.mem.eql(u8, kv.key.string, "bold")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        style.bold = true;
                    }
                } else if (std.mem.eql(u8, kv.key.string, "italic")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        style.italic = true;
                    }
                } else if (std.mem.eql(u8, kv.key.string, "underline")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        style.ul_style = .single;
                    }
                } else if (std.mem.eql(u8, kv.key.string, "reverse")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        style.reverse = true;
                    }
                }
            }

            try self.hl_attrs.put(id, style);
        } else if (std.mem.eql(u8, event_name.string, "flush")) {
            // Flush marks the end of a frame - caller should swap after this
        }
    }
}

pub fn render(self: *Surface, win: vaxis.Window) void {
    // Copy front buffer to vaxis window
    for (0..self.rows) |row| {
        for (0..self.cols) |col| {
            if (col < win.width and row < win.height) {
                const cell = self.front.readCell(@intCast(col), @intCast(row)) orelse continue;
                win.writeCell(@intCast(col), @intCast(row), cell);
            }
        }
    }

    // Copy cursor state
    if (self.front.cursor_vis and
        self.front.cursor_col < win.width and
        self.front.cursor_row < win.height)
    {
        win.showCursor(self.front.cursor_col, self.front.cursor_row);
    } else {
        win.hideCursor();
    }
}
