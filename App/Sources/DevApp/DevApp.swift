import CodeWorkspace
import ComponentKit
import DevDesktop
import DevScreenshotsCapture
import Foundation
import SwiftUI
import UpdateKit
import VaultKit
import VaultUI

/// The app, all of it but its entry point (App/Sources/Dev/DevMain.swift, which calls `DevApp.run()`).
public struct DevApp: App {
    @DevAppDelegateAdaptor(DevAppDelegate.self) private var appDelegate

    /// Updates from GitHub Releases (the universal Dev.zip, built by Tools/release/release.sh):
    /// checked daily once the user turns on automatic checks (never before), installed in place
    /// with a relaunch.
    private let updater = AppUpdater(github: "v57/Dev", assetName: "Dev.zip")

    public init() {
        AppLifecycle.install()
        if let hangLog = LaunchOptions.hangLog { MainThreadWatchdog.start(logTo: hangLog) }
        updater.start()
        // Projects added here sync with the other v57 apps and devices through the vault.
        // It also keeps their app icons, found with Code's ProjectIcon, for Dev's sidebar and the other apps, in
        // every account's vault (one sync engine carries them all).
        if !LaunchOptions.isScreenshotMode {
            Vault.shared.startSync()
            let vaults = Vaults.shared
            for account in vaults.allAccounts {
                vaults.vault(for: account)?.findProjectIcons(with: { ProjectIcon.find(in: $0) }) {
                    ProjectIcon.thumbnail(of: $0)
                }
            }
        }
    }

    public var body: some Scene {
        // Dev keeps the system accent: the kit's controls take it, like the system's did. A screenshot
        // launch builds every row and section at once, so a scene never captures a lazy placeholder.
        // A window's value is the account it shows (nil: Personal), so the account picker's "Open … in a New
        // Window" opens one on another account and a restored window comes back on its own.
        WindowGroup(for: String.self) { $account in
            DevWindow(account: $account).componentKit().kitLazyLoading(!LaunchOptions.isScreenshotMode)
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

extension DevApp {
    /// `Dev --screenshots <command>` is `dev-screenshots` (release.sh's screenshots step runs it this way);
    /// `Dev --mcp` serves MCP over stdin/stdout for agents and never opens a window; any other launch is the app.
    public static func run() {
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots") {
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(ScreenshotTool.run(Array(CommandLine.arguments[(index + 1)...])))
        }
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
        main()
    }
}

/// A main window on one account (../Ideas/Accounts.md): its sidebar lists that account's projects. Switching
/// doesn't rebuild the window, so an unsaved catalog or a running workflow stays; the sidebar follows the account.
struct DevWindow: View {
    @Binding var account: String?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VaultAccountScope(
            selection: Binding { account ?? VaultAccount.personal.id } set: { account = $0 }, rebuildsContent: false,
            manage: { [openSettings] in
                UserDefaults.standard.set("accounts", forKey: "settings.tab")
                openSettings()
            },
            openInNewWindow: { [openWindow] in openWindow(value: $0) }
        ) { _ in
            ContentView()
        }
    }
}

/// Quit guard for the Localize catalog: Save is the only writer of an
/// .xcstrings, so quitting with unsaved edits must ask instead of dropping
/// them. This runs at the application level (not through the SwiftUI alert)
/// because termination can arrive while no view is showing the prompt — and a
/// modal alert here can never leave the app stuck half-terminated.
enum AppLifecycle {
  static func install() {
    // A screenshot launch in the background restores no window: it opens one
    // through File ▸ New Window, so the tests and design checks always have one.
    DevAppDelegate.didFinishLaunching = {
      guard LaunchOptions.isScreenshotMode else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DevDesktop.openWindowIfNone() }
    }
    // Everything the translation store still holds for its writer lands before the app goes.
    DevAppDelegate.willTerminate = { TranslationData.shared.flushBeforeTerminating() }
    DevAppDelegate.shouldTerminate = shouldTerminate
  }

  private static func shouldTerminate() -> Bool {
    guard let store = LocalizationStore.active, store.hasUnsavedChanges else { return true }
    let answer = DevDesktop.ask(
      title: store.unsavedChangesTitle,
      message: "The edits in this window are not written to \(store.unsavedCatalogName) yet. Nothing saves on its own.",
      buttons: ["Save", "Discard", "Cancel"])
    switch answer {
    case 0:
      // A failed write surfaces its own alert and keeps the app open.
      return store.saveBeforeTerminating()
    case 1:
      return true
    default:
      return false
    }
  }
}
