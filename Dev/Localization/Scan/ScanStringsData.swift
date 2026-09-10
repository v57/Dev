//
//  ScanStringsData.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// One extracted localization entry inside a `.stringsdata` document.
nonisolated struct ScanStringsDataEntry: Decodable {
  var key: String
  var comment: String?
}

/// Decoded shape of the per-source-file `.stringsdata` JSON that the Swift
/// compiler emits next to `-emit-localized-strings`:
/// `{ "source": "File.swift", "tables": { "Localizable": [ { key, comment } ] } }`
nonisolated struct ScanStringsDataDocument: Decodable {
  var source: String?
  var tables: [String: [ScanStringsDataEntry]]?
}

/// Parses the `.stringsdata` artifacts written by the extraction step.
nonisolated enum ScanStringsData {
  /// Default table every localizable API without an explicit `tableName`
  /// targets — the only table that belongs in `Localizable.xcstrings`.
  static let localizableTable = "Localizable"

  /// Reads every `*.stringsdata` file in `directory` and folds the entries
  /// of the Localizable table into `key -> comments`. Entries in any other
  /// table (custom `tableName:`s) are counted and reported separately.
  static func parse(directory: URL) -> (keys: [String: Set<String>], skippedTableKeys: Int) {
    var keys: [String: Set<String>] = [:]
    var skipped = 0
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return (keys, skipped)
    }
    for file in files where file.pathExtension == "stringsdata" {
      guard let data = try? Data(contentsOf: file),
            let document = try? JSONDecoder().decode(ScanStringsDataDocument.self, from: data),
            let tables = document.tables
      else {
        continue
      }
      for (tableName, entries) in tables {
        guard tableName == localizableTable else {
          skipped += entries.count
          continue
        }
        for entry in entries {
          keys[entry.key, default: []].insert(entry.comment ?? "")
        }
      }
    }
    return (keys, skipped)
  }
}
