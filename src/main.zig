const std = @import("std");
const HyprlandIPC = @import("./root.zig").HyprlandIPC;
const HyprlandEventSocket = @import("./root.zig").HyprlandEventSocket;
const EventParseDiagnostics = @import("./root.zig").EventParseDiagnostics;

fn tryIpc() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var ipc = try HyprlandIPC.init(alloc);
    const response = try ipc.sendSetError(HyprlandIPC.Command.SetError{ .set = .{ .message = "Batata", .rgba = 0xff0000ff } });
    std.log.debug("{any}\n", .{response});
    defer response.deinit();
}

fn tryEvents() !void {
    var eventsSocket = try HyprlandEventSocket.init();
    var diags: EventParseDiagnostics = undefined;
    while (true) {
        const event = eventsSocket.consumeEvent(&diags) catch {
            std.log.err("{f}", .{diags});
            continue;
        };
        std.log.debug("{f}", .{event});
        switch (event) {
            .closewindow => std.log.debug("Closing window", .{}),
            else => {},
        }
    }
}

pub fn main() !void {
    try tryEvents();
}

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(@import("./ipc-tests.zig"));
}
