//
//  StoreAppStoreConnect.swift
//  Dev
//

import Foundation

/// A version's text can change in these states (App Store Connect Help ▸ App and submission statuses); once a version
/// is live only its promotional text can.
private let editableVersionStates: Set<String> = [
  "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "INVALID_BINARY", "WAITING_FOR_REVIEW", "ACCEPTED",
  "WAITING_FOR_EXPORT_COMPLIANCE", "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED",
]

/// The app's text in App Store Connect: `appInfoLocalizations` (name, subtitle, privacy URL), the platform version's
/// `appStoreVersionLocalizations` (description, keywords, promotional text, What's New, URLs), its copyright and review
/// notes, the primary category, and the build's `betaBuildLocalizations` (TestFlight's What to Test). Publishing changes
/// text only: it never submits a version for review.
nonisolated struct AppStoreConnectText: StoreService {
  let api: AppStoreConnectAPI
  let bundleID: String
  let platform: String

  /// The ids a publish writes to, and what they hold.
  private struct Context {
    var appInfoID: String
    var infoLocalizations: [[String: Any]] = []
    var versionID: String?
    var versionString: String?
    var versionEditable = false
    var versionLocalizations: [[String: Any]] = []
    var reviewDetailID: String?
    var reviewNotes: String?
    var copyright: String?
    var category: String?
    var buildID: String?
    var betaLocalizations: [[String: Any]] = []
    var summary = ""
  }

  private static func locale(_ item: [String: Any]) -> String { AppStoreConnectAPI.attribute(item, "locale") as? String ?? "" }

  /// Reads a path that may have no value yet: a version with no review details answers 404.
  private func optional(_ path: String) async -> [String: Any]? {
    try? await api.request("GET", path)
  }

  private func load(version wanted: String?) async throws -> Context {
    let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
    let apps = AppStoreConnectAPI.data(try await api.request("GET", "/v1/apps?filter[bundleId]=\(encoded)"))
    guard let appID = apps.first?["id"] as? String else {
      throw StoreTextError("App Store Connect has no app with the bundle ID \(bundleID).")
    }
    // The app info being prepared, when there's one; the live one takes no changes.
    let infos = AppStoreConnectAPI.data(try await api.request("GET", "/v1/apps/\(appID)/appInfos"))
    let info = infos.first { AppStoreConnectAPI.attribute($0, "state") as? String != "READY_FOR_DISTRIBUTION" } ?? infos.first
    guard let appInfoID = info?["id"] as? String else { throw StoreTextError("The app has no app information.") }
    var context = Context(appInfoID: appInfoID)
    context.infoLocalizations = AppStoreConnectAPI.data(
      try await api.request("GET", "/v1/appInfos/\(appInfoID)/appInfoLocalizations?limit=50"))
    if let category = await optional("/v1/appInfos/\(appInfoID)/primaryCategory") {
      context.category = AppStoreConnectAPI.data(category).first?["id"] as? String
    }

    let ascPlatform = platform == "macos" ? "MAC_OS" : "IOS"
    let versions = AppStoreConnectAPI.data(try await api.request(
      "GET", "/v1/apps/\(appID)/appStoreVersions?filter[platform]=\(ascPlatform)&limit=20"))
    let state = { (item: [String: Any]) in
      AppStoreConnectAPI.attribute(item, "appVersionState") as? String
        ?? AppStoreConnectAPI.attribute(item, "appStoreState") as? String ?? ""
    }
    let picked: [String: Any]?
    if let wanted {
      picked = versions.first { AppStoreConnectAPI.attribute($0, "versionString") as? String == wanted }
    } else {
      picked = versions.first { editableVersionStates.contains(state($0)) } ?? versions.first
    }
    if let picked, let versionID = picked["id"] as? String {
      context.versionID = versionID
      context.versionString = AppStoreConnectAPI.attribute(picked, "versionString") as? String
      context.versionEditable = editableVersionStates.contains(state(picked))
      context.copyright = AppStoreConnectAPI.attribute(picked, "copyright") as? String
      context.summary = "Version \(context.versionString ?? "") · \(state(picked))"
      context.versionLocalizations = AppStoreConnectAPI.data(
        try await api.request("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50"))
      if let review = await optional("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail"),
         let detail = AppStoreConnectAPI.data(review).first {
        context.reviewDetailID = detail["id"] as? String
        context.reviewNotes = AppStoreConnectAPI.attribute(detail, "notes") as? String
      }
    }

    // TestFlight's What to Test belongs to a build of the version.
    if let number = wanted ?? context.versionString {
      let builds = AppStoreConnectAPI.data(try await api.request(
        "GET", "/v1/builds?filter[app]=\(appID)&filter[preReleaseVersion.version]=\(number)&sort=-uploadedDate&limit=1"))
      if let buildID = builds.first?["id"] as? String {
        context.buildID = buildID
        context.betaLocalizations = AppStoreConnectAPI.data(
          try await api.request("GET", "/v1/builds/\(buildID)/betaBuildLocalizations?limit=50"))
      }
    }
    return context
  }

  func fetch(version: String?) async throws -> StoreLive {
    let context = try await load(version: version)
    var live = StoreLive()
    live.version = context.versionString ?? version
    live.summary = context.summary
    var locales = Set<String>()
    let add = { (key: StoreLive.Key, value: Any?) in
      if let text = value as? String, !text.isEmpty { live.texts[key] = text }
    }
    for item in context.infoLocalizations {
      let code = Self.locale(item)
      locales.insert(code)
      add(.init(field: .name, locale: code), AppStoreConnectAPI.attribute(item, "name"))
      add(.init(field: .subtitle, locale: code), AppStoreConnectAPI.attribute(item, "subtitle"))
      add(.init(field: .privacyURL, locale: code), AppStoreConnectAPI.attribute(item, "privacyPolicyUrl"))
    }
    for item in context.versionLocalizations {
      let code = Self.locale(item)
      locales.insert(code)
      add(.init(field: .description, locale: code), AppStoreConnectAPI.attribute(item, "description"))
      add(.init(field: .keywords, locale: code), AppStoreConnectAPI.attribute(item, "keywords"))
      add(.init(field: .promotionalText, locale: code), AppStoreConnectAPI.attribute(item, "promotionalText"))
      add(.init(field: .changelog, locale: code), AppStoreConnectAPI.attribute(item, "whatsNew"))
      add(.init(field: .supportURL, locale: code), AppStoreConnectAPI.attribute(item, "supportUrl"))
      add(.init(field: .marketingURL, locale: code), AppStoreConnectAPI.attribute(item, "marketingUrl"))
    }
    for item in context.betaLocalizations {
      let code = Self.locale(item)
      locales.insert(code)
      add(.init(field: .testers, locale: code), AppStoreConnectAPI.attribute(item, "whatsNew"))
    }
    add(.init(field: .category, locale: nil), context.category)
    add(.init(field: .copyright, locale: nil), context.copyright)
    add(.init(field: .reviewNotes, locale: nil), context.reviewNotes)
    live.locales = locales.sorted()

    let name = version.map { "version \($0)" } ?? "a version"
    if context.versionID == nil {
      let reason = "App Store Connect has no \(name) yet: create it first"
      for field in [StoreField.description, .keywords, .promotionalText, .changelog, .supportURL, .marketingURL, .copyright, .reviewNotes] {
        live.readOnly[field] = reason
      }
    } else if !context.versionEditable {
      let reason = "\(context.summary) can't change"
      for field in [StoreField.description, .keywords, .changelog, .supportURL, .marketingURL, .copyright, .reviewNotes] {
        live.readOnly[field] = reason
      }
    }
    if context.buildID == nil { live.readOnly[.testers] = "No build of \(name) has been uploaded yet" }
    return live
  }

  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws {
    let context = try await load(version: version)
    let attribute: (StoreField) -> String? = {
      switch $0 {
      case .name: "name"
      case .subtitle: "subtitle"
      case .privacyURL: "privacyPolicyUrl"
      case .description: "description"
      case .keywords: "keywords"
      case .promotionalText: "promotionalText"
      case .changelog, .testers: "whatsNew"
      case .supportURL: "supportUrl"
      case .marketingURL: "marketingUrl"
      default: nil
      }
    }
    /// Sets `attributes` on a locale's localization, making one when the service has none for that locale.
    func put(
      type: String, parent: (key: String, type: String, id: String), locale: String, attributes: [String: Any],
      in existing: [[String: Any]]
    ) async throws {
      if let id = existing.first(where: { Self.locale($0).caseInsensitiveCompare(locale) == .orderedSame })?["id"] as? String {
        _ = try await api.request("PATCH", "/v1/\(type)/\(id)", body: ["data": ["type": type, "id": id, "attributes": attributes]])
      } else {
        _ = try await api.request("POST", "/v1/\(type)", body: [
          "data": [
            "type": type, "attributes": attributes.merging(["locale": locale]) { first, _ in first },
            "relationships": [parent.key: ["data": ["type": parent.type, "id": parent.id]]],
          ],
        ])
      }
      progress("\(locale): \(type)")
    }

    let group = { (fields: Set<StoreField>) -> [String: [String: Any]] in
      var byLocale: [String: [String: Any]] = [:]
      for change in changes where fields.contains(change.field) {
        guard let locale = change.liveLocale, let key = attribute(change.field) else { continue }
        // App Store Connect takes keywords as one comma-separated string.
        byLocale[locale, default: [:]][key] = change.field.isList
          ? StoreLists.items(in: change.new).joined(separator: ",") : change.new
      }
      return byLocale
    }

    for (locale, attributes) in group([.name, .subtitle, .privacyURL]).sorted(by: { $0.key < $1.key }) {
      try await put(
        type: "appInfoLocalizations", parent: ("appInfo", "appInfos", context.appInfoID), locale: locale,
        attributes: attributes, in: context.infoLocalizations)
    }
    let versionFields: Set<StoreField> = [.description, .keywords, .promotionalText, .changelog, .supportURL, .marketingURL]
    for (locale, attributes) in group(versionFields).sorted(by: { $0.key < $1.key }) {
      guard let versionID = context.versionID else { throw StoreTextError("No version to write to.") }
      try await put(
        type: "appStoreVersionLocalizations", parent: ("appStoreVersion", "appStoreVersions", versionID), locale: locale,
        attributes: attributes, in: context.versionLocalizations)
    }
    for (locale, attributes) in group([.testers]).sorted(by: { $0.key < $1.key }) {
      guard let buildID = context.buildID else { throw StoreTextError("No build to write What to Test to.") }
      try await put(
        type: "betaBuildLocalizations", parent: ("build", "builds", buildID), locale: locale, attributes: attributes,
        in: context.betaLocalizations)
    }
    if let change = changes.first(where: { $0.field == .category }) {
      _ = try await api.request("PATCH", "/v1/appInfos/\(context.appInfoID)", body: [
        "data": [
          "type": "appInfos", "id": context.appInfoID,
          "relationships": ["primaryCategory": ["data": ["type": "appCategories", "id": change.new]]],
        ],
      ])
      progress("Category")
    }
    if let change = changes.first(where: { $0.field == .copyright }), let versionID = context.versionID {
      _ = try await api.request("PATCH", "/v1/appStoreVersions/\(versionID)", body: [
        "data": ["type": "appStoreVersions", "id": versionID, "attributes": ["copyright": change.new]],
      ])
      progress("Copyright")
    }
    if let change = changes.first(where: { $0.field == .reviewNotes }), let versionID = context.versionID {
      if let id = context.reviewDetailID {
        _ = try await api.request("PATCH", "/v1/appStoreReviewDetails/\(id)", body: [
          "data": ["type": "appStoreReviewDetails", "id": id, "attributes": ["notes": change.new]],
        ])
      } else {
        _ = try await api.request("POST", "/v1/appStoreReviewDetails", body: [
          "data": [
            "type": "appStoreReviewDetails", "attributes": ["notes": change.new],
            "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]],
          ],
        ])
      }
      progress("Review notes")
    }
  }
}
