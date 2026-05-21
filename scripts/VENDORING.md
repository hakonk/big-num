# Vendoring BoringSSL into big-num

This document explains how `Sources/CBigNumBoringSSL/` is produced from an
upstream [BoringSSL](https://boringssl.googlesource.com/boringssl) checkout
via `scripts/vendor-boringssl-2.sh`, why the approach is what it is, and
what the script does step-by-step.

The older `scripts/vendor-boringssl.sh` is retained for reference only and
should not be used. See [Why the old script is obsolete](#why-the-old-script-is-obsolete)
below.

## TL;DR — how to re-vendor

```bash
# HEAD of main
scripts/vendor-boringssl-2.sh

# A specific upstream tag or commit
scripts/vendor-boringssl-2.sh 0.20260508.0

# Reuse an existing clone (skips the network fetch)
scripts/vendor-boringssl-2.sh -p /path/to/boringssl
```

Prerequisites:

- GNU sed (`brew install gnu-sed` on macOS — the script expects `gsed`)
- `sha256sum` (provided by `brew install coreutils` on macOS)
- `perl` (preinstalled everywhere we care about)
- `git`

When it finishes, commit everything under `Sources/CBigNumBoringSSL/`,
including the regenerated `MANIFEST.sha256` and `PROVENANCE.txt`.

## What lands in `Sources/CBigNumBoringSSL/`

```
Sources/CBigNumBoringSSL/
├── include/                        # ~35 renamed openssl/*.h, narrowed to the BN deps
│   ├── CBigNumBoringSSL.h          # umbrella header (generated)
│   ├── module.modulemap            # Clang module (generated)
│   ├── CBigNumBoringSSL_base.h     # = include/openssl/base.h + prefix injection
│   ├── CBigNumBoringSSL_bn.h       # = include/openssl/bn.h with #include rewrites
│   ├── CBigNumBoringSSL_prefix_symbols.h
│   └── ...
├── crypto/                         # BN, AES, SHA-2, rand, err, threading, cpu probe
│   ├── bn/                         # public BN_* wrappers (no bn_asn1.cc)
│   ├── bytestring/                 # CBB/CBS — pulled in by BN_bn2hex / BN_bn2dec
│   ├── asn1/                       # internal.h + posix_time.cc only (used by cbs.cc)
│   └── fipsmodule/
│       ├── bn_unity.cc             # GENERATED — replaces upstream bcm.cc
│       ├── bn/, aes/, rand/, sha/, entropy/   # only the .cc.inc bn_unity uses
│       └── service_indicator/      # internal.h only (stubs inlined into bn_unity.cc)
├── gen/                            # only BN/AES/SHA-2 assembly + err_data.cc
├── hash.txt                        # upstream commit hash
├── PROVENANCE.txt                  # per-file mapping back to upstream
└── MANIFEST.sha256                 # sha256 of every committed file
```

What is **not** shipped: the implementation source for `base64`, `bio`,
`cipher`, `cms`, `conf`, `curve25519`, `dh`, `dsa`, `ec*`, `evp`, `hmac`,
`hkdf`, `hpke`, `hrss`, `kyber`, `mldsa`, `mlkem`, `obj`, `pem`, `pkcs*`,
`poly1305`, `rsa`, `slhdsa`, `trust_token`, `x509*`, `third_party/fiat/`,
nor `bcm.cc` itself. (`crypto/asn1/` is the lone partial — only its
`internal.h` and `posix_time.cc`. A few public headers, e.g. `bio.h`,
`mldsa.h`, `mlkem.h`, still ship because kept files include them, but no
matching `.cc` does.) The closure was determined empirically by deleting
everything else and iterating `swift build` / `swift test` until clean;
the exact set is the `ALLOW_FILES` array in `vendor-boringssl-2.sh`.

The library is built as a single SwiftPM target named `CBigNumBoringSSL`
declared in `Package.swift` (no `cxxSettings`; the package-level
`cxxLanguageStandard: .cxx17` covers it).

### Why `bn_unity.cc` exists

Upstream's `crypto/fipsmodule/bcm.cc` is a unity translation unit that
`#include`s every algorithm under `fipsmodule/` (AES, BN, EC, RSA, ML-DSA,
SLH-DSA, …) so the FIPS integrity check can hash one contiguous `.text`
section. Compiling it requires shipping the entire FIPS module.

`bn_unity.cc` is a hand-written replacement that `#include`s only the
`.cc.inc` files BN actually touches: the 21 `bn/*.cc.inc`, AES-ECB
(`aes.cc.inc` + `aes_nohw.cc.inc`) for the CTR-DRBG, the DRBG itself
(`rand/ctrdrbg.cc.inc`, `rand/rand.cc.inc`), entropy whitening
(`entropy/jitter.cc.inc`), and SHA-256/512. It also inlines the two
non-FIPS service-indicator stubs so we don't need to ship the EC/EVP-heavy
`service_indicator.cc.inc`. The full source is in the heredoc at the
bottom of `vendor-boringssl-2.sh`; do not edit the copy under
`crypto/fipsmodule/` directly — re-vendor instead.

### The one upstream patch: `convert.cc`

`crypto/bn/convert.cc` defines `BN_print` / `BN_print_fp`, which take a
`BIO *`. `crypto/bio/` is not part of the BN closure, so the script strips
those two functions and the `<openssl/bio.h>` include after copy. Anyone
who needs `BN_print` should reintroduce `crypto/bio/` and revert the
`bn-print-stripped` transform in `PROVENANCE.txt`.

## The core trick: upstream now ships the prefix headers

BoringSSL supports a build-time symbol prefix mechanism that namespaces
every public C symbol so it can't collide with a system OpenSSL. You opt
in by defining `BORINGSSL_PREFIX` before including any BoringSSL header;
the upstream `include/openssl/base.h` then pulls in `prefix_symbols*.h`,
which contain entries like:

```c
#define BN_new BORINGSSL_ADD_PREFIX(BN_new)   // expands to CBigNumBoringSSL_BN_new
```

for every public symbol.

**These headers are now committed to BoringSSL upstream.** They are
regenerated by the BoringSSL maintainers via `go ./util/pregenerate`
against their full cross-platform build matrix, so the committed list
already contains the union of every symbol across every supported target
(macOS, Linux, iOS, Android, Windows, x86_64/aarch64/arm/x86, etc.).

That single change is what lets the vendor script be ~560 lines of pure
shell with no Go, no Docker, no cross-compilers.

## Why individual files don't need prefixing

The prefix mechanism is **centralised in the preprocessor**, not applied
per-file. Once upstream's `prefix_symbols.h` exists, exactly one edit is
enough to rename every public symbol across the entire BoringSSL tree.

### The chain

1. Every BoringSSL `.cc` and public `.h` file already includes
   `openssl/base.h` (directly or transitively — it's their root header).
2. `base.h` contains:
   ```c
   #if defined(BORINGSSL_PREFIX)
   #include "prefix_symbols.h"   // upstream ships this file
   #endif
   ```
3. Upstream's `prefix_symbols.h` contains a `#define` for every public
   symbol, expanded via `BORINGSSL_PREFIX`:
   ```c
   #define BN_new BORINGSSL_ADD_PREFIX(BN_new)
   // BORINGSSL_ADD_PREFIX(BN_new) → CBigNumBoringSSL_BN_new
   ```
4. The vendor script makes exactly **one** edit, into `base.h`:
   ```c
   #define BORINGSSL_PREFIX CBigNumBoringSSL
   ```

After that, every translation unit BoringSSL compiles starts with:
include `base.h` → see `BORINGSSL_PREFIX` defined → pull in
`prefix_symbols.h` → every appearance of `BN_new`, `BN_free`,
`OPENSSL_malloc`, etc. is macro-expanded to its prefixed form **by the
preprocessor, before the compiler ever sees it**.

So the `.cc` file on disk still literally reads:

```c++
BIGNUM *BN_new(void) {
  BIGNUM *bn = reinterpret_cast<BIGNUM *>(OPENSSL_malloc(sizeof(BIGNUM)));
  // ...
}
```

But by the time the C++ frontend parses it, the function is defined as
`CBigNumBoringSSL_BN_new` and its call to `OPENSSL_malloc` is to
`CBigNumBoringSSL_OPENSSL_malloc`. The same expansion happens at every
call site in every other file. No per-file edits required.

### Why this didn't work in the old script

The old script had the same one-line `#define BORINGSSL_PREFIX
CBigNumBoringSSL` injection. The reason it needed cross-compilation
wasn't to "prefix files" — it was because **`prefix_symbols.h` didn't
exist in upstream yet**. The script had to *manufacture* that header
itself by running the BoringSSL build on every target platform,
extracting the symbol list from each `.a`, and emitting the
`#define BN_new …` lines into `boringssl_prefix_symbols.h`. Once that
file existed, the rest of the rename was identical preprocessor work.

The new script skips all that because upstream commits the same file
ready-made.

### The two exceptions

Two file categories aren't reached by `base.h`'s include chain, so the
vendor script touches them explicitly:

1. **Assembly (`.S`) files** — they don't include `base.h`, only
   `asm_base.h`. The script prepends `#define BORINGSSL_PREFIX
   CBigNumBoringSSL` as line 1 of every `.S` file so that when
   `asm_base.h` pulls in `prefix_symbols_internal_S.h`, the prefix
   macro is already defined.

2. **The header files themselves** — these are *renamed* on disk
   (`include/openssl/bn.h` → `include/CBigNumBoringSSL_bn.h`), and
   `#include <openssl/X>` is rewritten to `#include
   <CBigNumBoringSSL_X>` throughout the tree. That's a *header path*
   rename, not a *symbol* prefix — it just keeps SwiftPM's flat
   `include/` layout from clashing with a system OpenSSL's
   `openssl/*.h` if one were present on the include path.

Everything else — the actual C++ symbol prefixing across hundreds of
source files — is the preprocessor's job, driven by one `#define` and
one upstream-shipped header.

## What the script does, in order

1. **Clone** BoringSSL into a tempdir (or use `-p` to reuse an existing
   clone, skipping the network fetch).
2. **Checkout** the requested revision — the tag/SHA argument, or HEAD if
   none was given — and capture the resolved commit SHA.
3. **Wipe** any previously-vendored tree: `rm -rf` of `include/`,
   `crypto/`, `gen/`, and `third_party/` under `Sources/CBigNumBoringSSL/`.
4. **Copy** the `ALLOW_FILES` allowlist. This is an explicit array of
   roughly 170 exact upstream paths — *not* a glob — each copied verbatim
   to the same relative path under `Sources/CBigNumBoringSSL/`. If any
   allowlisted file no longer exists upstream the script aborts non-zero,
   so the list can't silently rot. `bcm.cc` and every test source are
   simply never listed, so there is nothing to exclude after the fact.
5. **Strip libssl headers** (`ssl.h`, `tls1.h`, `dtls1.h`, `srtp.h`,
   `ssl3.h`) — a defensive `rm -f`. The allowlist never copies them; the
   step just guarantees a libcrypto-only tree.
6. **Disable assembly on Windows-x86 / 32-bit Apple** by injecting
   `#define OPENSSL_NO_ASM` guards into `base.h`.
7. **Inject the prefix knob** into `base.h`:
   ```c
   #define BORINGSSL_PREFIX CBigNumBoringSSL
   #undef __PRAGMA_REDEFINE_EXTNAME
   ```
   See [Why we `#undef __PRAGMA_REDEFINE_EXTNAME`](#why-we-undef-__pragma_redefine_extname) below — this is load-bearing for Swift interop.
8. **Stamp `.S` files** with `#define BORINGSSL_PREFIX CBigNumBoringSSL`
   at the top. Assembly files don't include `base.h` (only `asm_base.h`
   via `target.h`), so the macro wouldn't otherwise be visible when
   `prefix_symbols_internal_S.h` runs.
9. **Patch `crypto/bn/convert.cc`**: delete the `<openssl/bio.h>` include
   and the `BN_print` / `BN_print_fp` function bodies, which take a
   `BIO *`. See [The one upstream patch](#the-one-upstream-patch-convertcc)
   above. This runs before the header rewrite in step 10, so the include
   it deletes is still spelled `<openssl/bio.h>`.
10. **Move and rename headers**: `include/openssl/X.h` → `include/CBigNumBoringSSL_X.h`. Rewrite every `#include <openssl/X>` and `#include "openssl/X"` to `#include <CBigNumBoringSSL_X>` across the whole tree (`.h`, `.cc`, `.S`, `.c.inc`, `.cc.inc`, `.inc`); header-to-header includes additionally switch to the quoted form.
11. **Install `bn_unity.cc`**: write the hand-rolled FIPS unity TU to
    `crypto/fipsmodule/bn_unity.cc` from the heredoc at the bottom of the
    script. It replaces upstream `bcm.cc`, which the allowlist never
    copies. See [Why `bn_unity.cc` exists](#why-bn_unitycc-exists) above.
12. **Write umbrella + modulemap**: `CBigNumBoringSSL.h` includes the
    handful of public headers BigNum.swift actually uses (`base`, `bn`,
    `crypto`, `err`, `mem`, `rand`). `module.modulemap` exposes the
    umbrella as a Clang module.
13. **Record provenance**: write `hash.txt` (one-line upstream commit)
    and update the `BoringSSL Commit:` line in `Package.swift`. Then emit
    `PROVENANCE.txt` — per-file
    `<vendored_path>\t<upstream_path>\t<transformation>` rows, where the
    transformation is one of `verbatim`, `include-rewrite`,
    `header-rename`, `header-rename+base`, `asm-prefix`,
    `bn-print-stripped`, or `generated`.
14. **Record manifest**: `MANIFEST.sha256` is `sha256sum` over every
    committed file except `MANIFEST.sha256` itself. Anyone can run
    `sha256sum -c MANIFEST.sha256` to confirm the tree hasn't been
    tampered with locally.

Combined, `PROVENANCE.txt` + `MANIFEST.sha256` + this deterministic
script give end-to-end attestation back to the BoringSSL upstream
revision in `hash.txt`.

## Why we `#undef __PRAGMA_REDEFINE_EXTNAME`

`prefix_symbols.h` has two parallel implementations of the prefix:

```c
#if defined(__PRAGMA_REDEFINE_EXTNAME) && !defined(__ASSEMBLER__)
  #pragma redefine_extname BN_new CBigNumBoringSSL_BN_new
  // ... thousands more pragmas ...
#else
  #define BN_new CBigNumBoringSSL_BN_new
  // ... thousands more defines ...
#endif
```

Apple Clang, mainline Clang, and GCC all define
`__PRAGMA_REDEFINE_EXTNAME`, so the pragma branch wins by default.
That's fine for C/C++ code: the pragma instructs the compiler to emit
the prefixed name as the linker symbol, which is exactly what we want.

It is **not** fine for Swift. Swift's Clang importer reads function
declarations by their textual name. `BIGNUM *BN_new(void);` gets
imported into Swift as `BN_new`. The pragma is invisible to the
importer, so Swift emits calls to a `BN_new` symbol that doesn't exist
in the linked archive (only `CBigNumBoringSSL_BN_new` does).

By forcing the `#define` branch, the textual name visible to the
importer becomes `CBigNumBoringSSL_BN_new`, which matches what's
exported. Swift code therefore calls the prefixed name directly,
matching the rest of the codebase.

Cross-platform: Linux Clang and Linux GCC both define
`__PRAGMA_REDEFINE_EXTNAME`, so the same `#undef` applies and the same
fix works for `swift test` inside `swift:6.3` Docker (verified on
linux/arm64).

## Why the old script is obsolete

`scripts/vendor-boringssl.sh` (the predecessor, adapted from
swift-nio-ssl) solved one problem: **producing the prefix headers
itself**, since older BoringSSL didn't ship them.

To do that it had to enumerate the actual set of symbols BoringSSL
exports on each supported target. Symbols vary per target — different
`#ifdef` branches, different ASM entry points (Intel vs ARM),
different inline/template expansions, different object-format mangling
(leading underscore on Mach-O, not on ELF). So it would:

1. Build `libCBigNumBoringSSL.a` for macOS via `swift build`.
2. Cross-compile the archive for each Linux destination JSON in
   `/Library/Developer/Destinations`.
3. (Historically) build for iOS too via `xcodebuild`.
4. Run `go run util/read_symbols.go` against each archive to dump
   symbol names (with separate `-obj-file-format elf` for Linux).
5. Concat + sort + uniq the per-platform lists.
6. Feed the union into `go run util/make_prefix_headers.go` to emit
   `boringssl_prefix_symbols*.h`.
7. Separately walk `crypto/*` for `DEFINE_STACK_OF(...)` and
   `DEFINE_LHASH_OF(...)` macros (`namespace_inlines`) and synthesize
   the corresponding `sk_X_*` / `lh_X_*` entries that the inline
   expansions need.

The new script doesn't need any of that:

| Old step | Status in `vendor-boringssl-2.sh` |
|---|---|
| `swift build` for macOS, just to inspect `.a` | Removed |
| Cross-compile `.a` for each Linux target | Removed |
| `util/read_symbols.go` invocation | Removed — and **`read_symbols.go` itself was deleted from BoringSSL upstream** in commit `1842c3eb` (Jan 2026) when prefix generation moved into CMake |
| `util/make_prefix_headers.go` invocation | Removed — same commit `b523a5f5` (Jan 2026), upstream now ships the headers it used to generate |
| Go toolchain at vendor time | Not required |
| `namespace_inlines` for `sk_*` / `lh_*` | Removed; upstream's `prefix_symbols.h` already enumerates these |
| `MANGLE_START` / `MANGLE_END` toggling of `Package.swift` | Removed (only existed to make `swift build` of step 1 possible) |
| Linux Docker builds | Not required (their only purpose was producing ELF archives for `read_symbols.go`) |
| `patch-1-inttypes.patch`, `patch-2-arm-arch.patch`, `patch-3-weak-linking.patch` | Not applied; upstream sources are clean on the platforms we target |

So the cross-compilation in the old script was never about *building
for* Linux or iOS — `Package.swift` does that at consumer build time.
It was purely about *enumerating linker symbols on* those platforms,
which became unnecessary the moment upstream started shipping a
prebuilt union list.

## Required `Package.swift` settings

The package must compile BoringSSL's `.cc` files as C++17. Modern
BoringSSL uses inline `constexpr` variables and the C++17 variable
templates `std::is_const_v`, `std::is_convertible_v`, and
`std::is_integral_v` in `include/openssl/span.h`. SwiftPM defaults to
an older C++ standard, so the package needs:

```swift
let package = Package(
    name: "big-num",
    // ...
    cxxLanguageStandard: .cxx17
)
```

This is set once at package level rather than per-target.

## Verifying a vendored tree

From a fresh checkout, in `Sources/CBigNumBoringSSL/`:

```bash
sha256sum -c MANIFEST.sha256   # every file matches its recorded hash
```

To verify the tree against upstream, you can independently re-run
`vendor-boringssl-2.sh` against the revision in `hash.txt`; the result
should be byte-identical to what's committed (modulo `MANIFEST.sha256`
itself, which is recomputed on each run from the same inputs and should
therefore also match).
