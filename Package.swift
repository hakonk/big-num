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

// C-level settings for the vendored BoringSSL target.
//
// BoringSSL's hot arithmetic paths (Montgomery multiply, modular
// exponentiation) are implemented in hand-written assembly that is already
// at peak efficiency.  The C settings below affect the surrounding C code
// (addition, shift, GCD, prime testing, error handling, …).
//
// Safe flags — usable even when this package is consumed as a dependency:
//
//   .define("NDEBUG", .when(configuration: .release))
//     Suppresses C assert() calls in release builds.  BoringSSL uses its own
//     compile-time OPENSSL_COMPILE_ASSERT for invariants, but some code paths
//     still call assert().  NDEBUG is harmless for the security model because
//     BoringSSL's runtime checks rely on its own BN_check_top / BSSL_CHECK
//     macros, not on assert().
//
// Unsafe flags — only valid for a top-level application; packages that are
// imported by other packages must NOT use unsafeFlags or the consuming build
// will fail:
//
//   .unsafeFlags(["-O3"], .when(configuration: .release))
//     Promotes C optimisation from -O2 (SPM default) to -O3, enabling
//     -funroll-loops and more aggressive inlining.  Measurable benefit on
//     the C portions of add/sub/shift and on the GCD / prime-testing paths.
//
//   .unsafeFlags(["-march=native"], .when(configuration: .release))
//     Allows the compiler to emit instructions for the exact CPU being used.
//     The assembly files already runtime-dispatch on CPUID (e.g. RSAZ-AVX2
//     for modular exponentiation), so this mainly helps the C portions.
//     Cannot be used for cross-compilation or distributed binaries.
//
// To apply the unsafe flags locally without breaking dependent packages,
// override them in a top-level Package.swift via:
//   package.targets.first { $0.name == "CBigNumBoringSSL" }?
//       .customSettings = [ .unsafeFlags(["-O3", "-march=native"]) ]
// (Swift 5.10+ only; see SE-NNNN for details.)
let boringSSLCSettings: [CSetting] = [
    // Disable C assert() in release builds; NDEBUG is respected by BoringSSL.
    .define("NDEBUG", .when(configuration: .release)),
]

let package = Package(
    name: "big-num",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(name: "BigNum", targets: ["BigNum"])
        /* This target is used only for symbol mangling. It's added and removed automatically because it emits build warnings. MANGLE_START
            .library(name: "CBigNumBoringSSL", type: .static, targets: ["CBigNumBoringSSL"]),
            MANGLE_END */
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BigNum",
            dependencies: ["CBigNumBoringSSL"],
            swiftSettings: defaultSwiftSettings
        ),
        .target(name: "CBigNumBoringSSL", cSettings: boringSSLCSettings),
        .testTarget(name: "BigNumTests", dependencies: ["BigNum"]),
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["BigNum"],
            path: "Sources/Benchmarks",
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
