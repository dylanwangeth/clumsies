//! Environment proxy resolution for provider transport.
//!
//! The provider transport cannot delegate this boundary to
//! `std.http.Client.initDefaultProxies`: the agent UI needs explicit proxy
//! decisions, `NO_PROXY` matching, unsupported-scheme diagnostics, and later a
//! hand-owned CONNECT + target TLS sequence. This module only parses and
//! classifies configuration; it does not open sockets.

const std = @import("std");

pub const Scheme = enum {
    http,
    https,
};

pub const Proxy = struct {
    host: []const u8,
    port: u16,
};

pub const UnsupportedReason = enum {
    invalid_url,
    proxy_auth,
    socks5,
    unsupported_scheme,
};

pub const Unsupported = struct {
    reason: UnsupportedReason,
    value: []const u8,
};

pub const Decision = union(enum) {
    direct,
    http: Proxy,
    unsupported: Unsupported,
};

/// Resolves the proxy decision for one provider request target.
///
/// `target_host` is the already-parsed provider host, not a full URL. The
/// provider transport uses this before connecting so proxy failures can be
/// reported as configuration problems instead of surfacing later as ambiguous
/// TLS or socket errors.
pub fn decide(env_map: *const std.process.EnvMap, target_scheme: Scheme, target_host: []const u8) Decision {
    if (noProxyMatchesEnv(env_map, target_host)) return .direct;

    const raw_proxy = proxyValue(env_map, target_scheme) orelse return .direct;
    return parse(raw_proxy);
}

/// Parses one proxy URL from an environment variable into a transport decision.
///
/// Only `http://host[:port]` is executable for the first provider transport:
/// HTTPS provider requests use an HTTP proxy by opening a TCP connection to
/// this host, sending CONNECT, and then layering TLS to the provider host.
pub fn parse(raw_url: []const u8) Decision {
    const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    if (trimmed.len == 0) return .direct;

    const uri = std.Uri.parse(trimmed) catch return unsupported(.invalid_url, trimmed);
    if (uri.user != null or uri.password != null) return unsupported(.proxy_auth, trimmed);

    if (std.ascii.eqlIgnoreCase(uri.scheme, "socks5")) return unsupported(.socks5, trimmed);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return unsupported(.unsupported_scheme, trimmed);
    if (uri.query != null or uri.fragment != null) return unsupported(.invalid_url, trimmed);
    if (!uri.path.isEmpty() and !std.mem.eql(u8, uri.path.percent_encoded, "/")) {
        return unsupported(.invalid_url, trimmed);
    }

    const host_component = uri.host orelse return unsupported(.invalid_url, trimmed);
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    if (host.len == 0) return unsupported(.invalid_url, trimmed);

    return .{ .http = .{
        .host = trimIpv6Brackets(host),
        .port = uri.port orelse 80,
    } };
}

/// Checks one `NO_PROXY` value against a target host.
///
/// The matcher intentionally covers only the semantics provider transport
/// needs now: `*`, exact host, and domain suffix entries such as `.example.com`
/// or `example.com`. CIDR and per-entry port matching are left unsupported so
/// the behavior stays explicit instead of pretending to be a full browser
/// proxy stack.
pub fn noProxyMatches(raw_list: []const u8, target_host: []const u8) bool {
    const host = normalizeHost(target_host);
    if (host.len == 0) return false;

    var parts = std.mem.splitScalar(u8, raw_list, ',');
    while (parts.next()) |part| {
        const entry = normalizeHost(std.mem.trim(u8, part, " \t\r\n"));
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;
        if (hostMatchesEntry(host, entry)) return true;
    }

    return false;
}

/// Returns the effective proxy URL for a target scheme, if the environment has one.
///
/// HTTPS provider calls intentionally prefer `HTTPS_PROXY`/`https_proxy`, then
/// `ALL_PROXY`/`all_proxy`. HTTP is included for completeness, but the current
/// provider transport design primarily exercises the HTTPS path.
pub fn proxyValue(env_map: *const std.process.EnvMap, target_scheme: Scheme) ?[]const u8 {
    return switch (target_scheme) {
        .https => firstNonEmpty(env_map, &.{
            "HTTPS_PROXY",
            "https_proxy",
            "ALL_PROXY",
            "all_proxy",
        }),
        .http => firstNonEmpty(env_map, &.{
            "HTTP_PROXY",
            "http_proxy",
            "ALL_PROXY",
            "all_proxy",
        }),
    };
}

fn noProxyMatchesEnv(env_map: *const std.process.EnvMap, target_host: []const u8) bool {
    if (firstNonEmpty(env_map, &.{ "NO_PROXY", "no_proxy" })) |value| {
        return noProxyMatches(value, target_host);
    }
    return false;
}

fn firstNonEmpty(env_map: *const std.process.EnvMap, comptime names: []const []const u8) ?[]const u8 {
    inline for (names) |name| {
        if (env_map.get(name)) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
        }
    }
    return null;
}

fn unsupported(reason: UnsupportedReason, value: []const u8) Decision {
    return .{ .unsupported = .{
        .reason = reason,
        .value = value,
    } };
}

