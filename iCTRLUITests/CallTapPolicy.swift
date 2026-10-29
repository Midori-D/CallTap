// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Original CallTap decision policy. Contains no audio capture or system hooks.

import Foundation

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
