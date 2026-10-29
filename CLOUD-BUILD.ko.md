# Mac 없이 CallTap IPA 빌드하기

확인일: 2026-10-29. 아래는 클라우드에서 컴파일하는 방법입니다. 이 프로젝트의 첫 실제 빌드와 아이폰 통화 검증은 아직 수행하지 않았습니다.

## 추천: GitHub Actions

GitHub가 제공하는 macOS/Xcode 서버에서 프로젝트의 빌드 스크립트를 실행하고 IPA 결과물을 내려받습니다. 이 소스에는 수동 실행 workflow가 이미 포함되어 있습니다. Xcode 27 전용 서버를 사용하도록 설정했습니다.

- [사용 가능한 표준 서버와 Xcode 27](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [공개 저장소의 표준 서버 무료 사용 및 비공개 저장소 과금](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

공개 저장소의 표준 서버 빌드 시간은 무료입니다. 비공개 저장소는 계정에 포함된 사용량과 과금 조건을 따릅니다. 공개 저장소를 선택하면 소스도 공개됩니다. 이 프로젝트의 클라우드 빌드에는 Apple ID, 개발 인증서, 페어링 파일, 아이폰 UDID를 업로드할 필요가 없습니다. 컴파일 결과는 설치 전에 SideStore가 다시 서명합니다.

## Windows 브라우저에서 실행

1. GitHub에 로그인하고 새 저장소를 만듭니다. 무료 표준 서버 사용을 원하고 소스 공개가 괜찮다면 Public을 선택합니다. 그 밖에는 Private을 선택하고 계정의 포함 사용량을 확인합니다.
2. `CallTap-iOS27-source.zip`을 PC에서 압축 해제합니다.
3. 저장소에서 **Add file → Upload files**를 누릅니다. 압축 해제한 **CallTap-iOS27 폴더 안의 내용 전체**를 올립니다. ZIP 파일만 올리거나, CallTap-iOS27 상위 폴더를 통째로 한 단계 아래에 넣으면 빌드 경로가 맞지 않습니다.
4. `.github` 폴더도 반드시 포함합니다. 저장소 루트에서 `.github/workflows/build-calltap.yml`, `project.yml`, `Makefile`, `Scripts/`가 보여야 합니다. GitHub 업로더가 점으로 시작하는 폴더를 누락했다면 **Add file → Create new file**에서 `.github/workflows/build-calltap.yml` 경로를 직접 만들고 원본 workflow 내용을 붙여 넣습니다.
5. 파일을 커밋한 뒤 **Actions → Build CallTap experimental IPA → Run workflow**를 누릅니다. Actions가 비활성화되어 있으면 먼저 저장소에서 활성화합니다. 수동 실행 workflow는 기본 브랜치에 있어야 버튼이 나타납니다.
6. 성공한 실행 화면의 **Artifacts → CallTap-iOS27-experimental**을 내려받아 압축 해제합니다. 현재 설정은 결과물을 7일 보관합니다.
7. `CallTap-Runner-unsigned.ipa`를 최신 SideStore에 직접 설치합니다. `CallTap-Helper-unsigned.ipa`는 DDI 실행 준비용 선택 앱입니다. 상세 설치 조건은 [설치 안내](CALLTAP-NOTES.md)를 확인합니다.

[수동 workflow 실행 안내](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), [결과물 다운로드 안내](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)

첫 컴파일에서 오류가 나면 실패한 단계의 로그를 확인해 수정해야 합니다. 서버에서 컴파일할 수 있다는 사실이 통화 자동 녹음의 실기기 성공을 보장하지는 않습니다. 클라우드 서버는 사용자의 실제 아이폰에 연결해 통화를 검증하지 않습니다.

## 다른 선택지

| 서비스 | 확인한 기능 | 이번 프로젝트에 대한 판단 |
|---|---|---|
| GitHub Actions | macOS/Xcode 서버, 수동 빌드, 결과물 다운로드 | 기존 workflow를 그대로 쓸 수 있어 첫 선택 |
| Codemagic | 네이티브 iOS 빌드, 사용자 스크립트, 개인 계정 macOS M2 월 500분 무료 | 기존 빌드 스크립트를 실행하도록 별도 YAML 구성이 필요 |
| Bitrise | iOS `build-for-testing` 전용 단계 | XCTest 프로젝트를 다룰 수 있지만 현재 사용자 빌드 스크립트와 패키징을 추가 설정해야 함 |

[Codemagic 개인 계정 요금](https://docs.codemagic.io/billing/pricing/), [네이티브 iOS 빌드](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/), [Bitrise 테스트용 빌드](https://docs.bitrise.io/en/bitrise-ci/testing/testing-ios-apps/building-an-ios-app-for-testing)

Codemagic·Bitrise에서 이 프로젝트를 실제로 실행해 본 것은 아닙니다. 일반 앱 아카이브 기능만 사용하면 독립 XCTest 러너 패키징 요구를 충족하지 못할 수 있으므로, 포함된 `Scripts/build-calltap.sh`와 중첩 `.xctest` 서명·패키징 구조를 유지해야 합니다.
