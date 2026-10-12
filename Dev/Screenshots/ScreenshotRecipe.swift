//
//  ScreenshotRecipe.swift
//  Dev
//

import Foundation

// MARK: - Recipe

/// How a project's captured screenshots become App Store pictures, in
/// `.dev/screenshots.json` at the project root: a background per scene, a
/// caption translated through the project's String Catalog, the window scaled
/// and shadowed, exported at one App Store size. Agents edit the same file over
/// MCP, and `updatedBy` says who changed it last.
nonisolated struct ScreenshotRecipe: Codable, Hashable, Sendable {
  /// The exported size in pixels: one of App Store Connect's sizes.
  var width = 2880
  var height = 1800
  /// The background when a scene sets none (`#RRGGBB`).
  var background = "#1D1D1F"
  var caption = Caption()
  var window = Window()
  /// Per captured picture, by name: its caption and background.
  var scenes: [Scene] = []
  /// Who changed the recipe last ("you", "Claude through MCP") and when.
  var updatedBy: String?
  var updatedAt: Date?

  struct Caption: Codable, Hashable, Sendable {
    /// The String Catalog captions are translated in, relative to the root.
    /// Each scene's caption is the key, as in any .xcstrings.
    var catalog = "Screenshots.xcstrings"
    /// Points at the exported size.
    var fontSize: Double = 110
    var color = "#FFFFFF"
    var bold = true
    /// More lines than this is reported as a caption that does not fit.
    var maxLines = 2
    /// Space above the caption, as a fraction of the height.
    var top: Double = 0.07
  }

  struct Window: Codable, Hashable, Sendable {
    /// The screenshot's width as a fraction of the picture's.
    var scale: Double = 0.82
    var shadow = true
    /// `bottom` lets the window run off the bottom edge, `center` floats it.
    var align = "bottom"
    var cornerRadius: Double = 24
  }

  struct Scene: Codable, Hashable, Sendable, Identifiable {
    /// The captured picture's name (`01-localization`).
    var match: String
    /// The caption in the development language: the catalog key.
    var caption: String?
    var background: String?

    var id: String { match }
  }

  func scene(named name: String) -> Scene? {
    scenes.first { name == $0.match || name.hasPrefix($0.match) }
  }

  // MARK: - file

  static func url(in root: URL) -> URL {
    root.appendingPathComponent(".dev/screenshots.json")
  }

  static func load(in root: URL) -> ScreenshotRecipe? {
    guard let data = try? Data(contentsOf: url(in: root)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ScreenshotRecipe.self, from: data)
  }

  func save(in root: URL, by author: String) throws {
    var recipe = self
    recipe.updatedBy = author
    recipe.updatedAt = Date()
    let url = Self.url(in: root)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(recipe).write(to: url, options: .atomic)
  }

  /// A starting recipe for a set of captured names: the default background and
  /// no captions, so the first render is the screenshots on a plain ground.
  static func starter(for names: [String], platform: String) -> ScreenshotRecipe {
    var recipe = ScreenshotRecipe()
    if platform == "ios" {
      recipe.width = 1320
      recipe.height = 2868
      recipe.caption.fontSize = 96
      recipe.window.scale = 0.86
    }
    recipe.scenes = names.map { Scene(match: $0) }
    return recipe
  }

  // MARK: - App Store sizes

  /// App Store Connect's accepted screenshot sizes, landscape and portrait.
  static let macSizes: [(Int, Int)] = [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]
  static let iPhoneSizes: [(Int, Int)] = [(1320, 2868), (1290, 2796), (1242, 2688), (1284, 2778), (1179, 2556), (1206, 2622)]
  static let iPadSizes: [(Int, Int)] = [(2064, 2752), (2048, 2732)]

  static func isAppStoreSize(width: Int, height: Int) -> Bool {
    (macSizes + iPhoneSizes + iPadSizes).contains { size in
      (size.0 == width && size.1 == height) || (size.0 == height && size.1 == width)
    }
  }
}

// MARK: - Captions

/// The captions' String Catalog: key → language → value.
nonisolated enum CaptionCatalog {
  static func load(_ url: URL) -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = json["strings"] as? [String: Any]
    else { return [:] }
    var out: [String: [String: String]] = [:]
    for (key, entry) in strings {
      guard let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
      for (language, value) in localizations {
        if let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any],
           let text = unit["value"] as? String {
          out[key, default: [:]][language] = text
        }
      }
    }
    return out
  }

  /// The caption in a locale (`de-DE` tries `de-DE`, then `de`), else the key.
  static func caption(_ key: String, locale: String, in table: [String: [String: String]]) -> String {
    let values = table[key] ?? [:]
    let language = locale.split(separator: "-").first.map(String.init) ?? locale
    return values[locale] ?? values[language] ?? key
  }

  /// Adds every scene caption missing from the catalog as a key, so the
  /// Localization tool translates them with the rest of the project.
  static func addMissingKeys(_ keys: [String], to url: URL, sourceLanguage: String = "en") throws {
    var json: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      json = existing
    } else {
      json = ["sourceLanguage": sourceLanguage, "version": "1.0"]
    }
    var strings = json["strings"] as? [String: Any] ?? [:]
    var changed = false
    for key in keys where strings[key] == nil {
      strings[key] = ["comment": "App Store screenshot caption", "extractionState": "manual"]
      changed = true
    }
    guard changed || json["strings"] == nil else { return }
    json["strings"] = strings
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
  }
}
