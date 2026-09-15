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
    /// The reply looks CUT OFF — the model stopped mid-array, so the ids it
    /// never reached were lost to the cut, not individually rejected. Told
    /// apart from `.missingIDs` because the right response differs: re-ask the
    /// remainder in smaller batches instead of repairing id by id.
    case truncated(covered: Int, expected: Int)
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
      case .truncated(let covered, let expected):
        return "reply truncated — \(covered) of \(expected) item(s) returned"
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
  /// "50% off" is not a match because a conversion must follow — and printf's SPACE flag is not
  /// honoured, so a space against the percent keeps prose out of the list (see `Runner.swift`'s
  /// own copy of this pattern for the reasoning). A specifier ends at its CONVERSION, so `%lldd`
  /// is `%lld` followed by a literal `d`, not one token.
  static func placeholders(_ text: String) -> [String] {
    matches(#"%(?:\d+\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|j|t|L|w)?[diouxXeEfgGaAcCsSpn@]"#, in: text)
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
  /// value key. A reply whose array never closes is reported as `.truncated`
  /// (the model stopped mid-answer), and the complete elements it did emit are
  /// still returned — they are real translations, and the caller can re-ask
  /// only for the ids the cut lost. Missing or extra ids are reported
  /// separately so the caller can decide whether to repair or re-run.
  static func parseBatch(_ raw: String, expectedIDs: [Int]) -> (values: [Int: String], issues: [Issue]) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let start = text.firstIndex(of: "[") else {
      return ([:], [.truncated(covered: 0, expected: expectedIDs.count)])
    }
    let closed = text[start...].contains("]")

    var rows: [[String: Any]] = []
    var truncated: Int?
    if closed,
       let end = text.lastIndex(of: "]"),
       start <= end,
       let data = String(text[start...end]).data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      rows = parsed
    } else {
      // No closing bracket (or unparseable after one): salvage the complete
      // elements so the batch's good work is not thrown away.
      rows = salvageRows(text[start...])
      truncated = rows.count
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
    if let covered = truncated {
      issues.append(.truncated(covered: covered, expected: expectedIDs.count))
    }
    let missing = expectedIDs.filter { values[$0] == nil }
    if !missing.isEmpty, truncated == nil {
      issues.append(.missingIDs(missing))
    }
    let unexpected = values.keys.filter { !expectedIDs.contains($0) }
    if !unexpected.isEmpty {
      issues.append(.unexpectedIDs(unexpected.sorted()))
    }
    return (values, issues)
  }

  /// Decodes as many COMPLETE `{…}` rows as the text holds, in order — the
  /// salvage path for a reply the model cut off mid-array. String state is
  /// tracked so a brace inside a translated value cannot end a row early, and
  /// the scan simply stops at the unbalanced object where the cut happened.
  private static func salvageRows(_ text: Substring) -> [[String: Any]] {
    var rows: [[String: Any]] = []
    var depth = 0
    var objectStart: String.Index?
    var inString = false
    var escaped = false

    for index in text.indices {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
      case "{":
        if depth == 0 { objectStart = index }
        depth += 1
      case "}":
        depth -= 1
        if depth <= 0, let objectStart {
          let slice = text[objectStart...index]
          if let data = slice.data(using: .utf8),
             let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rows.append(row)
          }
          depth = 0
          continue
        }
      default:
        continue
      }
    }
    return rows
  }

  private static func intValue(_ any: Any?) -> Int? {
    if let int = any as? Int { return int }
    if let number = any as? NSNumber { return number.intValue }
    if let string = any as? String { return Int(string) }
    return nil
  }
}
