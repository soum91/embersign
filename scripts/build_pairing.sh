#!/bin/bash
# Compile the MIT-licensed device-initiated remote pairing host for iOS.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TARGET="aarch64-apple-ios"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
rustup target add "$TASK_TARGET"
cd "$TASK_ROOT/pairing-native"
cargo build --release --target "$TASK_TARGET"
mkdir -p "$TASK_ROOT/build/pairing/lib"
cp "target/$TASK_TARGET/release/libembersign_pairing.a" "$TASK_ROOT/build/pairing/lib/"
echo "Built on-device pairing runtime for iOS arm64"
