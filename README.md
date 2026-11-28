<p align="center">
  <img src="https://raw.githubusercontent.com/farbenbuilds/tachyon/main/misc/tachyon-banner.png" alt="tachyon banner">
</p>

# tachyon

tachyon is a fast RFC 6455 WebSocket library for Zig 0.17.1. It targets the
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets) 0.10.0
surface with a zero-allocation, I/O-agnostic core. Framing is delegated to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay), a pure framing
engine and bounded connection state machine. Compression, backpressure,
streaming, and pub/sub compose at the application edge.

## Quick Start

Zig 0.17.1 is required. Fetch the package and replace `vX.Y.Z` with the release
tag:

```sh
zig fetch --save=tachyon https://github.com/farbenbuilds/tachyon/archive/refs/tags/vX.Y.Z.tar.gz
```

Wire the module in `build.zig`:

```zig
const tachyon = b.dependency("tachyon", .{
    .target = target,
    .optimize = optimize,
}).module("tachyon");
exe.root_module.addImport("tachyon", tachyon);
```

Encode a frame:

```zig
const std = @import("std");
const tachyon = @import("tachyon");

pub fn main() !void {
    var payload = [_]u8{ 'h', 'i' };
    const frame = tachyon.Frame.text(&payload);
    var wire: [tachyon.MaxHeadSize + payload.len]u8 = undefined;
    const bytes = try frame.write(&wire);
    std.debug.assert(bytes.len == 4);
}
```

The [Autobahn echo fixture](https://github.com/farbenbuilds/tachyon/blob/main/tests/autobahn-test/server.zig) is the full server example.

## Examples

Build the echo servers and client with `zig build examples`. See
[examples/README.md](https://github.com/farbenbuilds/tachyon/blob/main/examples/README.md)
for commands and raw-frame behavior.

## Benchmarks

```sh
zig build benches -Doptimize=ReleaseFast
sh benches/setup-competitors.sh
node benches/run.mjs
```

See [benches/README.md](https://github.com/farbenbuilds/tachyon/blob/main/benches/README.md)
for the comparison setup, results table, and SVG charts. The benchmark workflow
is manual and weekly, not a PR gate.

## Features

- Frame facade with `Frame`, `Payload`, `OpCode`, `CloseCode`, masking helpers,
  caller-buffer writes, and `std.Io.Writer` vectored writes.
- Role-aware connection over zslay: automatic pong and close replies, masking,
  exclusive message limits, closed gating, failure latches, and vectored or
  copied writes.
- Optional bounded backpressure over zslay's transmit ring, with explicit
  watermarks and `flush` as the `std.Io` wait point.
- Assembled fragment collection, chunked `MessageReader`/`MessageWriter`, split
  read/write halves, and a native `std.Io.net.Stream` adapter.
- Incremental zero-allocation UTF-8 validation across frames and split code
  points.
- RFC 7692 permessage-deflate codec plus handshake offer/selection/verification
  and negotiated RSV1. Compression is edge-composed; the default no-extension
  path is strict.
- RFC 6455 client handshake and server upgrade call order, including
  accept-token verification and explicit origin handling.
- Bounded zero-allocation pub/sub topic hub for application-layer fanout.

## Layers

| Layer | Modules | Responsibility |
| --- | --- | --- |
| Wire and framing | zslay | header codec, length validation, close predicate, masking, connection state, bounded queue |
| Connection | `connection.zig`, `split.zig` | role policy, automatic replies, limits, split halves |
| Transport | `native_stream.zig` | `std.Io.net.Stream` binding and caller-owned buffers |
| Messages | `fragment.zig`, `stream.zig`, `utf8.zig` | assembled and chunked messages, incremental UTF-8 |
| Handshake | `handshake.zig`, `upgrade.zig` | client handshake, server upgrade, extension negotiation |
| Edge extensions | `deflate.zig`, `backpressure.zig`, `pubsub.zig` | codec, flow control, fanout |

## Compatibility and Limits

tachyon keeps the fastwebsockets 0.10.0 names and observable behavior where
practical. Deliberate differences are recorded in
[CODEBASE.md](https://github.com/farbenbuilds/tachyon/blob/main/CODEBASE.md#compatibility-notes).

The default path is strict: no extensions, RSV1 rejected until negotiated, and
`Options.allow_rsv1` is opt-in. zslay owns framing, masking, close validation,
limits, and the bounded transmit queue; tachyon owns policy, transport, and
automatic replies. permessage-deflate is not automatic in the stream layer:
callers inflate, validate, deflate, and write RSV1 frames at the edge, bound
decompressed output, and treat decompressed bytes as untrusted.

The Autobahn gate covers cases 1-7 and 9-13. Compression cases 11-13 are enabled
through the fixture's negotiated permessage-deflate composition. Group 8 is
absent from the pinned suite and the action's default list omits it, so the gate
covers every case the suite ships. A green run is evidence only for that case
set, not full Autobahn or compression compliance.

Runtime-tested on x86_64-linux-gnu under Debug and ReleaseSafe, plus host and
host-architecture musl tests through `nix flake check`. CI compile-checks x86_64
and aarch64 Linux (gnu and musl), x86 Linux musl, x86_64 and aarch64 macOS, and
x86_64 Windows; non-Linux and foreign Linux targets are compile-only, with no
runtime claim for macOS, Windows, or non-x86_64 Linux.

## Build and Test

```sh
zig build
zig build test --summary all
zig build check
zig build autobahn-server -Doptimize=ReleaseSafe
zig fmt --check .
nix flake check
pre-commit run --all-files
```

## Documentation

- [CODEBASE.md](https://github.com/farbenbuilds/tachyon/blob/main/CODEBASE.md):
  architecture, runtime flow, compatibility notes, and extension map.
- [CONTRIBUTE.md](https://github.com/farbenbuilds/tachyon/blob/main/CONTRIBUTE.md):
  setup, checks, commits, and the manual release process.
- [CI_CD_PIPELINE.md](https://github.com/farbenbuilds/tachyon/blob/main/CI_CD_PIPELINE.md):
  lint, test, Autobahn, and benchmark workflows.
- [SECURITY.md](https://github.com/farbenbuilds/tachyon/blob/main/SECURITY.md):
  vulnerability reporting and security scope.
- [AGENTS.md](https://github.com/farbenbuilds/tachyon/blob/main/AGENTS.md):
  repository rules for coding agents.
- [tests/README.md](https://github.com/farbenbuilds/tachyon/blob/main/tests/README.md):
  test tree, naming, and run commands.
- [examples/README.md](https://github.com/farbenbuilds/tachyon/blob/main/examples/README.md) and [benches/README.md](https://github.com/farbenbuilds/tachyon/blob/main/benches/README.md):
  echo examples, benchmark setup, results, and charts.
- [CODING_CONVENTION.md](https://github.com/farbenbuilds/tachyon/blob/main/CODING_CONVENTION.md):
  Zig style and safety rules.
- [THIRD_PARTY_NOTICES.md](https://github.com/farbenbuilds/tachyon/blob/main/THIRD_PARTY_NOTICES.md):
  dependency attribution.

## License

MIT. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](https://github.com/farbenbuilds/tachyon/blob/main/THIRD_PARTY_NOTICES.md).
