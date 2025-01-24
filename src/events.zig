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

    fn strEql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
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
            const arg = self.innerIter.next() orelse return error.MissingParams;
            self.diagnostics.lastArgumentRead = arg;
            self.diagnostics.numberOfArgumentsRead += 1;
            return arg;
        }
        pub fn nextInt(self: *@This()) ParseErrorSet!u32 {
            const arg = try self.next();
            return std.fmt.parseInt(u32, arg, 10) catch return error.InvalidInteger;
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
            return parseBoolString(arg);
        }
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
        diags.command = commandName;
        var paramsIter = ParamsIterator.init(iter.next() orelse "", diags);

        // Check for this is separate from the others because of the unique
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
        inline for (allEventFields) |field| {
            if (std.mem.eql(u8, field.name, commandName)) {
                switch (@typeInfo(field.type)) {
                    .bool => return @unionInit(Self, field.name, try paramsIter.nextBool()),
                    .int => return @unionInit(Self, field.name, try paramsIter.nextInt()),
                    .pointer => return @unionInit(Self, field.name, try paramsIter.next()),
                    .@"enum" => |e| {
                        // Assume this is an integer enum that starts at 0 and have no gaps.
                        const int = try paramsIter.nextInt();
                        if (int >= e.fields.len) return error.InvalidBoolean;
                        return @unionInit(Self, field.name, @enumFromInt(int));
                    },
                    .@"struct" => |structType| {
                        var event: field.type = undefined;
                        inline for (structType.fields) |innerField| {
                            switch (@typeInfo(innerField.type)) {
                                .bool => @field(event, innerField.name) = try paramsIter.nextBool(),
                                .int => @field(event, innerField.name) = try paramsIter.nextInt(),
                                .pointer => @field(event, innerField.name) = try paramsIter.next(),
                                .@"enum" => |e| {
                                    // Assume this is an integer enum that starts at 0
                                    // and have no gaps.
                                    const int = try paramsIter.nextInt();
                                    if (int >= e.fields.len) return error.InvalidBoolean;
                                    @field(event, innerField.name) = @enumFromInt(int);
                                },
                                else => unreachable,
                            }
                        }
                        return @unionInit(Self, field.name, event);
                    },
                    else => unreachable,
                }
            }
        }
        return error.UnknownCommand;
    }
};
