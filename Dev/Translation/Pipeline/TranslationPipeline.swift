//
//  TranslationPipeline.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - Provider mapping

extension Provider {
  /// Backends persist under their own raw names; records persist under the
  /// model's Provider enum. Command Code (BackendID.commandcode) is the
  /// deepseek machine (KANBAN decision, see C-1 notes).
  init(backendID: BackendID) {
    switch backendID {
    case .apple:
      self = .apple
    case .ollama:
      self = .ollama
    case .commandcode:
      self = .deepseek
    }
  }
}

// MARK: - TranslationPipeline

/// The "Translate" run orchestrator. One run, in order:
///
///   0. LEARN   — fold pending user-confirmed TranslationEdits into the
///                language ContextDoc (deepseek, OVERRIDE authority, audit +
///                version bump) and upsert the reviewed TM entry.
///   1. TM      — resolve records that need a target value against exact
///                (sourceText, targetLanguage) TranslationMemory hits:
///                reviewed -> copied as .reviewed (gold), machine-only ->
///                copied as .needs_review hint; both skip the pipeline.
///   2. APPLE   — fill the still-empty records Apple can serve.
///   3. OLLAMA  — fill empty records Apple could not cover, and re-translate
///                Apple output with context (diff -> apple->ollama edit).
///   4. DEEPSEEK — review the survivors: still-empty, Ollama-corrected, or
///                stale/high-stakes machine values. Final suggestions.
///
/// Incremental: a record is only touched when it is NEW (empty) or STALE
/// (any recorded context-version is older than the current ContextDoc
/// version for its scope), and never when a human owns it (provider ==
/// .manual or state == .reviewed). Every machine write stamps provider +
/// context-versions + needs_review; nothing is ever auto-promoted.
///
/// Backend calls run ~3 at a time (off-main, the backends are nonisolated);
/// SwiftData reads/writes stay on the main actor. Progress + cancellation
/// flow through `TranslateRunProgress`.
struct TranslationPipeline {
  /// How many backend calls run concurrently.
  static let poolSize = 3

  /// Convenience entry for the Translate button: runs against the app's ONE
  /// shared SwiftData context (TranslationStore.shared.context).
  static func run(
    project: Project,
    sourceLanguage: String? = nil,
    key: String? = nil,
    languages: Set<String>? = nil,
    force: Bool = false,
    progress: TranslateRunProgress? = nil
  ) async -> PipelineRunSummary {
    await run(
      project: project,
      context: TranslationStore.shared.context,
      sourceLanguage: sourceLanguage,
      key: key,
      languages: languages,
      force: force,
      progress: progress
    )
  }

