//
//  Store.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  The SwiftData store the redesign reads and writes through: the app's real
//  container and the app's real models, and nothing else. Semantics are in
//  "Design notes.md", section 7.
//
//  Translation state STAYS IN SWIFTDATA (reader, 2026-09-13), and that is what
//  makes every load below synchronous: a context document, a slot record, a
//  journal row and a memory entry are all fetches on the main actor, so reading
//  one is a fault, not a suspension point. Only two things in the redesign stay
//  async — a model call, and opening/parsing/writing the .xcstrings.
//
//  Nothing here writes the .xcstrings: Save on the open catalog is the only
//  writer of the artifact, and it keeps writing through the catalog model the app
//  already has.
//
//  Nothing here calls the old pipeline either (`LocalizationStore`,
//  `TranslationPipeline`, `TranslationRouter`, `Stage0Learner`, `Reconcile`): the
//  two implementations share the MODELS, not code. What IS shared on purpose is
//  the storage the app already has, which is why the two rules below are the old
//  implementation's rules, restated here instead of called:
//
//    - the SENTINEL rule: SwiftData on this SDK decomposes `ContextVersions` into
//      nullable columns and crashes re-faulting a row whose versions are ALL nil,
//      so a stamp of three zeros is stored as the sentinel (global 0), never as
//      three nils. `Reconcile.persistableVersions` is the same fixup; it is read
//      as the precedent, never called. Every write in this file that carries a
//      stamp goes through it.
//    - the ADDITIVE rule: a column the redesign needs and the models lack is
//      added with an inline default, so the existing store migrates without a
//      custom stage. That is how `machine` and `reviewed` arrive on
//      `TranslationRecord`.
//
//  Two behaviours are deliberately NOT here, because they are the callers':
//  which slots a write may touch (a stage's write-back decides that from the
//  slot's own status) and the change gate that makes a no-op document write
//  write nothing. This store persists what it is handed, after the guards that
//  keep the store itself honest (the sentinel, and gold outranking a hint).
//

import Foundation
import SwiftData

/// The batch cursor of one run: the batch a paused or interrupted run resumes at,
/// so it starts where it stopped instead of re-billing the batches already applied
/// (5.6).
///
/// This is the redesign's ONLY addition to the app's schema (7.2, 10.16), and it is
/// a table rather than three keys in the app's defaults for two reasons: a cursor is
/// translation state that has to survive the way the records beside it do, and it is
/// addressed by a PAIR — (project, stage) — which defaults can only hold as one
/// flattened string. One row per pair; a stage resumes where it left off and two
/// projects never share a cursor. The run's tally and clock stay on the `Run`, not
/// here (5.7).
///
/// `project` is the redesign's project id (the app's project NAME — see
/// `Store.projectRow(id:)`) and `stage` the raw value of `Translation.Stage`; both are
/// strings on purpose, so the row can be written before or without the `Project` row
/// it describes, and so nothing here points back at the models the old pipeline owns.
@Model final class RunCursor {
  /// The project the run belongs to.
  var project: String
  /// The run's stage (`Stage.rawValue`).
  var stage: String
  /// The batch the run stopped BEFORE: resuming starts here.
  var batchIndex: Int
  /// When the cursor last moved.
  var updatedAt: Date

  init(
    project: String, stage: String, batchIndex: Int, updatedAt: Date = .now
  ) {
    self.project = project
    self.stage = stage
    self.batchIndex = batchIndex
    self.updatedAt = updatedAt
  }
}

