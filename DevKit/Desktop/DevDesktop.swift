import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// What Dev needs from the desktop beyond ComponentKit's `KitDesktop` (file panels, file icons, other apps and the
/// app's activation are `KitDesktop`'s), without the platform's types: its own other instances, its alerts and its
/// quit guard. AppKit on the Mac; elsewhere the process table, with what has no counterpart left out
/// (`DevCapabilities` says which tools need the Mac).
public enum DevDesktop {
  /// Whether this app is running in another process as the app (not as a command-line helper started with one of
  /// `helperArguments`, such as `--mcp`).
  public static func isOwnAppRunning(helperArguments: [String] = []) -> Bool {
    #if canImport(AppKit)
      let identifier = Bundle.main.bundleIdentifier ?? ""
      return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    #elseif os(Linux)
      let me = ProcessInfo.processInfo.processIdentifier
      guard let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"),
        let processes = try? FileManager.default.contentsOfDirectory(atPath: "/proc")
      else { return false }
      for pid in processes.compactMap(Int32.init) where pid != me {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) == executable,
          let line = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline")
        else { continue }
        let arguments = line.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        if !arguments.contains(where: helperArguments.contains) { return true }
      }
      return false
    #else
      return false
    #endif
  }

  /// Starts this app as the app (its bundle on the Mac, the executable without arguments elsewhere).
  public static func launchOwnApp() {
    #if canImport(AppKit)
      DispatchQueue.main.async { NSWorkspace.shared.open(Bundle.main.bundleURL) }
    #else
      guard let path = Bundle.main.executablePath else { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try? process.run()
    #endif
  }

  /// Shows an error in an alert of its own (an app-modal one on the Mac; on standard error elsewhere).
  @MainActor public static func showError(_ error: any Error) {
    #if canImport(AppKit)
      NSAlert(error: error).runModal()
    #else
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    #endif
  }

  /// Asks with an app-modal alert, for questions no window can show (the app is quitting); the index of the
  /// button picked. Off the Mac there is no such alert: the last button (Cancel) is the answer.
  @MainActor public static func ask(title: String, message: String, buttons: [String]) -> Int {
    #if canImport(AppKit)
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      for button in buttons { alert.addButton(withTitle: button) }
      let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      return (0..<buttons.count).contains(response) ? response : buttons.count - 1
    #else
      return buttons.count - 1
    #endif
  }

  /// Opens a window through File ▸ New Window when the app shows none (a launch in the background restores none).
  @MainActor public static func openWindowIfNone() {
    #if canImport(AppKit)
      guard !NSApp.windows.contains(where: \.isVisible) else { return }
      let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
      if let newWindow = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
        let action = newWindow.action
      {
        NSApp.sendAction(action, to: newWindow.target, from: newWindow)
      }
    #endif
  }
}

/// The tools of Dev that need the Mac, so the app shows "available on macOS" where this system lacks them.
public enum DevCapabilities {
  /// Xcode's tools: actool's icon renders, simulators and Mac screenshots, archives and installs of Mac apps, App
  /// Store Connect uploads.
  public static var xcode: Bool { isMac }

  /// UTM's virtual machines (utmctl).
  public static var virtualMachines: Bool { isMac }

  /// The storage cleaner, whose catalog is the Mac's folders (Library, Xcode, simulators, APFS clones).
  public static var storageCleaner: Bool { isMac }

  /// The system the Mac-only tools need, for their unavailable state: "Available on macOS".
  public static let requiredSystem = "macOS"

  private static var isMac: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }
}

extension DevDesktop {
  /// The longer side of the largest screen in pixels, for pictures shown full screen (2880 where screens aren't
  /// known).
  @MainActor public static var largestScreenPixels: Int {
    #if canImport(AppKit)
      Int(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880)
    #else
      2880
    #endif
  }
}

extension DevDesktop {
  /// The machine Dev runs on, as a workflow step's runner: "This Mac", or "This Computer".
  public nonisolated static var thisComputer: String {
    #if os(macOS)
      String(localized: "This Mac")
    #else
      String(localized: "This Computer")
    #endif
  }

  /// When the user last opened the app (or file) at `path`, as Spotlight recorded it; nil where nothing records it.
  public nonisolated static func lastUsed(_ path: String) -> Date? {
    #if canImport(AppKit)
      guard let item = MDItemCreate(nil, path as CFString) else { return nil }
      return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    #else
      nil
    #endif
  }
}
