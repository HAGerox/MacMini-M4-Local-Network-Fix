import AppKit
import Darwin
import Foundation
import LocalNetworkCore

/// Live end-to-end tests against the real System Settings. They run inside the
/// app so they use the app's own Accessibility permission. Each scenario
/// reproduces a failure seen in the field or a plausible one, and afterwards
/// every Local Network switch must match the state recorded before testing.
@MainActor
enum SelfTest {
  struct Failure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  struct Scenario {
    var name: String
    var body: () throws -> String
  }

  static let log = RunLog.shared
  static var instanceLockForScenarios: SingleInstanceLock?
  static var baseline: [RowKey: ToggleState] = [:]
  static var durations: [TimeInterval] = []
  static let testDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("toggle-local-network-self-test", isDirectory: true)
  static let storeURL = testDirectory.appendingPathComponent("pending-restore.json")

  static func main(arguments: [String]) -> Int32 {
    if let flag = arguments.firstIndex(of: "--reset-only") {
      // Experiment: run a full reset restricted to the named apps.
      let names = Set(arguments[flag + 1].split(separator: ",").map(String.init))
      let runner = ResetRunner(
        session: FilteredSession(base: SystemSettingsController(), names: names),
        store: FileRecoveryStore(url: storeURL), log: { log.write("  " + $0) },
        sleep: SystemSettingsController.pause)
      runner.traceEnabled = true
      do {
        let result = try runner.run()
        log.write(String(format: "reset-only: OK in %.2fs, attempts %d", result.duration, result.attempts))
      } catch {
        log.write("reset-only: FAILED \(error.localizedDescription)")
      }
      return EXIT_SUCCESS
    }
    if let flag = arguments.firstIndex(of: "--restore-from") {
      // Switches on (never off) every row that is on in a saved state file of
      // "index:label=1" lines, one press at a time, verified in fresh sessions.
      let wanted = ((try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)) ?? "")
        .split(separator: "\n").compactMap { line -> Int? in
          guard line.hasSuffix("=1"), let colon = line.firstIndex(of: ":") else { return nil }
          return Int(line[..<colon])
        }
      let settings = SystemSettingsController()
      for pass in 1...6 {
        do {
          try settings.close()
          try settings.openLocalNetworkPage()
          let rows = try settings.permissionRows()
          let off = rows.filter { wanted.contains($0.index) && $0.state == .off }
          log.write("restore pass \(pass): \(off.count) to switch on: \(off.map(\.label))")
          if off.isEmpty { try settings.close(); return EXIT_SUCCESS }
          var done = Set<String>()
          for row in off where !done.contains(row.label) {
            // Linked same-named rows follow one press.
            guard try settings.permissionRow(at: row.index).state == .off else { continue }
            try settings.pressToggle(at: row.index, expecting: RowKey(label: row.label))
            done.insert(row.label)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline,
              (try? settings.permissionRow(at: row.index).state) != .on
            {
              SystemSettingsController.pause(0.05)
            }
            SystemSettingsController.pause(0.4)
          }
        } catch {
          log.write("restore pass \(pass) error: \(error.localizedDescription)")
        }
      }
      try? settings.close()
      return EXIT_FAILURE
    }
    if let flag = arguments.firstIndex(of: "--press-once") {
      // Maintenance: press one switch and report every row afterwards.
      let index = Int(arguments[flag + 1]) ?? -1
      let settings = SystemSettingsController()
      var out = ""
      do {
        try settings.close()
        try settings.openLocalNetworkPage()
        if index >= 0 {
          let row = try settings.permissionRow(at: index)
          try settings.pressToggle(at: index, expecting: RowKey(label: row.label))
          SystemSettingsController.pause(1.5)
        }
        out = try settings.permissionRows().map { "\($0.index):\($0.label)=\($0.state == .on ? 1 : 0)" }
          .joined(separator: "\n")
        try settings.close()
      } catch { out += "error: \(error)" }
      try? out.write(toFile: value(after: "--report", in: arguments) ?? "/dev/stdout", atomically: true, encoding: .utf8)
      return EXIT_SUCCESS
    }
    if let flag = arguments.firstIndex(of: "--probe-press") {
      return probePress(
        index: Int(arguments[flag + 1]) ?? 0, reportPath: value(after: "--report", in: arguments) ?? "/dev/stdout")
    }
    if let flag = arguments.firstIndex(of: "--crash-child") {
      return crashChild(storePath: arguments[flag + 1])
    }
    let reportPath = value(after: "--report", in: arguments)
    let stressCount = Int(value(after: "--stress", in: arguments) ?? "") ?? 10
    let only = value(after: "--only", in: arguments)?.split(separator: ",").map(String.init)

