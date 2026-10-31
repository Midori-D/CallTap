// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import Darwin
import Foundation
import IDevice

enum CallTapRawAXOutcome {
    case waiting(String)
    case openedMore
    case startSubmitted
    case alreadyRecording
}
private struct CallTapRawAXError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private final class CallTapRawAXCallbacks {
    let permitted: () -> Bool
    let more: () -> Bool
    let start: () -> Bool
    init(_ permitted: @escaping () -> Bool, _ more: @escaping () -> Bool,
         _ start: @escaping () -> Bool) {
        self.permitted = permitted; self.more = more; self.start = start
    }
}
enum CallTapRawAXClient {
    private static let callback: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Bool = { context, action in
        guard let context else { return false }
        let callbacks = Unmanaged<CallTapRawAXCallbacks>.fromOpaque(context).takeUnretainedValue()
        switch action {
        case 0: return callbacks.permitted()
        case 1: return callbacks.permitted() && callbacks.more()
        case 2: return callbacks.permitted() && callbacks.start()
        default: return false
        }
    }
    /// Handles remain on the invoking dedicated worker for their entire lifetime.
    static func inspectAndAct(pairingPath: String, directHost: String? = nil, mayOpenMore: Bool,
                              shouldContinue: @escaping () -> Bool,
                              reserveMore: @escaping () -> Bool,
                              reserveStart: @escaping () -> Bool) throws -> CallTapRawAXOutcome {
        guard shouldContinue() else { return .waiting("현재 통화 상태를 다시 확인합니다.") }
        #if CALLTAP_DIRECT
        guard let directHost, let endpoint = CallTapDirectEndpoint(rawValue: directHost) else {
            throw CallTapRawAXError(message: "직접 연결 검사를 먼저 완료하세요.")
        }
        return try CallTapDirectTransport.withConnection(pairingPath: pairingPath, endpoint: endpoint) { adapter, handshake in
            try inspect(adapter: adapter, handshake: handshake, mayOpenMore: mayOpenMore,
                        shouldContinue: shouldContinue, reserveMore: reserveMore, reserveStart: reserveStart)
        }
        #else
        DDIMounter.primeCryptoProvider()
        var pairing: OpaquePointer?
        try check("페어링 파일 읽기") { rp_pairing_file_read(pairingPath, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(49152).bigEndian
        guard "10.7.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw CallTapRawAXError(message: "LocalDevVPN 주소를 확인할 수 없습니다.")
        }
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { socket in
                try check("기기 개발자 연결") {
                    tunnel_create_rppairing(socket, idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                                            "CallTap Raw AX", pairing, nil, nil, &adapter, &handshake)
                }
            }
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        guard let adapter, let handshake else {
            throw CallTapRawAXError(message: "개발자 연결 핸들을 만들지 못했습니다.")
        }
        return try inspect(adapter: adapter, handshake: handshake, mayOpenMore: mayOpenMore,
                           shouldContinue: shouldContinue, reserveMore: reserveMore, reserveStart: reserveStart)
        #endif
    }

    private static func inspect(adapter: OpaquePointer, handshake: OpaquePointer, mayOpenMore: Bool,
                                shouldContinue: @escaping () -> Bool,
                                reserveMore: @escaping () -> Bool,
                                reserveStart: @escaping () -> Bool) throws -> CallTapRawAXOutcome {
        let callbacks = CallTapRawAXCallbacks(shouldContinue, reserveMore, reserveStart)
        var outcome: UInt32 = 0
        try withExtendedLifetime(callbacks) {
            try check("통화 화면 접근성 검사") {
                calltap_ax_inspect(adapter, handshake, mayOpenMore, callback,
                                   Unmanaged.passUnretained(callbacks).toOpaque(), &outcome)
            }
        }
        switch outcome {
        case 0: return .waiting("잠금을 해제하고 기본 통화 화면을 열어 두세요.")
        case 1: return .openedMore
        case 2: return .startSubmitted
        case 3: return .alreadyRecording
        default: throw CallTapRawAXError(message: "알 수 없는 접근성 검사 결과입니다.")
        }
    }
    private static func check(_ operation: String,
                              _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error = call() else { return }
        let code = error.pointee.code
        let raw = error.pointee.message.map { String(cString: $0) } ?? ""
        idevice_error_free(error)
        // Only our fixed protocol labels may reach app status; never remote UI text.
        if let range = raw.range(of: "CallTap AX:") {
            throw CallTapRawAXError(message: String(raw[range.lowerBound...].prefix(180)))
        }
        #if CALLTAP_DIRECT
        throw CallTapRawAXError(message: "\(operation) 실패 (코드 \(code)). 직접 연결 검사와 개발자 디스크 상태를 확인하세요.")
        #else
        throw CallTapRawAXError(message: "\(operation) 실패 (코드 \(code)). VPN·개발자 디스크를 확인하세요.")
        #endif
    }
}
#endif
