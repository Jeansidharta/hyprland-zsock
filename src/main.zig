const std = @import("std");
const HyprlandIPC = @import("./root.zig").HyprlandIPC;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var ipc = try HyprlandIPC.init(alloc);
    const response = try ipc.sendSetError(HyprlandIPC.Command.SetError{ .set = .{ .message = "Batata", .rgba = 0xff0000ff } });
    std.log.debug("{any}\n", .{response});
    defer response.deinit();
}

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(@import("./ipc-tests.zig"));
}
