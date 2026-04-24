///
/// BigNum.swift
/// A Swift wrapper around the Rust `big_num_rustcrypto` crate, which exposes a
/// BoringSSL-BIGNUM-style API backed by RustCrypto's `crypto-bigint` and
/// `crypto-primes`.
/// Originally inspired by https://github.com/Bouke/Bignum
///

internal import CBigNumRustCrypto

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Swift wrapper class over the opaque `RCBigNum` handle vended by the Rust
/// FFI. Each instance owns its underlying handle and frees it on `deinit`.
public final class BigNum {
    @usableFromInline
    internal let ctx: OpaquePointer

    internal init(takingOwnership ptr: OpaquePointer) {
        self.ctx = ptr
    }

    private static func take(_ ptr: OpaquePointer?) -> OpaquePointer {
        guard let ptr else { preconditionFailure("BigNum FFI returned NULL") }
        return ptr
    }

    public init() {
        self.ctx = Self.take(rc_bignum_new())
    }

    public init(_ int: Int) {
        self.ctx = Self.take(rc_bignum_from_i64(Int64(int)))
    }

    public init?(_ dec: String) {
        guard let ptr = dec.withCString({ rc_bignum_from_dec($0) }) else {
            return nil
        }
        self.ctx = ptr
    }

    public init?(hex: String) {
        guard let ptr = hex.withCString({ rc_bignum_from_hex($0) }) else {
            return nil
        }
        self.ctx = ptr
    }

    public init<D: ContiguousBytes>(bytes: D) {
        let ptr: OpaquePointer = bytes.withUnsafeBytes { buf in
            let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return Self.take(rc_bignum_from_be_bytes(base, buf.count))
        }
        self.ctx = ptr
    }

    deinit {
        rc_bignum_free(ctx)
    }

    /// Raw big-endian byte representation, trimmed of leading zeroes. Value 0
    /// yields an empty `Data`.
    public var data: Data {
        let length = rc_bignum_to_be_bytes(ctx, nil, 0)
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        data.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            _ = rc_bignum_to_be_bytes(ctx, base, length)
        }
        return data
    }

    public var bytes: [UInt8] {
        let length = rc_bignum_to_be_bytes(ctx, nil, 0)
        guard length > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: length)
        out.withUnsafeMutableBufferPointer { buf in
            _ = rc_bignum_to_be_bytes(ctx, buf.baseAddress, length)
        }
        return out
    }

    public var dec: String {
        guard let cStr = rc_bignum_to_dec(ctx) else { return "" }
        defer { rc_bignum_free_cstr(cStr) }
        return String(cString: cStr)
    }

    public var hex: String {
        guard let cStr = rc_bignum_to_hex(ctx) else { return "" }
        defer { rc_bignum_free_cstr(cStr) }
        return String(cString: cStr)
    }
}

extension BigNum: CustomStringConvertible {
    public var description: String { self.dec }
}

extension BigNum: Comparable {
    public static func == (lhs: BigNum, rhs: BigNum) -> Bool {
        rc_bignum_equal(lhs.ctx, rhs.ctx) == 1
    }

    public static func < (lhs: BigNum, rhs: BigNum) -> Bool {
        rc_bignum_cmp(lhs.ctx, rhs.ctx) == -1
    }
}

extension BigNum: ExpressibleByIntegerLiteral {
    public typealias IntegerLiteralType = Int

    public convenience init(integerLiteral value: Int) {
        self.init(value)
    }
}

// MARK: - Binary arithmetic operators

private func wrap(_ ptr: OpaquePointer?) -> BigNum {
    guard let ptr else { preconditionFailure("BigNum FFI returned NULL") }
    return BigNum(takingOwnership: ptr)
}

public func + (lhs: BigNum, rhs: BigNum) -> BigNum {
    wrap(rc_bignum_add(lhs.ctx, rhs.ctx))
}

public func - (lhs: BigNum, rhs: BigNum) -> BigNum {
    wrap(rc_bignum_sub(lhs.ctx, rhs.ctx))
}

public func * (lhs: BigNum, rhs: BigNum) -> BigNum {
    wrap(rc_bignum_mul(lhs.ctx, rhs.ctx))
}

/// Returns `lhs / rhs`, rounded toward zero.
public func / (lhs: BigNum, rhs: BigNum) -> BigNum {
    wrap(rc_bignum_div(lhs.ctx, rhs.ctx))
}

/// Returns `lhs % rhs`.
public func % (lhs: BigNum, rhs: BigNum) -> BigNum {
    wrap(rc_bignum_mod(lhs.ctx, rhs.ctx))
}

public func >> (lhs: BigNum, shift: Int32) -> BigNum {
    wrap(rc_bignum_rshift(lhs.ctx, UInt32(shift)))
}

public func << (lhs: BigNum, shift: Int32) -> BigNum {
    wrap(rc_bignum_lshift(lhs.ctx, UInt32(shift)))
}

// MARK: - Member operations

