import Foundation

/// Flat, bounded JSON values. Nested objects are deliberately unsupported.
public enum PropertyValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case strings([String])
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .strings(try container.decode([String].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .strings(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}
extension PropertyValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}
extension PropertyValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension PropertyValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}
extension PropertyValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension PropertyValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension PropertyValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: String...) { self = .strings(elements) }
}
public typealias Properties = [String: PropertyValue]

public struct AnalyticsEvent: Codable, Equatable, Sendable {
  public var schema_version: Int = MobileContract.contractVersion
  public var event_id: String
  public var installation_id: String
  public var anonymous_id: String
  public var user_id: String?
  public var name: String
  public var occurred_at: String
  public var platform: String
  public var app_version: String
  public var properties: Properties
  public var onboarding: OnboardingDefinition?
}
public struct AnalyticsIdentity: Equatable, Sendable {
  public let installationId: String
  public let anonymousId: String
  public let userId: String?
}
public struct AnalyticsStatus: Equatable, Sendable {
  public let queued: Int
  public let dropped: Int
  public let enabled: Bool
  public let blocked: Bool
  /// Earliest permitted retry, including the server's Retry-After deadline.
  public let retryAt: Date?
}
public struct Diagnostic: Sendable {
  public enum Code: String, Codable, Sendable {
    case configuration, storage
    case invalidEvent = "invalid_event"
    case queueFull = "queue_full"
    case network, rejected, blocked
  }
  public let code: Code
  public let message: String
  public let eventId: String?
  public init(code: Code, message: String, eventId: String? = nil) {
    self.code = code
    self.message = message
    self.eventId = eventId
  }
}
public enum AnalyticsError: Error, Sendable, CustomStringConvertible {
  case configuration(String)
  case invalidInput(String)
  case storage(String)
  case unavailable(String)
  public var description: String {
    switch self {
    case .configuration(let s), .invalidInput(let s), .storage(let s), .unavailable(let s): return s
    }
  }
}
public enum AnalyticsEnvironment: String, Codable, Sendable { case development, production }

public struct AnalyticsOptions: Sendable {
  public var apiURL: URL
  public var collectionKey: String
  public var appVersion: String
  public var appId: String?
  public var environment: AnalyticsEnvironment?
  /// iOS in production; test is available for controlled server integration fixtures.
  public var platform: String = "ios"
  public var storage: (any AnalyticsStorage)?
  public var transport: any AnalyticsTransport = URLSessionAnalyticsTransport()
  public var generateId: @Sendable () -> String = { UUID().uuidString.lowercased() }
  public var now: @Sendable () -> Date = { Date() }
  public var onDiagnostic: (@Sendable (Diagnostic) -> Void)?
  public var flushInterval: TimeInterval = Double(MobileContract.defaultFlushIntervalMs) / 1000
  public var maxQueueSize: Int = MobileContract.defaultQueueSize
  public var batchSize: Int = MobileContract.defaultBatchSize
  public var requestTimeout: TimeInterval = Double(MobileContract.defaultRequestTimeoutMs) / 1000
  public var automaticLifecycle: Bool = true
  public init(apiURL: URL, collectionKey: String, appVersion: String) {
    self.apiURL = apiURL
    self.collectionKey = collectionKey
    self.appVersion = appVersion
  }
}

func encoded<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}
func matches(_ value: String, _ pattern: String) -> Bool {
  value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
}
func validUUID(_ value: String) -> Bool {
  matches(value, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
}
func isoTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
func parsedTimestamp(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)
}
func validProperties(_ properties: Properties) -> Bool {
  guard properties.count <= MobileContract.propertyCount else { return false }
  for (key, value) in properties {
    guard !key.isEmpty, key.utf16.count <= MobileContract.propertyKeyLength else { return false }
    switch value {
    case .string(let string):
      if string.utf16.count > MobileContract.propertyStringLength { return false }
    case .strings(let strings):
      if strings.count > MobileContract.propertyArrayLength
        || strings.contains(where: { $0.utf16.count > MobileContract.propertyArrayStringLength })
      {
        return false
      }
    case .number(let number): if !number.isFinite { return false }
    default: break
    }
  }
  return (try? propertyJSONBytes(properties)).map { $0 <= MobileContract.propertiesBytes } ?? false
}

/// JSON opaque identifiers use exact scalar bytes, not Swift's canonical Unicode equivalence.
func wireEqual(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }

/// The wire contract measures JSON.stringify's compact UTF-8 form, not an encoder's arbitrary
/// spelling of the same JSON number. Swift's encoder differs around exponential thresholds.
func propertyJSONBytes(_ properties: Properties) throws -> Int {
  var count = try encoded(properties).count
  for value in properties.values {
    if case .number(let number) = value {
      count += ecmaNumberBytes(number) - (try encoded(number).count)
    }
  }
  return count
}

private func ecmaNumberBytes(_ number: Double) -> Int {
  // JSON.stringify normalizes both signs of zero to a single digit.
  if number == 0 { return 1 }
  let magnitude = abs(number)
  let components = String(magnitude).lowercased().split(separator: "e")
  let mantissa = String(components[0])
  let exponent = components.count == 2 ? Int(components[1])! : 0
  var decimalPosition =
    (mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
      ?? mantissa.count) + exponent
  var digits = Array(mantissa.filter { $0 != "." })
  while digits.count > 1 && digits.first == "0" {
    digits.removeFirst()
    decimalPosition -= 1
  }
  while digits.count > 1 && digits.last == "0" { digits.removeLast() }
  let sign = number < 0 ? 1 : 0
  if magnitude >= 1e-6 && magnitude < 1e21 {
    if decimalPosition <= 0 { return sign + 2 - decimalPosition + digits.count }
    return sign + max(decimalPosition, digits.count) + (decimalPosition < digits.count ? 1 : 0)
  }
  // Exponential form has one leading digit, optional fraction, 'e', and an explicit exponent sign.
  return sign + digits.count + (digits.count > 1 ? 1 : 0) + 2
    + String(abs(decimalPosition - 1)).count
}
