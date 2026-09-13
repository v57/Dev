//
//  Vertical translate.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation {
  @Observable @MainActor class VerticalTranslate {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    /// One pass over the rows as they stood when the stage was built. A slot is
    /// work when it is empty or STALE — a language-document bump is exactly what
    /// makes the rest of a column stale, so dropping `.stale` here would silently
    /// lose the lesson — and when its row is translatable.
    ///
    /// There is no "row has no source" case: a row with nothing authored sends its
    /// KEY as the content (`row.content`).
    ///
    /// Split per language: one request carries one language's L1 block, and the
    /// item order inside a batch is the catalog's order.
    private func scan() {
      var byLanguages = [String: Operations]()
      for index in 0..<project.data.count {
        let row = project.data[index]
        guard row.translatable else { continue }
        for item in row.targets {
          guard item.needsMachineTranslate else { continue }
          byLanguages[item.language, default: Operations(language: item.language)].items
            .append(Operation(key: row.key, index: index, comment: row.comment, maxWidth: row.maxWidth, source: row.content, target: item.target))
        }
      }
      self.operations = byLanguages.values.flatMap { $0.split() }
    }
    struct Operations {
      let language: String
      var items: [Operation] = []
      var isCompleted = false
      var isFailed = false
      init(language: String, items: [Operation] = []) {
        self.language = language
        self.items = items
      }
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
    /// What one slot of a vertical batch sends, and what its reply is applied to.
    ///
    /// On the wire for this stage, per item: `comment`, `maxWidth`, `source` and
    /// `target`. The key is NOT sent — it never matters to the translation — so the
    /// id the model echoes back is the item's position in the batch, and the key
    /// stays here to apply the reply, address memory and journal the edit.
    ///
    /// `target` is the current value when there is one, or the empty plural skeleton
    /// of the target language when there is not.
    struct Operation: VerticalOperation, Identifiable, Hashable {
      var id: String { key }
      /// Catalog key. The reply is matched by id, and the memory and the journal
      /// address the row by this — never by `index`.
      let key: String
      let index: Int
      let comment: String
      let maxWidth: Int
      let source: StringBody
      var target: StringBody
      var stage: Stage { .vertical }
      consuming func resolve(_ target: StringBody) -> Self {
        self.target = target
        return self
      }
    }
  }
}
