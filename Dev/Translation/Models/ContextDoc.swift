//
//  ContextDoc.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// A versioned context document the pipeline reads when translating: one
/// global (identifier nil), one per project (identifier = project's own id),
/// one per language (identifier = BCP-47 code). Content is plain text —
/// glossary entries, key+comment+value lessons. Growth is fully autonomous
/// with OVERRIDE authority; every change appends a ContextEdit audit row and
/// bumps `version` so stale translations become detectable.
@Model final class ContextDoc {
  /// global / project / language.
  var scope: ContextScope
  /// Project id for scope == .project, BCP-47 code for scope == .language,
  /// nil for scope == .global.
  var identifier: String?
  /// Monotonic version; starts at 1, bumped on every autonomous change.
  var version: Int
  /// The document body.
  var content: String
  /// When the document was first created.
  var createdAt: Date
  /// When the document was last changed (version bump included).
  var updatedAt: Date

  // MARK: - relationships

  /// The owning project; set only when scope == .project.
  var project: Project?
  /// Audit trail of every change (before -> after + reason + author).
  @Relationship(deleteRule: .cascade, inverse: \ContextEdit.contextDoc)
  var edits: [ContextEdit] = []

  init(
    scope: ContextScope, identifier: String? = nil, version: Int = 1,
    content: String = "", createdAt: Date = .now, updatedAt: Date = .now,
    project: Project? = nil, edits: [ContextEdit] = []
  ) {
    self.scope = scope
    self.identifier = identifier
    self.version = version
    self.content = content
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.project = project
    self.edits = edits
  }
}
