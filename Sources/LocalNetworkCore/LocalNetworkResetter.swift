import ApplicationServices
import Foundation

public enum ToggleState: Int, Equatable, Sendable {
  case off = 0
  case on = 1

  public init(accessibilityValue: Any) throws {
    if let number = accessibilityValue as? NSNumber,
      let state = ToggleState(rawValue: number.intValue)
    {
      self = state
      return
    }
    if let string = accessibilityValue as? String,
      let rawValue = Int(string),
      let state = ToggleState(rawValue: rawValue)
    {
      self = state
      return
    }
    throw LocalNetworkError.invalidToggleValue
  }
}

/// One Local Network permission as currently shown by System Settings.
public struct PermissionRow: Equatable, Sendable {
  /// Position in the outline. Only valid until System Settings refreshes the list.
  public var index: Int
  /// The app name shown in the row, or an empty string if none was exposed.
  public var label: String
  /// A stable Accessibility identifier for the switch, when System Settings
  /// provides one. It separates apps that share a display name.
  public var identifier: String?
  public var state: ToggleState
  /// Total number of rows in the list when this row was read. Any insertion
  /// or removal changes it, which invalidates remembered positions.
  public var listSize: Int

  public init(
    index: Int, label: String, identifier: String? = nil, state: ToggleState, listSize: Int = 0
  ) {
    self.index = index
    self.label = label
    self.identifier = identifier
    self.state = state
    self.listSize = listSize
  }
}

/// Identifies a permission independently of its position, so a list that is
/// reordered or refreshed mid-run can never cause the wrong app to be toggled.
/// Apps sharing a display name (and identifier) are distinguished by their
/// order of appearance; see `LocalNetworkError.duplicateAppsChanged`.
public struct RowKey: Hashable, Codable, Sendable, CustomStringConvertible {
  public var label: String
  public var identifier: String?
  public var occurrence: Int

  public init(label: String, identifier: String? = nil, occurrence: Int = 0) {
    self.label = label
    self.identifier = identifier
    self.occurrence = occurrence
  }

  /// The identity shared by same-named apps, before numbering by occurrence.
  var base: RowKey { RowKey(label: label, identifier: identifier) }

  func matches(_ row: PermissionRow) -> Bool {
    row.label == label && row.identifier == identifier
  }

  public var description: String {
    let name = label.isEmpty ? "Unnamed app" : label
    return occurrence == 0 ? name : "\(name) (\(occurrence + 1))"
  }
}

extension Array where Element == PermissionRow {
  public func keyed() -> [(key: RowKey, row: PermissionRow)] {
    var seen: [RowKey: Int] = [:]
    return map { row in
      let base = RowKey(label: row.label, identifier: row.identifier)
      let occurrence = seen[base, default: 0]
      seen[base] = occurrence + 1
      return (RowKey(label: row.label, identifier: row.identifier, occurrence: occurrence), row)
    }
  }

  func baseCounts() -> [RowKey: Int] {
    reduce(into: [:]) { $0[RowKey(label: $1.label, identifier: $1.identifier), default: 0] += 1 }
  }
}

public enum LocalNetworkError: LocalizedError, Equatable {
  case accessibilityRequired
  case systemSettingsDidNotLaunch
  case systemSettingsDidNotQuit
  case systemSettingsQuitUnexpectedly
  case localNetworkPageNotFound
  case localNetworkListNotFound
  case rowNoLongerExists(Int)
  case rowChanged(Int)
  case permissionDisappeared(String)
  case invalidToggleValue
  case stateChangeTimedOut(String)
  case verificationFailed([String])
  case duplicateAppsChanged(String)
  case noResponse(String)
  case scrollPositionChanged

