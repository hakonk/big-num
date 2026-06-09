#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the big-num open source project
##
## Vendor a slim subset of BoringSSL suitable for SwiftPM-based BigNum.
##
## Unlike a full FIPS-module unity build (which compiles every algorithm
## through bcm.cc), this script copies *only* the files BN_* transitively
## needs, then drops bcm.cc and replaces it with a hand-written unity TU
## (bn_unity.cc) that includes just the .cc.inc files BN actually uses
## (BN + AES-ECB for the DRBG + SHA-256/512 for entropy).
##
## What that buys us:
##   - ~470 fewer vendored files vs. shipping the whole FIPS module
##   - no EC/RSA/MLKEM/MLDSA/SLHDSA/x509/asn1/evp/... source ships
##   - same upstream BoringSSL, same prefix-symbols mechanism
##
## Usage:
##   scripts/vendor-boringssl-2.sh                       # uses HEAD of main
##   scripts/vendor-boringssl-2.sh 0.20260508.0          # uses a specific tag/sha
##   scripts/vendor-boringssl-2.sh -p /path/to/clone     # uses a pre-existing clone
##
##===----------------------------------------------------------------------===##

set -euo pipefail

HERE="${HERE:-$(cd "$(dirname "$0")/.." && pwd)}"
DSTROOT="${DSTROOT:-${HERE}/Sources/CBigNumBoringSSL}"
PREFIX="${PREFIX:-CBigNumBoringSSL}"

# Argument parsing
PREEXISTING_CLONE=""
BORINGSSL_REVISION=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--path) PREEXISTING_CLONE="$2"; shift 2 ;;
        -h|--help)
            echo "usage: $0 [REVISION] [-p /path/to/existing/clone]"
            exit 0
            ;;
        *) BORINGSSL_REVISION="$1"; shift ;;
    esac
done

case "$(uname -s)" in
    Darwin) SED=gsed ;;
    *)      SED=sed  ;;
esac
if ! command -v "${SED}" >/dev/null 2>&1; then
    echo "Need ${SED} (on macOS: brew install gnu-sed)" >&2
    exit 43
fi

TMPDIR="$(mktemp -d /tmp/big-num-vendor.XXXXXX)"
trap 'rm -rf "${TMPDIR}"' EXIT

if [ -n "${PREEXISTING_CLONE}" ]; then
    SRCROOT="${PREEXISTING_CLONE}"
    echo "USING existing clone at ${SRCROOT}"
else
    SRCROOT="${TMPDIR}/boringssl"
    echo "CLONING BoringSSL"
    git clone https://boringssl.googlesource.com/boringssl "${SRCROOT}"
fi

(
    cd "${SRCROOT}"
    if [ -n "${BORINGSSL_REVISION}" ]; then
        echo "CHECKING OUT ${BORINGSSL_REVISION}"
        git fetch --tags 2>/dev/null || true
        git checkout "${BORINGSSL_REVISION}"
    fi
)
BORINGSSL_REVISION="$(cd "${SRCROOT}" && git rev-parse HEAD)"
echo "BoringSSL revision: ${BORINGSSL_REVISION}"

echo "REMOVING any previously-vendored BoringSSL code"
rm -rf "${DSTROOT}/include" "${DSTROOT}/crypto" "${DSTROOT}/gen" \
       "${DSTROOT}/third_party" "${DSTROOT}/provenance"

# -----------------------------------------------------------------------------
# Allowlist: the only files we copy from upstream BoringSSL.
#
# Closure determined empirically by deleting everything else, then iterating
# `swift build` / `swift test` until link errors disappeared. See
# scripts/VENDORING.md for the full reasoning.
#
# Categories:
#   * top-level crypto/ infrastructure (mem, err, cpu detection, threading)
#   * crypto/rand/ — public RAND_* + OS entropy sources
#   * crypto/bn/   — public BN wrappers (decimal/hex parse + format)
#   * crypto/bytestring/ — needed transitively by BN_bn2hex/dec
#   * crypto/asn1/ — only internal.h + posix_time.cc, pulled in by cbs.cc
#   * crypto/fipsmodule/bn/        — BIGNUM internals
#   * crypto/fipsmodule/aes/       — AES-ECB only (the DRBG block cipher)
#   * crypto/fipsmodule/rand/      — CTR-DRBG
#   * crypto/fipsmodule/entropy/   — entropy whitening (uses SHA-512)
#   * crypto/fipsmodule/sha/       — SHA-256/SHA-512 (no SHA-1)
#   * crypto/fipsmodule/service_indicator/internal.h — types only; stubs inlined into bn_unity.cc
#   * gen/bcm/  — BN, AES, SHA-256/512 assembly (no GCM/GHASH/P256/RDRAND/SHA1)
#   * gen/crypto/err_data.cc — global error-string table
#   * include/openssl/*.h — narrowed to what the kept .cc files include
#
# bcm.cc is *not* copied; we install scripts-inlined bn_unity.cc instead.
# -----------------------------------------------------------------------------

