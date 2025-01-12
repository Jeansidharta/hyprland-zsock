const std = @import("std");
const utils = @import("./utils.zig");

const Self = @This();

addr: std.os.linux.sockaddr.un,

pub fn init() !Self {
    return .{
        .addr = try utils.makeSocketAddr(.ipcSocket),
    };
}

fn connect(self: Self) !std.posix.socket_t {
    const socket = try utils.makeSocket();
    errdefer std.posix.close(socket);

    try std.posix.connect(socket, @ptrCast(&self.addr), @sizeOf(std.os.linux.sockaddr.un));
    return socket;
}

pub const CommandTag = enum {
    // ---------- Commands ----------
    /// Issue a dispatch to call a keybind dispatcher with an argument.
    dispatch,
    keyword,
    reload,
    kill,
    setcursor,
    output,
    switchxkblayout,
    seterror,
    notify,
    dismissnotify,
    batch,
    //  ---------- Info ----------
    version,
    monitors,
    workspaces,
    activeworkspace,
    workspacerules,
    clients,
    devices,
    decorations,
    binds,
    activewindow,
    layers,
    splash,
    getoption,
    cursorpos,
    animations,
    instances,
    layouts,
    configerrors,
    rollinglog,
    locked,
    descriptions,
    submap,
    systeminfo,
    globalshortcuts,
};

