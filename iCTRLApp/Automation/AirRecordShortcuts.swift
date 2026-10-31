// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import AppIntents
import Foundation

private struct AirRecordShortcutError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resumes the user's existing auto-start choice from a Shortcuts automation.
/// Kept in the main app process so it shares the UI's observer and reservations.
struct ResumeAirRecordMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "통화 감시 재개"
    static var description: IntentDescription = "LocalDevVPN 연결 후 AirRecord의 켜져 있는 자동 시작 설정을 재개합니다. 자동 시작이 꺼져 있으면 변경하지 않습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try Task.checkCancellation()
        let monitor = CallTapRawAXMonitor.shared
        let ready = await monitor.resumeFromShortcut()
        try Task.checkCancellation()
        guard ready else {
            throw AirRecordShortcutError(message: monitor.status)
        }
        return .result(value: "통화 감시 준비 완료")
    }
}

struct AirRecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeAirRecordMonitoringIntent(),
            phrases: ["\(.applicationName) 통화 감시 재개"],
            shortTitle: "통화 감시 재개",
            systemImageName: "waveform"
        )
    }
}
#endif
