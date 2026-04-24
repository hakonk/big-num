FROM swift:6.1 as builder

# Install Rust (required for the crypto-bigint FFI library used by BigNum).
RUN apt-get -qq update \
 && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
 && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --default-toolchain stable --profile minimal

WORKDIR /BigNum
COPY . .
RUN ./scripts/build-rust.sh \
 && swift test
