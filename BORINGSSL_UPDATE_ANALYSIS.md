# Updating the vendored BoringSSL: analysis, plan, and comparison with `claude/revendor-take3-review-kzmrrk`

*Analysis date: 2026-07-16. Upstream `main` HEAD at time of writing:
`0934f4a1f929f11cd3a420ac47641aa8fd584552` (2026-07-15).*

## 1. Where the codebase is today

`Sources/CBigNumBoringSSL` is a cutdown vendored copy of BoringSSL at revision
`295b31324f8c557dcd3c1c831857e33a7f23bc52`, committed **2022-01-07**
(`BORINGSSL_API_VERSION 16`). It was produced by `scripts/vendor-boringssl.sh`,
an adaptation of swift-crypto's vendoring script, and consists of:

- ~60 C99 source files: the BIGNUM core (`crypto/fipsmodule/bn/*.c`), plus its
  transitive dependencies — AES/cipher/modes (the CTR-DRBG behind `BN_rand`),
  the FIPS `rand` module, `rand_extra`, `err`, `bio`, `bytestring`, `stack`,
  `mem`, `thread*`, `cpu_*`, and `bn_extra/convert.c` (`BN_bn2dec` etc.).
- ~90 assembly files generated at vendor time by `scripts/build-asm.py`
  (perlasm), one copy per OS (`*.linux.*.S`, `*.mac.*.S`, `*.ios.*.S`).
- Symbol mangling done the old swift-crypto way: build a static library on
  macOS *and* cross-compiled Linux, harvest symbols with
  `util/read_symbols.go`, generate `boringssl_prefix_symbols*.h` with
  `util/make_prefix_headers.go`.
- Renamed headers (`include/openssl/bn.h` → `include/CBigNumBoringSSL_bn.h`),
  a hand-written umbrella header, and three local patches.

The Swift wrapper (`Sources/BigNum/BigNum.swift`, 412 lines) uses ~35 BoringSSL
functions: `BN_new/free`, arithmetic (`BN_add`…`BN_mod_exp`), conversion
(`BN_bn2dec/hex`, `BN_dec2bn/hex2bn`, `BN_bin2bn/bn2bin`), bit ops, primes
(`BN_generate_prime_ex`, `BN_is_prime_ex`), randomness (`BN_rand[_range]`,
`BN_pseudo_rand[_range]`), `BN_equal_consttime`, and `BN_CTX_new/free`.

**Good news:** every one of those functions still exists, with unchanged
signatures, in today's BoringSSL (`BN_pseudo_rand*` survive as documented
aliases of `BN_rand*`). An update requires **no changes to `BigNum.swift`** —
the entire cost is in the vendoring machinery.

## 2. What changed upstream between Jan 2022 and now

Verified against a fresh clone of `boringssl.googlesource.com/boringssl`
(HEAD `0934f4a1`, `BORINGSSL_API_VERSION 42`):

1. **libcrypto is now C++17.** Every source file is `.cc`
   (`gen/sources.json` lists zero `.c` files); upstream sets
   `CMAKE_CXX_STANDARD 17`. Consequences for SwiftPM: the
   `CBigNumBoringSSL` target becomes a C++ target, `Package.swift` needs
   `cxxLanguageStandard: .cxx17`, and consumers link the C++ runtime
   (libc++/libstdc++). The *public* headers remain C-compatible, so the Swift
   side is unaffected. swift-crypto crossed this same bridge in 2024.

2. **The FIPS module is now a single unity translation unit.** The individual
   `crypto/fipsmodule/*/*.c` files no longer exist; they are `.cc.inc`
   fragments (`bn/add.cc.inc`, …) that only compile via
   `crypto/fipsmodule/bcm.cc`, which `#include`s ~90 fragments spanning the
   whole module (AES, BN, EC, RSA, ML-KEM, ML-DSA, self-check KATs, …).
   The old script's "copy `bn/*.c`, delete `bcm.c`" approach is structurally
   dead. Options: vendor `bcm.cc` wholesale (drags in everything), or write a
   trimmed replacement unity TU that includes only the fragments BIGNUM needs.

