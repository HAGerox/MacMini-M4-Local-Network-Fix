import ApplicationServices
import Foundation

@testable import LocalNetworkCore

/// A deterministic stand-in for System Settings. Time is simulated, so tests
/// covering long timeouts finish instantly.
@MainActor
final class FakeClock {
  var now = Date(timeIntervalSinceReferenceDate: 0)
  func sleep(_ interval: TimeInterval) { now = now.addingTimeInterval(max(interval, 0.001)) }
}

@MainActor
final class FakeSystemSettings: SettingsSession {
  struct App {
    var label: String
    var state: ToggleState
    /// Presses are ignored entirely.
    var stuck = false
  }

  private struct Pending {
    var id: Int
    var state: ToggleState
    var visibleAt: Date
  }

  let clock: FakeClock
  /// Apps in display order. `ids` gives each a stable identity for assertions.
  private(set) var apps: [App] = []
  private(set) var ids: [Int] = []
  private var nextID = 0
  private var pending: [Pending] = []

  /// Simulated System Settings latency between a press and the switch updating.
  var pressLatency: TimeInterval = 0.1
  /// Number of upcoming presses that System Settings silently ignores.
  var droppedPresses = 0
  /// Presses arriving sooner than this after the last change appeared are
  /// silently dropped, as the real System Settings does.
  var dropsPressesWithin: TimeInterval = 0
  /// Called before each press to change the latency, e.g. to slow down mid-run.
  var latencyForPress: ((Int) -> TimeInterval)?
  private var lastAppliedAt = Date.distantPast
  private(set) var tooSoonPresses = 0
  /// Presses that take effect but still report an Accessibility error.
  var ambiguousPressErrors = 0
  /// Probability that a read fails with a transient Accessibility error.
  var transientErrorRate = 0.0
  private var random = SeededRandom(seed: 42)
  /// After switching on, the value briefly reads off once (a UI refresh).
  var flapAfterOn = false
  var accessibilityRevoked = false
  /// Names whose rows share one switch, as System Settings does for apps with
  /// the same name: pressing any of them flips all of them.
  var linkedNames: Set<String> = []
  var failNextOpens = 0
  /// Close fails once this many sessions have been opened.
  var closeFailsFromOpen: Int?
  /// Apps whose switch, once pressed on, displays on in the current session
  /// but really stays off, as System Settings does for some grouped rows.
  var staleOnDisplay: Set<String> = []
  /// Whether the stale apps never really switch on, even in a new session.
  var staleForever = false
  private var staleShownOn: Set<Int> = []
  var closeFails = false
  private(set) var running = false
  private(set) var closeCount = 0
  private(set) var openCount = 0
  private(set) var pressLog: [String] = []
  /// Human-readable event history for debugging failing seeds.
  private(set) var trace: [String] = []
  private var readCount = 0
  private var flapping: Set<Int> = []

  /// Called after each successful press with the running press count.
  var afterPress: ((Int) -> Void)?
  var afterFullRead: ((Int) -> Void)?
  private(set) var fullReadCount = 0

  init(clock: FakeClock, apps: [(String, ToggleState)]) {
    self.clock = clock
    for (label, state) in apps { append(label, state) }
  }

  func append(_ label: String, _ state: ToggleState, at position: Int? = nil) {
    applyPending(all: linkedNames.contains(label))
    // A newcomer sharing a linked switch shows the group's state.
    let groupState = linkedNames.contains(label) ? apps.first { $0.label == label }?.state : nil
    let app = App(label: label, state: groupState ?? state)
    let position = position ?? apps.count
    trace.append("insert id\(nextID) \(label)=\(state) at \(position)")
    apps.insert(app, at: position)
    ids.insert(nextID, at: position)
    nextID += 1
  }

  func remove(_ label: String) {
    guard let index = apps.firstIndex(where: { $0.label == label }) else { return }
    apps.remove(at: index)
    ids.remove(at: index)
  }

