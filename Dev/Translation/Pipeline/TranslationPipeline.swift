//
//  TranslationPipeline.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - TranslationPipeline

/// The "Translate" run orchestrator. One run, in order:
///
///   0. LEARN   — fold pending user-confirmed TranslationEdits into the
///                language ContextDoc (Command Code, OVERRIDE authority,
///                audit + version bump) and upsert the reviewed TM entry.
///   1. TM      — resolve records that need a target value against exact
///                (sourceText, targetLanguage) TranslationMemory hits:
///                reviewed -> copied as .reviewed (gold), machine-only ->
///                copied as .needs_review hint; both skip the pipeline.
///   2. IMPORTED DB — when a translation DB is imported (Phase D), resolve
///                the still-untouched candidates against it BEFORE the AI
///                backend: exact source-text hits copy shipped human
///                translations as .reviewed + autoReviewed (the UI shows the
///                auto badge until a human confirms); misses fall through.
///   3. TRANSLATE — every remaining record is translated by Command Code
///                (the hosted Muse/deepseek model), the ONLY AI backend.
///
/// There is deliberately NO local draft stage. Apple Translation and Ollama
/// (translategemma) used to pre-fill records, but a draft could only ever
/// *pre-empt* Command Code — never improve on it — because no stage was ever
/// shown the previous stage's value (see `translatePool`: only the source
/// text and context reach a backend). Each pass therefore cost a full
/// on-device sweep of the catalog (Apple and translategemma both run at
/// single-digit strings/sec) while its output was simply overwritten by the
/// next stage, or worse, survived unreviewed via the old 'providers agreed'
/// skip. Apple additionally ignores the ContextDocs by construction, which
/// disqualifies it for glossary-driven localization.
///
/// Incremental: a record is only touched when it is NEW (empty) or STALE
/// (any recorded context-version is older than the current ContextDoc
/// version for its scope), and never when a human owns it (provider ==
/// .manual or state == .reviewed — DB hits land .reviewed, so they too are
/// never re-run). Every machine write stamps provider + context-versions +
/// needs_review; nothing is ever auto-promoted (the imported DB is the one
/// deliberate exception: shipped human translations land reviewed + a local
/// auto marker, and a single human confirm clears the marker).
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

    // Plural reconcile — create missing CLDR form records + file skeletons
    // BEFORE the stages, so Translate creates what the human never varied
    // by hand and every stage then fills/reviews forms like flat slots.
    if progress?.isCancelled != true {
      let forms = env.reconcilePluralForms()
      if forms > 0 {
        progress?.note("Plurals: \(forms) form slot(s) created")
      }
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

    // Imported-DB resolve — shipped human translations (Phase D), BEFORE any
    // AI backend: hits land .reviewed + autoReviewed and never reach the
    // machine stages (their reviewed state already excludes them); misses
    // fall through exactly as today. Inert with no DB imported.
    var db = DBResolveOutcome()
    if progress?.isCancelled != true {
      db = await importedDBResolve(
        env: env,
        excluded: excludedByTM,
        progress: progress
      )
      summary.dbFilled += db.filled
      summary.dbUpgraded += db.upgraded
      summary.failures += db.failures
    }
    if db.ran {
      progress?.note("Imported DB: \(db.filled) filled, \(db.upgraded) upgraded")
    }

    // TRANSLATE — the one AI stage. Every record that still needs a target
    // value goes to Command Code (Muse/deepseek). No local draft stages:
    // they could only pre-empt this model, never improve on it.
    var translated = StageOutcome()
    if progress?.isCancelled != true {
      translated = await runTranslateStage(
        env: env,
        excluded: excludedByTM,
        progress: progress
      )
      summary.translatedFilled += translated.filled
      summary.translatedRewritten += translated.corrected
      summary.failures += translated.failures
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

  /// Log/progress key for a record: "lang.key" flat, "lang.key#form" plural.
  private static func displayKey(_ record: TranslationRecord) -> String {
    if let category = record.category {
      return "\(record.language).\(record.key)#\(category)"
    }
    return "\(record.language).\(record.key)"
  }

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

  /// Source text that is only whitespace cannot be translated — drop it from
  /// the worklist instead of failing per record.
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
        progress?.tick(key: displayKey(record))
      case .resolvedGold:
        outcome.gold += 1
        outcome.excluded.insert(record.persistentModelID)
        progress?.tick(key: displayKey(record))
      case .resolvedHint:
        outcome.hints += 1
        outcome.excluded.insert(record.persistentModelID)
        progress?.tick(key: displayKey(record))
      }
    }
    try? env.context.save()
    return outcome
  }

  // MARK: - imported-DB resolve (Phase D)

  /// Outcome of the imported-translation-DB stage.
  private struct DBResolveOutcome {
    var filled = 0       // empty slot got a shipped translation
    var upgraded = 0     // existing machine value replaced/promoted to auto-reviewed
    var failures: [String] = []
    var ran = false      // a DB was imported and opened (false = stage inert)
  }

  /// Resolves every record that needs a target value against the imported
  /// translation DB (when one is active): exact source-text rows are matched
  /// per record language via ImportedDBLanguage.hit, and a winner is copied
  /// as .reviewed + autoReviewed (shipped human translations are final; only
  /// a human confirm promotes them past the auto marker). Records the TM
  /// stage already resolved this run (`excluded`) are left alone. Misses
  /// tick through untouched — they flow to the AI stages as today.
  /// Sequential on the main actor: each source's rows are fetched ONCE per
  /// run (all languages of one catalog key share the source text) and cached
  /// in `rowsBySource`, so a whole-catalog run costs one index seek per
  /// unique source, not per record.
  private static func importedDBResolve(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    progress: TranslateRunProgress?
  ) async -> DBResolveOutcome {
    var outcome = DBResolveOutcome()
    let db = ImportedTranslationDB.shared
    guard db.isImported else { return outcome }
    do {
      try await db.ensureOpen()
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      outcome.failures.append("Imported DB unavailable: \(message)")
      progress?.note("Imported DB: unavailable (\(message)) — AI stages run instead")
      return outcome
    }
    outcome.ran = true

    let candidates = env.allRecords.filter {
      env.isTarget($0)
        && !excluded.contains($0.persistentModelID)
        && hasUsableSource($0)
        && needsTarget($0, env: env)
    }
    guard !candidates.isEmpty else { return outcome }
    progress?.begin(.dbResolve, total: candidates.count)

    let appRowCounts = db.stats?.apps ?? [:]
    var rowsBySource: [String: [ImportedDBRow]] = [:]
    for record in candidates {
      if progress?.isCancelled == true { break }
      do {
        let source = record.sourceText
        if rowsBySource[source] == nil {
          rowsBySource[source] = try await db.rows(forSource: source)
        }
        let rows = rowsBySource[source] ?? []
        guard let hit = ImportedDBLanguage.hit(
          in: rows,
          forCatalogLanguage: record.language,
          appRowCounts: appRowCounts
        ) else {
          progress?.tick(key: displayKey(record))
          continue
        }
        switch applyDBHit(env: env, record: record, hit: hit) {
        case .filled: outcome.filled += 1
        case .upgraded: outcome.upgraded += 1
        }
        progress?.tick(key: displayKey(record))
      } catch {
        let message = error.localizedDescription
        outcome.failures.append("db \(displayKey(record)): \(message)")
        progress?.fail(key: displayKey(record), message: message)
      }
    }
    try? env.context.save()
    return outcome
  }

  /// What a DB hit did to a candidate record.
  private enum DBHitWrite {
    case filled      // empty slot
    case upgraded    // existing machine value replaced or promoted
  }

  /// Applies an imported-DB hit: value + provider .importedDB + state
  /// .reviewed + autoReviewed, stamped with the run's context snapshot and
  /// audited as a TranslationEdit when the text changed (a same-value hit is
  /// a pure promotion — no edit, mirroring TM gold promotions). reviewedAt
  /// stays nil: NO human confirmed this yet, and the auto flag says so in
  /// the UI. No TM upsert here — DB output must not mint gold; the human
  /// one-click confirm does that (upsertReviewed, TM gold).
  private static func applyDBHit(
    env: PipelineRunContext,
    record: TranslationRecord,
    hit: ImportedDBHit
  ) -> DBHitWrite {
    let versions = env.snapshot(for: record.language)
    let wasEmpty = (record.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let oldValue = record.value
    let changed = oldValue != hit.value
    let appName = hit.app.isEmpty ? "the imported translation DB" : hit.app

    record.value = hit.value
    record.provider = .importedDB
    record.state = .reviewed
    record.autoReviewed = true
    record.reviewedAt = nil
    record.confidence = nil
    record.contextVersions = versions
    record.updatedAt = .now
    record.lastEditor = "\(ProvenanceMarkers.importedDB) — \(appName)"
    if changed {
      appendEdit(
        env: env, record: record, from: oldValue, to: hit.value,
        reason: wasEmpty
          ? "Filled from imported translation DB (\(appName))"
          : "Upgraded machine output from imported translation DB (\(appName))",
        versions: versions)
    }
    return wasEmpty ? .filled : .upgraded
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

  // MARK: - translate (the only AI stage)

  /// The one AI stage. Every record that still needs a target value — empty,
  /// stale against the current ContextDocs, or explicitly forced — is
  /// translated by Command Code (the hosted Muse/deepseek model) with the
  /// full context prompt. There is deliberately no draft stage in front of
  /// it: no stage is ever shown the previous stage's value, so a draft could
  /// only *pre-empt* this model, never improve on it, while costing a full
  /// on-device sweep of the catalog.
  private static func runTranslateStage(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    progress: TranslateRunProgress?
  ) async -> StageOutcome {
    var outcome = StageOutcome()
    // The router owns provider choice: free tiers first, Muse as the paid
    // fallback. Prompt assembly and the write path are unchanged.
    let backend = TranslationRouter.shared
    let work = env.allRecords
      .filter {
        env.isTarget($0)
          && !excluded.contains($0.persistentModelID)
          && hasUsableSource($0)
          && needsTarget($0, env: env)
      }
      .map { (record: $0, context: env.translationContext(for: $0)) }
    guard let probe = work.first else { return outcome }

    // Eligibility is "at least one provider key exists" — not a language
    // pair — so a single probe covers the whole worklist.
    guard await backend.isEligible(from: env.sourceLanguage, to: probe.record.language) else {
      outcome.failures.append("Translate: no model available — configure a provider key")
      return outcome
    }

    progress?.begin(.translate, total: work.count)
    let results = await translatePool(work: work, backend: backend, sourceLanguage: env.sourceLanguage, progress: progress)
    for (index, result) in results.sorted(by: { $0.index < $1.index }) {
      let record = work[index].record
      switch result {
      case .success(let value):
        if record.state == .empty {
          writeFill(
            env: env, record: record, value: value,
            provider: .deepseek, lastEditor: backend.displayName,
            reason: "Translate (Command Code): filled empty slot"
          )
          outcome.filled += 1
        } else if rewriteValue(
          env: env, record: record, value: value,
          provider: .deepseek, lastEditor: backend.displayName,
          reason: "Translate (Command Code): differs from previous machine value"
        ) {
          outcome.corrected += 1
        }
        progress?.tick(key: displayKey(record))
      case .failure(let backendError):
        let message = backendError.localizedDescription
        outcome.failures.append("translate \(displayKey(record)): \(message)")
        progress?.fail(key: displayKey(record), message: message)
      }
    }
    try? env.context.save()
    return outcome
  }
}
