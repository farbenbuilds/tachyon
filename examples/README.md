# tachyon examples

Build all examples:

```sh
zig build examples
```

The binaries are installed under `zig-out/bin/`.

## Echo server

```sh
./zig-out/bin/tachyon-echo-server
```

Listens on `ws://127.0.0.1:8080/`. The accept loop is sequential, but each
accepted connection runs in its own `std.Io` task. The example performs the
strict HTTP upgrade, binds a `NativeWebSocket`, echoes text, binary, and
continuation frames, and relies on the connection layer for automatic pong and
close replies. Buffers are caller-owned and allocated per connection.

## Split echo server

```sh
./zig-out/bin/tachyon-echo-server-split
```

Uses `upgrade.upgrade` to construct the split pair before writing the 101
response, then echoes data frames through the independent read and write halves.
Run it instead of the unsplit server, not at the same time, because both bind
port 8080.

## Echo client

With one of the servers running:

```sh
./zig-out/bin/tachyon-echo-client
```

Connects to `ws://127.0.0.1:8080/`, performs the client handshake, sends one text
frame, verifies the echoed bytes, and closes the connection with status 1000.
Mask keys come from the caller's secure `std.Io` random source.

## Why Swerver is not used

[Swerver](https://github.com/justinGrosvenor/swerver) is not included as a
WebSocket server example. Its documentation lists WebSocket server support for
1.0, its current main targets Zig 0.16, and it fails to build with Zig 0.17.1
because `b.args` was removed. It is therefore not a usable WebSocket server for
this tree, and adding it as a dependency or shipping a broken example would not
demonstrate tachyon. The direct `tachyon-echo-server` and
`tachyon-echo-server-split` examples above use the public upgrade, native stream,
and split APIs instead.
