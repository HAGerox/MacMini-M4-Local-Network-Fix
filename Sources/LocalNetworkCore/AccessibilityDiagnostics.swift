import ApplicationServices
import Foundation

/// Produces a bounded text dump of an Accessibility subtree so layout changes
/// in System Settings can be diagnosed from a tester's log.
enum AccessibilityDiagnostics {
  static func describe(
    _ element: AccessibilityElement,
    maxDepth: Int = 14,
    maxNodes: Int = 4000
  ) -> String {
    var lines: [String] = []
    var remaining = maxNodes
    visit(element, depth: 0, path: "", maxDepth: maxDepth, remaining: &remaining, lines: &lines)
    if remaining <= 0 {
      lines.append("… truncated after \(maxNodes) elements")
    }
    return lines.joined(separator: "\n")
  }

  private static func visit(
    _ element: AccessibilityElement,
    depth: Int,
    path: String,
    maxDepth: Int,
    remaining: inout Int,
    lines: inout [String]
  ) {
    guard remaining > 0 else { return }
    remaining -= 1

    var fields: [String] = []
    for attribute in [
      kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
      kAXDescriptionAttribute, kAXValueAttribute,
    ] {
      if let value = try? element.optionalValue(for: attribute as String),
        let text = printable(value)
      {
        fields.append("\(attribute)=\(text)")
      }
    }
    if let rows = try? element.elements(for: kAXRowsAttribute as String), !rows.isEmpty {
      fields.append("AXRows=\(rows.count)")
    }
    lines.append(String(repeating: "  ", count: depth) + path + " " + fields.joined(separator: " "))

    guard depth < maxDepth else { return }
    var children = (try? element.elements(for: kAXChildrenAttribute as String)) ?? []
    if depth == 0, let windows = try? element.elements(for: kAXWindowsAttribute as String) {
      lines.append("windows: \(windows.count)")
      children = windows
    }
    for (index, child) in children.enumerated() {
      visit(
        child, depth: depth + 1, path: "[\(index)]", maxDepth: maxDepth,
        remaining: &remaining, lines: &lines)
    }
  }

  private static func printable(_ value: Any) -> String? {
    switch value {
    case let string as String:
      let trimmed = string.count > 80 ? String(string.prefix(80)) + "…" : string
      return "\"\(trimmed)\""
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }
}
