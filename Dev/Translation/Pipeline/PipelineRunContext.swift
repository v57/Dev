//
//  PipelineRunContext.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - PipelineRunContext

/// Everything one Translate run knows about the world, captured once at run
/// start so every stage looks at the same picture:
///  - the owning `Project` and ALL of its records (sorted, live objects),
///  - every ContextDoc that exists (global / project / language), fetched
///    once; docs created mid-run by Stage 0 are appended here as they go,
///  - the merged catalog at `project.catalogURL` (best-effort) so prompts
///    and Stage-0 lessons can carry the developer COMMENT, which the record
///    model intentionally does not store,
///  - the source language (catalog wins, else the run parameter, else "en").
///
/// Main-actor isolated by the module default: SwiftData objects are read and
/// written on the main actor while the backend calls themselves run
/// off-main (see TranslationPipeline).
final class PipelineRunContext {
  let context: ModelContext
  let project: Project
  /// Every record of the project, sorted (language, key, category) for
  /// determinism. Always the FULL set — neighbors/comments/prompts sample
  /// across the project even on a single-key run; only candidate *selection*
  /// honors `targetKey`. Plural-form records are appended by
  /// `reconcilePluralForms()` before the stages run.
  var allRecords: [TranslationRecord]
  /// When set (a row's "Translate"), machine stages act on ONLY this key's
  /// records; every other record is skipped by `isTarget`. Neighbors and
  /// context still come from the whole project.
  let targetKey: String?
  /// When set (a row's "Translate" with columns selected), machine stages
  /// act on ONLY these target-language codes within the targeted key — the
  /// columns visible as sections. Nil = every language (whole-project run).
  let targetLanguages: Set<String>?
  /// When true (row-menu "Translate"), the incremental freshness gate is
  /// lifted for the run's records: non-human-owned `needs_review` machine
  /// values are re-translated/reviewed even when fresh. The whole-catalog
  /// button leaves this false so it stays incremental.
  let force: Bool
  /// BCP-47 code of the catalog's source language ("en" fallback).
  var sourceLanguage: String
  /// All context documents that exist right now; created docs are appended.
  private var docs: [ContextDoc]

  /// Best-effort catalog mirror (nil when the file is missing/unreadable).
  /// Refreshed by `reconcilePluralForms()` when it writes new skeletons.
  private(set) var catalog: StringCatalog?

  /// Per-language neighbor pools, built lazily: target-language values of
  /// OTHER keys — register samples the model stays consistent with.
  private var neighborPool: [String: [(key: String, value: String)]] = [:]

  /// Max lessons stored in one language doc before autonomous rewrites stop
  /// (a rewritten doc must round-trip losslessly; beyond this it goes to a
  /// human instead of risking a silent truncation by the model).
  static let maxDocFoldCharacters = 8000

  init(
    context: ModelContext,
    project: Project,
    sourceLanguage: String? = nil,
    targetKey: String? = nil,
    targetLanguages: Set<String>? = nil,
    force: Bool = false
  ) {
    self.context = context
    self.project = project
    self.targetKey = targetKey
    self.targetLanguages = targetLanguages
    self.force = force
    // Catalog wins over the caller's guess: the file IS the source of truth
    // for the source language and comments.
    let catalog = (try? StringCatalog.load(url: project.catalogURL))
    self.catalog = catalog
    self.sourceLanguage = catalog?.sourceLanguage ?? sourceLanguage ?? "en"
    var allDocs: [ContextDoc] = []
    let descriptor = FetchDescriptor<ContextDoc>()
    if let fetched = try? context.fetch(descriptor) {
      allDocs = fetched
    }
    docs = allDocs
    allRecords = project.records.sorted { ($0.language, $0.key, $0.category ?? "") < ($1.language, $1.key, $1.category ?? "") }
  }

  // MARK: - context docs

  /// True when a record belongs to this run's work set: `targetKey` is nil
  /// (whole-project run) or the record is the targeted key, AND (when the
  /// run is language-scoped) the record's language is one of the selected
  /// columns. Applied by every stage's candidate filter so a single-item run
  /// touches exactly the selected languages of one key.
  func isTarget(_ record: TranslationRecord) -> Bool {
    if let targetKey, record.key != targetKey { return false }
    if let targetLanguages, !targetLanguages.contains(record.language) { return false }
    return true
  }

