#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_UPSTREAM="${1:-$TASK_ROOT/upstream}"
TASK_BUILD="${GITHUB_RUN_NUMBER:-1}"
mkdir -p "$TASK_ROOT/packages"
cd "$TASK_UPSTREAM"
xcrun swift "$TASK_ROOT/scripts/make_icon.swift" "$TASK_UPSTREAM/Feather/Resources"
bash "$TASK_ROOT/scripts/build_stikjit.sh"
cp "$TASK_ROOT/project.yml" "$TASK_UPSTREAM/EmberSign.project.yml"
# Generate explicit, unique package-product links instead of the inherited duplicates.
xcodegen generate --spec EmberSign.project.yml
make deps
bash "$TASK_ROOT/scripts/build_pairing.sh"
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$TASK_ROOT/build/DerivedData" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$TASK_BUILD" ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
  > "$TASK_ROOT/packages/xcodebuild.log" 2>&1 || {
    tail -n 160 "$TASK_ROOT/packages/xcodebuild.log"
    exit 1
  }
TASK_APP="$TASK_UPSTREAM/_build/Applications/Feather.app"
test -d "$TASK_APP"
mkdir -p "$TASK_ROOT/build/Payload"
cp -R "$TASK_APP" "$TASK_ROOT/build/Payload/EmberSign.app"
cp deps/* "$TASK_ROOT/build/Payload/EmberSign.app/"
TASK_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$TASK_ROOT/upstream.lock.json").$TASK_BUILD"
for TASK_BUNDLE in "$TASK_ROOT/build/Payload/EmberSign.app" "$TASK_ROOT/build/Payload/EmberSign.app/PlugIns/EmberSignWidget.appex"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TASK_BUILD" "$TASK_BUNDLE/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TASK_VERSION" "$TASK_BUNDLE/Info.plist"
done
# Sign copied runtime dependencies before the two bundles; preserve widget entitlements.
find "$TASK_ROOT/build/Payload/EmberSign.app" -type f -name '*.dylib' -exec codesign --force --sign - --timestamp=none {} \;
find "$TASK_ROOT/build/Payload/EmberSign.app" -depth -type d -name '*.framework' -exec codesign --force --sign - --timestamp=none {} \;
codesign --force --sign - --timestamp=none --entitlements "$TASK_UPSTREAM/EmberSignWidget/EmberSignWidget.entitlements" "$TASK_ROOT/build/Payload/EmberSign.app/PlugIns/EmberSignWidget.appex"
codesign --force --sign - --timestamp=none --entitlements "$TASK_UPSTREAM/Feather/Supporting Files/Feather.entitlements" "$TASK_ROOT/build/Payload/EmberSign.app"
cd "$TASK_ROOT/build"
ditto -c -k --keepParent Payload "$TASK_ROOT/packages/EmberSign.ipa"
python3 "$TASK_ROOT/scripts/release_metadata.py"
echo "Packaged EmberSign.ipa (ad-hoc signed; re-sign before installation)."
