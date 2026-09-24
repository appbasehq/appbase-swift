import Foundation

/// Numeric versions normalize to the same wire label as an equivalent string version.
public enum OnboardingVersion: Sendable, Equatable, ExpressibleByIntegerLiteral,
  ExpressibleByStringLiteral
{
  case number(Int)
  case label(String)

  public init(integerLiteral value: Int) { self = .number(value) }
  public init(stringLiteral value: String) { self = .label(value) }
}

public struct OnboardingOption: Codable, Sendable, Equatable {
  public let id: String
  public let label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    WorkflowValidation.exact(lhs.id, rhs.id) && WorkflowValidation.exact(lhs.label, rhs.label)
  }
}

public struct OnboardingQuestion: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case single, multiple }
  public let id: String
  public let stepId: String
  public let title: String
  public let type: Kind
  public let options: [OnboardingOption]

  public init(id: String, stepId: String, title: String, type: Kind, options: [OnboardingOption]) {
    self.id = id
    self.stepId = stepId
    self.title = title
    self.type = type
    self.options = options
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    WorkflowValidation.exact(lhs.id, rhs.id) && WorkflowValidation.exact(lhs.stepId, rhs.stepId)
      && WorkflowValidation.exact(lhs.title, rhs.title) && lhs.type == rhs.type
      && lhs.options == rhs.options
  }
}

public struct OnboardingOptions: Sendable {
  public let id: String
  public let version: OnboardingVersion?
  public let steps: [String]
  public let questions: [OnboardingQuestion]

  public init(
    id: String, version: OnboardingVersion? = nil, steps: [String],
    questions: [OnboardingQuestion] = []
  ) {
    self.id = id
    self.version = version
    self.steps = steps
    self.questions = questions
  }
}

/// A value snapshot: mutating the original inputs cannot change registered metadata.
public struct OnboardingDefinition: Codable, Sendable, Equatable {
  public let id: String
  public let version: String
  public let steps: [String]
  public let questions: [OnboardingQuestion]?

  public init(id: String, version: String, steps: [String], questions: [OnboardingQuestion]? = nil)
  {
    self.id = id
    self.version = version
    self.steps = steps
    self.questions = questions?.isEmpty == true ? nil : questions
  }

  var key: String { "\(id)/\(version)" }
}

public struct OnboardingAttempt: Codable, Sendable, Equatable {
  public let attemptId: String
  public let completed: Bool
  public let nextStep: Int
}

struct SavedAnswer: Codable, Sendable, Equatable {
  var values: [String]?
  var revision: Int
}

struct SavedOnboarding: Codable, Sendable {
  var attemptId: String
  var completed: Bool
  var nextStep: Int
  var definition: OnboardingDefinition
  var answers: [String: SavedAnswer] = [:]

  var snapshot: OnboardingAttempt {
    OnboardingAttempt(attemptId: attemptId, completed: completed, nextStep: nextStep)
  }
}

/// Workflow failures are reported through the SDK diagnostic callback. No failed action advances state.
public struct Onboarding: Sendable {
  public let definition: OnboardingDefinition
  let analytics: Analytics

  /// Resume the persisted attempt, including a completed attempt, or begin the first attempt.
  @discardableResult
  public func start(_ properties: Properties = [:]) async -> String? {
    await act(.start, properties: properties)
  }

  /// Begin a genuinely new attempt. Ordinary screen rendering should call start instead.
  @discardableResult
  public func restart(_ properties: Properties = [:]) async -> String? {
    await act(.restart, properties: properties)
  }

  /// Revisiting an already reached step is allowed; skipping an unseen step is rejected.
  @discardableResult
  public func step(_ id: String, properties: Properties = [:]) async -> Bool {
    await act(.step(id), properties: properties) != nil
  }

  /// Pass nil for an explicit skip. Multiple selections are normalized to definition order.
  @discardableResult
  public func answer(_ questionId: String, selection: [String]?, properties: Properties = [:]) async
    -> Bool
  {
    await act(.answer(questionId, selection), properties: properties) != nil
  }

  @discardableResult
  public func answer(_ questionId: String, selection: String, properties: Properties = [:]) async
    -> Bool
  {
    await answer(questionId, selection: [selection], properties: properties)
  }

