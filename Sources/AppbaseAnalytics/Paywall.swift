import Foundation

public struct PaywallOptions: Sendable {
  public let id: String
  public let version: Int
  public init(id: String, version: Int = 1) {
    self.id = id
    self.version = version
  }
}

public enum PaywallAccessState: String, Codable, Sendable { case inactive, active, unknown }
public enum PaywallDismissReason: String, Codable, Sendable {
  case closeButton = "close_button"
  case back, purchased, other
}

public struct PaywallViewOptions: Sendable {
  public let placement: String
  public let accessState: PaywallAccessState?
  public let productIds: [String]?
  public let onboarding: Onboarding?
  public let properties: Properties

  /// Access and product IDs describe what was known immediately before this presentation.
  public init(
    placement: String, accessState: PaywallAccessState? = nil, productIds: [String]? = nil,
    onboarding: Onboarding? = nil, properties: Properties = [:]
  ) {
    self.placement = placement
    self.accessState = accessState
    self.productIds = productIds
    self.onboarding = onboarding
    self.properties = properties
  }
}

public struct PaywallProduct: Codable, Sendable, Equatable {
  public let productId: String
  public let offerId: String?
  public init(productId: String, offerId: String? = nil) {
    self.productId = productId
    self.offerId = offerId
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    WorkflowValidation.exact(lhs.productId, rhs.productId)
      && WorkflowValidation.exact(lhs.offerId, rhs.offerId)
  }
}

public struct PurchaseResult: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable { case succeeded, cancelled, failed, pending }
  public let result: Outcome
  public let transactionId: String?
  public let errorCode: String?

  /// App-reported callbacks never establish verified revenue. RevenueCat verifies billing separately.
  public init(result: Outcome, transactionId: String? = nil, errorCode: String? = nil) {
    self.result = result
    self.transactionId = transactionId
    self.errorCode = errorCode
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.result == rhs.result && WorkflowValidation.exact(lhs.transactionId, rhs.transactionId)
      && WorkflowValidation.exact(lhs.errorCode, rhs.errorCode)
  }
}

struct SavedPurchase: Codable, Sendable {
  var product: PaywallProduct
  var result: PurchaseResult?
}

struct SavedPaywallView: Codable, Sendable {
  var context: Properties
  var dismissed: String?
  var purchases: [String: SavedPurchase]
}

public struct Paywall: Sendable {
  public let id: String
  public let version: Int
  let analytics: Analytics

  /// Each call records a new presentation. Use getView to resume a saved one without another exposure.
  public func view(_ options: PaywallViewOptions) async -> PaywallView? {
    let viewId: String? =
      await analytics.perform { state, context -> String? in
        try WorkflowValidation.check(
          WorkflowValidation.label(options.placement), "Paywall requires a stable placement")
        if let products = options.productIds {
          try WorkflowValidation.check(
            (1...MobileContract.propertyArrayLength).contains(products.count)
              && products.allSatisfy(WorkflowValidation.opaque)
              && WorkflowValidation.unique(products),
            "List 1–20 unique product IDs, or omit the list when unknown")
        }
        var properties = options.properties
        for reserved in Self.reservedProperties { properties.removeValue(forKey: reserved) }
        if let onboarding = options.onboarding {
          try WorkflowValidation.check(
            onboarding.analytics === analytics,
            "Use an onboarding helper created by this SDK instance")
          guard let attempt = state.onboarding[onboarding.definition.key] else {
            throw WorkflowValidationError("Start onboarding on this SDK before linking a paywall")
          }
          properties["flow_id"] = .string(onboarding.definition.id)
          properties["flow_version"] = .string(onboarding.definition.version)
          properties["onboarding_attempt_id"] = .string(attempt.attemptId)
        }
        let viewId = try context.nextId()
        try WorkflowValidation.check(
          !state.paywalls.keys.contains { $0.lowercased() == viewId.lowercased() },
          "generateId returned a duplicate paywall view UUID")
        properties["paywall_id"] = .string(id)
        properties["paywall_version"] = .string(String(version))
        properties["paywall_view_id"] = .string(viewId)
        properties["placement"] = .string(options.placement)
        if let access = options.accessState {
          properties["paywall_access_state"] = .string(access.rawValue)
        }
        if let products = options.productIds { properties["product_ids"] = .strings(products) }
        guard try context.emit(name: "paywall_viewed", properties: properties, into: &state) else {
          return nil
        }
        state.paywalls[viewId] = SavedPaywallView(context: properties, purchases: [:])
        state.paywallOrder.append(viewId)
        // Only resumable handles are evicted; recorded history stays in the durable outbox.
        while state.paywallOrder.count > MobileContract.paywallViews {
          state.paywalls.removeValue(forKey: state.paywallOrder.removeFirst())
        }
        return viewId
      } ?? nil
    return viewId.map { PaywallView(viewId: $0, paywall: self) }
  }

