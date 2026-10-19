import AppKit
import CodeWorkspace
import ComponentKit
import DevScreenshotsCapture
import SwiftUI
import UpdateKit
import VaultKit

/// `Dev --screenshots <command>` is `dev-screenshots` (release.sh's screenshots step runs it this way);
/// `Dev --mcp` serves MCP over stdin/stdout for agents and never opens a window; a test run hosts DevTests in a bare
/// app; any other launch is the app.
@main enum DevMain {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots") {
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(ScreenshotTool.run(Array(CommandLine.arguments[(index + 1)...])))
        }
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
        // DevTests runs inside a bare app: no window, no vault sync, no update check.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        }
        MyApp.main()
    }
}

struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Updates from GitHub Releases (the universal Dev.zip, built by Tools/release/release.sh):
    /// checked daily once the user turns on automatic checks (never before), installed in place
    /// with a relaunch.
    private let updater = AppUpdater(github: "v57/Dev", assetName: "Dev.zip")

    init() {
        updater.start()
        // Projects added here sync with the other v57 apps and devices through the vault.
        // It also keeps their app icons, found with Code's ProjectIcon, for Dev's sidebar and the other apps.
        if !LaunchOptions.isScreenshotMode {
            Vault.shared.startSync()
            Vault.shared.findProjectIcons(with: { ProjectIcon.find(in: $0) }) { ProjectIcon.thumbnail(of: $0) }
        }
    }

    var body: some Scene {
        // Dev keeps the system accent: the kit's controls take it, like the system's did. A screenshot
        // launch builds every row and section at once, so a scene never captures a lazy placeholder.
        WindowGroup {
            ContentView().componentKit().kitLazyLoading(!LaunchOptions.isScreenshotMode)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            UpdaterCommands(updater: updater)
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
            SettingsView().componentKit().kitLazyLoading(!LaunchOptions.isScreenshotMode)
        }
        // KitSettings(…, window: .hiddenTitleBar) runs its sidebar up under the traffic lights.
        .windowStyle(.hiddenTitleBar)
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
