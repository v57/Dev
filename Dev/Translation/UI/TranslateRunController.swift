//
//  TranslateRunController.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import Observation
import SwiftData

// MARK: - TranslateRunController

/// Drives one Translate run from the UI. Owns the live `TranslateRunProgress`
/// the footer renders and the Cancel affordance, snapshots the records the
/// run may touch (the per-cell "in flight" spinner surface), and publishes
/// the machine-readable summary once the run is flushed back to the file.
///
/// Lifecycle (all on the main actor, like the rest of the app):
///   `begin` -> `execute` (long, async) -> store flushes DB -> file ->
///   `finish`. `isRunning` stays true through the flush so the Translate
///   button cannot re-enter while the artifact is being rewritten.
@Observable
final class TranslateRunController {
  /// Live progress of the current run; idle defaults until `begin`.
  private(set) var progress = TranslateRunProgress()
  /// True between `begin` and `finish` — the run is active.
  private(set) var isRunning = false
  /// Outcome of the last finished run (shown by the footer); nil until the
  /// first run completes.
  private(set) var summary: PipelineRunSummary?
  /// When the current run started. A record whose updatedAt predates this is
  /// still an unwritten run target; once the run writes it the timestamp
  /// moves past `startedAt` and the cell stops spinning.
  private(set) var startedAt: Date?
  /// Records the current run may still touch, snapshotted at `begin`.
  private var candidates: Set<PersistentIdentifier> = []

  /// True while the run is active AND `record` is one of its not-yet-written
  /// targets — the per-cell spinner condition.
  func isInFlight(_ record: TranslationRecord?) -> Bool {
    guard isRunning, let record, let startedAt,
          candidates.contains(record.persistentModelID),
          record.updatedAt < startedAt else {
      return false
    }
    return true
  }

  /// Snapshots the run state and the candidate record set. Returns false
  /// when a run is already active (caller must not start another).
  func begin(project: Project) -> Bool {
    begin(project: project, key: nil)
  }

  /// Whole-key run; see the language-scoped variant.
  func begin(project: Project, key: String?) -> Bool {
    begin(project: project, key: key, languages: nil)
  }

  /// `languages`-scoped run; force=false (incremental). See the canonical
  /// variant below.
  func begin(project: Project, key: String?, languages: Set<String>?) -> Bool {
    begin(project: project, key: key, languages: languages, force: false)
  }

  /// Same as `begin(project:)` but scopes the run (and its per-cell spinner
  /// candidates) to a single key and `languages` (the selected columns), and
  /// — when `force` — lifts the freshness gate so fresh machine values are
  /// re-targeted (row "Translate"). Plural form records that do not exist
  /// yet are created up front (same rule as the pipeline's own reconcile),
  /// so the spinner covers forms the run is about to fill.
  func begin(project: Project, key: String?, languages: Set<String>?, force: Bool) -> Bool {
    guard !isRunning else { return false }
    progress = TranslateRunProgress()
    summary = nil
    ensurePluralForms(project: project, key: key, languages: languages)
    candidates = Self.candidateRecords(of: project, key: key, languages: languages, force: force)
    startedAt = .now
    isRunning = true
    return true
  }

  /// Runs the whole pipeline for `project` against the app's one shared
  /// SwiftData context. Progress and cancellation flow through `progress`.
  func execute(project: Project) async -> PipelineRunSummary {
    await execute(project: project, key: nil)
  }

  /// Whole-key run; see the language-scoped variant.
  func execute(project: Project, key: String?) async -> PipelineRunSummary {
    await execute(project: project, key: key, languages: nil)
  }

  /// `languages`-scoped run; force=false (incremental).
  func execute(project: Project, key: String?, languages: Set<String>?) async -> PipelineRunSummary {
    await execute(project: project, key: key, languages: languages, force: false)
  }

  /// Runs the pipeline scoped to one key (row-menu "Translate"), restricted
  /// to `languages` when set — else the whole project. `force` lifts the
  /// freshness gate for the targeted records.
  func execute(project: Project, key: String?, languages: Set<String>?, force: Bool) async -> PipelineRunSummary {
    await TranslationPipeline.run(project: project, key: key, languages: languages, force: force, progress: progress)
  }

  /// Ends the run and publishes the summary. Called after the caller has
  /// flushed the DB back into the .xcstrings artifact.
  func finish(_ result: PipelineRunSummary) {
    summary = result
    isRunning = false
  }