/// All possible commands that can be sent to the Hyprland ipc socket.
/// https://wiki.hyprland.org/Configuring/Using-hyprctl/
pub const Command = union(CommandTag) {
    // TODO - make this a tagged union with all possible dispatchers.
    /// Issue a dispatch to call a keybind dispatcher with an argument.
    dispatch: []const u8,
    /// issue a keyword to call a config keyword dynamically.
    keyword: struct { key: []const u8, value: []const u8 },
    reload,
    /// Issue a kill to get into a kill mode, where you can kill
    /// an app by clicking on it. You can exit it with ESCAPE.
    kill,
    /// Sets the cursor theme and reloads the cursor manager.
    /// Will set the theme for everything except GTK, because GTK.
    setcursor: struct { theme: []const u8, size: u32 },
    /// Allows you to add and remove fake outputs to your preferred backend.
    output: union(enum) {
        create: struct {
            /// The name of the backend
            backend: union(enum) {
                /// Creates an output as a Wayland window. This will only work if
                /// you’re already running Hyprland with the Wayland backend.
                wayland,
                /// Creates a headless monitor output. If you’re running a
                /// VNC/RDP/Sunshine server, you should use this.
                headless,
                /// Picks a backend for you. For example, if you’re running Hyprland
                /// from the TTY, headless will be chosen.
                auto,
                /// Available in case a new backend is added and this library goes out of date.
                custom: []const u8,
            },
            /// Optional name for the output. If (name) is not specified,
            /// the default naming scheme will be used (HEADLESS-2, WL-1, etc.)
            name: ?[]const u8 = null,
        },
        remove: struct { name: []const u8 },
    },
    /// Sets the xkb layout index for a keyboard.
    switchxkblayout: struct {
        device: union(enum) {
            /// The main keyboard from devices.
            current,
            /// Affect all devices
            all,
            /// Choose a device with a matching name. Names can be
            /// listed with `hyprctl devices` command.
            name: []const u8,
        },
        cmd: union(enum) {
            next,
            prev,
            id: []const u8,
        },
    },
    /// Sets the hyprctl error string. Will reset when Hyprland’s config is reloaded.
    seterror: union(enum) {
        set: struct { rgba: u32, message: []const u8 },
        disable,
    },
    /// Sends a notification using the built-in Hyprland notification system.
    notify: struct {
        icon: enum(i8) {
            NONE = -1,
            WARNING = 0,
            INFO = 1,
            HINT = 2,
            ERROR = 3,
            CONFUSED = 4,
            OK = 5,
        } = .INFO,
        time_ms: u32,
        color: union(enum) { default, rgba: u32 } = .default,
        fontSize: ?u32 = null,
        message: []const u8,
    },
    /// Dismisses all or up to AMOUNT notifications.
    dismissnotify: ?u32,
    /// Use to specify a batch of commands to execute.
    batch: []const Command,
    /// Prints the Hyprland version along with flags, commit and branch of build.
    version,
    /// Lists active outputs with their properties, 'monitors all' lists active and inactive outputs
    monitors,
    /// Lists all workspaces with their properties
    workspaces,
    /// Gets the active workspace and its properties
    activeworkspace,
    /// Gets the list of defined workspace rules
    workspacerules,
    /// Lists all windows with their properties
    clients,
    /// Lists all connected keyboards and mice
    devices,
    /// Lists all decorations and their info
    decorations,
    /// Lists all registered binds
    binds,
    /// Gets the active window name and its properties
    activewindow,
    /// Lists all the layers
    layers,
    /// Prints the current random splash
    splash,
    /// Gets the config option status (values)
    getoption,
    /// Gets the current cursor position in global layout coordinates
    cursorpos,
    /// Gets the currently configured info about animations and beziers
    animations,
    /// Lists all running instances of Hyprland with their info
    instances,
    /// Lists all layouts available (including from plugins)
    layouts,
    /// Lists all current config parsing errors
    configerrors,
    /// Prints tail of the log. Also supports -f/--follow option
    rollinglog,
    /// Prints whether the current session is locked.
    locked,
    /// Returns a JSON with all config options, their descriptions and types.
    descriptions,
    /// Prints the current submap the keybinds are in
    submap,
    /// List system info
    systeminfo,
    /// List all global shortcuts
    globalshortcuts,

    pub fn name(self: Command) []const u8 {
        return @tagName(self);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const commandName = @tagName(self);
        try writer.writeByte('/');
        try writer.writeAll(commandName);
        switch (self) {
            .dispatch => |data| {
                try writer.writeByte(' ');
                try writer.writeAll(data);
            },
            .keyword => |keyword| {
                try writer.writeByte(' ');
                try writer.writeAll(keyword.key);
                try writer.writeByte(' ');
                try writer.writeAll(keyword.value);
            },
            .setcursor => |setcursor| {
                try writer.writeByte(' ');
                try writer.writeAll(setcursor.theme);
                try writer.writeByte(' ');
                try std.fmt.format(writer, "{}", .{setcursor.size});
            },
            .output => |output| {
                try writer.writeByte(' ');
                switch (output) {
                    .create => |create| {
                        try writer.writeAll("create");
                        try writer.writeAll(switch (create.backend) {
                            .wayland => "wayland",
                            .headless => "headless",
                            .auto => "auto",
                            .custom => |custom| custom,
                        });
                        if (create.name) |createName| {
                            try writer.writeByte(' ');
                            try writer.writeAll(createName);
                        }
                    },
                    .remove => |remove| {
                        try writer.writeAll("remove");
                        try writer.writeAll(remove.name);
                    },
                }
            },
            .switchxkblayout => |switchxkblayout| {
                try writer.writeByte(' ');
                try writer.writeAll(switch (switchxkblayout.device) {
                    .current => "current",
                    .all => "next",
                    .name => |deviceName| deviceName,
                });
                try writer.writeByte(' ');
                try writer.writeAll(switch (switchxkblayout.cmd) {
                    .next => "next",
                    .prev => "prev",
                    .id => |id| id,
                });
            },
            .seterror => |seterror| {
                try writer.writeByte(' ');
                switch (seterror) {
                    .disable => try writer.writeAll("disable"),
                    .set => |set| {
                        try std.fmt.format(writer, "rgba({x:08}) ", .{set.rgba});
                        try writer.writeAll(set.message);
                    },
                }
            },
            .notify => |notify| {
                try writer.writeByte(' ');
                try std.fmt.format(writer, "{d} {} ", .{ @intFromEnum(notify.icon), notify.time_ms });
                switch (notify.color) {
                    .default => try writer.writeByte('0'),
                    .rgba => |rgba| try std.fmt.format(writer, "rgba({x:08})", .{rgba}),
                }
                try writer.writeByte(' ');
                if (notify.fontSize) |fontSize| {
                    try std.fmt.format(writer, "fontsize:{d} ", .{fontSize});
                }
                try writer.writeAll(notify.message);
            },
            .dismissnotify => |dismissnotify| {
                if (dismissnotify) |ammount| {
                    try writer.writeByte(' ');
                    try std.fmt.format(writer, "{d}", .{ammount});
                }
            },
            .batch => |batch| {
                try writer.writeByte(' ');
                for (batch, 0..) |command, index| {
                    try std.fmt.format(writer, "{any}", .{command});

                    const isLastCommand = index != batch.len - 1;
                    if (!isLastCommand) {
                        try writer.writeAll(" ; ");
                    }
                }
            },
            else => return,
        }
    }
};

