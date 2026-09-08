import Foundation

enum CatalogError: Error {
  case notAnObject(String)
}

/// Outcome of merging extracted keys into a catalog file.
struct CatalogMergeOutcome {
  var existingEntryCount: Int
  var addedCount: Int
  var wroteFile: Bool
  var totalEntryCount: Int { existingEntryCount + addedCount }
}

/// Loads an .xcstrings catalog, merges extracted keys into it, and writes it
/// back as canonical pretty-printed JSON.
///
/// Semantics (never clobber a translation):
/// - Entries already present in the catalog — including every localization,
///   state, variation and unknown field — are preserved byte-for-byte at the
///   semantic level: the merge only *reads* existing entries, never rewrites
///   them.
/// - Keys missing from the catalog are added as entries with an empty
///   localization set and `extractionState: "new"` (source-language display
///   falls back to the key text, which is also the extracted default value).
/// - The existing top-level document is carried through unmodified except
///   for the added entries. When nothing is added the file is not rewritten.
/// - Writing uses `JSONSerialization` so numbers, booleans, exotic escaping
///   and unknown fields round-trip losslessly; keys are sorted for
///   deterministic output.
enum CatalogMerger {
  static func merge(
    extractedKeys: [String: Set<String>],
    into outputURL: URL
  ) throws -> CatalogMergeOutcome {
    var top: [String: Any]
    var strings: [String: Any]

    if FileManager.default.fileExists(atPath: outputURL.path) {
      let data = try Data(contentsOf: outputURL)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CatalogError.notAnObject("\(outputURL.path) is not a JSON object")
      }
      top = object
      strings = (top["strings"] as? [String: Any]) ?? [:]
    } else {
      top = ["sourceLanguage": "en", "version": "1.1"]
      strings = [:]
    }

    let existingCount = strings.count
    var added = 0
    for key in extractedKeys.keys.sorted() where strings[key] == nil {
      var entry: [String: Any] = [:]
      let comments = (extractedKeys[key] ?? [])
        .filter { !$0.isEmpty }
        .sorted()
      if !comments.isEmpty {
        entry["comment"] = comments.joined(separator: "\n")
      }
      entry["extractionState"] = "new"
      strings[key] = entry
      added += 1
    }

    guard added > 0 else {
      return CatalogMergeOutcome(existingEntryCount: existingCount, addedCount: 0, wroteFile: false)
    }

    top["strings"] = strings
    var data = try JSONSerialization.data(
      withJSONObject: top,
      options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A) // trailing newline, like Xcode's own files

    let parent = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try data.write(to: outputURL, options: .atomic)

    return CatalogMergeOutcome(existingEntryCount: existingCount, addedCount: added, wroteFile: true)
  }
}