  public var errorDescription: String? {
    switch self {
    case .accessibilityRequired:
      return "Accessibility access is required to operate the Local Network switches."
    case .systemSettingsDidNotLaunch:
      return "System Settings did not finish opening."
    case .systemSettingsDidNotQuit:
      return "System Settings did not finish closing."
    case .systemSettingsQuitUnexpectedly:
      return "System Settings quit unexpectedly."
    case .localNetworkPageNotFound:
      return "System Settings did not reach Privacy & Security > Local Network."
    case .localNetworkListNotFound:
      return "System Settings did not expose the Local Network permission list."
    case .rowNoLongerExists(let index):
      return "Local Network row \(index + 1) is no longer available."
    case .rowChanged(let index):
      return "Local Network row \(index + 1) changed to a different app."
    case .permissionDisappeared(let name):
      return "\(name) disappeared from the Local Network list."
    case .invalidToggleValue:
      return "System Settings returned an unrecognised Local Network switch value."
    case .stateChangeTimedOut(let name):
      return "The Local Network switch for \(name) did not finish changing state."
    case .verificationFailed(let names):
      return "These apps were not enabled after the reset: \(names.joined(separator: ", "))."
    case .noResponse(let name):
      return "System Settings did not respond to the switch for \(name)."
    case .duplicateAppsChanged(let name):
      return "Several apps named \(name) changed while being reset, so they could not be told apart."
    case .scrollPositionChanged:
      return "The Local Network list moved while its switches were being reset."
    }
  }
}

/// Thrown when a reset fails. Lists every app that may have been left disabled
/// so the person running the show knows exactly what to check.
public struct ResetFailure: LocalizedError {
  public var underlying: Error
  public var possiblyDisabled: [String]
  /// True when System Settings could not be read afterwards, so it is
  /// unknown whether anything was left disabled.
  public var unverified = false

  public init(underlying: Error, possiblyDisabled: [String], unverified: Bool = false) {
    self.underlying = underlying
    self.possiblyDisabled = possiblyDisabled
    self.unverified = unverified
  }

  public var errorDescription: String? {
    let reason = underlying.localizedDescription
    if unverified {
      return reason
        + " System Settings could not be opened afterwards to check, so some permissions may be off."
        + " Open it again to check."
    }
    guard !possiblyDisabled.isEmpty else {
      return reason + " All Local Network permissions were left enabled."
    }
    return reason
      + " These apps may still be disabled: \(possiblyDisabled.joined(separator: ", "))."
  }
}

extension Error {
  /// Errors that System Settings produces while it rebuilds its interface.
  /// Everything else is also retried within the bounded deadline, except a
  /// revoked Accessibility permission, which can never recover by waiting.
  var isFatalAccessibilityError: Bool {
    guard let error = self as? AccessibilityElementError,
      case .operationFailed(_, let axError) = error
    else { return false }
    return axError == .apiDisabled
  }

  /// Errors that waiting cannot fix within the current System Settings
  /// session. The runner starts a fresh session instead.
  var endsAttempt: Bool {
    if isFatalAccessibilityError { return true }
    switch self as? LocalNetworkError {
    case .systemSettingsQuitUnexpectedly?, .duplicateAppsChanged?, .noResponse?:
      return true
    default:
      return false
    }
  }
}

@MainActor
public protocol LocalNetworkUI: AnyObject {
  /// Every permission row currently in the list, in display order.
  func permissionRows() throws -> [PermissionRow]
  /// Reads one row freshly. Throws `rowNoLongerExists` if the index is gone.
  func permissionRow(at index: Int) throws -> PermissionRow
  /// Presses the switch at `index` only if that row still belongs to `key`'s
  /// app. Throws `rowChanged` otherwise.
  func pressToggle(at index: Int, expecting key: RowKey) throws
}

/// Safety limits only. How long to wait between steps is not configured: it
/// is learned from how quickly System Settings responds (see `ResponsePace`).
public struct ResetConfiguration: Sendable {
  /// Upper bound for any single switch to change.
  public var timeout: TimeInterval
  /// How often switches are read while waiting.
  public var pollInterval: TimeInterval
  /// Upper bound for each switch while restoring after a failure.
  public var restoreTimeout: TimeInterval
  /// Lower bound on how long a press may take to show before it counts as
  /// ignored, so one quick early response never makes the app impatient.
  public var minimumPatience: TimeInterval