  /// Runs the pipeline for one project (or, when `key` is set, for exactly
  /// one key of it — and, when `languages` is set, only those target
  /// languages of that key). `sourceLanguage` is only a fallback — the
  /// project's catalog file, when readable, is authoritative.
  static func run(
    project: Project,
    context: ModelContext,
    sourceLanguage: String? = nil,
    key: String? = nil,
    languages: Set<String>? = nil,
    force: Bool = false,
    progress: TranslateRunProgress? = nil
  ) async -> PipelineRunSummary {
    var summary = PipelineRunSummary()
    let runStart = Date.now
    let env = PipelineRunContext(
      context: context,
      project: project,
      sourceLanguage: sourceLanguage,
      targetKey: key,
      targetLanguages: languages,
      force: force
    )
    progress?.note(key == nil
      ? "Translate run: \(project.name) (\(env.allRecords.count) records, source \(env.sourceLanguage))"
      : "Translate \(key!)\(languages.map { " (\($0.count) columns)" } ?? ""): source \(env.sourceLanguage)")

    guard !env.allRecords.isEmpty else {
      progress?.note("No records to translate")
      progress?.begin(.done, total: 0)
      return summary
    }

    // Stage 0 — learn from pending user-confirmed edits first, so the rest
    // of the run sees freshly bumped context versions.
    if progress?.isCancelled != true {
      let learned = await Stage0Learner.learn(env: env, progress: progress)
      summary.learnedFolds += learned.folds
      summary.learnedCovered += learned.covered
      summary.contextBumps += learned.folds
      summary.failures += learned.failures
      progress?.note("Stage 0: \(learned.folds) fold(s), \(learned.covered) already covered")
    }

    // TM resolve — exact hits are copied and skip the machine stages.
    var excludedByTM = Set<PersistentIdentifier>()
    if progress?.isCancelled != true {
      let tm = tmResolve(
        env: env,
        sourceLanguage: env.sourceLanguage,
        progress: progress
      )
      summary.tmResolvedGold += tm.gold
      summary.tmResolvedHints += tm.hints
      summary.failures += tm.failures
      excludedByTM = tm.excluded
      progress?.note("TM: \(tm.gold) gold, \(tm.hints) hints")
    }

    // Stage 1 — Apple fills empty records.
    var apple = StageOutcome()
    if progress?.isCancelled != true {
      apple = await runAppleStage(
        env: env,
        excluded: excludedByTM,
        runStart: runStart,
        progress: progress
      )
      summary.stage1Filled += apple.filled
      summary.failures += apple.failures
    }

    // Stage 2 — Ollama: remaining empties + Apple output, with context.
    var ollama = StageOutcome()
    if progress?.isCancelled != true {
      ollama = await runOllamaStage(
        env: env,
        excluded: excludedByTM,
        runStart: runStart,
        progress: progress
      )
      summary.stage2Filled += ollama.filled
      summary.stage2Corrected += ollama.corrected
      summary.failures += ollama.failures
    }

    // Stage 3 — deepseek (Command Code) reviews the survivors.
    var deepseek = StageOutcome()
    if progress?.isCancelled != true {
      deepseek = await runDeepseekStage(
        env: env,
        excluded: excludedByTM,
        runStart: runStart,
        progress: progress
      )
      summary.stage3Filled += deepseek.filled
      summary.stage3Reviewed += deepseek.corrected
      summary.failures += deepseek.failures
    }

    summary.cancelled = progress?.isCancelled == true
    try? context.save()
    progress?.note(
      "Finished: \(summary.recordsTouched) records touched, "
        + "\(summary.failures.count) failure(s)"
    )
    progress?.begin(.done, total: 0)
    return summary
  }

  // MARK: - record selection

  /// True when a machine stage may re-examine a record: it is not
  /// human-owned (no .manual provider, not .reviewed) and it is either NEW
  /// (empty, needs any value) or STALE (context moved on since its value was
  /// written). On a forced run (row "Translate") a fresh machine value is
  /// treated as a target too. TM-resolved records of this run are excluded
  /// by the caller.
  private static func needsTarget(
    _ record: TranslationRecord,
    env: PipelineRunContext
  ) -> Bool {
    guard record.state != .reviewed, record.provider != .manual else {
      return false
    }
    if record.state == .empty {
      return true
    }
    return env.force || env.isStale(record)
  }

  /// True when the run itself wrote this record (updatedAt after run start).
  private static func justWritten(_ record: TranslationRecord, runStart: Date) -> Bool {
    record.updatedAt >= runStart
  }

  /// High-stakes strings get a final deepseek pass even when a cheaper stage
  /// already produced a value: format placeholders (%@, %lld, {name}) or
  /// very long text. Confidence-based selection is the extension point here —
  /// backends do not report confidence today, so the stakes heuristic stands
  /// in for "low confidence".
  private static func isHighStakes(_ text: String) -> Bool {
    if text.count >= 120 {
      return true
    }
    return text.range(of: "%[a-zA-Z@]|\\{[^}]*\\}", options: .regularExpression) != nil
  }

