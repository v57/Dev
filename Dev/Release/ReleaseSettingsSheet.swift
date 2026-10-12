//
//  ReleaseSettingsSheet.swift
//  Dev
//

import SwiftUI

/// The project's `release.env`, edited as a form: how release.sh builds, signs
/// and ships the app. Opened from the Workflows tab (Release Settings…); the
/// same file drives `Tools/release/release.sh` from a terminal.
struct ReleaseSettingsSheet: View {
  @State var config: ReleaseConfig
  let onSave: (ReleaseConfig) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var notary: AppStoreConnectKey.Status = .idle

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("App") {
          field("App name", "APP_NAME", "MyApp")
          field("Scheme", "SCHEME", "MyApp")
          field("Project", "PROJECT", "MyApp.xcodeproj")
          field("Workspace", "WORKSPACE", "MyApp.xcworkspace (instead of a project)")
          Picker("Platform", selection: binding("PLATFORM")) {
            Text("macOS").tag("macos")
            Text("iOS").tag("ios")
          }
          field("Team ID", "TEAM_ID", "ABCDE12345")
        }
        Section("Tests and screenshots") {
          field("Test scheme", "TEST_SCHEME", "empty skips tests")
          field("Test destination", "TEST_DESTINATION", "platform=macOS")
          field("Screenshot test", "SCREENSHOT_TEST", "MyAppUITests/ScreenshotTests")
          field("Locales", "SCREENSHOT_LOCALES", "en-US de-DE ja-JP")
        }
        Section {
          field("Formats", "DIRECT_DOWNLOAD", "zip dmg")
          // Empty means universal to release.sh.
          Picker("Builds", selection: Binding(
            get: { config["DIRECT_ARCHS"].isEmpty ? "universal" : config["DIRECT_ARCHS"] },
            set: { config["DIRECT_ARCHS"] = $0 })) {
            Text("Universal").tag("universal")
            Text("Apple silicon").tag("arm64")
            Text("Both").tag("universal arm64")
          }
          .help("Both ships <App> (universal) and <App>-AppleSilicon, half the size")
          HStack {
            field("Notary profile", "NOTARY_PROFILE", "notary")
            Button("Check") { Task { await checkNotary() } }
              .disabled(config["NOTARY_PROFILE"].isEmpty || notary == .checking)
          }
          switch notary {
          case .idle: EmptyView()
          case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking with Apple…").foregroundStyle(.secondary) }
          case .valid(let text): Label(text, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
          case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
          }
        } header: {
          Text("Direct download")
        } footer: {
          Text("A notarytool keychain profile. Use for Notarization below saves the App Store Connect key as one.")
        }
        Section("GitHub") {
          field("Repository", "GITHUB_REPO", "owner/repo")
          Toggle("Create as draft", isOn: Binding(
            get: { config["GITHUB_DRAFT"] != "no" },
            set: { config["GITHUB_DRAFT"] = $0 ? "yes" : "no" }))
        }
        Section {
          Toggle("Upload to App Store Connect", isOn: Binding(
            get: { config["APP_STORE"] == "yes" },
            set: { config["APP_STORE"] = $0 ? "yes" : "no" }))
          AppStoreConnectKeyFields(config: $config)
        } header: {
          Text("App Store Connect")
        } footer: {
          Text("The API key uploads screenshots, and builds without the account signed in to Xcode. Dev copies it to ~/.appstoreconnect/private_keys.")
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(config)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 540, height: 680)
  }

  private func checkNotary() async {
    notary = .checking
    notary = await AppStoreConnectKey.checkNotaryProfile(config["NOTARY_PROFILE"])
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { config[key] }, set: { config[key] = $0 })
  }

  private func field(_ title: String, _ key: String, _ prompt: String) -> some View {
    TextField(title, text: binding(key), prompt: Text(prompt))
  }
}
