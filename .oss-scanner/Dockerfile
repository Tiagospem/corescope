# Image for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner): the checkout of CoreScope, its Rust
# core built in the dev profile, and every crate it needs, so the audit can run offline.
#
# CoreScope runs only on macOS, and this image is Linux. Two parts cannot be built here:
#   - core/src/macos.c, the C adapter over libproc, sysctl, Mach and IOKit. On Linux, core/build.rs compiles stubs
#     generated from core/src/macos.h instead, which report every OS query as unavailable. The C source stays in /src
#     for review, but nothing here runs it.
#   - native/, the SwiftUI app (AppKit, SwiftUI, UserNotifications, ServiceManagement). It is source only here.
# Everything else in core/ builds and runs: the Docker Engine API client and its HTTP/JSON parsing, the history store
# over the system libsqlite3, the FFI entry points (cs_*), and the logic that decides which processes may be signalled.
# Tests that need a real macOS process table fail here, and that is expected. threat_model.md, next to this file, says
# what matters and how to exercise it.

# Latest stable Rust, as CI uses (the crate is edition 2024).
FROM rust:1-trixie
ENV DEBIAN_FRONTEND=noninteractive
# libsqlite3-dev: core/src/sqlite.rs binds the system libsqlite3 directly, with no bundled engine.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN rustup component add rustfmt clippy

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src/core

ENV RUST_BACKTRACE=1 \
    CARGO_TERM_COLOR=never

# Every crate in Cargo.lock, for every target, so later builds stay offline.
RUN cargo fetch --locked

# The library, the examples and every test binary, in the dev profile (debug assertions and overflow checks on).
# A step that fails fails the build.
RUN cargo build --locked --all-targets

# Run the tests so the log shows the image works, without letting the macOS-only ones abort the build.
RUN timeout 600 cargo test --locked --no-fail-fast -- --test-threads=1 \
    || echo "WARNING: cargo test reported failures (tests that read the macOS process table cannot pass on Linux)"

# Everything is fetched. From here on cargo must not try to reach a registry.
ENV CARGO_NET_OFFLINE=true
