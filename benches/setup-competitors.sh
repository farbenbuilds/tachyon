#!/bin/sh
# Builds the optional comparison servers used by benches/run.mjs.
#
# Sources are fetched into BENCH_CACHE_DIR (default /tmp/tachyon-bench-cache)
# and installed binaries go to benches/.servers. Neither directory is bundled
# with the repository. Each target is best-effort; set SKIP_UWEBSOCKETS,
# SKIP_FASTWEBSOCKETS, SKIP_TOKIO_TUNGSTENITE, or SKIP_RUST_WEBSOCKET to skip
# one. Omit all four to build everything that is available.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/benches/.servers"
CACHE="${BENCH_CACHE_DIR:-/tmp/tachyon-bench-cache}"
CARGO="${CARGO:-cargo}"
CXX="${CXX:-g++}"
MAKE="${MAKE:-make}"

mkdir -p "$OUT" "$CACHE"

success=0
failed=0
skipped=0

log() {
    printf '%s\n' "$*"
}

clone_repo() {
    repo=$1
    dest=$2
    recursive=$3

    if [ -d "$dest/.git" ]; then
        log "using existing checkout: $dest"
        git -C "$dest" fetch --depth 1 origin >/dev/null 2>&1 || true
    else
        log "cloning https://github.com/$repo -> $dest"
        if [ "$recursive" = "1" ]; then
            git clone --depth 1 --recursive "https://github.com/$repo" "$dest" || return 1
        else
            git clone --depth 1 "https://github.com/$repo" "$dest" || return 1
        fi
    fi

    if [ "$recursive" = "1" ]; then
        git -C "$dest" submodule update --init --recursive --depth 1 || return 1
    fi
}

build_uwebsockets() {
    if [ -n "${SKIP_UWEBSOCKETS:-}" ]; then
        log "skip uWebSockets (SKIP_UWEBSOCKETS)"
        return 2
    fi

    src="$CACHE/uWebSockets"
    clone_repo uNetworking/uWebSockets "$src" 1 || return 1

    log "building uSockets and uWebSockets examples through the Makefile"
    "$MAKE" -C "$src" default WITH_LTO=0 || return 1
    if ! "$MAKE" -C "$src" examples WITH_LTO=0; then
        log "make examples returned nonzero; checking for the known ./build quirk"
    fi

    mkdir -p "$OUT/uWebSockets"
    if [ -f "$src/EchoServer" ]; then
        cp "$src/EchoServer" "$OUT/uWebSockets/EchoServer" || return 1
    else
        # Nix's glibc shell currently makes build.c's system() invocation fail
        # with "--: not found" even though the same g++ command works when run
        # directly. Keep this fallback only for that platform quirk.
        log "Makefile did not produce EchoServer; falling back to direct g++ compile"
        cxx=${CXX:-g++}
        zlib_cflags=${ZLIB_CFLAGS:-}
        zlib_libs=${ZLIB_LIBS:-}
        if [ -z "$zlib_libs" ] && command -v pkg-config >/dev/null 2>&1; then
            zlib_cflags=$(pkg-config --cflags zlib 2>/dev/null || true)
            zlib_libs=$(pkg-config --libs zlib 2>/dev/null || true)
        fi
        [ -n "$zlib_libs" ] || zlib_libs="-lz"
        # shellcheck disable=SC2086
        "$cxx" -O3 -std=c++2b $zlib_cflags \
            -I"$src/src" -I"$src/uSockets/src" \
            "$src/examples/EchoServer.cpp" "$src"/uSockets/*.o \
            $zlib_libs \
            -o "$OUT/uWebSockets/EchoServer" || return 1
    fi

    log "installed $OUT/uWebSockets/EchoServer"
}

build_fastwebsockets() {
    if [ -n "${SKIP_FASTWEBSOCKETS:-}" ]; then
        log "skip fastwebsockets (SKIP_FASTWEBSOCKETS)"
        return 2
    fi

    src="$CACHE/fastwebsockets"
    clone_repo denoland/fastwebsockets "$src" 0 || return 1

    log "building fastwebsockets echo_server"
    (cd "$src" && "$CARGO" build --release --example echo_server --features upgrade) || return 1

    mkdir -p "$OUT/fastwebsockets"
    cp "$src/target/release/examples/echo_server" "$OUT/fastwebsockets/echo_server" || return 1
    log "installed $OUT/fastwebsockets/echo_server"
}

build_tokio_tungstenite() {
    if [ -n "${SKIP_TOKIO_TUNGSTENITE:-}" ]; then
        log "skip tokio-tungstenite (SKIP_TOKIO_TUNGSTENITE)"
        return 2
    fi

    src="$CACHE/tokio-tungstenite"
    clone_repo snapview/tokio-tungstenite "$src" 0 || return 1

    log "building tokio-tungstenite echo-server"
    (cd "$src" && "$CARGO" build --release --example echo-server --features handshake) || return 1

    mkdir -p "$OUT/tokio-tungstenite"
    cp "$src/target/release/examples/echo-server" "$OUT/tokio-tungstenite/echo-server" || return 1
    log "installed $OUT/tokio-tungstenite/echo-server"
}

build_rust_websocket() {
    if [ -n "${SKIP_RUST_WEBSOCKET:-}" ]; then
        log "skip rust-websocket (SKIP_RUST_WEBSOCKET)"
        return 2
    fi

    src="$CACHE/rust-websocket"
    clone_repo websockets-rs/rust-websocket "$src" 0 || return 1

    log "building rust-websocket async-autobahn-server"
    # The default features include SSL. Point the openssl-sys build at the local
    # OpenSSL installation with OPENSSL_INCLUDE_DIR/OPENSSL_LIB_DIR when needed.
    (cd "$src" && "$CARGO" build --release --example async-autobahn-server --features async) || return 1

    mkdir -p "$OUT/rust-websocket"
    cp "$src/target/release/examples/async-autobahn-server" "$OUT/rust-websocket/async-autobahn-server" || return 1
    log "installed $OUT/rust-websocket/async-autobahn-server"
}

run_build() {
    name=$1
    fn=$2
    if "$fn"; then
        success=$((success + 1))
    else
        status=$?
        if [ "$status" -eq 2 ]; then
            skipped=$((skipped + 1))
        else
            failed=$((failed + 1))
            log "warning: $name was not built; continuing with the other targets"
        fi
    fi
}

run_build uWebSockets build_uwebsockets
run_build fastwebsockets build_fastwebsockets
run_build tokio-tungstenite build_tokio_tungstenite
run_build rust-websocket build_rust_websocket

log "competitor builds: $success installed, $failed failed, $skipped skipped"

if [ "$success" -eq 0 ]; then
    log "no competitor servers were installed"
    exit 1
fi
