///
/// BigNum inline-annotation benchmark
///
/// Measures per-operation cost for the most common BigNum operations so you
/// can verify before/after the @inline(__always) / @inlinable annotations.
///
/// Usage:
///   swift run -c release Benchmarks
///
/// Always build with -c release (or swift build -c release); optimisations
/// such as @inline(__always) only fire under -O.
///

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import BigNum

// ---------------------------------------------------------------------------
// Minimal benchmark harness — no external dependencies.
// Runs `iterations` calls to `body`, discards the first `warmup` iterations,
// and reports the median wall-clock nanoseconds per call.
// ---------------------------------------------------------------------------

/// Returns current time in nanoseconds from a monotonic clock.
@inline(__always)
func nanoTime() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

func benchmark(
    _ name: String,
    warmup: Int = 500,
    iterations: Int = 50_000,
    body: () -> Void
) {
    // Warm up — fills instruction caches, triggers JIT-like branch prediction.
    for _ in 0..<warmup { body() }

    var samples = [Double]()
    samples.reserveCapacity(iterations)

    for _ in 0..<iterations {
        let t0 = nanoTime()
        body()
        let t1 = nanoTime()
        samples.append(Double(t1 - t0))
    }

    samples.sort()
    let median = samples[samples.count / 2]
    let p95    = samples[Int(Double(samples.count) * 0.95)]
    let mean   = samples.reduce(0, +) / Double(samples.count)

    print(String(
        format: "%-35s  median %6.1f ns   mean %6.1f ns   p95 %6.1f ns",
        name, median, mean, p95
    ))
}

// ---------------------------------------------------------------------------
// Prevent the compiler from eliminating benchmark calls as dead code.
// ---------------------------------------------------------------------------
@inline(never)
func blackHole<T>(_ x: T) { _ = x }

// ---------------------------------------------------------------------------
// Fixed operands — created once so allocation is not part of the measurement.
// ---------------------------------------------------------------------------
let a   = BigNum(12345678901234567)
let b   = BigNum(98765432109876543)
let mod = BigNum("115792089237316195423570985008687907853269984665640564039457584007913129639747")!
let exp = BigNum(65537)

print("BigNum micro-benchmarks  (build: \(ProcessInfo.processInfo.arguments[0]))")
print(String(repeating: "-", count: 78))

// Comparison — the tightest loop imaginable; benefits most from inlining.
benchmark("== (equal comparison)") {
    blackHole(a == b)
}

benchmark("< (less-than comparison)") {
    blackHole(a < b)
}

// Arithmetic
benchmark("+ (addition)") {
    blackHole(a + b)
}

benchmark("- (subtraction)") {
    blackHole(b - a)
}

benchmark("* (multiplication)") {
    blackHole(a * b)
}

benchmark("/ (division)") {
    blackHole(b / a)
}

benchmark("% (modulo)") {
    blackHole(b % a)
}

// Modular arithmetic — the hot path in most cryptographic code.
benchmark("mul(_:modulus:)") {
    blackHole(a.mul(b, modulus: mod))
}

benchmark("sqr(modulus:)") {
    blackHole(a.sqr(modulus: mod))
}

// power(_:modulus:) is intentionally run with fewer iterations — it is slow.
benchmark("power(_:modulus:)", warmup: 5, iterations: 200) {
    blackHole(a.power(exp, modulus: mod))
}

// Bit operations — often called in tight loops.
benchmark("numBits()") {
    blackHole(a.numBits())
}

benchmark("isBitSet(_:)") {
    blackHole(a.isBitSet(7))
}

// Conversion
benchmark("bytes property") {
    blackHole(a.bytes)
}

benchmark("dec property") {
    blackHole(a.dec)
}

print(String(repeating: "-", count: 78))
print("""

How to interpret:
  • Median is the most representative single-call cost.
  • p95 shows worst-case tail latency.
  • Noise ±5 ns is normal on a loaded machine.

To measure the effect of inlining annotations:
  1. Run once with the annotations in place:
       swift run -c release Benchmarks | tee after.txt
  2. Temporarily remove @inline(__always) from BigNum.operation /
     operationWithCtx, rebuild, and run again:
       swift run -c release Benchmarks | tee before.txt
  3. diff before.txt after.txt

The helpers (operation / operationWithCtx) are called by every arithmetic
operator, so the improvement shows up across all of the benchmarks above.
""")