  public init(
    timeout: TimeInterval = 20,
    pollInterval: TimeInterval = 0.03,
    restoreTimeout: TimeInterval = 15,
    minimumPatience: TimeInterval = 1
  ) {
    self.timeout = timeout
    self.pollInterval = pollInterval
    self.restoreTimeout = restoreTimeout
    self.minimumPatience = minimumPatience
  }
}

/// Learns how long System Settings takes to show a pressed switch changing,
/// and derives every wait from that, so the app adapts to a fast or slow Mac
/// instead of relying on fixed delays.
public struct ResponsePace: Sendable {
  /// Recent press-to-change times, newest last.
  public private(set) var samples: [TimeInterval] = []

  public init() {}

  mutating func record(_ latency: TimeInterval) {
    samples.append(max(latency, 0))
    if samples.count > 12 { samples.removeFirst() }
  }

  var typical: TimeInterval? {
    guard !samples.isEmpty else { return nil }
    return samples.sorted()[samples.count / 2]
  }

  var slowest: TimeInterval? { samples.max() }

  /// How long a new state must hold before it is trusted, and before the
  /// next press: as long as System Settings typically takes to show one.
  /// Presses sent sooner are the ones it silently drops.
  func settleWindow(poll: TimeInterval) -> TimeInterval {
    max(typical ?? 0, 2 * poll)
  }

  /// How long a press may show no effect before it counts as ignored. Until
  /// anything has been measured, the caller waits up to its safety limit.
  func patience(minimum: TimeInterval) -> TimeInterval? {
    slowest.map { max(4 * $0, minimum) }
  }

  /// How long other rows sharing a switch get to follow a pressed one.
  func followWindow(poll: TimeInterval) -> TimeInterval {
    max(2 * (slowest ?? 0), settleWindow(poll: poll))
  }
}

/// What an interrupted run intended to leave enabled.
public struct RecoveryState: Codable, Equatable, Sendable {
  public var keys: Set<RowKey>
  /// How many apps shared each name when recorded. A recorded occurrence of a
  /// shared name is only trusted while that number is unchanged.
  public var groupSizes: [RowKey: Int]

  public init(keys: Set<RowKey> = [], groupSizes: [RowKey: Int] = [:]) {
    self.keys = keys
    self.groupSizes = groupSizes
  }

  public var isEmpty: Bool { keys.isEmpty }

  mutating func merge(_ keys: [RowKey], groupSizes sizes: [RowKey: Int]) {
    self.keys.formUnion(keys)
    for key in keys {
      let size = sizes[key.base, default: 1]
      if let existing = groupSizes[key.base], existing != size {
        groupSizes[key.base] = 0  // Conflicting records: never trust occurrence.
      } else {
        groupSizes[key.base] = size
      }
    }
  }
}

public struct ResetReport: Equatable, Sendable {
  /// Permissions that were switched off and back on.
  public var reset: [RowKey]
  /// Permissions that were found disabled after an interrupted run and re-enabled.
  public var recovered: [RowKey]
  /// Number of rows in the Local Network list.
  public var totalRows: Int
  /// Apps that an interrupted run may have left disabled, but which share a
  /// name with other apps whose number has since changed, so which of them
  /// needs re-enabling cannot be known. They are reported, never guessed.
  public var ambiguous: [String] = []
}

@MainActor
public final class LocalNetworkResetter {
  private let ui: LocalNetworkUI
  private let configuration: ResetConfiguration
  private let now: () -> Date
  private let sleep: (TimeInterval) -> Void
  /// The pacing learned so far in this run.
  public private(set) var pace = ResponsePace()
  /// The most recent change, which must have settled before the next press.
  private var lastChange: (key: RowKey, state: ToggleState, landedAt: Date)?
  /// Reports progress: apps done, total, and the app being reset (nil when finished).
  public var progress: ((Int, Int, String?) -> Void)?
  /// Receives a line for every press, for diagnosing behaviour on real Macs.
  public var trace: ((String) -> Void)?
  /// Last known position of each permission, refreshed whenever a lookup misses.
  private var positions: [RowKey: Int] = [:]
  /// How many apps shared each name when the run started. Occurrence numbers
  /// are only trustworthy while these counts stay the same.
  private var expectedCounts: [RowKey: Int] = [:]
  /// List size at the last full read. Remembered positions are only used
  /// while the list still has exactly this many rows.
  private var knownListSize: Int?
  /// Row labels by position at the last full read.
  private var knownLabels: [Int: String] = [:]
  /// Names whose number of apps changed during this attempt. Their occurrence
  /// numbers are never trusted again, for pressing, restoring or verifying.
  private var changedGroups: Set<RowKey> = []

