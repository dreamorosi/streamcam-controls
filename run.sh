#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/.build/StreamCam Controls.app"

if pgrep -x StreamCamControls >/dev/null 2>&1; then
    print -u2 "Quit StreamCam Controls from its menu-bar panel before rebuilding."
    exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cargo build --release --locked --manifest-path "$ROOT/backend/Cargo.toml"
cp "$ROOT/backend/target/release/streamcam" "$APP/Contents/MacOS/streamcam"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    "$ROOT/app/StreamCamControls.swift" "$ROOT/app/HelperProcess.swift" -o "$APP/Contents/MacOS/StreamCamControls"
xcrun swiftc "$ROOT/scripts/make-icon.swift" -o "$ROOT/.build/make-icon"
"$ROOT/.build/make-icon" "$ROOT/.build/AppIcon.iconset"
iconutil -c icns "$ROOT/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime "$APP/Contents/MacOS/streamcam"
codesign --force --sign - --options runtime --entitlements "$ROOT/app/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--build-only" ]]; then
    print "Built: $APP"
else
    open "$APP"
    print "StreamCam Controls launched. Click the camera-aperture icon in your menu bar."
fi
