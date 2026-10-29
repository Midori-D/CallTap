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

print("CallTapPolicy: all state-machine checks passed")
