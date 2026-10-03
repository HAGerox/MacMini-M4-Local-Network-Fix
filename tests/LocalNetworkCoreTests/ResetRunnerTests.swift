import XCTest

@testable import LocalNetworkCore

@MainActor
final class ResetRunnerTests: XCTestCase {
  private var clock: FakeClock!
  private var store: MemoryRecoveryStore!
  private var messages: [String] = []

  override func setUp() async throws {
    clock = FakeClock()
    store = MemoryRecoveryStore()
    messages = []
  }

  func testSuccessClosesSettingsBeforeAndAfter() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 1)
    // One open, with closes only before and after the complete reset.
    XCTAssertEqual(settings.closeCount, 2)
    XCTAssertEqual(settings.openCount, 1)
    XCTAssertFalse(settings.running)
  }

  func testNavigationFailureRetriesWithFreshSettings() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    settings.failNextOpens = 2
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 3)
    XCTAssertEqual(settings.openCount, 3)
    XCTAssertEqual(settings.states(), ["QLab": .on])
  }

  func testLateMismatchDuringInvisibleVerificationTriggersRecovery() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on), ("Safari", .off)])
    // Initial list, end-of-reset list, enabled check, first full verification
    // snapshot, then a later snapshot reveals that QLab did not stay on.
    settings.afterFullRead = { count in
      if count == 5 { settings.force("QLab", .off) }
    }
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 2)
    XCTAssertEqual(settings.openCount, 2, "reopening happens only after the mismatch")
    XCTAssertEqual(settings.states(), ["QLab": .on, "Safari": .off])
    XCTAssertEqual(settings.pressCount("Safari"), 0)
    XCTAssertTrue(messages.contains { $0.contains("Attempt 1 failed") })
  }

  func testGivesUpAfterConfiguredAttempts() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    settings.failNextOpens = 10
    var failures: [Int] = []
    let runner = runner(settings)
    runner.onAttemptFailure = { attempt, _ in failures.append(attempt) }
    XCTAssertThrowsError(try runner.run()) { error in
      XCTAssertEqual(error as? LocalNetworkError, .localNetworkPageNotFound)
    }
    XCTAssertEqual(failures, [1, 2, 3])
    XCTAssertFalse(settings.running)
  }

  func testSettingsCrashingMidResetIsRecoveredByTheNextAttempt() throws {
    let settings = FakeSystemSettings(
      clock: clock, apps: [("QLab", .on), ("Eos", .on), ("Safari", .off)])
    var crashed = false
    settings.afterPress = { _ in
      if !crashed {
        crashed = true
        settings.crash()
      }
    }
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 2)
    XCTAssertEqual(settings.states(), ["QLab": .on, "Eos": .on, "Safari": .off])
    XCTAssertEqual(settings.pressCount("Safari"), 0)
    XCTAssertTrue(store.keys.isEmpty, "recovery state is cleared after success")
  }

  func testRecoveryStateIsSavedBeforeTheFirstPress() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on), ("Safari", .off)])
    var savedBeforePress: Set<RowKey>?
    settings.afterPress = { [store] count in
      if count == 1 { savedBeforePress = store!.keys }
    }
    try runner(settings).run()
    XCTAssertEqual(savedBeforePress, [RowKey(label: "QLab")])
    XCTAssertEqual(store.cleared, 1)
  }

  func testInterruptedRunIsRepairedOnNextLaunch() throws {
    store.state = RecoveryState(keys: [RowKey(label: "QLab"), RowKey(label: "Uninstalled app")])
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .off), ("Safari", .off)])
    let result = try runner(settings).run()
    XCTAssertEqual(result.report.recovered, [RowKey(label: "QLab")])
    XCTAssertEqual(settings.states(), ["QLab": .on, "Safari": .off])
    XCTAssertTrue(messages.contains { $0.contains("interrupted") })
  }

  func testUnwritableRecoveryStateDoesNotBlockTheReset() throws {
    store.failSaves = true
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    try runner(settings).run()
    XCTAssertEqual(settings.pressCount("QLab"), 2)
    XCTAssertTrue(messages.contains { $0.contains("Could not save recovery state") })
  }

  func testRevokedAccessibilityIsNotRetried() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    settings.accessibilityRevoked = true
    XCTAssertThrowsError(try runner(settings).run()) { error in
      XCTAssertEqual(error as? LocalNetworkError, .accessibilityRequired)
    }
    XCTAssertEqual(settings.openCount, 1)
  }

  func testSettingsRefusingToCloseAfterSuccessIsNotAFailure() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on)])
    let runner = runner(settings)
    settings.closeFailsFromOpen = 1  // only the close after the reset
    let result = try runner.run()
    XCTAssertEqual(result.attempts, 1)
    XCTAssertTrue(messages.contains { $0.contains("did not close afterwards") })
  }

  func testIgnoredPressIsRecoveredInAFreshSession() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on), ("Eos", .on)])
    settings.droppedPresses = 1
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 2)
    XCTAssertEqual(settings.states(), ["QLab": .on, "Eos": .on])
  }

  func testStuckSwitchIsReportedAndEverythingElseEnabled() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("A", .on), ("B", .on), ("C", .on)])
    settings.afterPress = { count in
      if count == 3 { settings.setStuck("B") }  // B is now off and frozen
    }
    XCTAssertThrowsError(try runner(settings).run()) { error in
      let failure = error as? ResetFailure
      XCTAssertEqual(failure?.possiblyDisabled, ["B"])
      XCTAssertTrue(failure?.localizedDescription.contains("may still be disabled: B") ?? false)
    }
    XCTAssertEqual(settings.states(), ["A": .on, "B": .off, "C": .on])
    XCTAssertTrue(messages.contains { $0.contains("Final check") })
  }

  func testLinkedGroupEndsEnabledWhenAnotherAppIsStuck() throws {
    let settings = FakeSystemSettings(
      clock: clock, apps: [("CapCom", .on), ("CapCom", .on), ("QLab", .on)])
    settings.linkedNames = ["CapCom"]
    settings.afterPress = { count in
      if count == 3 { settings.setStuck("QLab") }  // QLab is now off and frozen
    }
    XCTAssertThrowsError(try runner(settings).run()) { error in
      XCTAssertEqual((error as? ResetFailure)?.possiblyDisabled, ["QLab"])
    }
    XCTAssertEqual(settings.apps.filter { $0.label == "CapCom" }.map(\.state), [.on, .on])
  }

  func testFailedRunWithEverythingRestoredSaysSo() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("A", .on)])
    settings.failNextOpens = 3
    XCTAssertThrowsError(try runner(settings).run()) { error in
      XCTAssertEqual(error as? LocalNetworkError, .localNetworkPageNotFound)
    }
    XCTAssertEqual(settings.states(), ["A": .on])
  }

  func testStaleDisplayIsCaughtByTheFreshCheck() throws {
    // System Settings shows a switch as on while it is really off. Only a
    // freshly opened System Settings reveals it; it must then be fixed.
    let settings = FakeSystemSettings(clock: clock, apps: [("CapCom", .on), ("QLab", .on)])
    settings.staleOnDisplay = ["CapCom"]
    let result = try runner(settings, freshVerification: true).run()
    XCTAssertEqual(settings.states(), ["CapCom": .on, "QLab": .on])
    XCTAssertTrue(messages.contains { $0.contains("Fresh check 1: still off") })
    XCTAssertEqual(result.attempts, 1)
  }

  func testPermanentlyStaleSwitchIsReportedNotClaimedFixed() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("CapCom", .on), ("QLab", .on)])
    settings.staleOnDisplay = ["CapCom"]
    settings.staleForever = true
    XCTAssertThrowsError(try runner(settings, freshVerification: true).run()) { error in
      XCTAssertEqual((error as? ResetFailure)?.possiblyDisabled, ["CapCom"])
    }
    XCTAssertEqual(settings.states()["QLab"], .on)
  }

  func testScreenLockMidRunWaitsInsteadOfFailing() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [("QLab", .on), ("Eos", .on)])
    var locked = false
    var waits = 0
    settings.afterPress = { count in
      if count == 1 {
        locked = true
        settings.crash()  // System Settings becomes unusable while locked
      }
    }
    let runner = runner(settings)
    runner.isInteractive = { !locked }
    runner.waitForUnlock = {
      if locked { waits += 1 }
      locked = false
    }
    let result = try runner.run()
    XCTAssertEqual(result.attempts, 1, "a lock is not a failed attempt")
    XCTAssertEqual(waits, 1)
    XCTAssertEqual(settings.states(), ["QLab": .on, "Eos": .on])
  }

  // MARK: Pacing learned from System Settings, not fixed delays

  private func apps(_ count: Int) -> [(String, ToggleState)] {
    (1...count).map { ("App \($0)", ToggleState.on) }
  }

  func testFastSystemSettingsIsResetQuickly() throws {
    let settings = FakeSystemSettings(clock: clock, apps: apps(20))
    settings.pressLatency = 0.05
    let started = clock.now
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 1)
    XCTAssertLessThan(clock.now.timeIntervalSince(started), 10, "no fixed delays slow a fast Mac")
  }

  func testVerySlowSystemSettingsIsWaitedForWithoutRetrying() throws {
    // Every change takes 4 s to appear: slower than any old fixed timing.
    let settings = FakeSystemSettings(clock: clock, apps: apps(5))
    settings.pressLatency = 4
    let result = try runner(settings).run()
    XCTAssertEqual(result.attempts, 1)
    XCTAssertEqual(settings.pressLog.count, 10, "each switch pressed exactly twice")
    XCTAssertEqual(Set(settings.states().values), [.on])
  }

  func testPressesNeverArriveBeforeSystemSettingsHasSettled() throws {
    // System Settings drops presses that come within 0.3 s of a change
    // appearing, and takes 0.4 s to show each change.
    let settings = FakeSystemSettings(clock: clock, apps: apps(12))
    settings.pressLatency = 0.4
    settings.dropsPressesWithin = 0.3
    let result = try runner(settings).run()
    XCTAssertEqual(settings.tooSoonPresses, 0)
    XCTAssertEqual(result.attempts, 1)
  }

  func testLinkedGroupsUseTheSameSettlingWaitAsIndividualApps() throws {
    let settings = FakeSystemSettings(clock: clock, apps: [
      ("QLab", .on), ("Python", .on), ("Python", .on),
      ("CapCom", .on), ("CapCom", .on), ("Safari", .off),
    ])
    settings.linkedNames = ["Python", "CapCom"]
    settings.pressLatency = 0.4
    settings.dropsPressesWithin = 0.3
    let result = try runner(settings).run()
    XCTAssertEqual(settings.tooSoonPresses, 0)
    XCTAssertEqual(result.attempts, 1)
    XCTAssertEqual(settings.pressLog.count, 6, "one off/on pair for each linked group")
    XCTAssertEqual(settings.apps.map(\.state), [.on, .on, .on, .on, .on, .off])
  }

  func testSystemSettingsSlowingDownMidRunStillSucceeds() throws {
    // Fast at first, then twenty times slower (e.g. the Mac gets busy).
    let settings = FakeSystemSettings(clock: clock, apps: apps(10))
    settings.latencyForPress = { $0 < 8 ? 0.1 : 2 }
    let runner = runner(settings)
    runner.traceEnabled = ProcessInfo.processInfo.environment["TLN_DEBUG"] == "1"
    let result = try runner.run()
    if runner.traceEnabled { print(messages.joined(separator: "\n")) }
    XCTAssertEqual(Set(settings.states().values), [.on])
    XCTAssertLessThanOrEqual(result.attempts, 2, "at worst one retry in a fresh System Settings, which then adapts")
  }

  func testWorstCaseFailureIsBounded() throws {
    // Every switch is stuck: the run must still end, within a bounded time.
    let settings = FakeSystemSettings(clock: clock, apps: [("A", .on), ("B", .on)])
    settings.afterPress = { _ in
      settings.setStuck("A")
      settings.setStuck("B")
    }
    let started = clock.now
    XCTAssertThrowsError(try runner(settings).run())
    XCTAssertLessThan(clock.now.timeIntervalSince(started), 300)
  }

  private func runner(_ settings: FakeSystemSettings, freshVerification: Bool = false) -> ResetRunner {
    ResetRunner(
      session: settings,
      store: store,
      configuration: RunnerConfiguration(verifyInFreshSession: freshVerification),
      log: { [weak self] in self?.messages.append($0) },
      now: { [clock] in clock!.now },
      sleep: { [clock] in clock!.sleep($0) }
    )
  }
}

