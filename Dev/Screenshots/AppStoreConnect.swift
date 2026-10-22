//
//  AppStoreConnect.swift
//  Dev
//

import ComponentKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - API

/// The slice of the App Store Connect API the screenshot upload needs, signed
/// with the API key release.env already names (ASC_KEY_ID, ASC_ISSUER_ID,
/// ASC_KEY_PATH): find the app and its editable version, then replace each
/// locale's screenshots of one display type.
nonisolated struct AppStoreConnectAPI: Sendable {
  let keyID: String
  let issuerID: String
  let privateKey: P256.Signing.PrivateKey

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  init(config: ReleaseConfig) throws {
    let keyID = config["ASC_KEY_ID"], issuer = config["ASC_ISSUER_ID"]
    var path = config["ASC_KEY_PATH"]
    guard !keyID.isEmpty, !path.isEmpty else {
      throw Failure(message: "Add an App Store Connect API key in Release Settings (a key file and its key ID).")
    }
    if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
    guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw Failure(message: "Cannot read the API key at \(path).")
    }
    self.keyID = keyID
    self.issuerID = issuer
    self.privateKey = try Self.privateKey(pem: pem)
  }

  /// The key in a `.p8` file (PKCS #8 PEM, as App Store Connect downloads it).
  static func privateKey(pem: String) throws -> P256.Signing.PrivateKey {
    do {
      return try P256.Signing.PrivateKey(pemRepresentation: pem)
    } catch {
      throw Failure(message: "Not an App Store Connect API key: expected a P-256 private key in PEM form.")
    }
  }

  /// A 15-minute ES256 token.
  private func token() throws -> String {
    func base64URL(_ data: Data) -> String {
      data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let now = Int(Date().timeIntervalSince1970)
    // A team key names its issuer; an individual key has none and signs as the user.
    var payload: [String: Any] = ["iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"]
    if issuerID.isEmpty { payload["sub"] = "user" } else { payload["iss"] = issuerID }
    let claims = try JSONSerialization.data(withJSONObject: payload)
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let signature = try privateKey.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
  }

  func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    guard let url = URL(string: path.hasPrefix("http") ? path : "https://api.appstoreconnect.apple.com" + path) else {
      throw Failure(message: "Bad URL \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    guard (200..<300).contains(status) else {
      let detail = ((json["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? "HTTP \(status)"
      throw Failure(message: "\(method) \(path): \(detail)")
    }
    return json
  }

  static func data(_ json: [String: Any]) -> [[String: Any]] {
    if let list = json["data"] as? [[String: Any]] { return list }
    if let one = json["data"] as? [String: Any] { return [one] }
    return []
  }

  static func attribute(_ item: [String: Any], _ key: String) -> Any? {
    (item["attributes"] as? [String: Any])?[key]
  }

  /// App Store Connect's display type for a picture of this size.
  static func displayType(width: Int, height: Int, platform: String) -> String {
    if platform == "macos" { return "APP_DESKTOP" }
    let long = max(width, height)
    switch long {
    case 2868, 2796, 2622, 2556: return "APP_IPHONE_67"
    case 2688, 2778: return "APP_IPHONE_65"
    case 2752, 2732: return "APP_IPAD_PRO_3GEN_129"
    default: return "APP_IPHONE_67"
    }
  }

  // MARK: Upload

  /// Replaces the screenshots of `displayType` in every locale of the app's
  /// editable version with the files given, in order. Reports progress lines.
  func uploadScreenshots(
    bundleID: String, platform: String, files: [String: [URL]], replaceExisting: Bool,
    progress: @Sendable (String) -> Void
  ) async throws {
    let apps = Self.data(try await request("GET", "/v1/apps?filter[bundleId]=\(bundleID)"))
    guard let appID = apps.first?["id"] as? String else { throw Failure(message: "No app with bundle ID \(bundleID).") }
    let ascPlatform = platform == "macos" ? "MAC_OS" : "IOS"
    let versions = Self.data(try await request(
      "GET", "/v1/apps/\(appID)/appStoreVersions?filter[platform]=\(ascPlatform)&limit=20"))
    let editable = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]
    guard let version = versions.first(where: {
      editable.contains(Self.attribute($0, "appStoreState") as? String ?? "")
        || editable.contains(Self.attribute($0, "appVersionState") as? String ?? "")
    }), let versionID = version["id"] as? String else {
      throw Failure(message: "The app has no version in Prepare for Submission. Create one in App Store Connect first.")
    }
    progress("Version \(Self.attribute(version, "versionString") as? String ?? "")")
    let localizations = Self.data(try await request(
      "GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50"))
    for (locale, urls) in files.sorted(by: { $0.key < $1.key }) {
      guard let localization = localizations.first(where: {
        let ascLocale = Self.attribute($0, "locale") as? String ?? ""
        return ascLocale == locale || ascLocale.hasPrefix(locale + "-") || locale.hasPrefix(ascLocale)
      }), let localizationID = localization["id"] as? String else {
        progress("\(locale): no matching localization on the version, skipped")
        continue
      }
      let first = urls.first.map(ScreenshotLibrary.pixelSize) ?? (0, 0)
      let type = Self.displayType(width: first.0, height: first.1, platform: platform)
      let sets = Self.data(try await request(
        "GET", "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets"))
      var setID = sets.first { Self.attribute($0, "screenshotDisplayType") as? String == type }?["id"] as? String
      if setID == nil {
        let created = try await request("POST", "/v1/appScreenshotSets", body: [
          "data": ["type": "appScreenshotSets", "attributes": ["screenshotDisplayType": type],
                   "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": localizationID]]]],
        ])
        setID = Self.data(created).first?["id"] as? String
      }
      guard let setID else { continue }
      if replaceExisting {
        let existing = Self.data(try await request("GET", "/v1/appScreenshotSets/\(setID)/appScreenshots"))
        for shot in existing {
          if let id = shot["id"] as? String { _ = try await request("DELETE", "/v1/appScreenshots/\(id)") }
        }
      }
      for url in urls {
        try await upload(url, to: setID)
        progress("\(locale): uploaded \(url.lastPathComponent)")
      }
    }
  }

  private func upload(_ url: URL, to setID: String) async throws {
    let data = try Data(contentsOf: url)
    let reserved = try await request("POST", "/v1/appScreenshots", body: [
      "data": ["type": "appScreenshots", "attributes": ["fileName": url.lastPathComponent, "fileSize": data.count],
               "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": setID]]]],
    ])
    guard let shot = Self.data(reserved).first, let shotID = shot["id"] as? String,
          let operations = Self.attribute(shot, "uploadOperations") as? [[String: Any]]
    else { throw Failure(message: "App Store Connect did not reserve \(url.lastPathComponent).") }
    for operation in operations {
      guard let target = (operation["url"] as? String).flatMap(URL.init(string:)),
            let offset = operation["offset"] as? Int, let length = operation["length"] as? Int
      else { continue }
      var put = URLRequest(url: target)
      put.httpMethod = operation["method"] as? String ?? "PUT"
      for header in operation["requestHeaders"] as? [[String: String]] ?? [] {
        if let name = header["name"], let value = header["value"] { put.setValue(value, forHTTPHeaderField: name) }
      }
      let (_, response) = try await URLSession.shared.upload(for: put, from: data.subdata(in: offset..<(offset + length)))
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else {
        throw Failure(message: "Uploading \(url.lastPathComponent) failed.")
      }
    }
    let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    _ = try await request("PATCH", "/v1/appScreenshots/\(shotID)", body: [
      "data": ["type": "appScreenshots", "id": shotID, "attributes": ["uploaded": true, "sourceFileChecksum": checksum]],
    ])
  }
}

