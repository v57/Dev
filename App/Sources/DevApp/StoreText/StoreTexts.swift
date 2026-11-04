//
//  StoreTexts.swift
//  Dev
//

import Foundation

/// The address of one text file: which field, at which destination (nil is the base text), in which locale (nil is
/// the base locale), for which version (per-version fields only).
nonisolated struct StoreAddress: Hashable, Sendable {
  var field: StoreField
  var destination: StoreDestination? = nil
  var locale: String? = nil
  var version: String? = nil
}

/// `.dev/store/store.json`: what isn't a text.
nonisolated struct StoreSettings: Codable, Equatable, Sendable {
  /// The language the base texts are written in.
  var baseLocale = "en-US"
  /// The other locales, which Dev's translation fills.
  var locales: [String] = []
  /// The destinations this project uses; empty means every one.
  var destinations: [StoreDestination] = []
  /// What App Store Connect and Google Play know the app by. Empty asks the Xcode scheme in release.env.
  var bundleID: String?

  var used: [StoreDestination] { destinations.isEmpty ? StoreDestination.allCases : destinations }
  var allLocales: [String] { [baseLocale] + locales.filter { $0 != baseLocale } }

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    baseLocale = try container.decodeIfPresent(String.self, forKey: .baseLocale) ?? "en-US"
    locales = try container.decodeIfPresent([String].self, forKey: .locales) ?? []
    destinations = try container.decodeIfPresent([StoreDestination].self, forKey: .destinations) ?? []
    bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
  }
}

