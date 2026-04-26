FROM swift:6.1 as builder

# Install Rust (required for the crypto-bigint FFI library used by BigNum).
RUN apt-get -qq update \
 && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
 && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
# Bootstrap rustup with no default toolchain — the actual rustc version
# comes from rust/rust-toolchain.toml on first cargo invocation, so the
# resulting image is reproducible regardless of when it's built.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --default-toolchain none --profile minimal

WORKDIR /BigNum
COPY . .
RUN ./scripts/build-rust.sh \
 && BIGNUM_BUILD_FROM_SOURCE=1 swift test
