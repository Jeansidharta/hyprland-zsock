const std = @import("std");
const HyprlandIPC = @import("./ipc.zig");
const HyprlandEvents = @import("./events.zig").HyprlandEventSocket;

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const alloc = gpa.allocator();

    var socket = try HyprlandEvents.init();
    while (true) {
        const event = try socket.consumeEvent(null);
        std.debug.print("{}\n", .{event});
    }
}

test {
    // @import("std").testing.refAllDecls(@This());
}

test "Batata" {
    std.log.err("{any}\n", .{@typeInfo([]const u8)});
}