final class EnvironmentTests: XCTestCase {
  func testWaitsWhileLockedAndResumesWhenUnlocked() {
    var states = [
      UserSession.State(onConsole: true, locked: true, loginDone: true),
      UserSession.State(onConsole: false, locked: false, loginDone: true),
      UserSession.State(onConsole: true, locked: false, loginDone: true),
    ]
    var notified: [UserSession.State] = []
    let polls = UserSession.waitUntilInteractive(
      state: { states.removeFirst() }, sleep: { _ in }, onWait: { notified.append($0) })
    XCTAssertEqual(polls, 2)
    XCTAssertEqual(notified.count, 1)
  }

  func testDoesNotWaitWhenUnlocked() {
    let polls = UserSession.waitUntilInteractive(
      state: { UserSession.State(onConsole: true, locked: false, loginDone: true) },
      sleep: { _ in XCTFail("should not sleep") })
    XCTAssertEqual(polls, 0)
  }

  func testSingleInstanceLockExcludesASecondHolder() throws {
    let path = NSTemporaryDirectory() + "tln-lock-\(UUID().uuidString)/instance.lock"
    var first = SingleInstanceLock(path: path)
    XCTAssertNotNil(first)
    XCTAssertNil(SingleInstanceLock(path: path))
    first = nil
    XCTAssertNotNil(SingleInstanceLock(path: path))
  }

