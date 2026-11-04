//
//  StoreService.swift
//  Dev
//

import DevDesktop
import Foundation
import GitHubKit

/// How the services' requests go out: URLSession in the app, a stub in tests. Nothing here runs unless the reader
/// pressed Import or Publish.
nonisolated enum StoreHTTP {
  typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

  static let live: Send = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  /// A JSON request to one of the services.
  static func request(_ method: String, _ url: String, token: String? = nil, json: Any? = nil) throws -> URLRequest {
    guard let target = URL(string: url) else { throw StoreTextError("Bad URL \(url)") }
    var request = URLRequest(url: target)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let json {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    return request
  }

  /// Sends a request and answers its JSON, or throws what the service said.
  static func json(_ request: URLRequest, send: Send) async throws -> [String: Any] {
    let (data, status) = try await send(request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (200..<300).contains(status) else {
      let error = json["error"] as? [String: Any]
      let message = json["message"] as? String ?? error?["message"] as? String
        ?? json["error_description"] as? String ?? "HTTP \(status)"
      throw StoreTextError("\(request.httpMethod ?? "GET") \(request.url?.path ?? ""): \(message)")
    }
    return json
  }
}

/// A destination's language codes differ (`de-DE`, `de`, `de-de`): exact match first, then the same language.
nonisolated enum StoreLocale {
  static func match(_ code: String, in others: [String]) -> String? {
    if let exact = others.first(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) { return exact }
    let language = code.split(separator: "-").first.map { $0.lowercased() }
    return others.first { $0.split(separator: "-").first.map { $0.lowercased() } == language }
  }
}

/// What a service shows now.
nonisolated struct StoreLive: Sendable {
  struct Key: Hashable, Sendable {
    var field: StoreField
    /// The service's own code; nil for a field with one value for the app.
    var locale: String?
  }

  var texts: [Key: String] = [:]
  /// Locale codes the service knows, including ones with no text in a given field.
  var locales: [String] = []
  /// The version the per-version fields belong to, when the service has one.
  var version: String?
  /// Fields that can't be changed now, and why.
  var readOnly: [StoreField: String] = [:]
  /// A line about what was read ("Version 1.2 · Prepare for Submission").
  var summary = ""
}

/// One text a publish would change.
nonisolated struct StoreChange: Identifiable, Hashable, Sendable {
  var field: StoreField
  var title: String
  /// Dev's locale; nil for a field with one value for the app.
  var locale: String?
  /// The service's code for it: an existing one, or Dev's own for a locale the service doesn't have yet.
  var liveLocale: String?
  var old: String?
  var new: String

  var id: String { "\(field.rawValue)/\(locale ?? "")" }
}

/// What a publish would do, worked out from the local text and what's live. Nothing is sent to make it.
nonisolated struct StorePublishPlan: Sendable {
  var changes: [StoreChange] = []
  /// Over a documented limit: the publish won't start while there are any.
  var overLimit: [String] = []
  /// Nothing goes for these, and why: a locale not translated yet, a field the service won't take now.
  var skipped: [String] = []
  /// Fields the service's API can't set, to copy by hand when they differ.
  var manual: [StoreSlot] = []
}

/// One text an import would write.
nonisolated struct StoreImportItem: Identifiable, Hashable, Sendable {
  var address: StoreAddress
  var title: String
  var current: String?
  var value: String

  var id: String {
    "\(address.field.rawValue)/\(address.destination?.rawValue ?? "")/\(address.locale ?? "")/\(address.version ?? "")"
  }
}

/// A service's text, read and written.
nonisolated protocol StoreService: Sendable {
  /// Reads what's live. `version` picks the per-version fields; nil takes the service's newest.
  func fetch(version: String?) async throws -> StoreLive
  /// Sends the changes, which came from a plan made against a fetch.
  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws
}

/// What a `-DevScreenshotMode` launch reads and "sends": made-up text, no account and no request, so screenshots and
/// tests can reach the compare, the confirmation and the send.
nonisolated struct DemoStoreText: StoreService {
  var destination: StoreDestination

  func fetch(version: String?) async throws -> StoreLive {
    var live = StoreLive(locales: ["en-US", "de-DE"], version: version ?? "1.0", summary: "Demo: nothing was read")
    for slot in destination.slots where slot.isSent {
      if destination.isPerLocale(slot.field) {
        live.texts[.init(field: slot.field, locale: "en-US")] = "Live \(slot.title)"
      } else {
        live.texts[.init(field: slot.field)] = "Live \(slot.title)"
      }
    }
    return live
  }

  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws {
    for change in changes { progress("Demo: not sent, \(change.title)") }
  }
}

// MARK: - Plans

extension StoreTexts {
  /// The difference between the local text and what's live. A field empty here is left alone on the service:
  /// publishing never clears anything.
  func publishPlan(
    destination: StoreDestination, live: StoreLive, version: String?
  ) -> StorePublishPlan {
    var plan = StorePublishPlan()
    let settings = settings()
    for slot in destination.slots {
      let field = slot.field
      if field.isPerVersion, version == nil { continue }
      guard slot.isSent else {
        if !resolved(field, destination: destination, version: version).isEmpty { plan.manual.append(slot) }
        continue
      }
      if let reason = live.readOnly[field] {
        if !resolved(field, destination: destination, version: version).isEmpty {
          plan.skipped.append("\(slot.title): \(reason)")
        }
        continue
      }
      let locales: [String?] = destination.isPerLocale(field) ? settings.allLocales : [nil]
      for locale in locales {
        let text = resolved(field, destination: destination, locale: locale, version: field.isPerVersion ? version : nil)
        guard !text.isEmpty else { continue }
        let isBase = locale == nil || locale == settings.baseLocale
        let scope = locale.map { " · \($0)" } ?? ""
        // English in a German listing is worse than the listing as it is.
        if !isBase, field.isTranslated, text.origin == .base || text.origin == .baseOverride {
          plan.skipped.append("\(slot.title)\(scope): not translated yet")
          continue
        }
        let new = destination.localForm(text.text, field: field)
        if let limit = slot.limit, !slot.isEstimate, limit.count(new, field: field).isOver {
          plan.overLimit.append("\(slot.title)\(scope): \(limit.count(new, field: field).text)")
        }
        let liveLocale = locale.flatMap { StoreLocale.match($0, in: live.locales) }
        let old = live.texts[StoreLive.Key(field: field, locale: locale == nil ? nil : liveLocale)]
        if let old, destination.isSame(old, new, field: field) { continue }
        plan.changes.append(StoreChange(
          field: field, title: slot.title, locale: locale, liveLocale: liveLocale ?? locale, old: old, new: new))
      }
    }
    return plan
  }

  /// What an import would write, without touching a base text that's already there: text that differs becomes this
  /// destination's override, so the other destinations keep theirs.
  func importPlan(destination: StoreDestination, live: StoreLive) -> [StoreImportItem] {
    let settings = settings()
    var items: [StoreImportItem] = []
    for (key, raw) in live.texts {
      guard let slot = destination.slot(key.field) else { continue }
      let field = key.field
      let value = destination.localForm(raw, field: field)
      guard !value.isEmpty else { continue }
      let version = field.isPerVersion ? live.version : nil
      if field.isPerVersion, version == nil { continue }
      var locale: String?
      if let code = key.locale, StoreLocale.match(settings.baseLocale, in: [code]) == nil {
        locale = StoreLocale.match(code, in: settings.locales) ?? code
      }
      let scope = locale.map { " · \($0)" } ?? ""
      let base = entry(StoreAddress(field: field, locale: locale, version: version))?.text
      let override = entry(StoreAddress(field: field, destination: destination, locale: locale, version: version))?.text
      if let base, destination.isSame(base, value, field: field) { continue }
      if let override, destination.isSame(override, value, field: field) { continue }
      if base == nil {
        items.append(StoreImportItem(
          address: StoreAddress(field: field, locale: locale, version: version), title: "\(slot.title)\(scope)",
          current: nil, value: value))
      } else {
        items.append(StoreImportItem(
          address: StoreAddress(field: field, destination: destination, locale: locale, version: version),
          title: "\(slot.title)\(scope) (\(destination.shortTitle) only)", current: override, value: value))
      }
    }
    return items.sorted { $0.title < $1.title }
  }

  /// Writes what the reader kept of an import. What's live is public already, so it goes in the repository, except
  /// what's always private. New locales join the settings.
  func apply(_ items: [StoreImportItem]) throws {
    var settings = settings()
    for item in items {
      try write(item.value, at: item.address, ready: true)
      if let locale = item.address.locale, locale != settings.baseLocale, !settings.locales.contains(locale) {
        settings.locales.append(locale)
      }
    }
    if settings != self.settings() { try save(settings) }
  }

  /// Text that just went live is public: it joins the repository. Review notes and tester messages stay private.
  func markPublished(_ changes: [StoreChange], destination: StoreDestination, version: String?) throws {
    for field in Set(changes.map(\.field)) where !field.isAlwaysPrivate {
      let scoped = field.isPerVersion ? version : nil
      try setReady(true, field: field, version: scoped)
      try setReady(true, field: field, destination: destination, version: scoped)
    }
  }
}

// MARK: - Credentials

/// What a service needs, from release.env, the keychain and the GitHub sign-in: never from `.dev/store/`.
nonisolated enum StoreCredentials {
  static let microsoftSecretService = "dev.v57.dev.store"
  static let microsoftSecretAccount = "microsoft-store-client-secret"

  static func microsoftSecret() -> String? {
    DevKeychain.read(service: microsoftSecretService, account: microsoftSecretAccount)
  }

  static func saveMicrosoftSecret(_ secret: String) {
    let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.isEmpty {
      DevKeychain.delete(service: microsoftSecretService, account: microsoftSecretAccount)
    } else {
      DevKeychain.write(
        clean, service: microsoftSecretService, account: microsoftSecretAccount, label: "Dev: Microsoft Store client secret")
    }
  }

  /// What's still needed before a service can be asked anything; nil when it's all there. No network.
  static func missing(_ destination: StoreDestination, config: ReleaseConfig?, accountID: String) -> String? {
    if LaunchOptions.isScreenshotMode { return nil }
    switch destination {
    case .appStore:
      guard let config else { return "Set up release.env in Workflows ▸ Release Settings first." }
      return config["ASC_KEY_ID"].isEmpty || config["ASC_KEY_PATH"].isEmpty
        ? "Add an App Store Connect API key." : nil
    case .github:
      guard let config, !config["GITHUB_REPO"].isEmpty else {
        return "Name the repository (GITHUB_REPO) in Workflows ▸ Release Settings."
      }
      return (try? KeychainTokenStore.forAccount(accountID).load())?.token == nil
        ? "Sign in to GitHub in Settings first." : nil
    case .googlePlay:
      guard let config else { return "Set up release.env in Workflows ▸ Release Settings first." }
      return config["GOOGLE_PLAY_KEY_PATH"].isEmpty ? "Choose a Play Console service account key." : nil
    case .microsoftStore:
      guard let config else { return "Set up release.env in Workflows ▸ Release Settings first." }
      if config["MS_STORE_APP_ID"].isEmpty { return "Enter the app's Store ID from Partner Center." }
      if config["MS_STORE_TENANT_ID"].isEmpty || config["MS_STORE_CLIENT_ID"].isEmpty {
        return "Enter the Partner Center tenant and client IDs."
      }
      return microsoftSecret() == nil ? "Enter the Partner Center client secret." : nil
    }
  }

  /// The bundle ID from store.json, else the Xcode scheme in release.env (the Mac only).
  static func bundleID(root: URL, settings: StoreSettings, config: ReleaseConfig) async throws -> String {
    if let id = settings.bundleID, !id.isEmpty { return id }
    guard DevCapabilities.xcode else { throw StoreTextError("Enter the bundle ID in Store Text's Setup.") }
    return try await AppStoreUploadSheet.bundleID(root: root, config: config)
  }

  /// The service behind a destination. Reads credentials; sends nothing.
  static func service(
    _ destination: StoreDestination, root: URL, config: ReleaseConfig?, accountID: String
  ) async throws -> any StoreService {
    if LaunchOptions.isScreenshotMode { return DemoStoreText(destination: destination) }
    if let missing = missing(destination, config: config, accountID: accountID) { throw StoreTextError(missing) }
    let config = config ?? ReleaseConfig()
    let settings = StoreTexts(root: root).settings()
    switch destination {
    case .appStore:
      return AppStoreConnectText(
        api: try AppStoreConnectAPI(config: config),
        bundleID: try await bundleID(root: root, settings: settings, config: config),
        platform: config["PLATFORM"].isEmpty ? "macos" : config["PLATFORM"])
    case .github:
      let token = (try? KeychainTokenStore.forAccount(accountID).load())?.token ?? ""
      return GitHubStoreText(repository: config["GITHUB_REPO"], token: token)
    case .googlePlay:
      var package = config["GOOGLE_PLAY_PACKAGE"]
      if package.isEmpty { package = try await bundleID(root: root, settings: settings, config: config) }
      var path = config["GOOGLE_PLAY_KEY_PATH"]
      if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
      guard let key = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        throw StoreTextError("Can't read the service account key at \(path).")
      }
      return try GooglePlayStoreText(
        package: package, serviceAccount: key,
        testTrack: config["GOOGLE_PLAY_TRACK"].isEmpty ? "internal" : config["GOOGLE_PLAY_TRACK"])
    case .microsoftStore:
      return MicrosoftStoreText(
        appID: config["MS_STORE_APP_ID"], tenant: config["MS_STORE_TENANT_ID"], client: config["MS_STORE_CLIENT_ID"],
        secret: microsoftSecret() ?? "")
    }
  }
}
