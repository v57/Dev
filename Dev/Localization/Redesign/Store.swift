//
//  Store.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md", section 7.
//
//  Translation state STAYS IN SWIFTDATA (reader, 2026-09-13). That is what makes
//  the loads above synchronous: a context document, a slot record, a journal row
//  and a memory entry are all fetches on the main actor, so reading one is a fault,
//  not a suspension point. Only two things in the redesign stay async — a model
//  call, and opening/parsing/writing the .xcstrings.
//
//  Nothing here writes the .xcstrings: Save on the open catalog is the only writer
//  of the artifact, and it keeps writing through the catalog model the app already
//  has.
//

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
    let context: ModelContext
    init(context: ModelContext) {
      self.context = context
    }

    // MARK: - context documents

    /// The document for a scope, or nil when it has never been written (which is an
    /// empty body at version 1, not a bump).
    func document(_ scope: Context.Scope) throws -> ContextDoc? { nil }
    /// Upserts body + version. Called only after a REAL change: a no-op write must
    /// not bump the version, because the bump is what marks the whole column stale.
    func saveDocument(_ scope: Context.Scope, body: String, version: Int) throws {

    }

    // MARK: - rows and slots

    func records(project: String) throws -> [TranslationRecord] { [] }
    func upsert(_ record: TranslationRecord) throws {

    }

    // MARK: - journal (the learning corpus)

    func append(_ edit: TranslationEdit) throws {

    }
    /// `confirmedOnly` is the learn corpus: pipeline-written rows are not lessons,
    /// only the ones a human confirmed.
    func edits(project: String, confirmedOnly: Bool = true) throws -> [TranslationEdit] { [] }

    // MARK: - memory

    /// One remembered translation. Resolution is by (source text, language) WITHIN
    /// the project: the model's unique triple is (sourceText, sourceLanguage,
    /// targetLanguage), and the project tag narrows a global table to this project's
    /// memory.
    func memory(source: String, language: String, project: String) throws -> TranslationMemoryEntry? { nil }
    func upsert(_ entry: TranslationMemoryEntry) throws {

    }
    /// Drops the hints of one language — used when a language document changes
    /// enough that the old machine values are no longer evidence of anything. Gold
    /// is never dropped by a stage.
    func clearHints(language: String, project: String) throws {

    }

    // MARK: - run cursor

    /// Where a paused or interrupted run left off. Batch granularity, nothing finer.
    func cursor(for stage: Stage, project: String) throws -> Run.Cursor? { nil }
    func saveCursor(_ cursor: Run.Cursor, for stage: Stage, project: String) throws {

    }
  }
}