  public init(
    ui: LocalNetworkUI,
    configuration: ResetConfiguration = ResetConfiguration(),
    pace: ResponsePace = ResponsePace(),
    now: @escaping () -> Date = Date.init,
    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    self.ui = ui
    self.pace = pace
    self.configuration = configuration
    self.now = now
    self.sleep = sleep
  }

  /// Switches every enabled permission off and on again.
  ///
  /// - Parameters:
  ///   - recovering: permissions an earlier, interrupted run intended to leave
  ///     enabled. Any of them found disabled are switched back on.
  ///   - willModify: called with every permission about to be changed, before
  ///     the first switch is pressed, so the caller can persist it.
  @discardableResult
  public func reset(
    recovering: RecoveryState = RecoveryState(),
    willModify: (RecoveryState) throws -> Void = { _ in }
  ) throws -> ResetReport {
    expectedCounts = [:]
    changedGroups = []
    let initial = try readAllRows()
    expectedCounts = initial.map(\.row).baseCounts()
    let enabled = initial.filter { $0.row.state == .on }.map(\.key)
    var recover: [RowKey] = []
    var ambiguous: [String] = []
    for (key, row) in initial where row.state == .off && recovering.keys.contains(key) {
      let size = expectedCounts[key.base, default: 1]
      if size == 1 || recovering.groupSizes[key.base] == size {
        recover.append(key)
      } else if !ambiguous.contains(key.label) {
        ambiguous.append(key.label)
      }
    }
    var intent = RecoveryState()
    intent.merge(enabled + recover, groupSizes: expectedCounts)
    try willModify(intent)

    // Reset each app or linked group off/on before starting the next.
    var touched = recover + enabled
    var reset = enabled
    do {
      try resetInPhases(enabled, alsoEnabling: recover)

      // Rows that finished loading after the initial read are reset too.
      let known = Set(initial.map(\.key))
      let current = try readAllRows()
      let currentCounts = current.map(\.row).baseCounts()
      if let changed = changedGroups.first {
        throw LocalNetworkError.duplicateAppsChanged(changed.label)
      }
      let late = current.filter { !known.contains($0.key) && $0.row.state == .on }.map(\.key)
      if !late.isEmpty {
        expectedCounts = currentCounts
        intent.merge(late, groupSizes: currentCounts)
        try willModify(intent)
        touched += late
        reset += late
        try resetInPhases(late, alsoEnabling: [])
      }

      try confirmEnabled(touched)
      var expected = Dictionary(uniqueKeysWithValues: initial.map { ($0.key, $0.row.state) })
      for key in touched { expected[key] = .on }
      try verifyStates(expected)
      return ResetReport(
        reset: reset, recovered: recover, totalRows: initial.count + late.count,
        ambiguous: ambiguous)
    } catch {
      // When System Settings can no longer be trusted, nothing more is
      // pressed in this session: the runner restores from a fresh one.
      if error.endsAttempt {
        throw ResetFailure(underlying: error, possiblyDisabled: touched.map(\.description))
      }
      throw ResetFailure(underlying: error, possiblyDisabled: restore(touched))
    }
  }

  /// Switches back on every recorded permission that is off, without
  /// resetting anything else. Returns those that could not be confirmed on,
  /// including same-named apps that cannot be told apart.
  public func restoreOnly(_ recovering: RecoveryState) throws -> [String] {
    expectedCounts = [:]
    changedGroups = []
    let rows = try readAllRows()
    expectedCounts = rows.map(\.row).baseCounts()
    var targets: [RowKey] = []
    var unresolved: [String] = []
    for (key, row) in rows where row.state == .off && recovering.keys.contains(key) {
      let size = expectedCounts[key.base, default: 1]
      if size == 1 || recovering.groupSizes[key.base] == size {
        targets.append(key)
      } else if !unresolved.contains(key.label) {
        unresolved.append(key.label)
      }
    }
    return restore(targets) + unresolved
  }

