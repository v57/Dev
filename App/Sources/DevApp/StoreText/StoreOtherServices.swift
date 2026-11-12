//
//  StoreOtherServices.swift
//  Dev
//

import Foundation

// MARK: - GitHub

/// The repository's description, homepage and topics, and a release's notes. GitHub's tag lookup skips drafts, and
/// `release.sh github` makes drafts by default, so a release is found in the list.
nonisolated struct GitHubStoreText: StoreService {
  let repository: String
  let token: String
  var send: StoreHTTP.Send = StoreHTTP.live

  private var base: String { "https://api.github.com/repos/\(repository)" }

  private func get(_ path: String) async throws -> [String: Any] {
    try await StoreHTTP.json(try StoreHTTP.request("GET", base + path, token: token), send: send)
  }

  /// The release of a version (tag `v<version>`), or the newest when none is named.
  private func release(version: String?) async throws -> [String: Any]? {
    let request = try StoreHTTP.request("GET", base + "/releases?per_page=30", token: token)
    let (data, status) = try await send(request)
    guard (200..<300).contains(status) else { throw StoreTextError("GitHub answered \(status) for the releases.") }
    let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    guard let version else { return releases.first }
    return releases.first { $0["tag_name"] as? String == "v\(version)" }
  }

  func fetch(version: String?) async throws -> StoreLive {
    var live = StoreLive()
    let repository = try await get("")
    let add = { (field: StoreField, value: Any?) in
      if let text = value as? String, !text.isEmpty { live.texts[.init(field: field, locale: nil)] = text }
    }
    add(.subtitle, repository["description"])
    add(.marketingURL, repository["homepage"])
    let topics = try await get("/topics")["names"] as? [String] ?? []
    if !topics.isEmpty { live.texts[.init(field: .keywords, locale: nil)] = StoreLists.text(topics) }
    if let release = try await release(version: version) {
      add(.changelog, release["body"])
      let tag = release["tag_name"] as? String ?? ""
      live.version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
      live.summary = "Release \(tag)" + (release["draft"] as? Bool == true ? " · draft" : "")
    } else {
      live.version = version
      live.readOnly[.changelog] = "No release v\(version ?? "") yet: release.sh's github step makes it with these notes"
      live.summary = "No release v\(version ?? "") yet"
    }
    return live
  }

  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws {
    try StorePlaceholder.refuse(changes)
    var fields: [String: Any] = [:]
    for change in changes {
      switch change.field {
      case .subtitle: fields["description"] = change.new
      case .marketingURL: fields["homepage"] = change.new
      default: break
      }
    }
    if !fields.isEmpty {
      _ = try await StoreHTTP.json(try StoreHTTP.request("PATCH", base, token: token, json: fields), send: send)
      progress("Repository")
    }
    if let change = changes.first(where: { $0.field == .keywords }) {
      let names = StoreLists.items(in: change.new)
      _ = try await StoreHTTP.json(try StoreHTTP.request("PUT", base + "/topics", token: token, json: ["names": names]), send: send)
      progress("Topics")
    }
    if let change = changes.first(where: { $0.field == .changelog }) {
      guard let id = try await release(version: version)?["id"] as? Int else {
        throw StoreTextError("There's no release v\(version ?? "") to write notes to.")
      }
      _ = try await StoreHTTP.json(
        try StoreHTTP.request("PATCH", base + "/releases/\(id)", token: token, json: ["body": change.new]), send: send)
      progress("Release notes")
    }
  }
}

// MARK: - Google Play

