# CallTap — iOS 27 experimental native call-recording button automation

**Source prototype, not a compiled or device-tested IPA.** Target: iPhone 14 Pro, iOS 27.0, no jailbreak.

[한국어 빌드·설치·검증 안내](CALLTAP-NOTES.md)

CallTap uses a standalone XCTest runner to observe connected calls and try an exact-match native Start Recording button once per call. It does not patch Phone.app or capture privileged call audio. The autonomous mode does not start the upstream HTTP server or screen stream.

Build on macOS with Xcode 27+ and XcodeGen:

```sh
bash Scripts/build-calltap.sh
```

Or run the included manual GitHub Actions workflow after adding the source to your own repository. No workflow has been executed for this prototype yet.

Install the resulting runner **directly in SideStore**, rather than inside LiveContainer. DDI mounting, UI automation authorization, and development-signature renewal are required. Actual iOS 27 call-screen accessibility controls and locked-call behavior remain unverified.

Based on [iCTRL](https://github.com/OpenMinis/iCTRL) at commit `c1e4268859ba858d1579f7b846a56cb40641b7f6` (Apache-2.0). See [original README](README-UPSTREAM.md), [LICENSE](LICENSE), and [NOTICE](NOTICE.md). Added CallTap files and edits are marked in source.