extension Translation {
  /// The translation store: the app's SwiftData container, seen from the redesign.
  /// One container for the whole app, the main context for translation state.
  ///
  /// The models are the app's own, plus the ONE row the redesign adds:
  ///
  ///   ContextDoc            context documents. `identifier` is the project id for
  ///                         a project document and the FULL scope id,
  ///                         `"project/<id>/language/<code>"`, for a language
  ///                         document — which is what keeps per-project language
  ///                         documents apart (10.1). A language document does NOT
  ///                         set its `project` relationship: that is the to-one
  ///                         inverse of `Project.contextDoc`, the property the old
  ///                         browser reads for project rules, so only the project
  ///                         document owns it. Uniqueness is (scope, identifier).
  ///   RunCursor             the redesign's only addition to the schema (10.16): one
  ///                         row per (project, stage) holding the batch a paused or
  ///                         interrupted run resumes at (5.6).
  ///   TranslationRecord     one slot per (key, language). The redesign needs three
  ///                         bodies where the model has one value: `value` IS
  ///                         `target`, and `machine` / `reviewed` are additive
  ///                         columns with inline defaults (`var machine: String? =
  ///                         nil`) — the app's existing additive-migration style.
  ///   TranslationEdit       the journal: append-only before -> after, the learning
  ///                         corpus, never rewritten.
  ///   TranslationMemoryEntry  per-key memory. The model declares the entry global
  ///                         and `projectTag` informational; the redesign leans on
  ///                         that column for resolution, because memory is per
  ///                         project for the same reason language documents are.
  ///   Project               the project row.
  ///
  /// Two rules survive the move to the redesign unchanged:
  ///   - `Context.Version` (three non-optional ints, 0 = "no document existed") maps
  ///     onto `ContextVersions` (three optionals), and every write of one goes
  ///     through the sentinel fixup: SwiftData on this SDK crashes re-faulting an
  ///     all-nil versions row, so an all-zero Version is stored as the sentinel
  ///     (global 0), never as three nils.
  ///   - The store owns no logic. Staleness, status transitions and learning are
  ///     computed by the operations and written here.
  @Observable @MainActor class Store {
    /// The app's project row. `Translation.Project` (the redesign's view object)
    /// shadows that name inside this extension, so the row type is qualified once,
    /// here, and every method below names it `ProjectRow`.
    typealias ProjectRow = Dev.Project

    let context: ModelContext

    init(context: ModelContext) {
      self.context = context
    }

    // MARK: - version stamps

    /// A redesign stamp as the model's nullable snapshot.
    ///
    /// `Context.Version` is three non-optional ints where 0 means "no document
    /// existed then" (or "no document has been written yet" — the two are the same
    /// thing to every comparison the redesign makes). An all-zero stamp is written
    /// as the SENTINEL, `ContextVersions(global: 0)`: three nils is the row shape
    /// SwiftData on this SDK crashes re-faulting, which is the whole reason the
    /// sentinel exists. (`Reconcile.persistableVersions` is the same function in the
    /// old implementation — read as precedent, never called.)
    static func persistable(_ version: Context.Version) -> ContextVersions {
      if version.global == 0, version.project == 0, version.language == 0 {
        return ContextVersions(global: 0)
      }
      return ContextVersions(
        global: version.global, project: version.project, language: version.language)
    }

    /// The sentinel fixup for a snapshot built somewhere else (a legacy row, an
    /// edit a caller composed by hand). Only the all-nil corner is lifted; nil
    /// members are preserved exactly as they are, because "did not exist" and
    /// "existed at 0" compare the same everywhere in the redesign.
    static func lifted(_ versions: ContextVersions) -> ContextVersions {
      if versions.global == nil, versions.project == nil, versions.language == nil {
        return ContextVersions(global: 0)
      }
      return versions
    }

    /// A stored snapshot as the redesign's stamp: a nil member reads as 0, which is
    /// what the sentinel holds and what staleness expects (`0 < published` is true
    /// only once a document exists).
    static func version(_ versions: ContextVersions) -> Context.Version {
      Context.Version(
        global: versions.global ?? 0,
        project: versions.project ?? 0,
        language: versions.language ?? 0)
    }

    // MARK: - project identity

    /// The app's project row behind a redesign project id, or nil when the store
    /// does not hold that project yet (nothing to map onto, so every read below
    /// answers empty rather than inventing a row).
    ///
    /// The redesign addresses a project by a STRING, and the app already has one:
    /// the project's `name`, which is what the existing project-scope `ContextDoc`
    /// carries as its `identifier` (Reconcile.swift: `identifier: project.name`) and
    /// what translation memory carries as its `projectTag` (Stage0Learner's reviewed
    /// upsert). The catalog and root paths are accepted as well, so a caller that
    /// hands over a URL-derived id lands on the same row: this function is the ONLY
    /// place the string is resolved, so a different id costs one function, not every
    /// call site.
    func projectRow(id: String) throws -> ProjectRow? {
      let rows = try context.fetch(FetchDescriptor<ProjectRow>())
      return rows.first { $0.name == id }
        ?? rows.first { $0.catalogURL.path == id }
        ?? rows.first { $0.rootURL?.path == id }
    }

