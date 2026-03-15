#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftCrypto open source project
##
## Copyright (c) 2019-2021 Apple Inc. and the SwiftCrypto project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of SwiftCrypto project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
# This was substantially adapted from grpc-swift's vendor-boringssl.sh script.
# The license for the original work is reproduced below. See NOTICES.txt for
# more.
#
# Copyright 2016, gRPC Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script creates a vendored copy of BoringSSL that is
# suitable for building with the Swift Package Manager.
#
# Usage:
#   1. Run this script in the package root. It will place
#      a local copy of the BoringSSL sources in Sources/CBigNumBoringSSL.
#      Any prior contents of Sources/CBigNumBoringSSL will be deleted.
#
#   2. Optionally pass a BoringSSL revision (tag or commit) as the first argument:
#      ./scripts/vendor-boringssl.sh 0.20260211.0
#
set -eou pipefail

HERE=$(pwd)
DSTROOT=Sources/CBigNumBoringSSL
TMPDIR=$(mktemp -d /tmp/.workingXXXXXX)
SRCROOT="${TMPDIR}/src/boringssl.googlesource.com/boringssl"

# BoringSSL revision can be passed as the first argument to this script.
if [ "$#" -gt 0 ]; then
    BORINGSSL_REVISION="$1"
fi

# This function namespaces the awkward inline functions declared in OpenSSL
# and BoringSSL.
function namespace_inlines {
    # Pull out all STACK_OF functions.
    STACKS=$(grep --no-filename -rE -e "DEFINE_(SPECIAL_)?STACK_OF\([A-Z_0-9a-z]+\)" -e "DEFINE_NAMED_STACK_OF\([A-Z_0-9a-z]+, +[A-Z_0-9a-z:]+\)" "$1/"* | grep -v '//' | grep -v '#' | gsed -e 's/DEFINE_\(SPECIAL_\)\?STACK_OF(\(.*\))/\2/' -e 's/DEFINE_NAMED_STACK_OF(\(.*\), .*)/\1/')
    STACK_FUNCTIONS=("call_free_func" "call_copy_func" "call_cmp_func" "new" "new_null" "num" "zero" "value" "set" "free" "pop_free" "insert" "delete" "delete_ptr" "find" "shift" "push" "pop" "dup" "sort" "is_sorted" "set_cmp_func" "deep_copy" "delete_if")

    for s in $STACKS; do
        for f in "${STACK_FUNCTIONS[@]}"; do
            echo "#define sk_${s}_${f} BORINGSSL_ADD_PREFIX(sk_${s}_${f})" >> "$1/include/openssl/prefix_symbols.h"
        done
    done

    # Now pull out all LHASH_OF functions.
    LHASHES=$(grep --no-filename -rE "DEFINE_LHASH_OF\([A-Z_0-9a-z]+\)" "$1/"* | grep -v '//' | grep -v '#' | grep -v '\\$' | gsed 's/DEFINE_LHASH_OF(\(.*\))/\1/')
    LHASH_FUNCTIONS=("call_cmp_func" "call_hash_func" "new" "free" "num_items" "retrieve" "call_cmp_key" "retrieve_key" "insert" "delete" "call_doall" "call_doall_arg" "doall" "doall_arg")

    for l in $LHASHES; do
        for f in "${LHASH_FUNCTIONS[@]}"; do
            echo "#define lh_${l}_${f} BORINGSSL_ADD_PREFIX(lh_${l}_${f})" >> "$1/include/openssl/prefix_symbols.h"
        done
    done
}


# Modern BoringSSL ships pre-generated prefix symbol headers (prefix_symbols.h,
# prefix_symbols_internal_c.h, prefix_symbols_internal_S.h). We just need to
# define BORINGSSL_PREFIX and let base.h pull them in automatically.
function mangle_symbols {
    echo "ADDING symbol mangling"

    # Define BORINGSSL_PREFIX in base.h so prefix_symbols.h gets included.
    # Also undef __PRAGMA_REDEFINE_EXTNAME to force the #define path so that
    # prefixed symbol names are visible at the source level for Swift interop.
    perl -pi -e '$_ .= qq(\n#define BORINGSSL_PREFIX CBigNumBoringSSL\n) if /#define OPENSSL_HEADER_BASE_H/' "$DSTROOT/include/openssl/base.h"
    $sed -i '/^#if defined(BORINGSSL_PREFIX)/i #undef __PRAGMA_REDEFINE_EXTNAME' "$DSTROOT/include/openssl/base.h"

    # Add BORINGSSL_PREFIX to all assembly files.
    # shellcheck disable=SC2044
    for assembly_file in $(find "$DSTROOT" -name "*.S")
    do
        $sed -i '1 i #define BORINGSSL_PREFIX CBigNumBoringSSL' "$assembly_file"
    done

    # Namespace inline STACK_OF and LHASH_OF functions.
    namespace_inlines "$DSTROOT"
}

