# Why the new vendoring stages are needed

The re-vendoring pipeline (`scripts/vendor-boringssl-2.sh` on the
`claude/revendor-take3-review-kzmrrk` branch, and equivalently the plan in
`BORINGSSL_UPDATE_ANALYSIS.md`) contains a number of stages that did not exist
in the original `scripts/vendor-boringssl.sh`. None of them is incidental:
each one exists because (a) BoringSSL changed in a way that broke the old
stage it replaces, (b) SwiftPM imposes a constraint that upstream's own build
system handles differently, or (c) a concrete failure mode — observed in this
repository's own history — needed a guard.

This document walks the pipeline stage by stage and gives the reason each one
has to exist. The companion `scripts/VENDORING.md` on the branch describes
*how* the stages work; this document is the *why*.

---

## 1. Pinning an explicit upstream revision (and defaulting to releases)

**What it does:** the script takes a tag or commit as its argument, records
it in `hash.txt`, and stamps it into `Package.swift`.

**Why it is needed:** the old script vendored whatever `HEAD` happened to be
in a local clone, and its `sed` that recorded the commit into `Package.swift`
silently did nothing (the marker comment it searched for did not exist). The
result was a tree whose provenance could only be reconstructed from
`hash.txt` — and nothing that forced anyone to update it. Since 2024,
BoringSSL also publishes periodic Bazel Central Registry releases
(e.g. `0.20260508.0`); pinning those gives an auditable, citable version
instead of an arbitrary commit. Every downstream guarantee in the pipeline —
provenance patches, the manifest, the upstream watchdog — is defined
*relative to the pin*, so the pin must be explicit and machine-readable.

## 2. An explicit file allowlist instead of glob patterns

**What it does:** replaces the old `PATTERNS=('crypto/fipsmodule/bn/*.c' …)`
globs with a literal list of every file to copy (`ALLOW_FILES`).

**Why it is needed:** two reasons.

First, upstream's layout churned underneath the globs. `crypto/fipsmodule/bn/`
no longer contains `.c` files at all — it contains `.cc.inc` fragments.
`crypto/rand_extra/` became `crypto/rand/`; `crypto/bn_extra/` became
`crypto/bn/`; `err_data.c` moved to `gen/crypto/err_data.cc`. A glob that
matches nothing is not an error in shell — the old script would have silently
produced an incomplete tree.

Second, the trimmed unity build (stage 8) makes the vendored set a *precise
dependency closure*, not a neighborhood. Copying "everything in this
directory" no longer approximates correctness: one missing file is a link
error on some architectures only (see stage 15), and one extra file can drag
in an entire subsystem (upstream's `bn/convert.cc` alone pulls in BIO — see
stage 6). A closure this exact must be spelled out, reviewed, and diffed as
an explicit list.

## 3. Copying pregenerated assembly from `gen/` (deleting `build-asm.py`)

**What it does:** copies upstream's checked-in `gen/bcm/*.S` and
`gen/crypto/*.S` files verbatim, restricted to the algorithms in the closure.

**Why it is needed:** the old pipeline ran perlasm at vendor time
(`scripts/build-asm.py`) and emitted one copy of each file per OS
(`*.linux.x86_64.S`, `*.mac.x86_64.S`, `*.ios.arm.S`). Upstream has since
inverted this: assembly is pregenerated in-tree, one file per
platform/architecture pair, each internally guarded by preprocessor checks
(`OPENSSL_X86_64`, `__ELF__`, `__APPLE__`, …) via the new
`<openssl/asm_base.h>`. This removes the vendor-time dependency on Perl and
on upstream's generator scripts — which have themselves changed shape — and
means every platform's assembly can be compiled unconditionally in a SwiftPM
target, with the guards selecting the right body. Regenerating assembly
ourselves would now be *reimplementing* something upstream ships, tests, and
audits.

## 4. Injecting `OPENSSL_NO_ASM` for Windows x86/x86_64 (and 32-bit Apple)

**What it does:** adds a small `#if defined(_WIN32) …` block to `base.h`
defining `OPENSSL_NO_ASM`, instead of vendoring Windows assembly.

**Why it is needed:** upstream's Windows x86 assembly is shipped as nasm
`.asm` files. SwiftPM has no nasm build rule — it can only assemble `.S`
files through Clang. The choice is therefore: teach every Windows consumer to
run nasm out-of-band (impossible in a plain SwiftPM dependency), or compile
the portable C fallbacks on Windows. `OPENSSL_NO_ASM` is upstream's own
supported switch for exactly this; the performance cost applies only on
Windows, which this package's CI has never targeted. The 32-bit Apple gate
carries over the same decision the old script already made.

