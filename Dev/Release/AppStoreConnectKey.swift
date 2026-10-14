//
//  AppStoreConnectKey.swift
//  Dev
//

import SwiftUI
import UniformTypeIdentifiers

/// The App Store Connect API key release.env names (ASC_KEY_ID, ASC_ISSUER_ID,
/// ASC_KEY_PATH), set up the way Shell's Notarization sheet sets up its key:
/// choose the `.p8` App Store Connect downloads, read the key ID from its name,
/// check it with Apple. One key serves the screenshot upload, release.sh's
/// build upload and, saved as a notarytool profile, notarization.
nonisolated enum AppStoreConnectKey {
  /// Where altool and xcodebuild look for keys; the chosen key is copied here,
  /// so release.env keeps working when the download is cleaned up.
  static var folder: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".appstoreconnect/private_keys", isDirectory: true)
  }

  /// `AuthKey_<KEYID>.p8` is how App Store Connect names the download.
  static func keyID(fromFileName url: URL) -> String? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.hasPrefix("AuthKey_"), name.count > "AuthKey_".count else { return nil }
    return String(name.dropFirst("AuthKey_".count))
  }

  /// Copies the key into `folder` as `AuthKey_<keyID>.p8`, readable only by
  /// you, and returns the copy. A key already there is returned as is.
  static func install(_ source: URL, keyID: String, into folder: URL = folder) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = folder.appendingPathComponent("AuthKey_\(keyID).p8")
    guard source.standardizedFileURL != target.standardizedFileURL else { return target }
    let data = try Data(contentsOf: source)
    // A key that does not parse is not worth copying.
    _ = try AppStoreConnectAPI.privateKey(pem: String(decoding: data, as: UTF8.self))
    if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
    try data.write(to: target, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    return target
  }

  enum Status: Equatable, Sendable {
    case idle, checking
    case valid(String)
    case failed(String)
  }

  /// Signs a token with the key and lists one app: proof the key, its ID and
  /// the issuer belong together. Read-only.
  static func check(_ config: ReleaseConfig) async -> Status {
    do {
      let api = try AppStoreConnectAPI(config: config)
      let json = try await api.request("GET", "/v1/apps?limit=200&fields[apps]=bundleId")
      let count = AppStoreConnectAPI.data(json).count
      return .valid(count == 1 ? "Works · 1 app" : "Works · \(count) apps")
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  // MARK: notarytool (Shell's Notarization, for release.sh's NOTARY_PROFILE)

  /// Saves the key as a notarytool keychain profile; notarytool checks it with
  /// Apple first and keeps it in the keychain.
  static func storeNotaryProfile(_ profile: String, path: String, keyID: String, issuerID: String) async -> (status: Int32, output: String) {
    var arguments = ["notarytool", "store-credentials", profile, "--key", path, "--key-id", keyID]
    if !issuerID.isEmpty { arguments += ["--issuer", issuerID] }
    return await LineProcess.run("/usr/bin/xcrun", arguments)
  }

  /// Checks a notarytool profile by listing its history (a network request).
  static func checkNotaryProfile(_ profile: String) async -> Status {
    let result = await LineProcess.run(
      "/usr/bin/xcrun", ["notarytool", "history", "--keychain-profile", profile, "--output-format", "json"])
    if result.status == 0 { return .valid("Profile works") }
    let lowered = result.output.lowercased()
    if lowered.contains("no keychain password item found") || (lowered.contains("keychain") && lowered.contains("not found")) {
      return .failed("No profile named “\(profile)” in the keychain")
    }
    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(message.isEmpty ? "notarytool exited with status \(result.status)." : message)
  }
}

/// The App Store Connect section of Release Settings and of the screenshot
/// upload: the key file (Choose… fills in the key ID), the issuer, a check
/// with Apple, and the same key saved as the notary profile.
struct AppStoreConnectKeyFields: View {
  @Binding var config: ReleaseConfig
  /// Offer "Use for Notarization" (Release Settings does; the upload sheet doesn't need it).
  var offersNotary = true

  @State private var choosing = false
  @State private var status: AppStoreConnectKey.Status = .idle
  /// The key, ID and issuer the status was checked with; editing any makes it stale.
  @State private var checked: [String] = []
  @State private var notary: AppStoreConnectKey.Status = .idle
  @State private var importError: String?

  private var current: [String] { [config["ASC_KEY_PATH"], config["ASC_KEY_ID"], config["ASC_ISSUER_ID"]] }
  private var shown: AppStoreConnectKey.Status { checked == current ? status : .idle }
  private var complete: Bool { !config["ASC_KEY_PATH"].isEmpty && !config["ASC_KEY_ID"].isEmpty }

  var body: some View {
    LabeledContent("Key file") {
      HStack {
        Text(config["ASC_KEY_PATH"].isEmpty ? "None" : (config["ASC_KEY_PATH"] as NSString).lastPathComponent)
          .foregroundStyle(config["ASC_KEY_PATH"].isEmpty ? .secondary : .primary)
          .help(config["ASC_KEY_PATH"])
        Button("Choose…") { choosing = true }
          .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) {
            imported($0)
          }
      }
    }
    TextField("Key ID", text: binding("ASC_KEY_ID"), prompt: Text("from AuthKey_<KEY ID>.p8"))
    TextField("Issuer ID", text: binding("ASC_ISSUER_ID"), prompt: Text("team keys; empty for an individual key"))
    if let importError {
      Label(importError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
    }
    HStack {
      statusView(shown)
      Spacer()
      Link("Create a key…", destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
        .font(.callout)
      Button("Check with Apple") { Task { await check() } }
        .disabled(!complete || shown == .checking)
    }
    if offersNotary {
      HStack {
        statusView(notary)
        Spacer()
        Button("Use for Notarization") { Task { await saveNotary() } }
          .disabled(!complete || notary == .checking)
          .help("Saves this key as the notarytool profile “\(notaryProfile)” in your keychain")
      }
    }
  }

  @ViewBuilder
  private func statusView(_ status: AppStoreConnectKey.Status) -> some View {
    switch status {
    case .idle:
      EmptyView()
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking with Apple…").foregroundStyle(.secondary)
      }
    case .valid(let text):
      Label(text, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .lineLimit(4)
        .textSelection(.enabled)
    }
  }

  private var notaryProfile: String { config["NOTARY_PROFILE"].isEmpty ? "notary" : config["NOTARY_PROFILE"] }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { config[key] }, set: { config[key] = $0.trimmingCharacters(in: .whitespaces) })
  }

  private func imported(_ result: Result<URL, Error>) {
    importError = nil
    guard case .success(let url) = result else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let keyID = AppStoreConnectKey.keyID(fromFileName: url) ?? config["ASC_KEY_ID"]
    guard !keyID.isEmpty else {
      importError = "Enter the key ID first: the file isn’t named AuthKey_<KEY ID>.p8."
      return
    }
    do {
      let installed = try AppStoreConnectKey.install(url, keyID: keyID)
      config["ASC_KEY_ID"] = keyID
      config["ASC_KEY_PATH"] = installed.path
    } catch {
      importError = "That file isn’t an App Store Connect key (\(error.localizedDescription))."
    }
  }

  private func check() async {
    let key = current
    checked = key
    status = .checking
    let result = await AppStoreConnectKey.check(config)
    guard checked == key else { return }
    status = result
  }

  private func saveNotary() async {
    notary = .checking
    let profile = notaryProfile
    let result = await AppStoreConnectKey.storeNotaryProfile(
      profile, path: config["ASC_KEY_PATH"], keyID: config["ASC_KEY_ID"], issuerID: config["ASC_ISSUER_ID"])
    if result.status == 0 {
      config["NOTARY_PROFILE"] = profile
      notary = .valid("Saved as notary profile “\(profile)”")
    } else {
      let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      notary = .failed(message.isEmpty ? "notarytool exited with status \(result.status)." : message)
    }
  }
}
