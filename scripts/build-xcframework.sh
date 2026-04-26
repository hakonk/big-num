#!/usr/bin/env bash
# Builds the Rust FFI library for every supported Apple architecture, packs
# the slices into `CBigNumRustCrypto.xcframework`, zips it, and prints the
# SHA-256 checksum to paste into Package.swift's `.binaryTarget(checksum:)`.
#
# Must be run on macOS with Xcode (`xcodebuild`, `lipo`) and Rust
# (`cargo`, `rustup`) installed.
#
# Slice coverage:
#   Tier-1/2 (stable rustup):  macOS, iOS device, iOS simulator, Mac Catalyst
#   Tier-3   (nightly + -Z build-std):  tvOS device, tvOS simulator,
#                                       watchOS device, watchOS simulator,
#                                       visionOS device, visionOS simulator
#
# Both toolchains are pinned for reproducibility: stable comes from
# `rust/rust-toolchain.toml`, and the nightly date is `NIGHTLY_TOOLCHAIN`
# below. Bump the nightly date deliberately when a Tier-3 target needs it.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script must run on macOS (needs xcodebuild + lipo)." >&2
    exit 1
fi

for tool in cargo rustup xcodebuild lipo zip swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool not found in PATH: $tool" >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$script_dir/.." && pwd)"
cd "$pkg_root"

LIB_NAME="big_num_rustcrypto"
ARCHIVE="lib${LIB_NAME}.a"
FRAMEWORK_NAME="CBigNumRustCrypto"

# Pinned nightly date — Tier-3 Apple targets (tvOS / watchOS / visionOS)
# require nightly + `-Z build-std`, but we want every release to come from
# the same compiler. Override with `NIGHTLY_TOOLCHAIN=nightly-YYYY-MM-DD`
# if you need to test a different date.
NIGHTLY_TOOLCHAIN="${NIGHTLY_TOOLCHAIN:-nightly-2026-03-01}"

# Tier-1 / Tier-2 (work with stock stable rustup).
MACOS_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_DEVICE_TARGETS=(aarch64-apple-ios)
IOS_SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)
CATALYST_TARGETS=(aarch64-apple-ios-macabi x86_64-apple-ios-macabi)

STABLE_TARGETS=(
    "${MACOS_TARGETS[@]}"
    "${IOS_DEVICE_TARGETS[@]}"
    "${IOS_SIM_TARGETS[@]}"
    "${CATALYST_TARGETS[@]}"
)

# Tier-3 (require nightly + -Z build-std). Always built.
TVOS_DEVICE_TARGETS=(aarch64-apple-tvos)
TVOS_SIM_TARGETS=(aarch64-apple-tvos-sim x86_64-apple-tvos)
WATCHOS_DEVICE_TARGETS=(aarch64-apple-watchos)
WATCHOS_SIM_TARGETS=(aarch64-apple-watchos-sim x86_64-apple-watchos-sim)
VISIONOS_DEVICE_TARGETS=(aarch64-apple-visionos)
VISIONOS_SIM_TARGETS=(aarch64-apple-visionos-sim)

TIER3_TARGETS=(
    "${TVOS_DEVICE_TARGETS[@]}" "${TVOS_SIM_TARGETS[@]}"
    "${WATCHOS_DEVICE_TARGETS[@]}" "${WATCHOS_SIM_TARGETS[@]}"
    "${VISIONOS_DEVICE_TARGETS[@]}" "${VISIONOS_SIM_TARGETS[@]}"
)

echo "==> Ensuring stable rustup targets are installed"
for t in "${STABLE_TARGETS[@]}"; do
    rustup target add "$t" >/dev/null
done

echo "==> Ensuring $NIGHTLY_TOOLCHAIN + rust-src for Tier-3 targets"
rustup toolchain install "$NIGHTLY_TOOLCHAIN" --profile minimal >/dev/null
rustup component add rust-src --toolchain "$NIGHTLY_TOOLCHAIN" >/dev/null

echo "==> Building Rust staticlib for each stable Apple target"
pushd rust >/dev/null
for t in "${STABLE_TARGETS[@]}"; do
    echo "    -> $t"
    cargo build --release --target "$t"
done

echo "==> Building Rust staticlib for each Tier-3 target (nightly + build-std)"
for t in "${TIER3_TARGETS[@]}"; do
    echo "    -> $t"
    cargo "+$NIGHTLY_TOOLCHAIN" build --release \
        -Z build-std=core,alloc,std,panic_abort \
        --target "$t"
done
popd >/dev/null

