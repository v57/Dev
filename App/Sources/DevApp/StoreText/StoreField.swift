//
//  StoreField.swift
//  Dev
//

import Foundation

/// One thing a store or release page shows. Each is a plain text file (`StoreTexts`), so a field has one base text,
/// an optional override per destination and a text per locale.
nonisolated enum StoreField: String, CaseIterable, Identifiable, Codable, Sendable {
  case name, subtitle, description, keywords
  case promotionalText = "promotional-text"
  case supportURL = "url-support"
  case marketingURL = "url-marketing"
  case privacyURL = "url-privacy"
  case category, copyright
  case reviewNotes = "review-notes"
  case changelog, testers

  var id: String { rawValue }

  var title: String {
    switch self {
    case .name: "Name"
    case .subtitle: "Subtitle"
    case .description: "Description"
    case .keywords: "Keywords"
    case .promotionalText: "Promotional Text"
    case .supportURL: "Support URL"
    case .marketingURL: "Marketing URL"
    case .privacyURL: "Privacy Policy URL"
    case .category: "Category"
    case .copyright: "Copyright"
    case .reviewNotes: "Review Notes"
    case .changelog: "Changelog"
    case .testers: "Message to Testers"
    }
  }

  var systemImage: String {
    switch self {
    case .name: "textformat"
    case .subtitle: "text.alignleft"
    case .description: "doc.plaintext"
    case .keywords: "tag"
    case .promotionalText: "megaphone"
    case .supportURL, .marketingURL, .privacyURL: "link"
    case .category: "square.grid.2x2"
    case .copyright: "c.circle"
    case .reviewNotes: "checkmark.seal"
    case .changelog: "list.bullet.rectangle"
    case .testers: "testtube.2"
    }
  }

  /// A file per version (`versions/<version>/`), the others hold for the app.
  var isPerVersion: Bool { self == .changelog || self == .testers }

  /// Never reach git, whatever their state: review notes and tester messages are written for one reader.
  var isAlwaysPrivate: Bool { self == .reviewNotes || self == .testers }

  /// Dev's translation fills these per locale. A name stays as it is unless a locale says otherwise, and review notes
  /// are read by one review team.
  var isTranslated: Bool {
    switch self {
    case .subtitle, .description, .keywords, .promotionalText, .changelog, .testers: true
    default: false
    }
  }

  /// Has a text per language at all: these three say one thing whatever the language.
  var isLocalized: Bool { self != .category && self != .copyright && self != .reviewNotes }

  /// One value on one line, edited in a field instead of a text area.
  var isSingleLine: Bool {
    switch self {
    case .name, .subtitle, .supportURL, .marketingURL, .privacyURL, .category, .copyright: true
    default: false
    }
  }

  /// A list, one item per line in its file so a diff names the item that changed.
  var isList: Bool { self == .keywords }

  /// Listed in this order in the tool.
  static let listing: [StoreField] = [
    .name, .subtitle, .description, .keywords, .promotionalText, .category, .copyright,
  ]
  static let links: [StoreField] = [.supportURL, .marketingURL, .privacyURL]
  static let perVersion: [StoreField] = [.changelog, .testers]
}

