//
//  Vertical prelearn.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation {
  /// When translation is marked as reviewed but there is no record of machine translation result nothing can be learned for llm.
  /// So it will find translate those fields first, then `VerticalLearn` will compare them and improve its translation context
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
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        guard row.translatable else { continue }
        for item in row.targets {
          guard item.needsPrelearn else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(key: row.key, index: index, comment: row.comment, source: row.content))
        }
      }
      self.operations = byLanguages.values.flatMap { $0.split() }
    }
    struct Operations {
      let language: String
      var items: [Operation] = []
      var isCompleted = false
      var isFailed = false
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
            operations.append(current)
            current = Operations(language: language)
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
      var stage: Stage { .prelearn }
      consuming func resolve(_ machine: StringBody) -> Self {
        self.machine = machine
        return self
      }
    }
  }
}
