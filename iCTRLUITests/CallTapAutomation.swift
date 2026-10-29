// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Original CallTap automation, using the enclosing Apache-2.0 iCTRL runner's
// XCTest bootstrap and exception wrappers. No third-party recorder code used.
// This controls native call UI; it never captures or exports call audio.

import Foundation
import CallKit
import XCTest
import UIKit
import UserNotifications

/// Experimental native-call button automation. The aliases below are cautious
/// candidates, NOT labels verified on an iPhone running iOS 27.0. Unknown UI
/// fails closed and can be diagnosed from filtered button labels.
final class CallTapAutomation: NSObject, CXCallObserverDelegate, UNUserNotificationCenterDelegate {
    private struct Button {
        let label: String
        let key: String
        let selected: Bool
        let value: String?
    }
    private enum RecordingState: Equatable {
        case recording
        case notRecording
        case unknown
    }
    private enum TapOutcome {
        case sent
        case ambiguous
        case notAttempted
    }

    private static let pauseID = "CALLTAP_PAUSE"
    private static let resumeID = "CALLTAP_RESUME"
    private static let stopID = "CALLTAP_STOP"
    private static let diagnoseID = "CALLTAP_DIAGNOSE"
    private static let enabledCategory = "CALLTAP_ENABLED"
    private static let pausedCategory = "CALLTAP_PAUSED"
    private static let notificationID = "calltap.status"
    private static let allowedBundles: Set<String> = ["com.apple.mobilephone", "com.apple.InCallService"]

    // Exact matches only. In particular, the broad words "Record" / "녹음"
    // alone are deliberately excluded; they can also denote unrelated UI.
    private static let startLabels = normalizedSet([
        "Call Recording", "Record Call", "Start Call Recording", "Start Recording",
        "통화 녹음", "통화 녹음 시작", "녹음 시작"
    ])
    private static let stopLabels = normalizedSet([
        "Stop Recording", "Stop Call Recording", "End Recording",
        "통화 녹음 중지", "통화 녹음 종료", "녹음 중지", "녹음 종료"
    ])
    private static let recordingTexts = ["Recording", "Recording in Progress", "녹음 중", "통화 녹음 중"]
    private static let activeValues = normalizedSet(["1", "on", "selected", "recording", "녹음 중", "켜짐", "선택됨"])
    private static let inactiveValues = normalizedSet(["", "0", "off", "not selected", "꺼짐", "선택 안 됨"])
    private static let endLabels = CallTapCallUI.endLabels
    private static let callControlLabels = CallTapCallUI.controlLabels
    private static let moreLabels = CallTapCallUI.moreLabels
    private static let diagnosticLabels = startLabels.union(stopLabels)
        .union(endLabels).union(callControlLabels).union(moreLabels)

    private let logger: (String) -> Void
    private let prepareForBackground: (() -> Void)?
    private let observer = CXCallObserver()
    private let center = UNUserNotificationCenter.current()
    private weak var previousDelegate: UNUserNotificationCenterDelegate?
    private var policy = CallTapPolicy()
    private var enabled = false
    private var controlsAvailable = false
    private var isInspecting = false
    private var timer: Timer?
    private var hasOpenedMore: Set<UUID> = []
    private var verifiedCallUI: Set<UUID> = []
    private var diagnosedCalls: Set<UUID> = []
    private var lastWaitingReason: String?
    private var lastDecision: CallTapPolicy.Decision?
    private let runningLock = NSLock()
    private var running = false

    init(logger: @escaping (String) -> Void, prepareForBackground: (() -> Void)? = nil) {
        self.logger = logger
        self.prepareForBackground = prepareForBackground
        super.init()
    }

    /// Blocks the calling test's run loop until the notification's Stop action.
    /// All CallKit/UI state stays on main, even if XCTest invokes us off-main.
    /// No network listener, remote controller, audio capture, or unlock is used.
    func run() {
        runningLock.lock()
        running = true
        runningLock.unlock()
        onMainSync { self.begin() }
        while isRunning {
            autoreleasepool {
                let handled = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.75))
                // XCTest may invoke us on a thread without run-loop sources.
                // Do not burn CPU while CallKit and notifications run on main.
                if !handled { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        onMainSync { self.finish() }
    }

    private var isRunning: Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return running
    }