## 5. `BORINGSSL_PREFIX` injection + vendoring upstream's `prefix_symbols*.h`

**What it does:** injects `#define BORINGSSL_PREFIX CBigNumBoringSSL` into
`base.h` and copies upstream's pregenerated `prefix_symbols.h`,
`prefix_symbols_internal_c.h`, and `prefix_symbols_internal_S.h` — deleting
the whole `mangle_symbols` phase of the old script.

**Why it is needed:** symbol prefixing is not optional — it is what allows an
app to link this package alongside swift-crypto (or anything else embedding
BoringSSL) without duplicate-symbol collisions. But the old *mechanism* is
gone: `util/read_symbols.go` and `util/make_prefix_headers.go` no longer
exist upstream. The old stage also required a macOS host, a working Go
toolchain, and cross-compiled Linux builds just to harvest the symbol list —
it was the single most fragile, least reproducible part of the old script.
Upstream now ships the complete prefix header pregenerated and wires it in
automatically through `base.h`/`crypto/internal.h`/`asm_base.h` whenever
`BORINGSSL_PREFIX` is defined. Vendoring it wholesale (including entries for
symbols we don't ship, which are inert `#define`s) replaces a multi-platform
build-and-scrape pipeline with one copied file and one injected line.

Two sub-steps of this stage look odd and are load-bearing:

- **`#undef __PRAGMA_REDEFINE_EXTNAME`.** Upstream's prefix header prefers
  `#pragma redefine_extname`, which renames symbols at *link* level while
  leaving declaration names untouched. That is fine for C and C++ callers,
  but Swift's Clang importer imports functions by their textual declaration
  name and emits calls to that name — which would be the *unprefixed* symbol,
  absent from the archive. Forcing the macro-based fallback
  (`#define BN_new CBigNumBoringSSL_BN_new`) makes the rename visible to the
  importer. Without this line, the package fails to link from Swift on
  platforms whose toolchain advertises the pragma.

- **Stamping `#define BORINGSSL_PREFIX` at the top of every `.S` file.**
  Assembly files never include `base.h`; they reach the prefix machinery only
  through `asm_base.h`. If the macro is not already defined when the
  assembler preprocesses the file, the assembly exports *unprefixed* symbols
  — and everything still builds and tests green, because the C side would
  then also resolve against them. The failure is invisible until a consumer
  links a second BoringSSL copy. This is the worst silent-failure mode in the
  whole pipeline, which is also why the injection is assert-checked (stage 9).

## 6. Stripping `BN_print`/`BN_print_fp` from `crypto/bn/convert.cc`

**What it does:** deletes two functions (and one `#include`) from the one
upstream file the vendor otherwise ships verbatim.

**Why it is needed:** upstream's `convert.cc` provides `BN_bn2dec`/
`BN_dec2bn`/`BN_bn2hex`/`BN_hex2bn` — which `BigNum.swift` uses — but the
same file also defines `BN_print(BIO *, …)`, which drags in the whole
`crypto/bio/` subsystem for a formatter no Swift API exposes. Cutting the two
functions removes an entire directory from the closure. The old vendor
shipped `bio.c`/`file.c` precisely because of this coupling; the new pipeline
removes the coupling instead of paying for it. The deletion is done by
pattern with post-condition asserts, and is recorded as a provenance patch
(stage 12), so the deviation from upstream is explicit and reviewable rather
than buried.

## 7. Header renaming and include rewriting, now with a hard post-check

**What it does:** the same `openssl/bn.h` → `CBigNumBoringSSL_bn.h` renaming
the old script did, extended to the new file types (`.cc`, `.cc.inc`,
`.inc`), and followed by a tree-wide grep that **fails the run** if any
`#include <openssl/…>` survives.

**Why it is needed:** the renaming itself is a SwiftPM constraint carried
over from the old script — Clang modules built by SwiftPM need globally
unique header names so this package can coexist with any other OpenSSL/
BoringSSL-derived package in one build graph. What is new is the coverage
(the old sed only rewrote `.c`/`.h`/`.cc`/`.S`; the fragment files upstream
introduced would have been missed) and the terminal check: a missed rewrite
previously produced a "file not found" error only for whichever include
happened to be compiled on your machine, and nothing at all for
platform-gated code paths compiled only elsewhere.

## 8. Generating `bn_unity.cc` to replace upstream's `bcm.cc`

**What it does:** writes a small unity translation unit that `#include`s only
the `.cc.inc` fragments the BIGNUM closure needs (BN, AES core for the DRBG,
CTR-DRBG, jitter entropy, SHA-256/512) and inlines the two non-FIPS
service-indicator stubs.

**Why it is needed:** this is the stage forced most directly by upstream.
The FIPS module's sources are no longer standalone compilation units — they
are fragments designed to be textually included into one translation unit
(`bcm.cc`) so the FIPS integrity check can hash a single contiguous `.text`
section. There are only three options:

1. **Compile the fragments individually** — impossible; they are not written
   to stand alone (shared statics, include-order dependencies, no headers).
2. **Vendor `bcm.cc` as-is** — it includes ~90 fragments spanning AES, EC,
   RSA, ML-KEM, ML-DSA, ECDSA, HMAC, self-check KATs, and more, which
   quadruples the vendored surface and defeats this package's reason to
   exist (a small BIGNUM-only library).
3. **Write a trimmed unity TU** — keep upstream's compilation model (one TU,
   same include mechanics, same non-FIPS `#ifdef` behavior) while including
   only the needed fragments.

