import AppKit
import DevScreenshotsCapture
import SwiftUI
import UpdateKit
import VaultKit

/// `Dev --screenshots <command>` is `dev-screenshots` (release.sh's screenshots step runs it this way); any other
/// launch is the app.
@main enum DevMain {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots") {
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(ScreenshotTool.run(Array(CommandLine.arguments[(index + 1)...])))
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
        if !LaunchOptions.isScreenshotMode { Vault.shared.startSync() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands { UpdaterCommands(updater: updater) }
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