  public func view(
    placement: String, accessState: PaywallAccessState? = nil, productIds: [String]? = nil,
    onboarding: Onboarding? = nil, properties: Properties = [:]
  ) async -> PaywallView? {
    await view(
      PaywallViewOptions(
        placement: placement, accessState: accessState, productIds: productIds,
        onboarding: onboarding, properties: properties))
  }

  public func getView(_ viewId: String) async -> PaywallView? {
    let found = await analytics.readWorkflow { state in
      guard let view = state.paywalls[viewId] else { return false }
      return view.context["paywall_id"] == .string(id)
        && view.context["paywall_version"] == .string(String(version))
    }
    return found == true ? PaywallView(viewId: viewId, paywall: self) : nil
  }

  fileprivate func saved(_ state: SDKState, viewId: String) throws -> SavedPaywallView {
    guard let view = state.paywalls[viewId], view.context["paywall_id"] == .string(id),
      view.context["paywall_version"] == .string(String(version))
    else {
      throw WorkflowValidationError(
        "Paywall view is unavailable; it may have been reset or evicted")
    }
    return view
  }

  private static let reservedProperties = [
    "paywall_id", "paywall_version", "paywall_view_id", "placement", "paywall_access_state",
    "product_ids",
    "flow_id", "flow_version", "onboarding_attempt_id", "product_id", "offer_id",
    "purchase_attempt_id",
    "result", "result_source", "transaction_id", "error_code", "dismiss_reason",
  ]