  /// The global document, nil before Stage 0 ever created one.
  func globalDoc() -> ContextDoc? {
    docs.first { $0.scope == .global }
  }

  /// The project-scope document for this project, nil until created.
  func projectDoc() -> ContextDoc? {
    docs.first { $0.scope == .project && $0.project === project }
  }

  /// The language-scope document for a BCP-47 target code, nil until created.
  func languageDoc(for language: String) -> ContextDoc? {
    docs.first { $0.scope == .language && $0.identifier == language }
  }

  /// Registers a freshly inserted doc so later stages see it.
  func remember(_ doc: ContextDoc) {
    docs.append(doc)
  }

  // MARK: - versions & staleness

  /// Current version of the doc of a scope, or nil when the doc does not
  /// exist (a nil snapshot means "did not exist / not used at the time").
  func version(scope: ContextScope, language: String? = nil) -> Int? {
    switch scope {
    case .global:
      return globalDoc()?.version
    case .project:
      return projectDoc()?.version
    case .language:
      return languageDoc(for: language ?? "")?.version
    }
  }

  /// The three versions a translation written NOW should be stamped with.
  /// Routed through Reconcile.persistableVersions so an all-nil snapshot
  /// (no ContextDoc exists yet — nil members, which SwiftData on this SDK
  /// crashes on when re-faulting a persisted all-nil row) is lifted to
  /// ContextVersions(global: 0). Docs start at v1, so 0 is the safe "no doc
  /// existed" sentinel: staleness math is identical ((v ?? -1) < docVersion,
  /// and 0 < 1 once a doc exists). Every pipeline write — writeFill,
  /// rewriteValue, Stage-0's reviewed upsert, TM machine hints, and the
  /// TranslationEdit audits they append — receives this function's output.
  func snapshot(for language: String) -> ContextVersions {
    Reconcile.persistableVersions(
      ContextVersions(
        global: version(scope: .global),
        project: version(scope: .project),
        language: version(scope: .language, language: language)
      )
    )
  }

  /// True when a record's stored context-versions are older than the current
  /// docs for any scope — i.e. its value was produced against stale context.
  /// A record whose snapshot predates a doc's existence (nil vs 1+) is stale;
  /// equal or newer versions are fresh.
  func isStale(_ record: TranslationRecord) -> Bool {
    if let v = version(scope: .global), (record.contextVersions.global ?? -1) < v {
      return true
    }
    if let v = version(scope: .project), (record.contextVersions.project ?? -1) < v {
      return true
    }
    if let v = version(scope: .language, language: record.language),
       (record.contextVersions.language ?? -1) < v {
      return true
    }
    return false
  }

  // MARK: - catalog comments

  /// Developer comment attached to a catalog key (first-class prompt input),
  /// or nil when the catalog is unreadable or the key carries no comment.
  func comment(for key: String) -> String? {
    catalog?.entry(for: key)?.comment
  }

  // MARK: - plural reconcile