    // MARK: - context documents

    /// The document for a scope, or nil when it has never been written (which is an
    /// empty body at version 1, not a bump).
    func document(_ scope: Context.Scope) throws -> ContextDoc? {
      try contextDocs(for: scope).first
    }

    /// Upserts body + version. Called only after a REAL change: a no-op write must
    /// not bump the version, because the bump is what marks the whole column stale.
    ///
    /// The caller owns the change gate (3.8); the equality guard below is only a
    /// belt on top of it, so a caller that forgot cannot touch `updatedAt`, let
    /// alone the version, with an identical body.
    ///
    /// No `ContextEdit` audit row is written. That table is the OLD implementation's
    /// trail (it records what an autonomous rewrite overrode); the redesign's trail
    /// is the version stamp plus the slot-level journal in `TranslationEdit`, and a
    /// document here only ever holds human rules and folded lessons, both authored
    /// by the app rather than by a background overrider.
    func saveDocument(_ scope: Context.Scope, body: String, version: Int) throws {
      if let existing = try document(scope) {
        guard existing.content != body || existing.version != version else { return }
        existing.content = body
        existing.version = version
        existing.updatedAt = .now
      } else {
        context.insert(
          ContextDoc(
            scope: contextScope(for: scope),
            identifier: identifier(of: scope),
            version: version,
            content: body,
            createdAt: .now,
            updatedAt: .now,
            project: try relationshipOwner(of: scope).flatMap { try projectRow(id: $0) }))
      }
      try context.save()
    }

    /// The stored documents a scope names.
    ///
    /// A fetch of the whole table filtered here, not a predicate: `scope` is a
    /// Codable enum a predicate cannot address, and the current implementation reads
    /// the table exactly this way (`PipelineRunContext`: `FetchDescriptor<ContextDoc>()`
    /// then a filter). The table holds one row per document — one global, one per
    /// project, one per language of a project — so the fetch is cheap.
    ///
    /// Ownership: a project document is found through the project RELATIONSHIP (the
    /// current implementation's own test, `$0.scope == .project && $0.project === project`),
    /// with its `identifier` as the fallback for a row whose relationship is unset.
    /// A language document is found by its FULL scope id and never by the language code
    /// alone: the id carries the project, so only this project's document answers, and a
    /// legacy row keyed by the bare code (the old implementation shares one document per
    /// code across projects) is deliberately NOT adopted — a lesson must not leak between
    /// projects (10.1).
    private func contextDocs(for scope: Context.Scope) throws -> [ContextDoc] {
      let docs = try context.fetch(FetchDescriptor<ContextDoc>())
      switch scope {
      case .global:
        return docs.filter { $0.scope == .global }
      case .project(let id):
        if let owner = try projectRow(id: id)?.persistentModelID,
           let owned = docs.first(where: {
             $0.scope == .project && $0.project?.persistentModelID == owner
           }) {
          return [owned]
        }
        return docs.filter { $0.scope == .project && $0.project == nil && $0.identifier == id }
      case .language:
        return docs.filter { $0.scope == .language && $0.identifier == scope.id }
      }
    }

    /// The model's scope enum for a redesign scope.
    private func contextScope(for scope: Context.Scope) -> ContextScope {
      switch scope {
      case .global: .global
      case .project: .project
      case .language: .language
      }
    }

    /// The `identifier` column of a scope (7.2): the project id for a project
    /// document, the FULL scope id for a language document, nil for global.
    ///
    /// The two differ on purpose. A project document's identifier is the project id
    /// because that is what the app already writes there (`Reconcile`:
    /// `identifier: project.name`) and the old browser reads. A language document's is
    /// its whole scope id — `"project/<id>/language/<code>"`, the same string
    /// `Context.Scope.id` builds — because that is what keeps one project's lessons out
    /// of another's: language documents became per project (10.1), and with the
    /// relationship deliberately unset (below) the identifier is the only column that
    /// can say which project a document belongs to.
    private func identifier(of scope: Context.Scope) -> String? {
      switch scope {
      case .global: nil
      case .project(let id): id
      case .language: scope.id
      }
    }

