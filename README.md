# hyprland-zsock

A zig library to read and write to Hyprlands' IPC sockets, as described in the [Hyprland wiki](https://wiki.hyprland.org/IPC/).

## Installing

First, fetch it from github using

```bash
zig fetch --save https://github.com/Jeansidharta/hyprland-zsock
```

Then, in your build.zig file, add the following lines:

```zig
const hyprlandZsock = b.dependency("hyprland-zsock", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("hyprland-zsock", hyprlandZsock.module("hyprland-zsock"));
```

## Examples

Here's an example that listens for the active window title change:

```zig
const std = @import("std");
const HyprlandEvents = @import("hyprland-zsock").HyprlandEventSocket;
const EventParseDiagnostics = @import("hyprland-zsock").EventParseDiagnostics;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var eventListener = try HyprlandEvents.init();
    var diags: EventParseDiagnostics = undefined;
    while (true) {
        const event = eventListener.consumeEvent(&diags) catch {
            try stderr.print("Error consuming event: {any}\n", .{diags});
            continue;
        };
        switch (event) {
            .activewindow => |activeWindow| {
                try stdout.print("{s}\n", .{activeWindow.windowTitle});
            },
            else => {},
        }
    }
}
```
Here's and example of calling a hyprland command:
```zig
const std = @import("std");
const HyprlandIPC = @import("./root.zig").HyprlandIPC;

fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var ipc = try HyprlandIPC.init(alloc);
    const response = try ipc.sendNotify(.{
        .message = "Hello, world!",
        .fontSize = 30,
        .icon = .OK,
        .time_ms = 5000,
        .color = .{ .rgba = 0xff0000ff },
    });
    defer response.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{any}\n", .{response});
}
```
## Usage

Currently there are two sockets available from Hyprland: a command socket and an event socket. This library provides abstractions over both of them.

### eventListener

The event socket can be communicated with using the `HyprlandEventSocket` exported struct. First, init the scruct using `var eventListener = try HyprlandEventSocket.init()` and then call `try eventListener.consumeEvent(null)` to read the next event sent by Hyprland.

If this library is updated, the `consumeEvent` function should generally not throw any errors, but if it does, it's possible to know why by passing a reference to `EventParseDiagnostics` to it instead of null. This object will be populated with enough information to know when then function had an error, and why. If you don't care much about a custom error message, you can just print the diagnostics object, as such:

```zig
var diags: EventParseDiagnostics = undefined;
const event = eventListener.consumeEvent(&diags) catch {
    try stderr.print("Error consuming event: {any}\n", .{diags});
};
```

### IPC commands

To send commands through the Hyprland IPC socket, the `HyprlandIpc` struct should be used. This one will require an allocator, as opposed to the event listener struct. The init function should be called like this: `var ipc = try HyprlandIpc.init(allocator)`. Any command could then be called like `try ipc.requestActiveWindow()` or `try ipc.sendNotify(notifyRequest)`.

The IPC functions are separated between **requests** and **commands**
- Request function names are prepended with `request` and are generally used to get information from Hyprland, without sending much or any data. An example is `requestSplash`, which takes no argument and returns the current splash message.
- Command function names are prepended with `send` and are generally used to tell Hyprland to do something or change an attribute/option. It takes a request object, which is used as arguments to the command requested. An example is the `sendSetError` function, which sets the current error message displayed on the desktop.

Since the response is allocated, the returned object must be deallocated after being used. Here's an example of calling a request function:

```zig
{
    const activeWindow = try ipc.requestActiveWindow();
    defer activeWindow.deinit();

    try stdout.print("{s}\n", .{activeWindow.parsed.title});
}
```

## Contributing

If you find any problems or have any suggestions, feel free to open an issue or a pull request

