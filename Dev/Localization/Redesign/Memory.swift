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
import SwiftData

extension Translation {
  /// Per-key knowledge, in two grades. GLOBAL, not per project (6.2, reader
  /// 2026-09-14): the app's own model keeps ONE remembered translation per
  /// (sourceText, sourceLanguage, targetLanguage), shared by every project — its
  /// docs say a reviewed entry "auto-resolves as `reviewed` in ANY future catalog"
  /// — and `projectTag` is informational, written as provenance and never read as a
  /// filter. The imported database is the other global source, and it is a source,
  /// not a lesson — see `Imported`.
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
      /// seed a candidate, but it never overrides an existing human value.
      case hint
    }

    /// An exact (source, language) hit, GLOBALLY (6.2): memory is one table shared by
    /// every project, so a value a human confirmed for this source text in this
    /// language answers the slot in EVERY catalog that asks for the pair. A gold hit
    /// is what lets the run skip a slot entirely; a hint is provenance, not a
    /// decision — unless the slot holds nothing at all, which is the caller's rule
    /// and not this one's (10.19c, `Run.resolveMemory`).
    ///
    /// Resolution is by source text and language — the app's translation memory is
    /// keyed by its (sourceText, sourceLanguage, targetLanguage) triple, and the
    /// redesign has the target language and the source text — and the key travels for
    /// provenance.
    ///
    /// The two grades come straight off the row's state: `reviewed` is a human's
    /// entry and `needs_review` is the model's, which is the app's own convention
    /// (Stage 0 promotes a hint in place when a human confirms the same triple). A
    /// row in `empty` state resolves nothing — memory never carries a valueless
    /// entry, so such a row is a corrupted one and filling a slot with nothing is
    /// worse than a miss. The same guard is in the old TM resolve, for the same
    /// reason.
    func resolve(source: String, language: String) throws -> Entry? {
      guard let row = try entry(source: source, language: language) else { return nil }
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
    ///
    /// `saving: false` is for a caller writing MANY entries in one pass — a fold writes one gold
    /// entry per lesson of its batch — and it is passed STRAIGHT to `Store.upsert`: every
    /// `context.save()` is its own transaction, so the batch writes through and the caller saves
    /// once (`Store.save`), the shape `Project.saveData` uses (7.6).
    ///
    /// ONE read per write: the pair's existing row decides the source language, and it IS
    /// the row the triple names, so it is handed to the store instead of looked up again —
    /// this runs once per row a run writes, on the main actor.
    func upsert(_ entry: Entry, saving: Bool = true) throws {
      let gold = entry.grade == .gold
      let existing = try self.entry(source: entry.source, language: entry.language)
      let row = TranslationMemoryEntry(
        sourceText: entry.source,
        sourceLanguage: Self.sourceLanguage(of: existing),
        targetLanguage: entry.language,
        value: entry.value,
        // `deepseek` is the raw value of the app's hosted-model case — the one Muse
        // is served from; the raw value stays for record compatibility.
        provider: gold ? .manual : .deepseek,
        state: gold ? .reviewed : .needs_review,
        projectTag: project.id,
        contextVersions: Store.persistable(entry.versions),
        confirmedAt: gold ? .now : nil)
      switch existing {
      case nil:
        // Nothing for the pair at all, so nothing for the triple either.
        try store.upsert(row, over: nil, saving: saving)
      case let existing? where !existing.sourceLanguage.isEmpty:
        try store.upsert(row, over: existing, saving: saving)
      default:
        // A legacy row with no source language: the triple was named by the default, which is
        // not this row's, so the store looks the triple up itself.
        try store.upsert(row, saving: saving)
      }
    }

    /// Drops the hints of one language — used when a language document changes
    /// enough that the old machine values are no longer evidence of anything. Gold
    /// is never dropped by a stage.
    ///
    /// The tag scopes the DROP, not a read: it is the project a hint was last written
    /// from, and this drops the ones THIS project's runs left. Resolution is global and
    /// unfiltered (6.2) — an entry is one row per source -> target pair whatever its tag
    /// — so whether a hint drop should be global too is the reader's call and is
    /// reported, not decided here.
    func clearHints(language: String) throws {
      try store.clearHints(language: language, project: project.id)
    }

    /// The one remembered translation a (source text, target language) pair has —
    /// GLOBAL, and not narrowed by project (6.2).
    ///
    /// The app's model makes the triple (sourceText, sourceLanguage, targetLanguage)
    /// the unit: one row per remembered translation, shared by every project. So the
    /// read matches the two halves the redesign has and NOTHING else — `projectTag` is
    /// provenance ("Project the entry was created from (informational; entries are
    /// global)") and is never a filter. Newest confirmation first, and GOLD WINS when
    /// both grades exist for the pair, which is `Store.memory`'s own rule kept while
    /// its project filter goes.
    ///
    /// The rows are read through the store's context rather than `Store.memory`, which
    /// still narrows by project: dropping the filter there would touch `Store.swift`,
    /// another card's file. `Store.memory`'s filter and doc are drift against 6.2 and
    /// are reported on its card.
    private func entry(source: String, language: String) throws -> TranslationMemoryEntry? {
      let descriptor = FetchDescriptor<TranslationMemoryEntry>(
        predicate: #Predicate { $0.sourceText == source && $0.targetLanguage == language })
      let rows = try store.context.fetch(descriptor)
        .sorted { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) }
      return rows.first { $0.state == .reviewed } ?? rows.first
    }

    /// The source language an entry is written with, when the redesign has none to
    /// offer.
    ///
    /// 6.2 keys memory by (source text, language) GLOBALLY, and the redesign's `Entry`
    /// carries no source language — the redesign's `Project`
    /// holds target languages only. The app's `TranslationMemoryEntry` does require
    /// the column (its unique triple is (sourceText, sourceLanguage,
    /// targetLanguage)), so it is filled in this order:
    ///
    ///   1. the source language of the row this pair ALREADY has, so an entry the
    ///      old pipeline wrote for this project is updated rather than duplicated
    ///      beside itself with a different language on the same triple. That lookup is
    ///      GLOBAL too: the triple is one row whatever project wrote it, and a
    ///      project-narrowed read would miss the row another project's run wrote and
    ///      insert a second one for the same pair,
    ///   2. `defaultSourceLanguage` for a pair nothing has ever written: the app's
    ///      own fallback for a catalog that names none (`PipelineRunContext` and the
    ///      loader both default to it), which is what keeps ONE pair ONE row across
    ///      both writers (10.16: one store, two writers, the same records).
    private static func sourceLanguage(of existing: TranslationMemoryEntry?) -> String {
      guard let existing, !existing.sourceLanguage.isEmpty else { return defaultSourceLanguage }
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
