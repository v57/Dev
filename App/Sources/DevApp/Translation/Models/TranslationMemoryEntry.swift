//
//  TranslationMemoryEntry.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

/// Translation memory: one remembered translation per (sourceText,
/// sourceLanguage, targetLanguage), shared across projects. Gold is gold —
/// a reviewed entry auto-resolves as `reviewed` in ANY future catalog;
/// machine-only entries resolve as `needs_review` hints. Uniqueness over
/// the (sourceText, sourceLanguage, targetLanguage) triple is enforced at
/// the store level by the composite unique constraint below.
nonisolated struct TranslationMemoryEntry: Hashable, Sendable {
  /// Source text in the source language.
  var sourceText: String
  /// Source language, BCP-47.
  var sourceLanguage: String
  /// Target language, BCP-47.
  var targetLanguage: String
  /// The remembered translation.
  var value: String
  /// What produced the entry.
  var provider: Provider
  /// reviewed once a human confirms the entry, needs_review while
  /// machine-only (never empty — an entry always carries a value).
  var state: TranslationState
  /// Project the entry was created from (informational; entries are global).
  var projectTag: String?
  /// Context-document versions when the entry was created/confirmed.
  var contextVersions: ContextVersions
  /// When a human confirmed the entry; nil while machine-only.
  var confirmedAt: Date?
  /// Machine confidence in the value (0...1); nil for manual output.
  var confidence: Double?

  init(
    sourceText: String, sourceLanguage: String, targetLanguage: String,
    value: String, provider: Provider = .manual, state: TranslationState = .needs_review,
    projectTag: String? = nil, contextVersions: ContextVersions = ContextVersions(),
    confirmedAt: Date? = nil, confidence: Double? = nil
  ) {
    self.sourceText = sourceText
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.value = value
    self.provider = provider
    self.state = state
    self.projectTag = projectTag
    self.contextVersions = contextVersions
    self.confirmedAt = confirmedAt
    self.confidence = confidence
  }
}
