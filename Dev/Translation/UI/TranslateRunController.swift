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
  /// True while the run's PREPARATION is in flight (the plural-form skeleton,
  /// which runs off the main actor before `begin`). The footer shows the same
  /// progress surface for it, and re-entry is guarded against it exactly like
  /// a running run.
  private(set) var isPreparing = false
  /// True while a run is active in ANY phase — preparing or executing. The UI
  /// disables its run buttons on this, and `cancel()` works in both phases.
  var isActive: Bool { isPreparing || isRunning }
  /// Outcome of the last finished run (shown by the footer); nil until the
  /// first run completes.
  private(set) var summary: PipelineRunSummary?
  /// When the current run started. A record whose updatedAt predates this is
  /// still an unwritten run target; once the run writes it the timestamp
  /// moves past `startedAt` and the cell stops spinning.
  private(set) var startedAt: Date?
  /// The records the current run may still touch, snapshotted at `begin`.
  private var candidates: Set<PersistentIdentifier> = []

  /// Set while an off-main preparation pass (plural skeleton) is in flight, so
  /// `cancel()` can reach it. Cleared when the pass ends.
  private var preparationCancellation: PreparationCancellation?

  /// Non-nil when the last preparation pass failed to write its records. The
  /// store surfaces it through the same alert as its load/save errors.
  private(set) var preparationError: String?

  /// Clears the preparation error once the alert has been dismissed.
  func clearPreparationError() {
    preparationError = nil
  }

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
  /// re-targeted (row "Translate") on a forced run. The caller must run
  /// `ensurePluralForms` FIRST when the run needs plural forms the catalog
  /// does not have yet, so the spinner covers forms the run is about to fill.
  func begin(project: Project, key: String?, languages: Set<String>?, force: Bool) -> Bool {
    guard !isRunning else { return false }
    progress = TranslateRunProgress()
    summary = nil
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
  /// freshness gate for the targeted records. `catalog` is the UI's OPEN
  /// in-memory catalog (prompt/comment source and the run's non-destructive
  /// view of the world); the caller merges the run's output afterwards.
  func execute(project: Project, key: String?, languages: Set<String>?, force: Bool, catalog: StringCatalog? = nil) async -> PipelineRunSummary {
    await TranslationPipeline.run(
      project: project, key: key, languages: languages, force: force,
      catalog: catalog, progress: progress)
  }

  /// Runs the explicit "Update Translations" pass: the whole project's records
  /// that predate the current project context doc, one request per ROW with
  /// every target language of that row (`updatePass`), against the LARGER
  /// `updateSourceBudget`. The freshness gate is lifted (`force`), TM resolve
  /// is kept, and the imported-DB stage plus Stage 0 are skipped — this pass
  /// applies a project rule, it does not re-learn or re-promote DB values.
  /// `catalog` is the UI's OPEN in-memory catalog, as for a normal run.
  func executeUpdate(project: Project, catalog: StringCatalog? = nil) async -> PipelineRunSummary {
    await TranslationPipeline.run(
      project: project,
      force: true,
      catalog: catalog,
      progress: progress,
      sourceBudget: TranslationRouter.updateSourceBudget,
      skipImportedDB: true,
      skipStage0: true,
      updatePass: true)
  }

  /// Ends the run and publishes the summary. Called after the caller has
  /// flushed the DB back into the .xcstrings artifact.
  func finish(_ result: PipelineRunSummary) {
    summary = result
    isRunning = false
  }

  /// User-facing cancel: the pipeline checks the flag between records and
  /// stops at the next safe point. Also stops the off-main preparation pass —
  /// its flag lives outside the main actor on purpose (see
  /// `PreparationCancellation`), so both are set here.
  func cancel() {
    progress.cancel()
    preparationCancellation?.cancel()
  }

  /// Drops run state when a different catalog is opened.
  func reset() {
    summary = nil
    isRunning = false
    startedAt = nil
    candidates = []
    progress = TranslateRunProgress()
  }

  // MARK: - plural skeletons

  /// Cross-thread cancellation for the off-main preparation pass.
  /// `TranslateRunProgress.isCancelled` is main-actor state that a detached
  /// task cannot read; this is the same flag in a form the background loop
  /// can poll between keys. `nonisolated` (the module defaults to MainActor
  /// isolation, which would make the flag unreadable from the Sendable closure
  /// that polls it) and `@unchecked Sendable` behind a lock.
  nonisolated final class PreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return flag
    }
    func cancel() {
      lock.lock()
      flag = true
      lock.unlock()
    }
  }

  /// Creates the missing plural form records + the CLDR form skeleton for the
  /// run's scope, so newly created forms are spinner candidates and the run has
  /// forms to fill. Runs BEFORE `begin` — the candidate snapshot must see the
  /// new records — and OFF the main actor: the pass walks every key of the
  /// catalog and can insert thousands of records (see
  /// `Reconcile.ensurePluralForms`, which does the work in a background
  /// context). Returns the varied catalog, or nil when nothing needed varying
  /// or the pass was cancelled.
  ///
  /// The catalog half happens on the caller's OPEN catalog, which the caller
  /// adopts back (this controller never writes the artifact — Save is the only
  /// writer).
  @discardableResult
  func ensurePluralForms(
    project: Project,
    catalog: StringCatalog?,
    key: String?,
    languages: Set<String>?
  ) async -> StringCatalog? {
    guard let catalog, !isPreparing else { return nil }
    // A cancel left over from a PREVIOUS run must not abort this one: clear it
    // before the pass starts, so only a click during this pass stops it.
    progress.resetCancellation()
    let cancellation = PreparationCancellation()
    preparationCancellation = cancellation
    isPreparing = true
    defer {
      isPreparing = false
      preparationCancellation = nil
    }

    // Progress arrives on the background thread; the stream hands it to this
    // (main) actor so the footer can render it live while the pass runs.
    let (stream, continuation) = AsyncStream<Reconcile.PluralSkeletonProgress>.makeStream()
    let projectID = project.persistentModelID
    let work = Task.detached(priority: .userInitiated) {
      () -> Result<Reconcile.PluralSkeletonOutcome, Error> in
      defer { continuation.finish() }
      return await Reconcile.ensurePluralForms(
        catalog: catalog, projectID: projectID, key: key, languages: languages,
        in: TranslationStore.container,
        isCancelled: { cancellation.isCancelled },
        progress: { continuation.yield($0) })
    }
    var announced = false
    for await update in stream {
      if !announced {
        progress.begin(.pluralForms, total: update.total, note: "Preparing plural forms")
        announced = true
      }
      progress.report(completed: update.completed, key: update.key)
    }

    switch await work.value {
    case .success(let outcome):
      preparationError = nil
      if outcome.inserted > 0 {
        progress.note("Plural forms: \(outcome.inserted) record(s) created")
      }
      if outcome.cancelled, !progress.isCancelled {
        // Cancelled through some other path than the button: keep the flag the
        // caller checks honest.
        progress.cancel()
      }
      if progress.isCancelled {
        // Cancelled while preparing: no pipeline ran, but the footer reports
        // the attempt ("Last run — cancelled") instead of silently snapping
        // back to idle. A cancelled pass keeps what it inserted (nothing is
        // rolled back), and its run does not start — the caller checks
        // `progress.isCancelled`.
        summary = PipelineRunSummary(cancelled: true)
      }
      return outcome.varied ? outcome.catalog : nil
    case .failure(let error):
      preparationError = "Couldn't create the plural form records: \(error.localizedDescription)"
      return nil
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
    var languageVersions: [String: Int] = [:]
    for doc in docs where doc.scope == .language {
      if let identifier = doc.identifier {
        languageVersions[identifier] = doc.version
      }
    }

    // Delegates to the pipeline's own predicate so the two can never drift;
    // the project scope is deliberately not consulted (see
    // PipelineRunContext.isStale — a project-doc rule reaches existing
    // translations through the explicit Update Translations pass instead).
    func isStale(_ record: TranslationRecord) -> Bool {
      PipelineRunContext.isStale(
        record,
        globalVersion: globalVersion,
        languageVersion: languageVersions[record.language])
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