ALLOW_FILES=(
    # Top-level crypto infra
    'crypto/internal.h'
    'crypto/bcm_support.h'
    'crypto/mem_internal.h'
    'crypto/params_internal.h'
    'crypto/armv8_feature_parsing.h'
    'crypto/cpu_arm_linux.h'
    'crypto/crypto.cc'
    'crypto/mem.cc'
    'crypto/refcount.cc'
    'crypto/fuzzer_mode.cc'
    'crypto/thread.cc'
    'crypto/thread_none.cc'
    'crypto/thread_pthread.cc'
    'crypto/thread_win.cc'
    'crypto/cpu_aarch64_apple.cc'
    'crypto/cpu_aarch64_fuchsia.cc'
    'crypto/cpu_aarch64_linux.cc'
    'crypto/cpu_aarch64_openbsd.cc'
    'crypto/cpu_aarch64_sysreg.cc'
    'crypto/cpu_aarch64_win.cc'
    'crypto/cpu_arm_freebsd.cc'
    'crypto/cpu_arm_linux.cc'
    'crypto/cpu_intel.cc'
    # err
    'crypto/err/err.cc'
    'crypto/err/internal.h'
    # rand (public surface + OS entropy)
    'crypto/rand/deterministic.cc'
    'crypto/rand/fork_detect.cc'
    'crypto/rand/forkunsafe.cc'
    'crypto/rand/getentropy.cc'
    'crypto/rand/internal.h'
    'crypto/rand/ios.cc'
    'crypto/rand/passive.cc'
    'crypto/rand/rand.cc'
    'crypto/rand/trusty.cc'
    'crypto/rand/urandom.cc'
    'crypto/rand/windows.cc'
    # bn (public wrappers — bn_asn1.cc deliberately omitted; BigNum doesn't marshal ASN.1)
    'crypto/bn/convert.cc'
    'crypto/bn/div.cc'
    'crypto/bn/exponentiation.cc'
    'crypto/bn/sqrt.cc'
    # bytestring (CBB used by BN_bn2hex / BN_bn2dec; CBS pulled in transitively)
    'crypto/bytestring/cbb.cc'
    'crypto/bytestring/cbs.cc'
    'crypto/bytestring/internal.h'
    # asn1 (cbs.cc transitively needs OPENSSL_gmtime_adj)
    'crypto/asn1/internal.h'
    'crypto/asn1/posix_time.cc'
    # FIPS module — only the subset BN_* transitively touches.
    'crypto/fipsmodule/bcm_interface.h'
    'crypto/fipsmodule/delocate.h'
    'crypto/fipsmodule/fips_shared_support.cc'
    'crypto/fipsmodule/digest/md32_common.h'
    'crypto/fipsmodule/aes/aes.cc.inc'
    'crypto/fipsmodule/aes/aes_nohw.cc.inc'
    'crypto/fipsmodule/aes/internal.h'
    'crypto/fipsmodule/bn/add.cc.inc'
    'crypto/fipsmodule/bn/asm/x86_64-gcc.cc.inc'
    'crypto/fipsmodule/bn/bn.cc.inc'
    'crypto/fipsmodule/bn/bytes.cc.inc'
    'crypto/fipsmodule/bn/cmp.cc.inc'
    'crypto/fipsmodule/bn/ctx.cc.inc'
    'crypto/fipsmodule/bn/div.cc.inc'
    'crypto/fipsmodule/bn/div_extra.cc.inc'
    'crypto/fipsmodule/bn/exponentiation.cc.inc'
    'crypto/fipsmodule/bn/gcd.cc.inc'
    'crypto/fipsmodule/bn/gcd_extra.cc.inc'
    'crypto/fipsmodule/bn/generic.cc.inc'
    'crypto/fipsmodule/bn/internal.h'
    'crypto/fipsmodule/bn/jacobi.cc.inc'
    'crypto/fipsmodule/bn/montgomery.cc.inc'
    'crypto/fipsmodule/bn/montgomery_inv.cc.inc'
    'crypto/fipsmodule/bn/mul.cc.inc'
    'crypto/fipsmodule/bn/prime.cc.inc'
    'crypto/fipsmodule/bn/random.cc.inc'
    'crypto/fipsmodule/bn/rsaz_exp.cc.inc'
    'crypto/fipsmodule/bn/rsaz_exp.h'
    'crypto/fipsmodule/bn/shift.cc.inc'
    'crypto/fipsmodule/bn/sqrt.cc.inc'
    'crypto/fipsmodule/entropy/internal.h'
    'crypto/fipsmodule/entropy/jitter.cc.inc'
    'crypto/fipsmodule/entropy/sha512.cc.inc'
    'crypto/fipsmodule/rand/ctrdrbg.cc.inc'
    'crypto/fipsmodule/rand/internal.h'
    'crypto/fipsmodule/rand/rand.cc.inc'
    'crypto/fipsmodule/service_indicator/internal.h'
    'crypto/fipsmodule/sha/internal.h'
    'crypto/fipsmodule/sha/sha256.cc.inc'
    'crypto/fipsmodule/sha/sha512.cc.inc'
    # Assembly. Dropped: aes-gcm/aesni-gcm/aesv8-gcm/ghash (GCM not used by
    # DRBG), p256-* (no EC), rdrand-* (we use sysrand), sha1-* (no SHA-1
    # consumers in our slice), md5-/chacha-/aes128gcmsiv (no AEADs).
    'gen/bcm/aesni-x86-apple.S'
    'gen/bcm/aesni-x86-linux.S'
    'gen/bcm/aesni-x86_64-apple.S'
    'gen/bcm/aesni-x86_64-linux.S'
    'gen/bcm/aesv8-armv7-linux.S'
    'gen/bcm/aesv8-armv8-apple.S'
    'gen/bcm/aesv8-armv8-linux.S'
    'gen/bcm/aesv8-armv8-win.S'
    'gen/bcm/armv4-mont-linux.S'
    'gen/bcm/armv8-mont-apple.S'
    'gen/bcm/armv8-mont-linux.S'
    'gen/bcm/armv8-mont-win.S'
    'gen/bcm/bn-586-apple.S'
    'gen/bcm/bn-586-linux.S'
    'gen/bcm/bn-armv8-apple.S'
    'gen/bcm/bn-armv8-linux.S'
    'gen/bcm/bn-armv8-win.S'
    'gen/bcm/bsaes-armv7-linux.S'
    'gen/bcm/co-586-apple.S'
    'gen/bcm/co-586-linux.S'
    'gen/bcm/rsaz-avx2-apple.S'
    'gen/bcm/rsaz-avx2-linux.S'
    'gen/bcm/sha256-586-apple.S'
    'gen/bcm/sha256-586-linux.S'
    'gen/bcm/sha256-armv4-linux.S'
    'gen/bcm/sha256-armv8-apple.S'
    'gen/bcm/sha256-armv8-linux.S'
    'gen/bcm/sha256-armv8-win.S'
    'gen/bcm/sha256-x86_64-apple.S'
    'gen/bcm/sha256-x86_64-linux.S'
    'gen/bcm/sha512-586-apple.S'
    'gen/bcm/sha512-586-linux.S'
    'gen/bcm/sha512-armv4-linux.S'
    'gen/bcm/sha512-armv8-apple.S'
    'gen/bcm/sha512-armv8-linux.S'
    'gen/bcm/sha512-armv8-win.S'
    'gen/bcm/sha512-x86_64-apple.S'
    'gen/bcm/sha512-x86_64-linux.S'
    'gen/bcm/vpaes-armv7-linux.S'
    'gen/bcm/vpaes-armv8-apple.S'
    'gen/bcm/vpaes-armv8-linux.S'
    'gen/bcm/vpaes-armv8-win.S'
    'gen/bcm/vpaes-x86-apple.S'
    'gen/bcm/vpaes-x86-linux.S'
    'gen/bcm/vpaes-x86_64-apple.S'
    'gen/bcm/vpaes-x86_64-linux.S'
    'gen/bcm/x86-mont-apple.S'
    'gen/bcm/x86-mont-linux.S'
    'gen/bcm/x86_64-mont-apple.S'
    'gen/bcm/x86_64-mont-linux.S'
    'gen/bcm/x86_64-mont5-apple.S'
    'gen/bcm/x86_64-mont5-linux.S'
    'gen/crypto/err_data.cc'
    # Public headers. Anything not listed here gets dropped — even if upstream
    # ships it. The list was determined by `grep -r '#include <openssl/'` on
    # the kept tree plus iterating the build until clean.
    'include/openssl/aes.h'
    'include/openssl/arm_arch.h'
    'include/openssl/asm_base.h'
    'include/openssl/asn1.h'
    'include/openssl/asn1t.h'
    'include/openssl/base.h'
    'include/openssl/bio.h'
    'include/openssl/bn.h'
    'include/openssl/buf.h'
    'include/openssl/buffer.h'
    'include/openssl/bytestring.h'
    'include/openssl/chacha.h'
    'include/openssl/cpu.h'
    'include/openssl/crypto.h'
    'include/openssl/ctrdrbg.h'
    'include/openssl/err.h'
    'include/openssl/ex_data.h'
    'include/openssl/is_boringssl.h'
    'include/openssl/mem.h'
    'include/openssl/mldsa.h'
    'include/openssl/mlkem.h'
    'include/openssl/opensslconf.h'
    'include/openssl/posix_time.h'
    'include/openssl/prefix_symbols.h'
    'include/openssl/prefix_symbols_internal_S.h'
    'include/openssl/prefix_symbols_internal_c.h'
    'include/openssl/rand.h'
    'include/openssl/sha.h'
    'include/openssl/sha2.h'
    'include/openssl/span.h'
    'include/openssl/stack.h'
    'include/openssl/target.h'
    'include/openssl/thread.h'
    'include/openssl/type_check.h'
)

