//! Sharing the vault between machines: the sync layer's entry point.
//! Front ends (the CLI, the window) use this file only; what's behind it
//! is in src/sync/:
//!
//!     engine.zig       set up, join, sync, stop, the status
//!     keywrap.zig      the vault key wrapped with a passphrase (key.json)
//!     connector.zig    the interface every backend implements
//!     connectors.zig   the backends Locket knows
//!     folder.zig       any folder another tool keeps in step
//!     nomadfs.zig      NomadFS's swarm folder
//! @atlas layer: sync

pub const engine = @import("sync/engine.zig");
pub const connectors = @import("sync/connectors.zig");
pub const keywrap = @import("sync/keywrap.zig");
pub const Connector = @import("sync/connector.zig").Connector;

pub const Report = engine.Report;
pub const Status = engine.Status;
pub const setup = engine.setup;
pub const join = engine.join;
pub const stop = engine.stop;
pub const sync = engine.sync;
pub const syncIfShared = engine.syncIfShared;
pub const isShared = engine.isShared;
pub const configured = engine.configured;
pub const loadStatus = engine.loadStatus;
pub const describe = engine.describe;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("sync/folder.zig");
    _ = @import("sync/nomadfs.zig");
    _ = @import("sync/connector.zig");
}
