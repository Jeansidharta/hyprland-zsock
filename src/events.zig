const std = @import("std");
const utils = @import("./utils.zig");

const log = std.log.scoped(.HyprlandEvents);
const Allocator = std.mem.Allocator;

pub const ParseDiagnostics = struct {
    line: []const u8,
    /// If provided, the parser could parse the command.
    command: ?[]const u8 = null,
    /// if provided, the parser parsed at least one argument.
    lastArgumentRead: ?[]const u8 = null,
    numberOfArgumentsRead: u8 = 0,

    fn setLastArg(self: *@This(), arg: []const u8) void {
        self.lastArgumentRead = arg;
        self.numberOfArgumentsRead += 1;
    }
};

/// The main structure to receive events from the Hyprland Event socket.
/// Uses an internal buffer with no memory allocations.
pub const HyprlandEventSocket = struct {
    const Self = @This();

    socket: std.posix.socket_t,
    // We might use a ring buffer here, but that would require some unpleasant
    // logic to ppopulate the strings in the HyprlandEvent struct, since they
    // would all have to be continuous spaces in memory, and a ring buffer may wrap.
    buffer: [4 * 1024]u8 = undefined,
    /// First index in the buffer with data.
    start: usize = 0,
    /// First index in the buffer that does not contain data.
    /// The index before it must contain data (if the buffer is not empty).
    end: usize = 0,

    /// Read data from socket, until internal buffer is full.
    /// If buffer is full, will read nothing. Don't forget to flush the buffer.
    /// Caller does **not** own returned slice
    pub fn readFromSocket(self: *Self) ![]u8 {
        const len = try std.posix.read(self.socket, self.buffer[self.end..self.buffer.len]);
        self.end += len;
        return self.buffer[self.start..self.end];
    }

    /// Move all data to the start of the buffer, freeing some space at the end.
    pub fn flushBuffer(self: *Self) void {
        const start = self.start;
        const end = self.end;
        const len = end - start;
        @memcpy(self.buffer[0..len], self.buffer[start..end]);
        self.start = 0;
        self.end = len;
    }

    /// Get a slice with the meaningful data in the buffer.
    /// Returned slice's lifetime matches that of self.
    /// Returned slice may be invalidated on any read operations.
    fn bufData(self: *const Self) []const u8 {
        return self.buffer[self.start..self.end];
    }

    /// Reads from the socket until a newline is found. Returned slice is
    /// the content of the line, without the newline character.
    ///
    /// Doesn't advance the buffer, therefore consecutive calls will return the same data.
    ///
    /// Returned slice may be invalidated if the internal buffer is mutated.
    /// Returned slice's lifetime matches that of self
    pub fn readLine(self: *Self) ![]const u8 {
        while (true) {
            const data = self.bufData();
            if (std.mem.indexOfScalar(u8, data, '\n')) |index| return data[0..index];
            const isBufFull = self.end == self.buffer.len;
            if (isBufFull) {
                self.flushBuffer();
            }
            const isBufStillFull = self.end == self.buffer.len;
            if (isBufStillFull) {
                return error.BufferFull;
            }
            _ = try self.readFromSocket();
        }
    }

    /// Read from the socket until a newline is found. Returned slice is the content
    /// of the line without the newline character.
    ///
    /// Advances the buffer. Therefore consecutive calls will return different data.
    ///
    /// Returned slice may be invalidated if the internal buffer is mutated.
    /// Returned slice's lifetime matches that of self
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
    ///
    /// Returned slice may be invalidated if the internal buffer is mutated.
    /// Returned slice's lifetime matches that of self
    pub fn readEvent(self: *Self) !HyprlandEvent {
        const line = try self.readLine();
        return try HyprlandEvent.parse(line);
    }

    /// Reads from the socket and parses it into a HyprlandEvent object.
    /// Returns a Tuple with the read line, and the parsed event.
    ///
    /// Advances the buffer, therefore consecutive calls will return different data.
    ///
    /// Returned slice may be invalidated if the internal buffer is mutated.
    /// Returned slice's lifetime matches that of self
    pub fn consumeEvent(self: *Self, diags: ?*ParseDiagnostics) !HyprlandEvent {
        const line = try self.consumeLine();
        return try HyprlandEvent.parse(line, diags);
    }

    /// Closes socket to Hyprland.
    pub fn deinit(self: @This()) void {
        std.posix.close(self.socket);
    }

    /// Opens socket to Hyprland.
    pub fn init() !Self {
        const socket = try utils.openHyprlandSocket(.eventSocket);
        return .{ .socket = socket };
    }
};

