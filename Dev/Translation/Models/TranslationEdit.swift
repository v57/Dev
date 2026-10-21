//
//  TranslationEdit.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

/// One before->after value change on a TranslationRecord. Every write to a
/// record — machine output from a pipeline stage, a human typing or
/// confirming — appends an edit; confirmed human edits are the Stage-0
/// learning corpus.
nonisolated struct TranslationEdit: Hashable, Sendable {
  /// The slot this edit belongs to: its project and (key, language, category). Edits are
  /// stored by the slot's natural key, so a journal row needs no record id.
  var projectID: Int64
  var key: String
  var language: String
  var category: String?
  /// Value before the edit; nil when the slot was empty.
  var fromValue: String?
  /// Value after the edit.
  var toValue: String
  /// Who made the change: a human, or one of the machine providers.
  var editor: Editor
  /// Free-form reason; machine edits carry the model's rationale, human
  /// edits may carry a note or be nil.
  var reason: String?
  /// Context-document versions captured when the edit was made.
  var contextVersions: ContextVersions
  /// True when a human explicitly confirmed this edit (pipeline folds only
  /// user-confirmed edits into learning).
  var isUserConfirmed: Bool
  /// When the edit was made.
  var createdAt: Date

  init(
    record: TranslationRecord, fromValue: String? = nil, toValue: String,
    editor: Editor, reason: String? = nil, contextVersions: ContextVersions = ContextVersions(),
    isUserConfirmed: Bool = false, createdAt: Date = .now
  ) {
    projectID = record.projectID
    key = record.key
    language = record.language
    category = record.category
    self.fromValue = fromValue
    self.toValue = toValue
    self.editor = editor
    self.reason = reason
    self.contextVersions = contextVersions
    self.isUserConfirmed = isUserConfirmed
    self.createdAt = createdAt
  }

  init(
    projectID: Int64, key: String, language: String, category: String?,
    fromValue: String?, toValue: String, editor: Editor, reason: String?,
    contextVersions: ContextVersions, isUserConfirmed: Bool, createdAt: Date
  ) {
    self.projectID = projectID
    self.key = key
    self.language = language
    self.category = category
    self.fromValue = fromValue
    self.toValue = toValue
    self.editor = editor
    self.reason = reason
    self.contextVersions = contextVersions
    self.isUserConfirmed = isUserConfirmed
    self.createdAt = createdAt
  }

  /// The slot this edit is about.
  var slotKey: SlotKey { SlotKey(key: key, language: language, category: category) }
}
