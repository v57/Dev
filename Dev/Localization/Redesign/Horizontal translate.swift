//
//  Horizontal translate.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import Foundation

extension Translation {
  @Observable @MainActor class HorizontalTranslate {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    private func scan() {
      var operations = Operations()
      for index in 0..<project.data.count {
        let item = project.data[index]
        guard item.needsMachineTranslate else { continue }
        let targets = item.targets.map { LocalizationString(language: $0.language, machine: $0.machine, reviewed: $0.target) }
        operations.items
          .append(Operation(index: index, comment: item.comment, maxWidth: item.maxWidth, source: item.source, targets: targets))
      }
      self.operations = operations.split()
    }
    struct Operations {
      var items: [Operation] = []
      func split() -> [Operations] {
        var operations = [Operations]()
        var current = Operations()
        var size = 0
        let maxSize = 20_000
        for item in self.items {
          let chars = item.characters
          if chars >= maxSize {
            if !current.items.isEmpty {
              operations.append(current)
              current = Operations()
              size = 0
            }
            operations.append(Operations(items: [item]))
          } else if size + chars > maxSize {
            operations.append(current)
            current = Operations()
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
    struct Operation {
      let index: Int
      let comment: String
      let maxWidth: Int
      let source: StringBody
      let targets: [LocalizationString]
      var characters: Int { source.characters * targets.count }
    }
    struct LocalizationString {
      let language: String
      var machine: StringBody = .empty
      var reviewed: StringBody = .empty
    }
  }
}
