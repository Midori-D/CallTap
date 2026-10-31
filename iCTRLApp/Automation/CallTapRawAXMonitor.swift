// Copyright 2026 CallTap contributors. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import CallKit
import Darwin
import Foundation
import UIKit

/// Reads the existing lock state; this never unlocks, synthesizes input, or
/// starts XCTest. A registration/read failure is treated as locked.
private final class CallTapRawAXLockState: @unchecked Sendable {
    private let token: Int32

    init() {
        var value: Int32 = -1
        let result = notify_register_check("com.apple.springboard.lockstate", &value)
        token = result == 0 ? value : -1
    }

    var isUnlocked: Bool {
        guard token >= 0 else { return false }
        var state = UInt64.max
        return notify_get_state(token, &state) == 0 && state == 0
    }

    deinit {
        if token >= 0 { _ = notify_cancel(token) }
    }
}

/// The worker's synchronous callbacks access only this locked state. CallKit
/// snapshots are updated on the main actor; UIKit is never read on the worker.
private final class CallTapRawAXGate: @unchecked Sendable {
    struct Inspection {
        let generation: UInt64
        let callID: UUID
        let mayOpenMore: Bool
    }

    private let lock = NSLock()
    private let lockState = CallTapRawAXLockState()
    private var enabled = false
    private var generation: UInt64 = 0
    private var calls: [CallTapCallState] = []
    private var policy = CallTapPolicy()
    private var moreReservations: Set<UUID> = []
    private var deadlines: [UUID: TimeInterval] = [:]

    func update(_ calls: [CallTapCallState]) {
        lock.lock()
        defer { lock.unlock() }
        self.calls = calls
        let active = Set(calls.filter { !$0.hasEnded }.map(\.id))
        moreReservations.formIntersection(active)
        deadlines = deadlines.filter { active.contains($0.key) }
    }

    func start() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        enabled = true
        policy.resume()
        deadlines.removeAll()
        return generation
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
        generation &+= 1
    }

    func decision() -> (CallTapPolicy.Decision, Inspection?) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let decision = policy.decision(calls: calls, enabled: enabled, now: now)
        guard case .inspect(let id) = decision else { return (decision, nil) }
        if deadlines[id] == nil { deadlines[id] = now + 20 }
        return (decision, Inspection(generation: generation, callID: id,
                                     mayOpenMore: !moreReservations.contains(id)))
    }

    private func permitsLocked(_ inspection: Inspection) -> Bool {
        let active = calls.filter { !$0.hasEnded }
        return enabled && generation == inspection.generation
            && active.count == 1 && active[0].id == inspection.callID
            && active[0].hasConnected && !active[0].isOnHold
            && deadlines[inspection.callID].map { ProcessInfo.processInfo.systemUptime <= $0 } == true
            && lockState.isUnlocked
    }

    func permits(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return permitsLocked(inspection)
    }

    func reserveMore(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection), !moreReservations.contains(inspection.callID) else { return false }
        // Reservation remains spent even if the subsequent request is ambiguous.
        moreReservations.insert(inspection.callID)
        return true
    }

    func reserveStart(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection) else { return false }
        return policy.reserveStart(for: inspection.callID, calls: calls)
    }

    func isCurrent(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && generation == inspection.generation
    }

    func startWasReserved(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.reservedStarts.contains(inspection.callID)
    }

    func markAlreadyRecording(_ inspection: Inspection) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, generation == inspection.generation else { return }
        policy.markAlreadyRecording(inspection.callID)
    }
}