  /// Source text that is only whitespace cannot be translated — drop it from
  /// every stage's worklist instead of failing per record.
  private static func hasUsableSource(_ record: TranslationRecord) -> Bool {
    !record.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - TM resolve

  private struct TMResolveOutcome {
    var gold = 0
    var hints = 0
    var failures: [String] = []
    var excluded = Set<PersistentIdentifier>()
  }

  /// Resolves every record that needs a target value against exact TM hits.
  /// A hit (reviewed OR machine hint) is copied verbatim and the record is
  /// excluded from this run's machine stages — "skip pipeline".
  private static func tmResolve(
    env: PipelineRunContext,
    sourceLanguage: String,
    progress: TranslateRunProgress?
  ) -> TMResolveOutcome {
    var outcome = TMResolveOutcome()
    let candidates = env.allRecords.filter { env.isTarget($0) && needsTarget($0, env: env) }
    guard !candidates.isEmpty else { return outcome }
    progress?.begin(.tmResolve, total: candidates.count)

    for record in candidates {
      if progress?.isCancelled == true {
        outcome.failures.append("TM resolve cancelled")
        progress?.note("TM resolve cancelled")
        break
      }
      let resolved = TranslationMemory.resolve(
        in: env.context,
        env: env,
        record: record,
        sourceLanguage: sourceLanguage
      )
      switch resolved {
      case .none:
        progress?.tick(key: "\(record.language).\(record.key)")
      case .resolvedGold:
        outcome.gold += 1
        outcome.excluded.insert(record.persistentModelID)
        progress?.tick(key: "\(record.language).\(record.key)")
      case .resolvedHint:
        outcome.hints += 1
        outcome.excluded.insert(record.persistentModelID)
        progress?.tick(key: "\(record.language).\(record.key)")
      }
    }
    try? env.context.save()
    return outcome
  }

  // MARK: - stage plumbing

  /// One machine stage's result.
  private struct StageOutcome {
    var filled = 0       // empty record got a value
    var corrected = 0    // existing machine value was rewritten (diff)
    var failures: [String] = []
  }

  /// Runs one backend call per work item, ~`poolSize` at a time. Returns the
  /// results keyed by the item's index in `work`. Pure transport: SwiftData
  /// is not touched here, so the group runs off the main actor.
  private static func translatePool(
    work: [(record: TranslationRecord, context: TranslationContext)],
    backend: any TranslatorBackend,
    sourceLanguage: String,
    progress: TranslateRunProgress?
  ) async -> [(index: Int, result: Result<String, BackendError>)] {
    var collected: [(index: Int, result: Result<String, BackendError>)] = []
    var start = 0
    while start < work.count {
      if progress?.isCancelled == true { break }
      let end = min(start + poolSize, work.count)
      let slice = work[start..<end]

      let chunk = await withTaskGroup(of: (Int, Result<String, BackendError>).self) { group in
        for (offset, item) in slice.enumerated() {
          group.addTask {
            let index = start + offset
            let text = item.record.sourceText
            let language = item.record.language
            do {
              let value = try await backend.translate(
                text,
                from: sourceLanguage,
                to: language,
                context: item.context
              )
              return (index, .success(value))
            } catch let error as BackendError {
              return (index, .failure(error))
            } catch {
              // A backend escaping its error taxonomy still must not crash
              // the pool; wrap and keep going.
              return (index, .failure(.network(error.localizedDescription)))
            }
          }
        }
        var results: [(Int, Result<String, BackendError>)] = []
        for await result in group {
          results.append(result)
        }
        return results
      }
      collected += chunk
      start = end
    }
    return collected
  }

  /// Applies a machine fill to an EMPTY record: value + provider +
  /// needs_review + context-versions snapshot, an audit TranslationEdit, and
  /// the machine TM hint. Never auto-promotes.
  private static func writeFill(
    env: PipelineRunContext,
    record: TranslationRecord,
    value: String,
    provider: Provider,
    lastEditor: String,
    reason: String
  ) {
    guard record.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
      return
    }
    let versions = env.snapshot(for: record.language)
    record.value = value
    record.provider = provider
    record.state = .needs_review
    record.confidence = nil
    record.contextVersions = versions
    record.updatedAt = .now
    record.lastEditor = lastEditor
    record.reviewedAt = nil
    appendEdit(env: env, record: record, from: nil, to: value, reason: reason, versions: versions)
    TranslationMemory.upsertMachineHint(
      in: env.context,
      sourceText: record.sourceText,
      sourceLanguage: env.sourceLanguage,
      targetLanguage: record.language,
      value: value,
      provider: provider,
      contextVersions: versions,
      projectTag: env.project.name
    )
  }