3. **Assembly is pregenerated upstream.** `gen/bcm/*.S` and `gen/crypto/*.S`
   ship per-platform (`-apple`/`-linux`/`-win` suffixes) with internal
   `#if defined(OPENSSL_X86_64) && defined(__ELF__)`-style guards via the new
   `<openssl/asm_base.h>`. `scripts/build-asm.py` (perlasm at vendor time) and
   its ios/mac/linux renaming are obsolete; so is the Go toolchain dependency.
   Windows assembly is nasm `.asm`, which SwiftPM cannot build → inject
   `OPENSSL_NO_ASM` for Windows.

4. **Symbol prefixing is now first-class.** Upstream ships pregenerated
   `include/openssl/prefix_symbols.h`, `prefix_symbols_internal_c.h`, and
   `prefix_symbols_internal_S.h`, wired in automatically by `base.h`,
   `crypto/internal.h`, and `asm_base.h` whenever `BORINGSSL_PREFIX` is
   defined (`#pragma redefine_extname` / macro fallback).
   `util/read_symbols.go` and `util/make_prefix_headers.go` no longer exist.
   The entire `mangle_symbols` phase — including the macOS + cross-compiled
   Linux builds it required — collapses into "define
   `BORINGSSL_PREFIX CBigNumBoringSSL` in `base.h` and vendor the three
   prefix headers". The vendor script becomes runnable on any host with git,
   sed and perl.

5. **`err_data.c` is pregenerated** at `gen/crypto/err_data.cc`; the
   `go run err_data_generate.go` step disappears.

6. **Directory and header moves.** `crypto/rand_extra/` → `crypto/rand/`;
   entropy split into `crypto/fipsmodule/entropy/` (jitter + SHA-512
   whitening) + `crypto/fipsmodule/rand/` (CTR-DRBG);
   `crypto/bn_extra/` → `crypto/bn/`; new required headers `target.h`,
   `asm_base.h`, `bcm_interface.h`, `ctrdrbg.h`, `sha2.h`; `cpu.h` and
   `type_check.h` are now empty compatibility stubs; `refcount_c11.c`/
   `refcount_lock.c` merged into `refcount.cc`.

7. **BoringSSL now publishes releases.** Since 2024 upstream periodically
   stamps Bazel Central Registry releases ("Bump version for Bazel Central
   Registry" commits, e.g. `0.20260508.0` = `d589045a`, 2026-05-08 — the
   newest release as of this analysis). Pinning a release rather than an
   arbitrary `main` commit is now a legitimate, auditable choice.

8. **Old local patches are obsolete.** `patch-1-inttypes.patch`,
   `patch-2-arm-arch.patch`, `patch-3-weak-linking.patch` target 2022-era
   files; none apply to the new tree.

9. **Minor script rot worth fixing while here:** the old script's
   `getopts 'uk:'` doesn't match its documented `-c`/`-k` flags, and the
   `sed` that stamps "BoringSSL Commit:" into `Package.swift` silently
   no-ops because the marker comment no longer exists there.

## 3. My plan

### Strategy choice

- **Strategy A — realign with swift-crypto: vendor all of libcrypto.**
  Port swift-crypto's current vendoring approach (`CCryptoBoringSSL` →
  `CBigNumBoringSSL`), ship `bcm.cc` plus all ~243 `crypto/*.cc` files and
  ~120 assembly files. *Pros:* battle-tested upstream alignment, future
  re-vendors are nearly mechanical. *Cons:* ~4× more vendored code, slower
  builds, larger binaries; abandons this package's stated "cutdown" design.

- **Strategy B — keep the cutdown: trimmed unity TU.** Replace `bcm.cc` with
  a small hand-written unity file including only the fragments the BN closure
  needs: `bn/*.cc.inc`, AES core (DRBG block cipher), `rand/ctrdrbg`,
  `rand/rand`, `entropy/*`, `sha/sha256|sha512`, plus the non-FIPS wrappers
  (`crypto/bn/`, `crypto/rand/`, `bytestring`, `err`, `mem`, `thread`,
  `cpu_*`). Omit `self_check`/`service_indicator` internals (stub the two
  non-FIPS service-indicator functions). *Pros:* preserves the small
  footprint (~1/4 of the code). *Cons:* the dependency closure is bespoke and
  must be re-validated on every re-vendor, on **every supported
  architecture** — a static library links with unresolved symbols, so only
  `swift test` on each arch proves the closure.

