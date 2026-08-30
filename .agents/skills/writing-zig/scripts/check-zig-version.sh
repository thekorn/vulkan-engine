#!/usr/bin/env bash
set -euo pipefail

zig_cmd="${ZIG_CMD:-zig}"
expected="0.17.0-dev.1509+bb296ab9b"

if ! command -v "$zig_cmd" >/dev/null 2>&1; then
    printf 'ERROR: zig not found; set ZIG_CMD or enter `nix develop`.\n' >&2
    exit 1
fi

actual="$($zig_cmd version)"
if [[ "$actual" != "$expected" ]]; then
    printf 'ERROR: expected Zig %s, found %s.\n' "$expected" "$actual" >&2
    exit 1
fi

printf 'OK: Zig %s detected.\n' "$actual"