  /// Rewrites an existing machine value with a newer stage's suggestion.
  /// Returns true when the value actually changed (an edit is logged); when
  /// the newer stage agrees with the current value the record's provenance
  /// is refreshed to the current context versions so it stops being stale —
  /// no edit is logged because nothing changed.
  private static func rewriteValue(
    env: PipelineRunContext,
    record: TranslationRecord,
    value: String,
    provider: Provider,
    lastEditor: String,
    reason: String
  ) -> Bool {
    let versions = env.snapshot(for: record.language)
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let current = record.value ?? ""
    guard trimmed != current else {
      // Same suggestion against new context: re-verify the provenance so the
      // record is not re-sent on every run.
      record.contextVersions = versions
      record.updatedAt = .now
      return false
    }
    let old = record.value
    record.value = trimmed
    record.provider = provider
    record.state = .needs_review
    record.confidence = nil
    record.contextVersions = versions
    record.updatedAt = .now
    record.lastEditor = lastEditor
    record.reviewedAt = nil
    appendEdit(env: env, record: record, from: old, to: trimmed, reason: reason, versions: versions)
    TranslationMemory.upsertMachineHint(
      in: env.context,
      sourceText: record.sourceText,
      sourceLanguage: env.sourceLanguage,
      targetLanguage: record.language,
      value: trimmed,
      provider: provider,
      contextVersions: versions,
      projectTag: env.project.name
    )
    return true
  }

  private static func appendEdit(
    env: PipelineRunContext,
    record: TranslationRecord,
    from: String?,
    to: String,
    reason: String,
    versions: ContextVersions
  ) {
    let edit = TranslationEdit(
      record: record,
      fromValue: from,
      toValue: to,
      editor: .provider,
      reason: reason,
      contextVersions: versions,
      isUserConfirmed: false
    )
    record.edits.append(edit)
    env.context.insert(edit)
  }

  // MARK: - stage 1: Apple

  private static func runAppleStage(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    runStart: Date,
    progress: TranslateRunProgress?
  ) async -> StageOutcome {
    var outcome = StageOutcome()
    let backend = AppleTranslator()
    let candidates = env.allRecords.filter {
      env.isTarget($0)
        && !excluded.contains($0.persistentModelID)
        && $0.state == .empty
        && hasUsableSource($0)
    }
    guard !candidates.isEmpty else { return outcome }

    // Eligibility is per language pair and cheap-ish (Apple's availability
    // status); probe each pair once, serially, before the pool runs.
    var eligible = Set<String>()
    for language in Set(candidates.map { $0.language }) {
      if await backend.isEligible(from: env.sourceLanguage, to: language) {
        eligible.insert(language)
      }
    }
    let work = candidates
      .filter { eligible.contains($0.language) }
      .map { (record: $0, context: env.translationContext(for: $0)) }
    guard !work.isEmpty else {
      if candidates.contains(where: { !eligible.contains($0.language) }) {
        outcome.failures.append("Stage 1 (Apple): no eligible language pair on this Mac")
      }
      return outcome
    }

    progress?.begin(.stage1Apple, total: work.count)
    let results = await translatePool(work: work, backend: backend, sourceLanguage: env.sourceLanguage, progress: progress)
    for (index, result) in results.sorted(by: { $0.index < $1.index }) {
      let item = work[index]
      switch result {
      case .success(let value):
        writeFill(
          env: env, record: item.record, value: value,
          provider: .apple, lastEditor: backend.displayName,
          reason: "Stage 1 (Apple Translation): initial fill"
        )
        outcome.filled += 1
        progress?.tick(key: "\(item.record.language).\(item.record.key)")
      case .failure(let backendError):
        let message = backendError.localizedDescription
        outcome.failures.append("apple \(item.record.language).\(item.record.key): \(message)")
        progress?.fail(key: "\(item.record.language).\(item.record.key)", message: message)
      }
    }
    try? env.context.save()
    return outcome
  }

  // MARK: - stage 2: Ollama

