import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
public enum AccessibilityPermission {
  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Adds this app to the Accessibility list and asks macOS to show its own
  /// permission prompt. macOS usually shows that prompt only the first time.
  public static func requestSystemPrompt() {
    // The SDK imports kAXTrustedCheckOptionPrompt as mutable global state,
    // which Swift 6 rejects even on the main actor. This is its documented
    // dictionary key value.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  /// Whether macOS's own Accessibility prompt is on screen, so the app's own
  /// guidance is never shown on top of it.
  public static var isSystemPromptVisible: Bool {
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return windows.contains { $0[kCGWindowOwnerName as String] as? String == "universalAccessAuthWarn" }
  }

  /// Waits up to `timeout` for access, returning early once macOS's prompt
  /// has been dismissed without granting it.
  public static func waitWhileSystemPromptIsHandled(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.25
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    // Give the prompt a moment to appear before checking for it.
    let promptAppearDeadline = Date().addingTimeInterval(1.5)
    var promptSeen = false
    while Date() < deadline {
      if isTrusted { return true }
      let visible = isSystemPromptVisible
      promptSeen = promptSeen || visible
      if !visible && (promptSeen || Date() >= promptAppearDeadline) {
        return isTrusted
      }
      SystemSettingsController.pause(pollInterval)
    }
    return isTrusted
  }
}