  static func validateState(_ state: SDKState) throws {
    try WorkflowValidation.check(
      state.paywalls.count <= MobileContract.paywallViews
        && state.paywallOrder.count == state.paywalls.count
        && Set(state.paywallOrder).count == state.paywallOrder.count
        && Set(state.paywallOrder) == Set(state.paywalls.keys),
      "Invalid saved paywall order or storage limit")
    try WorkflowValidation.check(
      Set(state.paywalls.keys.map { $0.lowercased() }).count == state.paywalls.count,
      "Duplicate saved paywall view UUID")
    let purchaseIds = state.paywalls.values.flatMap { $0.purchases.keys.map { $0.lowercased() } }
    try WorkflowValidation.check(
      Set(purchaseIds).count == purchaseIds.count, "Duplicate saved purchase attempt UUID")
    for (viewId, view) in state.paywalls {
      func string(_ key: String) -> String? {
        guard case .string(let value) = view.context[key] else { return nil }
        return value
      }
      guard let id = string("paywall_id"), let version = string("paywall_version"),
        let number = Int(version),
        let placement = string("placement")
      else { throw WorkflowValidationError("Saved paywall is missing its context") }
      try WorkflowValidation.check(
        validUUID(viewId) && string("paywall_view_id") == viewId && WorkflowValidation.label(id)
          && number > 0 && number <= WorkflowValidation.maxSafeInteger && String(number) == version
          && WorkflowValidation.label(placement) && validProperties(view.context),
        "Invalid saved paywall context")
      if view.context["paywall_access_state"] != nil {
        try WorkflowValidation.check(
          string("paywall_access_state").flatMap(PaywallAccessState.init(rawValue:)) != nil,
          "Invalid saved access state")
      }
      var products: [String]?
      if let value = view.context["product_ids"] {
        guard case .strings(let ids) = value else {
          throw WorkflowValidationError("Invalid saved product list")
        }
        try WorkflowValidation.check(
          (1...MobileContract.propertyArrayLength).contains(ids.count)
            && ids.allSatisfy(WorkflowValidation.opaque) && WorkflowValidation.unique(ids),
          "Invalid saved product list")
        products = ids
      }
      if ["flow_id", "flow_version", "onboarding_attempt_id"].contains(where: {
        view.context[$0] != nil
      }) {
        guard let flow = string("flow_id"), let flowVersion = string("flow_version"),
          let attempt = string("onboarding_attempt_id")
        else {
          throw WorkflowValidationError("Incomplete saved onboarding context")
        }
        try WorkflowValidation.check(
          WorkflowValidation.label(flow) && WorkflowValidation.label(flowVersion)
            && validUUID(attempt), "Invalid saved onboarding context")
      }
      try WorkflowValidation.check(
        [
          "product_id", "offer_id", "purchase_attempt_id", "result", "result_source",
          "transaction_id", "error_code", "dismiss_reason",
        ].allSatisfy { view.context[$0] == nil }, "Saved paywall context contains action fields")
      try WorkflowValidation.check(
        view.dismissed.map { PaywallDismissReason(rawValue: $0) != nil } ?? true,
        "Invalid saved dismissal")
      try WorkflowValidation.check(
        view.purchases.count <= MobileContract.paywallPurchases,
        "Saved paywall exceeds its purchase limit")
      for (attemptId, purchase) in view.purchases {
        try WorkflowValidation.check(
          validUUID(attemptId) && WorkflowValidation.opaque(purchase.product.productId)
            && (purchase.product.offerId.map(WorkflowValidation.opaque) ?? true)
            && (products.map {
              $0.contains { WorkflowValidation.exact($0, purchase.product.productId) }
            } ?? true), "Invalid saved purchase product")
        if let result = purchase.result {
          try WorkflowValidation.check(
            (result.transactionId.map(WorkflowValidation.opaque) ?? true)
              && (result.errorCode.map(WorkflowValidation.opaque) ?? true),
            "Invalid saved purchase result")
        }
      }
    }
  }
}

public struct PaywallView: Sendable {
  public let viewId: String
  fileprivate let paywall: Paywall

  @discardableResult
  public func productSelected(_ product: PaywallProduct) async -> Bool {
    await paywall.analytics.perform { state, context in
      let view = try paywall.saved(state, viewId: viewId)
      try WorkflowValidation.check(view.dismissed == nil, "Paywall view has been dismissed")
      return try context.emit(
        name: "paywall_product_selected", properties: productProperties(product, view: view),
        into: &state)
    } == true
  }

  public func purchaseStarted(_ product: PaywallProduct) async -> PaywallPurchase? {
    let attemptId: String? =
      await paywall.analytics.perform { state, context -> String? in
        var view = try paywall.saved(state, viewId: viewId)
        try WorkflowValidation.check(view.dismissed == nil, "Paywall view has been dismissed")
        try WorkflowValidation.check(
          view.purchases.count < MobileContract.paywallPurchases,
          "At most 20 purchase attempts per paywall view")
        var properties = try productProperties(product, view: view)
        let attemptId = try context.nextId()
        try WorkflowValidation.check(
          !state.paywalls.values.contains { saved in
            saved.purchases.keys.contains { $0.lowercased() == attemptId.lowercased() }
          }, "generateId returned a duplicate purchase attempt UUID")
        properties["purchase_attempt_id"] = .string(attemptId)
        guard
          try context.emit(name: "paywall_purchase_started", properties: properties, into: &state)
        else { return nil }
        view.purchases[attemptId] = SavedPurchase(product: product)
        state.paywalls[viewId] = view
        return attemptId
      } ?? nil
    return attemptId.map {
      PaywallPurchase(attemptId: $0, productId: product.productId, view: self)
    }
  }

