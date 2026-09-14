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
  ///
  /// The document's own `source` is kept too, as `files: key -> sources`: it
  /// is the ONLY place a key's source FILE is recorded (the format carries no
  /// line number), so the on-device comment pass reads its call site from
  /// here. The spelling is whatever the compiler emitted (usually a file
  /// name), and the caller resolves it against the module's own sources —
  /// see `ScanExtractor.compile`.
  static func parse(
    directory: URL
  ) -> (keys: [String: Set<String>], files: [String: Set<String>], skippedTableKeys: Int) {
    var keys: [String: Set<String>] = [:]
    var files: [String: Set<String>] = [:]
    var skipped = 0
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return (keys, files, skipped)
    }
    for file in contents where file.pathExtension == "stringsdata" {
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
          if let source = document.source, !source.isEmpty {
            files[entry.key, default: []].insert(source)
          }
        }
      }
    }
    return (keys, files, skipped)
  }
}