    /// The project whose `contextDoc` relationship a scope sets: the project id for a
    /// project document, nil for every other scope.
    ///
    /// A language document deliberately sets NO relationship. `Project.contextDoc` is
    /// the to-one inverse of `ContextDoc.project`, so a project document and its
    /// language documents cannot share it — and that property is exactly what the old
    /// browser reads for the project's rules. The full scope id keeps the documents
    /// apart instead (3.1), which costs no new relationship and no compound key. The
    /// global document belongs to no project at all.
    private func relationshipOwner(of scope: Context.Scope) -> String? {
      switch scope {
      case .project(let id): id
      case .global, .language: nil
      }
    }

    // MARK: - rows and slots

    /// Every slot record of a project.
    ///
    /// ONE fetch, never `project.records`: SwiftData faults a to-many one object at
    /// a time (the mirror measured 4.2 s to iterate 48 420 records that way, against
    /// 0.7 s for the same rows through this fetch). Sorted (key, language, category)
    /// so a caller sees a row's slots together and the order is stable — the
    /// redesign's own row order comes from the CATALOG, not from here.
    func records(project: String) throws -> [TranslationRecord] {
      guard let owner = try projectRow(id: project)?.persistentModelID else { return [] }
      let descriptor = FetchDescriptor<TranslationRecord>(
        predicate: #Predicate { $0.project?.persistentModelID == owner })
      return try context.fetch(descriptor).sorted {
        ($0.key, $0.language, $0.category ?? "")
          < ($1.key, $1.language, $1.category ?? "")
      }
    }

    /// Persists one slot record, inserting it when the store does not hold it yet.
    ///
    /// The stamp is lifted here, always: this is the redesign's door for a slot
    /// write, so it is the place the sentinel rule has to hold. `value` IS the
    /// slot's target (7.2); `machine` and `reviewed` are the additive columns beside
    /// it.
    ///
    /// Whether this write was ALLOWED — a `.verified` or `.imported` slot is never
    /// overwritten — is the caller's check, made against the slot's own status at
    /// apply time (5.5). The store cannot make it: it holds a record, not the
    /// statuses the run resolved.
    func upsert(_ record: TranslationRecord) throws {
      record.contextVersions = Self.lifted(record.contextVersions)
      record.updatedAt = .now
      if record.modelContext == nil { context.insert(record) }
      try context.save()
    }

    // MARK: - journal (the learning corpus)

    /// Appends one journal row. Append-only: an edit is never rewritten, and it is
    /// the provenance of every value the app holds.
    func append(_ edit: TranslationEdit) throws {
      edit.contextVersions = Self.lifted(edit.contextVersions)
      context.insert(edit)
      try context.save()
    }

    /// `confirmedOnly` is the learn corpus: pipeline-written rows are not lessons,
    /// only the ones a human confirmed. Oldest first, which is the order `learn`
    /// folds in.
    ///
    /// The owner is TWO relationships away (`edit.record.project`), and a predicate
    /// fetch on that path is NOT trustworthy: measured in a probe against these models
    /// (in-memory store, one record, two journal rows), the qualified
    /// `#Predicate { $0.record?.project?.persistentModelID == owner }` returned ONE of
    /// the two rows — it does not throw, so the `try?`/fallback shape
    /// `Reconcile.records(of:in:)` uses never fires, and which row it drops varies
    /// between runs. Silent and partial is the worst pair of properties for a table
    /// `learn` reads lessons out of, so the fetch below is unqualified and the filter
    /// is the source of truth. The table holds one row per value change, and the filter
    /// has to read the relationship anyway, so nothing is saved by narrowing the query.
    func edits(project: String, confirmedOnly: Bool = true) throws -> [TranslationEdit] {
      guard let owner = try projectRow(id: project)?.persistentModelID else { return [] }
      return try context.fetch(FetchDescriptor<TranslationEdit>())
        .filter { $0.record?.project?.persistentModelID == owner }
        .filter { !confirmedOnly || $0.isUserConfirmed }
        .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - memory

    // The read is `Memory.entry(source:language:)` and it is GLOBAL (6.2): one table
    // shared by every project, one row per (sourceText, sourceLanguage,
    // targetLanguage) triple, `projectTag` is provenance and never a filter. A
    // project-narrowed read used to live here — `memory(source:language:project:)`,
    // filtering on the tag — and was REMOVED (reader, 2026-09-14) rather than left
    // beside the global one: it encoded a rule the app does not have, and the next
    // caller would have picked it up.

    /// Persists one memory entry.
    ///
    /// The row is resolved by the model's unique triple — (sourceText,
    /// sourceLanguage, targetLanguage) is unique across the whole table, so a second
    /// project's entry for the same triple IS the same row, with its `projectTag`
    /// moved to the project that wrote last. Inserting a second row for the triple
    /// would collide with the constraint, so the upsert writes through the existing
    /// one instead.
    ///
    /// Gold is never overwritten by a hint: `state == .reviewed` means a human
    /// confirmed this translation and the app's rule is that gold is gold (the old
    /// machine-hint upsert kept the same guard). Gold may still be updated by gold —
    /// a human re-confirming a newer value wins.
    func upsert(_ entry: TranslationMemoryEntry) throws {
      entry.contextVersions = Self.lifted(entry.contextVersions)
      guard let existing = try entryRow(for: entry), existing !== entry else {
        if entry.modelContext == nil { context.insert(entry) }
        try context.save()
        return
      }
      guard !(existing.state == .reviewed && entry.state != .reviewed) else { return }
      existing.value = entry.value
      existing.provider = entry.provider
      existing.state = entry.state
      existing.projectTag = entry.projectTag
      existing.contextVersions = entry.contextVersions
      existing.confirmedAt = entry.confirmedAt
      existing.confidence = entry.confidence
      try context.save()
    }

    /// Drops the hints of one language — used when a language document changes
    /// enough that the old machine values are no longer evidence of anything. Gold
    /// is never dropped by a stage.
    func clearHints(language: String, project: String) throws {
      let descriptor = FetchDescriptor<TranslationMemoryEntry>(
        predicate: #Predicate { $0.targetLanguage == language })
      let rows = try context.fetch(descriptor)
      let hints = rows.filter { $0.projectTag == project && $0.state != .reviewed }
      guard !hints.isEmpty else { return }
      for hint in hints { context.delete(hint) }
      try context.save()
    }

    /// The row the model's unique triple already claims, if any.
    private func entryRow(for entry: TranslationMemoryEntry) throws -> TranslationMemoryEntry? {
      let sourceText = entry.sourceText
      let sourceLanguage = entry.sourceLanguage
      let targetLanguage = entry.targetLanguage
      let descriptor = FetchDescriptor<TranslationMemoryEntry>(
        predicate: #Predicate {
          $0.sourceText == sourceText
            && $0.sourceLanguage == sourceLanguage
            && $0.targetLanguage == targetLanguage
        })
      return try context.fetch(descriptor).first
    }

    // MARK: - run cursor

    /// Where a paused or interrupted run left off. Batch granularity, nothing finer.
    ///
    /// A `RunCursor` ROW, not a key in the app's defaults (5.6, 7.2): a cursor has to
    /// survive and be inspectable exactly like the translation state around it, and it
    /// is addressed by (project, stage) — a pair, which the defaults had to flatten into
    /// a string key. The tally is the value that stays on the Run, not here (5.7).
    func cursor(for stage: Stage, project: String) throws -> Run.Cursor? {
      try cursorRow(for: stage, project: project).map { Run.Cursor(batchIndex: $0.batchIndex) }
    }

    func saveCursor(_ cursor: Run.Cursor, for stage: Stage, project: String) throws {
      guard let row = try cursorRow(for: stage, project: project) else {
        context.insert(
          RunCursor(project: project, stage: stage.rawValue, batchIndex: cursor.batchIndex))
        try context.save()
        return
      }
      guard row.batchIndex != cursor.batchIndex else { return }
      row.batchIndex = cursor.batchIndex
      row.updatedAt = .now
      try context.save()
    }

    /// The one cursor row per (project, stage) pair. Same fetch-first upsert the rest of
    /// this file uses — no unique constraint is added to the schema for it, so resolving
    /// the row is this function's job.
    private func cursorRow(for stage: Stage, project: String) throws -> RunCursor? {
      let rawStage = stage.rawValue
      let descriptor = FetchDescriptor<RunCursor>(
        predicate: #Predicate { $0.project == project && $0.stage == rawStage })
      return try context.fetch(descriptor).first
    }
  }
}
