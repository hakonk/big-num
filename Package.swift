// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let defaultSwiftSettings: [SwiftSetting] =
    [
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
        .enableUpcomingFeature("InternalImportsByDefault"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        .enableUpcomingFeature("MemberImportVisibility"),
    ]

// The Rust static library is built out-of-band by `scripts/build-rust.sh`
// (invoked automatically by `swift build` / `swift test` via Docker or by
// developers locally). We link it using unsafe flags so the path stays
// relative to the package root.
let rustLibraryLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", "rust/target/release",
    ]),
    .linkedLibrary("big_num_rustcrypto"),
]

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
            linkerSettings: rustLibraryLinkerSettings
        ),
        .target(
            name: "CBigNumRustCrypto",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "BigNumTests",
            dependencies: ["BigNum"],
            linkerSettings: rustLibraryLinkerSettings
        ),
    ]
)