echo "COPYING ${#ALLOW_FILES[@]} allowlisted files from BoringSSL"
missing=0
for rel in "${ALLOW_FILES[@]}"; do
    src="${SRCROOT}/${rel}"
    if [ ! -e "${src}" ]; then
        echo "  MISSING (BoringSSL no longer ships): ${rel}" >&2
        missing=$((missing + 1))
        continue
    fi
    dest="${DSTROOT}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    cp "${src}" "${dest}"
done
if [ "${missing}" -gt 0 ]; then
    echo "FATAL: ${missing} allowlisted file(s) missing in upstream. Update ALLOW_FILES." >&2
    exit 44
fi

echo "REMOVING libssl headers (if any slipped in)"
for h in dtls1.h ssl.h srtp.h ssl3.h tls1.h; do
    rm -f "${DSTROOT}/include/openssl/${h}"
done

echo "DISABLING assembly on Windows x86 and 32-bit Apple platforms"
${SED} -i '/#define OPENSSL_HEADER_BASE_H/a\
#if defined(_WIN32) \&\& (defined(__x86_64) || defined(_M_AMD64) || defined(_M_X64) || defined(__x86) || defined(__i386) || defined(__i386__) || defined(_M_IX86))\
#define OPENSSL_NO_ASM\
#endif\
#if defined(__APPLE__) \&\& defined(__i386__)\
#define OPENSSL_NO_ASM\
#endif' "${DSTROOT}/include/openssl/base.h"

