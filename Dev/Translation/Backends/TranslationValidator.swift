//
//  TranslationValidator.swift
//  Dev
//

import Foundation

// MARK: - TranslationValidator

/// Deterministic checks on model output. Runs BEFORE any paid review pass, so
/// the failures that matter most (dropped placeholders, empty replies,
/// untranslated echoes, misaligned batch ids) are caught for free.
nonisolated enum TranslationValidator {
  /// A reason a translation was rejected.
  enum Issue: Equatable, Sendable {
    case empty
    /// Placeholder multiset differs from the source's.
    case placeholders(expected: [String], got: [String])
    /// The "translation" is the source text unchanged.
    case echo
    /// The batch response did not cover every requested id.
    case missingIDs([Int])
    /// The batch response invented ids that were never requested.
    case unexpectedIDs([Int])

    var description: String {
      switch self {
      case .empty:
        return "empty response"
      case .placeholders(let expected, let got):
        return "placeholders changed (expected \(expected.joined(separator: " ")), got \(got.joined(separator: " ")))"
      case .echo:
        return "untranslated (identical to source)"
      case .missingIDs(let ids):
        return "missing ids \(ids.map(String.init).joined(separator: ","))"
      case .unexpectedIDs(let ids):
        return "unexpected ids \(ids.map(String.init).joined(separator: ","))"
      }
    }
  }

  // MARK: - placeholder extraction

  /// Placeholder / format-specifier tokens, in order of appearance.
  ///
  /// Covers printf-style specifiers (`%@`, `%lld`, `%1$@`, `%.2f`) and
  /// brace-style tokens (`{name}`, `{{name}}`). A bare percent such as
  /// "50% off" is not a match because a letter or `@` must follow.
  static func placeholders(_ text: String) -> [String] {
    matches(#"%(\d+\$)?[@a-zA-Z][a-zA-Z0-9]*"#, in: text)
      + matches(#"\{\{?[A-Za-z_][A-Za-z0-9_]*\}?\}"#, in: text)
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }

  /// Multiset comparison: translations legitimately reorder placeholders, so
  /// only the SET of tokens (with duplicates) has to survive.
  static func placeholdersMatch(source: String, target: String) -> Bool {
    placeholders(source).sorted() == placeholders(target).sorted()
  }

  // MARK: - single item

  /// Everything wrong with one translation. Empty means it is acceptable.
  static func validate(source: String, target: String) -> [Issue] {
    var issues: [Issue] = []
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [.empty] }
    if !placeholdersMatch(source: source, target: target) {
      issues.append(.placeholders(
        expected: placeholders(source).sorted(),
        got: placeholders(target).sorted()))
    }
    // Only meaningful for strings long enough that an unchanged copy is not a
    // legitimate loanword/acronym.
    let sourceTrimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if sourceTrimmed.count > 4, trimmed.caseInsensitiveCompare(sourceTrimmed) == .orderedSame {
      issues.append(.echo)
    }
    return issues
  }

  // MARK: - batch response

  /// Parses a model's batch reply into id → translation.
  ///
  /// Tolerates a markdown fence and either `text` or `translation` as the
  /// value key. Returns nil only when no JSON array can be recovered at all;
  /// missing or extra ids are reported separately so the caller can decide
  /// whether to repair or re-run the whole batch.
  static func parseBatch(_ raw: String, expectedIDs: [Int]) -> (values: [Int: String], issues: [Issue]) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let start = text.firstIndex(of: "["),
          let end = text.lastIndex(of: "]"),
          start <= end,
          let data = String(text[start...end]).data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return ([:], [.missingIDs(expectedIDs)])
    }

    var values: [Int: String] = [:]
    for row in rows {
      guard let id = intValue(row["id"]) else { continue }
      let value = (row["text"] as? String) ?? (row["translation"] as? String) ?? ""
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      values[id] = trimmed
    }

    var issues: [Issue] = []
    let missing = expectedIDs.filter { values[$0] == nil }
    if !missing.isEmpty {
      issues.append(.missingIDs(missing))
    }
    let unexpected = values.keys.filter { !expectedIDs.contains($0) }
    if !unexpected.isEmpty {
      issues.append(.unexpectedIDs(unexpected.sorted()))
    }
    return (values, issues)
  }

  private static func intValue(_ any: Any?) -> Int? {
    if let int = any as? Int { return int }
    if let number = any as? NSNumber { return number.intValue }
    if let string = any as? String { return Int(string) }
    return nil
  }
}