@MainActor
final class CallTapRawAXMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var status = "자동 시작이 꺼져 있습니다."

    private let observer = CXCallObserver()
    private let gate = CallTapRawAXGate()
    private var timer: Timer?
    private var workerIsRunning = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var preparationID = UUID()
    private let defaults: UserDefaults
    private static let enabledKey = "CallTap.RawAX.autoStartEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        super.init()
        if isEnabled { status = "자동 시작 설정이 유지되어 있습니다. 연결을 확인하면 재개합니다." }
    }

    func start() async {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        await prepare()
    }

    func resumeIfEnabled() async {
        guard isEnabled, UIApplication.shared.applicationState == .active else { return }
        await prepare()
    }

    private func prepare() async {
        guard isEnabled, !isRunning, !isPreparing else { return }
        isPreparing = true
        let request = UUID()
        preparationID = request
        setStatus("페어링 파일과 기기 연결을 확인하고 있습니다.")
        guard PairingFileStore.exists else {
            isPreparing = false
            setStatus("실행 준비에서 페어링 파일을 먼저 가져오세요.")
            return
        }

        let probe = await LocalDevVPN.probeTunnel()
        guard preparationID == request, isPreparing else { return }
        switch probe {
        case .reachable: break
        case .localNetworkDenied:
            isPreparing = false
            setStatus("설정에서 CallTap의 로컬 네트워크 접근을 허용하세요.")
            return
        case .unreachable:
            isPreparing = false
            setStatus("LocalDevVPN을 연결한 뒤 다시 시작하세요.")
            return
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CallTap Raw AX") { [weak self] in
            // UIKit invokes expiration on the main actor. End its assertion
            // synchronously, and never let an old expiration pause a new run.
            guard let self, self.preparationID == request else { return }
            self.pause(message: "자동 시작 설정은 켜져 있습니다. iOS가 감시를 일시 중단했으며 앱으로 돌아오면 자동 재개합니다.")
            if UIApplication.shared.applicationState == .active {
                Task { await self.resumeIfEnabled() }
            }
        }
        guard backgroundTask != .invalid else {
            isPreparing = false
            setStatus("백그라운드 실행 시간을 받지 못했습니다. 잠시 후 다시 켜 주세요.")
            return
        }

        observer.setDelegate(self, queue: .main)
        updateCalls()
        _ = gate.start()
        isPreparing = false
        isRunning = true
        setStatus("통화 연결을 기다립니다. 백그라운드 허용 시간 안에서 동작합니다.")
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        evaluate()
    }

    func stop() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        pause(message: "자동 시작을 껐습니다. 이미 시작된 기본 녹음은 통화 화면에서 중지할 수 있습니다.")
    }

    private func pause(message: String) {
        preparationID = UUID()
        gate.stop() // Invalidates worker callbacks before touching UI/task state.
        isRunning = false
        isPreparing = false
        timer?.invalidate()
        timer = nil
        observer.setDelegate(nil, queue: nil)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        setStatus(message)
        // Never join a blocking network worker on the main actor. Its callbacks
        // now refuse input, and the client's bounded operation closes normally.
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.evaluate() }
    }

    private func updateCalls() {
        gate.update(observer.calls.map {
            CallTapCallState(id: $0.uuid, hasConnected: $0.hasConnected,
                             hasEnded: $0.hasEnded, isOnHold: $0.isOnHold)
        })
    }

    private func evaluate() {
        guard isRunning else { return }
        updateCalls()
        guard !workerIsRunning else { return }
        let (decision, inspection) = gate.decision()
        switch decision {
        case .inspect:
            guard let inspection else { return }
            guard gate.permits(inspection) else {
                setStatus("잠금을 해제하고 기본 통화 화면을 열어 두세요.")
                return
            }
            inspect(inspection)
        case .expired:
            setStatus("이번 통화의 준비 시간이 끝났습니다. 자동으로 다시 누르지 않습니다.")
        case .multipleCalls:
            setStatus("활성 통화가 여럿이어서 자동 시작을 건너뜁니다.")
        case .held:
            setStatus("보류 중인 통화에서는 자동 시작하지 않습니다.")
        case .connecting:
            setStatus("통화가 연결되기를 기다립니다.")
        case .noCall:
            setStatus("통화 연결을 기다립니다. 백그라운드 허용 시간 안에서 동작합니다.")
        default: break
        }
    }

    private func inspect(_ inspection: CallTapRawAXGate.Inspection) {
        workerIsRunning = true
        let gate = self.gate
        let pairingPath = PairingFileStore.storedURL.path
        // At most one worker exists, including across stop/start. A dedicated
        // thread avoids the small Swift concurrency worker stack used by FFI.
        let thread = Thread { [weak self] in
            let result: Result<CallTapRawAXOutcome, Error>
            do {
                result = .success(try CallTapRawAXClient.inspectAndAct(
                    pairingPath: pairingPath, mayOpenMore: inspection.mayOpenMore,
                    shouldContinue: { gate.permits(inspection) },
                    reserveMore: { gate.reserveMore(inspection) },
                    reserveStart: { gate.reserveStart(inspection) }))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self?.didInspect(result, inspection: inspection)
            }
        }
        thread.name = "calltap.rawax.inspect"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func didInspect(_ result: Result<CallTapRawAXOutcome, Error>,
                            inspection: CallTapRawAXGate.Inspection) {
        workerIsRunning = false
        guard gate.isCurrent(inspection), isRunning else {
            if isRunning { evaluate() }
            return
        }
        switch result {
        case .success(.waiting(let detail)):
            setStatus(detail)
        case .success(.openedMore):
            setStatus("더 보기를 열었습니다. 보이는 통화 녹음 항목을 확인합니다.")
        case .success(.startSubmitted):
            setStatus("녹음 시작 요청을 한 번 보냈습니다. 통화 화면의 녹음 타이머를 확인하세요.")
        case .success(.alreadyRecording):
            gate.markAlreadyRecording(inspection)
            setStatus("이미 녹음 중이어서 자동 시작을 건너뛰었습니다.")
        case .failure:
            // Never emit native exception text: it can contain private UI text.
            if gate.startWasReserved(inspection) {
                setStatus("녹음 시작 요청의 결과를 확인하지 못했습니다. 이번 통화에는 다시 누르지 않습니다.")
            } else {
                setStatus("통화 화면 검사에 실패했습니다. 준비 시간 안에서 다시 확인합니다.")
            }
        }
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
        ictrlLog("CallTap RawAX 1.1: \(value)")
    }
}
#endif
