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
    /// These rows teach, they are not translated: the stage writes the language
    /// document and memory, and never a slot's value or status.
    ///
    /// The comparison it feeds on is machine output vs the human's value — that
    /// delta is the lesson. A slot the model already got right
    /// (`machine == target`) has nothing to teach and `toLearn` drops it.
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        guard row.translatable else { continue }
        for item in row.targets {
          guard let reviewed = item.toLearn else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(key: row.key, index: index, comment: row.comment, source: row.content, machine: item.machine, target: reviewed))
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
      var stage: Stage { .learn }
    }
  }
}
