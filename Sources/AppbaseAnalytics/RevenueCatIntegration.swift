import Foundation

/// A RevenueCat `StoreTransaction`, readable without Appbase depending on RevenueCat.
/// Add once in your app: `extension StoreTransaction: @retroactive RevenueCatStoreTransaction {}`.
public protocol RevenueCatStoreTransaction {
  var transactionIdentifier: String { get }
}

/// Connects RevenueCat: keeps the RevenueCat customer linked to the analytics identity, tracks
/// access for paywall views and records purchases. Create it with `Analytics.connectRevenueCat`.
public final class RevenueCatIntegration: @unchecked Sendable {
  private let analytics: Analytics
  private let projectId: String
  private let entitlement: String?
  private let appUserID: @Sendable () async throws -> String
  private let tracker = PurchaseTracker()
  private let lock = NSLock()
  private var access = PaywallAccessState.unknown
  private var stopped = false
  private var following: [Task<Void, Never>] = []

  init(
    analytics: Analytics, projectId: String, entitlement: String?,
    appUserID: @escaping @Sendable () async throws -> String
  ) {
    self.analytics = analytics
    self.projectId = projectId
    self.entitlement = entitlement
    self.appUserID = appUserID
    link()
  }

  /// The customer's current access for paywall views: `.unknown` until RevenueCat has reported
  /// customer info (through `follow` or `update`), then `.active` or `.inactive`.
  public var accessState: PaywallAccessState {
    lock.lock()
    defer { lock.unlock() }
    return access
  }

  /// Follows RevenueCat's customer updates to keep identity and access current:
  /// `revenueCat.follow(Purchases.shared.customerInfoStream) { Set($0.entitlements.active.keys) }`.
  public func follow<Updates: AsyncSequence & Sendable>(
    _ updates: Updates, activeEntitlements: @escaping @Sendable (Updates.Element) -> Set<String>
  ) {
    let task = Task { [weak self] in
      do {
        for try await info in updates {
          guard let self, !self.isStopped else { return }
          self.update(activeEntitlements: activeEntitlements(info))
        }
      } catch {
        // A finished or failed stream stops following; purchases keep working.
      }
    }
    lock.lock()
    if stopped { task.cancel() } else { following.append(task) }
    lock.unlock()
  }

  /// Reports RevenueCat customer info's active entitlement identifiers (what `follow` does for
  /// each update), and links the current RevenueCat customer again.
  public func update(activeEntitlements: Set<String>) {
    let granted = entitlement.map(activeEntitlements.contains) ?? !activeEntitlements.isEmpty
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    access = granted ? .active : .inactive
    lock.unlock()
    link()
  }

  /// Links the current RevenueCat customer again. Updates and purchases already do this; call it
  /// after `analytics.identify` or `reset` when RevenueCat itself did not change.
  public func sync() async {
    link()
    await tracker.settled()
  }

  /// Runs a RevenueCat purchase and records its attempt and outcome on the paywall view:
  /// `try await revenueCat.purchase(view, productId: package.storeProduct.productIdentifier) {
  /// try await Purchases.shared.purchase(package: package) }`. Returns RevenueCat's result, or
  /// rethrows its error, unchanged; analytics never delays or fails the purchase.
  public func purchase<Transaction: RevenueCatStoreTransaction, CustomerInfo>(
    _ view: PaywallView?, product: PaywallProduct,
    _ purchase: () async throws -> (
      transaction: Transaction?, customerInfo: CustomerInfo, userCancelled: Bool
    )
  ) async throws -> (transaction: Transaction?, customerInfo: CustomerInfo, userCancelled: Bool) {
    if isStopped { return try await purchase() }
    link()
    return try await tracker.track(
      view, product: product,
      succeeded: { result in
        result.userCancelled
          ? PurchaseResult(result: .cancelled)
          : PurchaseResult(
            result: .succeeded, transactionId: result.transaction?.transactionIdentifier)
      },
      failed: Self.failedOutcome, purchase)
  }

  public func purchase<Transaction: RevenueCatStoreTransaction, CustomerInfo>(
    _ view: PaywallView?, productId: String,
    _ purchase: () async throws -> (
      transaction: Transaction?, customerInfo: CustomerInfo, userCancelled: Bool
    )
  ) async throws -> (transaction: Transaction?, customerInfo: CustomerInfo, userCancelled: Bool) {
    try await self.purchase(view, product: PaywallProduct(productId: productId), purchase)
  }

  /// Returns once identity links and purchase outcomes recorded so far have been stored.
  public func settled() async { await tracker.settled() }

  /// Stops following RevenueCat. Purchases still work; they are no longer recorded.
  public func stop() {
    lock.lock()
    stopped = true
    let tasks = following
    following = []
    lock.unlock()
    tasks.forEach { $0.cancel() }
  }

  // RevenueCat's `ErrorCode` (domain `RevenueCat.ErrorCode`): 1 cancelled, 20 pending (Ask to Buy).
  static func failedOutcome(_ error: any Error) -> PurchaseResult {
    let error = error as NSError
    guard error.domain == "RevenueCat.ErrorCode" else { return PurchaseResult(result: .failed) }
    let code = String(error.code)
    switch error.code {
    case 1: return PurchaseResult(result: .cancelled, errorCode: code)
    case 20: return PurchaseResult(result: .pending, errorCode: code)
    default: return PurchaseResult(result: .failed, errorCode: code)
    }
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  // The analytics SDK deduplicates identical links, so relinking on every update is cheap.
  private func link() {
    let (analytics, projectId, appUserID) = (analytics, projectId, appUserID)
    tracker.background {
      _ = await analytics.linkRevenueCatUser(projectId: projectId, getAppUserId: appUserID)
    }
  }
}

extension Analytics {
  /// Connects RevenueCat after `Purchases.configure`. `appUserID` reads RevenueCat's current
  /// customer (`{ Purchases.shared.appUserID }`); `entitlement` is the one that unlocks the
  /// paywalled offering (any active entitlement counts when omitted). Throws for invalid options.
  public nonisolated func connectRevenueCat(
    projectId: String, entitlement: String? = nil,
    appUserID: @escaping @Sendable () async throws -> String
  ) throws -> RevenueCatIntegration {
    guard validProviderId(projectId) else {
      throw AnalyticsError.invalidInput("Supply the RevenueCat project ID")
    }
    guard entitlement.map(validProviderId) ?? true else {
      throw AnalyticsError.invalidInput("Use the RevenueCat entitlement identifier, or omit it")
    }
    return RevenueCatIntegration(
      analytics: self, projectId: projectId, entitlement: entitlement, appUserID: appUserID)
  }
}