pub const CommandResponseVariant = union(CommandTag) {
    const ActionResult = union(enum) {
        Ok,
        Err: []const u8,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self) {
                .Ok => try writer.writeAll("Ok"),
                .Err => |message| {
                    try writer.writeAll("Error: ");
                    try writer.writeAll(message);
                },
            }
        }
    };
    // ---------- Commands ----------
    dispatch: ActionResult,
    keyword: ActionResult,
    reload: ActionResult,
    kill: ActionResult,
    setcursor: ActionResult,
    output: ActionResult,
    switchxkblayout: ActionResult,
    seterror: ActionResult,
    notify: ActionResult,
    dismissnotify: ActionResult,
    // TODO - batch action has to get multiple responses
    batch: ActionResult,
    //  ---------- Info ----------
    version: struct {
        branch: []const u8,
        commit: []const u8,
        version: []const u8,
        dirty: bool,
        commit_message: []const u8,
        commit_date: []const u8,
        tag: []const u8,
        commits: []const u8,
        buildAquamarine: []const u8,
        flags: []const []const u8,
    },
    monitors: []const struct {
        id: u32,
        name: []const u8,
        description: []const u8,
        make: []const u8,
        model: []const u8,
        serial: []const u8,
        width: u32,
        height: u32,
        refreshRate: f32,
        x: i32,
        y: i32,
        activeWorkspace: struct {
            id: u32,
            name: []const u8,
        },
        specialWorkspace: struct {
            id: u32,
            name: []const u8,
        },
        reserved: struct { u32, u32, u32, u32 },
        scale: f32,
        transform: u32,
        focused: bool,
        dpmsStatus: bool,
        vrr: bool,
        solitary: []const u8,
        activelyTearing: bool,
        disabled: bool,
        currentFormat: []const u8,
        mirrorOf: []const u8,
        availableModes: []const []const u8,
    },
    workspaces: []const struct {
        id: u32,
        name: []const u8,
        monitor: []const u8,
        monitorID: u32,
        windows: u32,
        hasfullscreen: bool,
        lastwindow: []const u8,
        lastwindowtitle: []const u8,
    },
    activeworkspace: struct {
        id: u32,
        name: []const u8,
        monitor: []const u8,
        monitorID: u32,
        windows: u32,
        hasfullscreen: bool,
        lastwindow: []const u8,
        lastwindowtitle: []const u8,
    },
    // TODO - find a shape for this
    workspacerules: []const struct {},
    clients: []const struct {
        address: []const u8,
        mapped: bool,
        hidden: bool,
        at: struct { u32, u32 },
        size: struct { u32, u32 },
        workspace: struct {
            id: u32,
            name: []const u8,
        },
        floating: bool,
        pseudo: bool,
        monitor: u32,
        class: []const u8,
        title: []const u8,
        initialClass: []const u8,
        initialTitle: []const u8,
        pid: u32,
        xwayland: bool,
        pinned: bool,
        fullscreen: u32,
        fullscreenClient: u32,
        // TODO - find the shape for this
        grouped: []const struct {},
        // TODO - find the shape for this
        tags: []const struct {},
        swallowing: []const u8,
        focusHistoryID: u32,
    },
    devices: struct {
        mice: []const struct {
            address: []const u8,
            name: []const u8,
            defaultSpeed: f32,
        },
        keyboards: []const struct {
            address: []const u8,
            name: []const u8,
            rules: []const u8,
            model: []const u8,
            layout: []const u8,
            variant: []const u8,
            options: []const u8,
            active_keymap: []const u8,
            capsLock: bool,
            numLock: bool,
            main: bool,
        },
        // TODO - find out the shape of this
        tablets: []const struct {},
        touch: []const struct {},
        switches: []const struct { address: []const u8, name: []const u8 },
    },
    // TODO - Hyprland currently does not return valid json
    decorations,
    binds: []const struct {
        locked: bool,
        mouse: bool,
        release: bool,
        repeat: bool,
        non_consuming: bool,
        has_description: bool,
        modmask: u32,
        submap: []const u8,
        key: []const u8,
        keycode: u32,
        catch_all: bool,
        description: []const u8,
        dispatcher: []const u8,
        arg: []const u8,
    },
    activewindow: struct {
        address: []const u8,
        mapped: bool,
        hidden: bool,
        at: struct { i32, i32 },
        size: struct { i32, i32 },
        workspace: struct {
            id: i32,
            name: []const u8,
        },
        floating: bool,
        pseudo: bool,
        monitor: u32,
        class: []const u8,
        title: []const u8,
        initialClass: []const u8,
        initialTitle: []const u8,
        pid: u32,
        xwayland: bool,
        pinned: bool,
        fullscreen: u8,
        fullscreenClient: u8,
        // TODO - figure out whats the shape of this
        grouped: []const struct {},
        // TODO - figure out whats the shape of this
        tags: []const struct {},
        swallowing: []const u8,
        focusHistoryID: u32,
    },
    layers: std.json.ArrayHashMap(struct {
        levels: std.json.ArrayHashMap(
            []const struct {
                address: []const u8,
                x: i32,
                y: i32,
                w: u32,
                h: u32,
                namespace: []const u8,
            },
        ),
    }),
    // TODO - Hyprland currently does not return json data
    splash,
    // TODO - find shape for this
    getoption,
    cursorpos: struct { x: u32, y: u32 },
    // TODO - find shape for this
    animations,
    instances: []const struct {
        instance: []const u8,
        time: u64,
        pid: u32,
        wl_socket: []const u8,
    },
    layouts: []const []const u8,
    configerrors: []const []const u8,
    // TODO - Hyprland currently does not return valid json
    rollinglog,
    locked: struct { locked: bool },
    // TODO - Hyprland currently does not return valid json
    descriptions,
    // TODO - Hyprland currently does not return valid json
    submap,
    // TODO - currently Hyprland does not return valid json
    systeminfo,
    globalshortcuts: []const struct {},
};

