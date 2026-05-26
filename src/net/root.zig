//! Network primitives shared by client and agent code.

pub const HttpTransport = @import("http_transport.zig");

test {
    _ = HttpTransport;
}
