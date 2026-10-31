// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Run with swiftc iCTRLUITests/CallTapPolicy.swift Tests/CallTapPolicy/main.swift -o /tmp/calltap-policy-tests

import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("FAILED: \(message)")
    }
}

let firstID = UUID()
let secondID = UUID()
func call(_ id: UUID = firstID, connected: Bool = true, ended: Bool = false,
          held: Bool = false) -> CallTapCallState {
    CallTapCallState(id: id, hasConnected: connected, hasEnded: ended, isOnHold: held)
}

do {
    var policy = CallTapPolicy()
    check(policy.decision(calls: [], enabled: true, now: 0) == .noCall, "no call")
    check(policy.decision(calls: [call(connected: false)], enabled: true, now: 0) == .connecting,
          "ringing must not start")
    check(!policy.reserveStart(for: firstID, calls: [call(connected: false)]),
          "cannot reserve an unconnected call")
    check(policy.decision(calls: [call()], enabled: true, now: 1) == .inspect(firstID),
          "connected callback starts readiness inspection")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "duplicate callback remains bounded readiness inspection")
    check(policy.reserveStart(for: firstID, calls: [call()]), "first tap reservation")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no second reservation")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .handled(firstID),
          "ambiguous or successful tap is never retried")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "resume cannot grant a second start tap")
}

do {
    var policy = CallTapPolicy()
    check(policy.decision(calls: [call(held: true)], enabled: true, now: 0) == .held,
          "held call")
    check(policy.decision(calls: [call(), call(secondID, connected: false)], enabled: true, now: 0)
          == .multipleCalls, "call waiting blocks start too")
    check(policy.decision(calls: [call(), call(secondID, held: true)], enabled: true, now: 1)
          == .multipleCalls, "held second call still counts")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "single remaining connected call can be inspected")
    check(!policy.reserveStart(for: firstID, calls: [call(), call(secondID)]),
          "revalidate active count immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(held: true)]),
          "revalidate hold immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(ended: true)]),
          "revalidate ended immediately before tap")
    check(!policy.reserveStart(for: secondID, calls: [call()]), "must match UUID")
}

do {
    var policy = CallTapPolicy()
    check(policy.decision(calls: [call()], enabled: false, now: 0) == .paused, "pause")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no inspection while paused")
    _ = policy.decision(calls: [call()], enabled: true, now: 1)
    _ = policy.decision(calls: [call()], enabled: false, now: 1.1)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "pause revokes a pending tap")
    _ = policy.decision(calls: [call()], enabled: true, now: 1.2)
    policy.markAlreadyRecording(firstID)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "manual recording is respected")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .handled(firstID),
          "manual recording stays handled after resume")
    check(policy.decision(calls: [call(ended: true)], enabled: true, now: 3) == .noCall,
          "ended call removed")
    check(policy.completedCalls.isEmpty, "ended UUID pruned")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .inspect(firstID),
          "reused UUID after ended session is new")
    check(policy.reserveStart(for: firstID, calls: [call()]), "new session can reserve")
    _ = policy.decision(calls: [], enabled: false, now: 5)
    check(policy.reservedStarts.isEmpty, "cleanup runs while paused too")
}

do {
    var policy = CallTapPolicy(retryWindow: 2, maximumInspections: 10)
    check(policy.decision(calls: [call()], enabled: true, now: 0) == .inspect(firstID), "window starts")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .expired(firstID), "deadline bound")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "deadline is not reset by another callback")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 5) == .handled(firstID),
          "expired call remains handled until new call")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired never reserves")
}

do {
    var policy = CallTapPolicy(retryWindow: 100, maximumInspections: 2)
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    _ = policy.decision(calls: [call()], enabled: true, now: 0.1)
    check(policy.decision(calls: [call()], enabled: true, now: 0.2) == .expired(firstID),
          "inspection count bound")
}

do {
    check(CallTapCallUI.recognizes(buttonLabels: ["더 보기", "소리 끔", "스피커", "키패드"]),
          "captured iOS 27 Korean call controls work without a recognized end label")
    check(CallTapCallUI.recognizes(buttonLabels: ["more options", " MUTE ", "Audio", "Keypad"]),
          "English controls use the same normalized semantic families")
    check(CallTapCallUI.recognizes(buttonLabels: ["통화 종료", "소리 끔"]),
          "the existing end-call plus control route still works")
    check(!CallTapCallUI.recognizes(buttonLabels: ["더 보기", "키패드"]),
          "a generic More menu and keypad alone are not a call screen")
    check(!CallTapCallUI.recognizes(buttonLabels: ["More", "Mute", "음소거", "Keypad"]),
          "multiple mute aliases cannot replace the missing audio family")
    check(!CallTapCallUI.recognizes(buttonLabels: ["More", "More Options", "Mute", "Speaker", "Keypad"]),
          "an ambiguous More target cannot verify the fallback screen")
    check(!CallTapCallUI.recognizes(buttonLabels: ["Mute", "Speaker", "Keypad"]),
          "the fallback requires the actual More menu too")
    check(!CallTapCallUI.recognizes(buttonLabels: ["Hang Up"]),
          "an end-call label alone is insufficient")
    check(!CallTapCallUI.recognizes(buttonLabels: ["More", "one", "two", "three"]),
          "unknown buttons cannot replace known call controls")
}

do {
    var policy = CallTapPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) == 27.5,
          "a late More request receives eight seconds for menu readiness and confirmation")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 21) == nil,
          "the same menu cannot repeatedly extend its deadline")
    check(policy.decision(calls: [call()], enabled: true, now: 22) == .inspect(firstID),
          "record inspection survives the old twenty-second boundary")
    check(policy.reserveStart(for: firstID, calls: [call()]), "start can be reserved in menu phase")
    policy.resume()
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 23) == nil,
          "rearm cannot reopen the window of a submitted recording start")
    check(policy.decision(calls: [call()], enabled: true, now: 23) == .handled(firstID),
          "rearm never submits a second recording start")
}

do {
    var policy = CallTapPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call(held: true)], now: 1) == nil,
          "held calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: firstID, calls: [call(), call(secondID)], now: 1) == nil,
          "multiple calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: secondID, calls: [call()], now: 1) == nil,
          "menu phase must match the active call")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) != nil,
          "only a valid call enters the menu phase")
    check(policy.decision(calls: [call()], enabled: true, now: 28) == .expired(firstID),
          "menu phase is still bounded")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired menu never starts recording")
    check(policy.decision(calls: [], enabled: true, now: 29) == .noCall,
          "ended calls clear their menu reservations")
    check(policy.decision(calls: [call()], enabled: true, now: 30) == .inspect(firstID),
          "a genuinely new session may reuse an ended UUID")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 30) != nil,
          "the new session can reserve its own menu phase")
}

print("CallTapPolicy: all state-machine, menu-readiness, and call-screen checks passed")
