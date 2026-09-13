//
//  Memory.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md", section 6.
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
      let key: String
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
    func resolve(source: String, language: String) throws -> Entry? { nil }
    /// `learn` writes gold; a translate stage writes hints for what it produced,
    /// so the next run can show where a value came from.
    func upsert(_ entry: Entry) throws {

    }
    /// Drops the hints of one language — used when a language document changes
    /// enough that the old machine values are no longer evidence of anything. Gold
    /// is never dropped by a stage.
    func clearHints(language: String) throws {

    }
  }

  /// The shipped human translations (the imported SQLite database).
  enum Imported {
    /// Resolves slots before any model call and marks them `.imported`: usable,
    /// unreviewed, and shown in their own colour because the reviewer has to know
    /// the value did not come from our model.
    ///
    /// Writes NO memory entry — the database is the source of truth it is, not a
    /// lesson about our model — and the horizontal pass does not consult it at
    /// all: with the freshness gate lifted it would replace existing machine
    /// values with shipped ones, which is not what "apply my rule" means.
    static func resolve(rows: [LocalizationKey], language: String) throws -> [String: String] { [:] }
  }
}
