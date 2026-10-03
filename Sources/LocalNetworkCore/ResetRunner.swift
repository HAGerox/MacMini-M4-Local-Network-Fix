import Foundation

/// Remembers which permissions must end up enabled, so a run that is killed
/// part-way (crash, force quit, power loss) is repaired by the next run.
public protocol RecoveryStore: AnyObject {
  func load() -> RecoveryState
  func save(_ state: RecoveryState) throws
  func clear()
}

public final class FileRecoveryStore: RecoveryStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Toggle Local Network", isDirectory: true)
      .appendingPathComponent("pending-restore.json")
  }

  public func load() -> RecoveryState {
    guard let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(RecoveryState.self, from: data)
    else { return RecoveryState() }
    return state
  }

  public func save(_ state: RecoveryState) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: url, options: .atomic)
  }

  public func clear() {
    try? FileManager.default.removeItem(at: url)
  }
}

public struct RunnerConfiguration: Sendable {
  /// Each attempt starts from a freshly launched System Settings.
  public var attempts: Int
  public var delayBetweenAttempts: TimeInterval
  /// Diagnostic mode: independently reread values in a new Settings process.
  /// Normal runs verify the current page without changing the window.
  public var verifyInFreshSession: Bool

  public init(attempts: Int = 3, delayBetweenAttempts: TimeInterval = 0, verifyInFreshSession: Bool = false) {
    self.attempts = attempts
    self.delayBetweenAttempts = delayBetweenAttempts
    self.verifyInFreshSession = verifyInFreshSession
  }
}

public struct RunResult: Sendable {
  public var report: ResetReport
  public var attempts: Int
  public var duration: TimeInterval
}

@MainActor
public final class ResetRunner {
  private let session: SettingsSession
  private let store: RecoveryStore
  private let configuration: RunnerConfiguration
  private let resetConfiguration: ResetConfiguration
  private let log: (String) -> Void
  private let now: () -> Date
  private let sleep: (TimeInterval) -> Void

  /// Called after each failed attempt, before System Settings is closed, so
  /// the caller can capture diagnostics.
  public var onAttemptFailure: ((Int, Error) -> Void)?
  /// Logs every press with its timing.
  public var traceEnabled = ProcessInfo.processInfo.environment["TLN_TRACE"] == "1"

  public init(
    session: SettingsSession,
    store: RecoveryStore,
    configuration: RunnerConfiguration = RunnerConfiguration(),
    resetConfiguration: ResetConfiguration = ResetConfiguration(),
    log: @escaping (String) -> Void = { _ in },
    now: @escaping () -> Date = Date.init,
    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    self.session = session
    self.store = store
    self.configuration = configuration
    self.resetConfiguration = resetConfiguration
    self.log = log
    self.now = now
    self.sleep = sleep
  }

  /// Whether the desktop can currently be automated.
  public var isInteractive: () -> Bool = { true }
  /// How quickly System Settings responds, carried from attempt to attempt.
  public private(set) var pace = ResponsePace()
  private var currentResetter: LocalNetworkResetter?
  /// Blocks until the desktop can be automated.
  public var waitForUnlock: () -> Void = {}

