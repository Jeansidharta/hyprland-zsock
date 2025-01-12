const std = @import("std");
const utils = @import("./utils.zig");

const log = std.log.scoped(.HyprlandEvents);

const Location = struct { start: usize, len: usize };

const EventParamsIter = struct {
    lastIndex: usize,
    iter: std.mem.SplitIterator(u8, .scalar),

    fn init(
        initialIndex: usize,
        params: []const u8,
    ) EventParamsIter {
        return .{
            .lastIndex = initialIndex,
            .iter = std.mem.splitScalar(u8, params, ','),
        };
    }

    fn next(self: *EventParamsIter) ?Location {
        const str = self.iter.next() orelse return null;
        const start = self.lastIndex;
        self.lastIndex += str.len + 1;
        return .{ .start = start, .len = str.len };
    }
};

pub const HyprlandEventSocket = struct {
    const Self = @This();

    socket: std.os.linux.socket_t,
    buffer: [4 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// Read data from socket, without overflowing the buffer
    /// Caller does **not** own returned slice
    pub fn readFromSocket(self: *Self) ![]u8 {
        const len = try std.posix.read(self.socket, self.buffer[self.end..self.buffer.len]);
        self.end += len;
        return self.buffer[self.start..self.end];
    }

    // Move all data to the start of the buffer
    pub fn flushBuffer(self: *Self) void {
        const start = self.start;
        const end = self.end;
        const len = end - start;
        @memcpy(self.buffer[0..len], self.buffer[start..end]);
    }

    /// Caller does **not** own returned slice
    fn bufData(self: Self) []const u8 {
        return self.buffer[self.start..self.end];
    }

    /// Reads from the socket until a newline is found. Returned slice is
    /// the content of the line, without the newline character.
    ///
    /// Doesn't advance the buffer, therefore consecutive calls will return the same data.
    /// Data is possibly invalidated after any call to `consumeLine` or `consumeEvent`.
    ///
    /// Caller does **not** own returned slice
    pub fn readLine(self: *Self) ![]const u8 {
        while (true) {
            const data = self.bufData();
            const index = std.mem.indexOfScalar(u8, data, '\n') orelse {
                const isBufFull = self.end == self.buffer.len;
                if (isBufFull) {
                    self.flushBuffer();
                }
                _ = try self.readFromSocket();
                continue;
            };
            return data[0..index];
        }
    }

    /// Read from the socket until a newline is found. Returned slice is the content
    /// of the line without the newline character.
    ///
    /// Advances the buffer. Therefore consecutive calls will return different data.
    /// Data is possibly invalidated after any call to `consumeLine` or `consumeEvent`.
    ///
    /// Caller does **not** own returned slice
    pub fn consumeLine(self: *Self) ![]const u8 {
        const line = try self.readLine();
        self.start += line.len + 1; // add one to skip the newline character
        std.debug.assert(self.end >= self.start);
        return line;
    }

    /// Reads from the socket and parses it into a HyprlandEvent object.
    /// Returns a Tuple with the read line, and the parsed event.
    ///
    /// Doesn't advance the buffer, therefore consecutive calls will return the same data.
    /// Data is possibly invalidated after any call to `consumeLine` or `consumeEvent`.
    ///
    /// Caller does **not** own returned slice
    pub fn readEvent(self: *Self) !struct { []const u8, HyprlandEvent } {
        const line = try self.readLine();
        return .{ line, try HyprlandEvent.parse(line) };
    }

    /// Reads from the socket and parses it into a HyprlandEvent object.
    /// Returns a Tuple with the read line, and the parsed event.
    ///
    /// Advances the buffer, therefore consecutive calls will return different data.
    /// Data is possibly invalidated after any call to `consumeLine` or `consumeEvent`.
    ///
    /// Caller does **not** own returned slice
    pub fn consumeEvent(self: *Self) !struct { []const u8, HyprlandEvent } {
        const line = try self.consumeLine();
        return .{ line, try HyprlandEvent.parse(line) };
    }

    pub fn deinit(self: @This()) void {
        std.posix.close(self.socket);
    }

    pub fn open() !Self {
        const socket = try utils.openHyprlandSocket(.eventSocket);
        return .{ .socket = socket };
    }
};

pub const HyprlandEvent = union(enum) {
    const Self = @This();

    workspace: struct {
        workspaceName: Location,
    },
    workspacev2: struct {
        workspaceName: Location,
        workspaceId: Location,
    },
    focusedmon: struct {
        workspaceName: Location,
        monitorName: Location,
    },
    focusedmonv2: struct {
        monitorName: Location,
        workspaceId: Location,
    },
    activewindow: struct {
        windowClass: Location,
        windowTitle: Location,
    },
    activewindowv2: struct {
        windowAddress: Location,
    },
    fullscreen: enum {
        exit,
        enter,
    },
    monitorremoved: struct {
        monitorName: Location,
    },
    monitoradded: struct {
        monitorName: Location,
    },
    monitoraddedv2: struct {
        monitorName: Location,
        monitorId: Location,
        monitorDescription: Location,
    },
    createworkspace: struct {
        workspaceName: Location,
    },
    createworkspacev2: struct {
        workspaceName: Location,
        workspaceId: Location,
    },
    destroyworkspace: struct {
        workspaceName: Location,
    },
    destroyworkspacev2: struct {
        workspaceName: Location,
        workspaceId: Location,
    },
    moveworkspace: struct {
        workspaceName: Location,
        monitorName: Location,
    },
    moveworkspacev2: struct {
        workspaceName: Location,
        monitorName: Location,
        workspaceId: Location,
    },
    renameworkspace: struct {
        workspaceId: Location,
        newName: Location,
    },
    activespecial: struct {
        workspaceName: Location,
        monitorName: Location,
    },
    activelayout: struct {
        keyboardName: Location,
        layoutName: Location,
    },
    openwindow: struct {
        windowAddress: Location,
        workspaceName: Location,
        windowClass: Location,
        windowTitle: Location,
    },
    closewindow: struct {
        windowAddress: Location,
    },
    movewindow: struct {
        windowAddress: Location,
        workspaceName: Location,
    },
    movewindowv2: struct {
        windowAddress: Location,
        workspaceName: Location,
        workspaceId: Location,
    },
    openlayer: struct {
        namespace: Location,
    },
    closelayer: struct {
        namespace: Location,
    },
    submap: struct {
        submapName: Location,
    },
    changefloatingmode: struct {
        windowAddress: Location,
        floating: bool,
    },
    urgent: struct {
        windowAddress: Location,
    },
    screencast: struct {
        state: bool,
        owner: enum { monitor, window },
    },
    windowtitle: struct {
        windowAddress: Location,
    },
    windowtitlev2: struct {
        windowAddress: Location,
        windowTitle: Location,
    },
    togglegroup: struct {
        state: bool,
        // TODO - This has to be an arrayList
        windowAddress: Location,
    },
    moveintogroup: struct {
        windowAddress: Location,
    },
    moveoutofgroup: struct {
        windowAddress: Location,
    },
    ignoregrouplock: bool,
    lockgroups: bool,
    configreloaded,
    pin: struct {
        windowAddress: Location,
        pinState: bool,
    },

    fn lowercase(comptime name: []u8) []u8 {
        for (0..name.len) |index| {
            name[index] = std.ascii.toLower(name[index]);
        }
        return name;
    }

    fn strEql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
    fn parseBoolString(location: Location, line: []const u8) !bool {
        const str = line[location.start .. location.start + location.len];
        if (strEql(str, "1")) {
            return true;
        } else if (strEql(str, "0")) {
            return false;
        } else return error.InvalidString;
    }

    pub const ParseError = error{ MissingParams, InvalidParams, MissingCommandName, UnknownCommand };

    pub fn parse(line: []const u8) ParseError!Self {
        var iter = std.mem.splitSequence(u8, line, ">>");
        const commandName = iter.next() orelse return ParseError.MissingCommandName;
        var paramsIter = EventParamsIter.init(commandName.len + 2, iter.next() orelse "");

        const err: ParseError = err: {
            if (strEql("workspace", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .workspace = .{
                    .workspaceName = arg1,
                } };
            } else if (strEql("workspacev2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .workspacev2 = .{
                    .workspaceId = arg1,
                    .workspaceName = arg2,
                } };
            } else if (strEql("focusedmon", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .focusedmon = .{
                    .monitorName = arg1,
                    .workspaceName = arg2,
                } };
            } else if (strEql("focusedmonv2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .focusedmonv2 = .{
                    .monitorName = arg1,
                    .workspaceId = arg2,
                } };
            } else if (strEql("activewindow", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .activewindow = .{
                    .windowClass = arg1,
                    .windowTitle = arg2,
                } };
            } else if (strEql("activewindowv2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .activewindowv2 = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("fullscreen", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const state = parseBoolString(arg1, line) catch break :err error.InvalidParams;
                return .{ .fullscreen = if (state) .enter else .exit };
            } else if (strEql("monitorremoved", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .monitorremoved = .{
                    .monitorName = arg1,
                } };
            } else if (strEql("monitoradded", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .monitoradded = .{
                    .monitorName = arg1,
                } };
            } else if (strEql("monitoraddedv2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                const arg3 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .monitoraddedv2 = .{
                    .monitorId = arg1,
                    .monitorName = arg2,
                    .monitorDescription = arg3,
                } };
            } else if (strEql("createworkspace", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .createworkspace = .{
                    .workspaceName = arg1,
                } };
            } else if (strEql("createworkspacev2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .createworkspacev2 = .{
                    .workspaceId = arg1,
                    .workspaceName = arg2,
                } };
            } else if (strEql("destroyworkspace", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .destroyworkspace = .{
                    .workspaceName = arg1,
                } };
            } else if (strEql("destroyworkspacev2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .destroyworkspacev2 = .{
                    .workspaceId = arg1,
                    .workspaceName = arg2,
                } };
            } else if (strEql("moveworkspace", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .moveworkspace = .{
                    .workspaceName = arg1,
                    .monitorName = arg2,
                } };
            } else if (strEql("moveworkspacev2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                const arg3 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .moveworkspacev2 = .{
                    .workspaceId = arg1,
                    .workspaceName = arg2,
                    .monitorName = arg3,
                } };
            } else if (strEql("renameworkspace", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .renameworkspace = .{
                    .workspaceId = arg1,
                    .newName = arg2,
                } };
            } else if (strEql("activespecial", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .activespecial = .{
                    .workspaceName = arg1,
                    .monitorName = arg2,
                } };
            } else if (strEql("activelayout", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .activelayout = .{
                    .keyboardName = arg1,
                    .layoutName = arg2,
                } };
            } else if (strEql("openwindow", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                const arg3 = paramsIter.next() orelse break :err error.MissingParams;
                const arg4 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .openwindow = .{
                    .windowAddress = arg1,
                    .workspaceName = arg2,
                    .windowClass = arg3,
                    .windowTitle = arg4,
                } };
            } else if (strEql("closewindow", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .closewindow = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("movewindow", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .movewindow = .{
                    .windowAddress = arg1,
                    .workspaceName = arg2,
                } };
            } else if (strEql("movewindowv2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                const arg3 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .movewindowv2 = .{
                    .windowAddress = arg1,
                    .workspaceId = arg2,
                    .workspaceName = arg3,
                } };
            } else if (strEql("openlayer", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .openlayer = .{
                    .namespace = arg1,
                } };
            } else if (strEql("closelayer", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .closelayer = .{
                    .namespace = arg1,
                } };
            } else if (strEql("submap", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .submap = .{
                    .submapName = arg1,
                } };
            } else if (strEql("changefloatingmode", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .changefloatingmode = .{
                    .windowAddress = arg1,
                    .floating = parseBoolString(arg2, line) catch break :err error.InvalidParams,
                } };
            } else if (strEql("urgent", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .urgent = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("screencast", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                const owner = parseBoolString(arg2, line) catch break :err error.InvalidParams;
                return .{ .screencast = .{
                    .state = parseBoolString(arg1, line) catch break :err error.InvalidParams,
                    .owner = if (owner) .window else .monitor,
                } };
            } else if (strEql("windowtitle", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .windowtitle = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("windowtitlev2", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .windowtitlev2 = .{
                    .windowAddress = arg1,
                    .windowTitle = arg2,
                } };
            } else if (strEql("togglegroup", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{
                    .togglegroup = .{
                        .state = parseBoolString(arg1, line) catch break :err error.InvalidParams,
                        // TODO - make this an array
                        .windowAddress = arg2,
                    },
                };
            } else if (strEql("moveintogroup", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .moveintogroup = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("moveoutofgroup", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .moveoutofgroup = .{
                    .windowAddress = arg1,
                } };
            } else if (strEql("ignoregrouplock", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{
                    .ignoregrouplock = parseBoolString(arg1, line) catch break :err error.InvalidParams,
                };
            } else if (strEql("lockgroups", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                return .{
                    .lockgroups = parseBoolString(arg1, line) catch break :err error.InvalidParams,
                };
            } else if (strEql("configreloaded", commandName)) {
                return .configreloaded;
            } else if (strEql("pin", commandName)) {
                const arg1 = paramsIter.next() orelse break :err error.MissingParams;
                const arg2 = paramsIter.next() orelse break :err error.MissingParams;
                return .{ .pin = .{
                    .windowAddress = arg1,
                    .pinState = parseBoolString(arg2, line) catch break :err error.InvalidParams,
                } };
            } else break :err error.UnknownCommand;
        };
        switch (err) {
            error.MissingParams => log.err("While parsing line \"{s}\", missing parameters", .{line}),
            error.InvalidParams => log.err("While parsing line \"{s}\", an invalid parameter was found", .{line}),
            error.MissingCommandName => log.err("While parsing line \"{s}\", no command was found", .{line}),
            error.UnknownCommand => log.err("While parsing line \"{s}\", an uknown command was found", .{line}),
        }
        return err;
    }
};
