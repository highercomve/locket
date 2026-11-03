//! The shared vault's key, wrapped with a passphrase: `key.json` next to
//! the shared vault. A machine that knows the passphrase unwraps the key
//! once (joining) and keeps it as its own master.key; the shared folder
//! alone (any device's copy, a backup device, a stolen disk) reveals
//! nothing without the passphrase.
//!
//!     { "version": 1, "kdf": "argon2id", "t": 3, "m": 65536, "p": 1,
//!       "salt": "<base64, 16 bytes>",
//!       "wrapped": "<base64: nonce (12) || key encrypted (32) || tag (16)>" }
//!
//! Argon2id at 64 MiB and 3 passes turns the passphrase into a key that
//! seals the vault key with AES-256-GCM; the parameters travel in the
//! file, so they can grow later without breaking older wraps. They, and
//! the salt, are bound into the seal's associated data: a key.json edited
//! to weaker parameters doesn't open.
//! @atlas layer: sync

const std = @import("std");

const argon2 = std.crypto.pwhash.argon2;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const b64 = std.base64.standard;

pub const key_len = 32;
pub const file = "key.json";
const ad_prefix = "locket/key/v1";
/// The largest key.json read: a real one is a few hundred bytes.
pub const max_file = 16 << 10;
const salt_len = 16;
const wrapped_len = Aes.nonce_length + key_len + Aes.tag_length;

/// What new wraps use: OWASP's Argon2id baseline, raised to 64 MiB.
pub const default_params: argon2.Params = .{ .t = 3, .m = 64 * 1024, .p = 1 };
/// Passphrases shorter than this are refused: the wrap is only as strong
/// as the passphrase.
pub const min_passphrase = 8;

const Doc = struct {
    version: u32,
    kdf: []const u8,
    t: u32,
    m: u32,
    p: u24,
    salt: []const u8,
    wrapped: []const u8,
};

/// `key` wrapped with `passphrase`, as key.json's text (gpa, caller frees).
pub fn wrap(io: std.Io, gpa: std.mem.Allocator, key: [key_len]u8, passphrase: []const u8, params: argon2.Params) ![]u8 {
    if (passphrase.len < min_passphrase) return error.WeakPassphrase;
    var salt: [salt_len]u8 = undefined;
    io.random(&salt);
    var kek: [key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &kek);
    try argon2.kdf(gpa, &kek, passphrase, &salt, params, .argon2id, io);

    var wrapped: [wrapped_len]u8 = undefined;
    const nonce = wrapped[0..Aes.nonce_length];
    io.random(nonce);
    var tag: [Aes.tag_length]u8 = undefined;
    var ad_buf: [ad_max]u8 = undefined;
    Aes.encrypt(wrapped[Aes.nonce_length..][0..key_len], &tag, &key, try adOf(&ad_buf, params, &salt), nonce.*, kek);
    @memcpy(wrapped[wrapped.len - Aes.tag_length ..], &tag);

    var salt_b64: [b64.Encoder.calcSize(salt_len)]u8 = undefined;
    var wrapped_b64: [b64.Encoder.calcSize(wrapped_len)]u8 = undefined;
    const doc: Doc = .{
        .version = 1,
        .kdf = "argon2id",
        .t = params.t,
        .m = params.m,
        .p = params.p,
        .salt = b64.Encoder.encode(&salt_b64, &salt),
        .wrapped = b64.Encoder.encode(&wrapped_b64, &wrapped),
    };
    return std.json.Stringify.valueAlloc(gpa, doc, .{ .whitespace = .indent_2 });
}

