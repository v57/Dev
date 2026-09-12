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
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        for item in row.targets {
          guard let reviewed = item.toLearn else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(index: index, comment: row.comment, source: row.source, machine: item.target, target: reviewed))
        }
      }
      self.operations = byLanguages.values.flatMap { $0.split() }
    }
    struct Operations {
      let language: String
      var items: [Operation] = []
      func split() -> [Operations] {
        var operations = [Operations]()
        var current = Operations(language: language)
        var size = 0
        let maxSize = 20_000
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
    struct Operation: VerticalOperation {
      let index: Int
      let comment: String
      let source: StringBody
      let machine: StringBody
      let target: StringBody // User reviewed
    }
  }
}
