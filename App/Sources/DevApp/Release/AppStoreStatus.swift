//
//  AppStoreStatus.swift
//  Dev
//

import Foundation

/// Where an app stands in App Store Connect, read with the App Store Connect key: its record, its versions on a
/// platform with the build each has, its recent builds and how far they processed, and what a version still lacks
/// before it can be submitted (text, screenshots, review contact, age rating, category, price, export compliance).
/// Only GET requests. App Privacy answers have no API, so they are never reported as done.
nonisolated enum AppStoreStatus {
  static func read(api: AppStoreConnectAPI, bundleID: String, platform: String, version wanted: String?) async throws
    -> [String: Any]
  {
    let ascPlatform = AppStoreConnectAPI.ascPlatform(platform)
    let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
    guard let app = AppStoreConnectAPI.data(try await api.request("GET", "/v1/apps?filter[bundleId]=\(encoded)")).first,
      let appID = app["id"] as? String
    else {
      return ["bundleID": bundleID, "app": NSNull(),
              "missing": ["App Store Connect has no app with the bundle ID \(bundleID): add it in App Store Connect ▸ Apps"]]
    }
    func attribute(_ item: [String: Any]?, _ key: String) -> Any { item.flatMap { AppStoreConnectAPI.attribute($0, key) } ?? NSNull() }
    func optional(_ path: String) async -> [String: Any]? { try? await api.request("GET", path) }
    func filled(_ value: Any) -> Bool { !((value as? String) ?? "").isEmpty }
    var missing: [String] = []

    // Builds, newest first, with the marketing version each belongs to
    // Every platform's: an upload for the wrong one shows up instead of nothing
    let buildsJSON = try await api.request(
      "GET", "/v1/builds?filter[app]=\(appID)&sort=-uploadedDate&limit=10&include=preReleaseVersion")
    let preReleaseItems = ((buildsJSON["included"] as? [[String: Any]]) ?? []).compactMap { item in
      (item["id"] as? String).map { ($0, item) }
    }
    let preReleases = Dictionary(preReleaseItems.map { ($0.0, AppStoreConnectAPI.attribute($0.1, "version") as? String ?? "") },
                                 uniquingKeysWith: { first, _ in first })
    let preReleasePlatforms = Dictionary(
      preReleaseItems.map { ($0.0, AppStoreConnectAPI.attribute($0.1, "platform") as? String ?? "") },
      uniquingKeysWith: { first, _ in first })
    let builds = AppStoreConnectAPI.data(buildsJSON).map { build -> [String: Any] in
      let preRelease = ((build["relationships"] as? [String: Any])?["preReleaseVersion"] as? [String: Any])?["data"]
        as? [String: Any]
      return [
        "id": build["id"] as Any, "build": attribute(build, "version"),
        "version": preRelease.flatMap { ($0["id"] as? String).flatMap { preReleases[$0] } } ?? NSNull(),
        "platform": preRelease.flatMap { ($0["id"] as? String).flatMap { preReleasePlatforms[$0] } } ?? NSNull(),
        "processingState": attribute(build, "processingState"), "uploaded": attribute(build, "uploadedDate"),
        "expired": attribute(build, "expired"), "usesNonExemptEncryption": attribute(build, "usesNonExemptEncryption"),
      ]
    }

    // Versions on the platform, with the build attached to each
    let versionsJSON = try await api.request(
      "GET", "/v1/apps/\(appID)/appStoreVersions?filter[platform]=\(ascPlatform)&limit=20&include=build")
    let versions = AppStoreConnectAPI.data(versionsJSON)
    let attachedBuilds = Dictionary(
      ((versionsJSON["included"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "builds" }.compactMap { item in
        (item["id"] as? String).map { ($0, AppStoreConnectAPI.attribute(item, "version") as? String ?? "") }
      }, uniquingKeysWith: { first, _ in first })
    func buildID(of version: [String: Any]) -> String? {
      (((version["relationships"] as? [String: Any])?["build"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
    }
    let versionList = versions.map { version -> [String: Any] in
      ["id": version["id"] as Any, "version": attribute(version, "versionString"),
       "state": AppStoreConnectAPI.state(of: version),
       "build": buildID(of: version).flatMap { attachedBuilds[$0] } ?? NSNull()]
    }
    let chosen = wanted.flatMap { wanted in versions.first { AppStoreConnectAPI.attribute($0, "versionString") as? String == wanted } }
      ?? versions.first { AppStoreConnectAPI.editableStates.contains(AppStoreConnectAPI.state(of: $0)) }
    var detail: [String: Any] = [:]
    if let wanted, chosen.map({ AppStoreConnectAPI.attribute($0, "versionString") as? String }) != wanted {
      missing.append("No version \(wanted) on \(ascPlatform) yet (publishing the Store Text makes it)")
    }
    if let chosen, let versionID = chosen["id"] as? String {
      detail["version"] = attribute(chosen, "versionString")
      detail["state"] = AppStoreConnectAPI.state(of: chosen)
      detail["copyright"] = attribute(chosen, "copyright")
      detail["releaseType"] = attribute(chosen, "releaseType")
      if let id = buildID(of: chosen) {
        let build = builds.first { $0["id"] as? String == id }
        detail["build"] = attachedBuilds[id] ?? NSNull()
        if let build, build["usesNonExemptEncryption"] is NSNull {
          missing.append("Export compliance: the attached build has no encryption answer")
        }
      } else {
        detail["build"] = NSNull()
        missing.append("No build attached to \(attribute(chosen, "versionString"))")
      }
      if !filled(attribute(chosen, "copyright")) { missing.append("Copyright") }

      // Text and screenshots per locale
      let localizations = AppStoreConnectAPI.data(
        try await api.request("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50"))
      var locales: [[String: Any]] = []
      for localization in localizations {
        let code = AppStoreConnectAPI.attribute(localization, "locale") as? String ?? ""
        var shots: [String: Int] = [:]
        if let id = localization["id"] as? String {
          let sets = AppStoreConnectAPI.data(try await api.request(
            "GET", "/v1/appStoreVersionLocalizations/\(id)/appScreenshotSets?limit=50"))
          for set in sets {
            guard let setID = set["id"] as? String else { continue }
            let pictures = try await api.request("GET", "/v1/appScreenshotSets/\(setID)/appScreenshots?limit=1")
            let total = ((pictures["meta"] as? [String: Any])?["paging"] as? [String: Any])?["total"] as? Int
            shots[AppStoreConnectAPI.attribute(set, "screenshotDisplayType") as? String ?? "?"] =
              total ?? AppStoreConnectAPI.data(pictures).count
          }
        }
        let fields = ["description", "keywords", "supportUrl", "marketingUrl", "promotionalText", "whatsNew"]
        let empty = fields.filter { !filled(attribute(localization, $0)) }
        locales.append(["locale": code, "emptyFields": empty, "screenshots": shots])
        for field in empty where ["description", "keywords", "supportUrl"].contains(field) {
          missing.append("\(code): \(field)")
        }
        if !shots.keys.contains(where: { $0.hasPrefix("APP_IPHONE") }) { missing.append("\(code): iPhone screenshots") }
      }
      detail["locales"] = locales

      // App Review: whether each part is there, never the values
      if let review = await optional("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail"),
        let item = AppStoreConnectAPI.data(review).first
      {
        let contact = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"]
        let lacking = contact.filter { !filled(attribute(item, $0)) }
        detail["review"] = ["contactComplete": lacking.isEmpty, "notes": filled(attribute(item, "notes")),
                            "demoAccountRequired": attribute(item, "demoAccountRequired")]
        if !lacking.isEmpty { missing.append("App Review contact: \(lacking.joined(separator: ", "))") }
      } else {
        detail["review"] = NSNull()
        missing.append("App Review contact")
      }
    } else if versions.isEmpty {
      missing.append("No App Store version on \(ascPlatform) yet")
    }

    // App-wide: category, age rating, content rights, price, App Privacy
    var info: [String: Any] = [:]
    let infos = AppStoreConnectAPI.data(try await api.request("GET", "/v1/apps/\(appID)/appInfos"))
    let appInfo = infos.first { item in
      let state = AppStoreConnectAPI.attribute(item, "state") as? String ?? AppStoreConnectAPI.attribute(item, "appStoreState") as? String ?? ""
      return !["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"].contains(state)
    } ?? infos.first
    if let appInfo, let infoID = appInfo["id"] as? String {
      let category = await optional("/v1/appInfos/\(infoID)/primaryCategory").flatMap { AppStoreConnectAPI.data($0).first }
      info["primaryCategory"] = category?["id"] ?? NSNull()
      if category == nil { missing.append("Primary category") }
      let localizations = AppStoreConnectAPI.data(
        (await optional("/v1/appInfos/\(infoID)/appInfoLocalizations?limit=50")) ?? [:])
      info["names"] = localizations.map { ["locale": attribute($0, "locale"), "name": attribute($0, "name"),
                                           "subtitle": attribute($0, "subtitle"),
                                           "privacyPolicyUrl": attribute($0, "privacyPolicyUrl")] }
      for item in localizations where !filled(attribute(item, "privacyPolicyUrl")) {
        missing.append("\(attribute(item, "locale")): privacy policy URL")
      }
      if let rating = await optional("/v1/appInfos/\(infoID)/ageRatingDeclaration").flatMap({ AppStoreConnectAPI.data($0).first }) {
        let attributes = rating["attributes"] as? [String: Any] ?? [:]
        let unanswered = attributes.filter { $0.value is NSNull && !optionalAgeRatingFields.contains($0.key) }.map(\.key).sorted()
        info["ageRating"] = ["unanswered": unanswered]
        if !unanswered.isEmpty { missing.append("Age rating: \(unanswered.count) questions unanswered") }
      } else {
        missing.append("Age rating")
      }
    }
    let rights = attribute(app, "contentRightsDeclaration")
    info["contentRightsDeclaration"] = rights
    if rights is NSNull { missing.append("Content rights declaration (App Information)") }
    let prices = await optional("/v1/appPriceSchedules/\(appID)/manualPrices?limit=1")
    let priced = prices.map { !AppStoreConnectAPI.data($0).isEmpty } ?? false
    info["priced"] = priced
    if !priced { missing.append("Price (Pricing and Availability)") }
    missing.append("App Privacy: no API reads it; check App Store Connect ▸ App Privacy")

    return [
      "bundleID": bundleID,
      "app": ["id": appID, "name": attribute(app, "name"), "sku": attribute(app, "sku"),
              "primaryLocale": attribute(app, "primaryLocale")],
      "appInfo": info, "versions": versionList, "selected": detail.isEmpty ? NSNull() : detail, "builds": builds,
      "missing": missing,
    ]
  }

  /// Age rating attributes App Store Connect leaves empty unless they apply: a region's own rating, an override, a
  /// kids' age band, the developer's page about it.
  static let optionalAgeRatingFields: Set<String> = [
    "kidsAgeBand", "developerAgeRatingInfoUrl", "gracRatingClassificationNumber", "koreaAgeRatingOverride",
    "ageRatingOverride", "ageRatingOverrideV2",
  ]

  /// Attaches a build App Store Connect already processed to its version (made when the app has none), without
  /// waiting: one still processing fails, and the call can be made again. Nothing is submitted for review.
  static func attach(
    api: AppStoreConnectAPI, bundleID: String, platform: String, version: String, build: String
  ) async throws -> [String] {
    final class Lines: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [String] = []
      func add(_ line: String) { lock.withLock { items.append(line) } }
      var all: [String] { lock.withLock { items } }
    }
    let lines = Lines()
    let request = AppStoreUploadRequest(bundleID: bundleID, platform: platform, version: version, build: build)
    try await AppStoreBuildPublisher.attach(request, api: api, timeout: 0, sleep: { _ in }, log: lines.add)
    return lines.all
  }
}