# Inject the BORINGSSL_PREFIX. This is THE knob that activates the upstream-
# shipped prefix_symbols*.h headers. No symbol extraction or Go tooling needed.
#
# We also #undef __PRAGMA_REDEFINE_EXTNAME so that prefix_symbols.h takes the
# macro-based (#define BN_new ${PREFIX}_BN_new) branch rather than the
# `#pragma redefine_extname` branch. The pragma form only renames symbols at
# link time, which is fine for C/C++ callers, but Swift's Clang importer
# reads function declarations by their textual name and would then emit calls
# to the unprefixed symbols (which don't exist in the linked archive).
echo "INJECTING BORINGSSL_PREFIX=${PREFIX}"
perl -pi -e '$_ .= qq(\n#define BORINGSSL_PREFIX '"${PREFIX}"'\n#undef __PRAGMA_REDEFINE_EXTNAME\n) if /#define OPENSSL_HEADER_BASE_H/' \
    "${DSTROOT}/include/openssl/base.h"

# .S files don't include base.h (only asm_base.h, via target.h), so the prefix
# macro from base.h isn't visible during assembly. Stamp it at the top of every
# .S file so prefix_symbols_internal_S.h is pulled in correctly.
echo "PREFIXING assembly files"
for s in $(find "${DSTROOT}" -name "*.S" | LC_ALL=C sort); do
    ${SED} -i "1 i #define BORINGSSL_PREFIX ${PREFIX}" "${s}"
