import AppKit
import ApplicationServices
import Darwin
import Foundation

@MainActor
public protocol SettingsSession: LocalNetworkUI {
  /// Quits every running System Settings process.
  func close() throws
  /// Opens System Settings at Privacy & Security > Local Network and waits
  /// until the permission list has finished loading.
  func openLocalNetworkPage() throws
  /// A text description of the System Settings interface for failure logs.
  func diagnosticDump() -> String
}

public struct SettingsConfiguration: Sendable {
  public var navigationTimeout: TimeInterval
  public var quitTimeout: TimeInterval
  public var pollInterval: TimeInterval
  /// How long the row count must stay unchanged before the list counts as loaded.
  public var listSettleInterval: TimeInterval
  /// How long the Local Network list must stay absent before the page is
  /// accepted as empty. Long, because a list still loading at startup must
  /// never be mistaken for one with nothing to reset.
  public var emptyListGrace: TimeInterval
  public var navigationRetryInterval: TimeInterval
  /// Upper bound for any single Accessibility call to System Settings.
  public var messagingTimeout: Float

  public init(
    navigationTimeout: TimeInterval = 15,
    quitTimeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.03,
    listSettleInterval: TimeInterval = 0.25,
    emptyListGrace: TimeInterval = 10,
    navigationRetryInterval: TimeInterval = 1.5,
    messagingTimeout: Float = 3
  ) {
    self.navigationTimeout = navigationTimeout
    self.quitTimeout = quitTimeout
    self.pollInterval = pollInterval
    self.listSettleInterval = listSettleInterval
    self.emptyListGrace = emptyListGrace
    self.navigationRetryInterval = navigationRetryInterval
    self.messagingTimeout = messagingTimeout
  }
}

@MainActor
public final class SystemSettingsController: SettingsSession {
  public static let bundleIdentifier = "com.apple.systempreferences"
  public static let privacyURL = URL(
    string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
  )!
  public static let accessibilityURL = URL(
    string:
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
  )!
  public static let localNetworkIdentifier = "Local Network_Navigator"

  /// System Settings names the Local Network page, and its navigator's
  /// identifier, in the Mac's language. These are Apple's own translations,
  /// read from the Privacy & Security extension, so the page is recognised
  /// exactly in every language. English is always included.
  public static let localNetworkNames: Set<String> = {
    var names: Set<String> = ["Local Network"]
    let table = URL(
      fileURLWithPath:
        "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable"
    )
    if let data = try? Data(contentsOf: table),
      let languages = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    {
      for case let strings as [String: Any] in languages.values {
        if let name = strings["LOCAL_NETWORK"] as? String, !name.isEmpty {
          names.insert(name)
        }
      }
    }
    return names
  }()

  static func isLocalNetworkNavigator(identifier: String?) -> Bool {
    guard let identifier, identifier.hasSuffix("_Navigator") else { return false }
    return localNetworkNames.contains(String(identifier.dropLast("_Navigator".count)))
  }