**Recommendation:** Strategy B, *provided* the closure fragility is fenced
with automation (manifest/provenance verification, multi-arch CI, an upstream
staleness watchdog). Without that fencing, Strategy A is the safer default.
This package exists specifically to be a small BIGNUM library; tripling its
vendored surface to include RSA/EC/ML-KEM it never calls is hard to justify —
and per-file provenance is *more* auditable than a bulk copy.

### Steps

1. **Rewrite the vendor script** (new file; keep the old one for reference):
   - Clone upstream at an explicit revision argument (default: latest BCR
     release; optionally `main` HEAD).
   - Copy an explicit allowlist of files (sources, `.cc.inc` fragments,
     internal headers, `gen/bcm` + `gen/crypto/err_data.cc` assembly for the
     needed algorithms only, public headers narrowed to the closure).
   - Generate the trimmed unity TU replacing `bcm.cc`.
   - Keep the header renaming (`CBigNumBoringSSL_` prefix, quoted includes)
     and umbrella header; regenerate the modulemap.
   - Inject `#define BORINGSSL_PREFIX CBigNumBoringSSL` into `base.h`; vendor
     upstream's pregenerated `prefix_symbols*.h` as-is (extra `#define`s for
     symbols we don't ship are harmless).
   - Inject `OPENSSL_NO_ASM` for Windows (no nasm under SwiftPM) and 32-bit
     Apple.
   - Drop entirely: `mangle_symbols`, `build-asm.py`, `err_data_generate.go`,
     the Go/cross-compile prerequisites, the three stale patches.
   - Make every textual-surgery step (sed/perl) assert its own post-condition
     so upstream refactors fail the vendor run loudly.
   - Record the pinned revision (`hash.txt` + a stamp in `Package.swift`).
2. **Update `Package.swift`:** add `cxxLanguageStandard: .cxx17`; exclude any
   non-source metadata directories from the target.
3. **Re-vendor and validate:** `swift test` on macOS arm64/x86_64 and Linux
   arm64/x86_64 (closure link-check requires the test executable, not just
   `swift build`); `nm` the static library to confirm every exported symbol
   carries the `CBigNumBoringSSL_` prefix.
4. **CI:** keep the existing matrix; add a job that verifies the vendored
   tree matches upstream at the pinned revision (catches silent local edits);
   add a scheduled workflow that fails when upstream commits touch vendored
   paths, as a forcing function against another four-year freeze.
5. **Docs:** document the new vendoring flow and the rationale for the
   trimmed closure.

### Risks

- **Closure drift:** upstream can add a new cross-fragment dependency at any
  time; only per-arch `swift test` catches it. Mitigated by CI + watchdog.
- **C++ runtime linkage:** consumers now transitively link libc++/libstdc++.
  swift-crypto shipped the same change; no action needed, but it belongs in
  release notes as a semver-minor behavior change.
- **Symbol-collision safety** must be re-verified (apps embedding both this
  package and swift-crypto): the new prefix mechanism covers C symbols and
  assembly, and BoringSSL's C++ internals live in the `bssl` namespace within
  a static archive.

## 4. Comparison with `claude/revendor-take3-review-kzmrrk`

The branch (5 commits, ending `de2bf9f`, 2026-07-02) re-vendors at
`d589045a77` = **release `0.20260508.0`** (2026-05-08, API version 40) and is,
in structure, the same Strategy B described above — executed with guardrails
that go beyond my plan in several places.

### What the branch does

- `scripts/vendor-boringssl-2.sh` (668 lines): explicit `ALLOW_FILES`
  allowlist; generated `bn_unity.cc` replacing `bcm.cc` (BN + AES-ECB +
  CTR-DRBG + jitter entropy + SHA-256/512, with the two non-FIPS
  service-indicator functions stubbed inline); pregenerated `gen/bcm`
  assembly for exactly those algorithms; upstream `prefix_symbols*.h`
  vendored wholesale; `OPENSSL_NO_ASM` injected for Windows x86/x86_64 and
  32-bit Apple; post-condition assertions after every sed/perl edit.