/// The Play Developer API: an edit holds every read and write, and only its commit changes anything. A store listing
/// is replaced whole, so a change merges into the listing as it is. A commit refuses while a review is pending.
nonisolated struct GooglePlayStoreText: StoreService {
  typealias Signer = @Sendable (_ input: Data, _ privateKeyPEM: String) async throws -> Data

  let package: String
  let clientEmail: String
  let privateKey: String
  let tokenURI: String
  let testTrack: String
  var send: StoreHTTP.Send = StoreHTTP.live
  var sign: Signer = GooglePlayStoreText.signWithOpenSSL

  init(package: String, serviceAccount: Data, testTrack: String) throws {
    guard let json = (try? JSONSerialization.jsonObject(with: serviceAccount)) as? [String: Any],
          let email = json["client_email"] as? String, let key = json["private_key"] as? String
    else { throw StoreTextError("That isn't a Play Console service account key (a JSON file with client_email and private_key).") }
    self.package = package
    clientEmail = email
    privateKey = key
    tokenURI = json["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
    self.testTrack = testTrack
  }

  private var base: String { "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/\(package)" }

  /// CryptoKit has no RSA: openssl signs the token, from a key file that exists for the length of the call.
  static let signWithOpenSSL: Signer = { input, pem in
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dev-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = folder.appendingPathComponent("key.pem"), data = folder.appendingPathComponent("input")
    let signature = folder.appendingPathComponent("signature")
    FileManager.default.createFile(atPath: key.path, contents: Data(pem.utf8), attributes: [.posixPermissions: 0o600])
    try input.write(to: data)
    let result = await LineProcess.run(
      "/usr/bin/env", ["openssl", "dgst", "-sha256", "-sign", key.path, "-out", signature.path, data.path])
    guard result.status == 0, let signed = try? Data(contentsOf: signature) else {
      throw StoreTextError("openssl couldn't sign with the service account key.")
    }
    return signed
  }

  private func token() async throws -> String {
    func base64URL(_ data: Data) -> String {
      data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: [
      "iss": clientEmail, "scope": "https://www.googleapis.com/auth/androidpublisher", "aud": tokenURI,
      "iat": now, "exp": now + 3600,
    ] as [String: Any])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try await sign(Data(input.utf8), privateKey)
    guard let url = URL(string: tokenURI) else { throw StoreTextError("Bad token URL in the service account key.") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(input).\(base64URL(signature))".utf8)
    guard let token = try await StoreHTTP.json(request, send: send)["access_token"] as? String else {
      throw StoreTextError("Google gave no access token for the service account.")
    }
    return token
  }

  private func call(_ method: String, _ path: String, token: String, json: Any? = nil) async throws -> [String: Any] {
    try await StoreHTTP.json(try StoreHTTP.request(method, base + path, token: token, json: json), send: send)
  }

  /// A version's release on a track: the one naming the version, else the newest.
  private static func releaseIndex(in track: [String: Any], version: String?) -> Int? {
    let releases = track["releases"] as? [[String: Any]] ?? []
    guard let version else { return releases.isEmpty ? nil : 0 }
    return releases.firstIndex { ($0["name"] as? String)?.contains(version) == true }
  }

  func fetch(version: String?) async throws -> StoreLive {
    let token = try await token()
    guard let edit = try await call("POST", "/edits", token: token, json: [:])["id"] as? String else {
      throw StoreTextError("Google Play didn't open an edit.")
    }
    var live = StoreLive()
    live.version = version
    do {
      let listings = try await call("GET", "/edits/\(edit)/listings", token: token)["listings"] as? [[String: Any]] ?? []
      for listing in listings {
        guard let code = listing["language"] as? String else { continue }
        live.locales.append(code)
        for (field, key) in [(StoreField.name, "title"), (.subtitle, "shortDescription"), (.description, "fullDescription")] {
          if let text = listing[key] as? String, !text.isEmpty { live.texts[.init(field: field, locale: code)] = text }
        }
      }
      let details = try await call("GET", "/edits/\(edit)/details", token: token)
      if let website = details["contactWebsite"] as? String, !website.isEmpty {
        live.texts[.init(field: .supportURL, locale: nil)] = website
      }
      for (field, track) in [(StoreField.changelog, "production"), (.testers, testTrack)] {
        let body = (try? await call("GET", "/edits/\(edit)/tracks/\(track)", token: token)) ?? [:]
        guard let index = Self.releaseIndex(in: body, version: version),
              let release = (body["releases"] as? [[String: Any]])?[index]
        else {
          live.readOnly[field] = "The \(track) track has no release of \(version ?? "this version") yet"
          continue
        }
        for note in release["releaseNotes"] as? [[String: Any]] ?? [] {
          if let code = note["language"] as? String, let text = note["text"] as? String, !text.isEmpty {
            live.texts[.init(field: field, locale: code)] = text
            if !live.locales.contains(code) { live.locales.append(code) }
          }
        }
      }
    } catch {
      _ = try? await call("DELETE", "/edits/\(edit)", token: token)
      throw error
    }
    // One open edit at a time: a read leaves none behind.
    _ = try? await call("DELETE", "/edits/\(edit)", token: token)
    live.summary = "\(package) · " + String(localized: "\(live.locales.count) languages")
    return live
  }

  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws {
    try StorePlaceholder.refuse(changes)
    let token = try await token()
    guard let edit = try await call("POST", "/edits", token: token, json: [:])["id"] as? String else {
      throw StoreTextError("Google Play didn't open an edit.")
    }
    do {
      let keys: [StoreField: String] = [.name: "title", .subtitle: "shortDescription", .description: "fullDescription"]
      let listings = Dictionary(grouping: changes.filter { keys[$0.field] != nil }) { $0.liveLocale ?? "" }
      for (code, group) in listings.sorted(by: { $0.key < $1.key }) {
        var listing = (try? await call("GET", "/edits/\(edit)/listings/\(code)", token: token)) ?? [:]
        listing["language"] = code
        for change in group { if let key = keys[change.field] { listing[key] = change.new } }
        _ = try await call("PUT", "/edits/\(edit)/listings/\(code)", token: token, json: listing)
        progress("\(code): listing")
      }
      if let change = changes.first(where: { $0.field == .supportURL }) {
        var details = try await call("GET", "/edits/\(edit)/details", token: token)
        details["contactWebsite"] = change.new
        _ = try await call("PUT", "/edits/\(edit)/details", token: token, json: details)
        progress("Website")
      }
      for (field, track) in [(StoreField.changelog, "production"), (.testers, testTrack)] {
        let group = changes.filter { $0.field == field }
        guard !group.isEmpty else { continue }
        var body = try await call("GET", "/edits/\(edit)/tracks/\(track)", token: token)
        guard let index = Self.releaseIndex(in: body, version: version),
              var releases = body["releases"] as? [[String: Any]]
        else { throw StoreTextError("The \(track) track has no release of \(version ?? "this version").") }
        var notes = releases[index]["releaseNotes"] as? [[String: Any]] ?? []
        for change in group {
          let code = change.liveLocale ?? ""
          notes.removeAll { $0["language"] as? String == code }
          notes.append(["language": code, "text": change.new])
        }
        releases[index]["releaseNotes"] = notes
        body["releases"] = releases
        _ = try await call("PUT", "/edits/\(edit)/tracks/\(track)", token: token, json: body)
        progress("\(track): notes")
      }
      _ = try await call("POST", "/edits/\(edit):commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW", token: token, json: [:])
      progress("Committed")
    } catch {
      _ = try? await call("DELETE", "/edits/\(edit)", token: token)
      throw error
    }
  }
}

// MARK: - Microsoft Store

/// Partner Center's submission API: an app's text lives on a submission. A publish writes it to the pending submission
/// (making one from the last published when there's none) and stops: committing starts certification, so that stays
/// the reader's step in Partner Center. The first submission of an app can only be made there.
nonisolated struct MicrosoftStoreText: StoreService {
  let appID: String
  let tenant: String
  let client: String
  let secret: String
  var send: StoreHTTP.Send = StoreHTTP.live

  private var base: String { "https://manage.devcenter.microsoft.com/v1.0/my/applications/\(appID)" }

  private func token() async throws -> String {
    guard let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/token") else {
      throw StoreTextError("Bad tenant ID.")
    }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let escape = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      "grant_type=client_credentials&client_id=\(escape(client))&client_secret=\(escape(secret))&resource=\(escape("https://manage.devcenter.microsoft.com"))".utf8)
    guard let token = try await StoreHTTP.json(request, send: send)["access_token"] as? String else {
      throw StoreTextError("Microsoft gave no access token.")
    }
    return token
  }

  private func submissionID(in application: [String: Any], key: String) -> String? {
    (application[key] as? [String: Any])?["id"] as? String
  }

  func fetch(version: String?) async throws -> StoreLive {
    let token = try await token()
    let application = try await StoreHTTP.json(try StoreHTTP.request("GET", base, token: token), send: send)
    guard let id = submissionID(in: application, key: "pendingApplicationSubmission")
      ?? submissionID(in: application, key: "lastPublishedApplicationSubmission")
    else { throw StoreTextError("The app has no submission yet: the first one is made in Partner Center.") }
    let submission = try await StoreHTTP.json(
      try StoreHTTP.request("GET", base + "/submissions/\(id)", token: token), send: send)
    var live = StoreLive()
    live.version = version
    live.summary = "Submission \(id)"
    let listings = submission["listings"] as? [String: Any] ?? [:]
    for (code, value) in listings {
      guard let listing = (value as? [String: Any])?["baseListing"] as? [String: Any] else { continue }
      live.locales.append(code)
      for (field, key) in [
        (StoreField.name, "title"), (.subtitle, "shortDescription"), (.description, "description"),
        (.copyright, "copyrightAndTrademarkInfo"), (.changelog, "releaseNotes"),
      ] {
        if let text = listing[key] as? String, !text.isEmpty { live.texts[.init(field: field, locale: code)] = text }
      }
      if let keywords = listing["keywords"] as? [String], !keywords.isEmpty {
        live.texts[.init(field: .keywords, locale: code)] = StoreLists.text(keywords)
      }
    }
    live.locales.sort()
    if let notes = submission["notesForCertification"] as? String, !notes.isEmpty {
      live.texts[.init(field: .reviewNotes, locale: nil)] = notes
    }
    return live
  }

  func publish(_ changes: [StoreChange], version: String?, progress: @Sendable (String) -> Void) async throws {
    try StorePlaceholder.refuse(changes)
    let token = try await token()
    let application = try await StoreHTTP.json(try StoreHTTP.request("GET", base, token: token), send: send)
    var submission: [String: Any]
    if let id = submissionID(in: application, key: "pendingApplicationSubmission") {
      submission = try await StoreHTTP.json(try StoreHTTP.request("GET", base + "/submissions/\(id)", token: token), send: send)
    } else {
      submission = try await StoreHTTP.json(try StoreHTTP.request("POST", base + "/submissions", token: token), send: send)
      progress("Made a new submission")
    }
    guard let id = submission["id"] as? String else { throw StoreTextError("Partner Center gave no submission.") }
    var listings = submission["listings"] as? [String: Any] ?? [:]
    for change in changes {
      if change.field == .reviewNotes {
        submission["notesForCertification"] = change.new
        continue
      }
      let keys: [StoreField: String] = [
        .name: "title", .subtitle: "shortDescription", .description: "description",
        .copyright: "copyrightAndTrademarkInfo", .changelog: "releaseNotes", .keywords: "keywords",
      ]
      guard let key = keys[change.field], let code = change.liveLocale else { continue }
      var entry = listings[code] as? [String: Any] ?? [:]
      var listing = entry["baseListing"] as? [String: Any] ?? [:]
      listing[key] = change.field.isList ? StoreLists.items(in: change.new) as Any : change.new as Any
      entry["baseListing"] = listing
      listings[code] = entry
    }
    submission["listings"] = listings
    _ = try await StoreHTTP.json(
      try StoreHTTP.request("PUT", base + "/submissions/\(id)", token: token, json: submission), send: send)
    progress("Saved on submission \(id). Submit it in Partner Center to send it for certification.")
  }
}