  private static func runOllamaStage(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    runStart: Date,
    progress: TranslateRunProgress?
  ) async -> StageOutcome {
    var outcome = StageOutcome()
    let backend = OllamaTranslator()
    let candidateRecords = env.allRecords.filter {
      env.isTarget($0)
        && !excluded.contains($0.persistentModelID)
        && hasUsableSource($0)
        && (($0.state == .empty)  // (a) Apple could not cover these
            || ($0.state == .needs_review
                && (env.force  // forced single-item: re-translate machine output
                    || ($0.provider == .apple  // (b) Apple output, fresh or stale
                        && (justWritten($0, runStart: runStart) || env.isStale($0))))))
    }
    guard !candidateRecords.isEmpty else { return outcome }

    var eligible = Set<String>()
    for language in Set(candidateRecords.map { $0.language }) {
      if await backend.isEligible(from: env.sourceLanguage, to: language) {
        eligible.insert(language)
      }
    }
    let work = candidateRecords
      .filter { eligible.contains($0.language) }
      .map { (record: $0, context: env.translationContext(for: $0)) }
    guard !work.isEmpty else {
      outcome.failures.append("Stage 2 (Ollama): server not reachable — skipping")
      return outcome
    }

    progress?.begin(.stage2Ollama, total: work.count)
    let results = await translatePool(work: work, backend: backend, sourceLanguage: env.sourceLanguage, progress: progress)
    for (index, result) in results.sorted(by: { $0.index < $1.index }) {
      let record = work[index].record
      switch result {
      case .success(let value):
        if record.state == .empty {
          writeFill(
            env: env, record: record, value: value,
            provider: .ollama, lastEditor: backend.displayName,
            reason: "Stage 2 (Ollama): filled empty slot with context"
          )
          outcome.filled += 1
        } else if rewriteValue(
          env: env, record: record, value: value,
          provider: .ollama, lastEditor: backend.displayName,
          reason: "Stage 2 (Ollama): context re-translation differs from Apple output"
        ) {
          outcome.corrected += 1
        }
        progress?.tick(key: "\(record.language).\(record.key)")
      case .failure(let backendError):
        let message = backendError.localizedDescription
        outcome.failures.append("ollama \(record.language).\(record.key): \(message)")
        progress?.fail(key: "\(record.language).\(record.key)", message: message)
      }
    }
    try? env.context.save()
    return outcome
  }

  // MARK: - stage 3: deepseek review

  private static func runDeepseekStage(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    runStart: Date,
    progress: TranslateRunProgress?
  ) async -> StageOutcome {
    var outcome = StageOutcome()
    let backend = CommandCodeTranslator()
    let candidateRecords = env.allRecords.filter {
      guard env.isTarget($0),
            !excluded.contains($0.persistentModelID),
            hasUsableSource($0),
            $0.state != .reviewed,
            $0.provider != .manual else {
        return false
      }
      if $0.state == .empty {
        return true  // survivors nobody filled
      }
      // Forced single-item: the target row's machine output always gets a
      // final review pass, even when fresh.
      if env.force, $0.state == .needs_review {
        return true
      }
      // Survivors with a value: Ollama output that is fresh or stale, and
      // Apple output that is fresh or stale AND high-stakes (placeholders /
      // long text get a final deepseek check even when Ollama agreed).
      if $0.provider == .ollama, $0.state == .needs_review {
        return justWritten($0, runStart: runStart) || env.isStale($0)
      }
      if $0.provider == .apple, $0.state == .needs_review,
         justWritten($0, runStart: runStart) || env.isStale($0) {
        return isHighStakes($0.sourceText)
      }
      return false
    }
    guard !candidateRecords.isEmpty else { return outcome }

    var eligible = Set<String>()
    for language in Set(candidateRecords.map { $0.language }) {
      if await backend.isEligible(from: env.sourceLanguage, to: language) {
        eligible.insert(language)
      }
    }
    let work = candidateRecords
      .filter { eligible.contains($0.language) }
      .map { (record: $0, context: env.translationContext(for: $0)) }
    guard !work.isEmpty else {
      outcome.failures.append("Stage 3 (Command Code): not configured — final review skipped")
      return outcome
    }

    progress?.begin(.stage3Deepseek, total: work.count)
    let results = await translatePool(work: work, backend: backend, sourceLanguage: env.sourceLanguage, progress: progress)
    for (index, result) in results.sorted(by: { $0.index < $1.index }) {
      let record = work[index].record
      switch result {
      case .success(let value):
        if record.state == .empty {
          writeFill(
            env: env, record: record, value: value,
            provider: .deepseek, lastEditor: backend.displayName,
            reason: "Stage 3 (Command Code): final suggestion for unfilled slot"
          )
          outcome.filled += 1
        } else if rewriteValue(
          env: env, record: record, value: value,
          provider: .deepseek, lastEditor: backend.displayName,
          reason: "Stage 3 (Command Code): reviewed suggestion differs from current value"
        ) {
          outcome.corrected += 1
        }
        progress?.tick(key: "\(record.language).\(record.key)")
      case .failure(let backendError):
        let message = backendError.localizedDescription
        outcome.failures.append("deepseek \(record.language).\(record.key): \(message)")
        progress?.fail(key: "\(record.language).\(record.key)", message: message)
      }
    }
    try? env.context.save()
    return outcome
  }
}