  @discardableResult
  public func complete(_ properties: Properties = [:]) async -> Bool {
    await act(.complete, properties: properties) != nil
  }

  public func getState() async -> OnboardingAttempt? {
    await analytics.readWorkflow { $0.onboarding[definition.key]?.snapshot } ?? nil
  }

  private enum Action: Sendable {
    case start, restart
    case step(String)
    case answer(String, [String]?)
    case complete
  }

  private func act(_ action: Action, properties: Properties) async -> String? {
    await analytics.perform { state, context -> String? in
      let previous = state.onboarding[definition.key]
      var attempt: SavedOnboarding
      switch action {
      case .start where previous != nil:
        return previous?.attemptId
      case .start, .restart:
        try WorkflowValidation.check(
          previous != nil || state.onboarding.count < MobileContract.onboardingDefinitions,
          "Onboarding attempt storage limit reached")
        let attemptId = try context.nextId()
        try WorkflowValidation.check(
          !state.onboarding.values.contains { $0.attemptId.lowercased() == attemptId.lowercased() },
          "generateId returned a duplicate onboarding attempt UUID")
        attempt = SavedOnboarding(
          attemptId: attemptId, completed: false, nextStep: 0, definition: definition)
      default:
        guard let previous else {
          throw WorkflowValidationError(
            "Call onboarding.start() before tracking a step or completion")
        }
        attempt = previous
        if attempt.completed { return attempt.attemptId }
      }

      var props = properties
      props["flow_id"] = .string(definition.id)
      props["flow_version"] = .string(definition.version)
      props["attempt_id"] = .string(attempt.attemptId)
      let name: String
      switch action {
      case .start, .restart:
        name = "onboarding_started"
      case .step(let stepId):
        guard let index = definition.steps.firstIndex(of: stepId), index <= attempt.nextStep else {
          throw WorkflowValidationError("Track the declared onboarding steps in order")
        }
        props["step_id"] = .string(stepId)
        name = "onboarding_step_viewed"
        if index == attempt.nextStep { attempt.nextStep += 1 }
      case .answer(let questionId, let selection):
        guard let question = definition.questions?.first(where: { $0.id == questionId }),
          let step = definition.steps.firstIndex(of: question.stepId), step < attempt.nextStep
        else {
          throw WorkflowValidationError("View the question’s declared step before answering")
        }
        if let selection {
          let optionIds = Set(question.options.map(\.id))
          try WorkflowValidation.check(
            !selection.isEmpty && Set(selection).count == selection.count
              && (question.type != .single || selection.count == 1)
              && selection.allSatisfy(optionIds.contains),
            "Choose valid question options, or nil to explicitly skip")
        }
        let values = selection.map { selected in
          question.options.filter { selected.contains($0.id) }.map(\.id)
        }
        let prior = attempt.answers[questionId]
        if let prior, prior.values == values { return attempt.attemptId }
        try WorkflowValidation.check(
          (prior?.revision ?? 0) < WorkflowValidation.maxSafeInteger,
          "Answer revision limit reached")
        let revision = (prior?.revision ?? 0) + 1
        props["step_id"] = .string(question.stepId)
        props["question_id"] = .string(questionId)
        props["answer_ids"] = .strings(values ?? [])
        props["answer_status"] = .string(values == nil ? "skipped" : "answered")
        props["answer_revision"] = .number(Double(revision))
        attempt.answers[questionId] = SavedAnswer(values: values, revision: revision)
        name = "onboarding_answered"
      case .complete:
        try WorkflowValidation.check(
          attempt.nextStep == definition.steps.count,
          "Track every onboarding step before completion")
        attempt.completed = true
        name = "onboarding_completed"
      }
      guard try context.emit(name: name, properties: props, onboarding: definition, into: &state)
      else { return nil }
      state.onboarding[definition.key] = attempt
      return attempt.attemptId
    } ?? nil
  }
}

