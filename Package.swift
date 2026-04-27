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

// MARK: - Backend selection
//
// `BigNum` ships with two interchangeable C/Rust backends. Pick one with the
// `BIGNUM_BACKEND` environment variable when invoking SwiftPM:
//
//   BIGNUM_BACKEND=rustcrypto   (default)  RustCrypto's crypto-bigint via FFI
//   BIGNUM_BACKEND=boringssl              vendored cut-down BoringSSL BIGNUM
//
// The two backends expose the same public Swift API; the choice only affects
// what gets compiled, downloaded, and linked. Mixing both in a single build
// is unsupported.

let env = ProcessInfo.processInfo.environment
let backend = env["BIGNUM_BACKEND"]?.lowercased() ?? "rustcrypto"

guard ["rustcrypto", "boringssl"].contains(backend) else {
    fatalError("Unknown BIGNUM_BACKEND: \(backend); use 'rustcrypto' or 'boringssl'")
}

// MARK: RustCrypto-specific knobs (ignored when backend == "boringssl")
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

// MARK: Per-backend target configuration

let backendTarget: Target
let bigNumDependencies: [Target.Dependency]
let bigNumLinkerSettings: [LinkerSetting]
let bigNumSwiftSettings: [SwiftSetting]

switch backend {
case "rustcrypto":
    if canUseBinary {
        backendTarget = .binaryTarget(
            name: "CBigNumRustCrypto",
            url: xcframeworkURL,
            checksum: xcframeworkChecksum
        )
        bigNumLinkerSettings = []
    } else {
        backendTarget = .target(
            name: "CBigNumRustCrypto",
            publicHeadersPath: "include"
        )
        bigNumLinkerSettings = [
            .unsafeFlags(["-L", "rust/target/release"]),
            .linkedLibrary("big_num_rustcrypto"),
        ]
    }
    bigNumDependencies = ["CBigNumRustCrypto"]
    bigNumSwiftSettings = defaultSwiftSettings + [.define("BIGNUM_BACKEND_RUSTCRYPTO")]

case "boringssl":
    backendTarget = .target(name: "CBigNumBoringSSL")
    bigNumDependencies = ["CBigNumBoringSSL"]
    bigNumLinkerSettings = []
    bigNumSwiftSettings = defaultSwiftSettings + [.define("BIGNUM_BACKEND_BORINGSSL")]

default:
    fatalError("unreachable")
}

let testLinkerSettings: [LinkerSetting] = bigNumLinkerSettings

let package = Package(
    name: "big-num",
    products: [
        .library(name: "BigNum", targets: ["BigNum"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BigNum",
            dependencies: bigNumDependencies,
            swiftSettings: bigNumSwiftSettings,
            linkerSettings: bigNumLinkerSettings
        ),
        backendTarget,
        .testTarget(
            name: "BigNumTests",
            dependencies: ["BigNum"],
            linkerSettings: testLinkerSettings
        ),
    ]
)