- **Provenance system** (beyond my plan): a reversible `.patch` per modified
  file under `Sources/CBigNumBoringSSL/provenance/`, `PROVENANCE.txt` mapping
  every vendored file to its upstream path, `MANIFEST.sha256` over the whole
  tree, and `scripts/verify-provenance.sh` wired into CI to re-derive the
  tree from a blobless upstream clone.
- **`upstream-watch.yml`**: monthly workflow that fails when upstream commits
  touch any vendored path since the pin — the anti-staleness forcing function
  I wanted, already built, and correctly derived from `PROVENANCE.txt` rather
  than a hand-maintained list.
- `Package.swift`: `cxxLanguageStandard: .cxx17`, `exclude: ["provenance"]`,
  and a re-instated "BoringSSL Commit:" stamp (fixing the old script's
  silent no-op sed).
- `scripts/VENDORING.md` (478 lines): documents the flow, the closure
  rationale, and why the old script is obsolete.
- Zero changes to `Sources/BigNum/BigNum.swift` — consistent with my API
  audit.
- The final commit fixes a real closure bug found in review: `rdrand-x86_64`
  assembly had been dropped although `rand.cc.inc` references
  `CRYPTO_rdrand*` on x86_64, breaking the link on Intel — caught only by
  `swift test` on linux/x86_64. This is precisely the Strategy B risk my plan
  flags, and it validates the "test on every arch" requirement.

### Where my plan and the branch agree

Strategy (trimmed unity TU over full-libcrypto or wholesale `bcm.cc`),
`cxx17` in `Package.swift`, pregenerated assembly + `err_data.cc`, upstream
prefix headers with `BORINGSSL_PREFIX` injected into `base.h`, `OPENSSL_NO_ASM`
on Windows, deletion of the Go/perlasm/cross-compile machinery, loud
post-condition asserts, provenance/staleness CI, no Swift-side changes.

### Differences and findings from the review

1. **The branch is already stale by its own watchdog's criterion.** Checked
   against upstream `main` today: **49 commits since `d589045a` touch
   vendored paths** (e.g. `5124f7e` "Enable .subsections_via_symbols on all
   assembly files", `0705ca9` perlasm AESNI fix, plus broad edits to
   `crypto/internal.h` and `bytestring/`). No newer BCR release exists yet,
   so the choices are: merge as-is at the latest *release* and let
   `upstream-watch` drive the next re-vendor, or re-run
   `vendor-boringssl-2.sh` against `main` HEAD (`0934f4a1`) before merging.
   If "latest revision" is taken literally, do the latter; I'd lean to
   release-pinning as the steady-state policy, with a re-vendor at the next
   release.
2. **Pin policy: release vs HEAD.** My plan defaulted to "latest revision";
   the branch pins the newest BCR release. The branch's choice is more
   auditable and I'd adopt it — but it should be stated as policy in
   `VENDORING.md` (it currently reads as incidental: the script defaults to
   `main` HEAD while the tree pins a release).
3. **Old tooling retained.** `vendor-boringssl.sh`, `build-asm.py`, and the
   three stale patches remain in `scripts/` "for reference". I'd delete them
   (git history preserves them); at minimum they must not look runnable.
4. **Provenance depth.** The branch's per-file patch + manifest + verifier
   system exceeds my plan (I had only planned a pinned-revision diff check in
   CI). It's the strongest part of the branch: it makes the bespoke trimmed
   closure — Strategy B's main liability — independently re-derivable and
   tamper-evident.
5. **Verification status unknown in this environment.** No Swift toolchain is
   available in this container, so I could not run `swift test` on the
   branch. The final commit message reports `swift test` passing on
   linux/x86_64 after the rdrand fix; before merging, CI should demonstrate
   green on macOS arm64 + Linux x86_64/arm64 at minimum (the rdrand episode
   shows single-arch verification is insufficient).

### Verdict

The branch is a sound, careful implementation of the same strategy I would
choose, with better provenance tooling than I had planned. I would merge it
subject to three follow-ups: decide the pin policy explicitly (and either
re-vendor at `main` HEAD now or accept release-lag until the next BCR
release), prove multi-arch CI green, and remove the obsolete 2022 tooling
from `scripts/`.
