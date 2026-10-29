//
//  StorageLanguages.swift
//  Dev
//

import Foundation

/// The Languages view of Storage: every programming language on this Mac, its
/// installed versions (toolchains, interpreters, SDKs — with the packages
/// installed into them) and its caches and build output, gathered from the
/// scan's items wherever their category put them. A version a project of yours
/// pins (`.python-version`, `.nvmrc`, `rust-toolchain.toml`, `go.mod`…) is
/// marked with that project, so the versions nothing uses stand out.
nonisolated enum StorageLanguages {
  struct Language: Identifiable, Sendable {
    let name: String
    /// Two letters for the icon.
    let mono: String
    var versions: [StorageItem] = []
    var caches: [StorageItem] = []
    /// Item id → the projects that use that version.
    var usedBy: [String: [String]] = [:]

    var id: String { name }
    var bytes: Int64 { (versions + caches).reduce(0) { $0 + $1.bytes } }
    var unusedVersions: [StorageItem] { versions.filter { usedBy[$0.id, default: []].isEmpty && !$0.isLocked } }
  }

  /// Which language an item belongs to, and whether it is a version (as
  /// opposed to a cache or build output), or nil when it is no language's.
  static func classify(_ item: StorageItem) -> (language: String, isVersion: Bool)? {
    switch item.category {
    case .toolchains:
      return (languageName(item.group), !item.title.lowercased().contains("cargo install"))
    case .languages:
      return (languageName(item.group), false)
    case .jsGlobal:
      return ("Node", item.group == "Node Versions")
    case .javascript:
      return ("Node", false)
    case .pythonTools:
      return ("Python", item.group == "Python Versions")
    case .python:
      return ("Python", false)
    case .xcode:
      switch item.group {
      case "Toolchains": return ("Swift", true)
      case "Swift Package Manager", "DerivedData", "Project Builds", "Xcode Caches": return ("Swift", false)
      default: return nil
      }
    case .android:
      switch item.group {
      case "JDKs": return ("Java", true)
      case "Gradle": return ("Java", false)
      default: return nil
      }
    default:
      return nil
    }
  }

  private static func languageName(_ group: String) -> String {
    switch group {
    case "Dart & Flutter": "Dart"
    case "Other": "Other"
    default: group
    }
  }

  static func mono(_ name: String) -> String {
    switch name {
    case "Swift": "S"
    case "Python": "Py"
    case "Node": "JS"
    case "Java": "J"
    case "Rust": "Rs"
    case "Go": "Go"
    case "Ruby": "Rb"
    case ".NET": ".N"
    case "Dart": "D"
    default: String(name.prefix(2))
    }
  }

  /// The languages found in `items`, largest first, with each version's users
  /// among `projects` (name, folder).
  static func languages(from items: [StorageItem], projects: [(String, URL)]) -> [Language] {
    var byName: [String: Language] = [:]
    for item in items {
      guard let (name, isVersion) = classify(item) else { continue }
      var language = byName[name] ?? Language(name: name, mono: mono(name))
      if isVersion { language.versions.append(item) } else { language.caches.append(item) }
      byName[name] = language
    }
    let pins = projectPins(projects)
    for (name, var language) in byName {
      language.versions.sort { $0.bytes > $1.bytes }
      language.caches.sort { $0.bytes > $1.bytes }
      for version in language.versions {
        let users = (pins[name] ?? []).filter { matches(version, $0.spec) }.map(\.project)
        if !users.isEmpty { language.usedBy[version.id] = Array(Set(users)).sorted() }
      }
      byName[name] = language
    }
    return byName.values.sorted { $0.bytes > $1.bytes }
  }

  // MARK: - Project pins

  struct Pin: Sendable {
    let project: String
    /// `3.11`, `20`, `stable`, `1.85.0`…
    let spec: String
  }

  /// What each project pins, per language, read from its version files.
  static func projectPins(_ projects: [(String, URL)]) -> [String: [Pin]] {
    var pins: [String: [Pin]] = [:]
    func read(_ root: URL, _ file: String) -> String? {
      (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    func add(_ language: String, _ project: String, _ spec: String?) {
      guard let spec = spec?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty else { return }
      pins[language, default: []].append(Pin(project: project, spec: spec))
    }
    for (name, root) in projects {
      add("Python", name, read(root, ".python-version")?.split(separator: "\n").first.map(String.init))
      add("Node", name, read(root, ".nvmrc").map { $0.replacingOccurrences(of: "v", with: "") })
      add("Node", name, read(root, ".node-version").map { $0.replacingOccurrences(of: "v", with: "") })
      add("Ruby", name, read(root, ".ruby-version"))
      add("Java", name, read(root, ".java-version"))
      add("Swift", name, read(root, ".swift-version"))
      if let package = read(root, "Package.swift"),
         let match = package.firstMatch(of: #/swift-tools-version:\s*([0-9.]+)/#) {
        add("Swift", name, String(match.1))
      }
      for file in ["rust-toolchain.toml", "rust-toolchain"] {
        guard let text = read(root, file) else { continue }
        if let match = text.firstMatch(of: #/channel\s*=\s*"([^"]+)"/#) { add("Rust", name, String(match.1)) }
        else { add("Rust", name, text.split(separator: "\n").first.map(String.init)) }
      }
      if let mod = read(root, "go.mod") {
        if let match = mod.firstMatch(of: #/(?m)^toolchain\s+go([0-9.]+)/#) { add("Go", name, String(match.1)) }
        else if let match = mod.firstMatch(of: #/(?m)^go\s+([0-9.]+)/#) { add("Go", name, String(match.1)) }
      }
      if let global = read(root, "global.json"),
         let match = global.firstMatch(of: #/"version"\s*:\s*"([0-9.]+)"/#) {
        add(".NET", name, String(match.1))
      }
    }
    return pins
  }

  /// Whether a version item satisfies a pin: `3.11` matches `3.11.13`,
  /// `20` matches `v20.19.5`, `stable` matches the stable toolchain.
  static func matches(_ item: StorageItem, _ spec: String) -> Bool {
    let title = item.title.lowercased()
    let spec = spec.lowercased()
    if spec.first?.isLetter == true {
      return title.contains(spec.split(separator: "-").first.map(String.init) ?? spec)
    }
    guard let version = title.firstMatch(of: #/\d+(\.\d+)*/#).map({ String($0.output.0) }) else { return false }
    let have = version.split(separator: ".")
    let want = spec.split(separator: ".")
    guard want.count <= have.count else { return have.elementsEqual(want.prefix(have.count)) }
    return Array(have.prefix(want.count)) == want
  }
}
