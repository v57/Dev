//
//  Stage0Learner.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - Stage0ModelClient

/// Raw chat channel for the Stage-0 LEARN calls (deepseek via Command Code).
///
/// Translating strings goes through `TranslatorBackend.translate`, but
/// learning is a different task (fold a confirmed edit into a glossary
/// document with OVERRIDE authority), so it needs its own prompt — and its
/// own wire call. The wire is deliberately a mirror of
/// `CommandCodeTranslator` (same endpoint/model/key lookup, same OpenAI chat
/// shape); the two live in different cards' folders (Backends vs Pipeline),
/// and the constants below are reused rather than duplicated.
nonisolated enum Stage0ModelClient {
  /// True when a key is configured somewhere (keychain/env/.env).
  static var isConfigured: Bool {
    CommandCodeKeychain.apiKey() != nil
  }

  /// One chat completion. Throws `BackendError` on any failure (never
  /// crashes); returns the trimmed message content.
  static func complete(system: String, user: String) async throws -> String {
    guard let apiKey = CommandCodeKeychain.apiKey() else {
      throw BackendError.notConfigured(
        "Command Code is not configured: set COMMANDCODE_API_KEY in the login keychain, "
          + "the environment, or ~/.hermes/.env."
      )
    }

    let body: Data
    do {
      body = try JSONEncoder().encode(
        Request(
          model: CommandCodeTranslator.model,
          messages: [
            Request.Message(role: "system", content: system),
            Request.Message(role: "user", content: user),
          ]
        )
      )
    } catch {
      throw BackendError.network("could not encode request: \(error.localizedDescription)")
    }

    var request = URLRequest(url: CommandCodeTranslator.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = CommandCodeTranslator.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = body

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw BackendError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw BackendError.network("no HTTP response from Command Code")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw BackendError.badStatus(http.statusCode, BackendError.bodyExcerpt(data))
    }

    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
    }
    if let apiError = decoded.error?.message, !apiError.isEmpty {
      throw BackendError.badStatus(http.statusCode, apiError)
    }
    guard
      let content = decoded.choices?.first?.message?.content,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BackendError.emptyResult("Command Code (\(CommandCodeTranslator.model)) learn call")
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - wire shapes (mirror of CommandCodeTranslator)

  private struct Request: Encodable {
    var model: String
    var messages: [Message]
    var temperature: Double = 0.0

    struct Message: Encodable {
      var role: String
      var content: String
    }
  }

  private struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        var content: String?
      }

      var message: Message?
    }

    struct APIError: Decodable {
      var message: String?
    }

    var choices: [Choice]?
    var error: APIError?
  }
}

// MARK: - GlossaryFormat