  func testFileRecoveryStoreRoundTripsAndToleratesCorruption() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tln-\(UUID().uuidString)/pending.json")
    let store = FileRecoveryStore(url: url)
    XCTAssertEqual(store.load(), RecoveryState())
    let state = RecoveryState(
      keys: [RowKey(label: "QLab"), RowKey(label: "node", occurrence: 1)],
      groupSizes: [RowKey(label: "QLab"): 1, RowKey(label: "node"): 2])
    try store.save(state)
    XCTAssertEqual(store.load(), state)
    try Data("not json".utf8).write(to: url)
    XCTAssertEqual(store.load(), RecoveryState())
    store.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testLogAppendsAndKeepsOnlyRecentDiagnostics() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tln-log-\(UUID().uuidString)")
    let log = RunLog(directory: directory)
    log.echoToStandardError = false
    log.write("first")
    log.write("second")
    let contents = try String(contentsOf: log.url, encoding: .utf8)
    XCTAssertTrue(contents.contains("first") && contents.contains("second"))
    for index in 0..<8 {
      log.writeDiagnostic("dump \(index)", name: "Failure")
      Thread.sleep(forTimeInterval: 0.002)
    }
    let dumps = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("Failure") }
    XCTAssertEqual(dumps.count, 5)
  }
}

