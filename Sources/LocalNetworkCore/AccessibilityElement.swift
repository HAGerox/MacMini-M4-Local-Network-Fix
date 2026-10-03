import ApplicationServices
import Foundation

enum AccessibilityElementError: LocalizedError {
  case operationFailed(String, AXError)
  case missingAttribute(String)
  case unexpectedAttribute(String)

  var errorDescription: String? {
    switch self {
    case .operationFailed(let operation, let error):
      return "Accessibility could not \(operation) (error \(error.rawValue))."
    case .missingAttribute(let attribute):
      return "System Settings did not expose its \(attribute) Accessibility attribute."
    case .unexpectedAttribute(let attribute):
      return
        "System Settings returned an unexpected value for its \(attribute) Accessibility attribute."
    }
  }
}

extension AXError {
  var isTransient: Bool {
    self == .cannotComplete || self == .invalidUIElement || self == .failure
  }
}

struct AccessibilityElement {
  let rawValue: AXUIElement

  func value(for attribute: String) throws -> Any {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(rawValue, attribute as CFString, &value)
    guard error == .success else {
      throw AccessibilityElementError.operationFailed("read \(attribute)", error)
    }
    guard let value else {
      throw AccessibilityElementError.missingAttribute(attribute)
    }
    return value
  }

  func optionalValue(for attribute: String) throws -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(rawValue, attribute as CFString, &value)
    if error == .noValue || error == .attributeUnsupported {
      return nil
    }
    guard error == .success else {
      throw AccessibilityElementError.operationFailed("read \(attribute)", error)
    }
    return value
  }

  func stringValue(for attribute: String) throws -> String? {
    guard let value = try optionalValue(for: attribute) else { return nil }
    guard let string = value as? String else {
      throw AccessibilityElementError.unexpectedAttribute(attribute)
    }
    return string
  }

  func elements(for attribute: String) throws -> [AccessibilityElement] {
    guard let value = try optionalValue(for: attribute) else { return [] }
    guard let elements = value as? [AXUIElement] else {
      throw AccessibilityElementError.unexpectedAttribute(attribute)
    }
    return elements.map(AccessibilityElement.init)
  }

  func element(for attribute: String) throws -> AccessibilityElement? {
    guard let value = try optionalValue(for: attribute) else { return nil }
    let cfValue = value as CFTypeRef
    guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
      throw AccessibilityElementError.unexpectedAttribute(attribute)
    }
    return AccessibilityElement(
      rawValue: unsafeDowncast(cfValue as AnyObject, to: AXUIElement.self)
    )
  }

  func children(withRole role: String) throws -> [AccessibilityElement] {
    try elements(for: kAXChildrenAttribute as String).filter {
      try $0.stringValue(for: kAXRoleAttribute as String) == role
    }
  }

  func child(withRole role: String, occurrence: Int) throws -> AccessibilityElement? {
    let matches = try children(withRole: role)
    guard matches.indices.contains(occurrence) else { return nil }
    return matches[occurrence]
  }

  /// Breadth-first search limited in depth and size, so a changed or very
  /// large interface can never make a lookup unbounded. Elements that fail to
  /// answer are skipped.
  func firstDescendant(
    maxDepth: Int,
    maxNodes: Int = 3000,
    where matches: (AccessibilityElement) throws -> Bool
  ) -> AccessibilityElement? {
    var queue: [(element: AccessibilityElement, depth: Int)] = [(self, 0)]
    var cursor = 0
    while cursor < queue.count && cursor < maxNodes {
      let (element, depth) = queue[cursor]
      cursor += 1
      if cursor > 1, (try? matches(element)) == true {
        return element
      }
      guard depth < maxDepth,
        let children = try? element.elements(for: kAXChildrenAttribute as String)
      else { continue }
      queue.append(contentsOf: children.map { ($0, depth + 1) })
    }
    return nil
  }

  func firstDescendant(withRole role: String, maxDepth: Int) -> AccessibilityElement? {
    firstDescendant(maxDepth: maxDepth) {
      try $0.stringValue(for: kAXRoleAttribute as String) == role
    }
  }

  func perform(action: String) throws {
    let error = AXUIElementPerformAction(rawValue, action as CFString)
    guard error == .success else {
      throw AccessibilityElementError.operationFailed("perform \(action)", error)
    }
  }

}
