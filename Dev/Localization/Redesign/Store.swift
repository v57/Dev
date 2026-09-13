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

extension Translation {
  /// The translation store: the app's SwiftData container, seen from the redesign.
  /// One container for the whole app, the main context for translation state.
  ///
  /// The models are the ones the app already has, used additively:
  ///
  ///   ContextDoc            context documents. `identifier` is the project id for
  ///                         a project document and the BCP-47 code for a language
  ///                         document — which ALSO sets its `project` relationship,
  ///                         because language documents are per project (10.1).
  ///                         Uniqueness is therefore (scope, identifier, project).
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
    /// The app's defaults, for the one value that is run state rather than
    /// translation state — the run cursor. See `cursor(for:project:)`.
    private let defaults = UserDefaults.standard

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
            project: try owner(of: scope).flatMap { try projectRow(id: $0) }))
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
    /// A language document is found by (code, project) and NEVER by code alone:
    /// language documents became per project (10.1), so a legacy document with no
    /// project is not adopted — a lesson must not leak between projects.
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
      case .language(let project, let code):
        guard let owner = try projectRow(id: project)?.persistentModelID else { return [] }
        return docs.filter {
          $0.scope == .language && $0.identifier == code && $0.project?.persistentModelID == owner
        }
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

    /// The `identifier` column of a scope: the project id for a project document,
    /// the BCP-47 code for a language document, nil for global (7.2).
    private func identifier(of scope: Context.Scope) -> String? {
      switch scope {
      case .global: nil
      case .project(let id): id
      case .language(_, let code): code
      }
    }

    /// The project a scope belongs to: the project id, or nil for the global
    /// document (which belongs to no project).
    private func owner(of scope: Context.Scope) -> String? {
      switch scope {
      case .global: nil
      case .project(let id): id
      case .language(let project, _): project
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
    /// The owner is two relationships away (`edit.record.project`); the fetch asks
    /// for it first and falls back to filtering in memory when the predicate is not
    /// supported on this SDK — the same two-step `Reconcile.records(of:in:)` uses.
    func edits(project: String, confirmedOnly: Bool = true) throws -> [TranslationEdit] {
      guard let owner = try projectRow(id: project)?.persistentModelID else { return [] }
      let descriptor = FetchDescriptor<TranslationEdit>(
        predicate: #Predicate { $0.record?.project?.persistentModelID == owner })
      let rows: [TranslationEdit]
      if let owned = try? context.fetch(descriptor) {
        rows = owned
      } else {
        rows = try context.fetch(FetchDescriptor<TranslationEdit>())
      }
      return rows
        .filter { $0.record?.project?.persistentModelID == owner }
        .filter { !confirmedOnly || $0.isUserConfirmed }
        .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - memory

    /// One remembered translation. Resolution is by (source text, language) WITHIN
    /// the project: the model's unique triple is (sourceText, sourceLanguage,
    /// targetLanguage), and the project tag narrows a global table to this project's
    /// memory.
    ///
    /// Gold wins when both grades exist for the same pair — `state == .reviewed` is
    /// a human's entry, and handing back a hint where gold exists would show the
    /// model's guess over a human's decision.
    func memory(source: String, language: String, project: String) throws -> TranslationMemoryEntry? {
      let rows = try memoryRows(source: source, language: language, project: project)
      return rows.first { $0.state == .reviewed } ?? rows.first
    }

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

    /// This project's memory rows for one (source, language) pair, newest
    /// confirmation first.
    ///
    /// The triple's SOURCE language is not part of the redesign's addressing
    /// (`memory(source:language:project:)` is handed a source body, a target
    /// language and a project), so a row is matched on the two halves the redesign
    /// knows and narrowed by its project tag; the sort only decides which of several
    /// rows answers.
    private func memoryRows(
      source: String, language: String, project: String
    ) throws -> [TranslationMemoryEntry] {
      let descriptor = FetchDescriptor<TranslationMemoryEntry>(
        predicate: #Predicate { $0.sourceText == source && $0.targetLanguage == language })
      return try context.fetch(descriptor)
        .filter { $0.projectTag == project }
        .sorted { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) }
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
    /// Kept in the app's defaults rather than in the models on purpose: a cursor is
    /// RUN state, like the run's clock and its per-model tally, which belong on the
    /// run and not on a translation record (5.7), and the app's schema has no column
    /// to reuse for it — adding a table for one Int would put a model in front of the
    /// old pipeline that has nothing to do with translating.
    func cursor(for stage: Stage, project: String) throws -> Run.Cursor? {
      let key = cursorKey(stage, project)
      guard defaults.object(forKey: key) != nil else { return nil }
      return Run.Cursor(batchIndex: defaults.integer(forKey: key))
    }

    func saveCursor(_ cursor: Run.Cursor, for stage: Stage, project: String) throws {
      defaults.set(cursor.batchIndex, forKey: cursorKey(stage, project))
    }

    /// One cursor per (project, stage): a stage resumes where it left off, and two
    /// projects never share a cursor.
    private func cursorKey(_ stage: Stage, _ project: String) -> String {
      "Translation.RunCursor.\(project).\(stage.rawValue)"
    }
  }
}
