#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash Scripts/build-idevice-rawax.sh
bash Tests/CallTapPolicy/run.sh
xcodegen generate --quiet
xcodebuild build -project iCTRL.xcodeproj -scheme CallTapRawAX -configuration Release \
  -derivedDataPath build/rawax-ios -destination 'generic/platform=iOS' ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='CALLTAP_AUTOMATION CALLTAP_RAWAX' \
  MARKETING_VERSION=1.1.2 CURRENT_PROJECT_VERSION=6
APP="$ROOT/build/rawax-ios/Build/Products/Release-iphoneos/iCTRL.app"
[[ -d "$APP" ]] || { echo "App bundle missing" >&2; exit 1; }
# This target must remain a normal app with no XCTest dependency or test plugin.
if find "$APP" -name '*.xctest' -print -quit | grep -q .; then exit 1; fi
if otool -L "$APP/iCTRL" | grep -E 'XCTest|XCUIAutomation'; then exit 1; fi
find "$APP" -type f \( -name '*.dylib' -o -name '*.debug.dylib' \) -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p release build/rawax-payload/Payload
cp -R "$APP" build/rawax-payload/Payload/
(cd build/rawax-payload && zip -qr "$ROOT/release/CallTap-AX-unsigned.ipa" Payload)
python3 Scripts/verify-calltap-ax-ipa.py release/CallTap-AX-unsigned.ipa
echo 'AirRecord 1.1.2 build 6 packaged; VPN-based 1.1.2 behavior restored.'
