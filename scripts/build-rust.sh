#!/usr/bin/env bash
# Builds the Rust FFI library (`libbig_num_rustcrypto.a`) that the Swift
# `BigNum` target links against. Must be run before `swift build` or
# `swift test`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$script_dir/.." && pwd)"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install Rust via https://rustup.rs/" >&2
    exit 1
fi

cd "$pkg_root/rust"

# Release build for performance; the resulting static archive lives at
# rust/target/release/libbig_num_rustcrypto.a (this path is what
# Package.swift references via -L rust/target/release).
cargo build --release

echo "Built $(pwd)/target/release/libbig_num_rustcrypto.a"