/// Canonical on-disk format of a lesson inside a language ContextDoc.
///
/// Each lesson occupies exactly ONE line:
///
///     KEY<TAB>SOURCE<TAB>VALUE
///
/// A literal tab/newline/backslash INSIDE a field is escaped as \\t / \\n /
/// \\\\ so the line stays single-line and the coverage check stays exact.
/// The model has OVERRIDE authority: when the doc already holds a line with
/// the same KEY+SOURCE but an outdated VALUE, it rewrites that line in place
/// instead of appending a second one. One line per (key, source) is what
/// makes Stage 0 idempotent: an already-covered lesson is detected
/// deterministically and never re-sent to the model.
nonisolated enum GlossaryFormat {
  /// Literal reply the model gives when the doc already covers the lesson.
  static let noChangeMarker = "NO_CHANGE"

  /// The literal two-character escape models sometimes emit instead of a
  /// real tab separator (they read the instruction as "write \\t"). Tolerated
  /// on read, canonicalized to a real tab on write.
  static let literalSeparator = "\\t"

  static func escapeField(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }

  static func lessonLine(key: String, source: String, value: String) -> String {
    "\(key)\t\(escapeField(source))\t\(escapeField(value))"
  }

  /// True when the doc content already carries exactly this lesson — in
  /// either the canonical real-tab form or the two-character \\t form a
  /// model may have written. Deterministic half of Stage-0 idempotency.
  static func isCovered(content: String, key: String, source: String, value: String) -> Bool {
    let escapedSource = escapeField(source)
    let escapedValue = escapeField(value)
    let canonical = "\(key)\t\(escapedSource)\t\(escapedValue)"
    let literalStyle = "\(key)\(literalSeparator)\(escapedSource)\(literalSeparator)\(escapedValue)"
    return content
      .split(separator: "\n", omittingEmptySubsequences: false)
      .contains { line in
        String(line) == canonical || String(line) == literalStyle
      }
  }

  /// Rewrites lesson lines that use the two-character \\t separator (or a
  /// trailing-tab variant) into the canonical real-tab form. Only lines that
  /// split into EXACTLY three fields are touched — anything ambiguous is
  /// preserved byte-for-byte. Applied on every doc write so the stored
  /// document converges on one format and coverage stays exact.
  static func canonicalize(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let canonicalized = lines.map { rawLine -> String in
      let line = String(rawLine)
      // Already real-tab separated with exactly three fields: canonical.
      let realParts = line.split(separator: "\t", omittingEmptySubsequences: false)
      if realParts.count == 3 {
        return line
      }
      // Two-character \\t separators with exactly three fields.
      if !line.contains("\t"), line.contains(literalSeparator) {
        let parts = line.components(separatedBy: literalSeparator)
        if parts.count == 3 {
          return "\(parts[0])\t\(parts[1])\t\(parts[2])"
        }
      }
      return line
    }
    return canonicalized.joined(separator: "\n")
  }

  /// Parses the model's reply into a fold decision.
  enum FoldReply {
    case noChange
    case revised(String)
    case unusable
  }

  static func parseFoldReply(_ raw: String) -> FoldReply {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Tolerate a single markdown fence pair some models insist on.
    if text.hasPrefix("```") {
      text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !text.isEmpty else { return .unusable }
    if text == noChangeMarker {
      return .noChange
    }
    return .revised(text)
  }
}

// MARK: - Stage0Learner

/// The Stage-0 learning engine: folds PENDING user-confirmed TranslationEdits
/// (isUserConfirmed == true, and still the record's current value) into the
/// language-scope ContextDoc of the edit's target language, then upserts the
/// reviewed TranslationMemoryEntry.
///
/// Pending definition (keeps runs idempotent WITHOUT extra model fields):
///  - the edit is user-confirmed,
///  - the record's current value IS the edit's toValue (older confirmed
///    edits are superseded history and are never re-learned),
///  - no reviewed TM entry for the (sourceText, sourceLanguage, targetLanguage)
///    triple carries this value yet, and the language doc does not already
///    contain the canonical lesson line.
///
/// A fold is LLM-driven: deepseek sees the current doc + the lesson and may
/// ADD a line or OVERRIDE an outdated one. The reply is either NO_CHANGE
/// (doc already covers it in its own words) or the COMPLETE revised doc; only
/// a real content change writes a ContextEdit audit and bumps the doc
/// version. The reviewed TM upsert happens ONLY after the fold succeeds, so a
/// reviewed entry doubles as the "this lesson was folded" marker — when the
/// model is unavailable the edit simply stays pending for the next run.
struct Stage0Learner {
  /// Per-run results of the learn stage.
  struct Outcome {
    var folds = 0        // docs actually changed (each = one audit + one bump)
    var covered = 0      // already in doc / model said NO_CHANGE
    /// Oversized docs rewritten smaller (each = one audit + one bump).
    var compressions = 0
    var failures: [String] = []
  }

  /// Gathers and folds every pending confirmed edit of the project, then
  /// compresses any language doc that has outgrown the prompt cap.
  ///
  /// The compression pass belongs to THIS stage on purpose: it runs after
  /// every fold of the run, so each folded lesson already carries its TM-gold
  /// entry — the marker that survives a doc rewrite.
  static func learn(
    env: PipelineRunContext,
    progress: TranslateRunProgress?,
    trace: TranslationTrace? = nil
  ) async -> Outcome {
    var outcome = Outcome()

    // Collect pending confirmed edits across the project, oldest first.
    var pending: [(edit: TranslationEdit, record: TranslationRecord)] = []
    for record in env.allRecords {
      for edit in record.edits where edit.isUserConfirmed {
        guard record.value == edit.toValue else { continue }  // superseded
        pending.append((edit, record))
      }
    }
    pending.sort { $0.edit.createdAt < $1.edit.createdAt }

    // One upfront configuration gate: without Command Code the whole stage is
    // inert — folding AND the compression pass below — and every edit simply
    // stays pending for a later run.
    if !pending.isEmpty, !Stage0ModelClient.isConfigured {
      outcome.failures.append("Stage 0 learning skipped: Command Code is not configured")
      progress?.fail(key: nil, message: "learning skipped: Command Code is not configured")
      try? env.context.save()
      return outcome
    }

    if !pending.isEmpty {
      progress?.begin(.stage0Learn, total: pending.count)
      for item in pending {
        if progress?.isCancelled == true {
          outcome.failures.append("Stage 0 cancelled by user")
          progress?.note("Stage 0 cancelled")
          break
        }
        let record = item.record
        let failuresBefore = outcome.failures.count
        await fold(item, env: env, outcome: &outcome)
        if outcome.failures.count > failuresBefore {
          progress?.fail(
            key: "\(record.language).\(record.key)",
            message: outcome.failures.last ?? "learning failed"
          )
        } else {
          progress?.tick(key: "\(record.language).\(record.key)")
        }
      }
    }

    // Nothing to fold is not nothing to do: an oversized doc still has to come
    // back under its prompt cap. Compression runs LAST, after every fold, so a
    // lesson whose line the rewrite drops already has its TM-gold entry.
    await compressOversizedDocs(env: env, progress: progress, trace: trace, outcome: &outcome)

    try? env.context.save()
    return outcome
  }

  // MARK: - compression

  /// Rewrites every language doc that has outgrown the prompt cap, so the
  /// STORED doc fits what a prompt can send and the tail-keeping truncation
  /// never has to fire. One model call per doc.
  ///
  /// This replaces the old "the doc is too big — needs human cleanup" park:
  /// nothing is ever parked, a failed or unusable reply leaves the doc exactly
  /// as it was (the truncation path is the safety net), and a rewrite that
  /// canonicalizes to the stored content writes nothing and bumps nothing —
  /// a language-doc bump makes every other record of that language stale, so
  /// an unconditional compression would re-translate that whole column on
  /// every run.
  ///
  /// What survives a dropped line: every folded lesson already has a reviewed
  /// TM entry keyed (sourceText, sourceLanguage, targetLanguage), and TM
  /// resolves exact hits without any prompt — so compressing the doc costs
  /// prompt space, not the lesson. Hand-written lines in a language doc have
  /// no such backstop; the ContextEdit audit holds the before/after for them.
  private static func compressOversizedDocs(
    env: PipelineRunContext,
    progress: TranslateRunProgress?,
    trace: TranslationTrace?,
    outcome: inout Outcome
  ) async {
    let limit = ContextPromptBuilder.maxLanguageCharacters
    let oversized = env.allLanguageDocs().filter { $0.content.count > limit }
    guard !oversized.isEmpty else { return }
    guard Stage0ModelClient.isConfigured else {
      outcome.failures.append(
        "Stage 0 compression skipped: Command Code is not configured "
          + "(\(oversized.count) doc(s) over \(limit) chars)"
      )
      return
    }

    for doc in oversized {
      if progress?.isCancelled == true {
        outcome.failures.append("Stage 0 compression cancelled by user")
        break
      }
      let language = doc.identifier ?? "?"
      let before = doc.content
      let prompt = compressionPrompt(doc: before, language: language, limit: limit)

      let reply: GlossaryFormat.FoldReply
      do {
        let raw = try await Stage0ModelClient.complete(system: prompt.system, user: prompt.user)
        reply = GlossaryFormat.parseFoldReply(raw)
      } catch {
        outcome.failures.append("compress \(language): \(error.localizedDescription)")
        progress?.note("Compression failed for \(language) — doc left as stored")
        continue
      }

      let revised: String
      switch reply {
      case .noChange:
        continue
      case .unusable:
        outcome.failures.append("compress \(language): unusable model reply")
        continue
      case .revised(let text):
        revised = text
      }

      let canonical = GlossaryFormat.canonicalize(
        revised.trimmingCharacters(in: .whitespacesAndNewlines))
      guard !canonical.isEmpty else {
        outcome.failures.append("compress \(language): empty revision")
        continue
      }
      guard canonical != before else { continue }

      doc.content = canonical
      doc.version += 1
      doc.updatedAt = .now
      let audit = ContextEdit(
        contextDoc: doc,
        before: before,
        after: canonical,
        reason: "Stage-0 compression of the language doc (deduped to fit the "
          + "\(limit)-char prompt cap)",
        author: .deepseek
      )
      env.context.insert(audit)
      outcome.compressions += 1
      trace?.add(TranslationTrace.Step(
        kind: .learn,
        title: "Compressed \(language) glossary doc",
        model: RoutedModel.muse.name,
        provider: RoutedModel.muse.provider.displayName,
        isPaid: true,
        input: "\(before.count) chars, target <= \(limit)",
        output: "\(canonical.count) chars",
        before: before,
        after: canonical,
        isFailure: false))
      progress?.note("Compressed \(language): \(before.count) -> \(canonical.count) chars")
    }
  }

  /// The compression instruction: dedupe, merge, keep every term and
  /// convention, fit the cap. The entry format is NOT restated loosely — it is
  /// the same tab-separated contract the fold writes, because the reply is
  /// canonicalized and re-checked against it.
  private static func compressionPrompt(doc: String, language: String, limit: Int) -> FoldPrompt {
    let system = """
    You are the glossary-compression engine of a self-improving software \
    localization pipeline. You maintain ONE plain-text glossary document for the \
    target language "\(language)". You receive the current document and must \
    return it COMPRESSED and DEDUPLICATED.

    Entry format is unchanged — every lesson occupies exactly ONE line, its three \
    fields separated by a real tab character (U+0009), exactly like this line:
    cancel\tCancel\tОтмена
    Separators are REAL tab characters — never the two-character text \\t. A tab, \
    newline or backslash INSIDE a field is escaped as \\t, \\n, \\\\ — reproduce \
    those escapes exactly.

    Rules:
    1. Reply ONLY with the complete rewritten document text — no explanations, no \
    markdown fences, no commentary.
    2. Keep exactly ONE line per (key, source) pair. When two lines contradict \
    each other for the same key and source, keep the LAST one: entries are \
    appended over time, so the last is the newest.
    3. Merge duplicates and redundant wording. Never drop a term, a proper noun, \
    a transliteration rule, or a register convention.
    4. Never invent a lesson that the input does not imply, and never change a \
    value that carries no duplicate.
    5. The result MUST be at most \(limit) characters. Drop the most generic and \
    the oldest lines first; keep the newest and the most specific ones.
    6. If the document cannot be usefully shortened, reply with exactly the \
    single line NO_CHANGE.
    """

    let user = """
    CURRENT \(language.uppercased()) GLOSSARY DOCUMENT — \(doc.count) characters, \
    target at most \(limit)

    \(doc)
    """
    return FoldPrompt(system: system, user: user)
  }

  // MARK: - one fold

  /// Folds ONE record's pending confirmed edit — the row inspector's learning
  /// mode. Unlike `learn`, it never touches other keys, so a diagnostic run
  /// cannot rewrite the rest of the project's context docs.
  ///
  /// Records a single trace step carrying the ContextDoc BEFORE and AFTER, so
  /// the inspector can show exactly what the model learned and where.
  static func learnOne(
    env: PipelineRunContext,
    record: TranslationRecord,
    trace: TranslationTrace?
  ) async -> Outcome {
    var outcome = Outcome()
    let lessonKey = record.category.map { "\(record.key)#\($0)" } ?? record.key
    let language = record.language

    // Same "pending" rule as `learn`: the newest user-confirmed edit whose
    // value is still the record's current value.
    let edit = record.edits
      .filter(\.isUserConfirmed)
      .sorted { $0.createdAt < $1.createdAt }
      .last { record.value == $0.toValue }

    guard let edit else {
      trace?.add(TranslationTrace.Step(
        kind: .learn,
        title: "Nothing to learn for \(language).\(lessonKey)",
        model: nil,
        output: record.state == .reviewed
          ? "The row is reviewed but carries no still-current confirmed edit, so there is no lesson to fold."
          : "The row is not reviewed, so there is no confirmed edit to fold.",
        isFailure: false))
      return outcome
    }

    let before = env.languageDoc(for: language)?.content
    let memoryBefore = TranslationMemory.entry(
      in: env.context,
      sourceText: record.sourceText,
      sourceLanguage: env.sourceLanguage,
      targetLanguage: language)

    await fold((edit, record), env: env, outcome: &outcome)

    let after = env.languageDoc(for: language)?.content
    let docChanged = (before ?? "") != (after ?? "")
    let result = outcome.failures.last
      ?? (docChanged
          ? "ContextDoc rewritten — version bumped, audit written"
          : "No change — the doc already covered this lesson (TM gold refreshed)")

    trace?.add(TranslationTrace.Step(
      kind: .learn,
      title: "Fold \(language).\(lessonKey)",
      model: RoutedModel.muse.name,
      provider: RoutedModel.muse.provider.displayName,
      isPaid: true,
      input: lessonInput(edit: edit, record: record, memory: memoryBefore, lessonKey: lessonKey),
      output: result,
      before: before,
      after: after,
      isFailure: !outcome.failures.isEmpty))
    try? env.context.save()
    return outcome
  }

  /// The lesson handed to the model, in the inspector's words.
  private static func lessonInput(
    edit: TranslationEdit,
    record: TranslationRecord,
    memory: TranslationMemoryEntry?,
    lessonKey: String
  ) -> String {
    var lines = [
      "document: language/\(record.language)",
      "key: \(lessonKey)",
      "source: \(record.sourceText)",
      "approved value: \(edit.toValue)",
    ]
    if let previous = edit.fromValue, !previous.isEmpty {
      lines.append("previous value: \(previous)")
    }
    if let memory {
      lines.append("TM before: \(memory.state.rawValue) — \(memory.value)")
    } else {
      lines.append("TM before: no entry")
    }
    return lines.joined(separator: "\n")
  }

  private static func fold(
    _ item: (edit: TranslationEdit, record: TranslationRecord),
    env: PipelineRunContext,
    outcome: inout Outcome
  ) async {
    let record = item.record
    let value = item.edit.toValue
    let sourceLanguage = env.sourceLanguage
    let targetLanguage = record.language
    // Plural forms learn under a form-tagged key ("key#one") so the TM
    // triple (sourceText, source, target) stays unique per form: "one" and
    // "other" of the same key never collide.
    let lessonKey = record.category.map { "\(record.key)#\($0)" } ?? record.key

    // A reviewed TM entry carrying exactly this value means a previous run
    // already folded this lesson (the reviewed upsert is the fold marker).
    let memoryEntry = TranslationMemory.entry(
      in: env.context,
      sourceText: record.sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let alreadyInMemory = memoryEntry?.state == .reviewed && memoryEntry?.value == value

    // The reviewed TM upsert is the "folded" marker: when it already carries
    // exactly this value, the lesson was folded by a previous run — doc and
    // TM are both up to date, so this is a pure no-op (no TM re-stamp, no
    // LLM call). Keeps repeated runs completely write-free.
    if alreadyInMemory {
      outcome.covered += 1
      return
    }

    let doc = env.languageDoc(for: targetLanguage)
    let docCovered = doc.map {
      GlossaryFormat.isCovered(content: $0.content, key: lessonKey, source: record.sourceText, value: value)
    } ?? false
    if docCovered {
      // The doc already holds the canonical lesson line (e.g. the store was
      // restored without the TM row) — nothing for the model to do, but the
      // gold still belongs in TM.
      outcome.covered += 1
      upsertMemory(env: env, record: record, value: value)
      return
    }

    // No size gate here anymore. An oversized doc is folded into like any
    // other, and the stage's compression pass brings it back under the prompt
    // cap once every fold of this run has landed (see compressOversizedDocs).
    // Parked folds used to mean a lesson could never arrive; the tail-keeping
    // truncation in the prompt builder is now the only failure path, and it
    // costs prompt space rather than the lesson (TM gold still resolves it).

    guard Stage0ModelClient.isConfigured else {
      outcome.failures.append(
        "Stage 0 learning skipped: Command Code is not configured"
      )
      return
    }

    let prompt = foldPrompt(
      doc: doc?.content ?? "",
      language: targetLanguage,
      key: lessonKey,
      comment: env.comment(for: record.key),
      source: record.sourceText,
      value: value,
      previous: item.edit.fromValue
    )

    let reply: GlossaryFormat.FoldReply
    do {
      let raw = try await Stage0ModelClient.complete(system: prompt.system, user: prompt.user)
      reply = GlossaryFormat.parseFoldReply(raw)
    } catch {
      outcome.failures.append("learn \(targetLanguage).\(lessonKey): \(error.localizedDescription)")
      return
    }

    switch reply {
    case .noChange:
      // Doc already covers the lesson in its own words; nothing to write.
      outcome.covered += 1
      upsertMemory(env: env, record: record, value: value)
    case .unusable:
      outcome.failures.append("learn \(targetLanguage).\(lessonKey): unusable model reply")
    case .revised(let revised):
      let trimmed = revised.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        outcome.failures.append("learn \(targetLanguage).\(lessonKey): empty revision")
        return
      }
      guard trimmed != (doc?.content ?? "") else {
        outcome.covered += 1
        upsertMemory(env: env, record: record, value: value)
        return
      }
      let changed = applyRevision(
        env: env,
        doc: doc,
        language: targetLanguage,
        content: trimmed,
        key: lessonKey,
        value: value
      )
      if changed {
        outcome.folds += 1
      } else {
        // The revision canonicalizes to the stored content — covered.
        outcome.covered += 1
      }
      upsertMemory(env: env, record: record, value: value)
    }
  }

  /// Writes the revised doc: creates the language doc on first use (audit
  /// with a nil `before`), otherwise rewrites content + audit + version bump.
  /// The content is canonicalized so lesson lines converge on the real-tab
  /// format regardless of how the model rendered the separators. Returns
  /// false (no write, no bump) when the canonical revision equals the stored
  /// content — the lesson is then treated as covered.
  private static func applyRevision(
    env: PipelineRunContext,
    doc: ContextDoc?,
    language: String,
    content: String,
    key: String,
    value: String
  ) -> Bool {
    let canonical = GlossaryFormat.canonicalize(content)
    guard canonical != doc?.content ?? "" else { return false }
    let audit: ContextEdit
    if let doc {
      let before = doc.content
      doc.content = canonical
      doc.version += 1
      doc.updatedAt = .now
      audit = ContextEdit(
        contextDoc: doc,
        before: before,
        after: canonical,
        reason: "Stage-0 fold of user-confirmed edit (\(key)); value updated with override authority",
        author: .deepseek
      )
    } else {
      let doc = ContextDoc(
        scope: .language,
        identifier: language,
        version: 1,
        content: canonical,
        createdAt: .now,
        updatedAt: .now
      )
      env.context.insert(doc)
      env.remember(doc)
      audit = ContextEdit(
        contextDoc: doc,
        before: nil,
        after: canonical,
        reason: "Stage-0 fold of user-confirmed edit (\(key)); language doc created",
        author: .deepseek
      )
    }
    env.context.insert(audit)
    return true
  }

  /// The reviewed TM upsert that marks a lesson folded. Runs only after the
  /// fold succeeded (or was deterministically already covered / parked).
  private static func upsertMemory(
    env: PipelineRunContext,
    record: TranslationRecord,
    value: String
  ) {
    TranslationMemory.upsertReviewed(
      in: env.context,
      sourceText: record.sourceText,
      sourceLanguage: env.sourceLanguage,
      targetLanguage: record.language,
      value: value,
      contextVersions: env.snapshot(for: record.language),
      projectTag: env.project.name
    )
  }

  // MARK: - prompt

  private struct FoldPrompt {
    var system: String
    var user: String
  }

  private static func foldPrompt(
    doc: String,
    language: String,
    key: String,
    comment: String?,
    source: String,
    value: String,
    previous: String?
  ) -> FoldPrompt {
    let commentSection = comment.map { "\ncomment: \($0)" } ?? ""
    let previousSection = previous.map { "\nreplaced previous value: \($0)" } ?? "\nreplaced previous value: (none — slot was empty)"
    let docSection = doc.isEmpty ? "(document is empty)" : doc

    let system = """
    You are the autonomous glossary-learning engine of a self-improving software \
    localization pipeline. You maintain ONE plain-text glossary document for the \
    target language "\(language)". You receive one lesson: a translation a human \
    just confirmed for one key.

    You have OVERRIDE authority: when the document already holds an entry for the \
    same KEY and SOURCE with an outdated VALUE, REWRITE that entry's value in \
    place — never keep two conflicting entries for the same key+source, never \
    append a duplicate. When the document already covers the lesson (its own \
    wording is fine), make NO change.

    Entry format — every lesson occupies exactly ONE line, its three fields \
    separated by a real tab character (U+0009), exactly like this line:
    cancel\tCancel\tОтмена
    Separators are REAL tab characters — never the two-character text \\t. A \
    tab, newline or backslash INSIDE a field is escaped as the two-character \
    sequences \\t, \\n, \\\\ — reproduce those escapes exactly.

    Rules:
    1. Reply ONLY with the COMPLETE revised document text.
    2. Keep every unrelated existing line byte-for-byte.
    3. Never drop, reword, or reorder lines that do not conflict with the lesson.
    4. If the document already covers the lesson, reply with exactly the single \
    line NO_CHANGE.
    5. No explanations, no markdown fences, no commentary.
    """

    let user = """
    LESSON — user-confirmed translation
    key: \(key)\(commentSection)
    source (\(source)): \(source)
    confirmed value (\(language)): \(value)\(previousSection)

    CURRENT \(language.uppercased()) GLOSSARY DOCUMENT
    \(docSection)
    """
    return FoldPrompt(system: system, user: user)
  }
}