  public func run() throws -> RunResult {
    let started = now()
    var recovering = store.load()
    if !recovering.isEmpty {
      log(
        "An earlier run was interrupted; ensuring these stay enabled: "
          + recovering.keys.map(\.description).sorted().joined(separator: ", "))
    }

    var lastError: Error = LocalNetworkError.localNetworkPageNotFound
    var attempt = 0
    var lockInterruptions = 0
    while attempt < max(1, configuration.attempts) {
      attempt += 1
      waitForUnlock()
      do {
        try session.close()
        try session.openLocalNetworkPage()
        let opened = now()
        let resetter = LocalNetworkResetter(
          ui: session, configuration: resetConfiguration, pace: pace, now: now, sleep: sleep)
        currentResetter = resetter
        resetter.progress = { [log] done, total, name in
          if let name {
            log("Resetting group \(done + 1)/\(total): \(name)")
          } else {
            log("Completed \(total) groups: off/on confirmed on the current page.")
          }
        }
        if traceEnabled {
          let started = now()
          resetter.trace = { [log, now] in
            log(String(format: "  +%.2fs ", now().timeIntervalSince(started)) + $0)
          }
        }
        let report = try resetter.reset(recovering: recovering) { intent in
          recovering.merge(Array(intent.keys), groupSizes: intent.groupSizes)
          do {
            try store.save(recovering)
          } catch {
            // Persisting is a safety net; it must never stop the reset itself.
            log("Could not save recovery state: \(error.localizedDescription)")
          }
        }
        let checked = now()
        if configuration.verifyInFreshSession {
          try confirmInFreshSession(report.reset + report.recovered)
          log(String(format: "Diagnostic fresh verification in %.2fs", now().timeIntervalSince(checked)))
        } else {
          log("Verified the full list on the current page; no Settings reopen needed.")
        }
        store.clear()
        log(
          String(
            format: "Attempt %d: opened Local Network in %.2fs, reset %d of %d permissions in %.2fs",
            attempt, opened.timeIntervalSince(started), report.reset.count, report.totalRows,
            now().timeIntervalSince(opened)))
        if !report.recovered.isEmpty {
          log("Re-enabled after an interrupted run: \(report.recovered.map(\.description))")
        }
        if !report.ambiguous.isEmpty {
          log("Could not tell apart same-named apps to re-enable: \(report.ambiguous)")
        }

        do {
          try session.close()
        } catch {
          // Every permission is verified, so this is not a failed reset.
          log("System Settings did not close afterwards: \(error.localizedDescription)")
        }
        return RunResult(
          report: report, attempts: attempt, duration: now().timeIntervalSince(started))
      } catch {
        if let currentResetter { pace = currentResetter.pace }
        // Capture diagnostics while System Settings is still showing the problem.
        let diagnostics = onAttemptFailure
        if !(!isInteractive() && lockInterruptions < 20) {
          diagnostics?(attempt, error)
        }
        try? session.close()
        if Self.isAccessibilityRevoked(error) {
          throw LocalNetworkError.accessibilityRequired
        }
        // The screen locking mid-run makes System Settings unusable; it is
        // not a failed attempt. Wait for the unlock and try again, keeping
        // the recovery state so anything switched off is restored.
        if !isInteractive(), lockInterruptions < 20 {
          lockInterruptions += 1
          attempt -= 1
          log("The Mac was locked during the reset; continuing after it is unlocked.")
          continue
        }
        lastError = error
        log("Attempt \(attempt) failed: \(error.localizedDescription)")
        if attempt < configuration.attempts {
          sleep(configuration.delayBetweenAttempts)
        }
      }
    }
    throw finalRestore(after: lastError, recovering: recovering)
  }

  /// System Settings can display a switch as on while it is really off, so
  /// success is only accepted once a newly opened System Settings, which
  /// loads the saved state, shows every permission enabled. Anything still
  /// off is switched on and checked again in another fresh session.
  private func confirmInFreshSession(_ keys: [RowKey]) throws {
    guard !keys.isEmpty else { return }
    for pass in 1...3 {
      try session.close()
      try session.openLocalNetworkPage()
      let resetter = LocalNetworkResetter(
        ui: session, configuration: resetConfiguration, now: now, sleep: sleep)
      let off = try resetter.disabled(among: keys)
      if off.isEmpty { return }
      log("Fresh check \(pass): still off after the reset: \(off.map(\.description))")
      guard pass < 3 else {
        throw ResetFailure(
          underlying: LocalNetworkError.verificationFailed(off.map(\.description)),
          possiblyDisabled: off.map(\.description))
      }
      _ = resetter.restore(off)
    }
  }

  /// After the last failed attempt, one more fresh System Settings session
  /// switches back on anything an attempt left off, so a failed run never
  /// relies on a display that stopped updating.
  private func finalRestore(after error: Error, recovering: RecoveryState) -> Error {
    guard !recovering.isEmpty, !Self.isAccessibilityRevoked(error) else { return error }
    let underlying = (error as? ResetFailure)?.underlying ?? error
    var stillDisabled: [String] = []
    var verified = false
    var pass = 0
    var lockRetries = 0
    while pass < 3 {
      pass += 1
      waitForUnlock()
      do {
        try session.close()
        try session.openLocalNetworkPage()
        let resetter = LocalNetworkResetter(
          ui: session, configuration: resetConfiguration, now: now, sleep: sleep)
        // Each pass reads a freshly opened System Settings, so the result is
        // the saved state rather than a display that may be stale.
        let (off, unresolved) = try resetter.disabled(recovering: recovering)
        stillDisabled = off.map(\.description) + unresolved
        verified = true
        if off.isEmpty || pass == 3 { break }
        _ = resetter.restore(off)
      } catch {
        if !isInteractive(), lockRetries < 20 {
          lockRetries += 1
          pass -= 1
          continue
        }
        log("Final check pass \(pass) failed: \(error.localizedDescription)")
        verified = false
      }
    }
    try? session.close()
    guard verified else {
      log("Final check: System Settings could not be read; state unknown.")
      return ResetFailure(underlying: underlying, possiblyDisabled: [], unverified: true)
    }
    log(
      stillDisabled.isEmpty
        ? "Final check: every permission is enabled."
        : "Final check: could not confirm enabled: \(stillDisabled)")
    if stillDisabled.isEmpty { store.clear() }
    return ResetFailure(underlying: underlying, possiblyDisabled: stillDisabled)
  }


  private static func isAccessibilityRevoked(_ error: Error) -> Bool {
    if let failure = error as? ResetFailure {
      return failure.underlying.isFatalAccessibilityError
    }
    return error.isFatalAccessibilityError
  }
}
