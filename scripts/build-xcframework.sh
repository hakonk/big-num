#!/usr/bin/env bash
# Builds the Rust FFI library for every Apple architecture, packs the slices
# into `CBigNumRustCrypto.xcframework`, zips it, and prints the SHA-256
# checksum to paste into Package.swift's `.binaryTarget(checksum:)`.
#
# Must be run on macOS with Xcode (`xcodebuild`, `lipo`) and Rust
# (`cargo`, `rustup`) installed.
#
# Default: macOS, iOS device, iOS simulator, Mac Catalyst.
# Optional Tier-3 platforms are gated behind environment flags because they
# require a nightly Rust toolchain, the `rust-src` component, and `-Z
# build-std`. Pass any combination of:
#   ENABLE_TVOS=1    ENABLE_WATCHOS=1    ENABLE_VISIONOS=1
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

# Tier-3 (require nightly + -Z build-std). Filled in based on env flags.
TVOS_DEVICE_TARGETS=()
TVOS_SIM_TARGETS=()
WATCHOS_DEVICE_TARGETS=()
WATCHOS_SIM_TARGETS=()
VISIONOS_DEVICE_TARGETS=()
VISIONOS_SIM_TARGETS=()
TIER3_TARGETS=()

if [[ "${ENABLE_TVOS:-0}" == "1" ]]; then
    TVOS_DEVICE_TARGETS=(aarch64-apple-tvos)
    TVOS_SIM_TARGETS=(aarch64-apple-tvos-sim x86_64-apple-tvos)
    TIER3_TARGETS+=("${TVOS_DEVICE_TARGETS[@]}" "${TVOS_SIM_TARGETS[@]}")
fi
if [[ "${ENABLE_WATCHOS:-0}" == "1" ]]; then
    WATCHOS_DEVICE_TARGETS=(aarch64-apple-watchos)
    WATCHOS_SIM_TARGETS=(aarch64-apple-watchos-sim x86_64-apple-watchos-sim)
    TIER3_TARGETS+=("${WATCHOS_DEVICE_TARGETS[@]}" "${WATCHOS_SIM_TARGETS[@]}")
fi
if [[ "${ENABLE_VISIONOS:-0}" == "1" ]]; then
    VISIONOS_DEVICE_TARGETS=(aarch64-apple-visionos)
    VISIONOS_SIM_TARGETS=(aarch64-apple-visionos-sim)
    TIER3_TARGETS+=("${VISIONOS_DEVICE_TARGETS[@]}" "${VISIONOS_SIM_TARGETS[@]}")
fi

echo "==> Ensuring stable rustup targets are installed"
for t in "${STABLE_TARGETS[@]}"; do
    rustup target add "$t" >/dev/null
done

if (( ${#TIER3_TARGETS[@]} > 0 )); then
    NIGHTLY_TOOLCHAIN="${NIGHTLY_TOOLCHAIN:-nightly}"
    echo "==> Tier-3 targets requested; ensuring $NIGHTLY_TOOLCHAIN + rust-src"
    rustup toolchain install "$NIGHTLY_TOOLCHAIN" --profile minimal >/dev/null
    rustup component add rust-src --toolchain "$NIGHTLY_TOOLCHAIN" >/dev/null
fi

echo "==> Building Rust staticlib for each stable Apple target"
pushd rust >/dev/null
for t in "${STABLE_TARGETS[@]}"; do
    echo "    -> $t"
    cargo build --release --target "$t"
done

if (( ${#TIER3_TARGETS[@]} > 0 )); then
    echo "==> Building Rust staticlib for each Tier-3 target (nightly + build-std)"
    for t in "${TIER3_TARGETS[@]}"; do
        echo "    -> $t"
        cargo "+$NIGHTLY_TOOLCHAIN" build --release \
            -Z build-std=core,alloc,std,panic_abort \
            --target "$t"
    done
fi
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

build_slice_lib "$MACOS_LIB"      "${MACOS_TARGETS[@]}"
build_slice_lib "$IOS_DEVICE_LIB" "${IOS_DEVICE_TARGETS[@]}"
build_slice_lib "$IOS_SIM_LIB"    "${IOS_SIM_TARGETS[@]}"
build_slice_lib "$CATALYST_LIB"   "${CATALYST_TARGETS[@]}"

XCFRAMEWORK_ARGS=(
    -library "$MACOS_LIB"        -headers "$HEADERS"
    -library "$IOS_DEVICE_LIB"   -headers "$HEADERS"
    -library "$IOS_SIM_LIB"      -headers "$HEADERS"
    -library "$CATALYST_LIB"     -headers "$HEADERS"
)

if (( ${#TVOS_DEVICE_TARGETS[@]} > 0 )); then
    TVOS_DEVICE_LIB="$BUILD/tvos-device-$ARCHIVE"
    TVOS_SIM_LIB="$BUILD/tvos-sim-$ARCHIVE"
    build_slice_lib "$TVOS_DEVICE_LIB" "${TVOS_DEVICE_TARGETS[@]}"
    build_slice_lib "$TVOS_SIM_LIB"    "${TVOS_SIM_TARGETS[@]}"
    XCFRAMEWORK_ARGS+=(
        -library "$TVOS_DEVICE_LIB" -headers "$HEADERS"
        -library "$TVOS_SIM_LIB"    -headers "$HEADERS"
    )
fi

if (( ${#WATCHOS_DEVICE_TARGETS[@]} > 0 )); then
    WATCHOS_DEVICE_LIB="$BUILD/watchos-device-$ARCHIVE"
    WATCHOS_SIM_LIB="$BUILD/watchos-sim-$ARCHIVE"
    build_slice_lib "$WATCHOS_DEVICE_LIB" "${WATCHOS_DEVICE_TARGETS[@]}"
    build_slice_lib "$WATCHOS_SIM_LIB"    "${WATCHOS_SIM_TARGETS[@]}"
    XCFRAMEWORK_ARGS+=(
        -library "$WATCHOS_DEVICE_LIB" -headers "$HEADERS"
        -library "$WATCHOS_SIM_LIB"    -headers "$HEADERS"
    )
fi

if (( ${#VISIONOS_DEVICE_TARGETS[@]} > 0 )); then
    VISIONOS_DEVICE_LIB="$BUILD/visionos-device-$ARCHIVE"
    VISIONOS_SIM_LIB="$BUILD/visionos-sim-$ARCHIVE"
    build_slice_lib "$VISIONOS_DEVICE_LIB" "${VISIONOS_DEVICE_TARGETS[@]}"
    build_slice_lib "$VISIONOS_SIM_LIB"    "${VISIONOS_SIM_TARGETS[@]}"
    XCFRAMEWORK_ARGS+=(
        -library "$VISIONOS_DEVICE_LIB" -headers "$HEADERS"
        -library "$VISIONOS_SIM_LIB"    -headers "$HEADERS"
    )
fi

XCFRAMEWORK="$BUILD/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK"

echo "==> Assembling $FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$XCFRAMEWORK" >/dev/null

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
