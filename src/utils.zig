const std = @import("std");

const SocketType = union(enum) {
    eventSocket,
    ipcSocket,
    custom: []const u8,
};

pub fn makeSocketAddr(socketType: SocketType) !std.os.linux.sockaddr.un {
    const socketName = switch (socketType) {
        .custom => |name| name,
        .eventSocket => ".socket2.sock",
        .ipcSocket => ".socket.sock",
    };

    const instanceSignature = std.posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse {
        std.log.err("Failed to get HYPRLAND_INSTANCE_SIGNATURE environtment variable", .{});
        return error.InstanceSignatureNotFound;
    };
    const runtimeDirPath: []const u8 = std.posix.getenv("XDG_RUNTIME_DIR") orelse {
        std.log.err("Failed to get XDG_RUNTIME_DIR environtment variable", .{});
        return error.RuntimeDirNotFound;
    };

    var addr: std.os.linux.sockaddr.un = .{ .path = .{0} ** 108 };
    {
        const pathParts = [_][]const u8{
            runtimeDirPath,
            "/hypr/",
            instanceSignature,
            "/",
            socketName,
        };
        var start: usize = 0;
        for (pathParts) |part| {
            if (start + part.len > 108) {
                std.log.err("Socket path is longer than 108 characters. This is the maximum length on linux", .{});
                return error.SocketPathTooLong;
            }
            @memcpy(addr.path[start .. start + part.len], part);
            start += part.len;
        }
    }

    return addr;
}

pub fn makeSocket() !std.posix.socket_t {
    return std.posix.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0) catch |e| {
        std.log.err("Failed to create unix domain socket", .{});
        return e;
    };
}

pub fn openHyprlandSocket(socketType: SocketType) !std.posix.socket_t {
    const addr = try makeSocketAddr(socketType);
    const socket = makeSocket();
    try std.posix.connect(socket, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
    return socket;
}
