import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// A view over the whole screen above everything else (the menu bar included) that takes the keyboard: a picture
/// viewer that leaves no window chrome. A borderless panel on the Mac; elsewhere `isAvailable` is false and
/// `present` does nothing.
@MainActor public enum FullScreenViewer {
  /// The keys a viewer handles.
  public enum Key: Sendable { case previous, next, close, character(Character) }

  public static var isAvailable: Bool {
    #if canImport(AppKit)
      true
    #else
      false
    #endif
  }

  #if canImport(AppKit)
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
  #endif

  /// Fades `content` in over the screen of the key window. `onKey` gets ← ↑ (previous), → ↓ (next), Esc and Space
  /// (close) and plain characters; true when it handled the key.
  public static func present<Content: View>(_ content: Content, onKey: @escaping @MainActor (Key) -> Bool) {
    #if canImport(AppKit)
      dismiss(animated: false)
      let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
      let panel = ViewerPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
      panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hidesOnDeactivate = true
      panel.isReleasedWhenClosed = false
      panel.contentView = NSHostingView(rootView: content)
      panel.setFrame(screen.frame, display: true)
      panel.alphaValue = 0
      panel.makeKeyAndOrderFront(nil)
      NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
      self.panel = panel

      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.window === Self.panel else { return event }
        let key: Key
        switch event.keyCode {
        case 123, 126: key = .previous  // ← ↑
        case 124, 125: key = .next  // → ↓
        case 53, 49: key = .close  // Esc, Space
        default:
          guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            let character = event.charactersIgnoringModifiers?.lowercased().first
          else { return event }
          key = .character(character)
        }
        return onKey(key) ? nil : event
      }
    #endif
  }

  public static func dismiss(animated: Bool = true) {
    #if canImport(AppKit)
      if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
      keyMonitor = nil
      guard let panel else { return }
      self.panel = nil
      guard animated else {
        panel.orderOut(nil)
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        panel.animator().alphaValue = 0
      } completionHandler: {
        panel.orderOut(nil)
      }
    #endif
  }
}

#if canImport(AppKit)
  /// A borderless panel that still takes the keyboard.
  private final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
  }
#endif
