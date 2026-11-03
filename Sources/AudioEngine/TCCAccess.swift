import CryptoKit
import Foundation
import Security

/// Private TCC SPI, loaded at runtime. Personal-use app; never distributed.
/// Only two symbols are looked up; the service name is a plain CFString.
public final class TCCAccess: @unchecked Sendable {
    public enum Preflight: Equatable, Sendable {
        case granted, denied, notDetermined, unavailable
    }

    public static let shared = TCCAccess()
    public let available: Bool

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    // The completion block is retained by TCC and called later, so it must be
    // declared escaping; a non-escaping block here traps at runtime.
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private let preflightFn: PreflightFn?
    private let requestFn: RequestFn?
    private let service = "kTCCServiceAudioCapture" as CFString

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let p = dlsym(handle, "TCCAccessPreflight"),
              let r = dlsym(handle, "TCCAccessRequest") else {
            preflightFn = nil
            requestFn = nil
            available = false
            Log.permission.error("TCC SPI unavailable (dlopen/dlsym failed)")
            return
        }
        preflightFn = unsafeBitCast(p, to: PreflightFn.self)
        requestFn = unsafeBitCast(r, to: RequestFn.self)
        available = true
    }

    /// 0 granted, 1 denied, 2 unknown (never asked). Anything else → unavailable.
    public func preflight() -> Preflight {
        guard let f = preflightFn else { return .unavailable }
        let v = f(service, nil)
        switch v {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default:
            Log.permission.error("TCCAccessPreflight returned unexpected \(v)")
            return .unavailable
        }
    }

    /// Shows the system prompt when the state is not determined. Completion on
    /// an arbitrary thread.
    public func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let f = requestFn else { completion(false); return }
        f(service, nil) { granted in completion(granted) }
    }
}

/// Identity of the running code, for keying persisted flags so that a new
/// certificate (or an ad-hoc build) starts over.
public struct CodeIdentity: Sendable {
    public let identifier: String
    public let isAdHoc: Bool
    /// SHA-1 of the leaf certificate, or "adhoc".
    public let leafHash: String

    public var flagSuffix: String { "\(identifier).\(leafHash)" }

    public static let current: CodeIdentity = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return CodeIdentity(identifier: Bundle.main.bundleIdentifier ?? "unknown", isAdHoc: true, leafHash: "adhoc")
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return CodeIdentity(identifier: Bundle.main.bundleIdentifier ?? "unknown", isAdHoc: true, leafHash: "adhoc")
        }
        let ident = info[kSecCodeInfoIdentifier as String] as? String ?? Bundle.main.bundleIdentifier ?? "unknown"
        let sigFlags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let adhoc = SecCodeSignatureFlags(rawValue: sigFlags).contains(.adhoc)
        var hash = "adhoc"
        if !adhoc, let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            let data = SecCertificateCopyData(leaf) as Data
            hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return CodeIdentity(identifier: ident, isAdHoc: adhoc, leafHash: hash)
    }()
}
