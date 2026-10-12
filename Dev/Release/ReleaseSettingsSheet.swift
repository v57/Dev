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
          Picker("Builds", selection: binding("DIRECT_ARCHS")) {
            Text("Universal").tag("universal")
            Text("Apple silicon").tag("arm64")
            Text("Both").tag("universal arm64")
          }
          .help("Both ships <App> (universal) and <App>-AppleSilicon, half the size")
          field("Notary profile", "NOTARY_PROFILE", "v57-notary")
        } header: {
          Text("Direct download")
        } footer: {
          Text("Create the notary profile once in Terminal: xcrun notarytool store-credentials <name>")
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
          field("API key ID", "ASC_KEY_ID", "optional")
          field("Issuer ID", "ASC_ISSUER_ID", "optional")
          field("Key file", "ASC_KEY_PATH", "~/.appstoreconnect/AuthKey_XXXX.p8")
        } header: {
          Text("App Store Connect")
        } footer: {
          Text("Without an API key the upload uses the account signed in to Xcode.")
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
    .frame(width: 520, height: 640)
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { config[key] }, set: { config[key] = $0 })
  }

  private func field(_ title: String, _ key: String, _ prompt: String) -> some View {
    TextField(title, text: binding(key), prompt: Text(prompt))
  }
}
