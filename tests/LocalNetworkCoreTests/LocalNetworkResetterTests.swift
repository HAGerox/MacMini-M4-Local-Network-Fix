import XCTest

@testable import LocalNetworkCore

@MainActor
final class LocalNetworkResetterTests: XCTestCase {
  private var clock: FakeClock!

  override func setUp() async throws {
    clock = FakeClock()
  }

  // MARK: Basic behaviour

  func testOnlyEnabledPermissionsAreRoundTripped() throws {
    let settings = fake([("QLab", .on), ("Safari", .off), ("Eos", .on)])

    let report = try resetter(settings).reset()

    XCTAssertEqual(report.reset.map(\.label), ["QLab", "Eos"])
    // One app at a time: each goes off and back on before the next.
    XCTAssertEqual(settings.pressLog, ["QLab", "QLab", "Eos", "Eos"])
    XCTAssertEqual(settings.states(), ["QLab": .on, "Safari": .off, "Eos": .on])
  }

  func testEmptyListSucceedsWithoutPressing() throws {
    let settings = fake([])
    let report = try resetter(settings).reset()
    XCTAssertEqual(report, ResetReport(reset: [], recovered: [], totalRows: 0))
    XCTAssertTrue(settings.pressLog.isEmpty)
  }

  func testAllDisabledSucceedsWithoutPressing() throws {
    let settings = fake([("A", .off), ("B", .off)])
    let report = try resetter(settings).reset()
    XCTAssertTrue(report.reset.isEmpty)
    XCTAssertTrue(settings.pressLog.isEmpty)
  }

  func testManyPermissionsAllReset() throws {
    let apps = (1...60).map { ("App \($0)", $0 % 3 == 0 ? ToggleState.off : .on) }
    let settings = fake(apps)
    let report = try resetter(settings).reset()
    XCTAssertEqual(report.reset.count, 40)
    XCTAssertEqual(settings.states(), Dictionary(uniqueKeysWithValues: apps))
    for (label, state) in apps {
      XCTAssertEqual(settings.pressCount(label), state == .on ? 2 : 0, label)
    }
  }

  func testWillModifyReceivesEveryTargetBeforeTheFirstPress() throws {
    let settings = fake([("A", .on), ("B", .off), ("C", .on)])
    var pressesAtCallback = -1
    var announced = RecoveryState()
    try resetter(settings).reset(willModify: { intent in
      pressesAtCallback = settings.pressLog.count
      announced = intent
    })
    XCTAssertEqual(pressesAtCallback, 0)
    XCTAssertEqual(announced.keys, [RowKey(label: "A"), RowKey(label: "C")])
    XCTAssertEqual(announced.groupSizes[RowKey(label: "A")], 1)
  }

  // MARK: Slow or unreliable System Settings

  func testSlowSwitchIsNotPressedTwice() throws {
    // Slower than the poll interval but faster than the retry interval: a
    // second press would flip the switch back.
    let settings = fake([("A", .on), ("B", .on)])
    settings.pressLatency = 3
    try resetter(settings).reset()
    XCTAssertEqual(settings.pressLog, ["A", "A", "B", "B"])
    XCTAssertEqual(settings.states(), ["A": .on, "B": .on])
  }

  func testPressErrorThatStillTookEffectDoesNotDoublePress() throws {
    let settings = fake([("A", .on)])
    settings.ambiguousPressErrors = 2
    try resetter(settings).reset()
    XCTAssertEqual(settings.pressCount("A"), 2)
    XCTAssertEqual(settings.states(), ["A": .on])
  }

  func testTransientAccessibilityErrorsAreTolerated() throws {
    let settings = fake([("A", .on), ("B", .off), ("C", .on)])
    settings.transientErrorRate = 0.4
    try resetter(settings).reset()
    XCTAssertEqual(settings.states(), ["A": .on, "B": .off, "C": .on])
    XCTAssertEqual(settings.pressCount("B"), 0)
  }