done

# Patch convert.cc: drop BN_print / BN_print_fp, which use BIO_*. We don't
# ship crypto/bio/, and BigNum's Swift API doesn't expose these formatters.
echo "PATCHING crypto/bn/convert.cc — removing BIO-using BN_print*"
${SED} -i '/^#include <openssl\/bio.h>$/d' "${DSTROOT}/crypto/bn/convert.cc"
${SED} -i '/^int BN_print(BIO \*bp, const BIGNUM \*a) {$/,/^}$/d' "${DSTROOT}/crypto/bn/convert.cc"
${SED} -i '/^int BN_print_fp(FILE \*fp, const BIGNUM \*a) {$/,/^}$/d' "${DSTROOT}/crypto/bn/convert.cc"

echo "RENAMING and PREFIXING headers"
(
    cd "${DSTROOT}"
    mv include/openssl/* include/
    rmdir include/openssl

    # Rewrite every #include of <openssl/X> and "openssl/X" in the whole tree.
    find . -type f \( -name "*.h" -o -name "*.cc" -o -name "*.S" -o -name "*.c.inc" -o -name "*.cc.inc" -o -name "*.inc" \) \
        -exec ${SED} -i \
            -e "s|include <openssl/|include <${PREFIX}_|g" \
            -e "s|include \"openssl/|include \"${PREFIX}_|g" \
            {} +

    cd include
    for f in $(find . -maxdepth 1 -name "*.h" -not -name "${PREFIX}_*"); do
        base="$(basename "${f}")"
        mv "${f}" "${PREFIX}_${base}"
    done

    # Headers may include each other by bare name; switch those to the prefix
    # and to quoted form (SwiftPM keeps the include directory implicit).
    find . -name "*.h" -exec ${SED} -i \
        -e "s|include \"\\([a-z_][a-z_0-9]*\\.h\\)\"|include \"${PREFIX}_\\1\"|g" \
        -e "s|include <${PREFIX}_\\([a-z_][a-z_0-9]*\\.h\\)>|include \"${PREFIX}_\\1\"|g" \
        {} +
)

echo "INSTALLING bn_unity.cc (replaces upstream bcm.cc as the FIPS unity TU)"
cat > "${DSTROOT}/crypto/fipsmodule/bn_unity.cc" <<EOF
// big-num: replacement for crypto/fipsmodule/bcm.cc.
//
// bcm.cc is BoringSSL's unity TU for the entire FIPS module — it #includes
// every algorithm (AES, EC, RSA, ML-DSA, …) so the static integrity check can
// hash one contiguous .text section. big-num only needs BIGNUM, and the only
// transitive deps are what BN_rand / BN_generate_prime_ex pull in (the
// CTR-DRBG, which needs AES + a SHA for entropy whitening). Everything else
// from the FIPS module is omitted.
//
// We never define BORINGSSL_FIPS in this build, so the integrity check and
// power-on-self-test machinery are #ifdef-ed out and don't link in.
//
// This file is generated by scripts/vendor-boringssl-2.sh — do not edit by
// hand; edit the heredoc in the script and re-vendor instead.

#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <${PREFIX}_crypto.h>
#include "../bcm_support.h"
#include "../internal.h"
#include "bcm_interface.h"

OPENSSL_CLANG_PRAGMA("clang diagnostic push")
OPENSSL_CLANG_PRAGMA("clang diagnostic ignored \"-Wheader-hygiene\"")

// AES — needed by the CTR-DRBG (ECB only). The CBC / CFB / OFB / CTR public
// wrappers in aes/mode_wrappers.cc.inc are not built; they pull in cipher/.
#include "aes/aes.cc.inc"
#include "aes/aes_nohw.cc.inc"

// BIGNUM.
#include "bn/add.cc.inc"
#include "bn/asm/x86_64-gcc.cc.inc"
#include "bn/bn.cc.inc"
#include "bn/bytes.cc.inc"
#include "bn/cmp.cc.inc"
#include "bn/ctx.cc.inc"
#include "bn/div.cc.inc"
#include "bn/div_extra.cc.inc"
#include "bn/exponentiation.cc.inc"
#include "bn/gcd.cc.inc"
#include "bn/gcd_extra.cc.inc"
#include "bn/generic.cc.inc"
#include "bn/jacobi.cc.inc"
#include "bn/montgomery.cc.inc"
#include "bn/montgomery_inv.cc.inc"
#include "bn/mul.cc.inc"
#include "bn/prime.cc.inc"
#include "bn/random.cc.inc"
#include "bn/rsaz_exp.cc.inc"
#include "bn/shift.cc.inc"
#include "bn/sqrt.cc.inc"

// CTR-DRBG + the rand glue BN_rand calls into.
#include "rand/ctrdrbg.cc.inc"
#include "rand/rand.cc.inc"

// Entropy whitening for the DRBG seed. jitter.cc.inc transitively includes
// entropy/sha512.cc.inc; do not include the latter directly.
#include "entropy/jitter.cc.inc"

// SHA-256 / SHA-512 — used by the entropy path.
#include "sha/sha256.cc.inc"
#include "sha/sha512.cc.inc"

OPENSSL_CLANG_PRAGMA("clang diagnostic pop")

using namespace bssl;

// service_indicator/service_indicator.cc.inc unconditionally #includes
// evp/internal.h, ec.h, etc., which we no longer ship. In non-FIPS builds it
// only defines two trivial stubs, inlined here.
namespace bssl {
uint64_t FIPS_service_indicator_before_call() { return 0; }
uint64_t FIPS_service_indicator_after_call() { return 1; }
}  // namespace bssl
EOF

echo "WRITING umbrella header and modulemap"
cat > "${DSTROOT}/include/${PREFIX}.h" <<EOF
#ifndef C_BIGNUM_BORINGSSL_H
#define C_BIGNUM_BORINGSSL_H

#include "${PREFIX}_base.h"
#include "${PREFIX}_bn.h"
#include "${PREFIX}_crypto.h"
#include "${PREFIX}_err.h"
#include "${PREFIX}_mem.h"
#include "${PREFIX}_rand.h"

#endif
EOF

cat > "${DSTROOT}/include/module.modulemap" <<EOF
module ${PREFIX} {
    header "${PREFIX}.h"
    export *
}
EOF

echo "This directory is derived from BoringSSL cloned from https://boringssl.googlesource.com/boringssl at revision ${BORINGSSL_REVISION}" \
    > "${DSTROOT}/hash.txt"
${SED} -i -e "s|BoringSSL Commit: [0-9a-f]\\+|BoringSSL Commit: ${BORINGSSL_REVISION}|" "${HERE}/Package.swift" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Provenance.
#
# PROVENANCE.txt is the index: one row per vendored file recording its
# upstream origin and the transformation applied. For every *modified* file
# the script also writes a reversible unified diff under
#   provenance/<vendored_path>.patch
# Reverse-applying that patch to the vendored file reproduces the upstream
# original byte-for-byte, so verification does not depend on trusting this
# script. scripts/verify-provenance.sh checks exactly that.
# ---------------------------------------------------------------------------
echo "GENERATING PROVENANCE.txt + provenance/ patches"

# gen_patch <upstream_rel> <vendored_rel>
# Writes ${DSTROOT}/provenance/<vendored_rel>.patch as the git diff taking the
# upstream file to the vendored file. Returns 0 if a patch was written, or 1
# if the two files are byte-identical (caller then records it as "verbatim").
gen_patch() {
    local up="$1" vend="$2"
    local out="${DSTROOT}/provenance/${vend}.patch"
    local stg
    stg="$(mktemp -d "${TMPDIR}/patch.XXXXXX")"
    mkdir -p "${stg}/a/$(dirname "${up}")" "${stg}/b/$(dirname "${vend}")"
    cp "${SRCROOT}/${up}" "${stg}/a/${up}"
    cp "${DSTROOT}/${vend}" "${stg}/b/${vend}"
    mkdir -p "$(dirname "${out}")"
    # Pinned diff settings keep the output reproducible regardless of the
    # caller's git config; --no-prefix yields clean "a/<up>" / "b/<vend>"
    # headers that patch(1) and `git apply` both accept.
    ( cd "${stg}" \
        && git -c core.autocrlf=false \
               -c diff.algorithm=myers \
               -c diff.indentHeuristic=true \
               diff --no-index --no-prefix --no-color --unified=3 \
               "a/${up}" "b/${vend}" ) > "${out}" || true
    rm -rf "${stg}"
    [ -s "${out}" ] && return 0
    rm -f "${out}"
    return 1
}

rm -rf "${DSTROOT}/provenance"

# Enumerate vendored files into a list up front, so that creating provenance/
# during the loop below cannot perturb the file walk.
LISTFILE="${TMPDIR}/vendored-files.txt"
( cd "${DSTROOT}" && find . -type f \
    \( -name "*.h" -o -name "*.cc" -o -name "*.S" -o -name "*.cc.inc" \
       -o -name "*.c.inc" -o -name "*.inc" -o -name "*.modulemap" \
       -o -name "hash.txt" \) \
    | LC_ALL=C sort ) > "${LISTFILE}"

{
    echo "# BoringSSL provenance for big-num"
    echo "# upstream_revision = ${BORINGSSL_REVISION}"
    echo "#"
    echo "# format: <vendored_path>\\t<upstream_path>\\t<transformation>"
    echo "#"
    echo "# Every modified file also has a reversible unified diff at"
    echo "#   provenance/<vendored_path>.patch"
    echo "# Reverse-applying it to a copy of the vendored file reproduces the"
    echo "# upstream original byte-for-byte:"
    echo "#   patch -R <copy-of-vendored-file> < provenance/<vendored_path>.patch"
    echo "# scripts/verify-provenance.sh checks the whole tree this way."
    echo "#"
    echo "# Transformations:"
    echo "#   verbatim            = byte-identical to upstream (no patch)"
    echo "#   include-rewrite     = #include rewrites only"
    echo "#   header-rename       = renamed include/openssl/X.h -> include/${PREFIX}_X.h + include-rewrite"
    echo "#   header-rename+base  = header-rename + injected BORINGSSL_PREFIX + OPENSSL_NO_ASM gates"
    echo "#   asm-prefix          = include-rewrite + #define BORINGSSL_PREFIX prepended"
    echo "#   bn-print-stripped   = include-rewrite + BN_print / BN_print_fp removed (BIO dropped)"
    echo "#   generated           = produced by the vendor script, no upstream source (no patch)"
    echo "#"
    while read -r f; do
        rel="${f#./}"
        case "${rel}" in
            include/${PREFIX}.h | include/module.modulemap | hash.txt | crypto/fipsmodule/bn_unity.cc)
                printf "%s\t-\tgenerated\n" "${rel}"
                continue
                ;;
            include/${PREFIX}_base.h)
                up="include/openssl/base.h" ; xform="header-rename+base" ;;
            include/${PREFIX}_*.h)
                up="include/openssl/${rel#include/${PREFIX}_}" ; xform="header-rename" ;;
            crypto/bn/convert.cc)
                up="${rel}" ; xform="bn-print-stripped" ;;
            *.S)
                up="${rel}" ; xform="asm-prefix" ;;
            *)
                up="${rel}" ; xform="include-rewrite" ;;
        esac
        if ! gen_patch "${up}" "${rel}"; then
            xform="verbatim"
        fi
        printf "%s\t%s\t%s\n" "${rel}" "${up}" "${xform}"
    done < "${LISTFILE}"
} > "${DSTROOT}/PROVENANCE.txt"

echo "  $(find "${DSTROOT}/provenance" -name '*.patch' -type f 2>/dev/null | wc -l | tr -d ' ') provenance patch(es) written"

# Manifest: hashes of every vendored file. Anyone with the committed tree can
# run `sha256sum -c MANIFEST.sha256` to confirm nothing has been tampered with
# locally. Combined with the deterministic vendor script + PROVENANCE.txt, this
# gives end-to-end attestation back to BoringSSL upstream.
echo "GENERATING MANIFEST.sha256"
(
    cd "${DSTROOT}"
    find . -type f -not -name MANIFEST.sha256 \
        | LC_ALL=C sort \
        | xargs sha256sum \
        > MANIFEST.sha256
)

echo "DONE: ${BORINGSSL_REVISION}"
echo "Vendored: ${DSTROOT}"
echo "Manifest:   ${DSTROOT}/MANIFEST.sha256"
echo "Provenance: ${DSTROOT}/PROVENANCE.txt"
