//! C FFI wrapper exposing a BoringSSL-BIGNUM-like API backed by RustCrypto's
//! `crypto-bigint` (`BoxedUint`) and `crypto-primes`.
//!
//! Memory management:
//! - `BIGNUM*` values returned by the constructors must be released with
//!   `rc_bignum_free`.
//! - `char*` values returned by the stringification helpers must be released
//!   with `rc_bignum_free_cstr`.
//!
//! All integers are non-negative; modular operations require an odd modulus
//! when called via `rc_bignum_mod_exp` (matches the inputs used by the Swift
//! wrapper).

use core::ffi::{c_char, c_int};
use std::ffi::{CStr, CString};

use crypto_bigint::{
    BitOps, BoxedUint, CheckedAdd, CheckedSub, ConcatenatingMul, ConcatenatingSquare, CtEq, Gcd,
    NonZero, Odd, RandomBits, RandomMod, Resize,
};
use crypto_bigint::rand_core::UnwrapErr;
use crypto_primes::{Flavor, is_prime, random_prime};
use getrandom::SysRng;

/// Crypto-grade RNG suitable for both `Rng` and `CryptoRng` bounds.
fn rng() -> UnwrapErr<SysRng> {
    UnwrapErr(SysRng)
}

/// Minimum precision we round up to so tiny values still have room to grow.
const MIN_PRECISION: u32 = 64;

/// Round a bit count up to the next multiple of 64 so it is a valid BoxedUint
/// precision.
fn round_precision(bits: u32) -> u32 {
    let bits = bits.max(MIN_PRECISION);
    (bits + 63) & !63
}

/// Ensure `n` has *at least* `at_least_bits` precision, widening a copy if
/// needed. Returns either a borrowed reference or an owned widened value.
fn widen_to(n: &BoxedUint, at_least_bits: u32) -> BoxedUint {
    let target = round_precision(at_least_bits);
    if n.bits_precision() >= target {
        n.clone()
    } else {
        n.resize(target)
    }
}

/// Align two operands to have the same precision (the greater of the two, plus
/// any requested extra headroom).
fn align_pair(a: &BoxedUint, b: &BoxedUint, extra: u32) -> (BoxedUint, BoxedUint) {
    let target = round_precision(a.bits_precision().max(b.bits_precision()) + extra);
    (a.resize(target), b.resize(target))
}

/// Opaque handle exposed to C. Transparent over Box<BoxedUint> so that the
/// pointer is directly usable as `*mut BoxedUint`.
#[repr(transparent)]
pub struct RCBigNum(BoxedUint);

fn into_handle(n: BoxedUint) -> *mut RCBigNum {
    Box::into_raw(Box::new(RCBigNum(n)))
}

unsafe fn as_ref<'a>(ptr: *const RCBigNum) -> Option<&'a BoxedUint> {
    if ptr.is_null() { None } else { Some(unsafe { &(*ptr).0 }) }
}

unsafe fn as_mut<'a>(ptr: *mut RCBigNum) -> Option<&'a mut BoxedUint> {
    if ptr.is_null() { None } else { Some(unsafe { &mut (*ptr).0 }) }
}

// --- lifecycle ---------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn rc_bignum_new() -> *mut RCBigNum {
    into_handle(BoxedUint::zero_with_precision(MIN_PRECISION))
}

