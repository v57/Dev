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
///   3. TRANSLATE — every remaining record is translated in per-language
///                batches by the model router (free tiers first, Muse last),
///                validated, repaired singly, then passed through the paid
///                verification gate.
///
/// There is deliberately NO local draft stage. Apple Translation and Ollama
/// (translategemma) used to pre-fill records, but a draft could only ever
/// *pre-empt* Command Code — never improve on it — because no stage was ever
/// shown the previous stage's value (only source text and context ever reach
/// a backend). Each pass therefore cost a full
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
///
/// A run NEVER writes the .xcstrings artifact — `Save` is the only writer.
/// It takes the caller's open in-memory catalog as its prompt/comment
/// source (`catalog:`; nil = read the file), and the caller merges the run's
/// DB output back into its own catalog when the run returns.
struct TranslationPipeline {
  /// Convenience entry for the Translate button: runs against the app's ONE
  /// shared SwiftData context (TranslationStore.shared.context).
  static func run(
    project: Project,
    sourceLanguage: String? = nil,
    key: String? = nil,
    languages: Set<String>? = nil,
    force: Bool = false,
    catalog: StringCatalog? = nil,
    progress: TranslateRunProgress? = nil,
    trace: TranslationTrace? = nil,
    sourceBudget: Int = TranslationRouter.translateSourceBudget,
    skipImportedDB: Bool = false,
    skipStage0: Bool = false,
    updatePass: Bool = false
  ) async -> PipelineRunSummary {
    await run(
      project: project,
      context: TranslationStore.shared.context,
      sourceLanguage: sourceLanguage,
      key: key,
      languages: languages,
      force: force,
      catalog: catalog,
      progress: progress,
      trace: trace,
      sourceBudget: sourceBudget,
      skipImportedDB: skipImportedDB,
      skipStage0: skipStage0,
      updatePass: updatePass
    )
  }

