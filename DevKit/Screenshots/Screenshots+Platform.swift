import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit

  extension Screenshots {
    @MainActor
    enum Platform {
      static func apply(_ appearance: ScreenshotConfig.Appearance?) {
        guard let appearance else { return }
        NSApplication.shared.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
      }

      /// A background launch doesn't present SwiftUI's first window; a reopen event (`open -g` again) does, still
      /// without focus, so after a moment the app asks `dev-screenshots` for one.
      static func waitForWindow() async {
        for attempt in 0..<300 {
          if window != nil { return }
          if attempt == 15 { ScreenshotSignal.send("reopen") }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }

      /// The windows of earlier pictures.
      private static var pictured: Set<Int> = []

      static var candidates: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil && $0.contentView != nil }
      }

      /// The window a scene opened (the newest one since the last picture, so a Settings window wins), else the
      /// front one on screen. The window server's order, since `NSApp.orderedWindows` doesn't follow it while the
      /// app is inactive, and a window an inactive app opens can land behind the one we ordered front before.
      static var window: NSWindow? {
        let candidates = candidates
        if let opened = candidates.filter({ !pictured.contains($0.windowNumber) }).max(by: { $0.windowNumber < $1.windowNumber }) {
          return opened
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] ?? []
        for info in onScreen
        where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
          if let number = info[kCGWindowNumber as String] as? Int,
            let window = candidates.first(where: { $0.windowNumber == number })
          {
            return window
          }
        }
        return candidates.first
      }

      static func present() async -> Int? {
        guard let window else { return nil }
        window.collectionBehavior.insert(.moveToActiveSpace)
        // A fixed-size window (Settings) keeps its own size.
        if let size = ScreenshotSignal.windowSize, window.styleMask.contains(.resizable) {
          window.setContentSize(NSSize(width: size.width, height: size.height))
          if let screen = window.screen ?? NSScreen.main, !screen.visibleFrame.contains(window.frame) {
            window.setFrameOrigin(
              NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: max(screen.visibleFrame.minY, screen.visibleFrame.midY - window.frame.height / 2)))
          }
        }
        while true {
          if ScreenshotSignal.activates {
            await waitForFocus()
            window.makeKeyAndOrderFront(nil)
          }
          window.orderFrontRegardless()
          window.sheets.forEach { $0.orderFrontRegardless() }
          // The resize lays out again, and a window that just got focus redraws.
          try? await Task.sleep(for: .milliseconds(600))
          // Focus lost while it settled: wait for it again.
          if !ScreenshotSignal.activates || NSApp.isActive { break }
        }
        pictured.formUnion(candidates.map(\.windowNumber))
        return window.windowNumber
      }

      private static var askedToActivate = false

      /// Until the app is the active one. An app launched in the background can't make itself active, so the first
      /// time it asks `dev-screenshots`, which reopens it like a Dock click. After that a reader who switched to
      /// another app is waited for, not interrupted: the capture goes on when they come back.
      static func waitForFocus() async {
        guard !NSApp.isActive else { return }
        if !askedToActivate {
          askedToActivate = true
          ScreenshotSignal.send("activate")
        }
        while !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
      }

      private static var focusObservers: [NSObjectProtocol] = []

      /// Tells `dev-screenshots` when the app gains and loses focus, so it pauses its timeout while the reader is
      /// elsewhere and retakes a picture that focus left during.
      static func reportFocus() {
        let center = NotificationCenter.default
        focusObservers = [
          center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ScreenshotSignal.send("focus active")
          },
          center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            ScreenshotSignal.send("focus inactive")
          },
        ]
      }
    }
  }

#elseif canImport(UIKit)
  import UIKit

  extension Screenshots {
    @MainActor
    enum Platform {
      /// `dev-screenshots` sets the simulator's appearance for a launch; a later scene in the same launch switches
      /// the app's windows.
      static func reportFocus() {}

      static func apply(_ appearance: ScreenshotConfig.Appearance?) {
        guard let appearance else { return }
        for window in windows { window.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light }
      }

      static func waitForWindow() async {
        for _ in 0..<300 {
          if window != nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        apply(ScreenshotSignal.appearance)
      }

      static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      }

      static var window: UIWindow? { windows.first { $0.isKeyWindow } ?? windows.first }

      /// The simulator takes the picture of the whole screen.
      static func present() async -> Int? { nil }
    }
  }

#else
  extension Screenshots {
    @MainActor
    enum Platform {
      static func apply(_ appearance: ScreenshotConfig.Appearance?) {}
      static func reportFocus() {}
      static func waitForWindow() async {}
      static func present() async -> Int? { nil }
    }
  }
#endif