final class WatchdogTests: XCTestCase {
  func testStalenessResetsOnBeatAndIsHiddenWhileSuspended() {
    let watchdog = Watchdog()
    watchdog.beat()
    XCTAssertLessThan(watchdog.staleness ?? 99, 1)
    watchdog.suspend()
    XCTAssertNil(watchdog.staleness)
    watchdog.resume()
    XCTAssertNotNil(watchdog.staleness)
  }

  func testUnsticksThenGivesUpWhenNoProgress() {
    let watchdog = Watchdog()
    let unstuck = expectation(description: "unstick")
    let gaveUp = expectation(description: "give up")
    watchdog.start(firstStage: 1, secondStage: 3, unstick: { unstuck.fulfill() }, giveUp: { gaveUp.fulfill() })
    wait(for: [unstuck, gaveUp], timeout: 15, enforceOrder: true)
  }
}

@MainActor
final class LocalisationTests: XCTestCase {
  func testLocalNetworkIsRecognisedInOtherLanguages() {
    let names = SystemSettingsController.localNetworkNames
    XCTAssertTrue(names.contains("Local Network"))
    XCTAssertGreaterThan(names.count, 10, "translations should be read from macOS")
    for name in ["Lokales Netzwerk", "Réseau local", "Red local"] {
      XCTAssertTrue(names.contains(name), name)
    }
    XCTAssertTrue(SystemSettingsController.isLocalNetworkNavigator(identifier: "Lokales Netzwerk_Navigator"))
    XCTAssertFalse(SystemSettingsController.isLocalNetworkNavigator(identifier: "Bluetooth_Navigator"))
    XCTAssertFalse(SystemSettingsController.isLocalNetworkNavigator(identifier: "Local Network"))
  }
}
