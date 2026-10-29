//
//  ReleaseSettingsSheet.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The project's `release.env`, edited as a form: how release.sh builds, signs
/// and ships the app. Opened from the Workflows tab (Release Settings…); the
/// same file drives `Tools/release/release.sh` from a terminal.
struct ReleaseSettingsSheet: View {
  @State var config: ReleaseConfig
  let onSave: (ReleaseConfig) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var notary: AppStoreConnectKey.Status = .idle

  var body: some View {
    KitSheet(
      title: "Release Settings", meta: "release.env: how release.sh builds, signs and ships the app",
      systemImage: "shippingbox", width: 560
    ) {
      FormCard("App") {
        field("App name", "APP_NAME", "MyApp")
        field("Scheme", "SCHEME", "MyApp")
        field("Project", "PROJECT", "MyApp.xcodeproj")
        field("Workspace", "WORKSPACE", "instead of a project")
        GroupRow("Platform") {
          // Empty means macOS to release.sh.
          KitPicker(
            "Platform",
            selection: Binding(
              get: { config["PLATFORM"].isEmpty ? "macos" : config["PLATFORM"] }, set: { config["PLATFORM"] = $0 }),
            options: ReleasePlatform.allCases.map { ($0.title, $0.rawValue) })
        }
        field("Team ID", "TEAM_ID", "ABCDE12345")
      }
      FormCard("Tests and screenshots") {
        field("Test scheme", "TEST_SCHEME", "empty skips tests")
        field("Test destination", "TEST_DESTINATION", "platform=macOS")
        field("Screenshot test", "SCREENSHOT_TEST", "MyAppUITests/ScreenshotTests")
        field("Locales", "SCREENSHOT_LOCALES", "en-US de-DE ja-JP")
      }
      FormCard(
        "Direct download",
        footer: "A notarytool keychain profile. Use for Notarization below saves the App Store Connect key as one."
      ) {
        field("Formats", "DIRECT_DOWNLOAD", "zip dmg")
        // Empty means universal to release.sh.
        GroupRow("Builds", help: "Both ships <App> (universal) and <App>-AppleSilicon, half the size") {
          KitPicker(
            "Builds",
            selection: Binding(
              get: { config["DIRECT_ARCHS"].isEmpty ? "universal" : config["DIRECT_ARCHS"] },
              set: { config["DIRECT_ARCHS"] = $0 }),
            options: [("Universal", "universal"), ("Apple silicon", "arm64"), ("Both", "universal arm64")])
        }
        GroupRow("Notary profile", help: notaryLine) {
          HStack(spacing: 6) {
            textField("Notary profile", "NOTARY_PROFILE", "notary")
            Button("Check") { Task { await checkNotary() } }
              .buttonStyle(.kit)
              .disabled(config["NOTARY_PROFILE"].isEmpty || notary == .checking)
          }
        }
      }
      FormCard(
        "Windows, Linux and Android",
        footer: "Windows and Linux build on the VM their workflow step runs on, from this Mac's checkouts of every package the app uses (V57_LOCAL=1). Android isn't built yet."
      ) {
        field("Package", "PACKAGE_PATH", "App (its Package.swift)")
        field("Windows product", "WINDOWS_PRODUCT", "\(appName)WinUI")
        field("Linux product", "LINUX_PRODUCT", appName)
        GroupRow("Linux runtime built in", help: "A folder that runs without Swift installed") {
          Toggle("Linux runtime built in", isOn: Binding(
            get: { config["LINUX_STATIC"] != "no" },
            set: { config["LINUX_STATIC"] = $0 ? "" : "no" }))
          .labelsHidden().toggleStyle(.kitSwitch)
        }
        field("Android product", "ANDROID_PRODUCT", "\(appName)Android")
        field("Android keystore", "ANDROID_KEYSTORE", "the release key, kept on this Mac")
      }
      FormCard("GitHub") {
        field("Repository", "GITHUB_REPO", "owner/repo")
        GroupRow("Create as draft") {
          Toggle("Create as draft", isOn: Binding(
            get: { config["GITHUB_DRAFT"] != "no" },
            set: { config["GITHUB_DRAFT"] = $0 ? "yes" : "no" }))
          .labelsHidden().toggleStyle(.kitSwitch)
        }
      }
      FormCard(
        "App Store Connect",
        footer: "The API key uploads screenshots, and builds without the account signed in to Xcode. Dev copies it to ~/.appstoreconnect/private_keys."
      ) {
        GroupRow("Upload to App Store Connect") {
          Toggle("Upload to App Store Connect", isOn: Binding(
            get: { config["APP_STORE"] == "yes" },
            set: { config["APP_STORE"] = $0 ? "yes" : "no" }))
          .labelsHidden().toggleStyle(.kitSwitch)
        }
        AppStoreConnectKeyFields(config: $config)
      }
      FormCard(
        "Google Play and Microsoft Store",
        footer: "Not built yet: their steps check the settings and say what they still need."
      ) {
        GroupRow("Upload to Google Play") {
          Toggle("Upload to Google Play", isOn: Binding(
            get: { config["GOOGLE_PLAY"] == "yes" },
            set: { config["GOOGLE_PLAY"] = $0 ? "yes" : "" }))
          .labelsHidden().toggleStyle(.kitSwitch)
        }
        field("Play service account key", "GOOGLE_PLAY_KEY_PATH", "~/.google-play/key.json")
        GroupRow("Submit to the Microsoft Store") {
          Toggle("Submit to the Microsoft Store", isOn: Binding(
            get: { config["MS_STORE"] == "yes" },
            set: { config["MS_STORE"] = $0 ? "yes" : "" }))
          .labelsHidden().toggleStyle(.kitSwitch)
        }
        field("Store ID", "MS_STORE_APP_ID", "9NBLGGH4R315")
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") {
        onSave(config)
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }

  private var appName: String {
    (config["APP_NAME"].isEmpty ? config["SCHEME"] : config["APP_NAME"]).replacingOccurrences(of: " ", with: "")
  }

  /// The notary profile's check, as the row's line.
  private var notaryLine: String? {
    switch notary {
    case .idle: nil
    case .checking: "Checking with Apple…"
    case .valid(let text): text
    case .failed(let text): text
    }
  }

  private func checkNotary() async {
    notary = .checking
    notary = await AppStoreConnectKey.checkNotaryProfile(config["NOTARY_PROFILE"])
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { config[key] }, set: { config[key] = $0 })
  }

  /// A row with its value as a field at the end.
  private func field(_ title: String, _ key: String, _ prompt: String) -> some View {
    GroupRow(title) { textField(title, key, prompt) }
  }

  private func textField(_ title: String, _ key: String, _ prompt: String) -> some View {
    TextField(title, text: binding(key), prompt: Text(prompt))
      .labelsHidden()
      .kitField()
      .frame(width: 250)
  }
}