nonisolated struct StoreTextError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// A project's store and release text, as plain files in `.dev/store/` so the app, an agent and a text editor all edit
/// the same thing and a diff shows the sentence that changed:
///
///     .dev/store/
///       store.json                   base locale, other locales, destinations, bundle ID
///       .gitignore                   ignores private/
///       en-US/description.txt        the base text
///       en-US/description.appstore.txt   the override for one destination
///       en-US/versions/1.2.0/changelog.txt
///       de-DE/description.txt        the text in another locale
///       translations.json            what each translation was made from
///       private/...                  the same layout, never committed
///
/// A public repository shows everything it holds, so a text starts as a draft in `private/` and moves out when the
/// reader marks it ready, or when it's published and public anyway. Review notes and tester messages always stay there.
/// A file in `private/` wins over the same path outside it. Credentials never come near these files.
nonisolated struct StoreTexts: Sendable {
  let root: URL
  /// `store.json`'s base locale, read once: a text's path depends on it.
  let baseLocale: String

  static let path = ".dev/store"

  init(root: URL) {
    self.root = root
    let url = root.appendingPathComponent(Self.path).appendingPathComponent("store.json")
    baseLocale = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StoreSettings.self, from: $0) }?.baseLocale ?? "en-US"
  }

  var folder: URL { root.appendingPathComponent(Self.path, isDirectory: true) }
  var privateFolder: URL { folder.appendingPathComponent("private", isDirectory: true) }
  var settingsURL: URL { folder.appendingPathComponent("store.json") }

  private var manager: FileManager { .default }

  // MARK: Settings

  func settings() -> StoreSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONDecoder().decode(StoreSettings.self, from: data)
    else { return StoreSettings() }
    return settings
  }

  func save(_ settings: StoreSettings) throws {
    try Self.check(settings.baseLocale, "locale")
    for locale in settings.locales { try Self.check(locale, "locale") }
    try prepareFolder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(settings)
    data.append(0x0A)
    try data.write(to: settingsURL, options: .atomic)
  }

  /// The folder and the `.gitignore` that keeps drafts out of git. Every write comes through here, so a private file
  /// can't exist before the rule that hides it does.
  func prepareFolder() throws {
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let ignore = folder.appendingPathComponent(".gitignore")
    let current = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
    let lines = current.split(separator: "\n").map(String.init)
    guard !lines.contains("/private/") else { return }
    let header = current.isEmpty ? "# Drafts, review notes and messages to testers: never committed (Dev's Store Text tool).\n" : ""
    let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    try (current + separator + header + "/private/\n").write(to: ignore, atomically: true, encoding: .utf8)
  }

  // MARK: Paths

  /// A locale or version becomes a folder name, and agents pass both: nothing that leaves the folder gets through.
  static func check(_ value: String, _ what: String) throws {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !value.isEmpty, !value.hasPrefix("."), value.unicodeScalars.allSatisfy(allowed.contains) else {
      throw StoreTextError("\"\(value)\" isn't a \(what): use letters, numbers, dots and hyphens.")
    }
  }

  /// The file's path under `.dev/store/` or `.dev/store/private/`.
  func relativePath(_ address: StoreAddress) -> String {
    var parts = [address.locale ?? baseLocale]
    if address.field.isPerVersion, let version = address.version { parts += ["versions", version] }
    let override = address.destination.map { ".\($0.rawValue)" } ?? ""
    parts.append("\(address.field.rawValue)\(override).txt")
    return parts.joined(separator: "/")
  }

  private func check(_ address: StoreAddress) throws {
    if let locale = address.locale { try Self.check(locale, "locale") }
    if address.field.isPerVersion {
      guard let version = address.version else {
        throw StoreTextError("\(address.field.title) belongs to a version: name one.")
      }
      try Self.check(version, "version")
    }
  }

  // MARK: Reading

  /// A text as it is on disk.
  struct Entry: Equatable, Sendable {
    var text: String
    /// In `private/`: a draft, or a text that's always private.
    var isPrivate: Bool
  }

  /// The file at exactly this address, without falling back to anything.
  func entry(_ address: StoreAddress) -> Entry? {
    let path = relativePath(address)
    if let text = Self.read(privateFolder.appendingPathComponent(path)) { return Entry(text: text, isPrivate: true) }
    if let text = Self.read(folder.appendingPathComponent(path)) { return Entry(text: text, isPrivate: false) }
    return nil
  }

  /// The text without the newline the file ends in. An empty file is no text.
  private static func read(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
    return trimmed.isEmpty ? nil : trimmed
  }

  /// What a text is made of, for the tool to say.
  enum Origin: String, Codable, Sendable {
    /// This destination's own text in this locale.
    case override
    /// The field's text in this locale.
    case locale
    /// The destination's override in the base locale: nothing in this locale yet.
    case baseOverride = "base-override"
    /// The base text: nothing more specific.
    case base
    case missing
  }

  struct Resolved: Equatable, Sendable {
    var text: String
    var origin: Origin
    var isPrivate: Bool
    /// The file it was read from; nil when nothing was.
    var address: StoreAddress?
    var isEmpty: Bool { text.isEmpty }
  }

  /// What a destination shows for a field in a locale, most specific first: this locale's override, this locale's text
  /// (a translated description beats an English override), the base override, the base text.
  func resolved(
    _ field: StoreField, destination: StoreDestination? = nil, locale: String? = nil, version: String? = nil
  ) -> Resolved {
    let isBase = locale == nil || locale == baseLocale
    var attempts: [(StoreAddress, Origin)] = []
    let scoped = { (destination: StoreDestination?, locale: String?) in
      StoreAddress(field: field, destination: destination, locale: locale, version: version)
    }
    if let destination { attempts.append((scoped(destination, isBase ? nil : locale), .override)) }
    if !isBase { attempts.append((scoped(nil, locale), .locale)) }
    if let destination, !isBase { attempts.append((scoped(destination, nil), .baseOverride)) }
    attempts.append((scoped(nil, nil), .base))
    for (address, origin) in attempts {
      if let entry = entry(address) {
        return Resolved(text: entry.text, origin: origin, isPrivate: entry.isPrivate, address: address)
      }
    }
    return Resolved(text: "", origin: .missing, isPrivate: false)
  }

  /// The versions with any text, newest first.
  func versions() -> [String] {
    var found = Set<String>()
    for container in [folder, privateFolder] {
      let locales = (try? manager.contentsOfDirectory(atPath: container.path)) ?? []
      for locale in locales {
        let folder = container.appendingPathComponent(locale).appendingPathComponent("versions")
        for version in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !version.hasPrefix(".") {
          found.insert(version)
        }
      }
    }
    return found.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
  }

  // MARK: Writing

  /// Writes a text. `ready` true puts it in the repository, false in `private/`; nil keeps it where it is, and a new
  /// text starts private. A field that's always private ignores `ready`. An empty text removes the file.
  func write(_ text: String, at address: StoreAddress, ready: Bool? = nil) throws {
    try check(address)
    try prepareFolder()
    let clean = Self.normalized(text, field: address.field)
    let path = relativePath(address)
    let publicURL = folder.appendingPathComponent(path)
    let privateURL = privateFolder.appendingPathComponent(path)
    let isPublicNow = entry(address)?.isPrivate == false
    let goesPublic = !address.field.isAlwaysPrivate && (ready ?? isPublicNow)
    let target = goesPublic ? publicURL : privateURL
    let other = goesPublic ? privateURL : publicURL
    if clean.isEmpty {
      try? manager.removeItem(at: publicURL)
      try? manager.removeItem(at: privateURL)
      prune(publicURL.deletingLastPathComponent())
      prune(privateURL.deletingLastPathComponent())
      return
    }
    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (clean + "\n").write(to: target, atomically: true, encoding: .utf8)
    if manager.fileExists(atPath: other.path) {
      try manager.removeItem(at: other)
      prune(other.deletingLastPathComponent())
    }
  }

  /// Moves a field's text in every locale between `private/` and the repository: base, and each locale's copy. The
  /// translations follow what they were made from.
  func setReady(_ ready: Bool, field: StoreField, destination: StoreDestination? = nil, version: String? = nil) throws {
    guard !field.isAlwaysPrivate || !ready else {
      throw StoreTextError("\(field.title) stays private: it's written for one reader and never goes into the repository.")
    }
    let settings = settings()
    for locale in settings.allLocales {
      let address = StoreAddress(
        field: field, destination: destination, locale: locale, version: field.isPerVersion ? version : nil)
      if let entry = entry(address), entry.isPrivate == ready {
        try write(entry.text, at: address, ready: ready)
        moveSource(of: address, ready: ready)
      }
    }
  }

  /// Files end in one newline; single lines have no others; lists have one item per line.
  static func normalized(_ text: String, field: StoreField) -> String {
    if field.isList { return StoreLists.text(StoreLists.items(in: text)) }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if field.isSingleLine { return trimmed.replacingOccurrences(of: "\n", with: " ") }
    return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
  }

  /// Removes folders the last file of a text left empty, up to the store's own.
  private func prune(_ start: URL) {
    var current = start.standardizedFileURL
    let stops = [folder.standardizedFileURL.path, privateFolder.standardizedFileURL.path]
    while !stops.contains(current.path), current.path.hasPrefix(folder.standardizedFileURL.path) {
      guard (try? manager.contentsOfDirectory(atPath: current.path))?.isEmpty == true else { return }
      try? manager.removeItem(at: current)
      current = current.deletingLastPathComponent()
    }
  }

  // MARK: Translation records

  /// What each translation was made from, by relative path: a hash of the source text, so a changed source reads as
  /// outdated. A file with no record was written by hand, and translation leaves it alone.
  private func sources(private isPrivate: Bool) -> [String: String] {
    let url = (isPrivate ? privateFolder : folder).appendingPathComponent("translations.json")
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private func saveSources(_ sources: [String: String], private isPrivate: Bool) throws {
    let folder = isPrivate ? privateFolder : self.folder
    let url = folder.appendingPathComponent("translations.json")
    if sources.isEmpty {
      try? manager.removeItem(at: url)
      return
    }
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(sources)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }

  static func hash(_ text: String) -> String {
    // FNV-1a: a change detector for one project's text, nothing to do with security.
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      value ^= UInt64(byte)
      value = value &* 0x0000_0100_0000_01b3
    }
    return String(value, radix: 16)
  }

  /// How a locale's text stands against the base text it comes from.
  enum TranslationState: String, Sendable {
    /// Nothing written in the locale.
    case missing
    /// Translated from the current source.
    case current
    /// Translated from an older source.
    case outdated
    /// Written by hand: translation leaves it alone.
    case manual
  }

  func translationState(of address: StoreAddress) -> TranslationState {
    guard let entry = entry(address) else { return .missing }
    guard let recorded = sources(private: entry.isPrivate)[relativePath(address)] else { return .manual }
    var source = address
    source.locale = nil
    let text = self.entry(source)?.text ?? entry.text
    return recorded == Self.hash(text) ? .current : .outdated
  }

  /// Saves a translation, in the same place its source is, and remembers what it came from.
  func writeTranslation(_ text: String, at address: StoreAddress, sourceText: String, sourceIsPrivate: Bool) throws {
    try write(text, at: address, ready: !sourceIsPrivate)
    var sources = sources(private: sourceIsPrivate)
    sources[relativePath(address)] = Self.hash(sourceText)
    try saveSources(sources, private: sourceIsPrivate)
  }

  /// A hand edit of a translation: it stops following its source.
  func forgetTranslationSource(of address: StoreAddress) throws {
    for isPrivate in [true, false] {
      var sources = sources(private: isPrivate)
      if sources.removeValue(forKey: relativePath(address)) != nil { try saveSources(sources, private: isPrivate) }
    }
  }

  private func moveSource(of address: StoreAddress, ready: Bool) {
    let path = relativePath(address)
    var from = sources(private: ready)
    guard let recorded = from.removeValue(forKey: path) else { return }
    try? saveSources(from, private: ready)
    var to = sources(private: !ready)
    to[path] = recorded
    try? saveSources(to, private: !ready)
  }

  // MARK: Reports

  /// One field at one destination in one locale, as it stands.
  struct SlotReport: Sendable {
    var destination: StoreDestination
    var slot: StoreSlot
    var locale: String
    var version: String?
    var resolved: Resolved
    var count: StoreLimit.Count?
  }

  /// Every slot of the destinations in use, in every locale. `version` fills the per-version fields.
  func report(version: String?, field: StoreField? = nil) -> [SlotReport] {
    let settings = settings()
    var reports: [SlotReport] = []
    for destination in settings.used {
      for slot in destination.slots where field == nil || slot.field == field {
        if slot.field.isPerVersion, version == nil { continue }
        let locales = destination.isLocalized ? settings.allLocales : [settings.baseLocale]
        for locale in locales {
          let resolved = self.resolved(
            slot.field, destination: destination, locale: locale, version: slot.field.isPerVersion ? version : nil)
          reports.append(SlotReport(
            destination: destination, slot: slot, locale: locale, version: slot.field.isPerVersion ? version : nil,
            resolved: resolved, count: resolved.isEmpty ? nil : slot.limit?.count(resolved.text, field: slot.field)))
        }
      }
    }
    return reports
  }

  /// Files held in `private/`, for the tool's line about what stays out of git.
  func privateFileCount() -> Int {
    guard let walker = manager.enumerator(at: privateFolder, includingPropertiesForKeys: nil) else { return 0 }
    var count = 0
    for case let url as URL in walker where url.pathExtension == "txt" { count += 1 }
    return count
  }

  /// Files in `private/` git already tracks, which the ignore rule can't hide: someone forced them in, or they were
  /// committed before the rule. The tool warns, and only the reader can decide to rewrite history.
  func trackedPrivateFiles() async -> [String] {
    let result = await LineProcess.run("/usr/bin/git", ["ls-files", "--", Self.path + "/private"], directory: root)
    guard result.status == 0 else { return [] }
    return result.output.split(separator: "\n").map(String.init)
  }

  // MARK: Versions from git

  /// The first draft of a version's notes: the commits since the newest tag, the same lines `release.sh bump` writes.
  /// It's a draft to edit: a commit message isn't release copy.
  func changelogDraft() async -> String {
    let tag = await LineProcess.run("/usr/bin/git", ["describe", "--tags", "--abbrev=0"], directory: root)
    let name = tag.output.trimmingCharacters(in: .whitespacesAndNewlines)
    var arguments = ["log", "--no-merges", "--format=- %s", "--max-count=200"]
    if tag.status == 0, !name.isEmpty { arguments.append("\(name)..HEAD") }
    let log = await LineProcess.run("/usr/bin/git", arguments, directory: root)
    return log.status == 0 ? log.output : ""
  }

  /// The next version to suggest: one patch above the newest known here or in the tags.
  func suggestedVersion() async -> String {
    let tag = await LineProcess.run("/usr/bin/git", ["describe", "--tags", "--abbrev=0"], directory: root)
    let tagged = tag.status == 0 ? tag.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let cleanTag = tagged.hasPrefix("v") ? String(tagged.dropFirst()) : tagged
    let newest = (versions() + [cleanTag]).filter { !$0.isEmpty }
      .max { $0.compare($1, options: .numeric) == .orderedAscending }
    guard let newest else { return "1.0.0" }
    var parts = newest.split(separator: ".").map(String.init)
    guard let last = parts.last, let number = Int(last) else { return newest + ".1" }
    parts[parts.count - 1] = String(number + 1)
    return parts.joined(separator: ".")
  }
}

