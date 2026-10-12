import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Coarse native distribution signal only. Never exports Apple account/transaction identifiers.
public enum AppbaseRuntimeEnvironment {
    public static func detect() async -> String {
#if targetEnvironment(simulator) || DEBUG
        return "development"
#else
        // Physical development signing remains Development even in a Release build.
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .isoLatin1),
           let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
           start.lowerBound < end.upperBound,
           let plist = String(text[start.lowerBound..<end.upperBound]).data(using: .utf8),
           let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let entitlements = profile["Entitlements"] as? [String: Any],
           entitlements["get-task-allow"] as? Bool == true {
            return "development"
        }
#if canImport(StoreKit)
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            // A first-result gate bounds initialization even if StoreKit ignores cancellation.
            return await withCheckedContinuation { continuation in
                let gate = RuntimeEnvironmentResult(continuation)
                Task {
                    let value: String
                    do {
                        if case .verified(let transaction) = try await AppTransaction.shared {
                            switch transaction.environment {
                            case .production: value = "production"
                            case .sandbox: value = "sandbox"
                            case .xcode: value = "development"
                            default: value = "unknown"
                            }
                        } else { value = "unknown" }
                    } catch { value = "unknown" }
                    gate.finish(value)
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    gate.finish("unknown")
                }
            }
        }
#endif
        return "unknown"
#endif
    }
}

private final class RuntimeEnvironmentResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func finish(_ value: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
