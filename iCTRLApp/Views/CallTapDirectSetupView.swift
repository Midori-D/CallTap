// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_DIRECT
import SwiftUI

/// Setup for the direct-connection experiment. Mounting uses the direct
/// transport selected by DDIMounter; this view never starts or probes a VPN.
struct CallTapDirectSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mounter = DDIMounter()
    @StateObject private var images = DeveloperDiskImageStore()
    @State private var showPairingPicker = false
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var imagesReady = DeveloperDiskImageStore.isComplete
    @State private var pairingError: String?
    @State private var downloadError: String?

    private var canMount: Bool {
        hasPairingFile && imagesReady && !images.isDownloading && !mounter.isRunning
    }

    var body: some View {
        NavigationStack {
            List {
                Section("시작 전") {
                    Text("LocalDevVPN을 포함한 모든 VPN을 끄고, 아이폰의 잠금을 해제해 두세요. 개발자 모드도 켜져 있어야 합니다.")
                    Text("VPN 없이 기기 내부로 직접 연결하는 시험판입니다. 이 기기에서 연결이 허용되는지는 실제 확인이 필요합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("1. 페어링 파일") {
                    Label(hasPairingFile ? "가져오기 완료" : "페어링 파일이 필요합니다",
                          systemImage: hasPairingFile ? "checkmark.circle.fill" : "doc.badge.plus")
                    Button(hasPairingFile ? "페어링 파일 교체" : "페어링 파일 가져오기") {
                        showPairingPicker = true
                    }
                    .disabled(mounter.isRunning)
                    if hasPairingFile {
                        Button("페어링 파일 삭제", role: .destructive) {
                            PairingFileStore.remove()
                            refreshStoredState()
                            pairingError = nil
                        }
                        .disabled(mounter.isRunning)
                    }
                    if let pairingError {
                        Text(pairingError).font(.caption).foregroundStyle(.orange)
                    }
                }

                Section {
                    Label(imagesReady ? "파일 준비 완료" : "파일 다운로드가 필요합니다",
                          systemImage: imagesReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    if images.isDownloading {
                        ProgressView(value: images.progress)
                        Text("다운로드 중 · \(Int(images.progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !imagesReady {
                        Button("개발자 디스크 파일 다운로드") {
                            Task {
                                downloadError = nil
                                do { try await images.download() }
                                catch { downloadError = error.localizedDescription }
                                refreshStoredState()
                            }
                        }
                        .disabled(mounter.isRunning)
                    }
                    if let downloadError {
                        Text(downloadError).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("2. 개발자 디스크 파일")
                } footer: {
                    Text("기존 파일이 있으면 재사용합니다. 다운로드는 인터넷 연결이 필요하며, 기존 설정과 같은 DeveloperDiskImage 미러를 사용합니다.")
                }

                Section {
                    switch mounter.phase {
                    case .idle, .failed:
                        Button("개발자 디스크 마운트") {
                            Task { await mounter.mount() }
                        }
                        .disabled(!canMount)
                    case .connecting, .queryingDevice, .finalizing:
                        HStack {
                            ProgressView()
                            Text(phaseLabel).foregroundStyle(.secondary)
                        }
                    case .uploading(let fraction):
                        ProgressView(value: fraction)
                        Text("업로드 중 · \(Int(fraction * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    case .mounted:
                        Label("마운트 완료", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if case .failed(let message) = mounter.phase {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("3. 개발자 디스크 마운트")
                } footer: {
                    if !hasPairingFile {
                        Text("페어링 파일을 먼저 가져오세요.")
                    } else if !imagesReady {
                        Text("개발자 디스크 파일 다운로드를 완료하세요.")
                    } else {
                        Text("재부팅 후에는 다시 마운트해야 합니다. 완료 후 이 화면을 닫고 직접 연결 검사를 실행하세요.")
                    }
                }
            }
            .navigationTitle("VPN 없는 실행 준비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
            .onAppear { refreshStoredState() }
            .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in
                refreshStoredState()
                pairingError = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshStoredState()
            }
            .fileImporter(isPresented: $showPairingPicker,
                          allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
                do {
                    try PairingFileStore.importFile(from: result.get())
                    refreshStoredState()
                    pairingError = nil
                } catch {
                    pairingError = error.localizedDescription
                }
            }
        }
    }

    private func refreshStoredState() {
        hasPairingFile = PairingFileStore.exists
        imagesReady = DeveloperDiskImageStore.isComplete
    }

    private var phaseLabel: String {
        switch mounter.phase {
        case .connecting: return "기기 내부 직접 연결 확인 중…"
        case .queryingDevice: return "기기 정보 확인 중…"
        case .finalizing: return "마운트 마무리 중…"
        default: return "처리 중…"
        }
    }
}
#endif