extension BigNum {
    public static func += (lhs: inout BigNum, rhs: BigNum) { lhs = lhs + rhs }
    public static func -= (lhs: inout BigNum, rhs: BigNum) { lhs = lhs - rhs }
    public static func *= (lhs: inout BigNum, rhs: BigNum) { lhs = lhs * rhs }
    public static func /= (lhs: inout BigNum, rhs: BigNum) { lhs = lhs / rhs }
    public static func %= (lhs: inout BigNum, rhs: BigNum) { lhs = lhs % rhs }

    /// Returns: `self ** 2`.
    public func sqr() -> BigNum {
        wrap(rc_bignum_sqr(ctx))
    }

    /// Returns: `self ** p`.
    public func power(_ p: BigNum) -> BigNum {
        wrap(rc_bignum_exp(ctx, p.ctx))
    }

    /// Returns: `(self + b) % N`.
    public func add(_ b: BigNum, modulus: BigNum) -> BigNum {
        wrap(rc_bignum_mod_add(ctx, b.ctx, modulus.ctx))
    }

    /// Returns: `(self - b) % N`.
    public func sub(_ b: BigNum, modulus: BigNum) -> BigNum {
        wrap(rc_bignum_mod_sub(ctx, b.ctx, modulus.ctx))
    }

    /// Returns: `(self * b) % N`.
    public func mul(_ b: BigNum, modulus: BigNum) -> BigNum {
        wrap(rc_bignum_mod_mul(ctx, b.ctx, modulus.ctx))
    }

    /// Returns: `(self ** 2) % N`.
    public func sqr(modulus: BigNum) -> BigNum {
        wrap(rc_bignum_mod_sqr(ctx, modulus.ctx))
    }

    /// Returns: `(self ** p) % N`. The modulus must be odd (every use site in
    /// the Swift layer passes odd primes). Passing an even modulus will
    /// trigger a precondition failure.
    public func power(_ p: BigNum, modulus: BigNum) -> BigNum {
        wrap(rc_bignum_mod_exp(ctx, p.ctx, modulus.ctx))
    }

    /// Greatest common denominator.
    public static func gcd(_ first: BigNum, _ second: BigNum) -> BigNum {
        wrap(rc_bignum_gcd(first.ctx, second.ctx))
    }

    // MARK: Bit operations

    public func setBit(_ bit: Int32) {
        rc_bignum_set_bit(ctx, UInt32(bit))
    }

    public func clearBit(_ bit: Int32) {
        rc_bignum_clear_bit(ctx, UInt32(bit))
    }

    public func mask(_ bits: Int32) {
        rc_bignum_mask_bits(ctx, UInt32(bits))
    }

    public func isBitSet(_ bit: Int32) -> Bool {
        rc_bignum_is_bit_set(ctx, UInt32(bit)) == 1
    }

    public func numBits() -> UInt32 {
        rc_bignum_num_bits(ctx)
    }

    // MARK: Random generation

    public enum Top: Int32 {
        case any = -1
        case topBitSetToOne = 0
        case topTwoBitsSetToOne = 1
    }

    /// Cryptographically strong random number of maximum size defined in bits.
    public static func random(bits: Int32, top: Top = .any, odd: Bool = false) -> BigNum {
        wrap(rc_bignum_rand_bits(UInt32(bits), top.rawValue, odd ? 1 : 0))
    }

    /// Retained for source-compatibility. `crypto-bigint` only ships a CSPRNG
    /// path, so this is identical to ``random(bits:top:odd:)``.
    public static func psuedo_random(bits: Int32, top: Top = .any, odd: Bool = false) -> BigNum {
        random(bits: bits, top: top, odd: odd)
    }

    /// Cryptographically strong random number in range `0..<max`.
    public static func random(max: BigNum) -> BigNum {
        wrap(rc_bignum_rand_range(max.ctx))
    }

    /// See ``psuedo_random(bits:top:odd:)``.
    public static func psuedo_random(max: BigNum) -> BigNum {
        random(max: max)
    }

    // MARK: Primes

    /// Generate a random prime of the requested bit size.
    ///
    /// The `add` / `remainder` parameters that BoringSSL's
    /// `BN_generate_prime_ex` exposed are not supported by `crypto-primes`.
    /// They are accepted for source-compatibility but must be `nil`.
    public static func generatePrime(
        bitSize: Int32,
        safe: Bool,
        add: BigNum? = nil,
        remainder: BigNum? = nil
    ) -> BigNum {
        precondition(
            add == nil && remainder == nil,
            "generatePrime(add:remainder:) is no longer supported by the RustCrypto backend"
        )
        return wrap(rc_bignum_generate_prime(UInt32(bitSize), safe ? 1 : 0))
    }

    /// Probabilistic primality check. `numChecks` is accepted for
    /// source-compatibility but ignored — `crypto-primes` performs a
    /// Baillie-PSW test, which has no known counterexamples.
    public func isPrime(numChecks: Int32) -> Bool {
        rc_bignum_is_prime(ctx) == 1
    }
}

/// TODO: Remove this when we move to the next major version
extension BigNum: @unchecked Sendable {}
