# CallTap iOS 27 실험판

대상: iPhone 14 Pro · iOS 27.0 · 비탈옥 · SideStore 직접 설치.

**상태: GitHub Actions에서 IPA 빌드·패키징 성공. 실기기에서 Runner 실행과 연결된 통화의 버튼 읽기까지 확인했으며, 실제 자동 녹음 시작·저장은 추가 검증이 필요합니다.**

2026-10-29 기기 로그에서 `더 보기 · 소리 끔 · 스피커 · 키패드`를 확인했습니다. 종료 버튼의 접근성 이름이 일치하지 않아 진행이 막혔던 문제를 수정했습니다. 기본 통화 앱이 전면이고 잠금 해제된 단일 연결 통화일 때, 음소거·키패드·오디오 세 종류와 유일한 더 보기 버튼을 모두 확인하는 경로를 추가했습니다.

## 동작

별도 XCTest 러너가 공개 CallKit API로 통화 상태를 관찰하고, 연결된 단일 통화의 기본 녹음 시작 버튼을 정확히 찾았을 때 한 번 누릅니다. 기존 iOS 녹음과 저장 기능을 사용합니다. 전화 앱 바이너리나 안내음 파일은 변경하지 않습니다.

실제 iOS 27.0의 접근성 버튼 이름과 식별자는 실기기에서 확인해야 합니다. 코드에 있는 한국어·영어 이름은 첫 실험을 위한 후보이며, 해당 버전에서 확인된 값이 아닙니다. 후보가 일치하지 않으면 동작을 건너뜁니다. 화면 좌표 추측으로 버튼을 누르지 않습니다.

공개 CallKit API는 통화의 소유 앱을 알려 주지 않습니다. 현재 프로토타입은 시스템 통화 화면과 녹음 컨트롤을 추가로 확인합니다. 이를 모든 셀룰러 통화와 VoIP 통화를 완전히 구별하는 필터라고 해석하면 안 됩니다.

## 빌드

Mac에 Xcode 27 이상과 XcodeGen을 설치하고 이 폴더에서 실행합니다.

```sh
bash Scripts/build-calltap.sh
```

컴파일이 성공하면 `release/CallTap-Runner-unsigned.ipa`와 `release/CallTap-Helper-unsigned.ipa`가 생성됩니다. 이름의 unsigned는 개인 개발자 서명 전 배포용이라는 의미이며, 내부 바이너리는 임시 ad-hoc 서명됩니다. SideStore에서 사용자의 개발자 인증서로 다시 서명해야 합니다.

GitHub Actions를 쓰려면 이 폴더를 본인의 저장소 루트로 업로드하고 **Actions → Build CallTap experimental IPA → Run workflow**를 실행합니다. workflow는 수동 실행만 설정되어 있고 Apple ID나 인증서 비밀값을 요구하지 않습니다. Xcode 27 전용 호스팅 러너(`xcode-27`)를 사용하며, iPhoneOS SDK 27 이상이 없으면 빌드 전에 명확히 실패합니다.

Mac 없이 Windows 브라우저로 빌드하는 순서와 서비스 비교는 [클라우드 빌드 안내](CLOUD-BUILD.ko.md)에 있습니다.

## 설치와 첫 실험

1. 최신 SideStore로 **CallTap Runner를 독립 앱으로 직접 설치**합니다. LiveContainer 내부에 넣는 경로는 검증하지 않았습니다. 중첩 `.xctest`까지 서명하는 SideStore 버전이 필요합니다.
2. DDI가 아직 마운트되지 않았다면 CallTap Helper 또는 StikDebug로 마운트합니다. Helper의 실행 준비 화면에서 페어링 파일과 LocalDevVPN을 설정할 수 있습니다. iloader가 이 파생 앱을 자동 인식할 것으로 가정하지 말고, 페어링 파일을 내보내 직접 가져옵니다.
3. Runner를 열고 iOS의 UI 자동화 인증 요청과 알림 허용을 처리합니다.
4. 처음에는 잠금이 해제된 상태에서 통화를 연결하고 통화 화면을 그대로 열어 둡니다. Runner 알림으로 대기 상태와 결과를 확인합니다.
5. 버튼을 찾지 못하면 진단 결과를 바탕으로 코드의 정확한 식별자·레이블 후보를 조정한 뒤 다시 빌드해야 합니다. 통화 상대 번호, 이름, 통화 내용이나 스크린샷을 로그에 추가하지 않습니다.

Runner 실행 이후 앱 알림을 길게 눌러 일시정지·재개·종료합니다. 일시정지/종료는 이후 자동 버튼 누르기를 중단하며, 이미 시작된 기본 녹음을 강제로 종료하지 않습니다.

`Automation Running / Hold both volume buttons to stop`은 iOS/XCTest의 시스템 안내입니다. 양쪽 음량 버튼을 동시에 길게 누르면 UI 자동화를 중지합니다. 자동화를 유지하면서 이 문구만 숨기는 지원된 앱 설정은 확인되지 않았습니다. [Appium 공식 설명](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/#known-problems)

무료 계정의 활성 앱 3개 제한에 유의합니다. 예를 들어 SS+LC, Runner, Helper 또는 StikDebug로 3개를 사용할 수 있습니다. 실제 기기의 다른 독립 설치 앱 수에 따라 자리를 확보해야 합니다.

재부팅 뒤에는 DDI를 다시 마운트하고 Runner를 다시 실행해야 합니다. 개발자 서명 만료 전 SideStore 갱신도 필요합니다. 잠금 상태, 다른 화면에 있는 통화, 통화 대기/병합, 장시간 실행은 검증되지 않았으며 첫 버전의 보장 범위가 아닙니다.

## 조사한 근거

- [TrollRecorder 통화 감지](https://github.com/Lessica/TrollRecorder/blob/main/cli/call-monitor.mm): 공개 `CXCallObserver` 감지 경로를 확인했습니다. CallTap의 코드는 이를 복사하지 않고 공개 API로 별도 구현했습니다.
- [TrollRecorder 녹음 엔진](https://github.com/Lessica/TrollRecorder/blob/main/cli/call-recorder.mm), [권한 선언](https://github.com/Lessica/TrollRecorder/blob/main/cli/call-recorder.plist): 시스템 오디오 탭과 `CanTapTelephony` 등 특권을 사용합니다. SideStore 일반 서명으로 이 녹음 엔진을 실행할 수 있다고 가정하지 않습니다.
- [LiveContainer 한계](https://github.com/LiveContainer/LiveContainer#limitations): 내부 앱 트윅 주입과 시스템 전화 앱 수정은 별개입니다.
- 기반 소스: [iCTRL](https://github.com/OpenMinis/iCTRL/tree/c1e4268859ba858d1579f7b846a56cb40641b7f6), Apache-2.0. 원본 `LICENSE`와 `NOTICE.md`를 보존했습니다. 원본 README는 `README-UPSTREAM.md`에 보존합니다.

CallTap 모드에서는 원본 iCTRL의 HTTP 서버·원격 제어·화면 스트림을 시작하지 않습니다. 원본 코드와 빌드 구조는 호환성을 위해 소스에 보존되어 있습니다.