    private func onMainSync(_ work: () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private func begin() {
        previousDelegate = center.delegate
        center.delegate = self
        configureCategories()
        observer.setDelegate(self, queue: .main)
        logger("CallTap 실험 모드 시작. iOS 27.0의 실제 녹음 버튼 이름은 아직 검증되지 않았습니다.")
        logger("진단에는 알려진 통화 제어 버튼 이름과 미분류 버튼 수만 사용합니다. 음성과 화면 이미지를 수집하지 않습니다.")
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.controlsAvailable = granted
                self.enabled = granted
                if !granted {
                    self.logger("알림 권한이 없어 일시정지했습니다. 설정에서 알림을 허용한 뒤 러너를 다시 실행하세요.")
                }
                self.postStatus(granted ? "연결된 단일 통화에서 녹음 시작 버튼을 찾습니다." : "알림 권한 필요: 자동 시작 일시정지")
                self.prepareForBackground?()
                let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.evaluate() }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .default)
                self.evaluate() // Include a call already connected at startup.
            }
        }
    }

    private func finish() {
        enabled = false
        timer?.invalidate()
        timer = nil
        observer.setDelegate(nil, queue: nil)
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.delegate = previousDelegate
        logger("CallTap 중지. 진행 중인 기본 통화녹음의 종료·저장은 iOS가 처리합니다.")
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        evaluate()
    }

    private func callStates() -> [CallTapCallState] {
        observer.calls.map {
            CallTapCallState(id: $0.uuid, hasConnected: $0.hasConnected,
                             hasEnded: $0.hasEnded, isOnHold: $0.isOnHold)
        }
    }

    private func evaluate() {
        guard isRunning, !isInspecting else { return }
        let calls = callStates()
        let activeIDs = Set(calls.filter { !$0.hasEnded }.map(\.id))
        hasOpenedMore.formIntersection(activeIDs)
        verifiedCallUI.formIntersection(activeIDs)
        diagnosedCalls.formIntersection(activeIDs)
        let decision = policy.decision(calls: calls, enabled: enabled,
                                       now: ProcessInfo.processInfo.systemUptime)
        let changed = decision != lastDecision
        lastDecision = decision
        switch decision {
        case .inspect(let id):
            isInspecting = true
            defer { isInspecting = false }
            inspect(id)
        case .expired:
            logger("녹음 버튼 준비 대기 한도에 도달했습니다. 이 통화에서는 더 누르지 않습니다.")
            postStatus("이번 통화의 시작 버튼을 확인하지 못했습니다. 자동 재시도 종료.")
        case .multipleCalls where changed:
            logger("대기·보류 통화를 포함해 활성 통화가 여럿이어서 건너뜁니다.")
        case .held where changed:
            logger("보류된 통화에서는 녹음을 시작하지 않습니다.")
        case .noCall where changed:
            lastWaitingReason = nil
        default:
            break
        }
    }

    private func inspect(_ id: UUID) {
        guard enabled, !LockStateMonitor.shared().isLocked else {
            waiting("화면이 잠겨 있어 버튼을 누르지 않습니다. 자동 잠금 해제는 하지 않습니다.")
            return
        }
        guard let bundleID = allowedForegroundBundle() else {
            waiting("허용된 기본 통화 화면이 앞에 없어 기다립니다.")
            return
        }
        let app = XCUIApplication(bundleIdentifier: bundleID) // Read only: never activate/launch.
        guard let buttons = readButtons(app) else {
            waiting("통화 화면 버튼을 안전하게 읽지 못했습니다.")
            return
        }
        if !diagnosedCalls.contains(id) {
            diagnosedCalls.insert(id)
            logButtonLabels(buttons)
        }
        switch recordingState(app, buttons: buttons) {
        case .recording:
            policy.markAlreadyRecording(id)
            logger("이미 녹음 중인 표시를 발견했습니다. 녹음 버튼을 누르지 않습니다.")
            postStatus("기본 통화 화면에서 녹음 중인 표시 확인.")
            return
        case .unknown:
            waiting("녹음 진행 상태를 안전하게 읽지 못해 버튼을 누르지 않습니다.")
            return
        case .notRecording:
            break
        }
        let controlsVisible = CallTapCallUI.recognizes(buttonLabels: buttons.map(\.label))
        if controlsVisible { verifiedCallUI.insert(id) }
        guard verifiedCallUI.contains(id) else {
            waiting("기본 통화 화면의 제어 버튼 조합을 확인하지 못해 누르지 않습니다.")
            return
        }

        let starts = buttons.filter { Self.startLabels.contains($0.key) }
        if starts.count == 1 {
            // Revalidate call state, foreground owner, lock and recording state
            // immediately before reserving the ONE permitted start invocation.
            guard enabled, !LockStateMonitor.shared().isLocked,
                  allowedForegroundBundle() == bundleID,
                  let freshButtons = readButtons(app),
                  recordingState(app, buttons: freshButtons) == .notRecording else { return }
            let freshStarts = freshButtons.filter { Self.startLabels.contains($0.key) }
            guard freshStarts.count == 1, let target = freshStarts.first else { return }
            let outcome = invokeExactButton(label: target.label, in: app,
                                            bundleID: bundleID, callID: id, isStart: true)
            switch outcome {
            case .sent:
                logger("녹음 시작 버튼 탭을 한 번 보냈습니다. 실제 녹음·저장 성공은 별도 확인이 필요합니다.")
                postStatus("시작 버튼 탭 전송. 실제 녹음·저장은 직접 확인하세요.")
            case .ambiguous:
                logger("시작 버튼 탭 결과가 불확실합니다. 중복 탭으로 녹음을 중지할 수 있어 재시도하지 않습니다.")
                postStatus("시작 탭 결과 미확인. 이 통화에는 다시 누르지 않습니다.")
            case .notAttempted:
                waiting("버튼 상태가 바뀌어 탭하지 않았습니다. 준비 한도 안에서 다시 확인합니다.")
            }
            return
        }
        if starts.count > 1 {
            waiting("녹음 시작 후보가 여러 개여서 누르지 않습니다.")
            return
        }
        let more = buttons.filter { Self.moreLabels.contains($0.key) }
        if controlsVisible, !hasOpenedMore.contains(id), more.count == 1, let target = more.first {
            guard enabled, !LockStateMonitor.shared().isLocked,
                  allowedForegroundBundle() == bundleID,
                  isSameSingleConnectedCall(id),
                  let freshButtons = readButtons(app),
                  CallTapCallUI.recognizes(buttonLabels: freshButtons.map(\.label)),
                  recordingState(app, buttons: freshButtons) == .notRecording else { return }
            let outcome = invokeExactButton(label: target.label, in: app,
                                            bundleID: bundleID, callID: id, isStart: false)
            switch outcome {
            case .sent:
                logger("확인된 통화 화면의 더 보기 버튼을 한 번 눌렀습니다.")
            case .ambiguous:
                logger("더 보기 탭 결과가 불확실해 같은 메뉴 버튼을 다시 누르지 않습니다.")
            case .notAttempted:
                waiting("더 보기 버튼 상태가 바뀌어 탭하지 않았습니다.")
            }
            return
        }
        waiting("일치하는 녹음 시작 버튼이 없습니다. iOS 27.0의 버튼 이름을 진단으로 확인해야 합니다.")
    }

    private func isSameSingleConnectedCall(_ id: UUID) -> Bool {
        let active = callStates().filter { !$0.hasEnded }
        return active.count == 1 && active[0].id == id
            && active[0].hasConnected && !active[0].isOnHold
    }

    /// Resolve by an exact label predicate, never by a cached button index.
    /// A stale index can point at Stop/End Call after the call UI changes.
    /// The predicate remains part of XCTest's query when tap resolves it again.
    private func invokeExactButton(label: String, in app: XCUIApplication,
                                   bundleID: String, callID: UUID, isStart: Bool) -> TapOutcome {
        var attempted = false
        let reason = ObjCException.catching {
            let query = app.buttons.matching(NSPredicate(format: "label == %@", label))
            guard query.count == 1 else { return }
            let element = query.firstMatch
            guard element.exists, element.isHittable,
                  self.enabled, !LockStateMonitor.shared().isLocked,
                  self.allowedForegroundBundle() == bundleID,
                  self.isSameSingleConnectedCall(callID) else { return }
            if isStart {
                guard Self.startLabels.contains(Self.normalize(label)),
                      !element.isSelected,
                      Self.isInactiveValue(element.value),
                      self.policy.reserveStart(for: callID, calls: self.callStates()) else { return }
            } else {
                guard Self.moreLabels.contains(Self.normalize(label)),
                      !self.hasOpenedMore.contains(callID) else { return }
                self.hasOpenedMore.insert(callID)
            }
            attempted = true // Reserve even if tap raises after dispatching input.
            element.tap()
        }
        if attempted { return reason == nil ? .sent : .ambiguous }
        return .notAttempted
    }

    private func allowedForegroundBundle() -> String? {
        if let current = ForegroundApp.currentBundleID() {
            return Self.allowedBundles.contains(current) ? current : nil
        }
        // Xcode 27 may be unable to map the frontmost PID to a bundle id.
        // Only accept exactly one allowlisted app reported as foreground.
        let front = Self.allowedBundles.filter { ForegroundApp.appState(forBundleID: $0) == 4 }
        return front.count == 1 ? front.first : nil
    }

    private func readButtons(_ app: XCUIApplication) -> [Button]? {
        var result: [Button] = []
        let reason = ObjCException.catching {
            for element in app.buttons.allElementsBoundByIndex.prefix(80) {
                guard element.exists, element.isHittable else { continue }
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                result.append(Button(label: label, key: Self.normalize(label),
                                     selected: element.isSelected,
                                     value: element.value.map { String(describing: $0) }))
            }
        }
        // Never log exception text: XCTest can embed personal UI text in it.
        return reason == nil ? result : nil
    }

    private func recordingState(_ app: XCUIApplication, buttons: [Button]) -> RecordingState {
        if buttons.contains(where: { Self.stopLabels.contains($0.key) }) { return .recording }
        // Some accessibility toggles keep their original label while changing
        // selected/value. Never interpret such an active toggle as a new Start.
        let startButtons = buttons.filter { Self.startLabels.contains($0.key) }
        if startButtons.contains(where: { button in
            button.selected || button.value.map { Self.activeValues.contains(Self.normalize($0)) } == true
        }) { return .recording }
        if startButtons.contains(where: { !Self.isInactiveValue($0.value) }) { return .unknown }
        var found = false
        let reason = ObjCException.catching {
            let predicate = NSPredicate(format: "label IN %@", Self.recordingTexts as NSArray)
            let indicator = app.staticTexts.matching(predicate).firstMatch
            found = indicator.exists && indicator.isHittable
        }
        // A read failure must not allow a start tap or claim successful recording.
        if reason != nil { return .unknown }
        return found ? .recording : .notRecording
    }

    private func waiting(_ message: String) {
        guard message != lastWaitingReason else { return }
        lastWaitingReason = message
        logger(message)
    }

    private static func normalize(_ text: String) -> String {
        CallTapCallUI.normalize(text)
    }

    private static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.map { normalize($0) })
    }

    private static func isInactiveValue(_ value: Any?) -> Bool {
        guard let value = value else { return true }
        return inactiveValues.contains(normalize(String(describing: value)))
    }

    private func logButtonLabels(_ buttons: [Button]) {
        // A button can be labelled with a caller's name or phone number. Only
        // emit known control aliases; unknown labels are counted, never stored.
        let known = buttons.filter { Self.diagnosticLabels.contains($0.key) }
        let labels = Set(known.map(\.key)).sorted()
        let unknownCount = buttons.count - known.count
        logger("알려진 제어 버튼: " + (labels.isEmpty ? "없음" : labels.joined(separator: " | "))
               + " · 이름을 기록하지 않은 버튼 수: \(unknownCount)")
    }

    private func configureCategories() {
        let pause = UNNotificationAction(identifier: Self.pauseID, title: "일시정지", options: [.authenticationRequired])
        let resume = UNNotificationAction(identifier: Self.resumeID, title: "다시 시작", options: [.authenticationRequired])
        let stop = UNNotificationAction(identifier: Self.stopID, title: "러너 중지", options: [.authenticationRequired, .destructive])
        let diagnose = UNNotificationAction(identifier: Self.diagnoseID, title: "버튼 이름 진단", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.enabledCategory, actions: [pause, stop, diagnose], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.pausedCategory, actions: [resume, stop, diagnose], intentIdentifiers: [], options: [])
        ])
    }

    private func postStatus(_ detail: String) {
        guard controlsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = enabled ? "CallTap · 자동 시작 켜짐" : "CallTap · 일시정지"
        content.body = detail + " 알림을 길게 눌러 제어하세요."
        content.categoryIdentifier = enabled ? Self.enabledCategory : Self.pausedCategory
        content.threadIdentifier = "calltap.controls"
        if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
        center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self = self, self.isRunning else { return }
            switch response.actionIdentifier {
            case Self.pauseID:
                self.enabled = false
                _ = self.policy.decision(calls: self.callStates(), enabled: false,
                                         now: ProcessInfo.processInfo.systemUptime)
                self.logger("사용자가 자동 녹음 시작을 일시정지했습니다.")
                self.postStatus("자동 버튼 탭 일시정지. 진행 중인 녹음은 중지하지 않습니다.")
            case Self.resumeID:
                self.enabled = self.controlsAvailable
                self.policy.resume()
                self.logger("사용자가 자동 녹음 시작을 다시 켰습니다.")
                self.postStatus("다음 연결된 단일 통화의 시작 버튼을 찾습니다.")
                self.evaluate()
            case Self.stopID:
                self.enabled = false
                self.runningLock.lock()
                self.running = false
                self.runningLock.unlock()
            case Self.diagnoseID:
                guard !self.isInspecting, !LockStateMonitor.shared().isLocked,
                      let bundle = self.allowedForegroundBundle() else {
                    self.logger("진단 생략: 잠금 해제된 기본 통화 화면이 앞에 있어야 합니다.")
                    return
                }
                let active = self.callStates().filter { !$0.hasEnded }
                guard active.count == 1, active[0].hasConnected,
                      let buttons = self.readButtons(XCUIApplication(bundleIdentifier: bundle)) else {
                    self.logger("진단 생략: 연결된 단일 통화의 버튼을 읽지 못했습니다.")
                    return
                }
                self.logButtonLabels(buttons)
                self.postStatus("알려진 제어 버튼 이름과 미분류 버튼 수를 기기 로그에 남겼습니다.")
            default:
                break
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }
}