  /// Runs the pipeline for one project (or, when `key` is set, for exactly
  /// one key of it — and, when `languages` is set, only those target
  /// languages of that key). `sourceLanguage` is only a fallback — the
  /// catalog is authoritative: `catalog` when the caller hands one over
  /// (the UI's open catalog, unsaved edits included), else `project.catalogURL`.
  ///
  /// The Update Translations pass reuses this entry point with
  /// `updatePass: true` (selection narrowed to records predating the project
  /// context doc, one request per row) plus `skipImportedDB` / `skipStage0`:
  /// the pass applies a project rule, so it keeps TM resolve but never spends
  /// the imported-DB stage or re-learns from edits (Stage 0).
  static func run(
    project: Project,
    context: ModelContext,
    sourceLanguage: String? = nil,
    key: String? = nil,
    languages: Set<String>? = nil,
    force: Bool = false,
    catalog: StringCatalog? = nil,
    progress: TranslateRunProgress? = nil,
    trace: TranslationTrace? = nil,
    sourceBudget: Int = TranslationRouter.translateSourceBudget,
    skipImportedDB: Bool = false,
    skipStage0: Bool = false,
    updatePass: Bool = false
  ) async -> PipelineRunSummary {
    var summary = PipelineRunSummary()
    let env = PipelineRunContext(
      context: context,
      project: project,
      sourceLanguage: sourceLanguage,
      targetKey: key,
      targetLanguages: languages,
      force: force,
      updatePass: updatePass,
      catalog: catalog
    )
    progress?.note(updatePass
      ? "Update Translations run: \(project.name) (\(env.allRecords.count) records, source \(env.sourceLanguage))"
      : key == nil
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
    // of the run sees freshly bumped context versions. Skipped by the Update
    // Translations pass (`skipStage0`): that pass re-applies a project rule,
    // it does not re-learn.
    if !skipStage0, progress?.isCancelled != true {
      let learned = await Stage0Learner.learn(env: env, progress: progress, trace: trace)
      summary.learnedFolds += learned.folds
      summary.learnedCovered += learned.covered
      // A compression rewrites a doc + audit + bump exactly like a fold, so it
      // counts as a context bump too.
      summary.contextBumps += learned.folds + learned.compressions
      summary.failures += learned.failures
      progress?.note(
        "Stage 0: \(learned.folds) fold(s), \(learned.covered) already covered"
          + (learned.compressions > 0 ? ", \(learned.compressions) doc(s) compressed" : ""))
    }

    // TM resolve — exact hits are copied and skip the machine stages.
    var excludedByTM = Set<PersistentIdentifier>()
    if progress?.isCancelled != true {
      let tm = tmResolve(
        env: env,
        sourceLanguage: env.sourceLanguage,
        progress: progress,
        trace: trace
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
    // fall through exactly as today. Inert with no DB imported. Skipped by
    // the Update Translations pass (`skipImportedDB`): a project-rule sweep
    // must not silently promote shipped-DB values over the rule.
    var db = DBResolveOutcome()
    if !skipImportedDB, progress?.isCancelled != true {
      db = await importedDBResolve(
        env: env,
        excluded: excludedByTM,
        progress: progress,
        trace: trace
      )
      summary.dbFilled += db.filled
      summary.dbUpgraded += db.upgraded
      summary.failures += db.failures
    }
    if db.ran {
      progress?.note("Imported DB: \(db.filled) filled, \(db.upgraded) upgraded")
    }

    // TRANSLATE — the one AI stage: batch, validate, repair, paid gate.
    var translated = StageOutcome()
    if progress?.isCancelled != true {
      translated = await runTranslateStage(
        env: env,
        excluded: excludedByTM,
        progress: progress,
        trace: trace,
        sourceBudget: sourceBudget
      )
      summary.translatedFilled += translated.filled
      summary.translatedRewritten += translated.corrected
      summary.translatedGateFixes += translated.gateFixes
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
    progress: TranslateRunProgress?,
    trace: TranslationTrace? = nil
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
        trace?.add(TranslationTrace.Step(
          kind: .memory,
          title: "TM gold hit — \(displayKey(record))",
          input: "reviewed (sourceText, \(record.language)) entry",
          output: "copied as reviewed; excluded from the AI stage"))
        progress?.tick(key: displayKey(record))
      case .resolvedHint:
        outcome.hints += 1
        outcome.excluded.insert(record.persistentModelID)
        trace?.add(TranslationTrace.Step(
          kind: .memory,
          title: "TM machine hint — \(displayKey(record))",
          input: "machine-only (sourceText, \(record.language)) entry",
          output: "copied as needs_review; excluded from the AI stage"))
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
    progress: TranslateRunProgress?,
    trace: TranslationTrace? = nil
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
        trace?.add(TranslationTrace.Step(
          kind: .memory,
          title: "Imported DB hit — \(displayKey(record))",
          input: "shipped human translation from \(hit.app.isEmpty ? "the DB" : hit.app)",
          output: "written as reviewed + auto-reviewed"))
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
    /// Values the paid verification gate rewrote.
    var gateFixes = 0
    var failures: [String] = []
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
    record.edits = (record.edits ?? []) + [edit]
    env.context.insert(edit)
  }

  // MARK: - translate (the only AI stage)

  /// The one AI stage. Records that still need a target value — empty, stale
  /// against the current ContextDocs, or explicitly forced — go out in
  /// batches, then:
  ///
  ///   1. deterministic checks reject broken placeholders, empty replies and
  ///      untranslated echoes (`TranslationValidator`),
  ///   2. rejected items are re-run ONE at a time through the router,
  ///   3. the survivors go to the paid verification gate, whose corrections
  ///      are themselves validated before being trusted.
  ///
  /// Batching is not only throughput: one request carries the L0/L1 context
  /// blocks once instead of once per record, and for a short UI string those
  /// blocks ARE the bulk of the input cost.
  ///
  /// Two batch shapes share the whole pipeline below:
  ///  - NORMAL runs group by target language (`runLanguageBatches`) — the
  ///    worklist is language-major, so one request carries one language's L1
  ///    block.
  ///  - the UPDATE TRANSLATIONS pass groups by ROW (`runRowBatches`) — one
  ///    request per key carrying every target language of it, so a project
  ///    rule reaches all of a row's languages together.
  private static func runTranslateStage(
    env: PipelineRunContext,
    excluded: Set<PersistentIdentifier>,
    progress: TranslateRunProgress?,
    trace: TranslationTrace? = nil,
    sourceBudget: Int
  ) async -> StageOutcome {
    var outcome = StageOutcome()
    let router = TranslationRouter.shared
    // Attach the diagnostic sink for the duration of this stage only.
    router.trace = trace
    defer { router.trace = nil }
    // `allRecords` is sorted (language, key, category), so this worklist is
    // already language-major and a language batch never straddles two
    // languages. `isTarget` already narrows the update pass to records that
    // predate the project context doc.
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
    // pair — so a single probe covers the whole run.
    guard await router.isEligible(from: env.sourceLanguage, to: probe.record.language) else {
      outcome.failures.append("Translate: no model available — configure a provider key")
      return outcome
    }

    progress?.begin(.translate, total: work.count)
    if env.updatePass {
      await runRowBatches(
        work, env: env, router: router, progress: progress,
        outcome: &outcome, trace: trace, sourceBudget: sourceBudget)
    } else {
      await runLanguageBatches(
        work, env: env, router: router, progress: progress,
        outcome: &outcome, trace: trace, sourceBudget: sourceBudget)
    }
    return outcome
  }

  /// The normal path: the worklist is language-major (`allRecords` is sorted
  /// (language, key, category)), so a batch never straddles two languages and
  /// one request carries one language's L1 block.
  private static func runLanguageBatches(
    _ work: [(record: TranslationRecord, context: TranslationContext)],
    env: PipelineRunContext,
    router: TranslationRouter,
    progress: TranslateRunProgress?,
    outcome: inout StageOutcome,
    trace: TranslationTrace?,
    sourceBudget: Int
  ) async {
    var index = 0
    while index < work.count {
      if progress?.isCancelled == true { break }
      let language = work[index].record.language
      var slice: [(record: TranslationRecord, context: TranslationContext)] = []
      var spent = 0
      // Sized by payload, not by record count: the worklist is language-major
      // (sorted by (language, key, category)) so a batch never straddles two
      // languages, and its cost is what the request actually carries.
      while index < work.count, work[index].record.language == language {
        let cost = ContextPromptBuilder.batchCost(
          sourceText: work[index].record.sourceText,
          context: work[index].context)
        // A batch always takes at least one item, even when that item alone
        // exceeds the whole budget: a long record must still be sent, never
        // silently skipped.
        if !slice.isEmpty, spent + cost > sourceBudget { break }
        slice.append(work[index])
        spent += cost
        index += 1
      }
      await translateBatch(
        slice, language: language, env: env, router: router,
        progress: progress, outcome: &outcome, trace: trace)
      // Checkpoint per batch: a crash mid-run loses at most one batch.
      try? env.context.save()
    }
  }

  /// The Update Translations path: ONE request per ROW (key) carrying every
  /// target language of that row, so a project rule reaches all of a row's
  /// languages together. A row whose payload exceeds `sourceBudget` is split
  /// into consecutive requests; like the language path a slice always takes at
  /// least one item, so an oversized row is sent rather than skipped.
  private static func runRowBatches(
    _ work: [(record: TranslationRecord, context: TranslationContext)],
    env: PipelineRunContext,
    router: TranslationRouter,
    progress: TranslateRunProgress?,
    outcome: inout StageOutcome,
    trace: TranslationTrace?,
    sourceBudget: Int
  ) async {
    // Group by key. `work` follows `allRecords` (language, key, category), so
    // a row's items arrive ordered by (language, category); iterating the keys
    // sorted keeps the request order deterministic from run to run.
    var rows: [String: [(record: TranslationRecord, context: TranslationContext)]] = [:]
    for item in work {
      rows[item.record.key, default: []].append(item)
    }
    for key in rows.keys.sorted() {
      guard let row = rows[key] else { continue }
      var index = 0
      while index < row.count {
        if progress?.isCancelled == true { return }
        var slice: [(record: TranslationRecord, context: TranslationContext)] = []
        var spent = 0
        while index < row.count {
          let cost = ContextPromptBuilder.batchCost(
            sourceText: row[index].record.sourceText,
            context: row[index].context)
          if !slice.isEmpty, spent + cost > sourceBudget { break }
          slice.append(row[index])
          spent += cost
          index += 1
        }
        await translateBatch(
          slice, language: nil, env: env, router: router,
          progress: progress, outcome: &outcome, trace: trace)
        // Checkpoint per request: a crash mid-row loses at most one request.
        try? env.context.save()
      }
    }
  }

  /// One batch request: route, validate, repair, gate, write. `language`
  /// non-nil is the normal language-uniform batch (its item JSON omits a
  /// per-item language); nil is the Update Translations row batch, where each
  /// item names its own target language. Truncation, single-item repair and the
  /// paid gate are shared by both.
  private static func translateBatch(
    _ slice: [(record: TranslationRecord, context: TranslationContext)],
    language: String?,
    env: PipelineRunContext,
    router: TranslationRouter,
    progress: TranslateRunProgress?,
    outcome: inout StageOutcome,
    trace: TranslationTrace? = nil
  ) async {
    guard !slice.isEmpty else { return }
    let items = slice.enumerated().map { offset, item in
      ContextPromptBuilder.BatchItem(
        id: offset,
        sourceText: item.record.sourceText,
        context: item.context,
        // Only the mixed-language row batch names a language per item; the
        // uniform batch leaves it nil so its item JSON (and cache contract) is
        // byte-identical to before.
        targetLanguage: language == nil ? item.record.language : nil)
    }

    // 1. Batched translation — free tiers first, paid destination last.
    let batch: BatchOutcome
    if let language {
      batch = await router.translateBatch(items, from: env.sourceLanguage, to: language)
    } else {
      batch = await router.translateRowBatch(items, from: env.sourceLanguage)
    }
    var resolved: [Int: (value: String, editor: String)] = [:]
    for (id, value) in batch.values {
      resolved[id] = (value, batch.model)
    }

    // 1b. A reply the model CUT OFF is not a set of bad translations: the ids
    // it never reached were lost to the cut, while everything salvaged is real
    // output. So gate and write what arrived, then re-ask the remainder in
    // halves — cheaper and more faithful than one repair call per lost id, and
    // it keeps them off the paid single-item path. Recursion terminates: every
    // level halves the count, and a single item is never split (it falls
    // through to the repair path below).
    if batch.truncated, slice.count > 1 {
      await finishBatch(
        resolved, slice: slice, env: env, router: router,
        progress: progress, outcome: &outcome, trace: trace,
        markMissingAsFailed: false)
      let rest = slice.enumerated().filter { resolved[$0.offset] == nil }.map(\.element)
      guard !rest.isEmpty else { return }
      let cut = max(1, rest.count / 2)
      progress?.note("Reply truncated — re-asking \(rest.count) item(s) in smaller batches")
      await translateBatch(
        Array(rest[0..<cut]), language: language, env: env, router: router,
        progress: progress, outcome: &outcome, trace: trace)
      if cut < rest.count {
        await translateBatch(
          Array(rest[cut...]), language: language, env: env, router: router,
          progress: progress, outcome: &outcome, trace: trace)
      }
      return
    }

    // 2. Single-item repair for whatever the batch could not deliver. A
    // single item always knows its own language, so the row batch needs no
    // special case here.
    for id in batch.failedIDs where slice.indices.contains(id) {
      if progress?.isCancelled == true { break }
      let item = slice[id]
      let to = language ?? item.record.language
      do {
        let value = try await router.translate(
          item.record.sourceText, from: env.sourceLanguage, to: to, context: item.context)
        let issues = TranslationValidator.validate(source: item.record.sourceText, target: value)
        if issues.isEmpty {
          resolved[id] = (value, router.currentModel)
        } else {
          outcome.failures.append(
            "\(displayKey(item.record)): " + issues.map(\.description).joined(separator: "; "))
        }
      } catch {
        outcome.failures.append("\(displayKey(item.record)): \(error.localizedDescription)")
        progress?.fail(key: displayKey(item.record), message: error.localizedDescription)
      }
    }

    // The gate, the write and the "still unresolved" report, shared with the
    // truncation path above (which flushes salvaged values through the same
    // code without calling the cut ids failures).
    await finishBatch(
      resolved, slice: slice, env: env, router: router,
      progress: progress, outcome: &outcome, trace: trace)
  }

  /// The width guideline to hand the reviewer: the row's limit ONLY when the
  /// candidate actually exceeds it. A limit on a value that already fits is
  /// noise, and the reviewer must not be invited to rewrite what fits.
  private static func reviewerWidth(_ limit: Int?, _ candidate: String) -> Int? {
    guard let limit else { return nil }
    return candidate.count > limit ? limit : nil
  }

  /// Gates and writes a batch's accepted values, then reports whatever is
  /// still unresolved for this batch.
  private static func finishBatch(
    _ accepted: [Int: (value: String, editor: String)],
    slice: [(record: TranslationRecord, context: TranslationContext)],
    env: PipelineRunContext,
    router: TranslationRouter,
    progress: TranslateRunProgress?,
    outcome: inout StageOutcome,
    trace: TranslationTrace?,
    markMissingAsFailed: Bool = true
  ) async {
    var resolved = accepted

    // 3. Paid verification gate over everything about to be written.
    if !resolved.isEmpty {
      var gateItems: [GateItem] = []
      for id in resolved.keys.sorted() {
        guard let entry = resolved[id] else { continue }
        gateItems.append(GateItem(
          id: id,
          sourceText: slice[id].record.sourceText,
          comment: slice[id].context.comment,
          candidate: entry.value,
          maxWidth: Self.reviewerWidth(slice[id].record.maxWidth, entry.value)))
      }
      let fixes = await router.verifyBatch(gateItems)
      for (id, fix) in fixes where slice.indices.contains(id) {
        // A correction is trusted only if it passes the same checks.
        guard TranslationValidator.validate(
          source: slice[id].record.sourceText, target: fix).isEmpty else { continue }
        resolved[id] = (fix, router.currentModel)
        outcome.gateFixes += 1
        // A width fix is BEST-EFFORT: the value is accepted even when it is
        // still over the guideline — never loop, never re-ask. The browser
        // keeps flagging it for the human to shorten or accept.
        if let limit = slice[id].record.maxWidth, fix.count > limit {
          progress?.note(
            "\(displayKey(slice[id].record)): still \(fix.count) chars over the \(limit)-char limit")
        }
      }
    }

    // 4. Write, stamping the producing model as the editor.
    for id in resolved.keys.sorted() {
      guard let entry = resolved[id] else { continue }
      let item = slice[id]
      if item.record.state == .empty {
        writeFill(
          env: env, record: item.record, value: entry.value,
          provider: .deepseek, lastEditor: entry.editor,
          reason: "Translate (\(entry.editor)): filled empty slot")
        outcome.filled += 1
      } else if rewriteValue(
        env: env, record: item.record, value: entry.value,
        provider: .deepseek, lastEditor: entry.editor,
        reason: "Translate (\(entry.editor)): differs from previous machine value") {
        outcome.corrected += 1
      }
      trace?.add(TranslationTrace.Step(
        kind: .write,
        title: "Wrote \(displayKey(item.record))",
        model: entry.editor,
        output: entry.value))
      progress?.tick(key: displayKey(item.record))
    }

    // 5. Anything still unresolved failed for this record — unless the caller
    // is the truncation path, where the missing ids are re-asked instead.
    guard markMissingAsFailed else { return }
    for (id, item) in slice.enumerated() where resolved[id] == nil {
      if progress?.isCancelled == true { break }
      let message = "no translation produced"
      outcome.failures.append("\(displayKey(item.record)): \(message)")
      progress?.fail(key: displayKey(item.record), message: message)
    }
  }
}