/// An object representing an event reported by Hyprland.
///
/// You can read more about the events here:
/// https://wiki.hyprland.org/IPC/#events-list
pub const HyprlandEvent = union(enum) {
    const Self = @This();

    /// emitted on workspace change. Is emitted ONLY when a user
    /// requests a workspace change, and is not emitted on mouse
    /// movements (see focusedmon)
    workspace: struct {
        workspaceName: []const u8,
    },
    /// emitted on workspace change. Is emitted ONLY when a user
    /// requests a workspace change, and is not emitted on mouse
    /// movements (see focusedmon)
    workspacev2: struct {
        workspaceName: []const u8,
        workspaceId: u32,
    },
    /// emitted on the active monitor being changed.
    focusedmon: struct {
        workspaceName: []const u8,
        monitorName: []const u8,
    },
    /// emitted on the active monitor being changed.
    focusedmonv2: struct {
        monitorName: []const u8,
        workspaceId: u32,
    },
    /// emitted on the active window being changed.
    activewindow: struct {
        windowClass: []const u8,
        windowTitle: []const u8,
    },
    /// emitted on the active window being changed.
    activewindowv2: struct {
        windowAddress: []const u8,
    },
    /// emitted when a fullscreen status of a window changes.
    fullscreen: enum {
        exit,
        enter,
    },
    /// emitted when a monitor is removed (disconnected)
    monitorremoved: struct {
        monitorName: []const u8,
    },
    /// emitted when a monitor is added (connected)
    monitoradded: struct {
        monitorName: []const u8,
    },
    /// emitted when a monitor is added (connected)
    monitoraddedv2: struct {
        monitorName: []const u8,
        monitorId: []const u8,
        monitorDescription: []const u8,
    },
    /// emitted when a workspace is created
    createworkspace: struct {
        workspaceName: []const u8,
    },
    /// emitted when a workspace is created
    createworkspacev2: struct {
        workspaceName: []const u8,
        workspaceId: u32,
    },
    /// emitted when a workspace is destroyed
    destroyworkspace: struct {
        workspaceName: []const u8,
    },
    /// emitted when a workspace is destroyed
    destroyworkspacev2: struct {
        workspaceName: []const u8,
        workspaceId: u32,
    },
    /// emitted when a workspace is moved to a different monitor
    moveworkspace: struct {
        workspaceName: []const u8,
        monitorName: []const u8,
    },
    /// emitted when a workspace is moved to a different monitor
    moveworkspacev2: struct {
        workspaceName: []const u8,
        monitorName: []const u8,
        workspaceId: u32,
    },
    /// emitted when a workspace is renamed
    renameworkspace: struct {
        workspaceId: u32,
        newName: []const u8,
    },
    /// emitted when the special workspace opened in a monitor
    /// changes (closing results in an empty WORKSPACENAME)
    activespecial: struct {
        workspaceName: []const u8,
        monitorName: []const u8,
    },
    /// emitted on a layout change of the active keyboard
    activelayout: struct {
        keyboardName: []const u8,
        layoutName: []const u8,
    },
    /// emitted when a window is opened
    openwindow: struct {
        windowAddress: []const u8,
        workspaceName: []const u8,
        windowClass: []const u8,
        windowTitle: []const u8,
    },
    /// emitted when a window is closed
    closewindow: struct {
        windowAddress: []const u8,
    },
    /// emitted when a window is closed
    movewindow: struct {
        windowAddress: []const u8,
        workspaceName: []const u8,
    },
    /// emitted when a window is closed
    movewindowv2: struct {
        windowAddress: []const u8,
        workspaceName: []const u8,
        workspaceId: u32,
    },
    /// emitted when a layerSurface is mapped
    openlayer: struct {
        namespace: []const u8,
    },
    /// emitted when a layerSurface is unmapped
    closelayer: struct {
        namespace: []const u8,
    },
    /// emitted when a keybind submap changes. Empty means default.
    submap: struct {
        submapName: []const u8,
    },
    /// emitted when a window changes its floating mode.
    /// FLOATING is either 0 or 1.
    changefloatingmode: struct {
        windowAddress: []const u8,
        floating: bool,
    },
    /// emitted when a window requests an urgent state
    urgent: struct {
        windowAddress: []const u8,
    },
    /// emitted when a screencopy state of a client changes. Keep in
    /// mind there might be multiple separate clients.
    screencast: struct {
        state: bool,
        owner: enum { monitor, window },
    },
    /// emitted when a window title changes.
    windowtitle: struct {
        windowAddress: []const u8,
    },
    /// emitted when a window title changes.
    windowtitlev2: struct {
        windowAddress: []const u8,
        windowTitle: []const u8,
    },
    /// emitted when togglegroup command is used.
    /// returns state,handle where the state is a toggle status and the handle
    /// is one or more window addresses separated by a comma e.g.
    /// 0,64cea2525760,64cea2522380 where 0 means that a group has been destroyed
    /// and the rest informs which windows were part of it
    togglegroup: struct {
        state: bool,
        /// An iterator that returns the windows affected
        windowAddress: std.mem.SplitIterator(u8, .scalar),
    },
    /// emitted when the window is merged into a group. returns the address of a
    /// merged window
    moveintogroup: struct {
        windowAddress: []const u8,
    },
    /// emitted when the window is removed from a group. returns the address of
    /// a removed window
    moveoutofgroup: struct {
        windowAddress: []const u8,
    },
    /// emitted when ignoregrouplock is toggled.
    ignoregrouplock: bool,
    /// emitted when lockgroups is toggled.
    lockgroups: bool,
    /// emitted when the config is done reloading
    configreloaded,
    /// emitted when a window is pinned or unpinned
    pin: struct {
        windowAddress: []const u8,
        pinState: bool,
    },

    fn strEql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
    fn parseBoolString(str: []const u8) !bool {
        if (strEql(str, "1")) {
            return true;
        } else if (strEql(str, "0")) {
            return false;
        } else return error.InvalidString;
    }

    pub const ParseErrorSet = error{
        /// The event type was expecting more parameters than provided in the string.
        MissingParams,
        /// The last read parameter cannot be converted to a boolean
        InvalidBoolean,
        /// The last read parameter cannot be converted to an integer
        InvalidInteger,
        /// The string parsed does not contain a command.
        MissingCommandName,
        /// The command found in the string is not known.
        UnknownCommand,
    };

    /// Try to parse event from the given string. The returned event object will have
    /// a lifetime equal to the provided string. The returned object does **not** have to
    /// be deinit-ed.
    pub fn parse(line: []const u8, diagnostics: ?*ParseDiagnostics) ParseErrorSet!Self {
        var dummyDiags: ParseDiagnostics = undefined;
        const diags = diagnostics orelse &dummyDiags;

        diags.line = line;
        var iter = std.mem.splitSequence(u8, line, ">>");
        const commandName = iter.next() orelse return error.MissingCommandName;
        var paramsIter = std.mem.splitScalar(u8, iter.next() orelse "", ',');
        diags.command = commandName;

        if (strEql("workspace", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .workspace = .{
                .workspaceName = arg1,
            } };
        } else if (strEql("workspacev2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const workspaceId = std.fmt.parseInt(u32, arg1, 10) catch return error.InvalidInteger;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .workspacev2 = .{
                .workspaceId = workspaceId,
                .workspaceName = arg2,
            } };
        } else if (strEql("focusedmon", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .focusedmon = .{
                .monitorName = arg1,
                .workspaceName = arg2,
            } };
        } else if (strEql("focusedmonv2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const workspaceId = std.fmt.parseInt(u32, arg2, 10) catch return error.InvalidInteger;
            return .{ .focusedmonv2 = .{
                .monitorName = arg1,
                .workspaceId = workspaceId,
            } };
        } else if (strEql("activewindow", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .activewindow = .{
                .windowClass = arg1,
                .windowTitle = arg2,
            } };
        } else if (strEql("activewindowv2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .activewindowv2 = .{
                .windowAddress = arg1,
            } };
        } else if (strEql("fullscreen", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const state = parseBoolString(arg1) catch return error.InvalidBoolean;
            return .{ .fullscreen = if (state) .enter else .exit };
        } else if (strEql("monitorremoved", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .monitorremoved = .{
                .monitorName = arg1,
            } };
        } else if (strEql("monitoradded", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .monitoradded = .{
                .monitorName = arg1,
            } };
        } else if (strEql("monitoraddedv2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const arg3 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg3);
            return .{ .monitoraddedv2 = .{
                .monitorId = arg1,
                .monitorName = arg2,
                .monitorDescription = arg3,
            } };
        } else if (strEql("createworkspace", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .createworkspace = .{
                .workspaceName = arg1,
            } };
        } else if (strEql("createworkspacev2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const workspaceId = std.fmt.parseInt(u32, arg1, 10) catch return error.InvalidInteger;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .createworkspacev2 = .{
                .workspaceId = workspaceId,
                .workspaceName = arg2,
            } };
        } else if (strEql("destroyworkspace", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .destroyworkspace = .{
                .workspaceName = arg1,
            } };
        } else if (strEql("destroyworkspacev2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const workspaceId = std.fmt.parseInt(u32, arg1, 10) catch return error.InvalidInteger;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .destroyworkspacev2 = .{
                .workspaceId = workspaceId,
                .workspaceName = arg2,
            } };
        } else if (strEql("moveworkspace", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .moveworkspace = .{
                .workspaceName = arg1,
                .monitorName = arg2,
            } };
        } else if (strEql("moveworkspacev2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const workspaceId = std.fmt.parseInt(u32, arg1, 10) catch return error.InvalidInteger;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const arg3 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg3);
            return .{ .moveworkspacev2 = .{
                .workspaceId = workspaceId,
                .workspaceName = arg2,
                .monitorName = arg3,
            } };
        } else if (strEql("renameworkspace", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const workspaceId = std.fmt.parseInt(u32, arg1, 10) catch return error.InvalidInteger;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .renameworkspace = .{
                .workspaceId = workspaceId,
                .newName = arg2,
            } };
        } else if (strEql("activespecial", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .activespecial = .{
                .workspaceName = arg1,
                .monitorName = arg2,
            } };
        } else if (strEql("activelayout", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .activelayout = .{
                .keyboardName = arg1,
                .layoutName = arg2,
            } };
        } else if (strEql("openwindow", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const arg3 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg3);
            const arg4 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg4);
            return .{ .openwindow = .{
                .windowAddress = arg1,
                .workspaceName = arg2,
                .windowClass = arg3,
                .windowTitle = arg4,
            } };
        } else if (strEql("closewindow", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .closewindow = .{
                .windowAddress = arg1,
            } };
        } else if (strEql("movewindow", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .movewindow = .{
                .windowAddress = arg1,
                .workspaceName = arg2,
            } };
        } else if (strEql("movewindowv2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const workspaceId = std.fmt.parseInt(u32, arg2, 10) catch return error.InvalidInteger;
            const arg3 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg3);
            return .{ .movewindowv2 = .{
                .windowAddress = arg1,
                .workspaceId = workspaceId,
                .workspaceName = arg3,
            } };
        } else if (strEql("openlayer", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .openlayer = .{
                .namespace = arg1,
            } };
        } else if (strEql("closelayer", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .closelayer = .{
                .namespace = arg1,
            } };
        } else if (strEql("submap", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .submap = .{
                .submapName = arg1,
            } };
        } else if (strEql("changefloatingmode", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const floating = parseBoolString(arg1) catch return error.InvalidBoolean;
            return .{ .changefloatingmode = .{
                .windowAddress = arg1,
                .floating = floating,
            } };
        } else if (strEql("urgent", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .urgent = .{
                .windowAddress = arg1,
            } };
        } else if (strEql("screencast", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const state = parseBoolString(arg1) catch return error.InvalidBoolean;
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const owner = parseBoolString(arg2) catch return error.InvalidBoolean;
            return .{ .screencast = .{
                .state = state,
                .owner = if (owner) .window else .monitor,
            } };
        } else if (strEql("windowtitle", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .windowtitle = .{
                .windowAddress = arg1,
            } };
        } else if (strEql("windowtitlev2", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            return .{ .windowtitlev2 = .{
                .windowAddress = arg1,
                .windowTitle = arg2,
            } };
        } else if (strEql("togglegroup", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const state = parseBoolString(arg1) catch return error.InvalidBoolean;
            return .{
                .togglegroup = .{
                    .state = state,
                    .windowAddress = paramsIter,
                },
            };
        } else if (strEql("moveintogroup", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .moveintogroup = .{
                .windowAddress = arg1,
            } };
        } else if (strEql("moveoutofgroup", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            return .{ .moveoutofgroup = .{ .windowAddress = arg1 } };
        } else if (strEql("ignoregrouplock", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const ignoreGroupLock = parseBoolString(arg1) catch return error.InvalidBoolean;
            return .{ .ignoregrouplock = ignoreGroupLock };
        } else if (strEql("lockgroups", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const lockGroups = parseBoolString(arg1) catch return error.InvalidBoolean;
            return .{ .lockgroups = lockGroups };
        } else if (strEql("configreloaded", commandName)) {
            return .configreloaded;
        } else if (strEql("pin", commandName)) {
            const arg1 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg1);
            const arg2 = paramsIter.next() orelse return error.MissingParams;
            diags.setLastArg(arg2);
            const pinState = parseBoolString(arg2) catch return error.InvalidBoolean;
            return .{ .pin = .{
                .windowAddress = arg1,
                .pinState = pinState,
            } };
        } else return error.UnknownCommand;
    }
};