fn writerFn(socket: std.posix.socket_t, bytes: []const u8) !usize {
    var bytesWritten: usize = 0;
    while (bytesWritten < bytes.len) {
        bytesWritten += try std.posix.write(socket, bytes[bytesWritten..]);
    }
    return bytesWritten;
}

pub fn CommandResponse(comptime tagType: CommandTag) type {
    return struct {
        const VariantType = @FieldType(CommandResponseVariant, @tagName(tagType));

        variant: VariantType,
        rawResponse: []const u8,
        arenaAllocator: std.heap.ArenaAllocator,

        /// Takes ownership of the allocator and the rawResponse buffer
        fn init(
            arena: std.heap.ArenaAllocator,
            variant: VariantType,
            rawResponse: []const u8,
        ) @This() {
            return .{
                .variant = variant,
                .arenaAllocator = arena,
                .rawResponse = rawResponse,
            };
        }

        pub fn deinit(self: @This()) void {
            self.arenaAllocator.deinit();
        }
    };
}

pub fn sendCommand(
    self: *Self,
    argAlloc: std.mem.Allocator,
    comptime commandTag: CommandTag,
    commandPayload: @FieldType(Command, @tagName(commandTag)),
) !CommandResponse(commandTag) {
    const CommandResponseType = CommandResponse(commandTag);

    const socket = try self.connect();
    defer std.posix.close(socket);

    var arena = std.heap.ArenaAllocator.init(argAlloc);
    const alloc = arena.allocator();

    // Writes the command to the socket.
    {
        // Note: We could avoid this allocation by writing the data directly to the socket,
        // but Hyprland does not seem to handle partial writes very well. Therefore, we
        // must allocate the whole command onto a buffer that will be sent all at once.
        const line = try std.fmt.allocPrint(alloc, "j{any}\x00", .{@unionInit(Command, @tagName(commandTag), commandPayload)});
        defer alloc.free(line);
        var bytesSent: usize = 0;
        while (bytesSent < line.len) {
            bytesSent += try std.posix.write(socket, line[bytesSent..]);
        }
    }

    const rawResponse = rawResponse: {
        const allocStep = 1024;
        var buffer: []u8 = try alloc.alloc(u8, allocStep);
        var totalBytesRead: usize = 0;
        while (true) {
            const bytesRead = try std.posix.read(socket, buffer[totalBytesRead..]);
            totalBytesRead += bytesRead;

            if (bytesRead == 0) break;

            const isBufferFull = totalBytesRead == buffer.len;
            if (isBufferFull) {
                const newBufLen = buffer.len + allocStep;
                buffer = try alloc.realloc(buffer, newBufLen);
            }
        }
        _ = alloc.resize(buffer, totalBytesRead);
        buffer = buffer[0..totalBytesRead];
        break :rawResponse buffer;
    };

    if (CommandResponseType.VariantType == CommandResponseVariant.ActionResult) {
        if (std.mem.eql(u8, rawResponse, "ok")) {
            return CommandResponseType.init(arena, .Ok, rawResponse);
        } else {
            return CommandResponseType.init(arena, .{ .Err = rawResponse }, rawResponse);
        }
    }
    return CommandResponseType.init(
        arena,
        std.json.parseFromSliceLeaky(
            CommandResponseType.VariantType,
            alloc,
            rawResponse,
            .{ .allocate = .alloc_if_needed },
        ) catch |e| {
            if (e == error.UnknownField) {
                std.log.warn(
                    "For command {s}\nUnknown field while parsing the following json:\n{s}",
                    .{ @tagName(commandTag), rawResponse },
                );
            }
            return e;
        },
        rawResponse,
    );
}