  /// Ensures every targeted plural key carries a form record per CLDR
  /// category of each targeted language: creates missing form records
  /// (empty, from the source form) and missing CLDR forms in the file
  /// skeleton. Runs BEFORE the stages on every Translate run (whole-catalog
  /// and single-key), so AI fills forms the human never created by hand —
  /// "Translate" creates the missing categories. A key whose source has no
  /// plural variation gains no target forms (nothing to translate from).
  /// Returns how many form records were created.
  @discardableResult
  func reconcilePluralForms() -> Int {
    guard let catalog else { return 0 }
    var created = 0
    var keys = Set<String>()
    for record in allRecords where isTarget(record) {
      keys.insert(record.key)
    }
    if let targetKey {
      keys = [targetKey]
    }
    for key in keys {
      guard catalog.hasPlurals(for: key, language: catalog.sourceLanguage) else { continue }
      let languages: [String]
      if let targetLanguages {
        languages = Array(targetLanguages)
      } else {
        languages = catalog.languages.filter { $0 != catalog.sourceLanguage }
      }
      for language in languages {
        let entry = catalog.entry(for: key)
        let loc = entry?.localizations?[language]
        let hasPlural = loc?.variations?["plural"]?.isEmpty == false
        let hasFlat = loc?.stringUnit != nil
        // A flat-only target of a plural source: "other" moves into the
        // skeleton (same rule as Vary by plural) so its value survives.
        if !hasPlural && hasFlat {
          var mutable = catalog
          mutable.varyByPlural(key: key, languages: [language])
          persistCatalog(mutable)
        } else if !hasPlural && !hasFlat && (targetLanguages == nil || isTargetLanguage(language)) {
          // Whole-catalog run, or this language is in scope: create the
          // skeleton for the AI to fill. Single-key runs with no columns
          // selected (empty set) create nothing.
          if targetLanguages?.isEmpty == true { continue }
          var mutable = catalog
          mutable.varyByPlural(key: key, languages: [language])
          persistCatalog(mutable)
        }
        guard catalog.hasPlurals(for: key, language: language) else { continue }
        for category in PluralRules.categories(for: language) {
          if formRecord(key: key, language: language, category: category) != nil { continue }
          let record = TranslationRecord(
            key: key,
            sourceText: catalog.sourcePluralDisplay(for: key, category: category),
            language: language,
            value: nil, provider: nil, state: .empty,
            contextVersions: Reconcile.persistableVersions(ContextVersions()),
            category: category)
          context.insert(record)
          record.project = project
          allRecords.append(record)
          created += 1
        }
      }
    }
    if created > 0 {
      try? context.save()
    }
    // Re-sort: candidate selection is order-independent, but determinism
    // keeps progress + logs stable.
    allRecords.sort { ($0.language, $0.key, $0.category ?? "") < ($1.language, $1.key, $1.category ?? "") }
    return created
  }

  /// True when the language is in this run's scope (whole-catalog runs
  /// target everything).
  private func isTargetLanguage(_ language: String) -> Bool {
    guard let targetLanguages else { return true }
    return targetLanguages.contains(language)
  }

  /// The live form record for a slot, or nil.
  private func formRecord(key: String, language: String, category: String) -> TranslationRecord? {
    allRecords.first { $0.key == key && $0.language == language && $0.category == category }
  }

  /// Persists a mutated catalog copy back to the artifact and refreshes the
  /// cached mirror so later stages see the skeleton.
  private func persistCatalog(_ mutated: StringCatalog) {
    do {
      try mutated.save(to: project.catalogURL)
    } catch {
      return
    }
    catalog = mutated
  }

  // MARK: - neighbor pool

  /// Up to `limit` target-language values of OTHER keys in the same
  /// language, sorted by key — register and terminology samples. Flat
  /// values only: plural form fragments would read as broken sentences out
  /// of context.
  func neighbors(for language: String, excluding key: String, limit: Int = 10) -> [String] {
    let pool: [(key: String, value: String)]
    if let cached = neighborPool[language] {
      pool = cached
    } else {
      var built: [(key: String, value: String)] = []
      for record in allRecords where record.language == language && record.category == nil {
        guard let value = record.value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        built.append((record.key, value))
      }
      built.sort { $0.key < $1.key }
      neighborPool[language] = built
      pool = built
    }
    return pool
      .filter { $0.key != key }
      .prefix(limit)
      .map { $0.value }
  }

  // MARK: - prompt context assembly

  /// Assembles the TranslationContext for one record: key, comment (from the
  /// catalog), same-language neighbor values, and the three ContextDoc
  /// bodies. Plural form records also carry their category + every source
  /// form, so the model translates with the right number agreement. The
  /// backends' ContextPromptBuilder applies its own caps.
  func translationContext(for record: TranslationRecord) -> TranslationContext {
    var context = TranslationContext(
      key: record.key,
      comment: comment(for: record.key),
      neighbors: neighbors(for: record.language, excluding: record.key),
      globalContext: globalDoc()?.content,
      projectContext: projectDoc()?.content,
      languageContext: languageDoc(for: record.language)?.content
    )
    if let category = record.category {
      context.pluralCategory = category
      if let catalog {
        var forms: [String: String] = [:]
        for sourceCategory in PluralRules.categories(for: catalog.sourceLanguage) {
          let text = catalog.sourcePluralDisplay(for: record.key, category: sourceCategory)
          if !text.isEmpty {
            forms[sourceCategory] = text
          }
        }
        context.sourcePluralForms = forms
      }
    }
    return context
  }
}
