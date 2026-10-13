import Foundation

/// Records purchase attempts around a billing provider's store call. Shared by billing
/// integrations (RevenueCat today) so each one only maps its own result and error shapes.
///
/// Analytics never delays, changes or fails the purchase: the attempt is recorded without
/// waiting, the store call's result is returned (or its error rethrown) unchanged, and the
/// outcome is recorded in the background. `settled()` waits for that background work.
final class PurchaseTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var work: [UUID: Task<Void, Never>] = [:]
  // Outcomes are recorded one after another, in the order the purchases returned.
  private var lastOutcome: Task<Void, Never>?

  func track<Value>(
    _ view: PaywallView?, product: PaywallProduct,
    succeeded: (Value) -> PurchaseResult, failed: (any Error) -> PurchaseResult,
    _ purchase: () async throws -> Value
  ) async throws -> Value {
    // Starts immediately; the paywall API captures the attempt's time before storage work.
    let started = Task { await view?.purchaseStarted(product) }
    do {
      let value = try await purchase()
      finish(started, succeeded(value))
      return value
    } catch {
      finish(started, failed(error))
      throw error
    }
  }

  /// Runs analytics work in the background; `settled()` waits for it. Serial work starts only
  /// after earlier serial work has finished.
  func background(serial: Bool = false, _ operation: @escaping @Sendable () async -> Void) {
    let id = UUID()
    // Registered under the lock before the task can remove itself.
    lock.lock()
    let previous = serial ? lastOutcome : nil
    let task = Task { [weak self] in
      await previous?.value
      await operation()
      self?.remove(id)
    }
    work[id] = task
    if serial { lastOutcome = task }
    lock.unlock()
  }

  /// Returns once every recorded attempt, outcome and other background work has finished.
  func settled() async {
    while case let pending = pendingWork(), !pending.isEmpty {
      for task in pending { await task.value }
    }
  }

  private func pendingWork() -> [Task<Void, Never>] {
    lock.lock()
    defer { lock.unlock() }
    return Array(work.values)
  }

  private func finish(_ started: Task<PaywallPurchase?, Never>, _ outcome: PurchaseResult) {
    background(serial: true) {
      if let attempt = await started.value { await attempt.finished(outcome) }
    }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    work[id] = nil
    lock.unlock()
  }
}
