import AppKit
import Foundation
import LocalNetworkCore

@main
@MainActor
struct ToggleLocalNetworkApp {
  static let log = RunLog.shared

  static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()

    let arguments = CommandLine.arguments
    if arguments.contains("--version") {
      print(versionDescription)
      exit(EXIT_SUCCESS)
    }
    if let flag = arguments.firstIndex(of: "--dump-accessibility") {
      let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : nil
      exit(dumpAccessibility(to: path))
    }
    if arguments.contains("--self-test") {
      exit(SelfTest.main(arguments: arguments))
    }
    exit(run(interactive: !arguments.contains("--integration-test")))
  }

  static var versionDescription: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "development"
    let build = info["CFBundleVersion"] as? String ?? "0"
    return "Toggle Local Network \(version) (\(build))"
  }

  /// Runs a reset. Non-interactive mode never shows dialogs and reports
  /// through the exit status, for integration tests and scripting.
  static func run(interactive: Bool) -> Int32 {
    guard let instanceLock = SingleInstanceLock(path: SingleInstanceLock.defaultPath) else {
      log.write("Another copy is already running; exiting.")
      return EXIT_SUCCESS
    }
    defer { withExtendedLifetime(instanceLock) {} }

    log.write(
      "\(versionDescription) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    )
    UserSession.waitUntilInteractive(onWait: { state in
      log.write(
        "Waiting for the desktop to be unlocked (locked: \(state.locked), on console: \(state.onConsole))."
      )
    })

    if !AccessibilityPermission.isTrusted {
      log.write("Requesting Accessibility access.")
      AccessibilityPermission.requestSystemPrompt()
      var granted = AccessibilityPermission.waitWhileSystemPromptIsHandled(
        timeout: interactive ? 120 : 5)
      if !granted && interactive {
        granted = guideToAccessibility()
      }
      guard granted else {
        log.write("Accessibility access was not granted.")
        return EXIT_FAILURE
      }
      log.write("Accessibility access granted.")
    }

    startWatchdog()
    let settings = SystemSettingsController()
    settings.diagnosticLog = log.write
    while true {
      let runner = ResetRunner(
        session: sessionForRun(settings),
        store: FileRecoveryStore(url: FileRecoveryStore.defaultURL),
        log: log.write,
        sleep: SystemSettingsController.pause
      )
      runner.isInteractive = { UserSession.current().isInteractive }
      runner.waitForUnlock = {
        UserSession.waitUntilInteractive(
          sleep: SystemSettingsController.pause,
          onWait: { _ in log.write("Waiting for the Mac to be unlocked.") })
      }
      runner.onAttemptFailure = { attempt, _ in
        if let file = log.writeDiagnostic(settings.diagnosticDump(), name: "Failure attempt \(attempt)") {
          log.write("Saved diagnostics to \(file.path)")
        }
      }

      do {
        let result = try runner.run()
        let names = result.report.reset.map(\.description).joined(separator: ", ")
        log.write(
          String(
            format: "Success in %.2fs (%d attempt%@): %@", result.duration, result.attempts,
            result.attempts == 1 ? "" : "s", names.isEmpty ? "no enabled permissions" : names))
        if !result.report.ambiguous.isEmpty && interactive {
          showAmbiguousWarning(result.report.ambiguous)
        }
        if !interactive {
          print(
            String(
              format: "integration: PASS (%d enabled toggles, %.2fs)", result.report.reset.count,
              result.duration))
        }
        return EXIT_SUCCESS
      } catch {
        log.write("Reset failed: \(error.localizedDescription)")
        guard interactive else {
          fputs("integration: FAIL: \(error.localizedDescription)\n", stderr)
          return EXIT_FAILURE
        }
        if case LocalNetworkError.accessibilityRequired = error {
          guard guideToAccessibility() else { return EXIT_FAILURE }
          continue
        }
        if !showFailure(error) {
          return EXIT_FAILURE
        }
        log.write("Retrying at the user's request.")
      }
    }
  }

  /// Test hook: TLN_SIMULATE_HANG=1 freezes the app right after its first
  /// press, with that switch off, to prove the watchdog recovers.
  static func sessionForRun(_ settings: SystemSettingsController) -> SettingsSession {
    guard ProcessInfo.processInfo.environment["TLN_SIMULATE_HANG"] == "1" else { return settings }
    let session = InterceptingSession(base: settings)
    session.afterPress = { count in
      if count == 1 {
        log.write("Simulating a hang (test only).")
        Thread.sleep(forTimeInterval: 100_000)
      }
    }
    return session
  }

  /// Last-resort protection against the app ever hanging. A stuck run is
  /// first unblocked by force-quitting System Settings; if that fails, the
  /// app relaunches itself, and the new copy repairs anything left disabled
  /// using the saved recovery state.
  static func startWatchdog() {
    let bundlePath = Bundle.main.bundlePath
    Watchdog.shared.start(
      unstick: {
        RunLog.shared.write("Watchdog: no progress for 90s; force-quitting System Settings.")
        SystemSettingsController.forceQuitFromAnyThread()
      },
      giveUp: {
        RunLog.shared.write("Watchdog: still no progress; relaunching to recover.")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 3; /usr/bin/open -n \"$0\"", bundlePath]
        // The relaunched copy must never inherit a test-only hang.
        var environment = ProcessInfo.processInfo.environment
        environment["TLN_SIMULATE_HANG"] = nil
        relaunch.environment = environment
        try? relaunch.run()
        _exit(EXIT_FAILURE)
      })
  }

  /// Returns true if the person chose to try again.
  static func showFailure(_ error: Error) -> Bool {
    let alert = makeAlert()
    alert.messageText = "Couldn’t reset Local Network permissions"
    alert.informativeText =
      error.localizedDescription
      + "\n\nCheck Privacy & Security > Local Network before relying on network access."
    alert.addButton(withTitle: "Try Again")
    alert.addButton(withTitle: "Open Privacy & Security")
    alert.addButton(withTitle: "Show Log")
    alert.addButton(withTitle: "Quit")
    switch runModal(alert) {
    case .alertFirstButtonReturn:
      return true
    case .alertSecondButtonReturn:
      NSWorkspace.shared.open(SystemSettingsController.privacyURL)
    case .alertThirdButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([log.url])
    default:
      break
    }
    return false
  }

  static func showAmbiguousWarning(_ names: [String]) {
    let alert = makeAlert()
    alert.alertStyle = .warning
    alert.messageText = "Check Local Network for: \(names.joined(separator: ", "))"
    alert.informativeText =
      "An earlier reset was interrupted while one of several apps with this name was switched off, "
      + "and the list has changed since, so it can’t be told which one. Every other permission was reset. "
      + "Make sure the right ones are enabled in Privacy & Security > Local Network."
    alert.addButton(withTitle: "Open Privacy & Security")
    alert.addButton(withTitle: "OK")
    if runModal(alert) == .alertFirstButtonReturn {
      NSWorkspace.shared.open(SystemSettingsController.privacyURL)
    }
  }

  /// Keeps explaining how to grant Accessibility until it is granted or the
  /// person chooses Quit, so a wrong click can never leave the app silently
  /// doing nothing. Closes by itself the moment access is granted.
  static func guideToAccessibility() -> Bool {
    log.write("Showing Accessibility guidance.")
    NSWorkspace.shared.open(SystemSettingsController.accessibilityURL)
    defer { NSApplication.shared.setActivationPolicy(.accessory) }

    while !AccessibilityPermission.isTrusted {
      let alert = makeAlert()
      alert.alertStyle = .informational
      alert.messageText = "Allow Toggle Local Network to use Accessibility"
      alert.informativeText =
        "It needs this to press the Local Network switches in System Settings.\n\n"
        + "In Privacy & Security > Accessibility, switch on Toggle Local Network. "
        + "This message closes and the reset starts as soon as you do.\n\n"
        + "If it is already switched on but this message stays, select it, remove it with the "
        + "− button, then click Open Accessibility Settings and switch it on again when it reappears."
      alert.addButton(withTitle: "Open Accessibility Settings")
      alert.addButton(withTitle: "Quit")

      let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
          if AccessibilityPermission.isTrusted {
            NSApplication.shared.stopModal(withCode: .OK)
          }
        }
      }
      RunLoop.main.add(timer, forMode: .modalPanel)
      let response = runModal(alert)
      timer.invalidate()

      if AccessibilityPermission.isTrusted { break }
      guard response == .alertFirstButtonReturn else { return false }
      // Re-registers the app if it was removed from the list, then shows it.
      AccessibilityPermission.requestSystemPrompt()
      NSWorkspace.shared.open(SystemSettingsController.accessibilityURL)
    }
    return true
  }

  /// Runs an alert without the watchdog treating the wait as a hang.
  static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
    Watchdog.shared.suspend()
    defer { Watchdog.shared.resume() }
    return alert.runModal()
  }

  private static func makeAlert() -> NSAlert {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
    let alert = NSAlert()
    alert.alertStyle = .critical
    return alert
  }

  /// Opens Local Network and saves the full interface tree, for diagnosing
  /// System Settings layouts on testers' Macs.
  static func dumpAccessibility(to path: String?) -> Int32 {
    let settings = SystemSettingsController()
    if let language = ProcessInfo.processInfo.environment["TLN_SETTINGS_LANGUAGE"] {
      settings.launchArguments = ["-AppleLanguages", "(\(language))"]
    }
    var output = "\(versionDescription)\n"
    do {
      try settings.close()
      try settings.openLocalNetworkPage()
      let rows = try settings.permissionRows()
      output += "Rows: \(rows.map { "\($0.label)=\($0.state)" })\n"
    } catch {
      output += "Navigation failed: \(error.localizedDescription)\n"
    }
    for sample in 1...10 {
      let started = Date()
      let result = Result { try settings.permissionRows() }
      output += String(format: "full read %d: %.3fs ", sample, Date().timeIntervalSince(started))
      switch result {
      case .success(let rows): output += "\(rows.count) rows\n"
      case .failure(let error): output += "FAILED \(error)\n"
      }
      SystemSettingsController.pause(0.25)
    }
    output += settings.rowDiagnostics() + "\n"
    output += settings.diagnosticDump()
    try? settings.close()
    if let path {
      try? output.write(toFile: path, atomically: true, encoding: .utf8)
    } else {
      log.writeDiagnostic(output, name: "Accessibility dump")
    }
    return EXIT_SUCCESS
  }
}