case "$(uname -s)" in
    Darwin)
        sed=gsed
        ;;
    *)
        # shellcheck disable=SC2209
        sed=sed
        ;;
esac

if ! hash ${sed} 2>/dev/null; then
    echo "You need sed \"${sed}\" to run this script ..."
    echo
    echo "On macOS: brew install gnu-sed"
    exit 43
fi

echo "REMOVING any previously-vendored BoringSSL code"
rm -rf $DSTROOT/include
rm -rf $DSTROOT/ssl
rm -rf $DSTROOT/crypto
rm -rf $DSTROOT/gen
rm -rf $DSTROOT/third_party

echo "CLONING boringssl"
mkdir -p "$SRCROOT"
git clone https://boringssl.googlesource.com/boringssl "$SRCROOT"
cd "$SRCROOT"
if [ "${BORINGSSL_REVISION:-}" ]; then
    echo "CHECKING OUT boringssl@${BORINGSSL_REVISION}"
    git checkout "$BORINGSSL_REVISION"
else
    BORINGSSL_REVISION=$(git rev-parse HEAD)
    echo "CLONED boringssl@${BORINGSSL_REVISION}"
fi
cd "$HERE"

echo "OBTAINING submodules"
(
    cd "$SRCROOT"
    git submodule update --init
)

PATTERNS=(
# Public headers
'include/openssl/*.h'

# Top-level crypto infrastructure
'crypto/*.h'
'crypto/*.cc'

# BN (bignum) — the core module BigNum uses
'crypto/bn/*.cc'

# Supporting modules needed by BN
'crypto/asn1/internal.h'          # needed by bytestring/cbs.cc
'crypto/asn1/posix_time.cc'       # needed by bytestring/cbs.cc (OPENSSL_gmtime_adj)
'crypto/bio/*.h'
'crypto/bio/*.cc'                 # needed by bn/convert.cc (BN_print)
'crypto/buf/*.cc'                 # needed by bio
'crypto/bytestring/*.h'
'crypto/bytestring/*.cc'          # needed by bn/convert.cc (CBB for BN_bn2dec)
'crypto/err/*.h'
'crypto/err/*.cc'                 # error handling
'crypto/rand/*.h'
'crypto/rand/*.cc'                # needed by BN_rand, BN_generate_prime
'crypto/stack/*.cc'               # needed by ex_data

# FIPS module unity build and its kept submodules
'crypto/fipsmodule/bcm_interface.h'
'crypto/fipsmodule/bcm.cc'
'crypto/fipsmodule/delocate.h'
'crypto/fipsmodule/fips_shared_support.cc'
'crypto/fipsmodule/bn/*.h'
'crypto/fipsmodule/bn/*.cc.inc'
'crypto/fipsmodule/bn/asm/*.cc.inc'
'crypto/fipsmodule/aes/*.h'       # needed by CTR-DRBG (used by rand)
'crypto/fipsmodule/aes/*.cc.inc'
'crypto/fipsmodule/rand/*.h'
'crypto/fipsmodule/rand/*.cc.inc'
'crypto/fipsmodule/entropy/*.h'
'crypto/fipsmodule/entropy/*.cc.inc'
'crypto/fipsmodule/service_indicator/*.h'
'crypto/fipsmodule/service_indicator/*.cc.inc'

# Generated sources
'gen/crypto/err_data.cc'

# BN montgomery multiply assembly
'gen/bcm/bn-*'
'gen/bcm/armv4-mont-*'
'gen/bcm/armv8-mont-*'
'gen/bcm/x86-mont-*'
'gen/bcm/x86_64-mont-*'
'gen/bcm/x86_64-mont5-*'

# AES assembly (needed by CTR-DRBG) — exclude GCM variants
'gen/bcm/aesni-x86*'
'gen/bcm/aesv8-armv*'
'gen/bcm/bsaes-*'
'gen/bcm/vpaes-*'
)