  /// Force-quits System Settings from any thread. Used by the watchdog to
  /// unblock a call that is waiting on a wedged System Settings.
  public nonisolated static func forceQuitFromAnyThread() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    task.arguments = ["-9", "-x", "System Settings"]
    try? task.run()
    task.waitUntilExit()
  }

  /// Receives a description of what navigation was waiting for when it gave up.
  public var diagnosticLog: ((String) -> Void)?

  /// Extra launch arguments for System Settings, used by the self-test to run
  /// it in another language.
  public var launchArguments: [String] = []

  private let configuration: SettingsConfiguration
  private var applicationElement: AccessibilityElement?
  private var applicationPID: pid_t?
  /// Window titles that identify the Local Network page. The navigator's own
  /// label is added when found, so non-English systems are recognised.
  private var pageTitles: Set<String> = SystemSettingsController.localNetworkNames
  private var navigatorPressedAt: Date?
  private var lastNavigatorSearch = Date.distantPast
  /// Whether the loaded page showed permissions. If so, a missing list later
  /// means System Settings is refreshing, not that the list is empty.
  private var pageHadRows = false
  private var lastRowCount = -1
  private var lastStage = ""
  /// The title of the Local Network window when it was last found.
  public private(set) var pageTitle: String?

  public init(configuration: SettingsConfiguration = SettingsConfiguration()) {
    self.configuration = configuration
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), configuration.messagingTimeout)
  }

  // MARK: Lifecycle

  public func close() throws {
    defer { detach() }
    let applications = runningApplications()
    guard !applications.isEmpty else { return }
    let processIdentifiers = applications.map(\.processIdentifier)

    // Quitting System Settings while it is still launching, or while an open
    // request is on its way to it, makes macOS show "System Settings is not
    // open anymore". Let it finish launching first.
    let launchDeadline = Date().addingTimeInterval(configuration.quitTimeout)
    while applications.contains(where: { !$0.isFinishedLaunching && !$0.isTerminated }),
      Date() < launchDeadline
    {
      Self.pause(configuration.pollInterval)
    }

    // Signals are used instead of a quit Apple Event, which would require
    // Automation permission. A hung System Settings is force-killed.
    var quit = false
    for signal in [SIGTERM, SIGKILL] {
      for processIdentifier in processIdentifiers where Self.isAlive(processIdentifier) {
        Darwin.kill(processIdentifier, signal)
      }
      let deadline = Date().addingTimeInterval(configuration.quitTimeout)
      while processIdentifiers.contains(where: Self.isAlive) && Date() < deadline {
        Self.pause(configuration.pollInterval)
      }
      if !processIdentifiers.contains(where: Self.isAlive) {
        quit = true
        break
      }
    }
    guard quit else { throw LocalNetworkError.systemSettingsDidNotQuit }

    // Wait until macOS has also forgotten the old instance, so the next open
    // request launches a new one instead of being sent to the one that quit.
    let forgetDeadline = Date().addingTimeInterval(configuration.quitTimeout)
    while Date() < forgetDeadline,
      NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        .contains(where: { processIdentifiers.contains($0.processIdentifier) && !$0.isTerminated })
    {
      Self.pause(configuration.pollInterval)
    }
    Self.pause(0.3)
  }


  public func openLocalNetworkPage() throws {
    detach()
    navigatorPressedAt = nil
    lastNavigatorSearch = .distantPast
    pageHadRows = false
    let deadline = Date().addingTimeInterval(configuration.navigationTimeout)

    if !launchArguments.isEmpty, runningApplications().isEmpty {
      try launchWithArguments(deadline: deadline)
    }
    // Launch Services can briefly refuse to open System Settings just after
    // the previous instance quit, so opening is retried within the deadline.
    while !NSWorkspace.shared.open(Self.privacyURL) {
      guard Date() < deadline else { throw LocalNetworkError.systemSettingsDidNotLaunch }
      Self.pause(0.5)
    }

    var activated = false
    var nextNavigationAttempt = Date.distantPast
    lastRowCount = -1
    var rowCountChangedAt = Date()

    while Date() < deadline {
      defer { Self.pause(configuration.pollInterval) }
      guard let application = runningApplications().first else { continue }
      attach(to: application)
      if !activated {
        application.activate()
        activated = true
      }

      do {
        if let window = try localNetworkWindow() {
          let now = Date()
          // The cheap row count shows when loading has finished; one full
          // read then proves every row can be read before continuing. Only a
          // list that is cleanly absent counts as empty: a failed read means
          // System Settings is still busy, and is polled again.
          let count: Int
          do {
            count = try listRows(of: outline(in: window)).count
          } catch LocalNetworkError.localNetworkListNotFound {
            count = 0
          }
          if count != lastRowCount {
            lastRowCount = count
            rowCountChangedAt = now
          } else if count > 0,
            now.timeIntervalSince(rowCountChangedAt) >= configuration.listSettleInterval,
            (try? rows(in: window).isEmpty) == false
          {
            pageHadRows = true
            return
          } else if count == 0,
            now.timeIntervalSince(rowCountChangedAt) >= configuration.emptyListGrace
          {
            // No app has requested Local Network access.
            return
          }
        } else if Date() >= nextNavigationAttempt, let navigator = try findNavigator() {
          try navigator.perform(action: kAXPressAction as String)
          navigatorPressedAt = navigatorPressedAt ?? Date()
          nextNavigationAttempt = Date().addingTimeInterval(configuration.navigationRetryInterval)
        }
      } catch {
        if error.isFatalAccessibilityError { throw error }
        // System Settings is still building or replacing its interface, or
        // was relaunched; the next poll attaches to the new process.
      }
    }
    let titles = ((try? windows()) ?? []).map {
      (try? $0.stringValue(for: kAXTitleAttribute as String)) ?? "?"
    }
    diagnosticLog?(
      "Navigation gave up: running \(!runningApplications().isEmpty), windows \(titles), "
        + "navigator pressed \(navigatorPressedAt != nil), last row count \(lastRowCount)")
    throw LocalNetworkError.localNetworkPageNotFound
  }

  private func launchWithArguments(deadline: Date) throws {
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    else { throw LocalNetworkError.systemSettingsDidNotLaunch }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = launchArguments
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    while runningApplications().isEmpty {
      guard Date() < deadline else { throw LocalNetworkError.systemSettingsDidNotLaunch }
      Self.pause(self.configuration.pollInterval)
    }
    Self.pause(0.5)
  }

  // MARK: LocalNetworkUI

  public func permissionRows() throws -> [PermissionRow] {
    guard let window = try localNetworkWindow() else {
      throw LocalNetworkError.localNetworkPageNotFound
    }
    do {
      return try rows(in: window).map(\.row)
    } catch LocalNetworkError.localNetworkListNotFound where !pageHadRows {
      // The page loaded without any permission list: nothing to reset.
      return []
    }
  }

  public func permissionRow(at index: Int) throws -> PermissionRow {
    try resolvedRow(at: index).row
  }

  public func pressToggle(at index: Int, expecting key: RowKey) throws {
    let resolved = try resolvedRow(at: index)
    guard key.matches(resolved.row) else {
      throw LocalNetworkError.rowChanged(index)
    }
    try resolved.checkbox.perform(action: kAXPressAction as String)
  }

  /// The vertical scroll position of the Local Network page, used by tests to
  /// prove that resetting never scrolls the list.
  public func permissionScrollValue() throws -> Double? {
    guard let window = try localNetworkWindow(),
      let scrollArea = try outerScrollArea(in: window),
      let scrollBar = try scrollArea.element(for: kAXVerticalScrollBarAttribute as String)
    else { return nil }
    return (try scrollBar.value(for: kAXValueAttribute as String) as? NSNumber)?.doubleValue
  }

  /// Reads every row individually, recording the first failure of each, so a
  /// row System Settings cannot answer for is identified in the logs.
  public func rowDiagnostics() -> String {
    do {
      guard let window = try localNetworkWindow() else { return "Local Network page not open" }
      let rowElements = try listRows(of: outline(in: window))
      return rowElements.enumerated().map { index, element in
        do {
          guard let resolved = try resolve(row: element, index: index, listSize: rowElements.count)
          else { return "\(index): no switch" }
          return "\(index): \(resolved.row.label)=\(resolved.row.state)"
        } catch {
          let role = (try? element.stringValue(for: kAXRoleAttribute as String)) ?? "?"
          let children = (try? element.elements(for: kAXChildrenAttribute as String).count)
            .map(String.init) ?? "?"
          var detail = ""
          if let cell = try? element.child(withRole: kAXCellRole as String, occurrence: 0),
            let parts = try? cell.elements(for: kAXChildrenAttribute as String)
          {
            for part in parts {
              var value: CFTypeRef?
              let roleText = (try? part.stringValue(for: kAXRoleAttribute as String)) ?? "?"
              let code = AXUIElementCopyAttributeValue(
                part.rawValue, kAXValueAttribute as CFString, &value)
              detail += " [\(roleText) value=\(code.rawValue):\(String(describing: value))]"
            }
          }
          return "\(index): FAILED \(error) role=\(role) children=\(children)\(detail)"
        }
      }.joined(separator: "\n")
    } catch {
      return "row diagnostics failed: \(error)"
    }
  }

  public func probeRow(_ index: Int) -> String {
    var out = ""
    func code(_ element: AXUIElement, _ attribute: String) -> String {
      var value: CFTypeRef?
      let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
      return "\(attribute)=\(error.rawValue):\(value.map { String(describing: $0).prefix(40) } ?? "nil")"
    }
    for round in 1...4 {
      guard let window = try? localNetworkWindow(), let outline = try? outline(in: window),
        let rows = try? listRows(of: outline), rows.indices.contains(index)
      else { return out + "no rows" }
      let row = rows[index].rawValue
      out += "round \(round): row \(code(row, kAXRoleAttribute))\n"
      var children: CFTypeRef?
      AXUIElementCopyAttributeValue(row, kAXChildrenAttribute as CFString, &children)
      for cell in (children as? [AXUIElement]) ?? [] {
        out += "  cell \(code(cell, kAXRoleAttribute))\n"
        var parts: CFTypeRef?
        AXUIElementCopyAttributeValue(cell, kAXChildrenAttribute as CFString, &parts)
        for part in (parts as? [AXUIElement]) ?? [] {
          out += "    \(code(part, kAXRoleAttribute)) \(code(part, kAXValueAttribute)) \(code(part, kAXValueAttribute)) \(code(part, kAXTitleAttribute))\n"
        }
      }
    }
    return out
  }

  public func diagnosticDump() -> String {
    diagnosticDump(bundleIdentifier: Self.bundleIdentifier)
  }

  public func diagnosticDump(bundleIdentifier: String) -> String {
    guard
      let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first
    else { return "\(bundleIdentifier) is not running." }
    let element = AccessibilityElement(
      rawValue: AXUIElementCreateApplication(application.processIdentifier))
    return AccessibilityDiagnostics.describe(element)
  }

  // MARK: Process helpers

  private func runningApplications() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
      .filter { !$0.isTerminated && Self.isAlive($0.processIdentifier) }
  }

  private func attach(to application: NSRunningApplication) {
    guard applicationPID != application.processIdentifier else { return }
    applicationPID = application.processIdentifier
    applicationElement = AccessibilityElement(
      rawValue: AXUIElementCreateApplication(application.processIdentifier))
  }

  private func detach() {
    applicationPID = nil
    applicationElement = nil
  }

  nonisolated static func isAlive(_ processIdentifier: pid_t) -> Bool {
    Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
  }

  /// Waits while still servicing the run loop, so AppKit stays responsive.
  public nonisolated static func pause(_ interval: TimeInterval) {
    Watchdog.shared.beat()
    guard interval > 0 else { return }
    let end = Date().addingTimeInterval(interval)
    RunLoop.current.run(until: end)
    let remaining = end.timeIntervalSinceNow
    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    Watchdog.shared.beat()
  }

  // MARK: Interface lookup

  private func windows() throws -> [AccessibilityElement] {
    guard let applicationElement, let applicationPID, Self.isAlive(applicationPID) else {
      throw LocalNetworkError.systemSettingsQuitUnexpectedly
    }
    return try applicationElement.elements(for: kAXWindowsAttribute as String)
  }

  private func localNetworkWindow() throws -> AccessibilityElement? {
    let windows = try windows()
    for window in windows {
      if let title = try window.stringValue(for: kAXTitleAttribute as String),
        pageTitles.contains(title)
      {
        pageTitle = title
        return window
      }
    }
    // Only a positively identified Local Network page is used, so switches on
    // any other privacy page can never be pressed.
    return nil
  }

  private func findNavigator() throws -> AccessibilityElement? {
    for window in try windows() {
      if let navigator = try navigatorButton(in: window) {
        // Learn the localised page title from the navigator's own label.
        for label in Self.labels(of: navigator) {
          pageTitles.insert(label)
        }
        return navigator
      }
    }
    return nil
  }

  private func navigatorButton(in window: AccessibilityElement) throws -> AccessibilityElement? {
    // Fast path: the Privacy & Security security section.
    if let scrollArea = try? outerScrollArea(in: window),
      let securityGroup = try? scrollArea.child(withRole: kAXGroupRole as String, occurrence: 3)
    {
      for button in (try? securityGroup.children(withRole: kAXButtonRole as String)) ?? [] {
        if Self.isLocalNetworkNavigator(
          identifier: try? button.stringValue(for: kAXIdentifierAttribute as String))
        {
          return button
        }
      }
    }

    // Fallback for a rearranged Privacy & Security page, rate-limited because
    // it visits far more elements.
    guard Date().timeIntervalSince(lastNavigatorSearch) >= 0.5 else { return nil }
    lastNavigatorSearch = Date()
    return window.firstDescendant(maxDepth: 12) {
      Self.isLocalNetworkNavigator(identifier: try $0.stringValue(for: kAXIdentifierAttribute as String))
    }
  }

  private func outerScrollArea(in window: AccessibilityElement) throws -> AccessibilityElement? {
    guard let windowGroup = try window.child(withRole: kAXGroupRole as String, occurrence: 0),
      let splitGroup = try windowGroup.child(withRole: kAXSplitGroupRole as String, occurrence: 0),
      let detailGroup = try splitGroup.child(withRole: kAXGroupRole as String, occurrence: 1),
      let contentGroup = try detailGroup.child(withRole: kAXGroupRole as String, occurrence: 0)
    else { return nil }
    return try contentGroup.child(withRole: kAXScrollAreaRole as String, occurrence: 0)
  }

  private func outline(in window: AccessibilityElement) throws -> AccessibilityElement {
    // Fast path: the hierarchy used by macOS 15.
    if let scrollArea = try outerScrollArea(in: window),
      let group = try scrollArea.child(withRole: kAXGroupRole as String, occurrence: 0),
      let innerScrollArea = try group.child(withRole: kAXScrollAreaRole as String, occurrence: 0),
      let outline = try innerScrollArea.child(withRole: kAXOutlineRole as String, occurrence: 0)
    {
      return outline
    }
    // Fallback for a rearranged page: the first outline or table whose rows
    // hold switches. This excludes the System Settings sidebar outline.
    if let outline = window.firstDescendant(maxDepth: 12, where: { candidate in
      let role = try candidate.stringValue(for: kAXRoleAttribute as String)
      guard role == kAXOutlineRole as String || role == kAXTableRole as String else {
        return false
      }
      return try candidate.elements(for: kAXRowsAttribute as String).prefix(3).contains {
        $0.firstDescendant(withRole: kAXCheckBoxRole as String, maxDepth: 3) != nil
      }
    }) {
      return outline
    }
    throw LocalNetworkError.localNetworkListNotFound
  }

  private struct ResolvedRow {
    var row: PermissionRow
    var checkbox: AccessibilityElement
  }

  private func rows(in window: AccessibilityElement) throws -> [ResolvedRow] {
    let outline = try outline(in: window)
    let rowElements = try listRows(of: outline)
    // A row that fails to answer aborts the whole read rather than being
    // skipped, so a permission can never be silently left out.
    return try rowElements.indices.map {
      try resolveRetrying(index: $0, in: outline, first: rowElements)
    }
  }

  private func resolvedRow(at index: Int) throws -> ResolvedRow {
    guard let window = try localNetworkWindow() else {
      throw LocalNetworkError.localNetworkPageNotFound
    }
    let outline = try outline(in: window)
    let rowElements = try listRows(of: outline)
    guard rowElements.indices.contains(index) else {
      throw LocalNetworkError.rowNoLongerExists(index)
    }
    return try resolveRetrying(index: index, in: outline, first: rowElements)
  }

  /// The outline's rows in one Accessibility call.
  private func listRows(of outline: AccessibilityElement) throws -> [AccessibilityElement] {
    try outline.elements(for: kAXRowsAttribute as String)
  }

  /// Off-screen rows are built lazily and their elements are often invalid
  /// when first asked. Each retry fetches the row afresh from the list, which
  /// returns a live element, so every row is read without ever skipping one.
  private func resolveRetrying(
    index: Int, in outline: AccessibilityElement, first rowElements: [AccessibilityElement]
  ) throws -> ResolvedRow {
    var rows = rowElements
    var attempt = 0
    while true {
      do {
        // A row whose switch is not exposed yet is retried like any other
        // unreadable row, never skipped.
        guard let resolved = try resolve(row: rows[index], index: index, listSize: rows.count)
        else { throw LocalNetworkError.rowNoLongerExists(index) }
        return resolved
      } catch {
        attempt += 1
        if error.isFatalAccessibilityError || attempt >= 5 {
          if ProcessInfo.processInfo.environment["TLN_TRACE"] == "1" {
            FileHandle.standardError.write(Data("row \(index) failed \(attempt)x: \(error.localizedDescription) stage=\(lastStage)\n".utf8))
          }
          throw error
        }
        if attempt > 1 { Self.pause(0.01) }
        let fresh = try listRows(of: outline)
        // If the list changed size, the caller must start its read again.
        guard fresh.count == rows.count else { throw error }
        rows = fresh
      }
    }
  }

  private func resolve(
    row: AccessibilityElement, index: Int, listSize: Int
  ) throws -> ResolvedRow? {
    lastStage = "cell"
    let container = try row.child(withRole: kAXCellRole as String, occurrence: 0) ?? row

    // The name and switch are taken from one read of the cell's children.
    // Asking a lazily built off-screen cell for its children again can
    // return elements that are already invalid.
    lastStage = "parts"
    var text: AccessibilityElement?
    var checkbox: AccessibilityElement?
    for part in try container.elements(for: kAXChildrenAttribute as String) {
      switch try part.stringValue(for: kAXRoleAttribute as String) {
      case kAXStaticTextRole as String where text == nil: text = part
      case kAXCheckBoxRole as String where checkbox == nil: checkbox = part
      default: break
      }
    }
    if checkbox == nil {
      checkbox = container.firstDescendant(withRole: kAXCheckBoxRole as String, maxDepth: 3)
      text = text ?? container.firstDescendant(withRole: kAXStaticTextRole as String, maxDepth: 3)
    }
    guard let checkbox else { return nil }

    lastStage = "label"
    let label = try Self.appName(checkbox: checkbox, text: text)
    lastStage = "state"
    let state = try ToggleState(accessibilityValue: checkbox.value(for: kAXValueAttribute as String))
    return ResolvedRow(
      row: PermissionRow(index: index, label: label, state: state, listSize: listSize),
      checkbox: checkbox)
  }

  /// The switch's identifier is "<app name>_Toggle". It is preferred because
  /// it belongs to the element that is pressed, and because the name text of
  /// some lazily built off-screen rows repeatedly fails to answer while the
  /// switch itself does. The text is the fallback on layouts without it.
  static func appName(checkbox: AccessibilityElement, text: AccessibilityElement?) throws -> String {
    if let identifier = try? checkbox.stringValue(for: kAXIdentifierAttribute as String),
      let name = appName(fromToggleIdentifier: identifier)
    {
      return name
    }
    if let text, let value = try text.stringValue(for: kAXValueAttribute as String) {
      return value
    }
    return labels(of: checkbox).first ?? ""
  }

  static func appName(fromToggleIdentifier identifier: String) -> String? {
    let suffix = "_Toggle"
    guard identifier.hasSuffix(suffix), identifier.count > suffix.count else { return nil }
    return String(identifier.dropLast(suffix.count))
  }

  private static func labels(of element: AccessibilityElement) -> [String] {
    var labels: [String] = []
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
      if let text = try? element.stringValue(for: attribute as String), !text.isEmpty {
        labels.append(text)
      }
    }
    if let text = element.firstDescendant(withRole: kAXStaticTextRole as String, maxDepth: 2),
      let value = try? text.stringValue(for: kAXValueAttribute as String), !value.isEmpty
    {
      labels.append(value)
    }
    return labels
  }
}
