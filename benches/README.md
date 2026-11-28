# tachyon benchmarks

The benchmark tools measure the tachyon data path and compare echo throughput
with several other WebSocket servers.

## Build

```sh
zig build examples benches -Doptimize=ReleaseFast
```

This installs:

- `zig-out/bin/tachyon-echo-server`
- `zig-out/bin/tachyon-load-test`
- `zig-out/bin/tachyon-unmask`

`zig build` remains library-only; the examples and benchmark steps are opt-in.

## Load generator

```sh
./zig-out/bin/tachyon-load-test <host> <port> <connections> <duration_seconds> <payload_bytes>
```

Each connection performs the tachyon client handshake, sends one binary message,
reads the echo, and repeats. The tool prints `Msg/sec <n>` once per second and a
final `Final Msg/sec <n>` line. Buffers are caller-owned per worker, and mask
keys use a deterministic seed for reproducibility.

Example against the bundled echo server:

```sh
./zig-out/bin/tachyon-echo-server &
./zig-out/bin/tachyon-load-test 127.0.0.1 8080 10 2 1024
```

## Unmask benchmark

```sh
./zig-out/bin/tachyon-unmask
```

Allocates a 64 MiB payload and repeatedly runs `tachyon.unmask`, then prints
`bytes/sec` and `GB/s`. The codec performs no allocation; the benchmark allocates
only its own buffer.

## Comparison runner

```sh
node benches/run.mjs
```

The runner executes the original comparison cases:

| Connections | Payload |
| ---: | ---: |
| 100 | 20 B |
| 10 | 1 KiB |
| 10 | 16 KiB |
| 200 | 16 KiB |
| 500 | 16 KiB |

For each case and target it starts the server, waits for the port, runs the load
generator for `BENCH_DURATION` seconds (default 5), averages the per-second
samples, stops the server, and records the result. It writes:

- `benches/results.md`
- `benches/results.json`

The Markdown table is printed to stdout; the JSON includes samples, skipped
targets, and per-case errors. Missing targets are skipped rather than failing the
run.

### Targets and overrides

| Target | Default command | Port | Environment override |
| --- | --- | ---: | --- |
| tachyon | `zig-out/bin/tachyon-echo-server` | 8080 | `TACHYON_ECHO_SERVER` |
| uWebSockets | `node benches/servers/uwebsockets.mjs` | 9001 | `UWEBSOCKETS_SERVER` (script path) |
| fastwebsockets | `../fastwebsockets/target/release/examples/echo_server` | 8080 | `FASTWEBSOCKETS_SERVER` |
| tokio-tungstenite | `../tokio-tungstenite/target/release/examples/echo-server` | 8080 | `TOKIO_TUNGSTENITE_SERVER` |
| rust-websocket | `../rust-websocket/target/release/examples/async-autobahn-server` | 9002 | `RUST_WEBSOCKET_SERVER` |

Ports can be overridden with `TACHYON_PORT`, `UWEBSOCKETS_PORT`,
`FASTWEBSOCKETS_PORT`, `TOKIO_TUNGSTENITE_PORT`, and `RUST_WEBSOCKET_PORT`.
`TACHYON_LOAD_TEST` overrides the load generator path.

Node 22 is required for the uWebSockets.js target: its native addon currently
segfaults on Node 24. The runner itself and the other targets are otherwise
Node-version-agnostic, so use Node 22 when running the full target list. The
benchmark workflow pins Node 22 for that reason.

The uWebSockets target is installed only for benchmarks:

```sh
npm install --prefix benches
```

Build the comparison servers from their own repositories. For example:

```sh
git clone https://github.com/denoland/fastwebsockets
cargo build --release --manifest-path fastwebsockets/Cargo.toml --example echo_server
export FASTWEBSOCKETS_SERVER="$PWD/fastwebsockets/target/release/examples/echo_server"
```

The runner also accepts sibling checkouts at the default paths shown above.

## CI

`.github/workflows/bench.yml` is manual (`workflow_dispatch`) and runs weekly on
a schedule. It sets up Node 22, builds the tachyon tools, installs the Node
benchmark dependency, attempts the Rust comparison servers with
`continue-on-error`, runs `node benches/run.mjs`, appends `results.md` to the job
summary, and uploads `results.md` and `results.json`.

The comparison builds are best-effort. Results are useful for relative
throughput checks, not as a compliance claim, and they depend on the runner,
kernel, connection setup, payload mix, and the other servers' versions.
