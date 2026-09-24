import Foundation

extension Analytics {
  /// Stores client identity evidence only. This neither authenticates a user nor verifies revenue.
  /// Capture RevenueCat's current app user ID from the caller's configured SDK.
  public func linkRevenueCatUser(
    projectId: String, getAppUserId: @Sendable () async throws -> String
  ) async -> String? {
    guard validProviderId(projectId) else {
      diagnose(.invalidEvent, "Supply a valid RevenueCat project ID")
      return nil
    }
    guard !disposed, state.enabled else { return nil }
    let revision = identityRevision
    let appUserId: String
    do { appUserId = try await getAppUserId() } catch {
      diagnose(.invalidEvent, "RevenueCat identity lookup failed; retry after configuration")
      return nil
    }
    guard validProviderId(appUserId) else {
      diagnose(.invalidEvent, "RevenueCat App User ID must be an opaque 1–255 character identifier")
      return nil
    }
    guard !disposed, state.enabled, revision == identityRevision else {
      diagnose(
        .invalidEvent,
        "Analytics identity changed during RevenueCat lookup; link again after the account change")
      return nil
    }
    return performCurrent { state, context -> String? in
      if let old = state.revenuecatIdentity, wireEqual(old.projectId, projectId),
        wireEqual(old.appUserId, appUserId)
      {
        return old.eventId
      }
      guard
        try context.emit(
          name: "revenuecat_identity_linked",
          properties: [
            "revenuecat_project_id": .string(projectId),
            "revenuecat_app_user_id": .string(appUserId), "link_source": "client",
          ], into: &state), let event = state.events.last
      else { return nil }
      state.revenuecatIdentity = RevenueCatIdentity(
        projectId: projectId, appUserId: appUserId, eventId: event.event_id)
      return event.event_id
    } ?? nil
  }
}
func validProviderId(_ value: String) -> Bool {
  !value.isEmpty && value.utf16.count <= MobileContract.providerIdLength
    && WorkflowValidation.trimmed(value)
    && !value.unicodeScalars.contains { $0.value <= 31 || $0.value == 127 }
}
