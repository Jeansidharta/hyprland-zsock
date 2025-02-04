const events = @import("./events.zig");
const ipc = @import("./ipc.zig");

pub const HyprlandEvent = events.HyprlandEvent;
pub const HyprlandEventSocket = events.HyprlandEventSocket;
pub const EventParseDiagnostics = events.ParseDiagnostics;

pub const HyprlandIPC = ipc.HyprlandIPC;
pub const IpcResponse = ipc.IpcResponse;
pub const IpcResult = ipc.IpcResult;
