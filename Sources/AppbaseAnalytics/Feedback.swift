import Foundation

public struct FeedbackInput: Sendable {
  public var message: String
  public var email: String?
  /// Reuse the ID returned by FeedbackError for uncertain retries.
  public var submissionId: String?
  public init(message: String, email: String? = nil, submissionId: String? = nil) {
    self.message = message
    self.email = email
    self.submissionId = submissionId
  }
}
public struct FeedbackReceipt: Codable, Equatable, Sendable {
  public let id: String
  public let received_at: String
}
public struct FeedbackError: Error, Sendable, CustomStringConvertible {
  public enum Code: String, Sendable {
    case invalidInput = "invalid_input"
    case network
    case rateLimited = "rate_limited"
    case configuration, conflict, unavailable
  }
  public let submissionId: String
  public let code: Code
  public let retryAfterSeconds: TimeInterval?
  public let description: String
  init(_ description: String, id: String, code: Code, retryAfter: TimeInterval? = nil) {
    self.description = description
    self.submissionId = id
    self.code = code
    self.retryAfterSeconds = retryAfter
  }
}
private struct FeedbackSubmission: Encodable {
  let id: String
  let message: String
  let email: String?
  let platform: String
  let app_version: String
  let anonymous_id: String?
  let user_id: String?
}
extension Analytics {
  /// Explicit contact is independent of analytics consent; opted-out submissions omit analytics identity.
  public func feedback(_ input: FeedbackInput) async throws -> FeedbackReceipt {
    let id = input.submissionId ?? options.generateId()
    guard !disposed else {
      throw FeedbackError("This client has been disposed", id: id, code: .configuration)
    }
    let message = WorkflowValidation.trim(input.message)
    let email = input.email.map(WorkflowValidation.trim)
    guard validUUID(id), !message.isEmpty,
      message.utf16.count <= MobileContract.feedbackMessageLength, !message.contains("\0"),
      email == nil || email == ""
        || (email!.utf16.count <= MobileContract.feedbackEmailLength
          && matches(email!, "^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$"))
    else {
      throw FeedbackError(
        "Enter a message of 1–4000 characters and a valid optional email", id: id,
        code: .invalidInput)
    }
    let submission = FeedbackSubmission(
      id: id, message: message, email: email == "" ? nil : email, platform: options.platform,
      app_version: options.appVersion, anonymous_id: state.enabled ? state.anonymousId : nil,
      user_id: state.enabled ? state.userId : nil)
    do {
      let response = try await sendWithTimeout(
        request(path: "v1/feedback", body: encoded(submission)), transport: options.transport)
      guard (200..<300).contains(response.status) else {
        let code: FeedbackError.Code
        switch response.status {
        case 429: code = .rateLimited
        case 409: code = .conflict
        case 400: code = .invalidInput
        case 401, 403: code = .configuration
        default: code = .unavailable
        }
        let wait = retryAfter(response, now: options.now())
        throw FeedbackError(
          "Could not confirm feedback delivery (HTTP \(response.status)); keep the submission ID when retrying",
          id: id, code: code, retryAfter: wait > 0 ? wait : nil)
      }
      guard let receipt = try? JSONDecoder().decode(FeedbackReceipt.self, from: response.body),
        receipt.id == id, parsedTimestamp(receipt.received_at) != nil
      else {
        throw FeedbackError(
          "Could not confirm delivery; keep the submission ID when retrying", id: id,
          code: .unavailable)
      }
      return receipt
    } catch let error as FeedbackError { throw error } catch {
      throw FeedbackError(
        "Could not confirm delivery; check your connection and retry with this submission ID",
        id: id, code: .network)
    }
  }
}
