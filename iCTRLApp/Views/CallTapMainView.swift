// CallTap modification, 2026. Licensed under Apache-2.0.
import SwiftUI

struct CallTapMainView: View {
    @State private var showMount = false
    #if CALLTAP_RAWAX
    @StateObject private var monitor = CallTapRawAXMonitor()

    var body: some View {
        List {
            Section {
                Label("녹음 자동 시작 실험판", systemImage: "waveform")
                Text("기본 통화 화면의 더 보기와 통화 녹음 항목을 순서대로 누릅니다. 녹음과 저장은 아이폰의 기본 기능이 처리합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("실행 준비") {
                Button("페어링 파일 · 개발자 디스크 설정") { showMount = true }
                Text("LocalDevVPN 연결과 개발자 디스크 준비를 마친 뒤 자동 시작을 켜세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("자동 시작") {
                Label(monitor.isRunning ? "켜짐" : "꺼짐",
                      systemImage: monitor.isRunning ? "checkmark.circle.fill" : "pause.circle")
                Text(monitor.status)
                    .font(.footnote)
                Button(monitor.isPreparing ? "연결 확인 중…" : "자동 시작 켜기") {
                    Task { await monitor.start() }
                }
                .disabled(monitor.isRunning || monitor.isPreparing)
                Button("자동 시작 끄기", role: .destructive) { monitor.stop() }
                    .disabled(!monitor.isRunning && !monitor.isPreparing)
            }
            Section("첫 확인") {
                Text("잠금을 해제한 상태에서 통화를 연결하고 기본 통화 화면을 열어 두세요. 녹음 시작 요청 후 실제 녹음 타이머와 저장 결과를 확인하세요.")
                Text("이 실험판은 iOS가 허용한 백그라운드 실행 시간 안에서만 감시합니다. 시간이 끝나면 중지되며 앱에서 다시 켜야 합니다.")
                    .foregroundStyle(.secondary)
            }
            Section("안내음") {
                Text("안내음은 iOS와 기존 AirBeep 설정을 따릅니다. CallTap은 안내음 파일을 변경하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("CallTap 1.1")
        .sheet(isPresented: $showMount) { DDIMountView() }
    }
    #else
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
    #endif
}
