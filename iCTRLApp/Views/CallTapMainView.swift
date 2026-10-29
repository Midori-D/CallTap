// CallTap modification, 2026. Licensed under Apache-2.0.
import SwiftUI

struct CallTapMainView: View {
    @State private var showMount = false
    @State private var launchFailed = false

    var body: some View {
        List {
            Section {
                Label("실기기 검증 전 실험판", systemImage: "wrench.and.screwdriver")
                Text("통화가 연결되고 기본 녹음 버튼이 보이면 자동으로 한 번 누릅니다. iPhone 14 Pro · iOS 27.0에서 버튼 인식 확인이 필요합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("시작") {
                Button("1. 실행 준비") { showMount = true }
                Button("2. CallTap Runner 열기") {
                    guard let url = URL(string: "ictrl://start") else { return }
                    UIApplication.shared.open(url, options: [:]) { ok in
                        if !ok { launchFailed = true }
                    }
                }
                Text("CallTap Runner도 SideStore에 직접 설치해야 합니다. 알림을 허용하고, 실행 중 알림을 길게 눌러 일시정지·재개·종료할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("첫 확인") {
                Text("잠금을 해제하고 통화 화면을 열어 둔 상태에서 먼저 확인하세요. 버튼을 찾지 못하면 화면의 다른 곳을 임의로 누르지 않고 건너뜁니다.")
                Text("재부팅 후에는 실행 준비를 다시 하고 Runner를 열어야 합니다. 앱 서명 갱신도 필요합니다.")
            }
            Section("안내음") {
                Text("안내음은 iOS와 기존 AirBeep 설정을 따릅니다. CallTap은 안내음 파일을 변경하지 않습니다.")
            }
        }
        .navigationTitle("CallTap")
        .sheet(isPresented: $showMount) { DDIMountView() }
        .alert("Runner를 열 수 없습니다", isPresented: $launchFailed) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("CallTap Runner를 SideStore에 직접 설치한 뒤 홈 화면에서 먼저 열어 주세요.")
        }
    }
}