EXCLUDES=(
'*_test.*'
'test_*.*'
'test'
'example_*.cc'
)

echo "COPYING boringssl"
for pattern in "${PATTERNS[@]}"
do
  for i in $SRCROOT/$pattern; do
    path=${i#"$SRCROOT"}
    dest="$DSTROOT$path"
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"
    cp "$SRCROOT/$path" "$dest"
  done
done

for exclude in "${EXCLUDES[@]}"
do
  echo "EXCLUDING $exclude"
  find $DSTROOT -d -name "$exclude" -exec rm -rf {} \;
done

# bn_asn1.cc is not needed — BigNum doesn't use BN_marshal_asn1/BN_parse_asn1
echo "REMOVING unused BN ASN1 support"
rm -f "$DSTROOT/crypto/bn/bn_asn1.cc"

echo "REMOVING libssl"
(
    cd "$DSTROOT"
    rm -f "include/openssl/dtls1.h" "include/openssl/ssl.h" "include/openssl/srtp.h" "include/openssl/ssl3.h" "include/openssl/tls1.h"
    rm -rf "ssl"
)

echo "DISABLING assembly on x86 Windows"
(
    cd "$DSTROOT"
    $sed -i "/#define OPENSSL_HEADER_BASE_H/a#if defined(_WIN32) && (defined(__x86_64) || defined(_M_AMD64) || defined(_M_X64) || defined(__x86) || defined(__i386) || defined(__i386__) || defined(_M_IX86))\n#define OPENSSL_NO_ASM\n#endif" "include/openssl/base.h"
)

# Patch bcm.cc: strip it down to only BN + rand + AES + entropy + service_indicator.
# The original includes all fipsmodule .cc.inc files; we only need the BN subset.
echo "PATCHING bcm.cc to include only BN-related modules"
cat > "$DSTROOT/crypto/fipsmodule/bcm.cc" << 'BCMEOF'
// Copyright 2017 The BoringSSL Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE  // needed for syscall() on Linux.
#endif

#include <openssl/crypto.h>

#include <stdlib.h>

#include "../bcm_support.h"
#include "../internal.h"
#include "bcm_interface.h"

// The .cc.inc files are not written as headers, but .cc files which we
// currently need to combine together in the style of a unity or jumbo build.
OPENSSL_CLANG_PRAGMA("clang diagnostic push")
OPENSSL_CLANG_PRAGMA("clang diagnostic ignored \"-Wheader-hygiene\"")
// BN (bignum) — the only module BigNum actually uses
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
// Rand — needed by BN_rand, BN_generate_prime_ex
#include "rand/ctrdrbg.cc.inc"
#include "rand/rand.cc.inc"
// Entropy — needed by rand
#include "entropy/jitter.cc.inc"
// AES — needed by CTR-DRBG
#include "aes/aes.cc.inc"
#include "aes/aes_nohw.cc.inc"
// Service indicator — referenced by ctrdrbg
#include "service_indicator/service_indicator.cc.inc"
OPENSSL_CLANG_PRAGMA("clang diagnostic pop")
BCMEOF

# Patch service_indicator: move FIPS-only includes behind a FIPS guard
# so we don't need evp/ and ec/ headers/sources.
echo "PATCHING service_indicator.cc.inc for non-FIPS build"
SI_FILE="$DSTROOT/crypto/fipsmodule/service_indicator/service_indicator.cc.inc"
# Remove the unconditional includes for ec, ec_key, evp and evp/internal.h
$sed -i '/#include <openssl\/ec\.h>/d' "$SI_FILE"
$sed -i '/#include <openssl\/ec_key\.h>/d' "$SI_FILE"
$sed -i '/#include <openssl\/evp\.h>/d' "$SI_FILE"
$sed -i '/\.\.\/\.\.\/evp\/internal\.h/d' "$SI_FILE"
# Re-add them inside a FIPS guard, just before "using namespace"
$sed -i '/^using namespace bssl;/i \
#if defined(BORINGSSL_FIPS)\
#include <openssl/ec.h>\
#include <openssl/ec_key.h>\
#include <openssl/evp.h>\
#include "../../evp/internal.h"\
#endif\
' "$SI_FILE"

mangle_symbols

echo "MANGLE done"
# Removing ASM on 32 bit Apple platforms
echo "REMOVING assembly on 32-bit Apple platforms"
gsed -i "/#define OPENSSL_HEADER_BASE_H/a#if defined(__APPLE__) && defined(__i386__)\n#define OPENSSL_NO_ASM\n#endif" "$DSTROOT/include/openssl/base.h"

echo "RENAMING header files"
(
    # We need to rearrange a couple of things here, the end state will be:
    # - Headers from 'include/openssl/' will be moved up a level to 'include/'
    # - Their names will be prefixed with 'CBigNumBoringSSL_'
    # - The headers prefixed with 'boringssl_prefix_symbols' will also be prefixed with 'CBigNumBoringSSL_'
    # - Any include of another header in the 'include/' directory will use quotation marks instead of angle brackets

    # Let's move the headers up a level first.
    cd "$DSTROOT"
    mv include/openssl/* include/
    rmdir "include/openssl"

    # Now change the imports from "<openssl/X> to "<CBigNumBoringSSL_X>", apply the same prefix to the prefix_symbols headers.
    # shellcheck disable=SC2038
    find . -name "*.[ch]" -or -name "*.cc" -or -name "*.S" -or -name "*.c.inc" -or -name "*.cc.inc" | xargs $sed -i -e 's+include <openssl/\([[:alpha:]/]*/\)\{0,1\}+include <\1CBigNumBoringSSL_+' -e 's+include <prefix_symbols+include <CBigNumBoringSSL_prefix_symbols+' -e 's+include "openssl/\([[:alpha:]/]*/\)\{0,1\}+include "\1CBigNumBoringSSL_+'

    # Okay now we need to rename the headers adding the prefix "CBigNumBoringSSL_".
    pushd include
    while IFS= read -r -u3 -d $'\0' file; do
        dir=$(dirname "${file}")
        base=$(basename "${file}")
        mv "${file}" "${dir}/CBigNumBoringSSL_${base}"
    done 3< <(find . -name "*.h" -print0 | sort -rz)

    # Finally, make sure we refer to them by their prefixed names, and change any includes from angle brackets to quotation marks.
    # shellcheck disable=SC2038
    find . -name "*.h" | xargs $sed -i -e 's+include "\([[:alpha:]/]*/\)\{0,1\}+include "\1CBigNumBoringSSL_+' -e 's+include <\([[:alpha:]/]*/\)\{0,1\}CBigNumBoringSSL_\(.*\)>+include "\1CBigNumBoringSSL_\2"+'
    popd
)