    instanceLockForScenarios = SingleInstanceLock(path: SingleInstanceLock.defaultPath)
    guard instanceLockForScenarios != nil else {
      print("self-test: another copy is running")
      return EXIT_FAILURE
    }
    guard AccessibilityPermission.isTrusted else {
      print("self-test: FAIL: this app needs Accessibility access")
      return EXIT_FAILURE
    }
    guard UserSession.current().isInteractive else {
      print("self-test: FAIL: unlock the Mac first; System Settings is not automatable while locked")
      return EXIT_FAILURE
    }
    try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

    var lines: [String] = []
    func record(_ line: String) {
      print(line)
      fflush(stdout)
      log.write("self-test: " + line)
      lines.append(line)
    }

    do {
      baseline = try readStates()
    } catch {
      record("FAIL baseline: \(error.localizedDescription)")
      return EXIT_FAILURE
    }
    let enabled = baseline.filter { $0.value == .on }.map(\.key.description).sorted()
    record("baseline: \(baseline.count) permissions, \(enabled.count) enabled: \(enabled)")
    guard !enabled.isEmpty else {
      record("FAIL baseline: at least one enabled Local Network permission is needed to test")
      return EXIT_FAILURE
    }

    var failures = 0
    for scenario in scenarios(stressCount: stressCount)
    where only == nil || only!.contains(scenario.name) {
      let started = Date()
      do {
        let detail = try scenario.body()
        try verifyBaseline()
        record(
          String(format: "PASS %@ (%.1fs) %@", scenario.name, Date().timeIntervalSince(started), detail))
      } catch {
        failures += 1
        record("FAIL \(scenario.name): \(error.localizedDescription)")
        restoreBaseline(record: record)
      }
    }

    if !durations.isEmpty {
      let sorted = durations.sorted()
      record(
        String(
          format: "timing: %d full runs, min %.2fs, median %.2fs, max %.2fs", sorted.count,
          sorted.first!, sorted[sorted.count / 2], sorted.last!))
    }
    record(failures == 0 ? "self-test: ALL PASSED" : "self-test: \(failures) FAILED")
    if let reportPath {
      try? lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE
  }

  // MARK: Scenarios