// MARK: - Sheet

/// Upload… in the Screenshots tab: which locales go, whether the version's
/// existing pictures are replaced, and the progress.
struct AppStoreUploadSheet: View {
  let root: URL
  let library: ScreenshotLibrary?
  @Environment(\.kitDismiss) private var dismiss
  @State private var replace = true
  @State private var lines: [String] = []
  @State private var isUploading = false
  @State private var error: String?
  @State private var done = false
  /// release.env, nil when the project has none; the key fields edit it.
  @State private var config: ReleaseConfig?
  @State private var savedConfig: ReleaseConfig?

  private var hasKey: Bool { config.map { !$0["ASC_KEY_ID"].isEmpty && !$0["ASC_KEY_PATH"].isEmpty } ?? false }

  var body: some View {
    let finals = finalFiles()
    KitSheet(
      title: "Upload to App Store Connect",
      meta: "Replaces the screenshots of the app's version in Prepare for Submission, one display type per size, for \(finals.count) languages.",
      systemImage: "icloud.and.arrow.up", width: 520
    ) {
      FormCard("Pictures") {
        ForEach(finals.keys.sorted(), id: \.self) { locale in
          GroupRow(Locale.current.localizedString(forIdentifier: locale) ?? locale) {
            Text("\(finals[locale]?.count ?? 0) pictures").foregroundStyle(.kitSecondary)
          }
        }
      }
      .controlSize(.small)
      if config == nil {
        FormCard {
          FormRow(
            "No release.env", help: "Set it up in Workflows ▸ Release Settings first.",
            systemImage: "exclamationmark.triangle", hue: .orange)
        }
      } else if !hasKey || savedConfig != config {
        // Shell's key import: choose the .p8, check it with Apple; saved to release.env on Upload.
        FormCard("App Store Connect API key") {
          AppStoreConnectKeyFields(config: Binding(get: { config ?? ReleaseConfig() }, set: { config = $0 }), offersNotary: false)
        }
      }
      FormCard {
        GroupRow("Delete the version's current screenshots first") {
          Toggle("Delete the version's current screenshots first", isOn: $replace)
            .labelsHidden().toggleStyle(.kitSwitch)
        }
      }
      if !lines.isEmpty {
        ScrollView {
          Text(lines.joined(separator: "\n"))
            .kitFont(.monoSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 120)
        .kitSurface(.card, cornerRadius: KitMetrics.radiusCard)
      }
    } footer: {
      if let error {
        SheetStatus(error, systemImage: "exclamationmark.triangle", status: .failed)
      } else if isUploading {
        SheetStatus("Uploading…", systemImage: "icloud.and.arrow.up", status: .working)
      } else if done {
        SheetStatus("Uploaded", systemImage: "icloud.and.arrow.up", status: .done)
      }
      Button(done ? "Done" : "Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      if !done {
        Button("Upload") { Task { await upload(finals) } }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(isUploading || finals.isEmpty || !hasKey)
      }
    }
    .task {
      config = ReleaseConfig.load(from: root)
      savedConfig = config
    }
  }

  private func finalFiles() -> [String: [URL]] {
    library?.uploadFiles() ?? [:]
  }

  private func upload(_ files: [String: [URL]]) async {
    guard let config else { return }
    isUploading = true
    error = nil
    defer { isUploading = false }
    do {
      if config != savedConfig {
        try config.save(to: root)
        savedConfig = config
      }
      let api = try AppStoreConnectAPI(config: config)
      let bundleID = try await Self.bundleID(root: root, config: config)
      lines.append("App \(bundleID)")
      try await api.uploadScreenshots(
        bundleID: bundleID, platform: config["PLATFORM"].isEmpty ? "macos" : config["PLATFORM"],
        files: files, replaceExisting: replace
      ) { line in
        Task { @MainActor in lines.append(line) }
      }
      lines.append("Done.")
      done = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// PRODUCT_BUNDLE_IDENTIFIER of the release scheme.
  static func bundleID(root: URL, config: ReleaseConfig) async throws -> String {
    var arguments: [String] = []
    if !config["WORKSPACE"].isEmpty { arguments += ["-workspace", config["WORKSPACE"]] }
    else if !config["PROJECT"].isEmpty { arguments += ["-project", config["PROJECT"]] }
    arguments += ["-scheme", config["SCHEME"], "-showBuildSettings"]
    let result = await LineProcess.run("/usr/bin/xcodebuild", arguments, directory: root)
    let line = result.output.split(separator: "\n").first { $0.contains(" PRODUCT_BUNDLE_IDENTIFIER = ") }
    guard let id = line?.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
      throw AppStoreConnectAPI.Failure(message: "Could not read the app's bundle ID from the scheme \(config["SCHEME"]).")
    }
    return id
  }
}