/// The store text as the MCP tools answer it.
nonisolated enum StoreMCP {
  /// The base texts as they are, also for a field no chosen destination takes (a report has no row for those).
  static func base(_ texts: StoreTexts, version: String?, field: StoreField?) -> [[String: Any]] {
    let settings = texts.settings()
    var items: [[String: Any]] = []
    for candidate in StoreField.allCases where field == nil || candidate == field {
      if candidate.isPerVersion, version == nil { continue }
      for locale in candidate.isLocalized ? settings.allLocales : [settings.baseLocale] {
        let address = StoreAddress(field: candidate, locale: locale, version: candidate.isPerVersion ? version : nil)
        guard let entry = texts.entry(address) else { continue }
        var item: [String: Any] = ["field": candidate.rawValue, "locale": locale, "text": entry.text, "private": entry.isPrivate]
        if let version = address.version { item["version"] = version }
        items.append(item)
      }
    }
    return items
  }

  static func report(_ texts: StoreTexts, version: String?, field: StoreField?) -> [[String: Any]] {
    texts.report(version: version, field: field).map { row in
      var item: [String: Any] = [
        "field": row.slot.field.rawValue, "destination": row.destination.rawValue, "title": row.slot.title,
        "locale": row.locale, "text": row.resolved.text, "origin": row.resolved.origin.rawValue,
        "private": row.resolved.isPrivate, "sentByPublish": row.slot.isSent,
      ]
      if let version = row.version { item["version"] = version }
      if let count = row.count {
        var limit: [String: Any] = ["used": count.used, "limit": count.limit, "unit": count.unit, "over": count.isOver]
        if let long = count.longItem { limit["longItem"] = long }
        if row.slot.isEstimate { limit["estimate"] = true }
        item["limit"] = limit
      }
      return item
    }
  }
}
