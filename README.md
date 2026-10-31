# CallTap — iOS 27 experimental native call-recording button automation

**CallTap AX 1.1 (experimental):** a normal app uses the device's developer accessibility service instead of a long-running XCTest session. On iPhone 14 Pro / iOS 27.0, a Windows-hosted probe read the call menu and activated the one visible Call Recording control; the user confirmed that the recording timer started with no Automation Running overlay. The new on-device integration is being built and still needs installation testing. It has a finite background execution window, not all-day monitoring.

Use the separate **Build CallTap AX without XCTest** workflow for `CallTap-AX-unsigned.ipa`. It builds only the normal app and tests the pinned Rust protocol extension. See [AX notes](CALLTAP-AX-NOTES.md).

**Experimental IPA; native call-recording activation is still being tested.** Target: iPhone 14 Pro, iOS 27.0, no jailbreak. GitHub Actions builds the installable packages. Device logs confirm Runner startup, connected-call inspection, and the Korean mute/audio/keypad/More controls; the call-screen recognition now accepts that combination without requiring an end-call accessibility label.

[한국어 빌드·설치·검증 안내](CALLTAP-NOTES.md)

CallTap uses a standalone XCTest runner to observe connected calls and try an exact-match native Start Recording button once per call. It does not patch Phone.app or capture privileged call audio. The autonomous mode does not start the upstream HTTP server or screen stream.

Build on macOS with Xcode 27+ and XcodeGen:

```sh
bash Scripts/build-calltap.sh
```

Or run the included manual GitHub Actions workflow. Build success does not establish that native recording started or saved successfully.

Install the resulting runner **directly in SideStore**, rather than inside LiveContainer. DDI mounting, UI automation authorization, and development-signature renewal are required. Actual iOS 27 call-screen accessibility controls and locked-call behavior remain unverified.

Based on [iCTRL](https://github.com/OpenMinis/iCTRL) at commit `c1e4268859ba858d1579f7b846a56cb40641b7f6` (Apache-2.0). See [original README](README-UPSTREAM.md), [LICENSE](LICENSE), and [NOTICE](NOTICE.md). Added CallTap files and edits are marked in source.