/// The key wrapped in key.json's `text`; error.WrongPassphrase when the
/// passphrase doesn't open it, error.CorruptKeyFile when the file is
/// damaged or asks for more memory than a sane wrap would.
pub fn unwrap(io: std.Io, gpa: std.mem.Allocator, text: []const u8, passphrase: []const u8) ![key_len]u8 {
    if (text.len > max_file) return error.CorruptKeyFile;
    const parsed = std.json.parseFromSlice(Doc, gpa, text, .{ .ignore_unknown_fields = true }) catch return error.CorruptKeyFile;
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.version != 1 or !std.mem.eql(u8, doc.kdf, "argon2id")) return error.CorruptKeyFile;
    // Bounds, so a planted key.json can't make every machine burn
    // gigabytes or minutes (m is in KiB: 8 MiB to 256 MiB).
    if (doc.t < 1 or doc.t > 8 or doc.m < 8 * 1024 or doc.m > 256 * 1024 or doc.p < 1 or doc.p > 4) return error.CorruptKeyFile;
    const params: argon2.Params = .{ .t = doc.t, .m = doc.m, .p = doc.p };

    var salt: [salt_len]u8 = undefined;
    var wrapped: [wrapped_len]u8 = undefined;
    decodeExact(&salt, doc.salt) catch return error.CorruptKeyFile;
    decodeExact(&wrapped, doc.wrapped) catch return error.CorruptKeyFile;

    var kek: [key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &kek);
    try argon2.kdf(gpa, &kek, passphrase, &salt, params, .argon2id, io);

    var key: [key_len]u8 = undefined;
    errdefer std.crypto.secureZero(u8, &key);
    const tag = wrapped[wrapped.len - Aes.tag_length ..][0..Aes.tag_length].*;
    var ad_buf: [ad_max]u8 = undefined;
    const ad = try adOf(&ad_buf, params, &salt);
    Aes.decrypt(&key, wrapped[Aes.nonce_length..][0..key_len], tag, ad, wrapped[0..Aes.nonce_length].*, kek) catch return error.WrongPassphrase;
    return key;
}

const ad_max = ad_prefix.len + 64 + salt_len;

/// The seal's associated data: the format, the KDF's parameters and the salt.
fn adOf(buf: *[ad_max]u8, params: argon2.Params, salt: *const [salt_len]u8) ![]const u8 {
    const head = try std.fmt.bufPrint(buf, "{s}|argon2id|t={d}|m={d}|p={d}|", .{ ad_prefix, params.t, params.m, params.p });
    @memcpy(buf[head.len..][0..salt_len], salt);
    return buf[0 .. head.len + salt_len];
}

fn decodeExact(out: []u8, text: []const u8) !void {
    if ((b64.Decoder.calcSizeForSlice(text) catch return error.Invalid) != out.len) return error.Invalid;
    b64.Decoder.decode(out, text) catch return error.Invalid;
}

test "wrap and unwrap; the wrong passphrase and a tampered file are refused" {
    const testing = std.testing;
    const io = testing.io;
    const a = testing.allocator;
    // Small parameters: the test checks the format, not the cost.
    const fast: argon2.Params = .{ .t = 1, .m = 8 * 1024, .p = 1 };
    const key: [key_len]u8 = @splat(0x42);
    const text = try wrap(io, a, key, "correct horse battery", fast);
    defer a.free(text);
    try testing.expectEqual(key, try unwrap(io, a, text, "correct horse battery"));
    try testing.expectError(error.WrongPassphrase, unwrap(io, a, text, "wrong horse battery"));
    try testing.expectError(error.WeakPassphrase, wrap(io, a, key, "short", fast));

    const greedy = try std.mem.replaceOwned(u8, a, text, "\"m\": 8192", "\"m\": 4194304");
    defer a.free(greedy);
    try testing.expectError(error.CorruptKeyFile, unwrap(io, a, greedy, "correct horse battery"));
    try testing.expectError(error.CorruptKeyFile, unwrap(io, a, "{}", "x"));
    // Parameters edited within the bounds: the seal doesn't open.
    const weaker = try std.mem.replaceOwned(u8, a, text, "\"m\": 8192", "\"m\": 8193");
    defer a.free(weaker);
    try testing.expectError(error.WrongPassphrase, unwrap(io, a, weaker, "correct horse battery"));
    const huge = try a.alloc(u8, max_file + 1);
    defer a.free(huge);
    @memset(huge, ' ');
    try testing.expectError(error.CorruptKeyFile, unwrap(io, a, huge, "x"));
}