/// Where a text goes.
nonisolated enum StoreDestination: String, CaseIterable, Identifiable, Codable, Sendable {
  case appStore = "appstore"
  case github
  case googlePlay = "googleplay"
  case microsoftStore = "msstore"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .appStore: "App Store Connect"
    case .github: "GitHub"
    case .googlePlay: "Google Play"
    case .microsoftStore: "Microsoft Store"
    }
  }

  /// Short, for a segment.
  var shortTitle: String {
    switch self {
    case .appStore: "App Store"
    case .github: "GitHub"
    case .googlePlay: "Google Play"
    case .microsoftStore: "Microsoft"
    }
  }

  var systemImage: String {
    switch self {
    case .appStore: "app.badge"
    case .github: "arrow.triangle.branch"
    case .googlePlay: "play"
    case .microsoftStore: "square.grid.2x2"
    }
  }

  /// What each field is called here and how long it may be. A field missing from the list doesn't exist here.
  ///
  /// Limits checked against each service's documentation on 2026-11-04: App Store Connect's reference for app
  /// information and platform version information, GitHub's topic docs, Play Console Help's listing and release notes
  /// pages, and Partner Center's store listing pages. `isEstimate` marks the ones no service documents: they warn,
  /// but don't stop a publish. A field with no limit has none documented (App Store copyright, certification notes).
  var slots: [StoreSlot] {
    switch self {
    case .appStore:
      [
        StoreSlot(.name, "Name", .characters(30)),
        StoreSlot(.subtitle, "Subtitle", .characters(30)),
        StoreSlot(.description, "Description", .characters(4000)),
        // Bytes, and the commas count: the list goes as one comma-separated string.
        StoreSlot(.keywords, "Keywords", .bytes(100)),
        StoreSlot(.promotionalText, "Promotional Text", .characters(170)),
        StoreSlot(.supportURL, "Support URL", nil),
        StoreSlot(.marketingURL, "Marketing URL", nil),
        StoreSlot(.privacyURL, "Privacy Policy URL", nil),
        StoreSlot(.category, "Primary Category", nil, hint: "An ID such as DEVELOPER_TOOLS"),
        StoreSlot(.copyright, "Copyright", nil),
        StoreSlot(.reviewNotes, "Notes for App Review", .bytes(4000)),
        StoreSlot(.changelog, "What's New", .characters(4000)),
        StoreSlot(
          .testers, "TestFlight What to Test", .characters(4000), hint: "Apple documents no limit; 4000 as for What's New",
          isEstimate: true),
      ]
    case .github:
      [
        StoreSlot(
          .subtitle, "Repository Description", .characters(350), hint: "GitHub documents no limit; 350 as reported",
          isEstimate: true),
        StoreSlot(.keywords, "Topics", .items(max: 20, eachCharacters: 50), hint: "Lowercase letters, numbers and hyphens"),
        StoreSlot(.marketingURL, "Homepage", nil),
        StoreSlot(
          .changelog, "Release Notes", .characters(125_000), hint: "GitHub documents no limit; 125,000 as reported",
          isEstimate: true),
      ]
    case .googlePlay:
      [
        StoreSlot(.name, "Title", .characters(30)),
        StoreSlot(.subtitle, "Short Description", .characters(80)),
        StoreSlot(.description, "Full Description", .characters(4000)),
        StoreSlot(.supportURL, "Website", nil),
        StoreSlot(.privacyURL, "Privacy Policy", nil, isSent: false),
        StoreSlot(.category, "Category", nil, isSent: false),
        StoreSlot(.changelog, "Release Notes", .characters(500)),
        StoreSlot(.testers, "Test Track Notes", .characters(500), hint: "Goes to the test track in release.env"),
      ]
    case .microsoftStore:
      [
        StoreSlot(.name, "Product Name", .characters(256)),
        StoreSlot(.subtitle, "Short Description", .characters(1000)),
        StoreSlot(.description, "Description", .characters(10_000)),
        StoreSlot(.keywords, "Search Terms", .items(max: 7, eachCharacters: 40), hint: "At most 21 different words"),
        // The submission API ignores these three now: Partner Center's Properties page holds them.
        StoreSlot(.supportURL, "Support Contact", nil, isSent: false),
        StoreSlot(.marketingURL, "Website", nil, isSent: false),
        StoreSlot(.privacyURL, "Privacy Policy", nil, isSent: false),
        StoreSlot(.category, "Category", nil, isSent: false),
        StoreSlot(.copyright, "Copyright and Trademark", .characters(200)),
        StoreSlot(.reviewNotes, "Notes for Certification", nil),
        StoreSlot(.changelog, "What's New", .characters(1500)),
      ]
    }
  }

  func slot(_ field: StoreField) -> StoreSlot? { slots.first { $0.field == field } }

  /// GitHub has one language.
  var isLocalized: Bool { self != .github }

  /// Whether this field has a value per locale here, or one for the app.
  func isPerLocale(_ field: StoreField) -> Bool {
    switch self {
    case .github: false
    case .appStore: field != .category && field != .copyright && field != .reviewNotes
    case .googlePlay: [.name, .subtitle, .description, .changelog, .testers].contains(field)
    case .microsoftStore: [.name, .subtitle, .description, .keywords, .copyright, .changelog].contains(field)
    }
  }

  /// A text as this destination's list wants it: GitHub's topics are lowercase with hyphens.
  func localForm(_ text: String, field: StoreField) -> String {
    guard field.isList else { return StoreTexts.normalized(text, field: field) }
    let items = StoreLists.items(in: text)
    guard self == .github else { return StoreLists.text(items) }
    return StoreLists.text(items.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") })
  }

  /// Whether two texts say the same here. GitHub keeps topics in its own order.
  func isSame(_ first: String, _ second: String, field: StoreField) -> Bool {
    let (a, b) = (localForm(first, field: field), localForm(second, field: field))
    guard field.isList, self == .github else { return a == b }
    return StoreLists.items(in: a).sorted() == StoreLists.items(in: b).sorted()
  }
}

/// A field at one destination.
nonisolated struct StoreSlot: Identifiable, Hashable, Sendable {
  let field: StoreField
  let title: String
  let limit: StoreLimit?
  var hint: String?
  /// False where the service's API can't set it: the tool counts the text and offers it to copy.
  var isSent = true
  /// The limit is what people report, not what the service documents: going over warns without blocking.
  var isEstimate = false

  var id: String { field.rawValue }

  init(
    _ field: StoreField, _ title: String, _ limit: StoreLimit?, hint: String? = nil, isSent: Bool = true,
    isEstimate: Bool = false
  ) {
    self.field = field
    self.title = title
    self.limit = limit
    self.hint = hint
    self.isSent = isSent
    self.isEstimate = isEstimate
  }
}

/// How long a text may be at a destination.
nonisolated enum StoreLimit: Hashable, Sendable {
  case characters(Int)
  case bytes(Int)
  /// A list: how many items, and how long each.
  case items(max: Int, eachCharacters: Int)

  /// What the text measures against the limit.
  struct Count: Hashable, Sendable {
    let used: Int
    let limit: Int
    let unit: String
    /// An item over its own length, in a list.
    var longItem: String?

    var isOver: Bool { used > limit || longItem != nil }
    var text: String { "\(used) / \(limit) \(unit)" }
    /// How far along, for a bar.
    var fraction: Double { limit == 0 ? 0 : Double(used) / Double(limit) }
  }

  /// Counts `text` as the destination would receive it.
  func count(_ text: String, field: StoreField) -> Count {
    let sent = field.isList ? StoreLists.items(in: text).joined(separator: ",") : text
    switch self {
    case .characters(let limit):
      return Count(used: sent.count, limit: limit, unit: "characters")
    case .bytes(let limit):
      return Count(used: sent.utf8.count, limit: limit, unit: "bytes")
    case .items(let max, let each):
      let items = StoreLists.items(in: text)
      return Count(
        used: items.count, limit: max, unit: "items", longItem: items.first { $0.count > each })
    }
  }
}

/// A list's text: one item per line in the file; commas are accepted when one is pasted or imported.
nonisolated enum StoreLists {
  static func items(in text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "," })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  static func text(_ items: [String]) -> String { items.joined(separator: "\n") }
}
