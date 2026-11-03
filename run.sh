#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ "$(uname -m)" != arm64 ]]; then
    print -u2 "Build from a native Apple Silicon shell; Intel/Rosetta builds are not supported."
    exit 1
fi
BUILD_DIR="${STREAMCAM_BUILD_DIR:-$ROOT/.build}"
APP="$BUILD_DIR/StreamCam Controls.app"

python3 "$ROOT/scripts/check-build-target.py" "$APP/Contents/MacOS/StreamCamControls"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cargo build --release --locked --manifest-path "$ROOT/backend/Cargo.toml"
cp "$ROOT/backend/target/release/streamcam" "$APP/Contents/MacOS/streamcam"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
python3 "$ROOT/scripts/third-party-notices.py" "$APP/Contents/Resources/ThirdPartyNotices.txt"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    "$ROOT/app/StreamCamControls.swift" "$ROOT/app/HelperProcess.swift" -o "$APP/Contents/MacOS/StreamCamControls"
xcrun swiftc "$ROOT/scripts/make-icon.swift" -o "$BUILD_DIR/make-icon"
"$BUILD_DIR/make-icon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime "$APP/Contents/MacOS/streamcam"
codesign --force --sign - --options runtime --entitlements "$ROOT/app/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--build-only" ]]; then
    print "Built: $APP"
else
    open "$APP"
    print "StreamCam Controls launched. Click the camera-aperture icon in your menu bar."
fi
