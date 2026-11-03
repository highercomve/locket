//! What an updater error means, worded for people: `locket update` and
//! the window's update button both show these.
//! @atlas layer: front

const std = @import("std");
const builtin = @import("builtin");

pub const releases_url = "https://github.com/highercomve/locket/releases/latest";

/// This build's entry in the update manifests (Oriel's DEFAULT_TARGET).
const this_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused, error.UnknownHostName, error.NetworkUnreachable, error.ConnectionTimedOut, error.TemporaryNameServerFailure => "no connection to GitHub",
        error.Timeout => "the server took too long",
        error.BadHttpStatus => "no release with updates has been published yet (" ++ releases_url ++ ")",
        error.TargetNotInManifest => "no update is published for " ++ this_target ++ " (" ++ releases_url ++ ")",
        error.InvalidSignature, error.SignatureVerificationFailed => "the release's signature doesn't match: nothing was installed",
        error.HashMismatch, error.Sha256Mismatch => "the download was damaged: nothing was installed",
        error.AccessDenied, error.PermissionDenied => "this user can't replace Locket's files (installed by a package manager, or in a system folder)",
        error.FormatMismatch => "this copy can't update itself (a development build): install a release",
        else => @errorName(err),
    };
}

test describe {
    try std.testing.expect(std.mem.indexOf(u8, describe(error.TargetNotInManifest), this_target) != null);
    try std.testing.expectEqualStrings("Unexpected", describe(error.Unexpected));
}
