import CoreGraphics
import Darwin
import Foundation

/// Whether the logged-in user's desktop can currently be automated. While the
/// screen is locked or another user is switched in, System Settings exposes no
/// usable windows, so the reset must wait instead of failing.
public enum UserSession {
  public struct State: Equatable, Sendable {
    public var onConsole: Bool
    public var locked: Bool
    public var loginDone: Bool

    public init(onConsole: Bool, locked: Bool, loginDone: Bool) {
      self.onConsole = onConsole
      self.locked = locked
      self.loginDone = loginDone
    }

    public var isInteractive: Bool { onConsole && loginDone && !locked }
  }

  public static func current() -> State {
    let values = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    func flag(_ key: String) -> Bool? {
      (values[key] as? NSNumber)?.boolValue ?? (values[key] as? Bool)
    }
    return State(
      onConsole: flag(kCGSessionOnConsoleKey) ?? false,
      locked: flag("CGSSessionScreenIsLocked") ?? false,
      loginDone: flag(kCGSessionLoginDoneKey) ?? true
    )
  }

  /// Blocks until the session is interactive. Returns how long it waited.
  @discardableResult
  public static func waitUntilInteractive(
    state: () -> State = current,
    pollInterval: TimeInterval = 1,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    onWait: (State) -> Void = { _ in }
  ) -> Int {
    var polls = 0
    var current = state()
    while !current.isInteractive {
      if polls == 0 { onWait(current) }
      polls += 1
      sleep(pollInterval)
      current = state()
    }
    return polls
  }
}

/// Ensures only one copy runs at a time, so a login item and a manual launch
/// can never operate System Settings simultaneously. The lock is released by
/// the kernel when the process exits, even after a crash.
public final class SingleInstanceLock {
  private let descriptor: Int32

  public init?(path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    self.descriptor = descriptor
  }

  public static var defaultPath: String {
    FileRecoveryStore.defaultURL.deletingLastPathComponent()
      .appendingPathComponent("instance.lock").path
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}

/// Appends timestamped lines to ~/Library/Logs/Toggle Local Network, so
/// users can send a complete history of every run.
public final class RunLog: @unchecked Sendable {
  public static let shared = RunLog()

  public let directory: URL
  public let url: URL
  private let lock = NSLock()
  private let maximumSize = 2_000_000
  public var echoToStandardError = true

  public init(
    directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Toggle Local Network", isDirectory: true)
  ) {
    self.directory = directory
    self.url = directory.appendingPathComponent("Toggle Local Network.log")
  }

  public func write(_ message: String) {
    let line = "\(Self.timestamp()) [\(getpid())] \(message)\n"
    lock.lock()
    defer { lock.unlock() }
    if echoToStandardError {
      FileHandle.standardError.write(Data(line.utf8))
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
      size > maximumSize
    {
      let previous = directory.appendingPathComponent("Toggle Local Network.previous.log")
      try? FileManager.default.removeItem(at: previous)
      try? FileManager.default.moveItem(at: url, to: previous)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }

  /// Saves a diagnostic snapshot next to the log, keeping the newest five.
  @discardableResult
  public func writeDiagnostic(_ contents: String, name: String) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = Self.timestamp().replacingOccurrences(of: ":", with: "-")
    let file = directory.appendingPathComponent("\(name) \(stamp).txt")
    guard (try? contents.write(to: file, atomically: true, encoding: .utf8)) != nil else {
      return nil
    }
    let diagnostics =
      ((try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(name) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    for old in diagnostics.dropFirst(5) {
      try? FileManager.default.removeItem(at: old)
    }
    return file
  }

  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter.string(from: Date())
  }
}

/// Detects the app making no progress, which nothing else can rule out (for
/// example a system call into a wedged System Settings). Progress is reported
/// by every wait loop through `beat()`.
public final class Watchdog: @unchecked Sendable {
  public static let shared = Watchdog()

  public init() {}

  private let lock = NSLock()
  private var lastBeat = Date()
  private var suspended = 0
  private var started = false

  public func beat() {
    lock.withLock { lastBeat = Date() }
  }

  /// Pauses checking while the app is legitimately idle, such as when an
  /// alert is waiting for the person to respond.
  public func suspend() { lock.withLock { suspended += 1 } }

  public func resume() {
    lock.withLock {
      suspended = max(0, suspended - 1)
      lastBeat = Date()
    }
  }

  /// Seconds since the last beat, or nil while suspended.
  public var staleness: TimeInterval? {
    lock.withLock { suspended > 0 ? nil : Date().timeIntervalSince(lastBeat) }
  }

  /// Starts a background check. `unstick` runs once after `firstStage`
  /// seconds without progress; `giveUp` runs after `secondStage` seconds.
  public func start(
    firstStage: TimeInterval = 90,
    secondStage: TimeInterval = 150,
    unstick: @escaping @Sendable () -> Void,
    giveUp: @escaping @Sendable () -> Void
  ) {
    let shouldStart = lock.withLock { () -> Bool in
      defer { started = true }
      return !started
    }
    guard shouldStart else { return }
    beat()
    Thread.detachNewThread { [self] in
      var unstuck = false
      while true {
        Thread.sleep(forTimeInterval: 2)
        guard let stale = staleness else {
          unstuck = false
          continue
        }
        if stale < firstStage {
          unstuck = false
        } else if !unstuck {
          unstuck = true
          unstick()
        } else if stale >= secondStage {
          giveUp()
          return
        }
      }
    }
  }
}