  func reverse() {
    apps.reverse()
    ids.reverse()
  }

  /// Reorders the list the way System Settings realistically can: apps move,
  /// but apps sharing a name keep their relative order.
  func shuffleKeepingSameNamesInOrder(_ random: inout SeededRandom) {
    defer { trace.append("shuffle -> ids \(ids)") }
    var entries = Array(zip(apps, ids))
    for index in stride(from: entries.count - 1, to: 0, by: -1) {
      let other = Int(random.nextDouble() * Double(index + 1))
      entries.swapAt(index, other)
    }
    // Restore the original relative order within each name.
    var byName: [String: [(App, Int)]] = [:]
    for (app, id) in zip(apps, ids) { byName[app.label, default: []].append((app, id)) }
    var used: [String: Int] = [:]
    entries = entries.map { entry in
      let name = entry.0.label
      let position = used[name, default: 0]
      used[name] = position + 1
      return byName[name]![position]
    }
    apps = entries.map(\.0)
    ids = entries.map(\.1)
  }

  func setStuck(_ label: String) {
    for index in apps.indices where apps[index].label == label { apps[index].stuck = true }
  }

  func setState(_ label: String, _ state: ToggleState) {
    for index in apps.indices where apps[index].label == label { apps[index].state = state }
  }

  /// Something outside the app changes a switch, overriding pending changes.
  func force(_ label: String, _ state: ToggleState) {
    applyPending(all: true)
    setState(label, state)
  }

  func groupPressCount(_ label: String) -> Int { pressCount(label) }

  /// Simulates System Settings crashing or being quit by someone else.
  func crash() {
    trace.append("crash")
    running = false
    pending.removeAll()
  }

  func states() -> [String: ToggleState] {
    applyPending()
    return Dictionary(apps.map { ($0.label, $0.state) }, uniquingKeysWith: { first, _ in first })
  }

  func pressCount(_ label: String) -> Int {
    pressLog.filter { $0 == label }.count
  }

  // MARK: SettingsSession

  func close() throws {
    closeCount += 1
    if (closeFails || closeFailsFromOpen.map { openCount >= $0 } == true) && running {
      throw LocalNetworkError.systemSettingsDidNotQuit
    }
    staleShownOn = []
    // Quitting completes any change System Settings had already accepted; it
    // never surfaces later in a new session.
    applyPending(all: true)
    running = false
  }

  func openLocalNetworkPage() throws {
    openCount += 1
    trace.append("open: " + apps.enumerated().map { "id\(ids[$0.offset]) \($0.element.label)=\($0.element.state)" }.joined(separator: ", "))
    if failNextOpens > 0 {
      failNextOpens -= 1
      throw LocalNetworkError.localNetworkPageNotFound
    }
    running = true
  }

  func diagnosticDump() -> String { "fake" }

  func permissionRows() throws -> [PermissionRow] {
    try beginRead()
    fullReadCount += 1
    afterFullRead?(fullReadCount)
    return apps.enumerated().map { index, app in
      PermissionRow(
        index: index, label: app.label, state: displayedState(index), listSize: apps.count)
    }
  }

  func permissionRow(at index: Int) throws -> PermissionRow {
    try beginRead()
    guard apps.indices.contains(index) else { throw LocalNetworkError.rowNoLongerExists(index) }
    return PermissionRow(
      index: index, label: apps[index].label, state: displayedState(index), listSize: apps.count)
  }

