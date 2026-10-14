//
//  CaptionCatalog.swift
//  Dev
//

import Foundation

/// The String Catalog the screenshot captions are translated in (`framing.caption.catalog`): key → language → value.
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
