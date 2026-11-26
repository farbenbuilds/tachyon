# tachyon - Test Suite

The Zig test suite lives under `tests/` and is aggregated by `tests/main.zig`.
Library sources contain no test blocks; new coverage belongs in the category
folders described here.

The published Zig package is runtime-only and does not include `tests/`. Run the
suite from a full repository checkout; a fetched package ships the build files,
the generated zon2nix views, `flake.nix`, `flake.lock`, `src/`, `LICENSE`, and
`README.md` only.

## File Tree

```text
tests/
├── README.md
├── main.zig                              # Aggregates every category test file.
├── support.zig                           # Shared fixtures and test-only readers and writers.
├── module-test/
│   └── module_test.zig                   # Dependency boundary and public re-exports.
├── error-test/
│   └── error_test.zig                    # Error taxonomy, mappings, and close-code policy.
├── backpressure-test/
│   └── backpressure_test.zig             # Watermarks, admission, producer pause/resume, close, reset.
├── frame-test/
│   └── frame_test.zig                    # Frame facade, close codes, masking, and write paths.
├── utf8-test/
│   └── utf8_test.zig                     # Incremental UTF-8 validation and reader adaptation.
├── fragment-test/
│   ├── fragments_test.zig                # Fragment accumulator.
│   ├── collector_read_test.zig           # Collector reads and continuation assembly.
│   └── collector_policy_test.zig         # Collector limits and failure latching.
├── connection-test/
│   ├── connection_core_test.zig          # Construction, storage, and role policy.
│   ├── connection_control_test.zig       # Automatic ping and pong behavior.
│   ├── connection_close_test.zig         # Close validation, echo, and gating.
│   ├── connection_limits_test.zig        # Message-size limits and bounds.
│   ├── connection_read_test.zig          # Raw read path and failure latches.
│   ├── connection_write_test.zig         # Copied and vectored write paths.
│   └── connection_backpressure_test.zig  # Watermark batching, control reserve, and close paths.
├── stream-test/
│   ├── reader_chunks_test.zig            # Chunk order, FIN, borrow, and length boundaries.
│   ├── reader_control_test.zig           # Control interleaving, UTF-8, close, and latches.
│   ├── writer_test.zig                   # Writer ordering, masking, limits, and backpressure.
│   └── state_test.zig                    # Pure reader and writer state transitions.
├── split-test/
│   ├── split_core_test.zig               # Split construction and frame exchange.
│   ├── split_read_test.zig               # Read-half obligations and gating.
│   ├── split_backpressure_test.zig       # Backpressure-independent reads and collector behavior.
│   └── split_collector_test.zig          # FragmentCollectorRead over a split half.
├── native-stream-test/
│   └── native_stream_test.zig            # std.Io.net.Stream transport, WebSocket, and Split.
├── deflate-test/
│   ├── deflate_test.zig                  # Sender roundtrips, context takeover, aliasing, limits, and configuration.
│   └── inflate_test.zig                  # Receiver bounds, structurally invalid streams, BFINAL, adapter boundaries, and RFC vector.
├── handshake-test/
│   ├── handshake_request_test.zig        # Server request construction and validation.
│   ├── handshake_head_test.zig           # Bounded HTTP head parsing.
│   ├── handshake_response_test.zig       # Response verification and token checks.
│   └── handshake_client_test.zig         # Client handshake flow.
└── upgrade-test/
    └── upgrade_test.zig                  # Server upgrade call order and async borrowing.
```

Category folders use the `<area>-test/` naming pattern, and test files use
`<concern>_test.zig`. The folders follow the protocol layers:

| Folder | Coverage |
| --- | --- |
| `module-test` | Dependency boundary and public module re-exports. |
| `error-test` | Error taxonomy, mappings, close-code policy, and classification helpers. |
| `backpressure-test` | Watermark validation, data admission, control bypass, close draining, overflow, and reset. |
| `frame-test` | Frame facade, close codes, masking, and write paths. |
| `utf8-test` | Incremental UTF-8 validation and reader adaptation. |
| `fragment-test` | Fragment accumulator, collector reads, and collector policy. |
| `connection-test` | Connection core, control replies, close handling, limits, reads, writes, and watermark batching. |
| `stream-test` | Chunked message reads, control interleaving, incremental UTF-8, close and error latches, writer ordering, masking, limits, and watermark retries. |
| `split-test` | Split core, reads, outbound-pressure independence, and `FragmentCollectorRead`. |
| `native-stream-test` | `std.Io.net.Stream` transport binding, native `WebSocket`, native `Split`, watermark delegation, and buffer-alias rejection. |
| `deflate-test` | Codec payload roundtrips, context and no-context takeover, compression bounds, exact-full and decompression-bomb output, structurally invalid input, truncation behavior, aliasing, adapter boundaries, and RFC 7692 vector decoding. |
| `handshake-test` | Request, head, response, and client handshake behavior. |
| `upgrade-test` | Server upgrade call order, including validation and async behavior. |

The deflate category covers the RFC 7692 message payload codec only. It does not
claim wire activation, negotiated RSV1 support, or Autobahn compliance; those
remain blocked on zslay and the handshake layer. Malformed input that leaves a
non-clean block boundary fails closed, but DEFLATE has no integrity or checksum,
so some truncated or corrupted streams can still decode to a shorter or wrong
message. Decompressed output is untrusted.

`tests/main.zig` imports every category test file in one `test` block. It is the
root module for both the Debug and ReleaseSafe test steps. `tests/support.zig`
holds shared fixtures and test-only readers and writers; category files that
need them import the support file instead of duplicating fixtures.

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

## Adding Coverage

1. Choose the matching `tests/<area>-test/` folder, or add a new category folder
   when the protocol area does not have one.
2. Add focused tests to an existing `<concern>_test.zig` file or create a new
   file for a distinct concern.
3. Import a new file from `tests/main.zig`.
4. Reuse `tests/support.zig` for fixtures shared by more than one category.
5. Add the new file to the tree above and to the category table when it
   introduces a folder.
6. Run `zig build test` and `zig fmt --check .` before review.

## Future Integration Suites

Autobahn, fuzz, and loopback echo suites belong under `tests/` as new category
folders. None of these compliance suites is implemented yet. This tree currently
provides unit coverage
plus the loopback native-stream integration described above; do not claim
Autobahn, fuzz, or a full loopback echo compliance suite until those suites
exist and pass.