  @discardableResult
  public func dismissed(reason: PaywallDismissReason = .other) async -> Bool {
    await paywall.analytics.perform { state, context in
      var view = try paywall.saved(state, viewId: viewId)
      if view.dismissed != nil { return true }
      var properties = view.context
      properties["dismiss_reason"] = .string(reason.rawValue)
      guard try context.emit(name: "paywall_dismissed", properties: properties, into: &state) else {
        return false
      }
      view.dismissed = reason.rawValue
      state.paywalls[viewId] = view
      return true
    } == true
  }

  public func getPurchase(_ attemptId: String) async -> PaywallPurchase? {
    let productId: String? =
      await paywall.analytics.readWorkflow { state in
        try paywall.saved(state, viewId: viewId).purchases[attemptId]?.product.productId
      } ?? nil
    return productId.map { PaywallPurchase(attemptId: attemptId, productId: $0, view: self) }
  }

  fileprivate func productProperties(_ product: PaywallProduct, view: SavedPaywallView) throws
    -> Properties
  {
    try WorkflowValidation.check(
      WorkflowValidation.opaque(product.productId), "Use the exact product ID (1–200 characters)")
    try WorkflowValidation.check(
      product.offerId.map(WorkflowValidation.opaque) ?? true, "Invalid offer ID")
    if case .strings(let shown) = view.context["product_ids"] {
      try WorkflowValidation.check(
        shown.contains { WorkflowValidation.exact($0, product.productId) },
        "Product was not listed on this paywall view")
    }
    var properties = view.context
    properties["product_id"] = .string(product.productId)
    if let offerId = product.offerId { properties["offer_id"] = .string(offerId) }
    return properties
  }
}

public struct PaywallPurchase: Sendable {
  public let attemptId: String
  public let productId: String
  fileprivate let view: PaywallView

  /// Pending may later resolve, including after dismissal/restart. Identical callbacks are idempotent.
  @discardableResult
  public func finished(_ result: PurchaseResult) async -> Bool {
    await view.paywall.analytics.perform { state, context in
      var saved = try view.paywall.saved(state, viewId: view.viewId)
      guard var purchase = saved.purchases[attemptId] else {
        throw WorkflowValidationError("Purchase attempt is unavailable")
      }
      try WorkflowValidation.check(
        result.transactionId.map(WorkflowValidation.opaque) ?? true, "Invalid transaction ID")
      try WorkflowValidation.check(
        result.errorCode.map(WorkflowValidation.opaque) ?? true, "Invalid error code")
      if purchase.result == result { return true }
      try WorkflowValidation.check(
        purchase.result == nil || purchase.result?.result == .pending,
        "Purchase attempt already has a final result")
      var properties = try view.productProperties(purchase.product, view: saved)
      properties["purchase_attempt_id"] = .string(attemptId)
      properties["result"] = .string(result.result.rawValue)
      properties["result_source"] = .string("client")
      if let transaction = result.transactionId {
        properties["transaction_id"] = .string(transaction)
      }
      if let error = result.errorCode { properties["error_code"] = .string(error) }
      guard try context.emit(name: "paywall_purchase_result", properties: properties, into: &state)
      else { return false }
      purchase.result = result
      saved.purchases[attemptId] = purchase
      state.paywalls[view.viewId] = saved
      return true
    } == true
  }
}

extension Analytics {
  public func paywall(_ options: PaywallOptions) throws -> Paywall {
    try WorkflowValidation.check(
      WorkflowValidation.label(options.id), "Paywall requires a stable ID")
    try WorkflowValidation.check(
      options.version > 0 && options.version <= WorkflowValidation.maxSafeInteger,
      "Paywall version must be a positive safe integer")
    return Paywall(id: options.id, version: options.version, analytics: self)
  }

  public func paywall(id: String, version: Int = 1) throws -> Paywall {
    try paywall(PaywallOptions(id: id, version: version))
  }
}
