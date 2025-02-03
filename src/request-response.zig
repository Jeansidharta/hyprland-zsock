const std = @import("std");
const utils = @import("./utils.zig");

const Allocator = std.mem.Allocator;

pub const IpcResult = union(enum) {
    Ok,
    Err: struct {
        alloc: Allocator,
        message: []const u8,
    },

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        return switch (self) {
            .Ok => writer.writeAll("Ok"),
            .Err => |err| writer.print("Hyprland IPC Error: {s}", .{err.message}),
        };
    }

    pub fn deinit(self: @This()) void {
        switch (self) {
            .Err => |err| err.alloc.free(err.message),
            .Ok => {},
        }
    }
};

pub fn IpcResponse(T: type) type {
    return struct {
        alloc: std.heap.ArenaAllocator,
        rawResponse: []const u8,
        parsed: T,

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            return std.json.stringify(self.parsed, .{ .whitespace = .indent_2 }, writer);
        }

        pub fn deinit(self: @This()) void {
            self.alloc.deinit();
        }
    };
}

/// All possible commands that can be sent to the Hyprland ipc socket.
/// https://wiki.hyprland.org/Configuring/Using-hyprctl/
pub const Command = struct {
    // TODO - make this a tagged union with all possible dispatchers.
    /// Issue a dispatch to call a keybind dispatcher with an argument.
    pub const Dispatch = struct {
        dispatchers: []const u8,

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return std.fmt.allocPrint(alloc, "dispatch {s}", .{self.dispatchers});
        }
    };
    /// issue a keyword to call a config keyword dynamically.
    pub const Keyword = struct {
        key: []const u8,
        value: []const u8,
        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return std.fmt.allocPrint(alloc, "keyword {s} {s}", .{ self.key, self.value });
        }
    };
    /// Sets the cursor theme and reloads the cursor manager.
    /// Will set the theme for everything except GTK, because GTK.
    pub const SetCursor = struct {
        theme: []const u8,
        size: u32,
        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return std.fmt.allocPrint(alloc, "setcursor {s} {}", .{ self.theme, self.size });
        }
    };
    /// Allows you to add and remove fake outputs to your preferred backend.
    pub const Output = union(enum) {
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

                fn string(self: @This()) []const u8 {
                    return switch (self) {
                        .custom => |c| c,
                        else => @tagName(self),
                    };
                }
            },
            /// Optional name for the output. If (name) is not specified,
            /// the default naming scheme will be used (HEADLESS-2, WL-1, etc.)
            name: ?[]const u8 = null,
        },
        remove: struct { name: []const u8 },

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return switch (self) {
                .create => |create| std.fmt.allocPrint(
                    alloc,
                    "output create {s} {s}",
                    .{ create.backend.string(), create.name },
                ),
                .remove => |remove| std.fmt.allocPrint(
                    alloc,
                    "output remove {s}",
                    .{remove.name},
                ),
            };
        }
        pub const Response = IpcResult;
    };
    /// Sets the xkb layout index for a keyboard.
    pub const SwitchXkbLayout = struct {
        device: union(enum) {
            /// The main keyboard from devices.
            current,
            /// Affect all devices
            all,
            /// Choose a device with a matching name. Names can be
            /// listed with `hyprctl devices` command.
            name: []const u8,

            fn string(self: @This()) []const u8 {
                return switch (self) {
                    .name => |a| a,
                    else => @tagName(self),
                };
            }
        },
        /// Command to change the layout
        cmd: union(enum) {
            /// Change to the next defined layout
            next,
            /// Change to the previously defined layout
            prev,
            /// Change to the layout with the given id
            id: []const u8,

            fn string(self: @This()) []const u8 {
                return switch (self) {
                    .id => |a| a,
                    else => @tagName(self),
                };
            }
        },

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return try std.fmt.allocPrint(
                alloc,
                "switchxkblayout {s} {s}",
                .{ self.device.string(), self.cmd.string() },
            );
        }
    };
    /// Sets the hyprctl error string. Will reset when Hyprland’s config is reloaded.
    pub const SetError = union(enum) {
        set: struct { rgba: u32, message: []const u8 },
        disable,

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return switch (self) {
                .set => |set| std.fmt.allocPrint(
                    alloc,
                    "seterror rgba({x:08}) {s}",
                    .{ set.rgba, set.message },
                ),
                .disable => std.fmt.allocPrint(alloc, "seterror disable", .{}),
            };
        }
    };
    /// Sends a notification using the built-in Hyprland notification system.
    pub const Notify = struct {
        icon: enum(i8) {
            NONE = -1,
            WARNING = 0,
            INFO = 1,
            HINT = 2,
            ERROR = 3,
            CONFUSED = 4,
            OK = 5,
        } = .INFO,
        time_ms: u32 = 5000,
        color: union(enum) {
            default,
            rgba: u32,
        } = .default,
        fontSize: ?u32 = null,
        message: []const u8,

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            const icon = @intFromEnum(self.icon);
            if (self.fontSize) |fontSize| {
                return switch (self.color) {
                    .default => try std.fmt.allocPrint(
                        alloc,
                        "notify {} {} 0 fontisze:{} {s}",
                        .{ icon, self.time_ms, fontSize, self.message },
                    ),
                    .rgba => |rgba| try std.fmt.allocPrint(
                        alloc,
                        "notify {} {} rgba({x:08}) fonsize:{} {s}",
                        .{ icon, self.time_ms, rgba, fontSize, self.message },
                    ),
                };
            } else {
                return switch (self.color) {
                    .default => try std.fmt.allocPrint(
                        alloc,
                        "notify {} {} 0 {s}",
                        .{ icon, self.time_ms, self.message },
                    ),
                    .rgba => |rgba| try std.fmt.allocPrint(
                        alloc,
                        "notify {} {} rgba({x:08}) {s}",
                        .{ icon, self.time_ms, rgba, self.message },
                    ),
                };
            }
        }
    };

    /// Dismiss up to AMMOUNT notifications
    pub const DismissNotify = struct {
        pub const Response = IpcResult;
        /// The ammount of notifications to dismiss.
        /// If null, dismiss all notifications
        ammount: ?u32,

        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return if (self.ammount) |ammount| {
                std.fmt.allocPrint(alloc, "dismissnotify {d}", .{ammount});
            } else {
                std.fmt.allocPrint(alloc, "dismissnotify -1", .{});
            };
        }
    };

    // Gets the Hyprland version, along with flags, commit and branch of build
    pub const Version = struct {
        pub const Response = struct {
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
        };
    };
    // TODO - add batch command

    /// Lists active outputs with their properties, 'monitors all' lists active and inactive outputs
    pub const Monitors = struct {
        pub const Response = []const struct {
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
        };
    };
    /// Lists all workspaces with their properties
    pub const Workspaces = struct {
        pub const Response = []const struct {
            id: u32,
            name: []const u8,
            monitor: []const u8,
            monitorID: u32,
            windows: u32,
            hasfullscreen: bool,
            lastwindow: []const u8,
            lastwindowtitle: []const u8,
        };
    };
    /// Gets the active workspace and its properties
    pub const ActiveWorkspace = struct {
        pub const Response = struct {
            id: u32,
            name: []const u8,
            monitor: []const u8,
            monitorID: u32,
            windows: u32,
            hasfullscreen: bool,
            lastwindow: []const u8,
            lastwindowtitle: []const u8,
        };
    };

    /// Gets the list of defined workspace rules
    pub const Workspacerules = struct {
        pub const Request = void;
        // TODO - find a shape for this
        pub const Response = []const struct {};
    };
    /// Lists all windows with their properties
    pub const Clients = struct {
        pub const Request = void;
        pub const Response = []const struct {
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
        };
    };
    /// Lists all connected keyboards and mice
    pub const Devices = struct {
        pub const Request = void;

        pub const Response = struct {
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
        };
    };
    /// Lists all decorations and their info
    pub const Decorations = struct {
        pub const Request = void;
        // TODO - Hyprland currently does not return valid json
        pub const Response = void;
    };
    /// Lists all registered binds
    pub const Binds = struct {
        pub const Response = []const struct {
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
        };
    };
    /// Gets the active window name and its properties
    pub const ActiveWindow = struct {
        pub const Response = struct {
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
        };
    };
    /// Lists all the layers
    pub const Layers = struct {
        pub const Response = std.json.ArrayHashMap(struct {
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
        });
    };
    /// Prints the current random splash
    pub const Splash = struct {
        pub const Response = []const u8;
    };
    /// Gets the config option status (values)
    pub const GetOption = struct {
        pub const Response = union(enum) {
            NotFound,
            Option: []const u8,
        };
        optionName: []const u8,
        pub fn makeRequestString(self: @This(), alloc: Allocator) ![]const u8 {
            return std.fmt.allocPrint(alloc, "getoption -j {s}", .{self.message});
        }
    };
    /// Gets the current cursor position in global layout coordinates
    pub const CursorPos = struct {
        pub const Response = struct { x: u32, y: u32 };
    };
    /// Gets the currently configured info about animations and beziers
    pub const Animations = struct {
        // TODO - find shape for this
        pub const Response = void;
    };
    /// Lists all running instances of Hyprland with their info
    pub const Instances = struct {
        pub const Response = []const struct {
            instance: []const u8,
            time: u64,
            pid: u32,
            wl_socket: []const u8,
        };
    };
    /// Lists all layouts available (including from plugins)
    pub const Layouts = struct {
        pub const Response = []const []const u8;
    };
    /// Lists all current config parsing errors
    pub const ConfigErrors = struct {
        pub const Response = []const []const u8;
    };
    /// Prints tail of the log.
    pub const RollingLog = struct {
        // TODO - Hyprland currently does not return valid json
        pub const Response = void;
    };
    /// Prints whether the current session is locked.
    pub const Locked = struct {
        pub const Response = struct { locked: bool };
    };
    /// Returns a JSON with all config options, their descriptions and types.
    pub const Descriptions = struct {
        // TODO - Hyprland currently does not return valid json
        pub const Response = void;
    };
    /// Prints the current submap the keybinds are in
    pub const Submap = struct {
        pub const Request = void;
        // TODO - Hyprland currently does not return valid json
        pub const Response = void;
    };
    /// List system info
    pub const SystemInfo = struct {
        pub const Request = void;
        // TODO - currently Hyprland does not return valid json
        pub const Response = void;
    };
    /// List all global shortcuts
    pub const GlobalShortcuts = struct {
        pub const Request = void;
        // TODO - find a shape for this
        pub const Response = []const struct {};
    };
};
