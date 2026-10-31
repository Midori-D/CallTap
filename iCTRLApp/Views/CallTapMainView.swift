// CallTap modification, 2026. Licensed under Apache-2.0.
import SwiftUI

struct CallTapMainView: View {
    @State private var showMount = false
    #if CALLTAP_RAWAX
    @StateObject private var monitor = CallTapRawAXMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                Label("통화 녹음 자동 시작", systemImage: "waveform")
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
                Label(monitor.isRunning ? "감시 중" : (monitor.isEnabled ? "사용 · 재개 대기" : "꺼짐"),
                      systemImage: monitor.isRunning ? "checkmark.circle.fill" : "pause.circle")
                Text(monitor.status)
                    .font(.footnote)
                Button(monitor.isPreparing ? "연결 확인 중…" : (monitor.isEnabled ? "연결 다시 확인" : "자동 시작 켜기")) {
                    Task { await monitor.start() }
                }
                .disabled(monitor.isRunning || monitor.isPreparing)
                Button("자동 시작 끄기", role: .destructive) { monitor.stop() }
                    .disabled(!monitor.isEnabled && !monitor.isPreparing)
            }
            Section("단축어 자동화") {
                if ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil {
                    Text("현재 LiveContainer 안에서 실행 중입니다. 아래 단축어 동작은 SideStore 독립 설치 후 검증해야 합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("SideStore 독립 설치 후, 단축어의 ‘전화 앱이 열릴 때’ 자동화에서 ‘VPN 연결’ 다음에 AirRecord의 ‘통화 감시 재개’를 추가하세요.")
                    .font(.footnote)
                Text("앱에서 자동 시작을 한 번 켜 두어야 합니다. 이 동작은 짧은 감시 시간을 다시 준비하며, 전화 수신 자체를 감지하는 자동화는 아닙니다. LiveContainer 내부 설치에서는 단축어 동작이 등록되지 않을 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("‘통화 감시 재개’ 완료는 녹음 시작 확인이 아닙니다. 이 동작 바로 다음이나 ‘전화 앱이 닫힐 때’에 VPN 끄기를 붙이지 마세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("첫 확인") {
                Text("잠금을 해제한 상태에서 통화를 연결하고 기본 통화 화면을 열어 두세요. 녹음 시작 요청 후 실제 녹음 타이머와 저장 결과를 확인하세요.")
                Text("자동 시작 설정은 직접 끌 때까지 유지됩니다. iOS가 백그라운드 실행을 중단하면 감시는 일시 정지되며, 앱으로 돌아오면 연결을 확인하고 자동 재개합니다.")
                    .foregroundStyle(.secondary)
            }
            Section("안내음") {
                Text("안내음은 iOS와 기존 AirBeep 설정을 따릅니다. AirRecord는 안내음 파일을 변경하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("최근 상태") {
                DisclosureGroup("감시 기록 보기") {
                    Text(monitor.diagnosticSummary)
                        .font(.caption)
                        .textSelection(.enabled)
                    ShareLink("상태 기록 공유", item: monitor.diagnosticSummary)
                }
            }
        }
        .navigationTitle("AirRecord 1.1.3")
        .sheet(isPresented: $showMount) { DDIMountView() }
        .task { await monitor.resumeIfEnabled() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await monitor.resumeIfEnabled() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.resumeIfEnabled() }
        }
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
