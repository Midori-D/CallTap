// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Original CallTap decision policy. Contains no audio capture or system hooks.

import Foundation

/// Button evidence only; callers must also verify the native foreground app,
/// one connected call, and an unlocked screen before using this result.
enum CallTapCallUI {
    static let endLabels = normalizedSet(["End Call", "Hang Up", "통화 종료", "전화 끊기"])
    static let moreLabels = normalizedSet(["More", "More Options", "더 보기", "더보기"])
    private static let controlFamilies = [
        normalizedSet(["Mute", "음소거", "소리 끔"]),
        normalizedSet(["Keypad", "키패드"]),
        normalizedSet(["Speaker", "Audio", "스피커", "오디오"])
    ]
    static let controlLabels = controlFamilies.reduce(into: Set<String>()) { $0.formUnion($1) }

    static func recognizes(buttonLabels: [String]) -> Bool {
        let labels = buttonLabels.map(normalize)
        let keys = Set(labels)
        if !keys.isDisjoint(with: endLabels), !keys.isDisjoint(with: controlLabels) {
            return true
        }
        // iPhone 14 Pro / iOS 27.0 exposes mute, keypad, audio, and More while
        // its end-call button does not match our known accessibility aliases.
        // Require every semantic family; translated synonyms are not extra proof.
        return controlFamilies.allSatisfy { !keys.isDisjoint(with: $0) }
            && labels.filter { moreLabels.contains($0) }.count == 1
    }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.map(normalize))
    }
}

struct CallTapCallState {
    let id: UUID
    let hasConnected: Bool
    let hasEnded: Bool
    let isOnHold: Bool
}

/// Pure state machine, separated from CallKit and XCTest for executable tests.
struct CallTapPolicy {
    enum Decision: Equatable {
        case paused
        case noCall
        case multipleCalls
        case connecting
        case held
        case handled(UUID)
        case inspect(UUID)
        case expired(UUID)
    }

    private struct Window {
        var deadline: TimeInterval
        var inspections = 0
    }

    let retryWindow: TimeInterval
    let maximumInspections: Int
    private var windows: [UUID: Window] = [:]
    private var isEnabled = false
    private(set) var reservedStarts: Set<UUID> = []
    private(set) var completedCalls: Set<UUID> = []
    private var menuWindows: Set<UUID> = []

    init(retryWindow: TimeInterval = 20, maximumInspections: Int = 24) {
        self.retryWindow = max(0, retryWindow)
        self.maximumInspections = max(1, maximumInspections)
    }

    mutating func decision(calls: [CallTapCallState], enabled: Bool,
                           now: TimeInterval) -> Decision {
        let active = calls.filter { !$0.hasEnded }
        let ids = Set(active.map(\.id))
        // Completed/ended sessions must not leave stale state behind. A future
        // genuinely new session may reuse a UUID after it has disappeared.
        windows = windows.filter { ids.contains($0.key) }
        reservedStarts.formIntersection(ids)
        completedCalls.formIntersection(ids)
        menuWindows.formIntersection(ids)
        isEnabled = enabled
        guard enabled else { return .paused }
        guard !active.isEmpty else { return .noCall }
        guard active.count == 1 else { return .multipleCalls }
        let call = active[0]
        guard call.hasConnected else { return .connecting }
        guard !call.isOnHold else { return .held }
        guard !completedCalls.contains(call.id), !reservedStarts.contains(call.id) else {
            return .handled(call.id)
        }

        var window = windows[call.id] ?? Window(deadline: now + retryWindow)
        guard now <= window.deadline, window.inspections < maximumInspections else {
            windows.removeValue(forKey: call.id)
            completedCalls.insert(call.id)
            return .expired(call.id)
        }
        window.inspections += 1
        windows[call.id] = window
        return .inspect(call.id)
    }

    /// Give an already-validated More request one bounded menu-readiness phase.
    /// Repeated requests or rearming cannot extend this same call again.
    mutating func reserveMenuWindow(for id: UUID, calls: [CallTapCallState],
                                    now: TimeInterval) -> TimeInterval? {
        let active = calls.filter { !$0.hasEnded }
        guard isEnabled, active.count == 1, let call = active.first, call.id == id,
              call.hasConnected, !call.isOnHold, now.isFinite,
              !reservedStarts.contains(id), !completedCalls.contains(id), !menuWindows.contains(id),
              var window = windows[id], now <= window.deadline else { return nil }
        menuWindows.insert(id)
        window.deadline = max(window.deadline, now + 8)
        window.inspections = 0
        windows[id] = window
        return window.deadline
    }

    /// Reserve BEFORE invoking XCTest. A thrown/ambiguous tap is still spent:
    /// retrying it could turn a successful start into an accidental stop.
    mutating func reserveStart(for id: UUID, calls: [CallTapCallState]) -> Bool {
        let active = calls.filter { !$0.hasEnded }
        guard isEnabled, active.count == 1, let call = active.first, call.id == id,
              call.hasConnected, !call.isOnHold,
              windows[id] != nil,
              !reservedStarts.contains(id), !completedCalls.contains(id) else {
            return false
        }
        reservedStarts.insert(id)
        completedCalls.insert(id)
        windows.removeValue(forKey: id)
        return true
    }

    mutating func markAlreadyRecording(_ id: UUID) {
        completedCalls.insert(id)
        windows.removeValue(forKey: id)
    }

    /// Explicit Resume resets a still-pending readiness window. Handled,
    /// reserved, and expired calls stay completed until the session ends;
    /// Resume never grants those calls another start tap or readiness window.
    mutating func resume() {
        windows.removeAll()
    }
}