extension Analytics {
  public func onboarding(_ options: OnboardingOptions) throws -> Onboarding {
    let definition = try WorkflowValidation.definition(options)
    let previous =
      registeredDefinitions[definition.key] ?? state.onboarding[definition.key]?.definition
    if let previous {
      try WorkflowValidation.check(
        previous.steps == definition.steps,
        "This onboarding version already has different steps; choose a new version")
      try WorkflowValidation.check(
        (previous.questions ?? []) == (definition.questions ?? []),
        "This onboarding version already has different questions; choose a new version")
    }
    try WorkflowValidation.check(
      registeredDefinitions[definition.key] != nil
        || registeredDefinitions.count < MobileContract.onboardingDefinitions,
      "At most 100 onboarding definitions per SDK instance")
    registeredDefinitions[definition.key] = definition
    return Onboarding(definition: definition, analytics: self)
  }

  public func onboarding(
    id: String, version: OnboardingVersion? = nil, steps: [String],
    questions: [OnboardingQuestion] = []
  ) throws -> Onboarding {
    try onboarding(OnboardingOptions(id: id, version: version, steps: steps, questions: questions))
  }
}

struct WorkflowValidationError: Error, LocalizedError, CustomStringConvertible, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
  var description: String { message }
}

enum WorkflowValidation {
  static let maxSafeInteger = MobileContract.maximumSafeInteger