  /// Resets one app or same-named group at a time, without scrolling.
  private func resetInPhases(_ keys: [RowKey], alsoEnabling recover: [RowKey]) throws {
    // One app (or same-named group) at a time, as in v1: off, settled, back
    // on and confirmed before the next. At most one app is ever switched off.
    // The list is never scrolled.
    if !recover.isEmpty {
      trace?("re-enabling \(recover)")
      try setAll(recover, to: .on)
    }
    var order: [RowKey] = []
    var groups: [RowKey: [RowKey]] = [:]
    for key in keys {
      if groups[key.base] == nil { order.append(key.base) }
      groups[key.base, default: []].append(key)
    }
    for (position, base) in order.enumerated() {
      let members = groups[base]!
      trace?("\(position + 1)/\(order.count): \(base)")
      progress?(position, order.count, base.description)
      // The switch stays off until System Settings has had as long to settle
      // it as it takes to show a change, which is also what makes it visible.
      try setAll(members, to: .off)
      try setAll(members, to: .on)
    }
    progress?(order.count, order.count, nil)
  }


  /// The given permissions that are currently switched off. Permissions no
  /// longer in the list are not included.
  public func disabled(among keys: [RowKey]) throws -> [RowKey] {
    expectedCounts = [:]
    changedGroups = []
    let rows = try readAllRows()
    expectedCounts = rows.map(\.row).baseCounts()
    let states = Dictionary(
      rows.map { ($0.key, $0.row.state) }, uniquingKeysWith: { first, _ in first })
    return keys.filter { states[$0] == .off }
  }

  /// The recorded permissions that are currently off, plus the names of
  /// same-named apps whose group changed size since recording, which cannot
  /// safely be told apart and are never switched on by guesswork.
  public func disabled(recovering: RecoveryState) throws -> ([RowKey], [String]) {
    let off = try disabled(among: Array(recovering.keys))
    var trusted: [RowKey] = []
    var unresolved: [String] = []
    for key in off {
      let size = expectedCounts[key.base, default: 1]
      if size == 1 || recovering.groupSizes[key.base] == size {
        trusted.append(key)
      } else if !unresolved.contains(key.label) {
        unresolved.append(key.label)
      }
    }
    return (trusted, unresolved)
  }

  /// Presses every switch that is not yet in `state`, then confirms each one,
  /// re-pressing only those System Settings did not act on.
  ///
  /// Apps sharing a name are handled as a group: System Settings links their
  /// switches, so pressing one row flips every row with that name. Pressing
  /// each row would flip the group back and forth, so one member is pressed
  /// and another only if it demonstrably did not follow.
  private func setAll(
    _ keys: [RowKey], to state: ToggleState, timeout: TimeInterval? = nil
  ) throws {
    var groups: [RowKey: [RowKey]] = [:]
    var order: [RowKey] = []
    for key in keys {
      if groups[key.base] == nil { order.append(key.base) }
      groups[key.base, default: []].append(key)
    }

    // One switch at a time, each confirmed before the next is pressed.
    // System Settings stops updating grouped rows if they are pressed in
    // quick succession, so presses are never overlapped.
    var pressedAt: [RowKey: Date] = [:]
    for base in order {
      let members = groups[base]!
      if members.count == 1 && expectedCounts[base, default: 1] == 1 {
        try change(members[0], to: state, confirmStable: false, timeout: timeout)
      } else {
        try settleGroup(members, to: state, pressedAt: &pressedAt, timeout: timeout)
      }
    }
  }