  func testBrieflyFlickeringValueRequiresStableConfirmation() throws {
    let settings = fake([("A", .on), ("B", .on)])
    settings.flapAfterOn = true
    try resetter(settings).reset()
    XCTAssertEqual(settings.pressLog, ["A", "A", "B", "B"])
    XCTAssertEqual(settings.states(), ["A": .on, "B": .on])
  }

  // MARK: The list changing mid-run

  func testReorderedListNeverTogglesTheWrongApp() throws {
    let settings = fake([("A", .on), ("B", .off), ("C", .on), ("D", .off), ("E", .on)])
    settings.afterPress = { count in
      if count == 1 || count == 4 { settings.reverse() }
    }
    try resetter(settings).reset()
    XCTAssertEqual(settings.states(), ["A": .on, "B": .off, "C": .on, "D": .off, "E": .on])
    XCTAssertEqual(settings.pressCount("B"), 0)
    XCTAssertEqual(settings.pressCount("D"), 0)
    for label in ["A", "C", "E"] { XCTAssertEqual(settings.pressCount(label), 2, label) }
  }

  func testAppAddedAboveMidRunShiftsRowsSafely() throws {
    let settings = fake([("A", .on), ("B", .off), ("C", .on)])
    settings.afterPress = { count in
      if count == 1 { settings.append("New disabled app", .off, at: 0) }
    }
    try resetter(settings).reset()
    XCTAssertEqual(
      settings.states(), ["A": .on, "B": .off, "C": .on, "New disabled app": .off])
    XCTAssertEqual(settings.pressCount("New disabled app"), 0)
    XCTAssertEqual(settings.pressCount("B"), 0)
  }

  func testLateLoadingEnabledRowIsAlsoReset() throws {
    let settings = fake([("A", .on)])
    settings.afterPress = { count in
      if count == 2 { settings.append("Late", .on) }
    }
    let report = try resetter(settings).reset()
    XCTAssertEqual(report.reset.map(\.label), ["A", "Late"])
    XCTAssertEqual(settings.pressCount("Late"), 2)
  }

  func testDuplicateNamesAreTrackedSeparately() throws {
    let settings = fake([("node", .off), ("node", .on), ("Python", .on), ("node", .on)])
    let report = try resetter(settings).reset()
    XCTAssertEqual(
      report.reset, [RowKey(label: "node", occurrence: 1), RowKey(label: "Python"), RowKey(label: "node", occurrence: 2)])
    XCTAssertEqual(settings.apps.map(\.state), [.off, .on, .on, .on])
    XCTAssertEqual(settings.pressLog.count, 6)
  }

  func testLinkedSameNamedSwitchesArePressedOncePerPhase() throws {
    // As on a real Mac: twelve "CapCom" rows share one switch.
    let apps = [("QLab", ToggleState.on)] + Array(repeating: ("CapCom", ToggleState.on), count: 12)
      + [("Eos", .on)]
    let settings = fake(apps)
    settings.linkedNames = ["CapCom"]
    let report = try resetter(settings).reset()
    XCTAssertEqual(settings.pressCount("CapCom"), 2, "one press off, one press on")
    XCTAssertEqual(settings.pressCount("QLab"), 2)
    XCTAssertEqual(report.reset.count, 14)
    XCTAssertEqual(settings.apps.map(\.state), Array(repeating: .on, count: 14))
  }

  func testIndependentSameNamedSwitchesAreEachPressed() throws {
    let settings = fake([("node", .on), ("node", .on), ("node", .off)])
    let report = try resetter(settings).reset()
    XCTAssertEqual(report.reset.count, 2)
    XCTAssertEqual(settings.pressCount("node"), 4)
    XCTAssertEqual(settings.apps.map(\.state), [.on, .on, .off])
  }

