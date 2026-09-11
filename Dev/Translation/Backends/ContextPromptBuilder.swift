//
//  ContextPromptBuilder.swift
//  Dev
//

import Foundation

// MARK: - ContextPromptBuilder

/// Pure prompt assembler for the hosted translation models.
///
/// Foundation-only on purpose: this file (with TranslationContext.swift)
/// compiles standalone under `swiftc`, so prompt assembly stays verifiable
/// without the app, the network, or any credential. The module's MainActor
/// default isolation is opted out via `nonisolated` — the builder has no
/// state and no side effects.
///
/// ## Section order is a cache contract
///
/// Provider prefix caching bills a repeated leading run of tokens at a
/// fraction of the input rate, so sections are emitted **stable first,
/// per-item last**, in three levels:
///
///  - **L0** system prompt (source language only — never the target) and the
///    global + project context docs: identical for every target language.
///  - **L1** target language, its language doc, and the register sample:
///    identical for every record of one target language.
///  - **L2** key, plural form, comment, neighbors and the source text:
///    differs per record.
///
/// Reordering these blocks silently destroys the cache hit rate, so keep the
/// `TEXT TO TRANSLATE` / `ITEMS` payload dead last.
nonisolated struct ContextPromptBuilder {
  // MARK: - limits

  /// Per-scope cap for the context-document bodies, in characters. Separate
  /// numbers because the scopes carry different material: the global doc is
  /// cross-project vocabulary, the project doc is human-authored rules, and
  /// the language doc is accumulated Stage-0 lessons — small on purpose, since
  /// per-key lessons live in translation memory, which resolves exact hits
  /// without any prompt at all.
  static let maxGlobalCharacters = 5_000
  static let maxProjectCharacters = 10_000
  static let maxLanguageCharacters = 1_000
  /// Neighbor samples are capped in count and per-item length.
  static let maxNeighbors = 10
  static let maxNeighborCharacters = 400
  /// Comment and key caps.
  static let maxCommentCharacters = 600
  static let maxKeyCharacters = 200

  // MARK: - batch sizing

  /// Approximate payload cost of ONE batch item, in characters: its source
  /// text plus the per-item key/comment overhead the JSON payload carries. The
  /// batch budget is spent on these; the context blocks are on top of it.
  ///
  /// Deliberately NOT a token estimate: the routed models carry very large
  /// context windows, so a grapheme count is accurate enough and free. Batches
  /// are sized by this instead of by record count because records vary from a
  /// label to a sentence — a fixed count is either wasteful or oversized.
  static func batchCost(sourceText: String, context: TranslationContext?) -> Int {
    var cost = sourceText.count
    if let key = context?.key {
      cost += min(key.count, maxKeyCharacters)
    }
    if let comment = context?.comment {
      cost += min(comment.count, maxCommentCharacters)
    }
    // JSON scaffolding: id, quotes, field names, separators.
    return cost + 24
  }

  // MARK: - output

  /// Two chat messages any OpenAI-style client can send verbatim.
  struct AssembledPrompt: Equatable, Sendable {
    var system: String
    var user: String
  }

  /// One row of a batch request.
  struct BatchItem: Sendable {
    /// Position in the batch; echoed back by the model and validated.
    var id: Int
    var sourceText: String
    var context: TranslationContext?
  }

  // MARK: - single-item assembly

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
    AssembledPrompt(
      system: systemPrompt(sourceLanguage: sourceLanguage, batch: false),
      user: userPrompt(
        sourceText: sourceText,
        targetLanguage: targetLanguage,
        context: context))
  }

  // MARK: - batch assembly

  /// Builds one request that translates many records of the SAME target
  /// language. The shared L0/L1 blocks are emitted once, so a batch of N
  /// costs one copy of the context instead of N.
  ///
  /// `sharedContext` supplies the language-level material (context docs,
  /// register sample); per-item key/comment/plural travel with each item.
  static func assembleBatch(
    items: [BatchItem],
    sourceLanguage: String,
    targetLanguage: String,
    sharedContext: TranslationContext?
  ) -> AssembledPrompt {
    AssembledPrompt(
      system: systemPrompt(sourceLanguage: sourceLanguage, batch: true),
      user: batchUserPrompt(
        items: items,
        targetLanguage: targetLanguage,
        sharedContext: sharedContext))
  }

  // MARK: - system prompt

  /// Fixed role text: job, direction and output rules. The TARGET language is
  /// deliberately absent so this block is byte-identical for every target
  /// language in a run — it is the outermost cacheable prefix.
  static func systemPrompt(sourceLanguage: String, batch: Bool) -> String {
    let output = batch
      ? """
      1. Output ONLY a JSON array — no prose, no markdown fences. Each element \
      is {"id": <the item's id>, "text": "<the translation>"}, one element per \
      input item, in the same order.
      2. The items to translate are in the "ITEMS" section of the user message.
      """
      : """
      1. Output ONLY the translated text — no explanations, no notes, no \
      surrounding quotes, no markdown fences.
      2. The text to translate is the last section of the user message, \
      headed "TEXT TO TRANSLATE".
      """
    return """
    You are a careful software-localization translator. Translate product \
    strings and app content from "\(sourceLanguage)" into the target language \
    named in the "TARGET LANGUAGE" section of the user message.

    Rules:
    \(output)
    3. Preserve placeholders (%@, %lld, {name}), format specifiers, URLs, \
    markup and code tokens exactly as written. Never add or drop a placeholder.
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

  // MARK: - user prompt (single)

  /// L0 → L1 → L2, in that order. See the type doc: this order is a cache
  /// contract, not a style choice.
  static func userPrompt(
    sourceText: String,
    targetLanguage: String,
    context: TranslationContext?
  ) -> String {
    var sections: [String] = []

    // L0 — stable across every target language.
    appendSharedLeading(&sections, context: context)

    // L1 — stable across every record of this target language.
    sections.append("TARGET LANGUAGE\n\(targetLanguage)")
    if let language = context?.languageContext {
      appendContext(
        &sections, title: "CONTEXT — LANGUAGE (\(targetLanguage))", text: language,
        limit: maxLanguageCharacters)
    }

    // L2 — per record.
    appendItemLeading(&sections, context: context)
    let neighbors = normalizeNeighbors(context?.neighbors ?? [])
    if !neighbors.isEmpty {
      sections.append("EXISTING TRANSLATIONS (\(targetLanguage))\n" + neighbors.joined(separator: "\n"))
    }
    sections.append("TEXT TO TRANSLATE\n\(sourceText)")
    return sections.joined(separator: "\n\n")
  }

  // MARK: - user prompt (batch)

  private static func batchUserPrompt(
    items: [BatchItem],
    targetLanguage: String,
    sharedContext: TranslationContext?
  ) -> String {
    var sections: [String] = []

    // L0 — stable across every target language.
    appendSharedLeading(&sections, context: sharedContext)

    // L1 — stable across every record of this target language.
    sections.append("TARGET LANGUAGE\n\(targetLanguage)")
    if let language = sharedContext?.languageContext {
      appendContext(
        &sections, title: "CONTEXT — LANGUAGE (\(targetLanguage))", text: language,
        limit: maxLanguageCharacters)
    }
    let neighbors = normalizeNeighbors(sharedContext?.neighbors ?? [])
    if !neighbors.isEmpty {
      sections.append("EXISTING TRANSLATIONS (\(targetLanguage))\n" + neighbors.joined(separator: "\n"))
    }

    // L2 — the whole batch, last.
    sections.append("ITEMS\n" + itemsJSON(items))
    return sections.joined(separator: "\n\n")
  }

  /// The batch payload: a JSON array so ids round-trip unambiguously.
  private static func itemsJSON(_ items: [BatchItem]) -> String {
    let rows: [[String: String]] = items.map { item in
      var row: [String: String] = [
        "id": String(item.id),
        "source": item.sourceText,
      ]
      if let key = item.context?.key, !key.isEmpty {
        row["key"] = clamp(key, to: maxKeyCharacters)
      }
      if let comment = item.context?.comment,
         !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        row["comment"] = clamp(comment, to: maxCommentCharacters)
      }
      if let category = item.context?.pluralCategory, !category.isEmpty {
        row["pluralForm"] = category
        let forms = item.context?.sourcePluralForms ?? [:]
        if !forms.isEmpty {
          row["sourcePluralForms"] = forms.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " | ")
        }
      }
      return row
    }
    guard let data = try? JSONSerialization.data(
      withJSONObject: rows,
      options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8) else {
      // JSONSerialization cannot fail on [String: String]; keep a safe shape.
      return "[]"
    }
    return text
  }

  // MARK: - shared section helpers

  /// L0 blocks: identical for every target language.
  private static func appendSharedLeading(_ sections: inout [String], context: TranslationContext?) {
    if let global = context?.globalContext {
      appendContext(
        &sections, title: "CONTEXT — GLOBAL", text: global, limit: maxGlobalCharacters)
    }
    if let project = context?.projectContext {
      appendContext(
        &sections, title: "CONTEXT — PROJECT", text: project, limit: maxProjectCharacters)
    }
  }

  /// L2 leading blocks for the single-item prompt.
  private static func appendItemLeading(_ sections: inout [String], context: TranslationContext?) {
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
    if let comment = context?.comment,
       !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("COMMENT\n\(clamp(comment, to: maxCommentCharacters))")
    }
  }

  // MARK: - helpers

  /// Deduplicates a context-document body line by line (order preserved),
  /// then truncates the whole block to the scope's cap.
  ///
  /// The truncation keeps the TAIL: context docs are append-ordered (lessons
  /// and rules are added at the end), so when a doc outgrows its cap the
  /// OLDEST lines are what must go. A head-keeping cut would hide everything
  /// learned since the doc crossed the cap, and only the model would ever see
  /// the truncation marker.
  private static func appendContext(
    _ sections: inout [String],
    title: String,
    text: String,
    limit: Int
  ) {
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
    sections.append("\(title)\n\(clampTail(deduped, to: limit))")
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
  /// the model knows a section was cut. Used for the per-record blocks (key,
  /// comment, neighbor sample), where the head carries the meaning.
  private static func clamp(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n[section truncated]"
  }

  /// Line-aware, TAIL-preserving truncation for context documents, with a
  /// marker at the top naming what was dropped. Input is the already-deduped
  /// document body; lines are kept newest-first until the budget is spent, so
  /// the newest lessons and rules always survive. A single line longer than
  /// the whole budget has no line-level answer — its own tail is kept, so the
  /// block is still bounded and never empty.
  private static func clampTail(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let marker = "[section truncated — oldest lines dropped]"
    let budget = max(0, limit - marker.count - 1)
    var kept: [String] = []
    var used = 0
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
      let line = String(rawLine)
      let cost = line.count + (kept.isEmpty ? 0 : 1)
      if kept.isEmpty, cost > budget {
        kept.append(String(line.suffix(budget)))
        break
      }
      guard used + cost <= budget else { break }
      kept.append(line)
      used += cost
    }
    return marker + "\n" + kept.reversed().joined(separator: "\n")
  }
}