  static func scenarios(stressCount: Int) -> [Scenario] {
    [
      Scenario(name: "round-trip") {
        let result = try runReset()
        let expected = Set(baseline.filter { $0.value == .on }.keys)
        guard Set(result.report.reset) == expected else {
          throw Failure("reset \(result.report.reset) but expected \(expected)")
        }
        return String(format: "%d permissions in %.2fs", result.report.reset.count, result.duration)
      },

      Scenario(name: "single-window-verification") {
        let settings = InterceptingSession(base: SystemSettingsController())
        var openedPID: pid_t?
        var processChanged = false
        settings.afterOpen = { openedPID = settingsPID() }
        settings.beforeClose = {
          if let openedPID, settingsPID() != openedPID { processChanged = true }
        }
        let result = try runReset(session: settings)
        guard result.attempts == 1, settings.openCount == 1, settings.closeCount == 2,
          openedPID != nil, !processChanged
        else {
          throw Failure("normal run reopened Settings or changed its process: \(settings.openCount) opens, \(settings.closeCount) closes")
        }
        return "one Settings process and one open; final verification stayed on the page"
      },

      Scenario(name: "scroll-unchanged") {
        // Observe the production runner, including its recovery and pacing.
        let settings = InterceptingSession(base: SystemSettingsController())
        var before: Double?
        var differences: [String] = []
        var pageOpen = false
        settings.afterOpen = {
          before = try settings.base.permissionScrollValue()
          pageOpen = true
        }
        settings.beforeClose = {
          guard pageOpen else { return }
          pageOpen = false
          let after = try settings.base.permissionScrollValue()
          if before != after {
            differences.append("\(String(describing: before)) to \(String(describing: after))")
          }
        }
        settings.afterPress = { _ in
          let after = try? settings.base.permissionScrollValue()
          if before != after {
            differences.append("\(String(describing: before)) to \(String(describing: after))")
          }
        }
        let result = try runReset(session: settings)
        guard differences.isEmpty else {
          throw Failure("scroll moved: \(differences.joined(separator: "; "))")
        }
        return "\(settings.pressCount) presses; scroll unchanged; \(result.attempts) attempt(s)"
      },

      Scenario(name: "settings-open-on-other-pane") {
        NSWorkspace.shared.open(SystemSettingsController.accessibilityURL)
        SystemSettingsController.pause(2)
        let result = try runReset()
        return String(format: "%.2fs", result.duration)
      },

      Scenario(name: "settings-already-on-local-network") {
        let settings = SystemSettingsController()
        try settings.close()
        try settings.openLocalNetworkPage()
        let result = try runReset()
        return String(format: "%.2fs", result.duration)
      },

      Scenario(name: "settings-hung") {
        // A frozen System Settings ignores SIGTERM; it must be force-quit.
        NSWorkspace.shared.open(SystemSettingsController.privacyURL)
        let pid = try waitForSettingsProcess()
        SystemSettingsController.pause(1)
        kill(pid, SIGSTOP)
        let result = try runReset()
        guard !SystemSettingsControllerIsAlive(pid) else {
          throw Failure("the frozen System Settings process survived")
        }
        return String(format: "frozen process replaced; %.2fs", result.duration)
      },

      Scenario(name: "settings-killed-mid-reset") {
        // System Settings dies after the first switch is turned off. The
        // attempt must fail fast and the retry must re-enable everything.
        let settings = InterceptingSession(base: SystemSettingsController())
        settings.afterPress = { count in
          if count == 1, let pid = settingsPID() { kill(pid, SIGKILL) }
        }
        let result = try runReset(session: settings)
        guard result.attempts == 2 else {
          throw Failure("expected a retry, but used \(result.attempts) attempt(s)")
        }
        return String(format: "recovered on attempt 2 in %.2fs", result.duration)
      },

      Scenario(name: "app-crash-mid-reset") {
        // The app itself is killed with a switch turned off. The next run
        // must find that permission in its recovery file and re-enable it.
        try? FileManager.default.removeItem(at: storeURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--self-test", "--crash-child", storeURL.path]
        try child.run()
        child.waitUntilExit()
        guard child.terminationStatus == 9 else {
          throw Failure("crash child exited with \(child.terminationStatus), expected 9")
        }
        let states = try readStates()
        let disabled = baseline.filter { $0.value == .on && states[$0.key] == .off }.map(\.key)
        guard !disabled.isEmpty else {
          throw Failure("the simulated crash did not leave a permission disabled")
        }
        let pending = FileRecoveryStore(url: storeURL).load()
        guard Set(disabled).isSubset(of: pending.keys) else {
          throw Failure("recovery file \(pending) does not cover \(disabled)")
        }
        let result = try runReset()
        guard Set(disabled).isSubset(of: Set(result.report.reset + result.report.recovered)) else {
          throw Failure("\(disabled) were not re-enabled")
        }
        guard FileRecoveryStore(url: storeURL).load().isEmpty else {
          throw Failure("recovery file was not cleared after success")
        }
        return "\(disabled.map(\.description)) left off by the crash were re-enabled"
      },

      Scenario(name: "app-hang-watchdog") {
        // The app freezes mid-reset with a switch off. Its watchdog must
        // force-quit System Settings, relaunch the app, and the relaunched
        // copy must re-enable everything, all without anyone intervening.
        try SystemSettingsController().close()
        let logURL = RunLog.shared.url
        let startSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        let hung = Process()
        hung.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        hung.arguments = []
        hung.environment = ProcessInfo.processInfo.environment.merging(
          ["TLN_SIMULATE_HANG": "1"], uniquingKeysWith: { $1 })
        // The test releases its single-instance lock while the child runs.
        instanceLockForScenarios = nil
        defer { instanceLockForScenarios = SingleInstanceLock(path: SingleInstanceLock.defaultPath) }
        try hung.run()
        let started = Date()
        var sawHang = false, sawUnstick = false, sawRelaunch = false, sawSuccess = false
        while Date().timeIntervalSince(started) < 420 && !sawSuccess {
          SystemSettingsController.pause(2)
          let data = (try? Data(contentsOf: logURL)) ?? Data()
          let text = String(decoding: data.dropFirst(startSize), as: UTF8.self)
          sawHang = text.contains("Simulating a hang")
          sawUnstick = text.contains("Watchdog: no progress")
          sawRelaunch = text.contains("Watchdog: still no progress")
          sawSuccess = sawRelaunch && text.components(separatedBy: "Success in").count > 1
        }
        if hung.isRunning { hung.terminate() }
        guard sawHang, sawUnstick, sawRelaunch, sawSuccess else {
          throw Failure("hang \(sawHang), unstick \(sawUnstick), relaunch \(sawRelaunch), recovered \(sawSuccess)")
        }
        while settingsPID() != nil || NSRunningApplication.runningApplications(
          withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1
        {
          SystemSettingsController.pause(0.5)
          if Date().timeIntervalSince(started) > 480 { break }
        }
        return String(format: "recovered without intervention in %.0fs", Date().timeIntervalSince(started))
      },

      Scenario(name: "wrong-row-guard") {
        // A press aimed at a row that now shows a different app must be refused.
        let settings = SystemSettingsController()
        defer { try? settings.close() }
        try settings.close()
        try settings.openLocalNetworkPage()
        let row = try settings.permissionRows()[0]
        do {
          try settings.pressToggle(
            at: row.index, expecting: RowKey(label: row.label + " (not this app)", identifier: row.identifier))
          throw Failure("a mismatched press was performed")
        } catch LocalNetworkError.rowChanged {}
        SystemSettingsController.pause(0.5)
        guard try settings.permissionRow(at: row.index).state == row.state else {
          throw Failure("the refused press changed \(row.label)")
        }
        return "press on \(row.label) refused"
      },

      Scenario(name: "other-language") {
        // Page detection must not depend on the English "Local Network" title.
        let settings = SystemSettingsController()
        settings.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        let result = try runReset(session: settings)
        guard let title = settings.pageTitle, title != "Local Network" else {
          throw Failure("System Settings did not run in German (title \(String(describing: settings.pageTitle)))")
        }
        return String(format: "German page \"%@\" in %.2fs", title, result.duration)
      },

      Scenario(name: "focus-stolen-during-reset") {
        // Another app repeatedly takes focus while switches are pressed.
        let stop = StopFlag()
        Thread.detachNewThread {
          while !stop.isSet {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Finder"]
            try? process.run()
            process.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.2)
          }
        }
        defer { stop.set() }
        let result = try runReset()
        return String(format: "%.2fs", result.duration)
      },

      Scenario(name: "single-instance") {
        // A second copy (e.g. login item plus manual launch) must exit
        // without touching System Settings while this one holds the lock.
        try SystemSettingsController().close()
        let second = Process()
        second.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        second.arguments = ["--integration-test"]
        let started = Date()
        try second.run()
        while second.isRunning && Date().timeIntervalSince(started) < 10 {
          SystemSettingsController.pause(0.1)
        }
        if second.isRunning {
          second.terminate()
          throw Failure("the second copy kept running")
        }
        guard second.terminationStatus == 0, settingsPID() == nil else {
          throw Failure("the second copy exited \(second.terminationStatus) or opened System Settings")
        }
        return String(format: "second copy exited in %.2fs", Date().timeIntervalSince(started))
      },

      Scenario(name: "stress") {
        var times: [TimeInterval] = []
        for iteration in 1...stressCount {
          do {
            times.append(try runReset().duration)
          } catch {
            throw Failure("iteration \(iteration): \(error.localizedDescription)")
          }
        }
        return String(
          format: "%d consecutive runs, slowest %.2fs", stressCount, times.max() ?? 0)
      },
    ]
  }

  // MARK: Helpers

  @discardableResult
  static func runReset(session: SettingsSession? = nil) throws -> RunResult {
    let session = session ?? {
      let settings = SystemSettingsController()
      settings.diagnosticLog = { log.write("  " + $0) }
      return settings
    }()
    let runner = ResetRunner(
      session: session,
      store: FileRecoveryStore(url: storeURL),
      log: { log.write("  " + $0) },
      sleep: SystemSettingsController.pause
    )
    runner.isInteractive = { UserSession.current().isInteractive }
    runner.waitForUnlock = { UserSession.waitUntilInteractive(sleep: SystemSettingsController.pause) }
    runner.onAttemptFailure = { attempt, _ in
      if let file = log.writeDiagnostic(session.diagnosticDump(), name: "Self-test failure attempt \(attempt)") {
        log.write("  Saved diagnostics to \(file.lastPathComponent)")
      }
    }
    let result = try runner.run()
    durations.append(result.duration)
    return result
  }

  static func readStates() throws -> [RowKey: ToggleState] {
    let settings = SystemSettingsController()
    defer { try? settings.close() }
    try settings.close()
    try settings.openLocalNetworkPage()
    return Dictionary(
      try settings.permissionRows().keyed().map { ($0.key, $0.row.state) },
      uniquingKeysWith: { first, _ in first })
  }

  static func verifyBaseline() throws {
    let states = try readStates()
    let differences = baseline.compactMap { key, state -> String? in
      states[key] == state ? nil : "\(key) is \(String(describing: states[key])), expected \(state)"
    }
    guard differences.isEmpty else {
      throw Failure("switches differ from baseline: \(differences.joined(separator: "; "))")
    }
  }

  /// Only ever switches permissions on, one press at a time, each checked
  /// in a freshly opened System Settings. Never used for resetting.
  static func restoreBaseline(record: (String) -> Void) {
    for pid in settingsPIDs() { kill(pid, SIGCONT) }
    let wanted = Set(baseline.filter { $0.value == .on }.keys)
    let settings = SystemSettingsController()
    defer { try? settings.close() }
    for pass in 1...6 {
      do {
        try settings.close()
        try settings.openLocalNetworkPage()
        let off = try settings.permissionRows().keyed()
          .filter { wanted.contains($0.key) && $0.row.state == .off }
        if off.isEmpty {
          record("  restored baseline after failure (pass \(pass))")
          return
        }
        var pressedLabels = Set<String>()
        for (key, row) in off where !pressedLabels.contains(key.label) {
          // Linked same-named rows follow one press.
          guard try settings.permissionRow(at: row.index).state == .off else { continue }
          try settings.pressToggle(at: row.index, expecting: key)
          pressedLabels.insert(key.label)
          let deadline = Date().addingTimeInterval(3)
          while Date() < deadline, (try? settings.permissionRow(at: row.index).state) != .on {
            SystemSettingsController.pause(0.05)
          }
          SystemSettingsController.pause(0.4)
        }
      } catch {
        record("  restore pass \(pass) error: \(error.localizedDescription)")
      }
    }
    record("  WARNING: could not restore baseline; check Local Network settings")
  }


  static func crashChild(storePath: String) -> Int32 {
    let settings = InterceptingSession(base: SystemSettingsController())
    settings.afterPress = { count in
      guard count == 1 else { return }
      // Wait until System Settings shows the switch off, then die abruptly.
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if let rows = try? settings.permissionRows(),
          rows.contains(where: { $0.index == settings.lastPressedIndex && $0.state == .off })
        {
          break
        }
        SystemSettingsController.pause(0.05)
      }
      _exit(9)
    }
    let runner = ResetRunner(
      session: settings, store: FileRecoveryStore(url: URL(fileURLWithPath: storePath)))
    _ = try? runner.run()
    return EXIT_FAILURE
  }

