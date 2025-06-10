const std = @import("std");
const utils = @import("./utils.zig");

const log = std.log.scoped(.HyprlandEvents);
const Allocator = std.mem.Allocator;

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

/// An object containing important context for a ParseError.
pub const ParseDiagnostics = struct {
    /// The original line that was bein parsed when the error occurred.
    line: ?[]const u8 = null,
    /// If an error was triggered during parsing, it should end here.
    err: ?ParseErrorSet = null,
    /// The command that was being parsed. If null, no command was found.
    command: ?[]const u8 = null,
    /// The last argument that was being parsed. If null, no argument was found.
    lastArgumentRead: ?[]const u8 = null,
    /// The number of arguments that were read.
    numberOfArgumentsRead: u8 = 0,

    pub fn setAndTriggerErr(self: *@This(), err: ParseErrorSet) ParseErrorSet {
        self.err = err;
        return err;
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        if (self.line == null) {
            try writer.print("Error reading from socket: {any}", .{self.err});
        }
        const line = self.line.?;
        try writer.print("While parsing line \"{s}\": ", .{line});
        if (self.err == null) {
            try writer.writeAll("No errors were found");
        }
        const err = self.err.?;
        switch (err) {
            error.MissingCommandName => try writer.writeAll("No command was found"),
            error.UnknownCommand => try writer.print(
                "Command {s} is unknown",
                .{self.command.?},
            ),
            error.MissingParams => try writer.print(
                "{} arguments not enough. Need more",
                .{self.numberOfArgumentsRead},
            ),
            error.InvalidInteger => try writer.print(
                "Argument {s} is expected to be an integer",
                .{self.lastArgumentRead.?},
            ),
            error.InvalidBoolean => try writer.print(
                "Argument {s} is expected to be 0 or 1",
                .{self.lastArgumentRead.?},
            ),
        }
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
                // If you get this error, increase the buffer size.
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

    // =========== !IMPORTANT NOTE FOR MAINTAINERS! ===========
    // Since the `parse` function uses comptime, the order of
    // the arguments in each event tip matters. The first
    // declared struct argument will be parsed first, the
    // second argument will be parsed second, and etc...
    //
    // So the declaration
    // event: struct {
    //   arg1: []const u8,
    //   arg2: []const u8,
    // }
    // is different from
    // event: struct {
    //   arg2: []const u8,
    //   arg1: []const u8,
    // }
    // ========================================================

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
        workspaceId: i32,
    },
    /// emitted on the active monitor being changed.
    focusedmon: struct {
        monitorName: []const u8,
        workspaceName: []const u8,
    },
    /// emitted on the active monitor being changed.
    focusedmonv2: struct {
        monitorName: []const u8,
        workspaceId: i32,
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
    fullscreen: enum(u8) {
        exit = 0,
        enter = 1,
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
        monitorId: i32,
        monitorDescription: []const u8,
    },
    /// emitted when a workspace is created
    createworkspace: struct {
        workspaceName: []const u8,
    },
    /// emitted when a workspace is created
    createworkspacev2: struct {
        workspaceName: []const u8,
        workspaceId: i32,
    },
    /// emitted when a workspace is destroyed
    destroyworkspace: struct {
        workspaceName: []const u8,
    },
    /// emitted when a workspace is destroyed
    destroyworkspacev2: struct {
        workspaceName: []const u8,
        workspaceId: i32,
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
        workspaceId: i32,
    },
    /// emitted when a workspace is renamed
    renameworkspace: struct {
        workspaceId: i32,
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
        workspaceId: i32,
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
        owner: enum(u8) { monitor = 0, window = 1 },
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

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .pin => |pin| {
                try writer.print("pin (windowAddress: \"{s}\", pinState: {})", .{ pin.windowAddress, pin.pinState });
            },
            .configreloaded => {
                try writer.print("configreloaded", .{});
            },
            .lockgroups => |state| {
                try writer.print("lockgroups (state: {})", .{state});
            },
            .ignoregrouplock => |state| {
                try writer.print("ignoregrouplock (state: {})", .{state});
            },
            .moveoutofgroup => |moveoutofgroup| {
                try writer.print("moveoutofgroup (windowAddress: \"{s}\")", .{moveoutofgroup.windowAddress});
            },
            .moveintogroup => |moveintogroup| {
                try writer.print("moveintogroup (windowAddress: \"{s}\")", .{moveintogroup.windowAddress});
            },
            .togglegroup => |togglegroup| {
                try writer.print("togglegroup (state: {}, windowAddress: {any})", .{ togglegroup.state, togglegroup.windowAddress });
            },
            .windowtitlev2 => |windowtitlev2| {
                try writer.print("windowtitlev2 (windoTitle: \"{s}\", windowAddress: \"{s}\")", .{ windowtitlev2.windowTitle, windowtitlev2.windowAddress });
            },
            .windowtitle => |windowtitle| {
                try writer.print("windowtitle (windowAddress: \"{s}\")", .{windowtitle.windowAddress});
            },
            .screencast => |screencast| {
                try writer.print("screencast (state: {}, owner: {s})", .{ screencast.state, switch (screencast.owner) {
                    .monitor => "monitor",
                    .window => "window ",
                } });
            },
            .urgent => |urgent| {
                try writer.print("urgent (windowAddress: \"{s}\")", .{urgent.windowAddress});
            },
            .changefloatingmode => |changefloatingmode| {
                try writer.print("changefloatingmode (windowAddress: \"{s}\", floating: {})", .{ changefloatingmode.windowAddress, changefloatingmode.floating });
            },
            .submap => |submap| {
                try writer.print("submap (submapName: \"{s}\")", .{submap.submapName});
            },
            .closelayer => |closelayer| {
                try writer.print("closelayer (namespace: \"{s}\")", .{closelayer.namespace});
            },
            .openlayer => |openlayer| {
                try writer.print("openlayer (namespace: \"{s}\")", .{openlayer.namespace});
            },
            .movewindowv2 => |movewindowv2| {
                try writer.print(
                    "movewindowv2 (windowAddress: \"{s}\", workspaceName: \"{s}\", workspaceId: {})",
                    .{ movewindowv2.windowAddress, movewindowv2.workspaceName, movewindowv2.workspaceId },
                );
            },
            .movewindow => |movewindow| {
                try writer.print("movewindow (windowAddress: \"{s}\", workspaceName: \"{s}\")", .{ movewindow.windowAddress, movewindow.workspaceName });
            },
            .closewindow => |closewindow| {
                try writer.print("closewindow (windowAddress: \"{s}\")", .{closewindow.windowAddress});
            },
            .openwindow => |openwindow| {
                try writer.print(
                    "openwindow (windowAddress: \"{s}\", workspaceName: \"{s}\", windowClass: \"{s}\", windowTitle: \"{s}\")",
                    .{ openwindow.windowAddress, openwindow.workspaceName, openwindow.windowClass, openwindow.windowTitle },
                );
            },
            .activelayout => |activelayout| {
                try writer.print(
                    "activelayout (keyboardName: \"{s}\", layoutName: \"{s}\")",
                    .{ activelayout.keyboardName, activelayout.layoutName },
                );
            },
            .activespecial => |activespecial| {
                try writer.print(
                    "activespecial (workspaceName: \"{s}\", monitorName: \"{s}\")",
                    .{ activespecial.workspaceName, activespecial.monitorName },
                );
            },
            .renameworkspace => |renameworkspace| {
                try writer.print(
                    "renameworkspace (workspaceId: {}, newName: \"{s}\")",
                    .{ renameworkspace.workspaceId, renameworkspace.newName },
                );
            },
            .moveworkspacev2 => |moveworkspacev2| {
                try writer.print(
                    "moveworkspacev2 (workspaceName: \"{s}\", monitorName: \"{s}\", workspaceId: {})",
                    .{ moveworkspacev2.workspaceName, moveworkspacev2.monitorName, moveworkspacev2.workspaceId },
                );
            },
            .moveworkspace => |moveworkspace| {
                try writer.print(
                    "moveworkspace (workspaceName: \"{s}\", monitorName: \"{s}\")",
                    .{ moveworkspace.workspaceName, moveworkspace.monitorName },
                );
            },
            .destroyworkspacev2 => |destroyworkspacev2| {
                try writer.print(
                    "destroyworkspacev2 (workspaceName: \"{s}\", workspaceId: {})",
                    .{ destroyworkspacev2.workspaceName, destroyworkspacev2.workspaceId },
                );
            },
            .destroyworkspace => |destroyworkspace| {
                try writer.print("destroyworkspace (workspaceName: \"{s}\")", .{destroyworkspace.workspaceName});
            },
            .createworkspacev2 => |createworkspacev2| {
                try writer.print(
                    "createworkspacev2 (workspaceName: \"{s}\", workspaceId: {})",
                    .{ createworkspacev2.workspaceName, createworkspacev2.workspaceId },
                );
            },
            .createworkspace => |createworkspace| {
                try writer.print("createworkspace (workspaceName: \"{s}\")", .{createworkspace.workspaceName});
            },
            .monitoraddedv2 => |monitoraddedv2| {
                try writer.print(
                    "monitoraddedv2 (monitorName: \"{s}\", monitorId: {}, monitorDescription: \"{s}\")",
                    .{ monitoraddedv2.monitorName, monitoraddedv2.monitorId, monitoraddedv2.monitorDescription },
                );
            },
            .monitoradded => |monitoradded| {
                try writer.print("monitoradded (monitorName: \"{s}\")", .{monitoradded.monitorName});
            },
            .monitorremoved => |monitorremoved| {
                try writer.print("monitorremoved (monitorName: \"{s}\")", .{monitorremoved.monitorName});
            },
            .fullscreen => |fullscreen| {
                try writer.print("fullscreen ({s})", .{switch (fullscreen) {
                    .enter => "enter",
                    .exit => "exit",
                }});
            },
            .activewindowv2 => |activewindowv2| {
                try writer.print("activewindowv2 (windowAddress: \"{s}\")", .{activewindowv2.windowAddress});
            },
            .activewindow => |activewindow| {
                try writer.print(
                    "activewindow (windowClass: \"{s}\", windowTitle: \"{s}\")",
                    .{ activewindow.windowClass, activewindow.windowTitle },
                );
            },
            .focusedmonv2 => |focusedmonv2| {
                try writer.print(
                    "focusedmonv2 (monitorName: \"{s}\", workspaceId: {})",
                    .{ focusedmonv2.monitorName, focusedmonv2.workspaceId },
                );
            },
            .focusedmon => |focusedmon| {
                try writer.print(
                    "focusedmon (monitorName: \"{s}\", workspaceName: \"{s}\")",
                    .{ focusedmon.monitorName, focusedmon.workspaceName },
                );
            },
            .workspacev2 => |workspacev2| {
                try writer.print(
                    "workspacev2 (workspaceName: \"{s}\", workspaceId: {})",
                    .{ workspacev2.workspaceName, workspacev2.workspaceId },
                );
            },
            .workspace => |workspace| {
                try writer.print("workspace (workspaceName: \"{s}\")", .{workspace.workspaceName});
            },
        }
    }

    fn strEql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    /// A small wrapper around the default std.mem.SplitIterator for better
    /// ergonomics. Will automatically update the diagnostics object, and
    /// return the proper parsing error.
    const ParamsIterator = struct {
        innerIter: std.mem.SplitIterator(u8, .scalar),
        diagnostics: *ParseDiagnostics,
        pub fn init(str: []const u8, diags: *ParseDiagnostics) @This() {
            return .{
                .innerIter = std.mem.splitScalar(u8, str, ','),
                .diagnostics = diags,
            };
        }
        pub fn next(self: *@This()) ParseErrorSet![]const u8 {
            const arg = self.innerIter.next() orelse
                return self.diagnostics.setAndTriggerErr(error.MissingParams);
            self.diagnostics.lastArgumentRead = arg;
            self.diagnostics.numberOfArgumentsRead += 1;
            return arg;
        }
        pub fn nextInt(self: *@This()) ParseErrorSet!i32 {
            const arg = try self.next();
            return std.fmt.parseInt(i32, arg, 10) catch
                self.diagnostics.setAndTriggerErr(error.InvalidInteger);
        }
        fn parseBoolString(str: []const u8) ParseErrorSet!bool {
            if (strEql(str, "1")) {
                return true;
            } else if (strEql(str, "0")) {
                return false;
            } else return error.InvalidBoolean;
        }
        pub fn nextBool(self: *@This()) ParseErrorSet!bool {
            const arg = try self.next();
            return parseBoolString(arg) catch |e| self.diagnostics.setAndTriggerErr(e);
        }
    };

    /// Try to parse an event from the given string. If the `diagnostics` argument is not
    /// null, will populate it with contextual information in case an error occurs.
    ///
    /// The parsed event and the diagnostics object have the same lifetime as the
    /// `line` argument's slice. They are both invalidated if the line also is.
    pub fn parse(line: []const u8, diagnostics: ?*ParseDiagnostics) ParseErrorSet!@This() {
        var dummyDiags: ParseDiagnostics = undefined;
        const diags = diagnostics orelse &dummyDiags;
        // Resets the diagnostics object. Required if the user didn't initialize it.
        diags.* = .{ .line = line };

        var iter = std.mem.splitSequence(u8, line, ">>");
        const commandName = iter.next() orelse
            return diags.setAndTriggerErr(error.MissingCommandName);
        diags.command = commandName;
        var paramsIter = ParamsIterator.init(iter.next() orelse "", diags);

        // Check for this event is separate from the others because of the unique
        // windowAddress type, which is difficult to handle in comptime.
        if (std.mem.eql(u8, commandName, "togglegroup")) {
            return .{ .togglegroup = .{
                .state = try paramsIter.nextBool(),
                .windowAddress = paramsIter.innerIter,
            } };
        }

        // This is a bit of complicated comptime to check for every event and read
        // its arguments in the proper order. Essentially, this would do something like:
        //
        // ```zig
        // if (std.mem.eql(u8, commandName, "aCommandName")) {
        //   return .{ .aCommandName = .{
        //     .arg1 = try paramsIter.next(), // This will be a string
        //     .arg2 = try paramsIter.nextInt(), // This will be an int
        //     .arg3 = try paramsIter.nextBool(), // This will be a boolean
        //   } };
        // }
        // ```
        const allEventFields = @typeInfo(@This()).@"union".fields;
        inline for (allEventFields) |evField| {
            if (std.mem.eql(u8, evField.name, commandName)) {
                const command = evField.name;
                const initVal: evField.type = initVal: switch (@typeInfo(evField.type)) {
                    .void => void{},
                    .bool => try paramsIter.nextBool(),
                    .int => try paramsIter.nextInt(),
                    // Assume its a []const u8
                    .pointer => try paramsIter.next(),
                    // Assume this is an integer enum that starts at 0 and have no gaps.
                    .@"enum" => |e| {
                        const int = try paramsIter.nextInt();
                        if (int >= e.fields.len) return diags.setAndTriggerErr(error.InvalidBoolean);
                        break :initVal @enumFromInt(int);
                    },
                    .@"struct" => try parseInnerStruct(evField.type, &paramsIter, diags),
                    else => unreachable,
                };
                return @unionInit(@This(), command, initVal);
            }
        }
        return diags.setAndTriggerErr(error.UnknownCommand);
    }

    /// Helper recursive function to parse inner structs.
    pub fn parseInnerStruct(stru: type, paramsIter: *ParamsIterator, diags: *ParseDiagnostics) ParseErrorSet!stru {
        var obj: stru = undefined;
        inline for (@typeInfo(stru).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .void => void{},
                .bool => @field(obj, field.name) = try paramsIter.nextBool(),
                .int => @field(obj, field.name) = try paramsIter.nextInt(),
                // Assume its a []const u8
                .pointer => @field(obj, field.name) = try paramsIter.next(),
                // Assume this is an integer enum that starts at 0
                // and have no gaps.
                .@"enum" => |e| {
                    const int = try paramsIter.nextInt();
                    if (int >= e.fields.len) return diags.setAndTriggerErr(error.InvalidBoolean);
                    @field(obj, field.name) = @enumFromInt(int);
                },
                .@"struct" => @field(obj, field.name) = try parseInnerStruct(
                    field.type,
                    paramsIter,
                    diags,
                ),
                else => unreachable,
            }
        }
        return obj;
    }
};