  /// Brings every member of a same-named group to `state`, pressing a further
  /// member only after it has failed to follow the one already pressed.
  private func settleGroup(
    _ members: [RowKey], to state: ToggleState, pressedAt: inout [RowKey: Date],
    timeout: TimeInterval?
  ) throws {
    // Each round waits for the pressed member to land before judging which
    // members did not follow, so the group never ends with a press in flight.
    // Only presses that happened count towards the limit; unreadable rounds
    // are bounded by the deadline instead.
    // The time limit applies to each switch, so it restarts whenever a member
    // responds: a slow System Settings with many same-named apps still finishes.
    let limit = timeout ?? configuration.timeout
    var deadline = now().addingTimeInterval(limit)
    var pressesLeft = members.count
    var anyPressed = false
    trace?("settle \(members) to \(state)")
    while true {
      if let pressed = members.first(where: { pressedAt[$0] != nil }) {
        try change(
          pressed, to: state, confirmStable: false, timeout: timeout, pressedAt: pressedAt[pressed])
        pressedAt[pressed] = nil
      }
      var remaining = try members.filter { try read($0)?.state != state }
      // Other members get time to follow only after one has been switched.
      let followDeadline =
        anyPressed ? now().addingTimeInterval(pace.followWindow(poll: configuration.pollInterval)) : now()
      while !remaining.isEmpty && now() < followDeadline {
        sleep(configuration.pollInterval)
        remaining = try remaining.filter { try read($0)?.state != state }
      }
      guard let next = remaining.first else { return }
      guard pressesLeft > 0, now() < deadline else {
        throw LocalNetworkError.stateChangeTimedOut(next.description)
      }
      // This member is independent of those already switched: press it.
      // Group presses must observe the same settling rule as change().
      // Otherwise the off/on press for a linked group can arrive too soon.
      try waitForLastChangeToSettle()
      if let row = try read(next), row.state != state {
        if try press(row, key: next) {
          pressedAt[next] = now()
          pressesLeft -= 1
          anyPressed = true
          deadline = now().addingTimeInterval(limit)
        }
      } else {
        sleep(configuration.pollInterval)
      }
    }
  }

  /// Waits briefly, then makes sure nothing flipped back off while System
  /// Settings finished applying the changes, and verifies the whole set.
  private func confirmEnabled(_ keys: [RowKey]) throws {
    guard !keys.isEmpty else { return }
    trace?("confirming \(keys)")
    sleep(pace.settleWindow(poll: configuration.pollInterval))
    let states = Dictionary(
      try readAllRows().map { ($0.key, $0.row.state) }, uniquingKeysWith: { first, _ in first })
    let disabled = keys.filter { states[$0] != .on }
    if !disabled.isEmpty {
      try setAll(disabled, to: .on)
      sleep(pace.settleWindow(poll: configuration.pollInterval))
    }
    try verifyEnabled(keys)
  }

  /// Throws unless every given permission is currently enabled.
  public func verifyEnabled(_ keys: [RowKey]) throws {
    guard !keys.isEmpty else { return }
    let deadline = now().addingTimeInterval(configuration.timeout)
    while true {
      let rows = try readAllRows()
      if let changed = keys.first(where: { changedGroups.contains($0.base) }) {
        throw LocalNetworkError.duplicateAppsChanged(changed.label)
      }
      let states = Dictionary(
        rows.map { ($0.key, $0.row.state) }, uniquingKeysWith: { first, _ in first })
      let disabled = keys.filter { states[$0] != .on }
      if disabled.isEmpty { return }
      guard now() < deadline else {
        throw LocalNetworkError.verificationFailed(disabled.map(\.description))
      }
      sleep(configuration.pollInterval)
    }
  }

