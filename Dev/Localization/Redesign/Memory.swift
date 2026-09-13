//
//  Memory.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Translation memory (gold / hint) and the imported-database resolve. Semantics
//  are in "Design notes.md", section 6.
//
//  This is what makes the 1 000-character language document sufficient: the
//  document holds cross-key conventions, and per-key knowledge lives here, where an
//  exact hit answers a slot with no prompt at all.
//

import Foundation

extension Translation {
  /// Per-key knowledge, in two grades. Scoped to one project: what a lesson says
  /// is this project's own vocabulary, and the gold entries come from this
  /// project's own confirmations. The imported database is the one global source,
  /// and it is a source, not a lesson — see `Imported`.
  @Observable @MainActor class Memory {
    let project: Project
    /// SwiftData, so resolution and writes are synchronous fetches.
    let store: Store
    init(project: Project) {
      self.project = project
      store = project.global.store
    }
    struct Entry: Hashable {
      /// The catalog key, when the caller knows it. `learn` writes the key it
      /// taught; a RESOLVED entry leaves it nil, because the app's memory model
      /// keeps no key column — an entry is addressed by its (sourceText,
      /// sourceLanguage, targetLanguage) triple — so a resolve cannot recover one.
      /// The caller that asked by source text already has the key in hand.
      let key: String?
      let source: String
      let language: String
      let value: String
      let grade: Grade
      /// The documents the value was produced against — a gold entry written
      /// against an older project document is still usable (a human wrote it), but
      /// its provenance has to say so.
      let versions: Context.Version
    }

    enum Grade {
      /// A human confirmed this value: it resolves the slot with NO model call.
      case gold
      /// Machine output kept for reference. It may be shown as a hint and it may
      /// seed a repair, but it never overrides an existing human value.
      case hint
    }

    /// An exact (source, language) hit within this project. A gold hit is what lets
    /// the pipeline skip a slot entirely; a hint is provenance, not a decision.
    /// Resolution is by source text and language — the app's translation memory is
    /// keyed that way (see `Store.memory`) — and the key travels for provenance.
    ///
    /// The two grades come straight off the row's state: `reviewed` is a human's
    /// entry and `needs_review` is the model's, which is the app's own convention
    /// (Stage 0 promotes a hint in place when a human confirms the same triple). A
    /// row in `empty` state resolves nothing — memory never carries a valueless
    /// entry, so such a row is a corrupted one and filling a slot with nothing is
    /// worse than a miss. The same guard is in the old TM resolve, for the same
    /// reason.
    func resolve(source: String, language: String) throws -> Entry? {
      guard let row = try store.memory(source: source, language: language, project: project.id)
      else { return nil }
      guard row.state != .empty else { return nil }
      return Entry(
        key: nil,
        source: row.sourceText,
        language: row.targetLanguage,
        value: row.value,
        grade: row.state == .reviewed ? .gold : .hint,
        versions: Store.version(row.contextVersions))
    }

    /// `learn` writes gold; a translate stage writes hints for what it produced,
    /// so the next run can show where a value came from.
    ///
    /// One row per triple, in the app's model: `Store.upsert` resolves the
    /// (sourceText, sourceLanguage, targetLanguage) row and writes through it, and
    /// it refuses to let a hint overwrite gold — a human's entry stays the answer
    /// until a human replaces it. Gold may still update gold: a re-confirmation of
    /// a newer value wins.
    ///
    /// A gold entry carries what the old pipeline's Stage 0 wrote: provider
    /// `manual` ("a human vouched for this"), the confirmation time, and no
    /// confidence. A hint carries the hosted model's provider and no confirmation.
    func upsert(_ entry: Entry) throws {
      let gold = entry.grade == .gold
      let row = TranslationMemoryEntry(
        sourceText: entry.source,
        sourceLanguage: try sourceLanguage(for: entry),
        targetLanguage: entry.language,
        value: entry.value,
        // `deepseek` is the raw value of the app's hosted-model case — the one Muse
        // is served from; the raw value stays for record compatibility.
        provider: gold ? .manual : .deepseek,
        state: gold ? .reviewed : .needs_review,
        projectTag: project.id,
        contextVersions: Store.persistable(entry.versions),
        confirmedAt: gold ? .now : nil)
      try store.upsert(row)
    }

