//
//  Store.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  The translation store the redesign reads and writes through: the app's
//  `TranslationData` (in memory, persisted in the background) and its models, and
//  nothing else. Semantics are in "docs/Translation design notes.md", section 7.
//
//  Every read is synchronous and cheap — a dictionary lookup in memory — which is
//  why the redesign's loads stay synchronous. A project's records must be loaded
//  first (`TranslationData.loadRecords`, awaited by `Shell.focus`), and translation
//  memory before a run (`TranslationData.loadMemory`, awaited by `Workspace.run`).
//
//  Nothing here writes the .xcstrings: Save on the open catalog is the only
//  writer of the artifact, and it keeps writing through the catalog model the app
//  already has.
//

import Foundation

/// The batch cursor of one run: the batch a paused or interrupted run resumes at,
/// so it starts where it stopped instead of re-billing the batches already applied
/// (5.6).
///
/// A table rather than three keys in the app's defaults for two reasons: a cursor is
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
nonisolated struct RunCursor: Hashable, Sendable {
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
  /// The translation store, seen from the redesign: `TranslationData` plus the one rule the
  /// redesign owns about writing it — a batch of writes is STAGED and lands together.
  ///
  /// `upsert(_:saving: false)` and `append(_:saving: false)` stage a write, `save()` lands
  /// everything staged in one step and `rollback()` drops it, so a session write that throws
  /// part-way leaves nothing half-applied. A staged record is what the store reads back for its
  /// slot until then. A single write (`saving: true`, the default) lands at once.
  ///
  ///   ContextDoc            context documents. `identifier` is the project id for
  ///                         a project document and the FULL scope id,
  ///                         `"project/<id>/language/<code>"`, for a language
  ///                         document — which is what keeps per-project language
  ///                         documents apart (10.1). Only the project document
  ///                         carries the project's row id. Uniqueness is (scope, identifier).
  ///   RunCursor             one row per (project, stage) holding the batch a paused or
  ///                         interrupted run resumes at (5.6).
  ///   TranslationRecord     one slot per (key, language, form). `value` IS `target`,
  ///                         and `machine` / `reviewed` are the bodies beside it.
  ///   TranslationEdit       the journal: append-only before -> after, the learning
  ///                         corpus, never rewritten.
  ///   TranslationMemoryEntry  per-key memory, global (6.2).
  ///   Project               the project row.
  ///
  /// `Context.Version` (three non-optional ints, 0 = "no document existed") maps onto
  /// `ContextVersions` (three optionals), and every write of one goes through the sentinel
  /// fixup: an all-zero Version is stored as the sentinel (global 0), never as three nils —
  /// the rule the stamps the app has always written follow.
  ///
  /// The store owns no logic. Staleness, status transitions and learning are computed by the
  /// operations and written here.
  @MainActor class Store {
    /// The app's project row. `Translation.Project` (the redesign's view object)
    /// shadows that name inside this extension, so the row type is qualified once,
    /// here, and every method below names it `ProjectRow`.
    typealias ProjectRow = Dev.Project

    let data: TranslationData

    init(data: TranslationData? = nil) {
      self.data = data ?? .shared
    }

    // MARK: - version stamps

    /// A redesign stamp as the model's nullable snapshot. An all-zero stamp is written
    /// as the SENTINEL, `ContextVersions(global: 0)`, never as three nils.
    nonisolated static func persistable(_ version: Context.Version) -> ContextVersions {
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
    nonisolated static func lifted(_ versions: ContextVersions) -> ContextVersions {
      if versions.global == nil, versions.project == nil, versions.language == nil {
        return ContextVersions(global: 0)
      }
      return versions
    }

    /// A stored snapshot as the redesign's stamp: a nil member reads as 0, which is
    /// what the sentinel holds and what staleness expects (`0 < published` is true
    /// only once a document exists).
    nonisolated static func version(_ versions: ContextVersions) -> Context.Version {
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
    /// carries as its `identifier` and what translation memory carries as its
    /// `projectTag`. The catalog and root paths are accepted as well, so a caller that
    /// hands over a URL-derived id lands on the same row: this function is the ONLY
    /// place the string is resolved.
    func projectRow(id: String) throws -> ProjectRow? {
      if let bound = bindings[id], let row = data.project(id: bound) { return row }
      let rows = data.projects
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
    /// No `ContextEdit` audit row is written: the redesign's trail is the version stamp
    /// plus the slot-level journal, and a document here only ever holds human rules and
    /// folded lessons, both authored by the app rather than by a background overrider.
    func saveDocument(_ scope: Context.Scope, body: String, version: Int) throws {
      if var existing = try document(scope) {
        guard existing.content != body || existing.version != version else { return }
        existing.content = body
        existing.version = version
        existing.updatedAt = .now
        data.update(existing)
      } else {
        data.insertDocument(
          scope: contextScope(for: scope),
          identifier: identifier(of: scope),
          version: version,
          content: body,
          projectID: try relationshipOwner(of: scope).flatMap { try projectRow(id: $0)?.id })
      }
    }

    /// The stored documents a scope names.
    ///
    /// Ownership: a project document is found by its project row id, with its `identifier`
    /// as the fallback for a row that carries none. A language document is found by its FULL
    /// scope id and never by the language code alone: the id carries the project, so only
    /// this project's document answers, and a legacy row keyed by the bare code (the old
    /// implementation shares one document per code across projects) is deliberately NOT
    /// adopted — a lesson must not leak between projects (10.1).
    private func contextDocs(for scope: Context.Scope) throws -> [ContextDoc] {
      let docs = data.documents
      switch scope {
      case .global:
        return docs.filter { $0.scope == .global }
      case .project(let id):
        if let owner = try projectRow(id: id)?.id,
           let owned = docs.first(where: { $0.scope == .project && $0.projectID == owner }) {
          return [owned]
        }
        return docs.filter { $0.scope == .project && $0.projectID == nil && $0.identifier == id }
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
    private func identifier(of scope: Context.Scope) -> String? {
      switch scope {
      case .global: nil
      case .project(let id): id
      case .language: scope.id
      }
    }

    /// The project whose row id a scope's document carries: the project id for a project
    /// document, nil for every other scope (a language document is told apart by its full
    /// scope id instead).
    private func relationshipOwner(of scope: Context.Scope) -> String? {
      switch scope {
      case .project(let id): id
      case .global, .language: nil
      }
    }

    // MARK: - rows and slots

    /// Every slot record of a project, by slot — with the writes staged and not saved yet
    /// read back over the stored ones. Empty while the project's records are not loaded.
    func records(project: String) throws -> ProjectRecords {
      guard let owner = try projectRow(id: project)?.id,
        var records = data.records(project: owner)
      else { return ProjectRecords() }
      for record in staged.values where record.projectID == owner {
        records[record.slotKey] = record
      }
      return records
    }

    /// One slot's record — the staged write when there is one, else the stored record. A
    /// lookup: what a run's write-back reads per slot.
    func record(project: String, slot: SlotKey) -> TranslationRecord? {
      guard let owner = projectID(project) else { return nil }
      return staged[RecordAddress(project: owner, slot: slot)] ?? data.record(project: owner, slot: slot)
    }

    /// Pins a redesign project id to the project row it means. A NAME is not unique — two
    /// checkouts of one repo are two rows with one name — so the shell, which resolves the row
    /// from the catalog the pane is showing, binds the name to THAT row before anything reads
    /// through it; without it the first row of that name would answer, records and all.
    func bind(_ id: String, to project: Int64) {
      bindings[id] = project
      projectIDs[id] = project
    }
    private var bindings: [String: Int64] = [:]

    /// The row id behind a redesign project id, remembered once resolved.
    private func projectID(_ project: String) -> Int64? {
      if let known = projectIDs[project], data.project(id: known) != nil { return known }
      let resolved = try? projectRow(id: project)?.id
      projectIDs[project] = resolved
      return resolved
    }
    private var projectIDs: [String: Int64] = [:]

    /// A write for a project the store does not hold.
    struct MissingProject: LocalizedError {
      let id: String
      var errorDescription: String? { "The translation store has no project \(id)" }
    }

    /// The languages this project holds records for — the column set a project's rows are
    /// built from.
    func languages(project: String) throws -> [String] {
      try records(project: project).languages.sorted()
    }

    /// Writes staged by `saving: false`, by slot, waiting for `save()`.
    private var staged: [RecordAddress: TranslationRecord] = [:]
    private var stagedEdits: [TranslationEdit] = []
    private var stagedMemory: [MemoryKey: TranslationMemoryEntry] = [:]

    /// Persists one slot record. The stamp is lifted here, always: this is the
    /// redesign's door for a slot write, so it is the place the sentinel rule has to hold.
    ///
    /// Whether this write was ALLOWED — a `.verified` or `.imported` slot is never
    /// overwritten — is the caller's check, made against the slot's own status at
    /// apply time (5.5).
    ///
    /// `saving: false` stages the write for a caller writing MANY records in one pass; the
    /// caller lands them together (`save`).
    func upsert(_ record: TranslationRecord, saving: Bool = true) throws {
      var record = record
      record.contextVersions = Self.lifted(record.contextVersions)
      record.updatedAt = .now
      if saving {
        data.upsert(record)
      } else {
        staged[RecordAddress(project: record.projectID, slot: record.slotKey)] = record
      }
    }

    // MARK: - journal (the learning corpus)

    /// Appends one journal row. Append-only: an edit is never rewritten, and it is
    /// the provenance of every value the app holds.
    func append(_ edit: TranslationEdit, saving: Bool = true) throws {
      var edit = edit
      edit.contextVersions = Self.lifted(edit.contextVersions)
      if saving { data.append(edit) } else { stagedEdits.append(edit) }
    }

    /// Lands everything staged, in one step.
    func save() throws {
      let records = Array(staged.values)
      let edits = stagedEdits
      let memory = Array(stagedMemory.values)
      staged = [:]
      stagedEdits = []
      stagedMemory = [:]
      data.upsert(records)
      data.append(edits)
      for entry in memory { data.upsert(entry) }
    }

    /// Drops everything staged — a session write that threw part-way leaves nothing
    /// half-applied for a later, unrelated save to land by accident.
    func rollback() {
      staged = [:]
      stagedEdits = []
      stagedMemory = [:]
    }

    /// A project's journal, oldest first. `confirmedOnly` is the learn corpus: pipeline-written
    /// rows are not lessons, only the ones a human confirmed. Includes the journal rows staged
    /// and not saved yet.
    func edits(project: String, confirmedOnly: Bool = true) async throws -> [TranslationEdit] {
      guard let owner = try projectRow(id: project)?.id else { return [] }
      let stored = await data.edits(project: owner)
      return (stored + stagedEdits.filter { $0.projectID == owner })
        .filter { !confirmedOnly || $0.isUserConfirmed }
    }

    // MARK: - memory

    /// The entry a (source, target language) pair has — GLOBAL (6.2), newest confirmation
    /// first and gold winning when both grades exist. Staged entries are read back.
    func memoryEntry(source: String, language: String) -> TranslationMemoryEntry? {
      var rows = data.memoryEntries(source: source, targetLanguage: language)
      for entry in stagedMemory.values where entry.sourceText == source && entry.targetLanguage == language {
        rows.removeAll { MemoryKey($0) == MemoryKey(entry) }
        rows.append(entry)
      }
      rows.sort { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) }
      return rows.first { $0.state == .reviewed } ?? rows.first
    }

    /// Persists one memory entry, by its unique triple (sourceText, sourceLanguage,
    /// targetLanguage): a second project's entry for the same triple IS the same row, with
    /// its `projectTag` moved to the project that wrote last.
    ///
    /// Gold is never overwritten by a hint: `state == .reviewed` means a human
    /// confirmed this translation and the app's rule is that gold is gold. Gold may still
    /// be updated by gold — a human re-confirming a newer value wins.
    func upsert(_ entry: TranslationMemoryEntry, saving: Bool = true) throws {
      var entry = entry
      entry.contextVersions = Self.lifted(entry.contextVersions)
      let key = MemoryKey(entry)
      let existing = stagedMemory[key]
        ?? data.memoryEntry(
          source: entry.sourceText, sourceLanguage: entry.sourceLanguage,
          targetLanguage: entry.targetLanguage)
      if let existing, existing.state == .reviewed, entry.state != .reviewed { return }
      if saving { data.upsert(entry) } else { stagedMemory[key] = entry }
    }

    /// Drops the hints of one language that this project's runs left — used when a language
    /// document changes enough that the old machine values are no longer evidence of
    /// anything. Gold is never dropped by a stage.
    func clearHints(language: String, project: String) throws {
      for hint in data.memoryEntries(targetLanguage: language)
      where hint.projectTag == project && hint.state != .reviewed {
        data.delete(hint)
      }
    }

    // MARK: - run cursor

    /// Where a paused or interrupted run left off. Batch granularity, nothing finer.
    func cursor(for stage: Stage, project: String) throws -> Run.Cursor? {
      data.cursor(project: project, stage: stage.rawValue).map { Run.Cursor(batchIndex: $0.batchIndex) }
    }

    func saveCursor(_ cursor: Run.Cursor, for stage: Stage, project: String) throws {
      if let row = data.cursor(project: project, stage: stage.rawValue), row.batchIndex == cursor.batchIndex {
        return
      }
      data.update(RunCursor(project: project, stage: stage.rawValue, batchIndex: cursor.batchIndex))
    }
  }
}
