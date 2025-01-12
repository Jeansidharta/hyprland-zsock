const std = @import("std");
const HyprlandEventIpc = @import("./ipc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var socket = try HyprlandEventIpc.init();
    while (true) {
        const response = try socket.sendCommand(alloc, .devices, void{});
        defer response.deinit();
        std.debug.print("{any}\n", .{response.variant});
        std.time.sleep(1000000000);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
