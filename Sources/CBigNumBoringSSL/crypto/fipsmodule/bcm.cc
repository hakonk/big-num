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

#include <CBigNumBoringSSL_crypto.h>

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
