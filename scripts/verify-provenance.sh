#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the big-num open source project
##
## Verify the vendored BoringSSL tree against upstream.
##
## For every modified file, the matching provenance/<file>.patch is
## reverse-applied to a copy of the vendored file; the result must be
## byte-identical to the upstream original at the pinned revision. This
## proves the only differences from upstream are the ones recorded in the
## provenance patches — verification never trusts vendor-boringssl-2.sh.
##
## Usage:
##   scripts/verify-provenance.sh                     # clones upstream itself
##   scripts/verify-provenance.sh -p /path/to/clone   # reuse an existing clone
##
## Requires: git, patch, sha256sum, cmp.
##
##===----------------------------------------------------------------------===##

set -euo pipefail

HERE="${HERE:-$(cd "$(dirname "$0")/.." && pwd)}"
DSTROOT="${DSTROOT:-${HERE}/Sources/CBigNumBoringSSL}"

PREEXISTING_CLONE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--path) PREEXISTING_CLONE="$2"; shift 2 ;;
        -h|--help) echo "usage: $0 [-p /path/to/existing/boringssl/clone]"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in git patch sha256sum cmp; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "Need ${tool} on PATH" >&2; exit 43; }
done

PROV="${DSTROOT}/PROVENANCE.txt"
[ -f "${PROV}" ] || { echo "FATAL: ${PROV} not found" >&2; exit 44; }
[ -d "${DSTROOT}/provenance" ] || {
    echo "FATAL: ${DSTROOT}/provenance not found — re-run scripts/vendor-boringssl-2.sh" >&2
    exit 44
}

REV="$(awk '/^# upstream_revision/ {print $NF}' "${PROV}")"
[ -n "${REV}" ] || { echo "FATAL: no upstream_revision in ${PROV}" >&2; exit 44; }
echo "Pinned BoringSSL revision: ${REV}"

TMPCLONE="" ; WORK=""
cleanup() {
    [ -n "${TMPCLONE}" ] && rm -rf "${TMPCLONE}"
    [ -n "${WORK}" ] && rm -rf "${WORK}"
    return 0
}
trap cleanup EXIT
WORK="$(mktemp -d /tmp/big-num-verify.XXXXXX)"

# -----------------------------------------------------------------------------
# Step 1 — local integrity: every vendored file matches MANIFEST.sha256.
# -----------------------------------------------------------------------------
echo
echo "[1/3] Checking MANIFEST.sha256 (local integrity)"
if ( cd "${DSTROOT}" && sha256sum -c MANIFEST.sha256 >/dev/null ); then
    echo "  OK — every file matches its recorded hash"
else
    echo "  FAIL — run 'sha256sum -c MANIFEST.sha256' in ${DSTROOT} for details" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 2 — obtain a pristine upstream checkout at the pinned revision.
# -----------------------------------------------------------------------------
echo
if [ -n "${PREEXISTING_CLONE}" ]; then
    SRCROOT="${PREEXISTING_CLONE}"
    echo "[2/3] Using existing BoringSSL clone at ${SRCROOT}"
else
    TMPCLONE="$(mktemp -d /tmp/big-num-verify-clone.XXXXXX)"
    SRCROOT="${TMPCLONE}/boringssl"
    echo "[2/3] Cloning BoringSSL"
    git clone --quiet https://boringssl.googlesource.com/boringssl "${SRCROOT}"
fi
git -C "${SRCROOT}" fetch --quiet --tags origin 2>/dev/null || true
git -C "${SRCROOT}" checkout --quiet "${REV}"
echo "  upstream checked out at ${REV}"

# -----------------------------------------------------------------------------
# Step 3 — per-file verification.
#
# Modified file:  reverse-apply provenance/<file>.patch to the vendored copy,
#                 then assert the result equals the upstream original.
# verbatim file:  compare vendored to upstream directly.
# generated file: no upstream counterpart — counted, not compared.
# -----------------------------------------------------------------------------
echo
echo "[3/3] Verifying each vendored file against upstream"

pass=0 ; fail=0 ; generated=0 ; verbatim=0
fail_list=""

while IFS=$'\t' read -r vend up xform; do
    case "${vend}" in ''|'#'*) continue ;; esac

    case "${xform}" in
        generated)
            generated=$((generated + 1))
            continue
            ;;
        verbatim)
            if cmp -s "${SRCROOT}/${up}" "${DSTROOT}/${vend}"; then
                verbatim=$((verbatim + 1))
            else
                fail=$((fail + 1))
                fail_list="${fail_list}  ${vend}: marked verbatim but differs from upstream
"
            fi
            continue
            ;;
    esac

    patchfile="${DSTROOT}/provenance/${vend}.patch"
    if [ ! -f "${patchfile}" ]; then
        fail=$((fail + 1))
        fail_list="${fail_list}  ${vend}: no provenance patch
"
        continue
    fi
    if [ ! -f "${SRCROOT}/${up}" ]; then
        fail=$((fail + 1))
        fail_list="${fail_list}  ${vend}: upstream ${up} missing at ${REV}
"
        continue
    fi

    recon="${WORK}/recon"
    rm -f "${recon}" "${recon}.orig" "${recon}.rej"
    cp "${DSTROOT}/${vend}" "${recon}"
    if patch -R -s -f "${recon}" < "${patchfile}" >/dev/null 2>&1 \
       && cmp -s "${recon}" "${SRCROOT}/${up}"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        fail_list="${fail_list}  ${vend}: reverse-applied patch != upstream ${up}
"
    fi
done < "${PROV}"

# Orphan check — every patch must map to a PROVENANCE.txt row.
grep -v '^#' "${PROV}" | cut -f1 | grep -v '^$' > "${WORK}/known.txt" || true
while read -r p; do
    rel="${p#${DSTROOT}/provenance/}"
    rel="${rel%.patch}"
    if ! grep -qxF "${rel}" "${WORK}/known.txt"; then
        fail=$((fail + 1))
        fail_list="${fail_list}  ${rel}: orphan patch (no PROVENANCE.txt row)
"
    fi
done < <(find "${DSTROOT}/provenance" -name '*.patch' -type f | LC_ALL=C sort)

echo
echo "Results:"
echo "  verified  (patch reverts cleanly to upstream): ${pass}"
echo "  verbatim  (byte-identical to upstream):        ${verbatim}"
echo "  generated (no upstream counterpart):           ${generated}"
echo "  failed:                                        ${fail}"

if [ "${fail}" -ne 0 ]; then
    echo
    echo "FAILURES:"
    printf '%s' "${fail_list}"
    echo
    echo "VERIFICATION FAILED"
    exit 1
fi

echo
echo "VERIFICATION PASSED — every vendored file traces back to BoringSSL ${REV}"