  func testUnlabelledRowsFallBackToOrder() throws {
    let settings = fake([("", .on), ("", .off), ("", .on)])
    try resetter(settings).reset()
    XCTAssertEqual(settings.apps.map(\.state), [.on, .off, .on])
    XCTAssertEqual(settings.pressLog.count, 4)
  }

  func testPermissionRemovedMidRunFailsAndRestoresTheRest() throws {
    let settings = fake([("A", .on), ("B", .on), ("C", .on)])
    settings.afterPress = { count in
      if count == 3 { settings.remove("B") }  // B was just switched off
    }
    XCTAssertThrowsError(try resetter(settings).reset()) { error in
      let failure = error as? ResetFailure
      XCTAssertEqual(failure?.underlying as? LocalNetworkError, .permissionDisappeared("B"))
      XCTAssertEqual(failure?.possiblyDisabled, ["B"])
    }
    XCTAssertEqual(settings.states(), ["A": .on, "C": .on])
  }

  // MARK: Failures and restoration

  func testAtMostOneAppIsEverOff() throws {
    let apps = (1...8).map { ("App \($0)", ToggleState.on) }
    let settings = fake(apps)
    var maxOff = 0
    settings.afterPress = { _ in
      maxOff = max(maxOff, settings.states().values.filter { $0 == .off }.count)
    }
    settings.pressLatency = 0
    try resetter(settings).reset()
    XCTAssertEqual(maxOff, 1)
  }

  func testIgnoredPressEndsTheAttemptWithoutPressingAgain() throws {
    // A press with no visible effect may just be a stale display, so it is
    // never repeated in the same System Settings session.
    let settings = fake([("A", .on), ("B", .on)])
    settings.droppedPresses = 1
    XCTAssertThrowsError(try resetter(settings).reset()) { error in
      XCTAssertEqual((error as? ResetFailure)?.underlying as? LocalNetworkError, .noResponse("A"))
    }
    XCTAssertEqual(settings.pressLog, ["A"])
  }

  func testPermissionThatMovesMidRunIsFollowedByName() throws {
    let settings = fake([("A", .on), ("B", .on)])
    settings.afterPress = { count in
      if count == 3 {
        settings.remove("B")
        settings.append("B", .off)
      }
    }
    // B reappears disabled at a new position: it is found by name and restored.
    try resetter(settings).reset()
    XCTAssertEqual(settings.states(), ["A": .on, "B": .on])
  }

  func testSwitchDisabledByOthersDuringResetIsSwitchedBackOn() throws {
    let settings = fake([("A", .on), ("B", .on)])
    var sabotaged = false
    settings.afterPress = { count in
      if count == 4 && !sabotaged {
        sabotaged = true
        settings.force("A", .off)
      }
    }
    // A is switched off by something else after it was switched back on.
    // The final confirmation notices and switches it on again.
    try resetter(settings).reset()
    XCTAssertEqual(settings.states(), ["A": .on, "B": .on])
    XCTAssertEqual(settings.pressCount("A"), 3)
  }

  func testRevokedAccessibilityFailsImmediately() throws {
    let settings = fake([("A", .on)])
    settings.accessibilityRevoked = true
    let started = clock.now
    XCTAssertThrowsError(try resetter(settings).reset())
    XCTAssertLessThan(clock.now.timeIntervalSince(started), 1)
  }

  func testSystemSettingsQuittingEndsTheAttemptQuickly() throws {
    let settings = fake([("A", .on), ("B", .on)])
    settings.afterPress = { _ in settings.crash() }
    let started = clock.now
    XCTAssertThrowsError(try resetter(settings).reset()) { error in
      XCTAssertEqual(
        (error as? ResetFailure)?.underlying as? LocalNetworkError, .systemSettingsQuitUnexpectedly)
      XCTAssertEqual((error as? ResetFailure)?.possiblyDisabled, ["A", "B"])
    }
    XCTAssertLessThan(clock.now.timeIntervalSince(started), 1)
  }

