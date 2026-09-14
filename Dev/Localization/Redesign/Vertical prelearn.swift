//
//  Vertical prelearn.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation {
  /// When a human settled a slot but there is NO machine output on record, there is
  /// nothing to diff and nothing can be learned. This stage asks the model for the
  /// machine version of the SOURCE first, so that `VerticalLearn` has something to
  /// compare the human's value against and can improve its translation context.
  @Observable @MainActor class VerticalPrelearn {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    /// One document per language, so one batch per language: the L1 block (target
    /// language, its lesson document, the register sample) is what the provider
    /// cache is keyed on, and mixing languages in one request would throw it away.
    ///
    /// Writes `machine` ONLY. Never `target`, never `status`: the human settled
    /// this slot, so the machine value is evidence for `learn`, not a translation.
    ///
    /// The row must be a row of the OPEN CATALOG (4.8) as well as translatable: a row
    /// that is not one is not work here even if it reached `project.data` by another
    /// path — this is the stage the reader saw stale keys in. The answer is the row's
    /// OWN flag, set where the row was built, so this scan asks the row and never the
    /// store or the file.
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        guard row.isCatalogRow, row.translatable else { continue }
        for item in row.targets {
          guard item.needsPrelearn else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(key: row.key, index: index, comment: row.comment, source: row.content))
        }
      }
      // ONE group per language, in language order: this scan's order IS the run's
      // batch order — the runner numbers a batch by its ordinal, its pages page by
      // that ordinal, and a paused run's cursor counts those batches (5.6) — so it
      // may not depend on a Dictionary's iteration order. The items INSIDE a group
      // stay in catalog order, which is the order they were appended in.
      self.operations = byLanguages.keys.sorted().flatMap { byLanguages[$0]?.split() ?? [] }
    }
    struct Operations {
      let language: String
      var items: [Operation] = []
      var isCompleted = false
      var isFailed = false
      /// Sized by CHARACTERS, never by count (4.4): items join a batch until the
      /// next one would cross `Limits.batch`, an item that alone exceeds the budget
      /// gets a request of its own (a batch always takes at least one item, so
      /// nothing is ever skipped), and an item that crosses the line starts the NEXT
      /// batch rather than being dropped between the two.
      func split() -> [Operations] {
        var operations = [Operations]()
        var current = Operations(language: language)
        var size = 0
        let maxSize = Limits.batch
        for item in self.items {
          let chars = item.characters
          if chars >= maxSize {
            if !current.items.isEmpty {
              operations.append(current)
              current = Operations(language: language)
              size = 0
            }
            operations.append(Operations(language: language, items: [item]))
          } else if size + chars > maxSize {
            // `size` is only ever non-zero with a non-empty `current`, so the batch
            // being closed here has at least one item — and the item that did not
            // fit STARTS the next batch rather than being dropped between the two.
            operations.append(current)
            current = Operations(language: language, items: [item])
            size = chars
          } else {
            current.items.append(item)
            size += chars
          }
        }
        if !current.items.isEmpty {
          operations.append(current)
        }
        return operations
      }
    }
    /// `target` is `.empty` on purpose: prelearn has no expected value, it asks
    /// the model to produce the machine version of the source. The reply is
    /// written to the slot's `machine`, never to its `target`.
    struct Operation: VerticalOperation, Identifiable, Hashable {
      var id: String { key }
      let key: String
      let index: Int
      let comment: String
      let source: StringBody
      let target: StringBody = .empty
      /// The machine version of the source — what this stage actually WRITES. It is
      /// the evidence `learn` compares the human's value against, and it never
      /// touches `target` or `status`: the human owns the value.
      var machine: StringBody = .empty
      /// Where THIS row is in the run's life, filled by `RunBinding` from the batch's own
      /// `Run.Item` (8.1, "stage pages"). A page marks a row from the ROW's state and never from
      /// the batch's, because a batch that wrote some of its rows IS applied and the rows that
      /// went wrong are the only thing that carries the failure. `.pending` is a row nothing has
      /// been asked about yet.
      var phase: Translation.Run.Phase = .pending
      var stage: Stage { .prelearn }
      consuming func resolve(_ machine: StringBody) -> Self {
        self.machine = machine
        return self
      }
    }
  }
}
