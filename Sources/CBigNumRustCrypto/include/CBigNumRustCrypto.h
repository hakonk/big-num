// SPDX-License-Identifier: Apache-2.0
//
// C API exposed by the Rust `big_num_rustcrypto` crate. It provides a
// BoringSSL-BIGNUM-like surface backed by RustCrypto's `crypto-bigint`
// (`BoxedUint`) and `crypto-primes` crates.
//
// Lifetime rules:
//   * `RCBigNum*` returned by any constructor must be released with
//     `rc_bignum_free`.
//   * `char*` returned by the stringifiers must be released with
//     `rc_bignum_free_cstr`.
//
// All values are non-negative arbitrary-precision integers. Operations mirror
// the subset of BoringSSL's BIGNUM API previously consumed by this package.

#ifndef CBIGNUM_RUSTCRYPTO_H
#define CBIGNUM_RUSTCRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RCBigNum RCBigNum;

// --- lifecycle ---------------------------------------------------------------

RCBigNum *rc_bignum_new(void);
RCBigNum *rc_bignum_from_i64(int64_t value);
RCBigNum *rc_bignum_from_be_bytes(const uint8_t *bytes, size_t len);
RCBigNum *rc_bignum_from_dec(const char *s);
RCBigNum *rc_bignum_from_hex(const char *s);
void    rc_bignum_free(RCBigNum *n);
void    rc_bignum_free_cstr(char *s);

// --- accessors ---------------------------------------------------------------

uint32_t rc_bignum_num_bits(const RCBigNum *n);
// Writes up to `out_len` big-endian bytes of `n` into `out` and returns the
// full byte length of `n` (so callers can size their buffers correctly).
size_t   rc_bignum_to_be_bytes(const RCBigNum *n, uint8_t *out, size_t out_len);
char    *rc_bignum_to_dec(const RCBigNum *n);
char    *rc_bignum_to_hex(const RCBigNum *n);

// --- comparison --------------------------------------------------------------

int rc_bignum_cmp(const RCBigNum *a, const RCBigNum *b);   // -1 / 0 / 1
int rc_bignum_equal(const RCBigNum *a, const RCBigNum *b); // 0 / 1

// --- arithmetic --------------------------------------------------------------

RCBigNum *rc_bignum_add(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_sub(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_mul(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_div(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_mod(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_sqr(const RCBigNum *a);
RCBigNum *rc_bignum_exp(const RCBigNum *a, const RCBigNum *p);

// --- modular arithmetic ------------------------------------------------------

RCBigNum *rc_bignum_mod_add(const RCBigNum *a, const RCBigNum *b, const RCBigNum *n);
RCBigNum *rc_bignum_mod_sub(const RCBigNum *a, const RCBigNum *b, const RCBigNum *n);
RCBigNum *rc_bignum_mod_mul(const RCBigNum *a, const RCBigNum *b, const RCBigNum *n);
RCBigNum *rc_bignum_mod_sqr(const RCBigNum *a, const RCBigNum *n);
// `n` must be odd; returns NULL otherwise (callers should only pass odd
// moduli, matching how the Swift layer uses this).
RCBigNum *rc_bignum_mod_exp(const RCBigNum *a, const RCBigNum *p, const RCBigNum *n);

// --- misc --------------------------------------------------------------------

RCBigNum *rc_bignum_gcd(const RCBigNum *a, const RCBigNum *b);
RCBigNum *rc_bignum_lshift(const RCBigNum *a, uint32_t shift);
RCBigNum *rc_bignum_rshift(const RCBigNum *a, uint32_t shift);

void rc_bignum_set_bit(RCBigNum *a, uint32_t bit);
void rc_bignum_clear_bit(RCBigNum *a, uint32_t bit);
int  rc_bignum_is_bit_set(const RCBigNum *a, uint32_t bit);
void rc_bignum_mask_bits(RCBigNum *a, uint32_t bits);

// top: -1 = any, 0 = top bit set, 1 = top two bits set.
RCBigNum *rc_bignum_rand_bits(uint32_t bits, int top, int odd);
RCBigNum *rc_bignum_rand_range(const RCBigNum *max);

RCBigNum *rc_bignum_generate_prime(uint32_t bits, int safe);
int     rc_bignum_is_prime(const RCBigNum *a);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // CBIGNUM_RUSTCRYPTO_H
