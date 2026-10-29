//
//  TranslationStore.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

/// What one clear of the translation store removed, per model (Design notes 7.5).
///
/// Per MODEL, not as one total: what a table held is the only evidence that a
/// clear ran at all — an empty store is otherwise indistinguishable from a store
/// nothing ever wrote to — so this is what the button reports back.
struct StoreClearCounts: Equatable {
  var slots = 0
  var journal = 0
  var contextDocs = 0
  var contextEdits = 0
  var memory = 0
  var cursors = 0

  /// Every row the clear removed.
  var removed: Int { slots + journal + contextDocs + contextEdits + memory + cursors }

  /// True when there was nothing to delete — the second press of the button.
  var isEmpty: Bool { removed == 0 }

  /// One line naming every table, in the order 7.5 lists them.
  var summary: String {
    [
      "\(slots) slot record\(slots == 1 ? "" : "s")",
      "\(journal) journal row\(journal == 1 ? "" : "s")",
      "\(contextDocs) context document\(contextDocs == 1 ? "" : "s")",
      "\(contextEdits) context edit\(contextEdits == 1 ? "" : "s")",
      "\(memory) memory \(memory == 1 ? "entry" : "entries")",
      "\(cursors) run cursor\(cursors == 1 ? "" : "s")",
    ].joined(separator: ", ")
  }
}

