const std = @import("std");
const utils = @import("./utils.zig");
pub const IpcResult = @import("./request-response.zig").IpcResult;
pub const IpcResponse = @import("./request-response.zig").IpcResponse;

const Allocator = std.mem.Allocator;

/// Given a string, write it all into the given socket.
fn socketWriteAll(socket: std.posix.socket_t, message: []const u8) !void {
    var bytesSent: usize = 0;
    while (bytesSent < message.len) {
        bytesSent += try std.posix.write(socket, message);
    }
}

/// Read everything from the socket into an allocated slice. Returns when
/// the socket reads 0 bytes
fn socketReadAll(socket: std.posix.socket_t, alloc: Allocator) ![]u8 {
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
    return buffer;
}

/// Object used to send IPC requests.
pub const HyprlandIPC = struct {
    pub const Command = @import("./request-response.zig").Command;

    addr: std.os.linux.sockaddr.un,
    alloc: Allocator,

    pub fn init(alloc: Allocator) !@This() {
        return .{
            .alloc = alloc,
            .addr = try utils.makeSocketAddr(.ipcSocket),
        };
    }

    // ============================ HYPRLAND COMMANDS ============================
    // | A command is characterized by doing an action and returning either "Ok" |
    // | or an error message. The following functions are all possible commands  |
    // | that can be sent to Hyprland.                                           |
    // ===========================================================================

    /// Issue a dispatch to call a keybind dispatcher with an argument.
    pub fn sendDispatch(self: @This(), req: Command.Dispatch) !IpcResult {
        return self.sendAnyCommand(req);
    }

    /// issue a keyword to call a config keyword dynamically.
    pub fn sendKeyword(self: @This(), req: Command.Keyword) !IpcResult {
        return self.sendAnyCommand(req);
    }

    /// Sets the cursor theme and reloads the cursor manager.
    /// Will set the theme for everything except GTK, because GTK.
    pub fn sendSetCursor(self: @This(), req: Command.SetCursor) !IpcResult {
        return self.sendAnyCommand(req);
    }

    /// Allows you to add and remove fake outputs to your preferred backend.
    pub fn sendOutput(self: @This(), req: Command.Output) !IpcResult {
        return self.sendAnyCommand(req);
    }
    /// Sets the xkb layout index for a keyboard.
    pub fn sendSwitchXkbLayout(self: @This(), req: Command.SwitchXkbLayout) !IpcResult {
        return self.sendAnyCommand(req);
    }
    /// Sets the hyprctl error string. Will reset when Hyprland’s config is reloaded.
    pub fn sendSetError(self: @This(), req: Command.SetError) !IpcResult {
        return self.sendAnyCommand(req);
    }
    /// Sends a notification using the built-in Hyprland notification system.
    pub fn sendNotify(self: @This(), req: Command.Notify) !IpcResult {
        return self.sendAnyCommand(req);
    }

    /// Dismiss all up to AMMOUNT notifications
    pub fn sendDismissNotify(self: @This(), req: Command.DismissNotify) !IpcResult {
        return self.sendAnyCommand(req);
    }

    // ======================== HYPRLAND INFO REQUEST ============================
    // | An info request will not modify any state in Hyprland, only report the  |
    // | current state. Most info request functions take no arguments, and they  |
    // | all return a json object that contains the requested info.              |
    // ===========================================================================

    // Gets the Hyprland version, along with flags, commit and branch of build
    pub fn requestVersion(self: @This()) !IpcResponse(Command.Version.Response) {
        return self.sendRequest(Command.Version.Response, "j/version");
    }
    /// Lists active outputs with their properties, 'monitors all' lists active and inactive outputs
    pub fn requestMonitors(self: @This()) !IpcResponse(Command.Monitors.Response) {
        return self.sendRequest(Command.Monitors.Response, "j/monitors");
    }
    /// Lists all workspaces with their properties
    pub fn requestWorkspaces(self: @This()) !IpcResponse(Command.Workspaces.Response) {
        return self.sendRequest(Command.Workspaces.Response, "j/workspaces");
    }
    /// Gets the active workspace and its properties
    pub fn requestActiveWorkspace(self: @This()) !IpcResponse(Command.ActiveWorkspace.Response) {
        return self.sendRequest(Command.ActiveWorkspace.Response, "j/activeworkspace");
    }
    /// Gets the list of defined workspace rules
    pub fn requestWorkspacerules(self: @This()) !IpcResponse(Command.Workspacerules.Response) {
        return self.sendRequest(Command.Workspacerules.Response, "j/workspacerules");
    }
    /// Lists all windows with their properties
    pub fn requestClients(self: @This()) !IpcResponse(Command.Clients.Response) {
        return self.sendRequest(Command.Clients.Response, "j/clients");
    }
    /// Lists all connected keyboards and mice
    pub fn requestDevices(self: @This()) !IpcResponse(Command.Devices.Response) {
        return self.sendRequest(Command.Devices.Response, "j/devices");
    }
    // TODO - Hyprland currently does not return valid json
    // TODO - This has to take and argument
    /// Lists all decorations and their info
    pub fn requestDecorations(self: @This()) !IpcResponse(Command.Decorations.Response) {
        return self.sendRequest(Command.Decorations.Response, "j/decorations");
    }
    /// Lists all registered binds
    pub fn requestBinds(self: @This()) !IpcResponse(Command.Binds.Response) {
        return self.sendRequest(Command.Binds.Response, "j/binds");
    }
    /// Gets the active window name and its properties
    pub fn requestActiveWindow(self: @This()) !IpcResponse(Command.ActiveWindow.Response) {
        return self.sendRequest(Command.ActiveWindow.Response, "j/activewindow");
    }
    /// Lists all the layers
    pub fn requestLayers(self: @This()) !IpcResponse(Command.Layers.Response) {
        return self.sendRequest(Command.Layers.Response, "j/layers");
    }
    /// Gets the current random splash
    pub fn requestSplash(self: @This()) !IpcResponse(Command.Splash.Response) {
        // The splash info request does not return json, even when requested.
        return self.sendRequestUnparsed("splash");
    }

    // TODO - actually parse the response
    /// Gets the config option status (values)
    pub fn requestGetOption(self: @This(), req: Command.GetOption) !IpcResponse(Command.GetOption.Response) {
        const requestString = req.makeRequestString(self.alloc);
        defer self.alloc.free(requestString);
        return self.sendRequest(Command.GetOption.Response, requestString);
    }
    /// Gets the current cursor position in global layout coordinates
    pub fn requestCursorPos(self: @This()) !IpcResponse(Command.CursorPos.Response) {
        return self.sendRequest(Command.CursorPos.Response, "j/cursorpos");
    }
    /// Gets the currently configured info about animations and beziers
    pub fn requestAnimations(self: @This()) !IpcResponse(Command.Animations.Response) {
        return self.sendRequest(Command.Animations.Response, "j/animations");
    }
    // TODO - this doesn't seem like it's a hyprland command (which makes sense)
    // So we must figure out how hyprctl implements this, and copy that behavior
    // This command in the current state does not work
    /// Lists all running instances of Hyprland with their info
    fn requestInstances(self: @This()) !IpcResponse(Command.Instances.Response) {
        return self.sendRequest(Command.Instances.Response, "j/instances");
    }
    /// Lists all layouts available (including from plugins)
    pub fn requestLayouts(self: @This()) !IpcResponse(Command.Layouts.Response) {
        return self.sendRequest(Command.Layouts.Response, "j/layouts");
    }
    /// Lists all current config parsing errors
    pub fn requestConfigErrors(self: @This()) !IpcResponse(Command.ConfigErrors.Response) {
        return self.sendRequest(Command.ConfigErrors.Response, "j/layouts");
    }
    /// Prints tail of the log.
    pub fn requestRollingLog(self: @This()) !IpcResponse(Command.RollingLog.Response) {
        // Hyprland's json response for this is just bad. It's better to use the raw string.
        return self.sendRequestUnparsed("rollinglog");
    }
    /// Prints whether the current session is locked.
    pub fn requestLocked(self: @This()) !IpcResponse(Command.Locked.Response) {
        return self.sendRequest(Command.Locked.Response, "j/locked");
    }
    /// Returns all config options, their descriptions and types.
    pub fn requestDescriptions(self: @This()) !IpcResponse(Command.Descriptions.Response) {
        return self.sendRequest(Command.Descriptions.Response, "j/descriptions");
    }
    /// Prints the current submap the keybinds are in
    pub fn requestSubmap(self: @This()) !IpcResponse(Command.Submap.Response) {
        // Hyprland does not return proper json for this command, so the best we can do is
        // just pass it to the user
        return self.sendRequestUnparsed("j/systeminfo");
    }
    /// List system info
    pub fn requestSystemInfo(self: @This()) !IpcResponse(Command.SystemInfo.Response) {
        // Hyprland does not return proper json for this command, so the best we can do is
        // just pass it to the user
        return self.sendRequestUnparsed("j/systeminfo");
    }
    /// List all global shortcuts
    pub fn requestGlobalShortcuts(self: @This()) !IpcResponse(Command.GlobalShortcuts.Response) {
        return self.sendRequest(Command.GlobalShortcuts.Response, "j/globalshortcuts");
    }

    // ======================== UTILITY FUNCTIONS ================================
    // | From this point downwards, there are only utility functions not really  |
    // | intended for users.                                                     |
    // ===========================================================================

    fn sendRawRequest(self: *const @This(), request: []const u8, alloc: Allocator) ![]const u8 {
        const socket = try self.connect();
        defer std.posix.close(socket);

        try socketWriteAll(socket, request);
        return try socketReadAll(socket, alloc);
    }

    fn sendRequestUnparsed(self: *const @This(), request: []const u8) !IpcResponse([]const u8) {
        var arenaAllocator = std.heap.ArenaAllocator.init(self.alloc);
        const alloc = arenaAllocator.allocator();
        const rawResponse = try self.sendRawRequest(request, alloc);
        return .{
            .alloc = arenaAllocator,
            .rawResponse = rawResponse,
            .parsed = rawResponse,
        };
    }

    fn sendRequest(self: *const @This(), ResponseType: type, request: []const u8) !IpcResponse(ResponseType) {
        var arenaAllocator = std.heap.ArenaAllocator.init(self.alloc);
        const alloc = arenaAllocator.allocator();
        const rawResponse = try self.sendRawRequest(request, alloc);
        const parsed = try std.json.parseFromSliceLeaky(
            ResponseType,
            alloc,
            rawResponse,
            .{ .allocate = .alloc_if_needed },
        );
        return .{
            .alloc = arenaAllocator,
            .rawResponse = rawResponse,
            .parsed = parsed,
        };
    }

    fn sendRawCommand(self: *const @This(), request: []const u8) !IpcResult {
        const response = try self.sendRawRequest(request, self.alloc);

        if (std.mem.eql(u8, response, "ok")) {
            self.alloc.free(response);
            return .Ok;
        } else return .{ .Err = .{
            .message = response,
            .alloc = self.alloc,
        } };
    }

    fn sendAnyCommand(self: @This(), request: anytype) !IpcResult {
        if (!std.meta.hasMethod(@TypeOf(request), "makeRequestString")) {
            @compileError("IPC command request must implement makeRequestString");
        }
        const requestString = try request.makeRequestString(self.alloc);
        defer self.alloc.free(requestString);
        return self.sendRawCommand(requestString);
    }

    fn connect(self: @This()) !std.posix.socket_t {
        const socket = try utils.makeSocket();
        errdefer std.posix.close(socket);

        try std.posix.connect(socket, @ptrCast(&self.addr), @sizeOf(std.os.linux.sockaddr.un));
        return socket;
    }
};
