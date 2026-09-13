//
//  TranslationRecord.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// One translation slot: a catalog key in one target language, plus full
/// provenance (who wrote the current value, against which context versions).
/// The logical unique key is (key, language) WITHIN a project — two projects
/// may legitimately hold the same key+language with different values — so
/// there is deliberately no global DB unique constraint; deduplication is a
/// project-scoped fetch-first upsert by the reconcile layer.
@Model final class TranslationRecord {
  /// Catalog key (the .xcstrings dictionary key).
  var key: String
  /// Source-language text for the key at reconcile time.
  var sourceText: String
  /// Target language, BCP-47.
  var language: String
  /// Current translated value; nil while the slot is empty.
  var value: String?
  /// Plural category this record holds ("one", "other", …); nil for a flat
  /// (non-varied) slot. Plural forms are full records — each form carries its
  /// own sourceText, value, state and provenance, so the pipeline translates
  /// them exactly like flat slots. Nil-able so the pre-plural store migrates
  /// automatically (existing rows read back as flat).
  var category: String?
  /// What produced `value`; nil while the slot is empty.
  var provider: Provider?
  /// True when the current value came from the imported translation DB and
  /// was marked reviewed WITHOUT a human: state is .reviewed (so no stage or
  /// run ever re-translates it) but nobody vouched for it yet. The UI shows
  /// an "auto" badge; one click (human confirm) clears it. Persisted raw —
  /// records reconciled from a file always carry false (the file cannot
  /// express auto-reviewed). The inline default keeps the additive SwiftData
  /// migration lightweight.
  var autoReviewed: Bool = false
  /// empty / needs_review (machine output) / reviewed (human confirmed).
  var state: TranslationState
  /// Machine confidence in the current value (0...1); nil for manual output.
  var confidence: Double?
  /// Context-document versions the current value was produced against.
  var contextVersions: ContextVersions
  /// When the record was first reconciled.
  var createdAt: Date
  /// When the record was last touched (value, state, or provenance change).
  var updatedAt: Date
  /// When a human last confirmed the value (state -> .reviewed); nil until
  /// then.
  var reviewedAt: Date?
  /// Human name or provider that last wrote the value.
  var lastEditor: String?
  /// Reviewer note of the ROW this record belongs to (key-scoped: every record
  /// of one key carries the same note). nil = no note. App-local metadata —
  /// the .xcstrings format has no note field and Save is the only catalog
  /// writer. Persisted raw.
  var note: String?
  /// What the note does: `project` folds it into the project's ContextDoc as a
  /// rule the translator follows, `memo` keeps it in the app for humans only.
  /// Raw `Reconcile.NoteScope` value; nil while there is no note.
  var noteScope: String?
  /// When the current note text was folded into the project doc; nil until it
  /// is. A memo is never folded.
  var noteFoldedAt: Date?
  /// The exact note text that WAS folded, so an edit re-folds and clearing the
  /// note retracts the rule. nil = nothing folded.
  var noteFoldedText: String?
  /// Reviewer's MAX WIDTH guideline for this row's rendered text, in
  /// characters; nil = no guideline (the default). Key-scoped: every record of
  /// the key carries the same limit. App-local metadata, NEVER sent to the
  /// translator — only the reviewer side uses it (the browser flags a value
  /// that exceeds it, and the paid verification gate may shorten one).
  var maxWidth: Int?

  /// What the MACHINE produced for this slot. The record carries three bodies:
  /// `value` IS the slot's target, this is the model's own output beside it, and
  /// `reviewed` is the human's value at the moment they confirmed it. `machine`
  /// exists so learning has something to compare a human's edit with: a
  /// human-verified slot with no machine output on record is what `prelearn`
  /// fills. Written by machine stages only — a human edit never touches it.
  /// Additive with an inline default, like `autoReviewed`/`note`/`maxWidth`, so
  /// the existing store migrates without a custom stage.
  var machine: String? = nil

  /// The value at the moment a human confirmed the slot — a SNAPSHOT, not a
  /// second copy of the target. A later human edit makes `value != reviewed`,
  /// which re-arms learning for this slot; equal values mean there is nothing
  /// new to learn. nil until a human confirms. Additive with an inline default.
  var reviewed: String? = nil

  // MARK: - relationships

  /// The project whose catalog this record was reconciled from.
  var project: Project?
  /// Full before->after history — the learning corpus for Stage 0.
  @Relationship(deleteRule: .cascade, inverse: \TranslationEdit.record)
  var edits: [TranslationEdit] = []

  init(
    key: String, sourceText: String, language: String, value: String? = nil,
    provider: Provider? = nil, state: TranslationState = .empty,
    confidence: Double? = nil, contextVersions: ContextVersions = ContextVersions(),
    createdAt: Date = .now, updatedAt: Date = .now, reviewedAt: Date? = nil,
    lastEditor: String? = nil, project: Project? = nil, edits: [TranslationEdit] = [],
    category: String? = nil, autoReviewed: Bool = false,
    note: String? = nil, noteScope: String? = nil, noteFoldedAt: Date? = nil,
    noteFoldedText: String? = nil, maxWidth: Int? = nil,
    machine: String? = nil, reviewed: String? = nil
  ) {
    self.key = key
    self.sourceText = sourceText
    self.language = language
    self.value = value
    self.category = category
    self.provider = provider
    self.autoReviewed = autoReviewed
    self.state = state
    self.confidence = confidence
    self.contextVersions = contextVersions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.reviewedAt = reviewedAt
    self.lastEditor = lastEditor
    self.note = note
    self.noteScope = noteScope
    self.noteFoldedAt = noteFoldedAt
    self.noteFoldedText = noteFoldedText
    self.maxWidth = maxWidth
    self.machine = machine
    self.reviewed = reviewed
    self.project = project
    self.edits = edits
  }
}
