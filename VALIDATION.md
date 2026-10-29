# Validation status — 2026-10-29

**Source prototype. No installable IPA has been built.**

## Checks actually run

- PASS Swift syntax parser: iCTRLUITests/iCTRLUITests.swift
- PASS Swift syntax parser: iCTRLUITests/CallTapAutomation.swift
- PASS Swift syntax parser: iCTRLUITests/CallTapPolicy.swift
- PASS Swift syntax parser: iCTRLApp/iCTRLApp.swift
- PASS Swift syntax parser: iCTRLApp/Views/CallTapMainView.swift
- PASS Swift syntax parser: Tests/CallTapPolicy/main.swift
- PASS YAML parse and autonomous-mode/SDK/workflow settings
- PASS bash syntax: Scripts/build-calltap.sh
- PASS bash syntax: Scripts/package-release.sh
- PASS bash syntax: Scripts/fetch-idevice.sh
- PASS bash syntax: Tests/CallTapPolicy/run.sh
- PASS workflow shell syntax: step 2
- PASS workflow shell syntax: step 3
- PASS workflow shell syntax: step 4
- PASS XML/plist parse for all bundled plist files
- PASS package checker fixtures: valid metadata, mismatched IDs, profile, missing test, old OS

The IPA checker used fabricated ZIP metadata fixtures. Those fixtures are not iOS executables and are not distributed.

## Checks not run

- Swift compiler/type checking and linking with Xcode
- Swift CallTapPolicy executable tests (included; Mac build runs them)
- Real IPA packaging/codesign/install
- iPhone 14 Pro iOS 27.0 native call-screen buttons and recording
- Locked calls, other foreground apps, long-running background reliability

Tree-sitter syntax parsing does not type-check Swift, resolve Apple SDK symbols, or prove that the app compiles. The included policy tests run only when a Mac executes the build script.

Runtime target: iPhone 14 Pro, iOS 27.0. Start-button aliases are unverified candidates; a label mismatch causes a skip.

Upstream source: OpenMinis/iCTRL at c1e4268859ba858d1579f7b846a56cb40641b7f6, Apache-2.0.
