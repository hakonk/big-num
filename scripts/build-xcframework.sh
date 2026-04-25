#!/usr/bin/env bash
# Builds the Rust FFI library for every Apple architecture, packs the slices
# into `CBigNumRustCrypto.xcframework`, zips it, and prints the SHA-256
# checksum to paste into Package.swift's `.binaryTarget(checksum:)`.
#
# Must be run on macOS with Xcode (`xcodebuild`, `lipo`) and Rust
# (`cargo`, `rustup`) installed. This is the script CI invokes when cutting a
# release.
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

MACOS_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_DEVICE_TARGETS=(aarch64-apple-ios)
IOS_SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)
CATALYST_TARGETS=(aarch64-apple-ios-macabi x86_64-apple-ios-macabi)

ALL_TARGETS=(
    "${MACOS_TARGETS[@]}"
    "${IOS_DEVICE_TARGETS[@]}"
    "${IOS_SIM_TARGETS[@]}"
    "${CATALYST_TARGETS[@]}"
)

echo "==> Ensuring rustup targets are installed"
for t in "${ALL_TARGETS[@]}"; do
    rustup target add "$t" >/dev/null
done

echo "==> Building Rust staticlib for each Apple target"
pushd rust >/dev/null
for t in "${ALL_TARGETS[@]}"; do
    echo "    -> $t"
    cargo build --release --target "$t"
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

MACOS_LIB="$BUILD/macos-$ARCHIVE"
IOS_DEVICE_LIB="rust/target/${IOS_DEVICE_TARGETS[0]}/release/$ARCHIVE"
IOS_SIM_LIB="$BUILD/ios-sim-$ARCHIVE"
CATALYST_LIB="$BUILD/catalyst-$ARCHIVE"

fat "$MACOS_LIB" \
    "rust/target/aarch64-apple-darwin/release/$ARCHIVE" \
    "rust/target/x86_64-apple-darwin/release/$ARCHIVE"

fat "$IOS_SIM_LIB" \
    "rust/target/aarch64-apple-ios-sim/release/$ARCHIVE" \
    "rust/target/x86_64-apple-ios/release/$ARCHIVE"

fat "$CATALYST_LIB" \
    "rust/target/aarch64-apple-ios-macabi/release/$ARCHIVE" \
    "rust/target/x86_64-apple-ios-macabi/release/$ARCHIVE"

XCFRAMEWORK="$BUILD/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK"

echo "==> Assembling $FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
    -library "$MACOS_LIB"        -headers "$HEADERS" \
    -library "$IOS_DEVICE_LIB"   -headers "$HEADERS" \
    -library "$IOS_SIM_LIB"      -headers "$HEADERS" \
    -library "$CATALYST_LIB"     -headers "$HEADERS" \
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