#[unsafe(no_mangle)]
pub extern "C" fn rc_bignum_from_i64(value: i64) -> *mut RCBigNum {
    // Values are non-negative in the Swift API; negative inputs are treated as
    // their unsigned two's complement representation (same as BoringSSL's
    // BN_bin2bn on the raw bytes of `value.bigEndian`).
    let bytes = (value as u64).to_be_bytes();
    let n = BoxedUint::from_be_slice(&bytes, 64).expect("64 bits is always valid");
    into_handle(n)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_from_be_bytes(
    bytes: *const u8,
    len: usize,
) -> *mut RCBigNum {
    if bytes.is_null() && len != 0 {
        return std::ptr::null_mut();
    }
    let slice = if len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    let bits = round_precision((len as u32).saturating_mul(8));
    let n = BoxedUint::from_be_slice(slice, bits)
        .unwrap_or_else(|_| BoxedUint::zero_with_precision(MIN_PRECISION));
    into_handle(n)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_from_dec(s: *const c_char) -> *mut RCBigNum {
    if s.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(s) = (unsafe { CStr::from_ptr(s) }).to_str() else {
        return std::ptr::null_mut();
    };
    match BoxedUint::from_str_radix_vartime(s, 10) {
        Ok(n) => into_handle(n),
        Err(_) => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_from_hex(s: *const c_char) -> *mut RCBigNum {
    if s.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(s) = (unsafe { CStr::from_ptr(s) }).to_str() else {
        return std::ptr::null_mut();
    };
    let trimmed = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    match BoxedUint::from_str_radix_vartime(trimmed, 16) {
        Ok(n) => into_handle(n),
        Err(_) => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_free(n: *mut RCBigNum) {
    if !n.is_null() {
        drop(unsafe { Box::from_raw(n) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_free_cstr(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

// --- accessors ---------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_num_bits(n: *const RCBigNum) -> u32 {
    let Some(n) = (unsafe { as_ref(n) }) else { return 0 };
    n.bits_vartime()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_to_be_bytes(
    n: *const RCBigNum,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let Some(n) = (unsafe { as_ref(n) }) else { return 0 };
    let trimmed = n.to_be_bytes_trimmed_vartime();
    let copy_len = trimmed.len().min(out_len);
    if copy_len > 0 && !out.is_null() {
        unsafe { std::ptr::copy_nonoverlapping(trimmed.as_ptr(), out, copy_len) };
    }
    trimmed.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_to_dec(n: *const RCBigNum) -> *mut c_char {
    let Some(n) = (unsafe { as_ref(n) }) else { return std::ptr::null_mut() };
    let s = n.to_string_radix_vartime(10);
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_to_hex(n: *const RCBigNum) -> *mut c_char {
    let Some(n) = (unsafe { as_ref(n) }) else { return std::ptr::null_mut() };
    // BoringSSL emits uppercase hex; match that for byte-for-byte compatibility
    // with existing callers.
    let s = n.to_string_radix_vartime(16).to_uppercase();
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

// --- comparison --------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_cmp(a: *const RCBigNum, b: *const RCBigNum) -> c_int {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return 0;
    };
    let (a, b) = align_pair(a, b, 0);
    use core::cmp::Ordering::*;
    match a.cmp(&b) {
        Less => -1,
        Equal => 0,
        Greater => 1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_equal(a: *const RCBigNum, b: *const RCBigNum) -> c_int {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return 0;
    };
    let (a, b) = align_pair(a, b, 0);
    if bool::from(a.ct_eq(&b)) { 1 } else { 0 }
}

// --- arithmetic --------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_add(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let (a, b) = align_pair(a, b, 1);
    match a.checked_add(&b).into() {
        Some(r) => into_handle(r),
        None => {
            // Overflow past the aligned precision: widen more and retry.
            let target = round_precision(a.bits_precision().saturating_mul(2));
            let a = a.resize(target);
            let b = b.resize(target);
            into_handle(a.wrapping_add(&b))
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_sub(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let (a, b) = align_pair(a, b, 0);
    // BoringSSL's BN_sub is signed and produces negative results for a < b.
    // Since the Swift layer only deals with non-negative values, we mirror a
    // similar behavior: if b > a, return 0 (callers are expected to avoid this
    // scenario). This matches the unsigned semantics of BoxedUint.
    match a.checked_sub(&b).into() {
        Some(r) => into_handle(r),
        None => into_handle(BoxedUint::zero_with_precision(a.bits_precision())),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mul(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let needed = a.bits_vartime() + b.bits_vartime() + 1;
    let target = round_precision(needed);
    let a = widen_to(a, target);
    let b = widen_to(&b, target);
    // `concatenating_mul` returns a value whose precision is the sum of the two
    // operand precisions; resize back down to the minimum that still fits the
    // result so downstream operations stay cheap.
    into_handle(a.concatenating_mul(&b).resize(target))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_div(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let (a, b) = align_pair(a, b, 0);
    let Some(nz) = Option::<NonZero<BoxedUint>>::from(b.to_nz()) else {
        return std::ptr::null_mut();
    };
    let (q, _) = a.div_rem_vartime(&nz);
    into_handle(q)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let (a, b) = align_pair(a, b, 0);
    let Some(nz) = Option::<NonZero<BoxedUint>>::from(b.to_nz()) else {
        return std::ptr::null_mut();
    };
    let (_, r) = a.div_rem_vartime(&nz);
    into_handle(r)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_sqr(a: *const RCBigNum) -> *mut RCBigNum {
    let Some(a) = (unsafe { as_ref(a) }) else { return std::ptr::null_mut() };
    let needed = a.bits_vartime().saturating_mul(2) + 1;
    let target = round_precision(needed);
    let widened = widen_to(a, target);
    into_handle(widened.concatenating_square().resize(target))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_exp(a: *const RCBigNum, p: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(p)) = (unsafe { as_ref(a) }, unsafe { as_ref(p) }) else {
        return std::ptr::null_mut();
    };
    // Approximate output size: bits(a) * numeric_value(p).
    // Pull `p` into a u64; anything larger would blow up memory anyway.
    let p_val = {
        let bytes = p.to_be_bytes_trimmed_vartime();
        if bytes.len() > 8 {
            return std::ptr::null_mut();
        }
        let mut buf = [0u8; 8];
        buf[8 - bytes.len()..].copy_from_slice(&bytes);
        u64::from_be_bytes(buf)
    };
    let needed = (a.bits_vartime() as u64).saturating_mul(p_val).saturating_add(1);
    if needed > u32::MAX as u64 {
        return std::ptr::null_mut();
    }
    let needed = round_precision(needed as u32);
    let a_wide = widen_to(a, needed);
    let p_wide = widen_to(p, needed);
    match a_wide.checked_pow_vartime(&p_wide).into() {
        Some(r) => into_handle(r),
        None => std::ptr::null_mut(),
    }
}

// --- modular arithmetic ------------------------------------------------------

fn mod_align(
    a: &BoxedUint,
    b: &BoxedUint,
    n: &BoxedUint,
) -> Option<(BoxedUint, BoxedUint, NonZero<BoxedUint>)> {
    let target = round_precision(
        a.bits_precision()
            .max(b.bits_precision())
            .max(n.bits_precision()),
    );
    let a = a.resize(target);
    let b = b.resize(target);
    let n = n.resize(target);
    Option::<NonZero<BoxedUint>>::from(n.to_nz()).map(|nz| (a, b, nz))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod_add(
    a: *const RCBigNum,
    b: *const RCBigNum,
    n: *const RCBigNum,
) -> *mut RCBigNum {
    let (Some(a), Some(b), Some(n)) = (
        unsafe { as_ref(a) },
        unsafe { as_ref(b) },
        unsafe { as_ref(n) },
    ) else {
        return std::ptr::null_mut();
    };
    let Some((a, b, nz)) = mod_align(a, b, n) else {
        return std::ptr::null_mut();
    };
    // Reduce inputs first so add_mod's "inputs in range" precondition holds.
    let (_, a_red) = a.div_rem_vartime(&nz);
    let (_, b_red) = b.div_rem_vartime(&nz);
    into_handle(a_red.add_mod(&b_red, &nz))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod_sub(
    a: *const RCBigNum,
    b: *const RCBigNum,
    n: *const RCBigNum,
) -> *mut RCBigNum {
    let (Some(a), Some(b), Some(n)) = (
        unsafe { as_ref(a) },
        unsafe { as_ref(b) },
        unsafe { as_ref(n) },
    ) else {
        return std::ptr::null_mut();
    };
    let Some((a, b, nz)) = mod_align(a, b, n) else {
        return std::ptr::null_mut();
    };
    let (_, a_red) = a.div_rem_vartime(&nz);
    let (_, b_red) = b.div_rem_vartime(&nz);
    into_handle(a_red.sub_mod(&b_red, &nz))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod_mul(
    a: *const RCBigNum,
    b: *const RCBigNum,
    n: *const RCBigNum,
) -> *mut RCBigNum {
    let (Some(a), Some(b), Some(n)) = (
        unsafe { as_ref(a) },
        unsafe { as_ref(b) },
        unsafe { as_ref(n) },
    ) else {
        return std::ptr::null_mut();
    };
    let Some((a, b, nz)) = mod_align(a, b, n) else {
        return std::ptr::null_mut();
    };
    let (_, a_red) = a.div_rem_vartime(&nz);
    let (_, b_red) = b.div_rem_vartime(&nz);
    into_handle(a_red.mul_mod(&b_red, &nz))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod_sqr(
    a: *const RCBigNum,
    n: *const RCBigNum,
) -> *mut RCBigNum {
    let (Some(a), Some(n)) = (unsafe { as_ref(a) }, unsafe { as_ref(n) }) else {
        return std::ptr::null_mut();
    };
    let target = round_precision(a.bits_precision().max(n.bits_precision()));
    let a = a.resize(target);
    let n = n.resize(target);
    let Some(nz) = Option::<NonZero<BoxedUint>>::from(n.to_nz()) else {
        return std::ptr::null_mut();
    };
    let (_, a_red) = a.div_rem_vartime(&nz);
    into_handle(a_red.square_mod(&nz))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mod_exp(
    a: *const RCBigNum,
    p: *const RCBigNum,
    n: *const RCBigNum,
) -> *mut RCBigNum {
    let (Some(a), Some(p), Some(n)) = (
        unsafe { as_ref(a) },
        unsafe { as_ref(p) },
        unsafe { as_ref(n) },
    ) else {
        return std::ptr::null_mut();
    };
    let target = round_precision(
        a.bits_precision()
            .max(p.bits_precision())
            .max(n.bits_precision()),
    );
    let a = a.resize(target);
    let p = p.resize(target);
    let n = n.resize(target);
    // `pow_mod` requires an odd modulus; this matches every test in the Swift
    // suite (all moduli are odd primes).
    let Some(odd) = Option::<Odd<BoxedUint>>::from(n.to_odd()) else {
        return std::ptr::null_mut();
    };
    let Some(nz) = Option::<NonZero<BoxedUint>>::from(odd.clone().get().to_nz()) else {
        return std::ptr::null_mut();
    };
    let (_, a_red) = a.div_rem_vartime(&nz);
    into_handle(a_red.pow_mod(&p, &odd))
}

// --- gcd ---------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_gcd(a: *const RCBigNum, b: *const RCBigNum) -> *mut RCBigNum {
    let (Some(a), Some(b)) = (unsafe { as_ref(a) }, unsafe { as_ref(b) }) else {
        return std::ptr::null_mut();
    };
    let (a, b) = align_pair(a, b, 0);
    into_handle(a.gcd(&b))
}

// --- shifts ------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_lshift(a: *const RCBigNum, shift: u32) -> *mut RCBigNum {
    let Some(a) = (unsafe { as_ref(a) }) else { return std::ptr::null_mut() };
    let needed = a.bits_vartime().saturating_add(shift) + 1;
    let widened = widen_to(a, needed);
    match widened.overflowing_shl_vartime(shift) {
        Some(r) => into_handle(r),
        None => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_rshift(a: *const RCBigNum, shift: u32) -> *mut RCBigNum {
    let Some(a) = (unsafe { as_ref(a) }) else { return std::ptr::null_mut() };
    match a.overflowing_shr_vartime(shift) {
        Some(r) => into_handle(r),
        None => into_handle(BoxedUint::zero_with_precision(a.bits_precision())),
    }
}

// --- bit ops -----------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_set_bit(a: *mut RCBigNum, bit: u32) {
    let Some(a) = (unsafe { as_mut(a) }) else { return };
    if bit >= a.bits_precision() {
        *a = (&*a).resize(round_precision(bit + 1));
    }
    a.set_bit_vartime(bit, true);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_clear_bit(a: *mut RCBigNum, bit: u32) {
    let Some(a) = (unsafe { as_mut(a) }) else { return };
    if bit >= a.bits_precision() {
        return;
    }
    a.set_bit_vartime(bit, false);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_is_bit_set(a: *const RCBigNum, bit: u32) -> c_int {
    let Some(a) = (unsafe { as_ref(a) }) else { return 0 };
    if bit >= a.bits_precision() {
        return 0;
    }
    if a.bit_vartime(bit) { 1 } else { 0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_mask_bits(a: *mut RCBigNum, bits: u32) {
    let Some(a) = (unsafe { as_mut(a) }) else { return };
    let prec = a.bits_precision();
    if bits >= prec {
        return;
    }
    // Clear everything above `bits`.
    for i in bits..prec {
        a.set_bit_vartime(i, false);
    }
}

// --- random ------------------------------------------------------------------

/// top: -1 = any, 0 = top bit set to 1, 1 = top two bits set to 1 (mirrors
/// BoringSSL's BN_RAND_TOP_* constants).
#[unsafe(no_mangle)]
pub extern "C" fn rc_bignum_rand_bits(bits: u32, top: c_int, odd: c_int) -> *mut RCBigNum {
    if bits == 0 {
        return into_handle(BoxedUint::zero_with_precision(MIN_PRECISION));
    }
    let mut rng = rng();
    let prec = round_precision(bits);
    let mut n = BoxedUint::random_bits(&mut rng, bits);
    // Ensure the precision is the rounded value so later ops behave.
    if n.bits_precision() < prec {
        n = n.resize(prec);
    }
    match top {
        0 => n.set_bit_vartime(bits - 1, true),
        1 => {
            n.set_bit_vartime(bits - 1, true);
            if bits >= 2 {
                n.set_bit_vartime(bits - 2, true);
            }
        }
        _ => {}
    }
    if odd != 0 {
        n.set_bit_vartime(0, true);
    }
    into_handle(n)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_rand_range(max: *const RCBigNum) -> *mut RCBigNum {
    let Some(max) = (unsafe { as_ref(max) }) else { return std::ptr::null_mut() };
    let Some(nz) = Option::<NonZero<BoxedUint>>::from(max.to_nz()) else {
        return std::ptr::null_mut();
    };
    let mut rng = rng();
    into_handle(BoxedUint::random_mod_vartime(&mut rng, &nz))
}

// --- primes ------------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn rc_bignum_generate_prime(bits: u32, safe: c_int) -> *mut RCBigNum {
    let flavor = if safe != 0 { Flavor::Safe } else { Flavor::Any };
    let mut rng = rng();
    let prime: BoxedUint = random_prime(&mut rng, flavor, bits);
    into_handle(prime)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_bignum_is_prime(a: *const RCBigNum) -> c_int {
    let Some(a) = (unsafe { as_ref(a) }) else { return 0 };
    // `crypto_primes::is_prime` requires an odd candidate with a non-trivial
    // precision; copy with rounded precision to keep it happy.
    if bool::from(a.is_zero()) {
        return 0;
    }
    let target = round_precision(a.bits_vartime().max(MIN_PRECISION));
    let candidate = a.resize(target);
    if is_prime(Flavor::Any, &candidate) { 1 } else { 0 }
}