echo "PATCHING BoringSSL"
# Note: patch-1-inttypes.patch is no longer needed as inttypes.h works fine
# with modern Swift toolchains. patch-2-arm-arch.patch is no longer needed as
# modern BoringSSL's arm_arch.h has been simplified.

# We need to avoid having the stack be executable. BoringSSL does this in its build system, but we can't.
echo "PROTECTING against executable stacks"
(
    cd "$DSTROOT"
    # shellcheck disable=SC2038
    find . -name "*.S" | xargs $sed -i '$ a #if defined(__linux__) && defined(__ELF__)\n.section .note.GNU-stack,"",%progbits\n#endif\n'
)

# We need BoringSSL to be modularised
echo "MODULARISING BoringSSL"
cat << EOF > "$DSTROOT/include/CBigNumBoringSSL.h"
#ifndef C_BIGNUM_BORINGSSL_H
#define C_BIGNUM_BORINGSSL_H

#include "CBigNumBoringSSL_bn.h"
#include "CBigNumBoringSSL_bio.h"
#include "CBigNumBoringSSL_cpu.h"
#include "CBigNumBoringSSL_crypto.h"
#include "CBigNumBoringSSL_bytestring.h"
#include "CBigNumBoringSSL_err.h"
#include "CBigNumBoringSSL_rand.h"

#endif  // C_BIGNUM_BORINGSSL_H
EOF

echo "RECORDING BoringSSL revision"
echo "This directory is derived from BoringSSL cloned from https://boringssl.googlesource.com/boringssl at revision ${BORINGSSL_REVISION}" > "$DSTROOT/hash.txt"

echo "CLEANING temporary directory"
rm -rf "${TMPDIR}"

echo "DONE"
