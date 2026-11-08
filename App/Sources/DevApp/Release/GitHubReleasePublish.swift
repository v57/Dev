//
//  GitHubReleasePublish.swift
//  Dev
//

import Foundation
import GitHubKit
import Security
import UpdateKit

// MARK: - GitHubReleaseRequest

/// What a script asks Dev to publish: release.sh's `github` step (or SSH's `Scripts/release-libssh2.sh`) writes it as
/// JSON and names it on a `::publish github <file>` line. The script holds no token: Dev publishes in-process with the
/// project account's GitHub sign-in (GitHubKit, shared with Git and Markdown), so the token never reaches a script, a
/// step's environment or a log (security audit H1).
nonisolated struct GitHubReleaseRequest: Decodable, Equatable, Sendable {
  struct File: Decodable, Equatable, Sendable {
    var path: String
    var platform: String?
    /// Signed with the release key (minisign) before it's uploaded, as `<name>.minisig` beside it.
    var sign: Bool?
  }

  var format: Int
  /// `owner/repo`.
  var repository: String
  var tag: String
  var title: String?
  /// The version the files belong to, written into their signatures' trusted comment.
  var version: String?
  var notes: String?
  var notesFile: String?
  var generateNotes: Bool?
  var draft: Bool?
  /// The commit a new tag is made on.
  var target: String?
  var files: [File]

  static let marker = "::publish github "

  /// The request file a `::publish github <file>` line names, or nil for any other line.
  static func file(fromMarker line: String) -> URL? {
    guard line.hasPrefix(marker) else { return nil }
    let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
  }

  static func load(_ url: URL) throws -> GitHubReleaseRequest {
    try JSONDecoder().decode(GitHubReleaseRequest.self, from: Data(contentsOf: url))
  }

  enum Problem: LocalizedError, Equatable {
    case format(Int)
    case repository(String, allowed: [String])
    case tag(String)
    case file(String)
    case duplicate(String)
    case noVersion

    var errorDescription: String? {
      switch self {
      case .format(let format): "The publish request has format \(format), which this Dev doesn't know."
      case .repository(let repository, let allowed):
        "The run asked to publish to \(repository), which isn't this project's repository (\(allowed.isEmpty ? "none set" : allowed.joined(separator: ", ")))."
      case .tag(let tag): "“\(tag)” isn't a tag name a release can have."
      case .file(let path): "\(path) isn't a file of this project or of this run."
      case .duplicate(let name): "Two files are named \(name)."
      case .noVersion: "Files to sign need the release's version."
      }
    }
  }

  /// The request as it may be published: to a repository the project names (its release.env's GITHUB_REPO or its
  /// origin remote), with files that are regular files inside `folders` (the project, the run's output folder).
  func validated(allowedRepositories: Set<String>, folders: [URL]) throws -> GitHubReleaseRequest {
    guard format == 1 else { throw Problem.format(format) }
    let allowed = Set(allowedRepositories.map { $0.lowercased() })
    guard allowed.contains(repository.lowercased()), repository.split(separator: "/").count == 2 else {
      throw Problem.repository(repository, allowed: allowedRepositories.sorted())
    }
    guard !tag.isEmpty, tag.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil else {
      throw Problem.tag(tag)
    }
    let roots = folders.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
    var names = Set<String>()
    for file in files {
      let url = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().standardizedFileURL
      var isFolder: ObjCBool = false
      guard roots.contains(where: { url.path.hasPrefix($0) }),
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue
      else { throw Problem.file(file.path) }
      guard names.insert(url.lastPathComponent).inserted else { throw Problem.duplicate(url.lastPathComponent) }
      if file.sign == true {
        guard version?.isEmpty == false else { throw Problem.noVersion }
        guard names.insert(url.lastPathComponent + ".minisig").inserted else {
          throw Problem.duplicate(url.lastPathComponent + ".minisig")
        }
      }
    }
    if let notesFile {
      let url = URL(fileURLWithPath: notesFile).resolvingSymlinksInPath().standardizedFileURL
      guard roots.contains(where: { url.path.hasPrefix($0) }) else { throw Problem.file(notesFile) }
    }
    return self
  }

  /// One line for the confirmation and the log.
  var summary: String {
    "\(tag) on \(repository), \(files.count) file\(files.count == 1 ? "" : "s")"
      + (files.contains { $0.sign == true } ? ", Windows and Linux files signed" : "")
  }
}

// MARK: - ReleaseSigningKey

