const std = @import("std");
const HyprlandIPC = @import("./ipc.zig");
const HyprlandEvents = @import("./events.zig").HyprlandEventSocket;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var ipc = try HyprlandIPC.HyprlandIPC.init(alloc);
    const response = try ipc.sendMonitors();
    std.log.debug("{any}\n", .{response});
    defer response.deinit();
}

test {
    // @import("std").testing.refAllDecls(@This());
}

test "Batata" {
    std.log.err("{any}\n", .{@typeInfo([]const u8)});
}