fn hostMatchesEntry(host: []const u8, entry: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, entry)) return true;

    if (!isDomainSuffixEntry(entry)) return false;

    const suffix = if (entry[0] == '.') entry[1..] else entry;
    if (suffix.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
    if (host.len <= suffix.len) return false;
    if (host[host.len - suffix.len - 1] != '.') return false;
    return std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix);
}

fn isDomainSuffixEntry(entry: []const u8) bool {
    if (entry.len == 0) return false;
    if (entry[0] == '.') return entry.len > 1;
    if (std.ascii.eqlIgnoreCase(entry, "localhost")) return false;

    var has_dot = false;
    var has_alpha = false;
    for (entry) |char| {
        if (char == '.') has_dot = true;
        if (std.ascii.isAlphabetic(char)) has_alpha = true;
    }
    return has_dot and has_alpha;
}

fn normalizeHost(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";

    const without_brackets = trimIpv6Brackets(trimmed);
    if (without_brackets.len != trimmed.len) return without_brackets;

    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed[0..colon], ':') != null) return trimmed;

    const port = trimmed[colon + 1 ..];
    if (port.len == 0) return trimmed;
    for (port) |char| {
        if (!std.ascii.isDigit(char)) return trimmed;
    }
    return trimmed[0..colon];
}

fn trimIpv6Brackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

test "parses executable http proxy urls" {
    const with_port = parse("http://proxy.example.com:8080");
    try std.testing.expectEqual(Decision.http, std.meta.activeTag(with_port));
    try std.testing.expectEqualStrings("proxy.example.com", with_port.http.host);
    try std.testing.expectEqual(@as(u16, 8080), with_port.http.port);

    const default_port = parse(" http://proxy.example.com/ ");
    try std.testing.expectEqual(Decision.http, std.meta.activeTag(default_port));
    try std.testing.expectEqualStrings("proxy.example.com", default_port.http.host);
    try std.testing.expectEqual(@as(u16, 80), default_port.http.port);
}

test "classifies unsupported proxy urls" {
    const socks = parse("socks5://127.0.0.1:7890");
    try std.testing.expectEqual(Decision.unsupported, std.meta.activeTag(socks));
    try std.testing.expectEqual(UnsupportedReason.socks5, socks.unsupported.reason);

    const auth = parse("http://user:pass@proxy.example.com:8080");
    try std.testing.expectEqual(Decision.unsupported, std.meta.activeTag(auth));
    try std.testing.expectEqual(UnsupportedReason.proxy_auth, auth.unsupported.reason);

    const https = parse("https://proxy.example.com");
    try std.testing.expectEqual(Decision.unsupported, std.meta.activeTag(https));
    try std.testing.expectEqual(UnsupportedReason.unsupported_scheme, https.unsupported.reason);

    const with_path = parse("http://proxy.example.com/proxy.pac");
    try std.testing.expectEqual(Decision.unsupported, std.meta.activeTag(with_path));
    try std.testing.expectEqual(UnsupportedReason.invalid_url, with_path.unsupported.reason);
}

test "matches basic no proxy entries" {
    try std.testing.expect(noProxyMatches("*", "api.deepseek.com"));
    try std.testing.expect(noProxyMatches("localhost,127.0.0.1", "localhost"));
    try std.testing.expect(noProxyMatches("localhost,127.0.0.1", "127.0.0.1"));
    try std.testing.expect(noProxyMatches(".example.com", "api.example.com"));
    try std.testing.expect(noProxyMatches("example.com", "api.example.com"));
    try std.testing.expect(noProxyMatches("example.com", "example.com"));
    try std.testing.expect(noProxyMatches("example.com:443", "api.example.com"));
    try std.testing.expect(!noProxyMatches("localhost", "api.localhost"));
    try std.testing.expect(!noProxyMatches("127.0.0.1", "api.127.0.0.1"));
    try std.testing.expect(!noProxyMatches("example.com", "badexample.com"));
    try std.testing.expect(!noProxyMatches(".example.com", "example.org"));
}

test "resolves https proxy priority and no proxy bypass" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("ALL_PROXY", "http://all.example.com:8080");
    try env_map.put("HTTPS_PROXY", "http://https.example.com:8443");

    const proxied = decide(&env_map, .https, "api.deepseek.com");
    try std.testing.expectEqual(Decision.http, std.meta.activeTag(proxied));
    try std.testing.expectEqualStrings("https.example.com", proxied.http.host);
    try std.testing.expectEqual(@as(u16, 8443), proxied.http.port);

    try env_map.put("NO_PROXY", ".deepseek.com");
    const bypassed = decide(&env_map, .https, "api.deepseek.com");
    try std.testing.expectEqual(Decision.direct, std.meta.activeTag(bypassed));
}

test "resolves http proxy priority separately from https" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("ALL_PROXY", "http://all.example.com:8080");
    try env_map.put("http_proxy", "http://http.example.com:8081");

    const proxied = decide(&env_map, .http, "api.example.com");
    try std.testing.expectEqual(Decision.http, std.meta.activeTag(proxied));
    try std.testing.expectEqualStrings("http.example.com", proxied.http.host);
    try std.testing.expectEqual(@as(u16, 8081), proxied.http.port);
}