  static func waitForSettingsProcess() throws -> pid_t {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let pid = settingsPID() { return pid }
      SystemSettingsController.pause(0.1)
    }
    throw Failure("System Settings did not launch")
  }

  static func settingsPIDs() -> [pid_t] {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: SystemSettingsController.bundleIdentifier
    ).map(\.processIdentifier).filter(SystemSettingsControllerIsAlive)
  }

  static func settingsPID() -> pid_t? { settingsPIDs().first }

  static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }
}

func SystemSettingsControllerIsAlive(_ pid: pid_t) -> Bool {
  kill(pid, 0) == 0 || errno == EPERM
}

final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

/// Forwards to System Settings while letting a scenario inject failures
/// immediately after a switch is pressed.
@MainActor
final class InterceptingSession: SettingsSession {
  let base: SystemSettingsController
  var afterOpen: (() throws -> Void)?
  var beforeClose: (() throws -> Void)?
  var afterPress: ((Int) -> Void)?
  private(set) var pressCount = 0
  private(set) var lastPressedIndex = -1
  private(set) var openCount = 0
  private(set) var closeCount = 0

  init(base: SystemSettingsController) {
    self.base = base
  }

  func close() throws {
    closeCount += 1
    try beforeClose?()
    try base.close()
  }
  func openLocalNetworkPage() throws {
    openCount += 1
    try base.openLocalNetworkPage()
    try afterOpen?()
  }
  func diagnosticDump() -> String { base.diagnosticDump() }
  func permissionRows() throws -> [PermissionRow] { try base.permissionRows() }
  func permissionRow(at index: Int) throws -> PermissionRow { try base.permissionRow(at: index) }

