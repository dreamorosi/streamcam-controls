#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/.build"
cargo fmt --check --manifest-path "$ROOT/backend/Cargo.toml"
cargo clippy --locked --all-targets --manifest-path "$ROOT/backend/Cargo.toml" -- -D warnings
cargo test --locked --manifest-path "$ROOT/backend/Cargo.toml"
xcrun swiftc -swift-version 5 -parse-as-library -D TESTING \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    "$ROOT/app/StreamCamControls.swift" "$ROOT/app/HelperProcess.swift" \
    "$ROOT/tests/AppTests.swift" -o "$ROOT/.build/app-tests"
"$ROOT/.build/app-tests"
python3 -m unittest discover -s tests -p 'test_release_tools.py'
