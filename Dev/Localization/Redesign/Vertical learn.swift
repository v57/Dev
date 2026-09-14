//
//  Vertical learn.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation {
  @Observable @MainActor class VerticalLearn {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    /// One pass over the rows as they stood when the stage was built: the slots a
    /// human settled that the model has something to answer for (`toLearn`, 2.4)
    /// and whose row is translatable AND a row of the OPEN CATALOG (4.8). A row that
    /// is not one is not work here even if it reached `project.data` by another path —
    /// a hand-built data set, a preview, a future caller — and the answer is the row's
    /// OWN flag, set where the row was built: this scan asks the row, never the store
    /// and never the file.
    ///
    /// These rows teach, they are not translated: the lesson IS the delta between
    /// the model's attempt and the human's value, so a slot the model already got
    /// right (`machine == target`) has nothing to teach and is dropped, and so is
    /// one that has not moved since a human confirmed it (`reviewed == target`).
    ///
    /// Nothing here writes: no slot's value, no slot's status, no document and no
    /// memory entry — the batch is the whole output. The fold's write-back belongs
    /// to the runner (`Runner.fold`), because a second writer would append the same
    /// lesson lines twice and bump the language document's version twice, and the
    /// version bump is what marks the rest of the column stale (3.5, 3.6).
    ///
    /// Split per language: one request carries one language's L1 block, and the
    /// item order inside a batch is the catalog's order.
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        guard row.isCatalogRow, row.translatable else { continue }
        for item in row.targets {
          // `toLearn` answers the value to fold in — the human's `target` — or nil when
          // the slot has nothing to teach.
          guard let lesson = item.toLearn else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(key: row.key, index: index, comment: row.comment, source: row.content, machine: item.machine, target: lesson))
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
      /// What the stage's own UI needs beside the language (`Vertical learn UI.swift`
      /// builds its demo groups with the two flags), defaulted so a fresh batch starts
      /// unsettled.
      init(
        language: String, items: [Operation] = [], isCompleted: Bool = false,
        isFailed: Bool = false
      ) {
        self.language = language
        self.items = items
        self.isCompleted = isCompleted
        self.isFailed = isFailed
      }
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
            // being closed here has at least one item.
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
    /// What one slot of a learn batch sends, and what the lesson is about.
    ///
    /// `machine` is the model's own attempt (`item.machine`, never `item.target` —
    /// 2.6: the target here is the human's value, so passing it as the machine body
    /// would compare the value with itself and teach nothing), and `target` is the
    /// value the human settled on, which is the line the fold folds in (6.2). The
    /// key travels with them: the reply is document text rather than a per-id map,
    /// so the key is what names the lesson line, not something the model echoes.
    struct Operation: VerticalOperation, Identifiable, Hashable {
      var id: String { key }
      let key: String
      let index: Int
      let comment: String
      let source: StringBody
      /// What the model produced for this slot.
      let machine: StringBody
      /// What the human settled on — the lesson's target.
      let target: StringBody
      /// Where THIS row is in the run's life, filled by `RunBinding` from the batch's own
      /// `Run.Item` (8.1, "stage pages"). A page marks a row from the ROW's state and never from
      /// the batch's, because a batch that wrote some of its rows IS applied and the rows that
      /// went wrong are the only thing that carries the failure. `.pending` is a row nothing has
      /// been asked about yet.
      var phase: Translation.Run.Phase = .pending
      var stage: Stage { .learn }
    }
  }
}
