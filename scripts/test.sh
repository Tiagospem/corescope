#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --manifest-path core/Cargo.toml --check
cargo test --locked --manifest-path core/Cargo.toml
cargo clippy --all-targets --all-features --locked --manifest-path core/Cargo.toml -- -D warnings
mkdir -p build
swiftc -O native/NativeLogic.swift native/TokenUsage.swift tests/native-tests.swift -o build/native-tests
./build/native-tests
