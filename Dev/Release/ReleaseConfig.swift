//
//  ReleaseConfig.swift
//  Dev
//

import Foundation

// MARK: - ReleaseConfig

/// A project's `release.env`: how `release.sh` builds and ships it. The file is the
/// source of truth, so a release from Dev and one from a terminal are the same.
/// Keys Dev does not know are kept as they are.
nonisolated struct ReleaseConfig: Equatable, Sendable {
  static let fileName = "release.env"

  var values: [String: String] = [:]
  /// Lines Dev does not model (other keys, comments), written back unchanged.
  var extraLines: [String] = []

  /// The keys the Release tool edits, in file order, with the line written above each.
  static let fields: [(key: String, comment: String?)] = [
    ("APP_NAME", "How Tools/release/release.sh ships this app (see release.env.example)."),
    ("SCHEME", nil), ("PROJECT", nil), ("WORKSPACE", nil), ("PLATFORM", nil), ("TEAM_ID", nil),
    ("TEST_SCHEME", ""), ("TEST_DESTINATION", nil), ("SCREENSHOT_TEST", nil),
    ("SCREENSHOT_LOCALES", nil), ("SCREENSHOT_DESTINATION", nil),
    ("DIRECT_DOWNLOAD", ""), ("DIRECT_ARCHS", nil), ("NOTARY_PROFILE", nil),
    ("GITHUB_REPO", ""), ("GITHUB_DRAFT", nil),
    ("APP_STORE", ""), ("ASC_KEY_ID", nil), ("ASC_ISSUER_ID", nil), ("ASC_KEY_PATH", nil),
  ]

  /// An empty value and a missing key mean the same to the script, so only
  /// non-empty values are held.
  subscript(key: String) -> String {
    get { values[key] ?? "" }
    set { values[key] = newValue.isEmpty ? nil : newValue }
  }

  // MARK: - file

  static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

  static func load(from root: URL) -> ReleaseConfig? {
    guard let text = try? String(contentsOf: url(in: root), encoding: .utf8) else { return nil }
    return parse(text)
  }

  static func parse(_ text: String) -> ReleaseConfig {
    var config = ReleaseConfig()
    let known = Set(fields.map(\.key))
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
        // Dev writes its own comments; only foreign ones are kept.
        if line.hasPrefix("#"), !fields.contains(where: { $0.comment.map { "# " + $0 } == line }) {
          config.extraLines.append(raw)
        }
        continue
      }
      let key = String(line[..<equals])
      guard known.contains(key) else {
        config.extraLines.append(raw)
        continue
      }
      config[key] = value(String(line[line.index(after: equals)...]))
    }
    return config
  }

  /// A shell value: quoted, or bare up to an unquoted comment.
  private static func value(_ text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let quote = text.first, quote == "\"" || quote == "'" {
      let body = text.dropFirst()
      return String(body.prefix { $0 != quote })
    }
    if let hash = text.range(of: " #") { return String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
    return text
  }

  func rendered() -> String {
    var lines: [String] = []
    for (key, comment) in Self.fields {
      if let comment { lines.append(comment.isEmpty ? "" : "# " + comment) }
      let value = self[key]
      let needsQuotes = value.contains { $0 == " " || $0 == "#" || $0 == "\"" || $0 == "$" }
      lines.append("\(key)=" + (needsQuotes ? "'\(value)'" : value))
    }
    if !extraLines.isEmpty { lines.append(""); lines += extraLines }
    return lines.joined(separator: "\n") + "\n"
  }

  func save(to root: URL) throws {
    try rendered().write(to: Self.url(in: root), atomically: true, encoding: .utf8)
  }

  // MARK: - first setup

  /// A starting config read from the project itself: its Xcode project, first
  /// scheme, team, platform and GitHub remote.
  static func detect(in root: URL) async -> ReleaseConfig {
    var config = ReleaseConfig()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let workspace = names.first { $0.hasSuffix(".xcworkspace") }
    let project = names.first { $0.hasSuffix(".xcodeproj") }
    var container: [String] = []
    if let workspace {
      config["WORKSPACE"] = workspace
      container = ["-workspace", workspace]
    } else if let project {
      config["PROJECT"] = project
      container = ["-project", project]
    }
    let list = await LineProcess.run("/usr/bin/xcodebuild", container + ["-list", "-json"], directory: root)
    if let data = list.output.data(using: .utf8).flatMap(jsonObject),
       let schemes = ((data["project"] ?? data["workspace"]) as? [String: Any])?["schemes"] as? [String] {
      let preferred = project.map { ($0 as NSString).deletingPathExtension } ?? ""
      config["SCHEME"] = schemes.first { $0 == preferred } ?? schemes.first ?? ""
    }
    config["APP_NAME"] = config["SCHEME"]
    if !config["SCHEME"].isEmpty {
      let settings = await LineProcess.run(
        "/usr/bin/xcodebuild", container + ["-scheme", config["SCHEME"], "-showBuildSettings"], directory: root)
      let value = { (name: String) in
        settings.output.split(separator: "\n")
          .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + " = ") }
          .map { String($0.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) } ?? ""
      }
      config["TEAM_ID"] = value("DEVELOPMENT_TEAM")
      config["PLATFORM"] = value("PLATFORM_NAME") == "macosx" ? "macos" : "ios"
      if !value("PRODUCT_NAME").isEmpty { config["APP_NAME"] = value("PRODUCT_NAME") }
    }
    config["DIRECT_DOWNLOAD"] = config["PLATFORM"] == "macos" ? "zip dmg" : ""
    config["DIRECT_ARCHS"] = config["PLATFORM"] == "macos" ? "universal" : ""
    config["SCREENSHOT_LOCALES"] = "en-US"
    config["GITHUB_DRAFT"] = "yes"
    config["APP_STORE"] = config["PLATFORM"] == "ios" ? "yes" : "no"
    let remote = await LineProcess.run("/usr/bin/git", ["remote", "get-url", "origin"], directory: root)
    config["GITHUB_REPO"] = githubRepo(from: remote.output)
    return config
  }

  /// `owner/repo` from a GitHub remote URL, or "".
  static func githubRepo(from remote: String) -> String {
    let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = remote.range(of: "github.com[:/]", options: .regularExpression) else { return "" }
    var path = String(remote[range.upperBound...])
    if path.hasSuffix(".git") { path.removeLast(4) }
    return path.split(separator: "/").count == 2 ? path : ""
  }

  private static func jsonObject(_ data: Data) -> [String: Any]? {
    // xcodebuild may print warnings before the JSON.
    guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
    return try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any]
  }
}
