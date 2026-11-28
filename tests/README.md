# tachyon - Test Suite

The Zig test suite lives under `tests/` and is aggregated by `tests/main.zig`.
Library sources contain no test blocks; new coverage belongs in the category
folders described here.

The published Zig package is runtime-only and does not include `tests/`. Run the
suite from a full repository checkout; a fetched package ships the build files,
the generated zon2nix views, `flake.nix`, `flake.lock`, `src/`, `LICENSE`, and
`README.md` only.

## Test Tree

| Path | Files | Coverage |
| --- | --- | --- |
| `tests/main.zig` | `main.zig` | Aggregates every category test file for the Debug and ReleaseSafe steps. |
| `tests/support.zig` | `support.zig` | Shared fixtures and test-only readers and writers. |
| `tests/module-test/` | `*_test.zig` | Dependency boundary and public re-exports. |
| `tests/error-test/` | `*_test.zig` | Error taxonomy, mappings, close-code policy, and classification helpers. |
| `tests/backpressure-test/` | `*_test.zig` | Watermarks, admission, producer pause and resume, close, overflow, and reset. |
| `tests/frame-test/` | `*_test.zig` | Frame facade, close codes, masking, write paths, and strict or negotiated RSV1. |
| `tests/utf8-test/` | `*_test.zig` | Incremental UTF-8 validation and reader adaptation. |
| `tests/fragment-test/` | `*_test.zig` | Fragment accumulator, collector reads and policy, and compressed UTF-8 deferral. |
| `tests/connection-test/` | `*_test.zig` | Connection core, control replies, close handling, limits, reads, writes, backpressure, and RSV1. |
| `tests/stream-test/` | `*_test.zig` | Chunked reads, control interleaving, incremental UTF-8, close and error latches, writer ordering, masking, limits, watermark retries, and RSV1 state. |
| `tests/pubsub-test/` | `*_test.zig` | Hub capacity, duplicate and unknown topics, unsubscribe and id reuse, index churn, fanout, sender exclusion, payload borrowing, backpressure skips, reentrancy, and name lifetime. |
| `tests/split-test/` | `*_test.zig` | Split core, reads, outbound-pressure independence, and `FragmentCollectorRead`. |
| `tests/native-stream-test/` | `*_test.zig` | `std.Io.net.Stream` transport binding, native `WebSocket`, native `Split`, watermark delegation, and buffer-alias rejection. |
| `tests/deflate-test/` | `*_test.zig` | Codec roundtrips, context takeover, sender windows 8 through 15 with stored fallback, output bounds, malformed input, aliasing, adapter boundaries, and RFC 7692 vectors. |
| `tests/handshake-test/` | `*_test.zig` | Request, head, response, client handshake, and permessage-deflate offer, selection, and response subsets. |
| `tests/upgrade-test/` | `*_test.zig` | Server upgrade call order, validation, split construction, and async borrowing. |
| `tests/autobahn-test/server.zig` | `server.zig` | Repository-only Autobahn echo fixture; not aggregated by `tests/main.zig`. |

The deflate category covers the RFC 7692 message payload codec, including sender
windows 8 through 15 with the stored-block fallback. Negotiated RSV1 and
handshake negotiation are implemented in the library, but compression remains
edge-composed. DEFLATE has no integrity or checksum, so some truncated or
corrupted streams can still decode to a shorter or wrong message. Decompressed
output is untrusted.

## Naming

Name test blocks `<Area>: <behavior>`, for example
`Frame: encodes a masked extended-length header`. Keep one behavior per block,
assert typed errors for failure paths, and follow the boundary and malformed
input coverage in [AGENTS.md](../AGENTS.md#testing-guidelines).

## Running

```sh
zig build test              # Debug and ReleaseSafe suites over tests/main.zig
zig build test --summary all
zig build check             # Type-check the library and tests
zig build autobahn-server -Doptimize=ReleaseSafe  # Repository-only Autobahn echo fixture
zig fmt --check .           # Formatting gate
```

`zig build test` runs the aggregate twice, once with Debug safety and once with
ReleaseSafe, so overflow and bounds behavior is exercised in both modes.
`.github/workflows/test.yml` runs the same test step plus `zig build check` for
pull requests into `main` and pushes to `main` whenever a Zig or Zon file,
`build.zig`, or a workflow file changes. Each run records a deployment in the
`Testing` environment.

The native-stream tests open a loopback TCP pair through the caller's
`std.Io.Threaded` instance. They exercise the real `std.Io.net.Stream.reader`
and `std.Io.net.Stream.writer` paths without spawning a test task: the listening
backlog lets `connect` complete before `accept`, and the frames fit in the
kernel socket buffers.

`zig build autobahn-server -Doptimize=ReleaseSafe` builds and installs
`zig-out/bin/tachyon-autobahn` without changing the default library-only
`zig build`. The published package excludes `tests/`, so this step requires a
full repository checkout.

## Autobahn Integration

`tests/autobahn-test/server.zig` is a repository-only executable echo fixture.
It is not part of `zig build test` and is not imported by `tests/main.zig`; the
Autobahn suite is the integration test.

The fixture binds `127.0.0.1:9001` and accepts one connection at a time. Each
connection passes through strict `upgrade.incoming` validation, a shared
`handshake.write_response` or `handshake.write_response_with_extensions` 101
response, the native `std.Io.net.Stream` transport, and an assembled message
echo that returns text and binary messages as one FIN frame. Automatic pong and
close handling stay in the connection layer; peer failures map to close codes
1002 and 1007, and oversized messages map to 1009. Negotiated permessage-deflate
messages are inflated before text validation and echoed with RSV1; uncompressed
clients keep the strict path. The fixture encodes or parses no frame header and
applies no mask.

`.github/workflows/autobahn.yml` builds the fixture and runs
`farbenbuilds/autobahn-action`, pinned to commit
`1c4d57b3ca48e1ddf742e5ae1ab4ce5b51625b36` (`v1`), over the configured case set
`1.* 2.* 3.* 4.* 5.* 6.* 7.* 9.* 10.* 11.* 12.* 13.*`. Group 8 is absent from
the pinned testsuite, and the action's default list omits it; the gate covers
every case the suite ships (1-7, 9-13). Compression groups 11-13 are enabled
through the fixture's negotiated permessage-deflate composition. A green run is
evidence only for the configured case set, not a full Autobahn or compression
compliance claim.

## Adding Coverage

1. Choose the matching `tests/<area>-test/` folder, or add a new category folder
   when the protocol area does not have one.
2. Add focused tests to an existing `<concern>_test.zig` file or create a new
   file for a distinct concern.
3. Import a new file from `tests/main.zig`.
4. Reuse `tests/support.zig` for fixtures shared by more than one category.
5. Add the new file to the table above and add a category row when it
   introduces a folder.
6. Run `zig build test` and `zig fmt --check .` before review.

Fuzzing and a full loopback echo suite remain future integration work.
