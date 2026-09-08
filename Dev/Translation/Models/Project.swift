//
//  Project.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// A translation project: one merged .xcstrings catalog being translated.
/// A project owns its project-scope ContextDoc and the TranslationRecords
/// reconciled from its catalog.
@Model final class Project {
  /// Display name of the project (e.g. the repo name).
  var name: String
  /// File URL of the project's merged .xcstrings catalog.
  var catalogURL: URL
  /// When the project was first seen.
  var createdAt: Date

  // MARK: - relationships

  /// The project-scope context document (scope == .project); nil until the
  /// pipeline first learns from this project's confirmed edits.
  @Relationship(deleteRule: .cascade, inverse: \ContextDoc.project)
  var contextDoc: ContextDoc?

  /// Every translation record reconciled from this project's catalog.
  @Relationship(deleteRule: .cascade, inverse: \TranslationRecord.project)
  var records: [TranslationRecord] = []

  init(
    name: String, catalogURL: URL, createdAt: Date = .now,
    contextDoc: ContextDoc? = nil, records: [TranslationRecord] = []
  ) {
    self.name = name
    self.catalogURL = catalogURL
    self.createdAt = createdAt
    self.contextDoc = contextDoc
    self.records = records
  }
}