// Test wether we can parse the response from all commands.
// Will call `hyprctl <COMMAND>` replacing <COMMAND> with each one of our commands in `CommandTag`
test "Hyprland integration json data format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    fields_loop: inline for (@typeInfo(CommandResponseVariant).@"union".fields) |field| {
        // These commands are still not implemented. They should not be tested.
        if (field.type == void) {
            std.log.warn("Field {s} is empty. Skipping...", .{field.name});
            continue;
        }
        if (field.type == []const struct {}) {
            std.log.warn("Field {s} has no structure. Skipping...", .{field.name});
            continue;
        }
        // What commands to skip integration testing.
        // These commands require arguments, and therefore should be tested somewhere else.
        const commandFields: []const CommandTag = &.{
            .dispatch,
            .keyword,
            .reload,
            .kill,
            .setcursor,
            .output,
            .switchxkblayout,
            .seterror,
            .notify,
            .dismissnotify,
            .batch,
        };
        comptime for (commandFields) |commandField| {
            if (std.mem.eql(u8, @tagName(commandField), field.name)) {
                continue :fields_loop;
            }
        };
        const name = field.name;
        var child = std.process.Child.init(&.{ "hyprctl", "-j", name }, alloc);
        child.stdout_behavior = .Pipe;
        try child.spawn();
        const data = try child.stdout.?.readToEndAlloc(alloc, 8 * 1024 * 1028);
        defer alloc.free(data);
        _ = try child.kill();
        const json = std.json.parseFromSlice(@FieldType(CommandResponseVariant, name), alloc, data, .{}) catch |e| {
            std.log.err("Problem parsing command {s}. Error is {any}. Returned data is {s}", .{ name, e, data });
            return e;
        };
        std.log.warn("Command {s} passed", .{name});
        defer json.deinit();
    }

    std.log.warn("GPA deinit result: {any}", .{gpa.deinit()});
}
