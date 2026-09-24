import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct AnalyticsRequest: Sendable {
  public let url: URL
  public let headers: [String: String]
  public let body: Data
  public let timeout: TimeInterval
  public init(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) {
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }
}
public struct AnalyticsResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data
  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }
  func header(_ name: String) -> String? {
    headers.first { $0.key.lowercased() == name.lowercased() }?.value
  }
}
/// Implementations must observe task cancellation and bound response size (the default does both).
public protocol AnalyticsTransport: Sendable {
  func send(_ request: AnalyticsRequest) async throws -> AnalyticsResponse
}
public struct URLSessionAnalyticsTransport: AnalyticsTransport {
  public init() {}
  public func send(_ request: AnalyticsRequest) async throws -> AnalyticsResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeout
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = request.timeout
    configuration.timeoutIntervalForResource = request.timeout
    configuration.httpShouldSetCookies = false
    let session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw AnalyticsError.unavailable("Invalid HTTP response")
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < MobileContract.requestBytes else {
        throw AnalyticsError.unavailable("Response exceeds 1 MiB")
      }
      data.append(byte)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return AnalyticsResponse(status: http.statusCode, headers: headers, body: data)
  }
}

func sendWithTimeout(_ request: AnalyticsRequest, transport: any AnalyticsTransport) async throws
  -> AnalyticsResponse
{
  try await withThrowingTaskGroup(of: AnalyticsResponse.self) { group in
    group.addTask { try await transport.send(request) }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(request.timeout * 1_000_000_000))
      throw AnalyticsError.unavailable("Request timed out")
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw CancellationError() }
    return result
  }
}
func retryAfter(_ response: AnalyticsResponse, now: Date) -> TimeInterval {
  guard let value = response.header("retry-after") else { return 0 }
  if let seconds = Double(value), seconds.isFinite {
    return min(Double(MobileContract.retryAfterMaximumMs) / 1000, max(0, seconds))
  }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
  return formatter.date(from: value).map {
    min(Double(MobileContract.retryAfterMaximumMs) / 1000, max(0, $0.timeIntervalSince(now)))
  } ?? 0
}

// Redirects must not forward public collection credentials or user payloads to a different endpoint.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
