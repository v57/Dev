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
  /// What produced `value`; nil while the slot is empty.
  var provider: Provider?
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
    lastEditor: String? = nil, project: Project? = nil, edits: [TranslationEdit] = []
  ) {
    self.key = key
    self.sourceText = sourceText
    self.language = language
    self.value = value
    self.provider = provider
    self.state = state
    self.confidence = confidence
    self.contextVersions = contextVersions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.reviewedAt = reviewedAt
    self.lastEditor = lastEditor
    self.project = project
    self.edits = edits
  }
}
