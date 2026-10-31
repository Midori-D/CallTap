// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_DIRECT
import Foundation
import IDevice

enum CallTapDirectEndpoint: String, CaseIterable, Sendable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"
    var title: String { self == .ipv4 ? "내부 연결 IPv4" : "내부 연결 IPv6" }
}

final class CallTapConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct CallTapDirectProbeReport: Sendable {
    let endpoint: CallTapDirectEndpoint?
    let attempts: [String]
    var detail: String { attempts.joined(separator: "\n") }
}

struct CallTapDirectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All FFI handles are created, used, and freed on the invoking worker.
/// There is deliberately no VPN address, profile API, or pairing-setup fallback.
enum CallTapDirectTransport {
    static func withConnection<T>(pairingPath: String, endpoint: CallTapDirectEndpoint,
                                  body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
        var pairing: OpaquePointer?
        try check("페어링 파일 읽기") { rp_pairing_file_read(pairingPath, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }
        guard let pairing else { throw CallTapDirectError(message: "페어링 파일 핸들이 없습니다.") }
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        try check("직접 연결 인증") {
            calltap_direct_connect(endpoint.rawValue, pairing, &adapter, &handshake)
        }
        guard let adapter, let handshake else {
            throw CallTapDirectError(message: "직접 연결 핸들이 없습니다.")
        }
        return try body(adapter, handshake)
    }

    /// A successful port connect is insufficient: require RP authentication,
    /// dynamic TLS tunnel, RSD, DVT, and a read-only AX snapshot end to end.
    static func probe(pairingPath: String, shouldContinue: () -> Bool,
                      report: (String) -> Void) -> CallTapDirectProbeReport {
        var attempts: [String] = []
        for endpoint in CallTapDirectEndpoint.allCases {
            guard shouldContinue() else { break }
            report("\(endpoint.title): 인증과 접근성 연결을 확인하고 있습니다.")
            do {
                try withConnection(pairingPath: pairingPath, endpoint: endpoint) { adapter, handshake in
                    guard shouldContinue() else { throw CallTapDirectError(message: "연결 검사를 취소했습니다.") }
                    try check("접근성 읽기 검사") { calltap_ax_probe(adapter, handshake) }
                }
                guard shouldContinue() else { break }
                attempts.append("\(endpoint.title): 인증 · 개발자 서비스 · 접근성 읽기 성공")
                return CallTapDirectProbeReport(endpoint: endpoint, attempts: attempts)
            } catch {
                attempts.append("\(endpoint.title): \(error.localizedDescription)")
            }
        }
        return CallTapDirectProbeReport(endpoint: nil, attempts: attempts)
    }

    private static func check(_ operation: String,
                              _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error = call() else { return }
        let code = error.pointee.code
        let raw = error.pointee.message.map { String(cString: $0) } ?? ""
        idevice_error_free(error)
        // Our Rust entry points replace remote exceptions with fixed stages.
        for prefix in ["CallTap Direct:", "CallTap AX: probe"] {
            if let range = raw.range(of: prefix) {
                throw CallTapDirectError(message: String(raw[range.lowerBound...].prefix(180)))
            }
        }
        throw CallTapDirectError(message: "\(operation) 실패 (코드 \(code))")
    }
}
#endif