  func pressToggle(at index: Int, expecting key: RowKey) throws {
    try base.pressToggle(at: index, expecting: key)
    pressCount += 1
    lastPressedIndex = index
    afterPress?(pressCount)
  }
}

extension SelfTest {
  /// Presses one switch and records how every row reacts, then restores it.
  static func probePress(index: Int, reportPath: String) -> Int32 {
    var out = ""
    func snapshot(_ settings: SystemSettingsController) -> [String] {
      ((try? settings.permissionRows()) ?? []).map { "\($0.index):\($0.label)=\($0.state == .on ? 1 : 0)" }
    }
    func diff(_ a: [String], _ b: [String]) -> String {
      zip(a, b).filter { $0 != $1 }.map { "\($0) -> \($1)" }.joined(separator: ", ")
    }
    let settings = SystemSettingsController()
    do {
      try settings.close()
      try settings.openLocalNetworkPage()
      let before = snapshot(settings)
      let row = try settings.permissionRow(at: index)
      out += "pressing \(index) \(row.label) (was \(row.state))\n"
      try settings.pressToggle(at: index, expecting: RowKey(label: row.label))
      for delay in [0.2, 0.5, 1.0, 2.0] {
        SystemSettingsController.pause(delay)
        out += "after +\(delay)s: \(diff(before, snapshot(settings)))\n"
      }
      try settings.pressToggle(at: index, expecting: RowKey(label: row.label))
      for delay in [0.5, 1.5] {
        SystemSettingsController.pause(delay)
        out += "after restore +\(delay)s: \(diff(before, snapshot(settings)))\n"
      }
      try settings.close()
      try settings.openLocalNetworkPage()
      out += "after relaunch: \(diff(before, snapshot(settings)))\n"
      try settings.close()
    } catch {
      out += "error: \(error)\n"
    }
    try? out.write(toFile: reportPath, atomically: true, encoding: .utf8)
    return EXIT_SUCCESS
  }
}

/// Exposes only the named apps, so experiments touch a few permissions.
@MainActor
final class FilteredSession: SettingsSession {
  let base: SystemSettingsController
  let names: Set<String>

  init(base: SystemSettingsController, names: Set<String>) {
    self.base = base
    self.names = names
  }

  func close() throws { try base.close() }
  func openLocalNetworkPage() throws { try base.openLocalNetworkPage() }
  func diagnosticDump() -> String { base.diagnosticDump() }
  func permissionRows() throws -> [PermissionRow] {
    try base.permissionRows().filter { names.contains($0.label) }
  }
  func permissionRow(at index: Int) throws -> PermissionRow { try base.permissionRow(at: index) }
  func pressToggle(at index: Int, expecting key: RowKey) throws {
    guard names.contains(key.label) else { throw LocalNetworkError.rowChanged(index) }
    try base.pressToggle(at: index, expecting: key)
  }
}
