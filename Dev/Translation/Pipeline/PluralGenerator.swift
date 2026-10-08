//
//  PluralGenerator.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import Foundation

// MARK: - PluralGenerator

/// AI-authored source plural forms for "Generate plural" (row menu).
///
/// Vary-by-plural builds an empty skeleton; this fills the SOURCE forms so
/// the pipeline has something to translate from. The model sees the flat
/// string, its comment, and any already-filled forms, and returns a JSON map
/// for the language's CLDR categories. Only the caller's missing categories
/// are applied — existing forms are sent for consistency but never
/// overwritten here.
nonisolated enum PluralGenerator {
  /// Asks the model for the source-language plural forms. Returns
  /// category -> text (only categories with non-empty text). Throws
  /// `BackendError` (notConfigured when no OpenCode Go key, decoding on an
  /// unusable reply) — never crashes.
  static func sourceForms(
    key: String,
    comment: String?,
    text: String,
    language: String,
    categories: [String],
    existing: [String: String]
  ) async throws -> [String: String] {
    let prompt = promptFor(
      key: key, comment: comment, text: text, language: language,
      categories: categories, existing: existing)
    let raw = try await Stage0ModelClient.complete(system: prompt.system, user: prompt.user)
    guard let forms = parseForms(raw, categories: categories), !forms.isEmpty else {
      throw BackendError.decoding("the model did not return usable plural forms")
    }
    return forms
  }

  // MARK: - prompt

  private struct FormsPrompt {
    var system: String
    var user: String
  }

  private static func promptFor(
    key: String,
    comment: String?,
    text: String,
    language: String,
    categories: [String],
    existing: [String: String]
  ) -> FormsPrompt {
    let system = """
      You are a software-localization authoring assistant. Given ONE source \
      string, write its plural forms in "\(language)".

      Reply with ONLY a JSON object mapping every required category to its \
      form, e.g. {"one": "1 file", "other": "%d files"}. No explanations, no \
      markdown fences, no commentary.

      Rules:
      1. Preserve placeholders (%@, %lld, %d, {name}), format specifiers, \
      URLs, markup and code tokens exactly as written.
      2. Keep the same register and terminology across forms — only number \
      agreement changes.
      3. Reproduce every "already provided" form EXACTLY.
      4. If the string names no countable quantity, return the input text \
      unchanged for every required form.
      """

    var sections: [String] = []
    if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("KEY\n\(key)")
    }
    if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("COMMENT\n\(comment)")
    }
    sections.append("TEXT TO INFLECT\n\(text)")
    let required = categories.map { category in
      if let provided = existing[category] {
        return "\(category) — \(hint(for: category)) (already provided — reproduce exactly: \(provided))"
      }
      return "\(category) — \(hint(for: category)) (missing — write this)"
    }
    sections.append("REQUIRED CATEGORIES\n" + required.joined(separator: "\n"))

    return FormsPrompt(system: system, user: sections.joined(separator: "\n\n"))
  }

  /// Number-agreement hint per CLDR category.
  private static func hint(for category: String) -> String {
    switch category {
    case "zero": return "exactly zero items"
    case "one": return "exactly one item"
    case "two": return "exactly two items"
    case "few": return "a few items"
    case "many": return "many items"
    default: return "any other number — the fallback"
    }
  }

  // MARK: - parsing

  /// Parses the model's reply into category -> text, keeping only the
  /// requested categories with non-blank text. Tolerates one markdown fence
  /// pair and surrounding prose (extracts the first {...} block). Nil when
  /// nothing usable comes back.
  private static func parseForms(_ raw: String, categories: [String]) -> [String: String]? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let start = text.firstIndex(of: "{"),
          let end = text.lastIndex(of: "}"),
          start <= end else {
      return nil
    }
    let json = String(text[start...end])
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
      return nil
    }
    var forms: [String: String] = [:]
    for category in categories {
      if let value = decoded[category],
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        forms[category] = value
      }
    }
    return forms.isEmpty ? nil : forms
  }
}