  func pressToggle(at index: Int, expecting key: RowKey) throws {
    try beginRead(injectTransientErrors: false)
    guard apps.indices.contains(index) else { throw LocalNetworkError.rowNoLongerExists(index) }
    guard apps[index].label == key.label else { throw LocalNetworkError.rowChanged(index) }
    pressLog.append(apps[index].label)
    trace.append(
      "t=\(String(format: "%.2f", clock.now.timeIntervalSinceReferenceDate)) press #\(pressLog.count) id\(ids[index]) \(apps[index].label) now=\(apps[index].state) key=\(key)")

    if let latencyForPress { pressLatency = latencyForPress(pressLog.count) }
    if dropsPressesWithin > 0 && clock.now.timeIntervalSince(lastAppliedAt) < dropsPressesWithin {
      tooSoonPresses += 1
    } else if droppedPresses > 0 {
      droppedPresses -= 1
    } else if !apps[index].stuck {
      let label = apps[index].label
      let affected =
        linkedNames.contains(label)
        ? apps.indices.filter { apps[$0].label == label } : [index]
      for position in affected {
        let id = ids[position]
        let base = pending.last(where: { $0.id == id })?.state ?? apps[position].state
        pending.append(
          Pending(id: id, state: base == .on ? .off : .on, visibleAt: clock.now + pressLatency))
      }
    }
    afterPress?(pressLog.count)
    if ambiguousPressErrors > 0 {
      ambiguousPressErrors -= 1
      throw AccessibilityElementError.operationFailed("perform AXPress", .cannotComplete)
    }
  }

  // MARK: Simulation

  private func beginRead(injectTransientErrors: Bool = true) throws {
    if accessibilityRevoked {
      throw AccessibilityElementError.operationFailed("read AXWindows", .apiDisabled)
    }
    guard running else { throw LocalNetworkError.systemSettingsQuitUnexpectedly }
    applyPending()
    readCount += 1
    if ProcessInfo.processInfo.environment["CHAOS_SEED"] != nil && readCount % 1 == 0 {
      let view = apps.indices.map { "id\(ids[$0])=\(displayedStatePeek($0))" }.joined(separator: " ")
      if view != lastView { trace.append(String(format: "t=%.2f view ", clock.now.timeIntervalSinceReferenceDate) + view); lastView = view }
    }
    if injectTransientErrors && random.nextDouble() < transientErrorRate {
      throw AccessibilityElementError.operationFailed("read AXValue", .cannotComplete)
    }
  }

  private var lastView = ""
  private func displayedStatePeek(_ index: Int) -> ToggleState {
    staleShownOn.contains(ids[index]) ? .on : apps[index].state
  }

  private func displayedState(_ index: Int) -> ToggleState {
    if flapping.remove(ids[index]) != nil { return .off }
    if staleShownOn.contains(ids[index]) { return .on }
    return apps[index].state
  }

  private func applyPending(all: Bool = false) {
    let due = pending.filter { all || $0.visibleAt <= clock.now }
    pending.removeAll { all || $0.visibleAt <= clock.now }
    for change in due {
      guard let index = ids.firstIndex(of: change.id) else { continue }
      if change.state == .on && staleOnDisplay.contains(apps[index].label) {
        // Shown on in this session, but not saved. The first fresh session
        // reveals it; afterwards presses work unless it is stale forever.
        staleShownOn.insert(change.id)
        if !staleForever { staleOnDisplay.remove(apps[index].label) }
        continue
      }
      staleShownOn.remove(change.id)
      apps[index].state = change.state
      lastAppliedAt = min(change.visibleAt, clock.now)
      if change.state == .on && flapAfterOn { flapping.insert(change.id) }
    }
  }
}

final class MemoryRecoveryStore: RecoveryStore {
  var state = RecoveryState()
  var keys: Set<RowKey> { state.keys }
  var failSaves = false
  var cleared = 0

  func load() -> RecoveryState { state }

  func save(_ state: RecoveryState) throws {
    if failSaves { throw CocoaError(.fileWriteNoPermission) }
    self.state = state
  }

  func clear() {
    state = RecoveryState()
    cleared += 1
  }
}

/// A small deterministic generator so injected failures are reproducible.
struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func nextDouble() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(state >> 11) / Double(1 << 53)
  }
}
