// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let defaultSwiftSettings: [SwiftSetting] =
    [
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
        .enableUpcomingFeature("InternalImportsByDefault"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        .enableUpcomingFeature("MemberImportVisibility"),
    ]

// MARK: - CBigNumRustCrypto target selection
//
// Apple platforms get a pre-built XCFramework (downloaded from a GitHub
// release, integrity-verified by SwiftPM via the SHA-256 in `checksum:`).
// Linux falls back to building the Rust crate from source via
// `scripts/build-rust.sh` and linking the resulting static archive.
//
// Set `BIGNUM_BUILD_FROM_SOURCE=1` when invoking `swift build`/`swift test`
// to opt into source builds on Apple too — useful when iterating on the FFI
// before cutting a release.

let env = ProcessInfo.processInfo.environment
let forceSource = env["BIGNUM_BUILD_FROM_SOURCE"] == "1"

#if canImport(Darwin)
let canUseBinary = !forceSource
#else
let canUseBinary = false
#endif

// Update both `url` and `checksum` on every release. Generate the checksum
// with `scripts/build-xcframework.sh` (it prints the value at the end).
let xcframeworkURL =
    "https://github.com/hakonk/big-num/releases/download/v0.2.0/CBigNumRustCrypto.xcframework.zip"
let xcframeworkChecksum =
    "REPLACE_WITH_SHA256_FROM_BUILD_XCFRAMEWORK_SH"

let cTarget: Target
let bigNumLinkerSettings: [LinkerSetting]

if canUseBinary {
    cTarget = .binaryTarget(
        name: "CBigNumRustCrypto",
        url: xcframeworkURL,
        checksum: xcframeworkChecksum
    )
    // The XCFramework already bundles the Rust static archive; SwiftPM links
    // it for us when the BigNum target depends on `CBigNumRustCrypto`.
    bigNumLinkerSettings = []
} else {
    cTarget = .target(
        name: "CBigNumRustCrypto",
        publicHeadersPath: "include"
    )
    bigNumLinkerSettings = [
        .unsafeFlags(["-L", "rust/target/release"]),
        .linkedLibrary("big_num_rustcrypto"),
    ]
}

let package = Package(
    name: "big-num",
    products: [
        .library(name: "BigNum", targets: ["BigNum"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BigNum",
            dependencies: ["CBigNumRustCrypto"],
            swiftSettings: defaultSwiftSettings,
            linkerSettings: bigNumLinkerSettings
        ),
        cTarget,
        .testTarget(
            name: "BigNumTests",
            dependencies: ["BigNum"],
            linkerSettings: bigNumLinkerSettings
        ),
    ]
)