  /// User-facing cancel: the pipeline checks the flag between records and
  /// stops at the next safe point.
  func cancel() {
    progress.cancel()
  }

  /// Drops run state when a different catalog is opened.
  func reset() {
    summary = nil
    isRunning = false
    startedAt = nil
    candidates = []
    progress = TranslateRunProgress()
  }

  // MARK: - candidate snapshot

  /// Creates missing plural form records + file skeletons for the run's
  /// scope BEFORE the candidate snapshot, so newly created forms are
  /// spinner candidates. Mirrors the pipeline's reconcile rule: only keys
  /// whose SOURCE is plural-varied gain forms; single-key runs with no
  /// columns selected (empty set) create nothing.
  private func ensurePluralForms(project: Project, key: String?, languages: Set<String>?) {
    // The UI's coalescing worker may still hold the latest save — drain it
    // so this file read observes every prior write.
    CatalogFileIO.flush()
    guard var catalog = try? StringCatalog.load(url: project.catalogURL) else { return }
    let context = TranslationStore.shared.context
    let keys: [String]
    if let key {
      keys = [key]
    } else {
      keys = project.records.map(\.key).uniqued()
    }
    var touchedFile = false
    var touchedDB = false
    for targetKey in keys {
      guard catalog.hasPlurals(for: targetKey, language: catalog.sourceLanguage) else { continue }
      let targetLanguages: [String]
      if let languages {
        if languages.isEmpty { continue }
        targetLanguages = Array(languages)
      } else {
        targetLanguages = catalog.languages.filter { $0 != catalog.sourceLanguage }
      }
      for language in targetLanguages {
        if !catalog.hasPlurals(for: targetKey, language: language) {
          catalog.varyByPlural(key: targetKey, languages: [language])
          touchedFile = true
        }
        guard catalog.hasPlurals(for: targetKey, language: language) else { continue }
        for category in PluralRules.categories(for: language) {
          if Reconcile.record(key: targetKey, language: language, category: category, in: project) != nil {
            continue
          }
          let record = TranslationRecord(
            key: targetKey,
            sourceText: catalog.sourcePluralDisplay(for: targetKey, category: category),
            language: language,
            value: nil, provider: nil, state: .empty,
            contextVersions: Reconcile.persistableVersions(ContextVersions()),
            category: category)
          context.insert(record)
          record.project = project
          touchedDB = true
        }
      }
    }
    if touchedDB {
      try? context.save()
    }
    if touchedFile {
      CatalogFileIO.schedule(catalog, to: project.catalogURL)
    }
  }

  /// The records this run's stages could touch: not human-owned (.reviewed
  /// states and .manual providers are never rewritten) and either EMPTY or
  /// stale against the context docs that exist right now. Mirrors the
  /// pipeline's `needsTarget` rule so cells stop spinning exactly when the
  /// run writes their record — read-only duplication, since the pipeline's
  /// selector is private to Dev/Translation/Pipeline.
  private static func candidateRecords(of project: Project, key: String? = nil, languages: Set<String>? = nil, force: Bool = false) -> Set<PersistentIdentifier> {
    let context = TranslationStore.shared.context
    let docs = (try? context.fetch(FetchDescriptor<ContextDoc>())) ?? []
    let globalVersion = docs.first { $0.scope == .global }?.version
    let projectVersion = docs.first { $0.scope == .project && $0.project === project }?.version
    var languageVersions: [String: Int] = [:]
    for doc in docs where doc.scope == .language {
      if let identifier = doc.identifier {
        languageVersions[identifier] = doc.version
      }
    }

    func isStale(_ record: TranslationRecord) -> Bool {
      if let v = globalVersion, (record.contextVersions.global ?? -1) < v {
        return true
      }
      if let v = projectVersion, (record.contextVersions.project ?? -1) < v {
        return true
      }
      if let v = languageVersions[record.language],
         (record.contextVersions.language ?? -1) < v {
        return true
      }
      return false
    }

    var ids = Set<PersistentIdentifier>()
    for record in project.records {
      if let key, record.key != key { continue }
      if let languages, !languages.contains(record.language) { continue }
      guard record.state != .reviewed, record.provider != .manual else { continue }
      if record.state == .empty || force || isStale(record) {
        ids.insert(record.persistentModelID)
      }
    }
    return ids
  }
}
