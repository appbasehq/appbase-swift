import Darwin
import Foundation

/// Called synchronously on the analytics actor. Save must durably replace the complete value or throw.
/// Implementations must be safe to transfer between tasks. Use one live Analytics instance per namespace.
public protocol AnalyticsStorage: Sendable {
  func load(key: String) throws -> Data?
  func save(key: String, data: Data) throws
}

/// Atomic file replacement in Application Support, excluded from cloud/device backups.
public final class FileAnalyticsStorage: AnalyticsStorage, @unchecked Sendable {
  private let directory: URL
  private let lock = NSLock()
  public init(directory: URL? = nil) throws {
    self.directory =
      try directory
      ?? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("AppbaseAnalytics", isDirectory: true)
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = self.directory
    try url.setResourceValues(values)
  }
  private func path(_ key: String) throws -> URL {
    guard matches(key, "^mobile-analytics:v1:[a-zA-Z0-9_.-]+:(development|production)$") else {
      throw AnalyticsError.storage("Invalid storage namespace")
    }
    return directory.appendingPathComponent(key.replacingOccurrences(of: ":", with: "_") + ".json")
  }
  public func load(key: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    let url = try path(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    guard try file.seekToEnd() <= 32 * 1024 * 1024 else {
      throw AnalyticsError.storage("Analytics state exceeds 32 MiB; refusing to overwrite")
    }
    try file.seek(toOffset: 0)
    return try file.readToEnd() ?? Data()
  }
  func acquire(key: String) throws -> FileStorageLease {
    let file = try path(key)
    let lease = try FileStorageLease(url: file.appendingPathExtension("lock"))
    let prefix = "." + file.lastPathComponent + ".pending-"
    // Only this namespace is locked. Never remove another active namespace's temporary write.
    for entry in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let name = entry.lastPathComponent
      if name.hasPrefix(prefix), validUUID(String(name.dropFirst(prefix.count))) {
        try? FileManager.default.removeItem(at: entry)
      }
    }
    return lease
  }
  public func save(key: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard data.count <= 32 * 1024 * 1024 else {
      throw AnalyticsError.storage("Analytics state exceeds 32 MiB")
    }
    let url = try path(key)
    let temporary = directory.appendingPathComponent(
      "." + url.lastPathComponent + ".pending-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    #if os(iOS)
      try data.write(
        to: temporary,
        options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: temporary, options: .withoutOverwriting)
    #endif
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    guard rename(temporary.path, url.path) == 0 else {
      throw AnalyticsError.storage("Could not atomically replace analytics state")
    }
    // No fallible operation may be reported after rename: the new state is already committed.
    // Directory syncing is best-effort because availability differs across Apple filesystems.
    let parent = open(directory.path, O_RDONLY)
    if parent >= 0 {
      _ = fsync(parent)
      close(parent)
    }
  }
}

/// Prevent accidental competing clients/processes from replacing each other's outbox snapshots.
final class FileStorageLease: @unchecked Sendable {
  private let descriptor: Int32
  init(url: URL) throws {
    descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw AnalyticsError.storage("Cannot open analytics storage lock")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw AnalyticsError.storage(
        "This app/environment already has a live analytics storage owner")
    }
  }
  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