# Stage everything under build/xcframework/
BUILD="$pkg_root/build/xcframework"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Headers + module map shared by every slice.
HEADERS="$BUILD/Headers"
mkdir -p "$HEADERS"
cp Sources/CBigNumRustCrypto/include/CBigNumRustCrypto.h "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<EOF
module $FRAMEWORK_NAME {
    header "CBigNumRustCrypto.h"
    export *
}
EOF

fat() {
    local output="$1"; shift
    echo "==> lipo $(basename "$output")"
    lipo -create "$@" -output "$output"
}

# Convenience: turn a target list into a single .a (passes through if there's
# only one arch, lipos otherwise).
build_slice_lib() {
    local out="$1"; shift
    local libs=()
    for target in "$@"; do
        libs+=("rust/target/$target/release/$ARCHIVE")
    done
    if (( ${#libs[@]} == 1 )); then
        cp "${libs[0]}" "$out"
    else
        fat "$out" "${libs[@]}"
    fi
}

MACOS_LIB="$BUILD/macos-$ARCHIVE"
IOS_DEVICE_LIB="$BUILD/ios-device-$ARCHIVE"
IOS_SIM_LIB="$BUILD/ios-sim-$ARCHIVE"
CATALYST_LIB="$BUILD/catalyst-$ARCHIVE"
TVOS_DEVICE_LIB="$BUILD/tvos-device-$ARCHIVE"
TVOS_SIM_LIB="$BUILD/tvos-sim-$ARCHIVE"
WATCHOS_DEVICE_LIB="$BUILD/watchos-device-$ARCHIVE"
WATCHOS_SIM_LIB="$BUILD/watchos-sim-$ARCHIVE"
VISIONOS_DEVICE_LIB="$BUILD/visionos-device-$ARCHIVE"
VISIONOS_SIM_LIB="$BUILD/visionos-sim-$ARCHIVE"

build_slice_lib "$MACOS_LIB"          "${MACOS_TARGETS[@]}"
build_slice_lib "$IOS_DEVICE_LIB"     "${IOS_DEVICE_TARGETS[@]}"
build_slice_lib "$IOS_SIM_LIB"        "${IOS_SIM_TARGETS[@]}"
build_slice_lib "$CATALYST_LIB"       "${CATALYST_TARGETS[@]}"
build_slice_lib "$TVOS_DEVICE_LIB"    "${TVOS_DEVICE_TARGETS[@]}"
build_slice_lib "$TVOS_SIM_LIB"       "${TVOS_SIM_TARGETS[@]}"
build_slice_lib "$WATCHOS_DEVICE_LIB" "${WATCHOS_DEVICE_TARGETS[@]}"
build_slice_lib "$WATCHOS_SIM_LIB"    "${WATCHOS_SIM_TARGETS[@]}"
build_slice_lib "$VISIONOS_DEVICE_LIB" "${VISIONOS_DEVICE_TARGETS[@]}"
build_slice_lib "$VISIONOS_SIM_LIB"    "${VISIONOS_SIM_TARGETS[@]}"

XCFRAMEWORK="$BUILD/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK"

echo "==> Assembling $FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
    -library "$MACOS_LIB"           -headers "$HEADERS" \
    -library "$IOS_DEVICE_LIB"      -headers "$HEADERS" \
    -library "$IOS_SIM_LIB"         -headers "$HEADERS" \
    -library "$CATALYST_LIB"        -headers "$HEADERS" \
    -library "$TVOS_DEVICE_LIB"     -headers "$HEADERS" \
    -library "$TVOS_SIM_LIB"        -headers "$HEADERS" \
    -library "$WATCHOS_DEVICE_LIB"  -headers "$HEADERS" \
    -library "$WATCHOS_SIM_LIB"     -headers "$HEADERS" \
    -library "$VISIONOS_DEVICE_LIB" -headers "$HEADERS" \
    -library "$VISIONOS_SIM_LIB"    -headers "$HEADERS" \
    -output "$XCFRAMEWORK" >/dev/null

ZIP="$BUILD/$FRAMEWORK_NAME.xcframework.zip"
rm -f "$ZIP"
echo "==> Zipping XCFramework"
( cd "$BUILD" && zip -ryq "$(basename "$ZIP")" "$(basename "$XCFRAMEWORK")" )

CHECKSUM="$(swift package compute-checksum "$ZIP")"

cat <<EOF

Done.

Artifact : $ZIP
Checksum : $CHECKSUM

Next steps:
  1. Upload $ZIP to a GitHub release.
  2. Update Package.swift's .binaryTarget(url:checksum:) entries:
        url:      https://github.com/<owner>/<repo>/releases/download/<tag>/$FRAMEWORK_NAME.xcframework.zip
        checksum: $CHECKSUM
  3. Tag and push.
EOF
