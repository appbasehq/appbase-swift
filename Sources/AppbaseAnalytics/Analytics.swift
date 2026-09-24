import Foundation

struct RevenueCatIdentity: Codable, Sendable {
  var projectId: String
  var appUserId: String
  var eventId: String
}
struct SDKState: Codable, Sendable {
  var version = 1
  var installationId: String
  var anonymousId: String
  var userId: String?
  var enabled = true
  var events: [AnalyticsEvent] = []
  var dropped = 0
  var onboarding: [String: SavedOnboarding] = [:]
  var paywalls: [String: SavedPaywallView] = [:]
  var paywallOrder: [String] = []
  var revenuecatIdentity: RevenueCatIdentity?
}
struct EventContext: Sendable {
  let options: AnalyticsOptions
  let occurredAt: String
  func nextId() throws -> String {
    let id = options.generateId()
    guard validUUID(id) else { throw AnalyticsError.invalidInput("generateId must return a UUID") }
    return id
  }
  @discardableResult
  func emit(
    name: String, properties: Properties, onboarding: OnboardingDefinition? = nil,
    into state: inout SDKState
  ) throws -> Bool {
    guard matches(name, "^[a-z][a-z0-9_.]{0,79}$"), validProperties(properties) else {
      throw AnalyticsError.invalidInput("Use a valid event name and bounded flat properties")
    }
    let id = try nextId()
    guard !state.events.contains(where: { $0.event_id.lowercased() == id.lowercased() }) else {
      throw AnalyticsError.invalidInput("generateId returned a duplicate event UUID")
    }
    guard state.events.count < options.maxQueueSize else {
      state.dropped += 1
      options.onDiagnostic?(
        Diagnostic(
          code: .queueFull, message: "Queue is full; newest event was not recorded", eventId: id))
      return false
    }
    state.events.append(
      AnalyticsEvent(
        event_id: id, installation_id: state.installationId, anonymous_id: state.anonymousId,
        user_id: state.userId, name: name, occurred_at: occurredAt, platform: options.platform,
        app_version: options.appVersion, properties: properties, onboarding: onboarding))
    return true
  }
}

