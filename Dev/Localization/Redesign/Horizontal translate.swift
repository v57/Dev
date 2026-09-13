//
//  Horizontal translate.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import Foundation

extension Translation {
  /// One request per ROW, carrying EVERY language of that row.
  ///
  /// THIS IS A CROSS-LANGUAGE PASS, not a rules sweep and not a cheaper column pass.
  /// The column pass asks for a better translation per language; this one puts the
  /// whole row in view — including the columns a human has already verified — so the
  /// model can adapt machine output it produced earlier to what was settled, and
  /// catch the rows where its own output is an INVALID translation (a key whose
  /// meaning differs by language, which a per-language batch structurally cannot
  /// see: it never has two languages of the same key in front of it).
  ///
  /// A translate shape, not a rules sweep: there is no selection here. Every
  /// translatable row becomes one operation — a row with nothing authored sends its
  /// key as the content — and the payload is
  /// the whole row — settled (verified / imported) columns included, because a value
  /// this project has already committed to is the best evidence of the register and
  /// terminology it uses, and asking for it as well keeps the row's answer consistent
  /// across languages.
  ///
  /// What gets WRITTEN is decided when the reply is applied, not here: a slot whose
  /// status is `.verified` or `.imported` is never overwritten. Verified values are
  /// not editable in this pass.
  ///
  /// It is still a run of its own, separate from the vertical stages, because it
  /// sweeps the whole project — that makes it the expensive shape, and a
  /// project-document bump deliberately enqueues nothing, so a sweep is always
  /// something the user asked for.
  @Observable @MainActor class HorizontalTranslate {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    /// One pass over the rows: translatable, and with a source. Nothing else is
    /// asked — no version test, no per-language selection. The whole row travels,
    /// and the write-back is the only place a slot can be refused.
    /// Split by characters like every other stage: `Operations.split()`.
    private func scan() {
      var operations = Operations()
      for index in 0..<project.data.count {
        let item = project.data[index]
        guard item.translatable else { continue }
        // No selection, and no "row has no source" case either: a row with nothing
        // authored sends its KEY as the content (`item.content`).
        operations.items
          .append(Operation(key: item.key, index: index, comment: item.comment, maxWidth: item.maxWidth, source: item.content, targets: item.targets))
      }
      self.operations = operations.split()
    }
    struct Operations {
      var items: [Operation] = []
      var isCompleted = false
      var isFailed = false
      func split() -> [Operations] {
        var operations = [Operations]()
        var current = Operations()
        var size = 0
        let maxSize = Limits.batch
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
    struct Operation: RowOperation, Identifiable, Hashable {
      var id: String { key }
      let key: String
      let index: Int
      let comment: String
      let maxWidth: Int
      let source: StringBody
      /// EVERY language of this row, in column order — the ones that need work and
      /// the settled ones. A verified value is the best register sample this project
      /// can offer for this string, and asking for it keeps the row's answer
      /// consistent; it is context, not a target.
      var targets: [LocalizationString]
      var stage: Stage { .horizontal }
      /// The write-back, as a value the design preview can watch: only slots that
      /// NEED work are written. A `.verified` or `.imported` value is context and is
      /// left exactly as it was found, whatever the reply said about it.
      consuming func resolve(_ value: StringBody) -> Self {
        for index in targets.indices where targets[index].needsMachineTranslate {
          targets[index].target = value
          targets[index].status = .translated
        }
        return self
      }
    }
  }
}
