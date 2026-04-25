#!/usr/bin/env pwsh
# Windows / cross-platform PowerShell equivalent of build-rust.sh.
# Builds the Rust FFI library that the Swift `BigNum` target links against.
# Must be run before `swift build` / `swift test` on Windows.
#
# On Windows the resulting archive is rust\target\release\big_num_rustcrypto.lib
# (vs. libbig_num_rustcrypto.a on Unix). SwiftPM's `.linkedLibrary(...)`
# resolves the per-platform name automatically.

$ErrorActionPreference = 'Stop'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo not found. Install Rust via https://rustup.rs/'
    exit 1
}

$pkgRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $pkgRoot 'rust')
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $stem = if ($IsWindows) { 'big_num_rustcrypto.lib' } else { 'libbig_num_rustcrypto.a' }
    $artifact = Join-Path (Get-Location) (Join-Path 'target\release' $stem)
    Write-Host "Built $artifact"
} finally {
    Pop-Location
}
