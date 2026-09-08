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
  /// Every record of the project, sorted (language, key) for determinism.
  /// Always the FULL set — neighbors/comments/prompts sample across the
  /// project even on a single-key run; only candidate *selection* honors
  /// `targetKey`.
  let allRecords: [TranslationRecord]
  /// When set (a row's "Translate"), machine stages act on ONLY this key's
  /// records; every other record is skipped by `isTarget`. Neighbors and
  /// context still come from the whole project.
  let targetKey: String?
  /// BCP-47 code of the catalog's source language ("en" fallback).
  var sourceLanguage: String
  /// All context documents that exist right now; created docs are appended.
  private var docs: [ContextDoc]

  /// Best-effort catalog mirror (nil when the file is missing/unreadable).
  private let catalog: StringCatalog?

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
    targetKey: String? = nil
  ) {
    self.context = context
    self.project = project
    self.targetKey = targetKey
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
    allRecords = project.records.sorted { ($0.language, $0.key) < ($1.language, $1.key) }
  }

  // MARK: - context docs

  /// True when a record belongs to this run's work set: `targetKey` is nil
  /// (whole-project run) or the record is the targeted key. Applied by every
  /// stage's candidate filter so a single-item run touches exactly one key.
  func isTarget(_ record: TranslationRecord) -> Bool {
    targetKey == nil || record.key == targetKey
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

  // MARK: - neighbor pool

  /// Up to `limit` target-language values of OTHER keys in the same
  /// language, sorted by key — register and terminology samples.
  func neighbors(for language: String, excluding key: String, limit: Int = 10) -> [String] {
    let pool: [(key: String, value: String)]
    if let cached = neighborPool[language] {
      pool = cached
    } else {
      var built: [(key: String, value: String)] = []
      for record in allRecords where record.language == language {
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
  /// bodies. The backends' ContextPromptBuilder applies its own caps.
  func translationContext(for record: TranslationRecord) -> TranslationContext {
    TranslationContext(
      key: record.key,
      comment: comment(for: record.key),
      neighbors: neighbors(for: record.language, excluding: record.key),
      globalContext: globalDoc()?.content,
      projectContext: projectDoc()?.content,
      languageContext: languageDoc(for: record.language)?.content
    )
  }
}