  func testRecoveringReenablesPermissionsLeftOffByAnInterruptedRun() throws {
    let settings = fake([("A", .off), ("B", .on), ("C", .off)])
    let report = try resetter(settings).reset(
      recovering: RecoveryState(keys: [RowKey(label: "A")]))
    XCTAssertEqual(report.recovered, [RowKey(label: "A")])
    XCTAssertEqual(report.reset, [RowKey(label: "B")])
    XCTAssertEqual(settings.states(), ["A": .on, "B": .on, "C": .off])
    XCTAssertEqual(settings.pressCount("A"), 1)
  }

  func testRecoveringSameNamedAppTrustedWhileGroupSizeUnchanged() throws {
    let settings = fake([("node", .on), ("node", .off)])
    let key = RowKey(label: "node", occurrence: 1)
    let report = try resetter(settings).reset(
      recovering: RecoveryState(keys: [key], groupSizes: [key.base: 2]))
    XCTAssertEqual(report.recovered, [key])
    XCTAssertEqual(settings.apps.map(\.state), [.on, .on])
  }

  func testRecoveringSameNamedAppIsNeverGuessedAfterGroupChanged() throws {
    // Recorded when there were two "node" apps; a third has since appeared,
    // so which one was left off is unknowable. Report it, change nothing.
    let settings = fake([("node", .off), ("node", .off), ("node", .on)])
    let key = RowKey(label: "node", occurrence: 1)
    let report = try resetter(settings).reset(
      recovering: RecoveryState(keys: [key], groupSizes: [key.base: 2]))
    XCTAssertEqual(report.recovered, [])
    XCTAssertEqual(report.ambiguous, ["node"])
    XCTAssertEqual(settings.apps.map(\.state), [.off, .off, .on])
  }

  func testSameNamedAppAppearingMidRunEndsTheAttempt() throws {
    let settings = fake([("node", .on), ("node", .on)])
    settings.afterPress = { count in
      if count == 1 { settings.append("node", .off, at: 0) }
    }
    XCTAssertThrowsError(try resetter(settings).reset()) { error in
      XCTAssertEqual(
        (error as? ResetFailure)?.underlying as? LocalNetworkError, .duplicateAppsChanged("node"))
    }
    XCTAssertEqual(settings.pressCount("node"), 1, "no guessing after the group changed")
  }

  // MARK: Parsing

  func testToggleStateParsing() throws {
    XCTAssertEqual(try ToggleState(accessibilityValue: NSNumber(value: 0)), .off)
    XCTAssertEqual(try ToggleState(accessibilityValue: NSNumber(value: 1)), .on)
    XCTAssertEqual(try ToggleState(accessibilityValue: NSNumber(value: true)), .on)
    XCTAssertEqual(try ToggleState(accessibilityValue: "1"), .on)
    XCTAssertThrowsError(try ToggleState(accessibilityValue: NSNumber(value: 2)))
    XCTAssertThrowsError(try ToggleState(accessibilityValue: "mixed"))
  }

  func testRowKeysNumberDuplicateNames() {
    let rows = [
      PermissionRow(index: 0, label: "node", state: .on),
      PermissionRow(index: 3, label: "QLab", state: .on),
      PermissionRow(index: 5, label: "node", state: .off),
    ].keyed()
    XCTAssertEqual(rows.map(\.key.description), ["node", "QLab", "node (2)"])
    XCTAssertEqual(RowKey(label: "").description, "Unnamed app")
  }

  // MARK: Helpers

  private func fake(_ apps: [(String, ToggleState)]) -> FakeSystemSettings {
    let settings = FakeSystemSettings(clock: clock, apps: apps)
    try? settings.openLocalNetworkPage()
    return settings
  }

  private func resetter(_ settings: FakeSystemSettings) -> LocalNetworkResetter {
    LocalNetworkResetter(
      ui: settings,
      configuration: ResetConfiguration(),
      now: { [clock] in clock!.now },
      sleep: { [clock] in clock!.sleep($0) }
    )
  }
}
