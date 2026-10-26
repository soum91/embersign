#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_STIKJIT_COMMIT=32287268fa5824f9edce4cb359f5833ce0cf7b00
TASK_SOURCE="$TASK_ROOT/build/stikjit-source"
TASK_PRODUCTS="$TASK_ROOT/build/stikjit-derived/Build/Products/Release-iphoneos"

if [[ ! -d "$TASK_SOURCE/.git" ]]; then
  git init "$TASK_SOURCE"
  git -C "$TASK_SOURCE" remote add origin https://github.com/StikDebug/StikJIT.git
  git -C "$TASK_SOURCE" fetch --depth 1 origin "$TASK_STIKJIT_COMMIT"
  git -C "$TASK_SOURCE" checkout --detach FETCH_HEAD
fi
test "$(git -C "$TASK_SOURCE" rev-parse HEAD)" = "$TASK_STIKJIT_COMMIT"
cp "$TASK_ROOT/jit-integration/EmberTargetLauncher.swift" "$TASK_SOURCE/Sources/EmberTargetLauncher.swift"
(
  cd "$TASK_SOURCE"
  xcodegen generate
  xcodebuild -project StikJIT.xcodeproj -scheme StikJIT -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$TASK_ROOT/build/stikjit-derived" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    GENERATE_INFOPLIST_FILE=YES \
    > "$TASK_ROOT/packages/stikjit-xcodebuild.log" 2>&1 || {
      tail -n 140 "$TASK_ROOT/packages/stikjit-xcodebuild.log"
      exit 1
    }
)
test -d "$TASK_PRODUCTS/StikJIT.framework"
test -f "$TASK_PRODUCTS/StikJIT.framework/Info.plist" || {
  echo 'StikJIT framework lacks Info.plist; refusing to embed an invalid framework.' >&2
  exit 1
}
mkdir -p "$TASK_ROOT/build/stikjit"
cp -R "$TASK_PRODUCTS/StikJIT.framework" "$TASK_ROOT/build/stikjit/"