  // Swift's default String equality normalizes Unicode. Wire identifiers/text use exact sequences.
  static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
  static func exact(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (.some(let a), .some(let b)): return exact(a, b)
    default: return false
    }
  }
  static func unique(_ strings: [String]) -> Bool {
    Set(strings.map { Data($0.utf8) }).count == strings.count
  }

  /// Fail closed on unsupported/corrupt state; initialization must never overwrite it.
  static func validateState(_ state: SDKState) throws {
    try check(
      state.onboarding.count <= MobileContract.onboardingDefinitions,
      "Saved onboarding exceeds its storage limit")
    try check(
      Set(state.onboarding.values.map { $0.attemptId.lowercased() }).count
        == state.onboarding.count, "Duplicate saved onboarding attempt UUID")
    for (key, attempt) in state.onboarding {
      let saved = attempt.definition
      let validated = try definition(
        OnboardingOptions(
          id: saved.id, version: .label(saved.version), steps: saved.steps,
          questions: saved.questions ?? []))
      try check(
        saved == validated && key == saved.key && validUUID(attempt.attemptId)
          && (0...saved.steps.count).contains(attempt.nextStep)
          && (!attempt.completed || attempt.nextStep == saved.steps.count),
        "Invalid saved onboarding attempt")
      for (questionId, answer) in attempt.answers {
        guard let question = saved.questions?.first(where: { $0.id == questionId }),
          let index = saved.steps.firstIndex(of: question.stepId), index < attempt.nextStep
        else {
          throw WorkflowValidationError("Saved answer has no reached question")
        }
        try check(
          answer.revision > 0 && answer.revision <= maxSafeInteger, "Invalid saved answer revision")
        if let values = answer.values {
          let canonical = question.options.filter { values.contains($0.id) }.map(\.id)
          try check(
            !values.isEmpty && canonical == values
              && (question.type != .single || values.count == 1), "Invalid saved answer selection")
        }
      }
    }
    try Paywall.validateState(state)
  }

  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw WorkflowValidationError(message) }
  }

  static func label(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func alphanumeric(_ b: UInt8) -> Bool {
      (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b)
    }
    return (1...MobileContract.labelLength).contains(bytes.count) && alphanumeric(bytes[0])
      && bytes.allSatisfy { alphanumeric($0) || [45, 46, 95].contains($0) }
  }

  // ECMA-262 WhiteSpace + LineTerminator, deliberately matching JavaScript String.trim().
  private static func whitespace(_ s: Unicode.Scalar) -> Bool {
    [
      0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F,
      0x205F, 0x3000, 0xFEFF,
    ].contains(s.value) || (0x2000...0x200A).contains(s.value)
  }

  static func trimmed(_ value: String) -> Bool {
    return (value.unicodeScalars.first.map { !whitespace($0) } ?? true)
      && (value.unicodeScalars.last.map { !whitespace($0) } ?? true)
  }

  static func trim(_ value: String) -> String {
    var scalars = value.unicodeScalars[...]
    while let first = scalars.first, whitespace(first) { scalars.removeFirst() }
    while let last = scalars.last, whitespace(last) { scalars.removeLast() }
    return String(scalars)
  }

  static func opaque(_ value: String) -> Bool {
    !value.isEmpty && value.utf16.count <= MobileContract.storeIdLength && trimmed(value)
  }

  static func definition(_ options: OnboardingOptions) throws -> OnboardingDefinition {
    try check(
      options.questions.count <= MobileContract.onboardingQuestions
        && Set(options.questions.map(\.id)).count == options.questions.count,
      "Use at most 20 questions with unique IDs")
    for q in options.questions {
      try check(
        label(q.id) && options.steps.contains(q.stepId) && !q.title.isEmpty && trimmed(q.title)
          && q.title.utf16.count <= MobileContract.questionTitleLength
          && (1...MobileContract.questionOptions).contains(q.options.count)
          && Set(q.options.map(\.id)).count == q.options.count
          && q.options.allSatisfy {
            label($0.id) && !$0.label.isEmpty && trimmed($0.label)
              && $0.label.utf16.count <= MobileContract.optionLabelLength
          },
        "Use a declared step, a question title and 1–20 uniquely identified, labeled options")
    }
    let version: String
    switch options.version {
    case .number(let number):
      try check(
        number > 0 && number <= maxSafeInteger,
        "Onboarding version must be a positive safe integer or a stable string label")
      version = String(number)
    case .label(let value): version = value
    case nil: version = automaticVersion(steps: options.steps, questions: options.questions)
    }
    try check(
      label(options.id) && label(version)
        && (1...MobileContract.onboardingSteps).contains(options.steps.count)
        && options.steps.allSatisfy(label) && Set(options.steps).count == options.steps.count,
      "Onboarding requires stable ID/version labels and 1–20 unique step IDs")
    let definition = OnboardingDefinition(
      id: options.id, version: version, steps: options.steps, questions: options.questions)
    let json =
      "{\"id\":\(jsonString(definition.id)),\"version\":\(jsonString(version)),\"steps\":\(jsonArray(options.steps))"
      + (options.questions.isEmpty ? "" : ",\"questions\":\(jsonQuestions(options.questions))")
      + "}"
    try check(
      json.utf8.count <= MobileContract.onboardingDefinitionBytes,
      "Onboarding definition exceeds 16 KiB")
    return definition
  }

  // Explicit field ordering and JSON string escaping preserve the existing JavaScript wire fingerprint.
  static func automaticVersion(steps: [String], questions: [OnboardingQuestion]) -> String {
    let json =
      questions.isEmpty
      ? jsonArray(steps)
      : "{\"steps\":\(jsonArray(steps)),\"questions\":\(jsonQuestions(questions))}"
    var a: UInt32 = 0x811c_9dc5
    var b: UInt32 = 0x9e37_79b9
    for scalar in json.unicodeScalars {
      // JS `for ... of` visits code points, but charCodeAt(0) hashes only the first UTF-16 unit.
      let unit = scalar.value <= 0xffff ? scalar.value : 0xd800 + ((scalar.value - 0x10000) >> 10)
      a = (a ^ unit) &* 0x0100_0193
      b = (b ^ unit) &* 0x85eb_ca6b
    }
    return String(format: "auto-%08x%08x", a, b)
  }

  private static func jsonArray(_ values: [String]) -> String {
    "[" + values.map(jsonString).joined(separator: ",") + "]"
  }
  private static func jsonQuestions(_ questions: [OnboardingQuestion]) -> String {
    "["
      + questions.map { q in
        "{\"id\":\(jsonString(q.id)),\"stepId\":\(jsonString(q.stepId)),\"title\":\(jsonString(q.title)),\"type\":\(jsonString(q.type.rawValue)),\"options\":["
          + q.options.map { "{\"id\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}" }
          .joined(separator: ",") + "]}"
      }.joined(separator: ",") + "]"
  }
  private static func jsonString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5c: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x0c: result += "\\f"
      case 0x0a: result += "\\n"
      case 0x0d: result += "\\r"
      case 0x09: result += "\\t"
      case 0...0x1f: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}
