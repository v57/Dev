import AppKit
import SwiftUI

/// The entry point: `Dev --mcp` serves MCP over stdin/stdout for agents and
/// never opens a window; anything else is the app.
@main enum DevMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
        MyApp.main()
    }
}

struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Project…") {
                    NotificationCenter.default.post(name: .devAddProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New Icon") {
                    NotificationCenter.default.post(name: .devOpenProjectlessIcon, object: nil)
                }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

/// Quit guard for the Localize catalog: Save is the only writer of an
/// .xcstrings, so quitting with unsaved edits must ask instead of dropping
/// them. This runs at the application level (not through the SwiftUI alert)
/// because termination can arrive while no view is showing the prompt — and a
/// modal alert here can never leave the app stuck half-terminated.
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// A screenshot launch in the background restores no window: it opens one
  /// through File ▸ New Window, so the tests and design checks always have one.
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard LaunchOptions.isScreenshotMode else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard !NSApp.windows.contains(where: \.isVisible) else { return }
      let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
      if let newWindow = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
         let action = newWindow.action {
        NSApp.sendAction(action, to: newWindow.target, from: newWindow)
      }
    }
  }

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store = LocalizationStore.active, store.hasUnsavedChanges else {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.messageText = store.unsavedChangesTitle
    alert.informativeText = "The edits in this window are not written to \(store.unsavedCatalogName) yet. Nothing saves on its own."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Discard")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      // A failed write surfaces its own alert and keeps the app open.
      return store.saveBeforeTerminating() ? .terminateNow : .terminateCancel
    case .alertSecondButtonReturn:
      return .terminateNow
    default:
      return .terminateCancel
    }
  }
}
