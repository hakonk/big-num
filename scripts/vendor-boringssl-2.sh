#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the big-num open source project
##
## Vendor a copy of BoringSSL suitable for SwiftPM-based BigNum (Option A:
## full bcm.cc unity build).
##
## The modern BoringSSL ships pre-generated prefix-symbols headers under
## include/openssl/, so we no longer need to extract symbols or run any
## Go tooling at vendor time. We just copy, set BORINGSSL_PREFIX, and rename.
##
## Usage:
##   scripts/vendor-boringssl.sh                       # uses HEAD of main
##   scripts/vendor-boringssl.sh 0.20260508.0          # uses a specific tag/sha
##   scripts/vendor-boringssl.sh -p /path/to/clone     # uses a pre-existing clone
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
rm -rf "${DSTROOT}/include" "${DSTROOT}/crypto" "${DSTROOT}/gen" "${DSTROOT}/third_party"

# The FIPS module is built as a unity translation unit via bcm.cc which
# #includes the entire .cc.inc tree, so we cannot pick BN files alone --
# bcm.cc requires all the .cc.inc files it references.
PATTERNS=(
    'include/openssl/*.h'
    'crypto/*.h'
    'crypto/*.cc'
    'crypto/*/*.h'
    'crypto/*/*.cc'
    'crypto/*/*.S'
    'crypto/*/*/*.h'
    'crypto/*/*/*.cc.inc'
    'crypto/*/*/*.inc'
    'crypto/*/*/*.S'
    'crypto/*/*/*/*.cc.inc'
    'gen/crypto/*.cc'
    'gen/crypto/*.S'
    'gen/bcm/*.S'
    'third_party/fiat/*.h'
    'third_party/fiat/asm/*.S'
    'third_party/fiat/*.c.inc'
)

EXCLUDES=(
    '*_test.*'
    'test_*.*'
    'test'
    'example_*.cc'
)

echo "COPYING boringssl tree"
for pattern in "${PATTERNS[@]}"; do
    # Deterministic order: LC_ALL=C sort, so the script produces identical
    # output regardless of locale or filesystem ordering.
    for f in $(ls -1 ${SRCROOT}/${pattern} 2>/dev/null | LC_ALL=C sort); do
        [ -e "$f" ] || continue
        rel="${f#${SRCROOT}/}"
        dest="${DSTROOT}/${rel}"
        mkdir -p "$(dirname "${dest}")"
        cp "$f" "${dest}"
    done
done

for ex in "${EXCLUDES[@]}"; do
    find "${DSTROOT}" -depth -name "${ex}" -exec rm -rf {} +
done

echo "REMOVING libssl headers"
for h in dtls1.h ssl.h srtp.h ssl3.h tls1.h; do
    rm -f "${DSTROOT}/include/openssl/${h}"
done

# Some networking-related BIO sources require netdb.h which WASI libc lacks.
# big-num doesn't need them either way.
echo "REMOVING networking BIOs"
rm -f "${DSTROOT}/crypto/bio/connect.cc" \
      "${DSTROOT}/crypto/bio/socket.cc" \
      "${DSTROOT}/crypto/bio/socket_helper.cc"

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

# Provenance: for every vendored file, record where it came from in upstream.
# This is what the verifier uses to independently reconstruct each file from
# a fresh BoringSSL clone without trusting this script.
echo "GENERATING PROVENANCE.txt"
(
    cd "${DSTROOT}"
    {
        echo "# BoringSSL provenance for big-num"
        echo "# upstream_revision = ${BORINGSSL_REVISION}"
        echo "# format: <vendored_path>\\t<upstream_path>\\t<transformation>"
        echo "#"
        echo "# Transformations:"
        echo "#   verbatim                = byte-identical to upstream"
        echo "#   include-rewrite         = #include rewrites only"
        echo "#   header-rename           = renamed from include/openssl/X.h to include/${PREFIX}_X.h + include-rewrite"
        echo "#   header-rename+base      = header-rename + injected BORINGSSL_PREFIX + OPENSSL_NO_ASM gates"
        echo "#   asm-prefix              = include-rewrite + #define BORINGSSL_PREFIX prepended"
        echo "#   generated               = produced by the vendor script, no upstream source"
        echo "#"
        find . -type f \
            \( -name "*.h" -o -name "*.cc" -o -name "*.S" -o -name "*.cc.inc" -o -name "*.c.inc" -o -name "*.inc" \
               -o -name "*.modulemap" -o -name "hash.txt" \) \
            | LC_ALL=C sort \
            | while read -r f; do
                rel="${f#./}"
                case "${rel}" in
                    include/${PREFIX}.h | include/module.modulemap | hash.txt)
                        printf "%s\t-\tgenerated\n" "${rel}"
                        ;;
                    include/${PREFIX}_base.h)
                        printf "%s\tinclude/openssl/base.h\theader-rename+base\n" "${rel}"
                        ;;
                    include/${PREFIX}_*.h)
                        base="${rel#include/${PREFIX}_}"
                        printf "%s\tinclude/openssl/%s\theader-rename\n" "${rel}" "${base}"
                        ;;
                    *.S)
                        printf "%s\t%s\tasm-prefix\n" "${rel}" "${rel}"
                        ;;
                    *)
                        printf "%s\t%s\tinclude-rewrite\n" "${rel}" "${rel}"
                        ;;
                esac
            done
    } > PROVENANCE.txt
)

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