Option 3 is the only one that preserves both correctness and the cutdown
design. The stubs are needed because `service_indicator.cc.inc`
unconditionally includes headers from subsystems we do not ship, while in
non-FIPS builds it contributes exactly two trivial functions — inlining those
two functions is cheaper and safer than shipping the subsystems.

## 9. Post-condition assertions after every textual edit

**What it does:** every `sed`/`perl` surgery (prefix injection, NO_ASM gate,
`BN_print` strip, include rewrites) is immediately followed by an
`assert_contains`/`assert_absent` that fails the vendor run if the edit did
not land.

**Why it is needed:** the pipeline edits upstream files by pattern, and
upstream reformats code routinely (a 2026 upstream commit literally ran
spelling/grammar fixes across all comments). A pattern that stops matching
does not error — `sed` exits 0 having changed nothing. Most such misses
produce compile errors eventually, but the dangerous ones do not: as noted in
stage 5, a missed prefix injection yields a tree that **builds and passes
every test** with unprefixed symbols, shipping a latent symbol-collision bug
to consumers. The old script had exactly zero checks of this kind. Asserts
convert "silently wrong" into "loudly broken at vendor time", which is the
only time a human is watching.

## 10. Copying pregenerated `err_data.cc` (deleting the Go generation step)

**What it does:** copies `gen/crypto/err_data.cc` instead of running
`go run err_data_generate.go`.

**Why it is needed:** upstream now checks the generated error-string table
into the tree, and the generator moved into the `util/pregenerate` flow. With
this and stages 3 and 5, the Go toolchain — and with it the last
platform-specific prerequisite of the old script — drops out of the vendor
process entirely. Re-vendoring now needs git, GNU sed, and perl, and runs the
same on a Linux CI box as on a maintainer's Mac. That matters because the
harder a vendor run is to execute, the longer the tree goes stale (the
previous snapshot sat untouched for four and a half years).

## 11. Generating the umbrella header and `module.modulemap`

**What it does:** writes `CBigNumBoringSSL.h` (umbrella) and an explicit
Clang module map instead of relying on hand-maintained copies.

**Why it is needed:** the umbrella's contents are a function of the closure —
the old hand-written umbrella included `cipher.h` and `cpu.h`, which the
trimmed closure no longer ships as real headers. Anything derived from the
allowlist must be generated *from* the allowlist, or the two drift apart the
first time the list changes. Same reasoning as stage 2: the source of truth
must be single and executable.

## 12. Per-file provenance patches + `PROVENANCE.txt`

**What it does:** for every vendored file, records the upstream path it came
from; for every file that differs from upstream (renamed includes, injected
defines, the `BN_print` strip, generated files), writes a reversible `.patch`
under `Sources/CBigNumBoringSSL/provenance/`.