    /// Drops the hints of one language — used when a language document changes
    /// enough that the old machine values are no longer evidence of anything. Gold
    /// is never dropped by a stage.
    ///
    /// Scoped to this project: memory is per project (6.1), so another project's
    /// hints for the same language are none of this one's business.
    func clearHints(language: String) throws {
      try store.clearHints(language: language, project: project.id)
    }

    /// The source language an entry is written with, when the redesign has none to
    /// offer.
    ///
    /// 6.2 keys memory by (source text, language) within the project, and the
    /// redesign's `Entry` carries no source language — the redesign's `Project`
    /// holds target languages only. The app's `TranslationMemoryEntry` does require
    /// the column (its unique triple is (sourceText, sourceLanguage,
    /// targetLanguage)), so it is filled in this order:
    ///
    ///   1. the source language of the row this pair ALREADY has, so an entry the
    ///      old pipeline wrote for this project is updated rather than duplicated
    ///      beside itself with a different language on the same triple,
    ///   2. `defaultSourceLanguage` for a pair nothing has ever written: the app's
    ///      own fallback for a catalog that names none (`PipelineRunContext` and the
    ///      loader both default to it), which is what keeps ONE pair ONE row across
    ///      both writers (10.16: one store, two writers, the same records).
    private func sourceLanguage(for entry: Entry) throws -> String {
      guard
        let existing = try store.memory(
          source: entry.source, language: entry.language, project: project.id),
        !existing.sourceLanguage.isEmpty
      else { return Self.defaultSourceLanguage }
      return existing.sourceLanguage
    }

    /// The source language an entry gets when nothing knows better — the app's
    /// fallback, not a statement about this project's catalog (the redesign never
    /// sees the artifact's `sourceLanguage`, and the notes give memory no place to
    /// keep one).
    static let defaultSourceLanguage = "en"
  }

  /// The shipped human translations (the imported SQLite database).
  ///
  /// Read synchronously through `ImportedDB` (7.1: the `Imported` lookup is a local
  /// file read, like a store fetch — not a model call), because the app's own
  /// database facade is async for the old pipeline's stage.
  enum Imported {
    /// Resolves slots before any model call and marks them `.imported`: usable,
    /// unreviewed, and shown in their own colour because the reviewer has to know
    /// the value did not come from our model.
    ///
    /// Writes NO memory entry — the database is the source of truth it is, not a
    /// lesson about our model — and the horizontal pass does not consult it at
    /// all: with the freshness gate lifted it would replace existing machine
    /// values with shipped ones, which is not what "apply my rule" means.
    ///
    /// It answers one question — what the database has for the given rows' source
    /// text in one language — as key -> value. WHICH slots may take one is a fact
    /// about the open catalog and not about the database, so it stays with the
    /// caller: `Workspace.applyImported` applies a value only to a slot that holds
    /// nothing and whose status is writable, which is what keeps a shipped
    /// translation from replacing a value this project already committed to.
    ///
    /// A hit is picked by `ImportedDBLanguage.hit` — the same spelling-normalizing
    /// picker the old stage uses (the database's language codes are not clean
    /// BCP-47), so both readers agree on what a hit is.
    static func resolve(rows: [LocalizationKey], language: String) throws -> [String: String] {
      // No import, or a remembered file that is gone: nothing to resolve, and no
      // error — see `ImportedDB.handle()`.
      guard let database = try ImportedDB.handle() else { return [:] }
      let appRowCounts = ImportedTranslationDB.shared.stats?.apps ?? [:]
      var resolved: [String: String] = [:]
      // One pick per SOURCE TEXT: several keys may carry the same source body, and
      // the pick depends on the language, never on the key.
      var picks: [String: ImportedDBHit?] = [:]
      for row in rows {
        let source = row.content.catalogValue
        // A row with no text at all has nothing to look up. (`content` falls back
        // to the key, which is what the artifact shows for a row with no source
        // unit, so a row that reaches this line does carry something to match.)
        guard !source.isEmpty else { continue }
        let hit: ImportedDBHit?
        if let picked = picks[source] {
          hit = picked
        } else {
          hit = ImportedDBLanguage.hit(
            in: try database.rows(forSource: source),
            forCatalogLanguage: language,
            appRowCounts: appRowCounts)
          picks[source] = hit
        }
        guard let hit else { continue }
        resolved[row.key] = hit.value
      }
      return resolved
    }
  }
}
