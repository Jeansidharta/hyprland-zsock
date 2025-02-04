const std = @import("std");

const HyprlandIPC = @import("./root.zig").HyprlandIPC;
const IpcResponse = @import("./root.zig").IpcResponse;
const IpcResult = @import("./root.zig").IpcResult;

fn testCommand(method: anytype, argument: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    {
        const ipc = try HyprlandIPC.init(alloc);
        const response = try method(ipc, argument);
        defer response.deinit();

        if (response != .Ok) {
            std.log.err("{any}", .{response});
            return error.Failed;
        }
    }
    if (gpa.deinit() == .leak) {
        std.log.err("Memory leaks found", .{});
        return error.memoryLeaks;
    }
}

fn testRequest(method: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    {
        const ipc = try HyprlandIPC.init(alloc);
        const response = try method(ipc);
        defer response.deinit();
    }
    if (gpa.deinit() == .leak) {
        std.log.err("Memory leaks found", .{});
        return error.memoryLeaks;
    }
}

test "sendDispatch" {
    try testCommand(HyprlandIPC.sendDispatch, HyprlandIPC.Command.Dispatch{ .dispatch = "forcerendererreload" });
}
test "sendKeyword" {
    try testCommand(HyprlandIPC.sendKeyword, HyprlandIPC.Command.Keyword{ .key = "decoration:rounding", .value = "0" });
}
test "sendSetCursor" {
    try testCommand(HyprlandIPC.sendSetCursor, HyprlandIPC.Command.SetCursor{
        .size = 50,
        .theme = "Biabata-Modern-Classic",
    });
}
test "sendOutput" {
    try testCommand(HyprlandIPC.sendOutput, HyprlandIPC.Command.Output{
        .create = .{
            .backend = .headless,
            .name = "test",
        },
    });
    try testCommand(HyprlandIPC.sendOutput, HyprlandIPC.Command.Output{
        .remove = .{
            .name = "test",
        },
    });
}
test "sendSwitchXkbLayout" {
    try testCommand(HyprlandIPC.sendSwitchXkbLayout, HyprlandIPC.Command.SwitchXkbLayout{
        .cmd = .next,
        .device = .current,
    });
    try testCommand(HyprlandIPC.sendSwitchXkbLayout, HyprlandIPC.Command.SwitchXkbLayout{
        .cmd = .prev,
        .device = .current,
    });
}
test "sendSetError" {
    try testCommand(HyprlandIPC.sendSetError, HyprlandIPC.Command.SetError{
        .set = .{
            .message = "This is an error test",
            .rgba = 0xFF_00_00_FF,
        },
    });
    std.time.sleep(1000 * 1000 * 1000 * 0.5);
    // It seems that even though everything is correct, Hyprland will still throw an error
    // when disabling the error string.
    testCommand(HyprlandIPC.sendSetError, HyprlandIPC.Command.SetError{ .disable = void{} }) catch {};
}
test "sendNotify" {
    try testCommand(HyprlandIPC.sendNotify, HyprlandIPC.Command.Notify{
        .message = "Hello from hyprland-zsock test!",
        .color = .{ .rgba = 0x00_FF_00_FF },
        .fontSize = 40,
        .icon = .OK,
        .time_ms = 4000,
    });
}
test "sendDismissNotify" {
    try testCommand(HyprlandIPC.sendDismissNotify, HyprlandIPC.Command.DismissNotify{ .ammount = null });
}
test "requestVersion" {
    try testRequest(HyprlandIPC.requestVersion);
}
test "requestMonitors" {
    try testRequest(HyprlandIPC.requestMonitors);
}
test "requestWorkspaces" {
    try testRequest(HyprlandIPC.requestWorkspaces);
}
test "requestActiveWorkspace" {
    try testRequest(HyprlandIPC.requestActiveWorkspace);
}
test "requestWorkspacerules" {
    try testRequest(HyprlandIPC.requestWorkspacerules);
}
test "requestClients" {
    try testRequest(HyprlandIPC.requestClients);
}
test "requestDevices" {
    try testRequest(HyprlandIPC.requestDevices);
}
// test "requestDecorations" {
//     try testRequest(HyprlandIPC.requestDecorations);
// }
test "requestBinds" {
    try testRequest(HyprlandIPC.requestBinds);
}
test "requestActiveWindow" {
    try testRequest(HyprlandIPC.requestActiveWindow);
}
test "requestLayers" {
    try testRequest(HyprlandIPC.requestLayers);
}
test "requestSplash" {
    try testRequest(HyprlandIPC.requestSplash);
}
// test "requestGetOption" {
//     try testRequest(HyprlandIPC.requestGetOption);
// }
test "requestCursorPos" {
    try testRequest(HyprlandIPC.requestCursorPos);
}
test "requestAnimations" {
    try testRequest(HyprlandIPC.requestAnimations);
}
test "requestLayouts" {
    try testRequest(HyprlandIPC.requestLayouts);
}
test "requestConfigErrors" {
    try testRequest(HyprlandIPC.requestConfigErrors);
}
test "requestRollingLog" {
    try testRequest(HyprlandIPC.requestRollingLog);
}
test "requestLocked" {
    try testRequest(HyprlandIPC.requestLocked);
}
// test "requestDescriptions" {
//     try testRequest(HyprlandIPC.requestDescriptions);
// }
test "requestSubmap" {
    try testRequest(HyprlandIPC.requestSubmap);
}
test "requestSystemInfo" {
    try testRequest(HyprlandIPC.requestSystemInfo);
}
test "requestGlobalShortcuts" {
    try testRequest(HyprlandIPC.requestGlobalShortcuts);
}