**Why it is needed:** this is cryptographic code, and "trust me, it's
BoringSSL" is not a review standard. A re-vendor lands as a 60,000+ line diff
that no human reviews line by line; the realistic threats are (a) an honest
mistake in the pipeline's textual surgery, (b) an accidental local edit that
never makes it back into the script and is silently lost or silently kept,
and (c) tampering. Per-file patches shrink "what differs from audited
upstream code" from 60k lines to a few hundred reviewable lines of *known,
intentional* deltas. They also make the tree independently re-derivable:
anyone can take the pinned upstream revision, apply the recorded transforms,
and confirm byte-identity — without trusting either the vendor script or the
person who ran it.

## 13. `MANIFEST.sha256` over the whole tree

**What it does:** records a SHA-256 for every file in
`Sources/CBigNumBoringSSL/`, and the verifier additionally requires that
*every file present is listed* (not just that listed files match).

**Why it is needed:** `sha256sum -c` alone has a hole: it verifies the files
in the manifest and says nothing about files that were *added* to the tree
after the manifest was written. An injected extra `.cc` file would compile
into the library while passing verification. Requiring manifest-completeness
(and rejecting non-`.patch` files under `provenance/`) closes both directions
of drift: nothing removed or modified (hash check), nothing smuggled in
(completeness check). These two holes were found and closed during review of
the branch itself — they are not hypothetical.

## 14. The CI `verify-provenance` job

**What it does:** on every pull request, clones upstream bloblessly and runs
`scripts/verify-provenance.sh`, re-deriving the vendored tree and checking it
against the manifest and provenance records.

**Why it is needed:** stages 12–13 are only worth anything if they are
*enforced*. Without a CI gate, a well-meaning "quick fix" committed directly
into `Sources/CBigNumBoringSSL/` passes review, diverges the tree from its
provenance records, and turns every subsequent re-vendor into an unwitting
revert of that fix. The CI job makes the invariant structural: the vendored
tree changes only via the vendor script, or not at all.

## 15. Multi-architecture `swift test` as the closure check

**What it does:** treats a passing `swift test` on each supported
OS/architecture — not `swift build` — as the acceptance criterion for the
vendored closure.

**Why it is needed:** the package builds as a *static library*, and static
libraries link with unresolved symbols; only linking a final executable (the
test runner) resolves them. Worse, the unresolved set is
architecture-dependent because of the preprocessor-guarded assembly: this
exact failure happened on the branch, where dropping
`rdrand-x86_64-{apple,linux}.S` was invisible on arm64 (where the guard
compiles the reference away) and only surfaced as a link failure of
`swift test` on Intel. A hand-trimmed closure (stage 8) is only sound if the
link is exercised everywhere the guards can select different code.

## 16. The `upstream-watch` scheduled workflow

**What it does:** monthly, diffs upstream `main` against the pinned revision
*restricted to the vendored paths* (derived from `PROVENANCE.txt`), and fails
loudly if anything changed.

**Why it is needed:** the single biggest defect in the old process was not
technical but organizational: nothing ever demanded an update, so the
vendored snapshot froze for four and a half years — through security-relevant
upstream fixes to code this package ships. A failing scheduled job is a
forcing function with the right scope: it does not fire on the thousands of
upstream commits to TLS, X.509, or ML-KEM code we do not vendor, only on
commits that touch files we actually ship. Deriving the watched set from
`PROVENANCE.txt` (rather than a hand-kept directory list, which the first
draft used and got wrong) means the watchdog's coverage automatically tracks
the allowlist. As of this writing the check would already fire — 49 upstream
commits since the branch's pin touch vendored paths — which is the mechanism
working as designed.

---

## The shape of the whole

Seen together, the stages fall into three groups:

- **Stages forced by upstream** (1–3, 5, 8, 10): BoringSSL moved to C++17,
  unity-compiled FIPS fragments, pregenerated assembly/error tables, and a
  first-class prefixing mechanism, while deleting the tools the old script
  depended on. These stages are not improvements; they are the only way to
  vendor current BoringSSL at all.
- **Stages forced by SwiftPM and Swift** (4, 7, 11, and the two sub-steps of
  5): no nasm, globally unique header names, module maps, and a Clang
  importer that must see macro-renamed declarations.
- **Stages forced by failure modes** (6, 9, 12–16): every one of these
  corresponds to a failure that either already happened in this repository
  (four-year staleness, the silent `Package.swift` stamp, the rdrand
  link break, the manifest holes) or fails silently by construction
  (unprefixed symbols). They are the difference between a vendor script and
  a vendoring *process* that stays correct when nobody is looking.