/// A single durable owner for one app/environment. Keep it alive for the app's lifetime.
/// Operations run on this actor; mutations commit to storage without suspension points.
public actor Analytics {
  var state: SDKState
  var registeredDefinitions: [String: OnboardingDefinition] = [:]
  let options: AnalyticsOptions
  let storage: any AnalyticsStorage
  let storageKey: String
  private var fileLease: FileStorageLease?
  var disposed = false
  var identityRevision: UInt64 = 0
  private var blocked = false
  private var failures = 0
  private var retryAt: Date = .distantPast
  private var serverRetryAt: Date = .distantPast
  private var deliveryGeneration: UInt64 = 0
  private var inFlight: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  #if canImport(UIKit)
    private var lifecycle: AnalyticsLifecycle?
  #endif

  private init(
    options: AnalyticsOptions, storage: any AnalyticsStorage, key: String, state: SDKState,
    fileLease: FileStorageLease?
  ) {
    self.options = options
    self.storage = storage
    self.storageKey = key
    self.state = state
    self.fileLease = fileLease
  }
  public static func create(options supplied: AnalyticsOptions) async throws -> Analytics {
    var options = supplied
    guard options.appVersion.utf16.count >= 1,
      options.appVersion.utf16.count <= MobileContract.appVersionLength,
      ["ios", "android", "test"].contains(options.platform),
      options.flushInterval.isFinite, options.flushInterval >= 0,
      options.flushInterval <= Double(MobileContract.maxFlushIntervalMs) / 1000,
      options.requestTimeout.isFinite, options.requestTimeout > 0,
      options.requestTimeout <= Double(MobileContract.maxRequestTimeoutMs) / 1000,
      options.maxQueueSize > 0, options.maxQueueSize <= MobileContract.maxQueueSize,
      options.batchSize > 0,
      !options.collectionKey.isEmpty, options.collectionKey.utf16.count <= 1024,
      options.apiURL.host != nil, options.apiURL.user == nil, options.apiURL.password == nil,
      options.apiURL.query == nil, options.apiURL.fragment == nil,
      ["http", "https"].contains(options.apiURL.scheme?.lowercased() ?? "")
    else {
      throw AnalyticsError.configuration("Invalid app version, transport, queue limits, or API URL")
    }
    options.batchSize = min(options.batchSize, MobileContract.batchEvents)
    let pattern =
      "^ma_(dev|prod)_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_[0-9a-f]{48}$"
    if matches(options.collectionKey, pattern) {
      let pieces = options.collectionKey.split(separator: "_")
      let app = String(pieces[2])
      let environment: AnalyticsEnvironment = pieces[1] == "prod" ? .production : .development
      guard options.appId == nil || options.appId == app,
        options.environment == nil || options.environment == environment
      else {
        throw AnalyticsError.configuration(
          "Collection key does not match the configured app/environment")
      }
      options.appId = app
      options.environment = environment
    }
    guard let app = options.appId, matches(app, "^[a-zA-Z0-9_.-]{1,200}$"),
      let environment = options.environment
    else {
      throw AnalyticsError.configuration("Legacy keys require appId and environment")
    }
    guard environment != .production || options.apiURL.scheme?.lowercased() == "https" else {
      throw AnalyticsError.configuration("Production analytics requires HTTPS")
    }
    let storage = try options.storage ?? FileAnalyticsStorage()
    let key = "mobile-analytics:v1:\(app):\(environment.rawValue)"
    let fileLease = try (storage as? FileAnalyticsStorage)?.acquire(key: key)
    let initial: SDKState
    do {
      if let data = try storage.load(key: key) {
        guard data.count <= 32 * 1024 * 1024 else {
          throw AnalyticsError.storage("Saved analytics state is too large")
        }
        initial = try JSONDecoder().decode(SDKState.self, from: data)
        guard initial.version == MobileContract.contractVersion, validUUID(initial.installationId),
          validUUID(initial.anonymousId),
          initial.userId.map({ !$0.isEmpty && $0.utf16.count <= MobileContract.userIdLength })
            ?? true,
          initial.dropped >= 0, initial.events.count <= MobileContract.maxQueueSize,
          Set(initial.events.map { $0.event_id.lowercased() }).count == initial.events.count,
          initial.events.allSatisfy({ event in
            event.schema_version == MobileContract.contractVersion && validUUID(event.event_id)
              && validUUID(event.installation_id) && validUUID(event.anonymous_id)
              && validProperties(event.properties) && matches(event.name, "^[a-z][a-z0-9_.]{0,79}$")
              && parsedTimestamp(event.occurred_at) != nil
          })
        else { throw AnalyticsError.storage("Invalid saved analytics state") }
        try WorkflowValidation.validateState(initial)
        for event in initial.events {
          guard event.installation_id == initial.installationId,
            event.user_id.map({ !$0.isEmpty && $0.utf16.count <= MobileContract.userIdLength })
              ?? true,
            !event.app_version.isEmpty,
            event.app_version.utf16.count <= MobileContract.appVersionLength,
            ["ios", "android", "test"].contains(event.platform)
          else { throw AnalyticsError.storage("Invalid stored event context") }
          if let definition = event.onboarding {
            let validated = try WorkflowValidation.definition(
              OnboardingOptions(
                id: definition.id, version: .label(definition.version), steps: definition.steps,
                questions: definition.questions ?? []))
            guard validated == definition else {
              throw AnalyticsError.storage("Invalid stored event definition")
            }
          }
        }
        if let link = initial.revenuecatIdentity {
          guard validProviderId(link.projectId), validProviderId(link.appUserId),
            validUUID(link.eventId)
          else { throw AnalyticsError.storage("Invalid saved provider identity") }
        }
      } else {
        let context = EventContext(options: options, occurredAt: isoTimestamp(options.now()))
        var created = SDKState(
          installationId: try context.nextId(), anonymousId: try context.nextId())
        guard created.installationId != created.anonymousId else {
          throw AnalyticsError.invalidInput("Identity UUIDs must be distinct")
        }
        try context.emit(name: "app_first_open", properties: [:], into: &created)
        try storage.save(key: key, data: encoded(created))
        initial = created
      }
    } catch {
      options.onDiagnostic?(
        Diagnostic(
          code: .storage,
          message:
            "Unable to read or initialize analytics storage; existing data was not overwritten"))
      throw AnalyticsError.storage(
        "Unable to read or initialize analytics storage; existing data was not overwritten: \(error)"
      )
    }
    let client = Analytics(
      options: options, storage: storage, key: key, state: initial, fileLease: fileLease)
    await client.start()
    return client
  }
  private func start() async {
    if options.flushInterval > 0 {
      let interval = options.flushInterval
      timer = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch {
            return
          }
          await self?.flush()
        }
      }
    }
    #if canImport(UIKit)
      if options.automaticLifecycle {
        let owner = await AnalyticsLifecycle(analytics: self)
        lifecycle = owner
        await owner.start()
      }
    #endif
  }
  func diagnose(_ code: Diagnostic.Code, _ message: String, eventId: String? = nil) {
    options.onDiagnostic?(Diagnostic(code: code, message: message, eventId: eventId))
  }
  /// Workflow changes and event insertion either both commit or both roll back.
  nonisolated func perform<T: Sendable>(
    _ operation: @Sendable (inout SDKState, EventContext) throws -> T
  ) async -> T? {
    let occurredAt = isoTimestamp(options.now())
    return await performIsolated(operation, occurredAt: occurredAt)
  }
  func performCurrent<T: Sendable>(
    _ operation: @Sendable (inout SDKState, EventContext) throws -> T
  ) -> T? {
    performIsolated(operation, occurredAt: isoTimestamp(options.now()))
  }
  private func performIsolated<T: Sendable>(
    _ operation: @Sendable (inout SDKState, EventContext) throws -> T, occurredAt: String
  ) -> T? {
    guard !disposed, state.enabled else { return nil }
    do { return try transaction(occurredAt: occurredAt, operation) } catch {
      report(error)
      return nil
    }
  }
  func readWorkflow<T: Sendable>(_ operation: @Sendable (SDKState) throws -> T) -> T? {
    guard !disposed, state.enabled else { return nil }
    do { return try operation(state) } catch {
      report(error)
      return nil
    }
  }
  private func transaction<T>(
    occurredAt: String? = nil, _ operation: (inout SDKState, EventContext) throws -> T
  ) throws -> T {
    var candidate = state
    let result = try operation(
      &candidate,
      EventContext(options: options, occurredAt: occurredAt ?? isoTimestamp(options.now())))
    do { try storage.save(key: storageKey, data: encoded(candidate)) } catch {
      throw AnalyticsError.storage("Could not persist analytics state")
    }
    state = candidate
    if state.events.count >= options.batchSize { Task { [weak self] in await self?.flush() } }
    return result
  }
  private func report(_ error: any Error) {
    if case AnalyticsError.storage(let message) = error {
      diagnose(.storage, message)
    } else {
      diagnose(.invalidEvent, String(describing: error))
    }
  }
  @discardableResult
  public nonisolated func track(_ name: String, properties: Properties = [:]) async -> Bool {
    await perform { state, context in
      try context.emit(name: name, properties: properties, into: &state)
    } ?? false
  }
  @discardableResult
  public nonisolated func identify(_ userId: String) async -> Bool {
    await identifyIsolated(userId, occurredAt: isoTimestamp(options.now()))
  }
  private func identifyIsolated(_ userId: String, occurredAt: String) -> Bool {
    guard !disposed, !userId.isEmpty, userId.utf16.count <= MobileContract.userIdLength else {
      diagnose(.invalidEvent, "Use an opaque user ID of 1–200 characters")
      return false
    }
    guard state.userId == nil || wireEqual(state.userId!, userId) else {
      diagnose(.invalidEvent, "Call reset before switching accounts")
      return false
    }
    let changed = state.userId.map { !wireEqual($0, userId) } ?? true
    do {
      try transaction(occurredAt: occurredAt) { state, context in
        if changed { state.revenuecatIdentity = nil }
        state.userId = userId
        if state.enabled {
          try context.emit(name: "identity_linked", properties: [:], into: &state)
        }
      }
      if changed { identityRevision &+= 1 }
      return true
    } catch {
      report(error)
      return false
    }
  }
  @discardableResult
  public func reset() -> Bool {
    guard !disposed else { return false }
    do {
      try transaction { state, context in
        let next = try context.nextId()
        let occupied = [state.installationId, state.anonymousId] + state.events.map(\.anonymous_id)
        guard !occupied.contains(where: { $0.lowercased() == next.lowercased() }) else {
          throw AnalyticsError.invalidInput("generateId reused a retained identity UUID")
        }
        state.anonymousId = next
        state.userId = nil
        state.onboarding = [:]
        state.paywalls = [:]
        state.paywallOrder = []
        state.revenuecatIdentity = nil
      }
      identityRevision &+= 1
      return true
    } catch {
      report(error)
      return false
    }
  }
  @discardableResult
  public func setEnabled(_ enabled: Bool) -> Bool {
    guard !disposed else { return false }
    let changed = state.enabled != enabled
    do {
      try transaction { state, _ in
        state.enabled = enabled
        if !enabled {
          state.events = []
          state.onboarding = [:]
          state.paywalls = [:]
          state.paywallOrder = []
          state.revenuecatIdentity = nil
        }
      }
      if changed {
        identityRevision &+= 1
        deliveryGeneration &+= 1
      }
      if !enabled { inFlight?.cancel() }
      return true
    } catch {
      report(error)
      return false
    }
  }
  public func getIdentity() -> AnalyticsIdentity {
    AnalyticsIdentity(
      installationId: state.installationId, anonymousId: state.anonymousId, userId: state.userId)
  }
  public func getStatus() -> AnalyticsStatus {
    let deadline = max(retryAt, serverRetryAt)
    return AnalyticsStatus(
      queued: state.events.count, dropped: state.dropped, enabled: state.enabled, blocked: blocked,
      retryAt: deadline > options.now() ? deadline : nil)
  }
  public func resume() async {
    blocked = false
    retryAt = .distantPast
    await flush()
  }
  public func flush() async {
    if let running = inFlight {
      await running.value
      return
    }
    guard !disposed, !blocked, state.enabled, options.now() >= max(retryAt, serverRetryAt) else {
      return
    }
    let task = Task { await self.deliver() }
    inFlight = task
    await task.value
    inFlight = nil
  }
  private func deliver() async {
    for _ in 0..<MobileContract.maxBatchesPerFlush {
      guard !disposed, state.enabled, !Task.isCancelled, !state.events.isEmpty else { return }
      let generation = deliveryGeneration
      var batch: [AnalyticsEvent] = []
      var bytes = 14
      for event in state.events.prefix(options.batchSize) {
        guard let data = try? encoded(event) else {
          diagnose(.invalidEvent, "Stored event cannot be encoded")
          return
        }
        if !batch.isEmpty && bytes + data.count + 1 > MobileContract.clientBatchBytes { break }
        batch.append(event)
        bytes += data.count + 1
      }
      do {
        let response = try await sendWithTimeout(
          request(path: "v1/events/batch", body: encoded(["events": batch])),
          transport: options.transport)
        guard !disposed, state.enabled, generation == deliveryGeneration, !Task.isCancelled else {
          return
        }
        if response.status == 429 || response.status >= 500 {
          let wait = retryAfter(response, now: options.now())
          if wait > 0 { serverRetryAt = options.now().addingTimeInterval(wait) }
          if response.status == 429 {
            diagnose(.network, "HTTP 429: ingestion limit reached; events remain queued")
          }
          backoff(minimum: wait)
          return
        }
        guard (200..<300).contains(response.status) else {
          blocked = true
          diagnose(
            .blocked,
            "Collection rejected with HTTP \(response.status); fix configuration then resume")
          return
        }
        let ack = try JSONDecoder().decode(BatchAcknowledgement.self, from: response.body)
        let ids = ack.accepted + ack.rejected.map(\.event_id)
        guard !ids.isEmpty, Set(ids).count == ids.count,
          Set(ids).isSubset(of: Set(batch.map(\.event_id)))
        else {
          throw AnalyticsError.unavailable(
            "Invalid acknowledgement: duplicate, unknown, overlapping or empty IDs")
        }
        let removed = Set(ids)
        do {
          try transaction { state, _ in state.events.removeAll { removed.contains($0.event_id) } }
        } catch {
          diagnose(.storage, "Could not persist acknowledgement; events may be safely retried")
          backoff()
          return
        }
        for rejected in ack.rejected {
          diagnose(.rejected, rejected.reason, eventId: rejected.event_id)
        }
        failures = 0
        retryAt = .distantPast
      } catch {
        guard !disposed, state.enabled, generation == deliveryGeneration, !Task.isCancelled else {
          return
        }
        backoff()
        return
      }
    }
  }
  func request(path: String, body: Data) -> AnalyticsRequest {
    AnalyticsRequest(
      url: options.apiURL.appendingPathComponent(path),
      headers: ["Content-Type": "application/json", "X-API-Key": options.collectionKey], body: body,
      timeout: options.requestTimeout)
  }
  private func backoff(minimum: TimeInterval = 0) {
    failures += 1
    retryAt = options.now().addingTimeInterval(
      max(
        minimum, min(Double(MobileContract.retryMaximumMs) / 1000, pow(2, Double(min(failures, 6))))
      ))
    diagnose(.network, "Delivery deferred; events remain in persistent storage")
  }
  public func dispose() async {
    guard !disposed else { return }
    disposed = true
    identityRevision &+= 1
    deliveryGeneration &+= 1
    timer?.cancel()
    timer = nil
    #if canImport(UIKit)
      await lifecycle?.stop()
      lifecycle = nil
    #endif
    inFlight?.cancel()
    await inFlight?.value
    fileLease = nil
  }
}
private struct BatchAcknowledgement: Decodable {
  struct Rejection: Decodable {
    let event_id: String
    let reason: String
  }
  let accepted: [String]
  let rejected: [Rejection]
}
