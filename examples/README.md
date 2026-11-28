# tachyon examples

Build all examples:

```sh
zig build examples
```

The binaries are installed under `zig-out/bin/`. These steps require a full
repository checkout because the published package excludes `examples/` and
`benches/`.

## Echo server

```sh
./zig-out/bin/tachyon-echo-server
```

Listens on `ws://127.0.0.1:8080/` (set `PORT` to change it). The accept loop is
sequential and dispatches into a bounded `std.Io` task group; at the group limit,
work can run inline instead of on a separate task. The example performs the
strict HTTP upgrade, constructs and validates a `NativeWebSocket` before writing
the 101 response, echoes text, binary, and continuation frames, and relies on the
connection layer for automatic pong and close replies. Buffers are caller-owned
and allocated per connection.

## Split echo server

```sh
./zig-out/bin/tachyon-echo-server-split
```

Listens on `ws://127.0.0.1:8080/` (set `PORT` to change it). Uses
`upgrade.upgrade` to construct the split pair before writing the 101 response,
then echoes data frames through the independent read and write halves. Run it
instead of the unsplit server, not at the same time, because both default to
port 8080.

## Echo client

With one of the servers running:

```sh
./zig-out/bin/tachyon-echo-client
```

Connects to `ws://127.0.0.1:8080/`, performs the client handshake, sends one text
frame, verifies the echoed bytes, and closes the connection with status 1000.
Mask keys come from the caller's secure `std.Io` random source.

## Raw-frame echo behavior

The echo servers operate on raw WebSocket frames, not fully assembled messages.
They preserve fragmentation as received and rely on the connection layer's
clear-FIN text validation. A fragmented text message whose invalid UTF-8 spans
frames is therefore not validated as a whole. Use `MessageReader` or
`FragmentCollector` when strict cross-fragment UTF-8 validation is required.
