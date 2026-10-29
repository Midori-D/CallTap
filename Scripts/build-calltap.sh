#!/usr/bin/env bash
# CallTap modification, 2026. Licensed under Apache-2.0.
set -euo pipefail
CALLTAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$CALLTAP_ROOT"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "CallTap requires macOS and Xcode 27 or newer to build an iOS IPA." >&2
    exit 2
fi
command -v xcodegen >/dev/null || {
    echo "Install XcodeGen first: brew install xcodegen" >&2
    exit 2
}
CALLTAP_SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
if (( ${CALLTAP_SDK%%.*} < 27 )); then
    echo "iPhoneOS SDK $CALLTAP_SDK is selected. Select Xcode 27 or newer first." >&2
    exit 2
fi

# ZIP extraction on Windows may lose executable bits. Restore only this
# project's own scripts; no signing credentials or device secrets are needed.
chmod +x Scripts/*.sh
if [[ -f Tests/CallTapPolicy/run.sh ]]; then
    bash Tests/CallTapPolicy/run.sh
fi
make ipa UNSIGNED=1
cp release/iCTRLUITests-Runner.ipa release/CallTap-Runner-unsigned.ipa
cp release/iCTRL.ipa release/CallTap-Helper-unsigned.ipa
python3 Scripts/verify-calltap-ipa.py release/CallTap-Runner-unsigned.ipa
echo "Build complete. Install CallTap-Runner-unsigned.ipa directly with SideStore."
