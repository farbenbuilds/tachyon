#!/usr/bin/env sh

set -eu

if [ ! -f build.zig.zon ]; then
    exit 0
fi

if command -v zon2nix >/dev/null 2>&1; then
    zon2nix \
        --17 \
        --nix=build.zig.zon.nix \
        --json=build.zig.zon.json \
        --txt=build.zig.zon.txt \
        build.zig.zon
elif command -v nix >/dev/null 2>&1; then
    nix develop -c zon2nix \
        --17 \
        --nix=build.zig.zon.nix \
        --json=build.zig.zon.json \
        --txt=build.zig.zon.txt \
        build.zig.zon
else
    echo "zon2nix and nix not found" >&2
    exit 1
fi
