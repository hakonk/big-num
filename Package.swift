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

let package = Package(
    name: "big-num",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(name: "BigNum", targets: ["BigNum"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BigNum",
            dependencies: ["CBigNumBoringSSL"],
            swiftSettings: defaultSwiftSettings
        ),
        // Vendored by scripts/vendor-boringssl-2.sh; the stamp below is
        // rewritten by the script on each re-vendor.
        // BoringSSL Commit: d589045a772678d5ca131f4c8087d001b9258380
        .target(
            name: "CBigNumBoringSSL",
            // Provenance patches are attestation metadata, not build inputs.
            exclude: ["provenance"]
        ),
        .testTarget(name: "BigNumTests", dependencies: ["BigNum"]),
    ],
    cxxLanguageStandard: .cxx17
)