  /// Rereads the whole list throughout the learned settling window. This
  /// confirms displayed states, including permissions that started off; it
  /// cannot independently detect a permanently stale Settings display.
  private func verifyStates(_ expected: [RowKey: ToggleState]) throws {
    guard !expected.isEmpty else { return }
    let end = now().addingTimeInterval(pace.settleWindow(poll: configuration.pollInterval))
    repeat {
      let rows = try readAllRows()
      if let changed = expected.keys.first(where: { changedGroups.contains($0.base) }) {
        throw LocalNetworkError.duplicateAppsChanged(changed.label)
      }
      let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.row.state) })
      let mismatched = expected.keys.filter { states[$0] != expected[$0] }
      guard mismatched.isEmpty else {
        throw LocalNetworkError.verificationFailed(mismatched.map(\.description).sorted())
      }
      if now() >= end { return }
      sleep(configuration.pollInterval)
    } while true
  }

  /// Returns the permissions that could not be confirmed enabled.
  func restore(_ keys: [RowKey]) -> [String] {
    guard !keys.isEmpty else { return [] }
    // Each app or same-named group separately, so one that cannot be
    // restored never stops the others from being switched back on.
    var groups: [RowKey: [RowKey]] = [:]
    var order: [RowKey] = []
    for key in keys {
      if groups[key.base] == nil { order.append(key.base) }
      groups[key.base, default: []].append(key)
    }
    for base in order {
      do {
        try setAll(groups[base]!, to: .on, timeout: configuration.restoreTimeout)
      } catch {
        // Only a lost System Settings or Accessibility stops the others; an
        // app that does not respond is reported and the rest carry on.
        if error.isFatalAccessibilityError
          || (error as? LocalNetworkError) == .systemSettingsQuitUnexpectedly
        {
          break
        }
      }
    }
    guard let rows = try? readAllRows() else { return keys.map(\.description) }
    let states = Dictionary(
      rows.map { ($0.key, $0.row.state) }, uniquingKeysWith: { first, _ in first })
    return keys.filter { states[$0] != .on || changedGroups.contains($0.base) }
      .map(\.description)
  }

  // MARK: Reading

  private func readAllRows() throws -> [(key: RowKey, row: PermissionRow)] {
    let deadline = now().addingTimeInterval(configuration.timeout)
    while true {
      do {
        let rows = try ui.permissionRows().keyed()
        remember(rows)
        return rows
      } catch {
        if error.endsAttempt || now() >= deadline { throw error }
      }
      sleep(configuration.pollInterval)
    }
  }

  /// Reads a permission by identity, following it if the list was reordered.
  /// Returns nil for a transient miss; throws once the permission is gone.
  private func read(_ key: RowKey) throws -> PermissionRow? {
    if changedGroups.contains(key.base) {
      throw LocalNetworkError.duplicateAppsChanged(key.label)
    }
    if let index = positions[key] {
      do {
        let row = try ui.permissionRow(at: index)
        // A matching row in a list that has not grown or shrunk is the same
        // permission. For a shared name, its neighbours must also be where
        // they were. Anything else needs a full read.
        let unique = expectedCounts[key.base, default: 1] == 1
        if key.matches(row), row.listSize == knownListSize,
          try unique || neighboursUnchanged(around: index)
        {
          return row
        }
      } catch {
        if error.endsAttempt { throw error }
      }
    }

    let rows: [(key: RowKey, row: PermissionRow)]
    do {
      rows = try ui.permissionRows().keyed()
    } catch {
      if error.endsAttempt { throw error }
      return nil
    }
    remember(rows)
    if changedGroups.contains(key.base) {
      // An app with the same name appeared or vanished, so occurrence numbers
      // may now point at a different app. Never guess: start afresh.
      throw LocalNetworkError.duplicateAppsChanged(key.label)
    }
    guard let match = rows.first(where: { $0.key == key }) else {
      throw LocalNetworkError.permissionDisappeared(key.description)
    }
    return match.row
  }

  private func neighboursUnchanged(around index: Int) throws -> Bool {
    for neighbour in [index - 1, index + 1] {
      guard let expected = knownLabels[neighbour] else { continue }
      if try ui.permissionRow(at: neighbour).label != expected { return false }
    }
    return true
  }

  private func remember(_ rows: [(key: RowKey, row: PermissionRow)]) {
    knownLabels = Dictionary(
      rows.map { ($0.row.index, $0.row.label) }, uniquingKeysWith: { first, _ in first })
    let counts = rows.map(\.row).baseCounts()
    for (base, expected) in expectedCounts {
      let count = counts[base, default: 0]
      // A group losing every member is a disappearance, reported as such.
      if count != expected && count > 0 && (expected > 1 || count > 1) {
        changedGroups.insert(base)
      }
    }
    positions = Dictionary(
      rows.map { ($0.key, $0.row.index) }, uniquingKeysWith: { first, _ in first })
    knownListSize = rows.first?.row.listSize
  }

  // MARK: Changing

  private func change(
    _ key: RowKey,
    to wantedState: ToggleState,
    confirmStable: Bool,
    timeout: TimeInterval? = nil,
    pressedAt: Date? = nil
  ) throws {
    let deadline = now().addingTimeInterval(timeout ?? configuration.timeout)
    var pressed = pressedAt != nil
    var pressTime = pressedAt
    var lastError: Error?

    while true {
      do {
        if let row = try read(key) {
          if row.state == wantedState {
            if let pressTime {
              pace.record(now().timeIntervalSince(pressTime))
              trace?(String(format: "  %@ showed %@ after %.2fs", key.description, "\(wantedState)", now().timeIntervalSince(pressTime)))
            }
            pressTime = nil
            let settled = try !confirmStable || holds(key, wantedState)
            if settled {
              lastChange = (key, wantedState, now())
              return
            }
          } else if !pressed {
            try waitForLastChangeToSettle()
            if let current = try read(key), current.state != wantedState,
              try press(current, key: key)
            {
              pressed = true
              pressTime = now()
            }
          } else if let pressTime,
            let patience = pace.patience(minimum: configuration.minimumPatience),
            now().timeIntervalSince(pressTime) >= patience
          {
            // The press has shown no effect for far longer than System
            // Settings normally takes. Pressing again could flip a switch
            // whose display is merely stale, so the attempt ends instead and
            // a freshly opened System Settings shows the true state. The wait
            // is remembered, so the next attempt allows a slower System Settings.
            pace.record(now().timeIntervalSince(pressTime))
            trace?("noResponse patience pace \(pace.samples)")
            throw LocalNetworkError.noResponse(key.description)
          }
        }
      } catch {
        if error.endsAttempt { throw error }
        lastError = error
      }

      guard now() < deadline else {
        if let lastError, case LocalNetworkError.permissionDisappeared = lastError {
          throw lastError
        }
        if pressed && pressTime != nil { trace?("noResponse deadline"); throw LocalNetworkError.noResponse(key.description) }
        throw LocalNetworkError.stateChangeTimedOut(key.description)
      }
      sleep(configuration.pollInterval)
    }
  }

  /// Whether `key` keeps showing `state` for the whole settle window.
  private func holds(_ key: RowKey, _ state: ToggleState) throws -> Bool {
    let end = now().addingTimeInterval(pace.settleWindow(poll: configuration.pollInterval))
    repeat {
      sleep(configuration.pollInterval)
      guard try read(key)?.state == state else { return false }
    } while now() < end
    return true
  }

  /// Before any press, the previous change must have held for the settle
  /// window. If it has flipped back, System Settings did not keep it, and
  /// the attempt ends so a fresh System Settings can show the real state.
  private func waitForLastChangeToSettle() throws {
    guard let last = lastChange else { return }
    let window = pace.settleWindow(poll: configuration.pollInterval)
    while now().timeIntervalSince(last.landedAt) < window {
      let current = try read(last.key)?.state ?? last.state
      guard current == last.state else {
        trace?("noResponse settle-loop pace \(pace.samples)")
        throw LocalNetworkError.noResponse(last.key.description)
      }
      sleep(configuration.pollInterval)
    }
    let current = try read(last.key)?.state ?? last.state
    if current != last.state {
      trace?("noResponse settle-end pace \(pace.samples)")
      throw LocalNetworkError.noResponse(last.key.description)
    }
  }


  /// Returns false only when the press certainly did not happen, because the
  /// row had moved or disappeared, so it is safe to press again immediately.
  /// Any other failure may still have reached System Settings, so the normal
  /// retry spacing applies.
  private func press(_ row: PermissionRow, key: RowKey) throws -> Bool {
    do {
      trace?("press \(key) at row \(row.index), showing \(row.state)")
      try ui.pressToggle(at: row.index, expecting: key)
      return true
    } catch LocalNetworkError.rowChanged, LocalNetworkError.rowNoLongerExists {
      positions[key] = nil
      return false
    } catch {
      if error.endsAttempt { throw error }
      return true
    }
  }
}
