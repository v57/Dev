//
//  ContextPromptBuilder.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - ContextPromptBuilder

/// Pure prompt assembler for the Command Code backend.
///
/// Foundation-only on purpose: this file (with TranslationContext.swift)
/// compiles standalone under `swiftc`, so prompt assembly stays verifiable
/// without the app, the network, or any credential. The module's MainActor
/// default isolation is opted out via `nonisolated` — the builder has no
/// state and no side effects.
nonisolated struct ContextPromptBuilder {
  // MARK: - limits

  /// Per-document cap for the global / project / language context bodies.
  static let maxContextCharacters = 3_000
  /// Neighbor samples are capped in count and per-item length.
  static let maxNeighbors = 10
  static let maxNeighborCharacters = 400
  /// Comment and key caps.
  static let maxCommentCharacters = 600
  static let maxKeyCharacters = 200

  // MARK: - output

  /// Two chat messages any OpenAI-style client can send verbatim.
  struct AssembledPrompt: Equatable, Sendable {
    var system: String
    var user: String
  }

  // MARK: - assembly

  /// Builds the system + user prompt for one translation request.
  ///
  /// Only sections that carry content are emitted; neighbors and context
  /// documents are deduplicated (order-preserving) and truncated to the
  /// limits above, so the prompt stays bounded no matter how much context
  /// Stage-0 learning has accumulated.
  static func assemble(
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String,
    context: TranslationContext?
  ) -> AssembledPrompt {
    let system = systemPrompt(
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let user = userPrompt(
      sourceText: sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      context: context
    )
    return AssembledPrompt(system: system, user: user)
  }

  /// Fixed role text: job, direction, and output rules. Everything dynamic
  /// lives in the user message, so the system message is cacheable.
  static func systemPrompt(sourceLanguage: String, targetLanguage: String) -> String {
    """
    You are a careful software-localization translator. Translate product \
    strings and app content from "\(sourceLanguage)" into "\(targetLanguage)".

    Rules:
    1. Output ONLY the translated text — no explanations, no notes, no \
    surrounding quotes, no markdown fences.
    2. The text to translate is the last section of the user message, \
    headed "TEXT TO TRANSLATE".
    3. Preserve placeholders (%@, %lld, {name}), format specifiers, URLs, \
    markup and code tokens exactly as written.
    4. Context sections in the user message are authoritative: follow \
    glossary and terminology there over your defaults.
    5. The COMMENT states where the string appears — keep the translation \
    idiomatic for that spot.
    6. "EXISTING TRANSLATIONS" shows the register already used in this \
    target language; stay consistent with it.
    7. When a "PLURAL FORM" section is present, the text is ONE plural \
    category of a localized string: translate it with the number agreement \
    of that category in the target language (e.g. the "one" form reads \
    naturally for exactly one item), keeping placeholders intact.
    When the text is ambiguous, pick the most natural option and translate \
    it — never ask back, never refuse.
    """
  }

  /// One section per input, in a stable order; only non-empty sections are
  /// emitted. The source text is always last (see system rule 2).
  static func userPrompt(
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String,
    context: TranslationContext?
  ) -> String {
    var sections: [String] = []

    if let key = context?.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("KEY\n\(clamp(key, to: maxKeyCharacters))")
    }
    if let category = context?.pluralCategory, !category.isEmpty {
      sections.append("PLURAL FORM\n\(category)")
      let forms = context?.sourcePluralForms ?? [:]
      if !forms.isEmpty {
        let lines = forms.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        sections.append("SOURCE PLURAL FORMS\n" + lines.joined(separator: "\n"))
      }
    }
    if let comment = context?.comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("COMMENT\n\(clamp(comment, to: maxCommentCharacters))")
    }
    if let global = context?.globalContext {
      appendContext(&sections, title: "CONTEXT — GLOBAL", text: global)
    }
    if let project = context?.projectContext {
      appendContext(&sections, title: "CONTEXT — PROJECT", text: project)
    }
    if let language = context?.languageContext {
      appendContext(&sections, title: "CONTEXT — LANGUAGE (\(targetLanguage))", text: language)
    }
    let neighbors = normalizeNeighbors(context?.neighbors ?? [])
    if !neighbors.isEmpty {
      sections.append("EXISTING TRANSLATIONS (\(targetLanguage))\n" + neighbors.joined(separator: "\n"))
    }

    sections.append("TEXT TO TRANSLATE\n\(sourceText)")
    return sections.joined(separator: "\n\n")
  }

  // MARK: - helpers

  /// Deduplicates a context-document body line by line (order preserved),
  /// then truncates the whole block to the per-document cap.
  private static func appendContext(_ sections: inout [String], title: String, text: String) {
    var seen = Set<String>()
    var kept: [String] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !seen.contains(line) else { continue }
      seen.insert(line)
      kept.append(line)
    }
    let deduped = kept.joined(separator: "\n")
    guard !deduped.isEmpty else { return }
    sections.append("\(title)\n\(clamp(deduped, to: maxContextCharacters))")
  }

  /// Neighbors: trim, drop empties, dedupe on the truncated value, cap count.
  private static func normalizeNeighbors(_ neighbors: [String]) -> [String] {
    var seen = Set<String>()
    var kept: [String] = []
    for raw in neighbors {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let value = clamp(trimmed, to: maxNeighborCharacters)
      guard !seen.contains(value) else { continue }
      seen.insert(value)
      kept.append(value)
      if kept.count == maxNeighbors { break }
    }
    return kept
  }

  /// Character-prefix truncation on grapheme boundaries, with a marker so
  /// the model knows a section was cut.
  private static func clamp(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n[section truncated]"
  }
}
