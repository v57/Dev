//
//  ContextEdit.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// Audit row for every ContextDoc change. The autonomous learning engine
/// rewrites/extends context with OVERRIDE authority; each such change MUST
/// write a ContextEdit carrying the model's reason, keeping human-curated
/// glossary recoverable. Human glossary edits are recorded with
/// author == .manual.
@Model final class ContextEdit {
  /// The context document this edit belongs to.
  var contextDoc: ContextDoc?
  /// Content before the change; nil when the document was just created.
  var before: String?
  /// Content after the change.
  var after: String
  /// Why the change was made — required for autonomous overrides.
  var reason: String
  /// What made the change: the authoring model, or .manual for a human.
  var author: Provider
  /// When the change was made.
  var createdAt: Date

  init(
    contextDoc: ContextDoc? = nil, before: String? = nil, after: String = "",
    reason: String = "", author: Provider = .manual, createdAt: Date = .now
  ) {
    self.contextDoc = contextDoc
    self.before = before
    self.after = after
    self.reason = reason
    self.author = author
    self.createdAt = createdAt
  }
}