/// The release signing key (Ed25519, minisign; security audit M4): a generic password in this Mac's login keychain,
/// service `dev.v57.release-signing`, account `minisign-ed25519`, holding the 8-byte key id followed by the 32-byte
/// seed. Only Dev reads it (its access list names Dev.app), only while publishing a release, and it never leaves the
/// process: no script, environment or log sees it. UpdateKit embeds its public half (`Minisign.PublicKey.v57Release`).
nonisolated enum ReleaseSigningKey {
  static let service = "dev.v57.release-signing"
  static let account = "minisign-ed25519"

  enum Failure: LocalizedError {
    case missing
    case keychain(OSStatus)
    case notTheReleaseKey(String)

    var errorDescription: String? {
      switch self {
      case .missing: "This Mac's keychain has no release signing key (\(ReleaseSigningKey.service))."
      case .keychain(let status):
        "The keychain didn't hand over the release signing key (\(SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)"))."
      case .notTheReleaseKey(let id):
        "The keychain's signing key (\(id)) isn't the one UpdateKit trusts (\(Minisign.PublicKey.v57Release.id))."
      }
    }
  }

  /// The secret key, checked against the public key the apps trust.
  static func load() throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else { throw Failure.missing }
    guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
    // The item holds the bytes as hex (security add-generic-password -X stores them raw; both are read).
    let secret = data.count == 40 ? data : (Data(hex: String(decoding: data, as: UTF8.self)) ?? data)
    let publicKey = try Minisign.publicKey(secretKey: secret)
    guard publicKey == .v57Release else { throw Failure.notTheReleaseKey(publicKey.id) }
    return secret
  }
}

extension Data {
  nonisolated fileprivate init?(hex: String) {
    let digits = Array(hex.utf8)
    guard digits.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
      bytes.append(byte)
    }
    self.init(bytes)
  }
}

// MARK: - GitHubReleasePublisher

/// Publishes a validated request: the release (made, or found by its tag), then each file, a signed one with its
/// `.minisig`, replacing a file of the same name.
nonisolated enum GitHubReleasePublisher {
  static func publish(
    _ request: GitHubReleaseRequest, api: GitHubAPI, signingKey: @Sendable () throws -> Data,
    log: @escaping @Sendable (String) -> Void
  ) async throws -> GitHubRelease {
    let parts = request.repository.split(separator: "/").map(String.init)
    let (owner, repository) = (parts[0], parts[1])

    // Signatures first: a missing key stops the run before anything reaches GitHub.
    var uploads: [(name: String, data: Data)] = []
    var secret: Data?
    for file in request.files {
      let url = URL(fileURLWithPath: file.path)
      uploads.append((url.lastPathComponent, try Data(contentsOf: url, options: .mappedIfSafe)))
      guard file.sign == true, let version = request.version else { continue }
      if secret == nil { secret = try signingKey() }
      let signature = try Minisign.sign(
        file: url, secretKey: secret!,
        trustedComment: Minisign.releaseComment(fileName: url.lastPathComponent, version: version),
        untrustedComment: "signature from v57's release key \(Minisign.PublicKey.v57Release.id)")
      let signatureURL = url.appendingPathExtension("minisig")
      try signature.text.write(to: signatureURL, atomically: true, encoding: .utf8)
      uploads.append((signatureURL.lastPathComponent, Data(signature.text.utf8)))
      log("signed \(url.lastPathComponent) (\(signatureURL.lastPathComponent))")
    }

    let notes = try request.notesFile.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? request.notes
    var release: GitHubRelease
    if let existing = try await api.release(owner: owner, repository: repository, tag: request.tag) {
      release = existing
      if let notes { release = try await api.updateRelease(owner: owner, repository: repository, id: existing.id, name: nil, body: notes) }
      log("release \(request.tag) exists: adding the files")
    } else {
      release = try await api.createRelease(
        owner: owner, repository: repository, tag: request.tag, name: request.title ?? request.tag, body: notes,
        draft: request.draft ?? true, target: request.target.flatMap { $0.isEmpty ? nil : $0 }, generateNotes: notes == nil && request.generateNotes == true)
      log("created release \(request.tag)\(release.draft ? " (a draft)" : "")")
    }
    let existing = release.assets ?? []
    for upload in uploads {
      if let old = existing.first(where: { $0.name == upload.name }) {
        try await api.deleteReleaseAsset(owner: owner, repository: repository, id: old.id)
      }
      _ = try await api.uploadReleaseAsset(
        owner: owner, repository: repository, releaseID: release.id, name: upload.name, data: upload.data)
      log("uploaded \(upload.name) (\(ByteCountFormatter.string(fromByteCount: Int64(upload.data.count), countStyle: .file)))")
    }
    log("published: \(release.htmlURL)")
    return release
  }
}
