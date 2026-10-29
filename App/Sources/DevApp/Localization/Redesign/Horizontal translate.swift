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
  /// key as the content — and the payload is the whole row, settled (verified /
  /// imported) columns included, because a value this project has already committed
  /// to is the best evidence of the register and terminology it uses, and asking for
  /// it as well keeps the row's answer consistent across languages.
  ///
  /// What gets WRITTEN is decided when the reply is applied, not here: a slot whose
  /// status is `.verified` or `.imported` is never overwritten. Verified values are
  /// not editable in this pass.
  ///
  /// Every declaration here is the pass's contract, not the write-back: a stage
  /// says WHAT to send, `Runner` is the only thing that writes a slot (5.5).
  ///
  /// It is the LAST step of a translate run and always on (4.2): the rows with
  /// something settled in them are exactly where it has work to do, so after a
  /// verification session pressing the one button again is how the corrections
  /// reach the rest of the project — the columns have nothing left to redo
  /// (verified slots are not work), and this step carries them across. A run of
  /// this stage alone (`Stage.horizontal`) is the paid sweep a changed project
  /// rule asks for, because a project-document bump deliberately enqueues nothing
  /// (2.3) and a sweep is therefore always something the user asked for.
  @Observable @MainActor class HorizontalTranslate {
    var index: Int = 0
    var operations = [Operations]()
    let project: Project
    init(project: Project) {
      self.project = project
      scan()
    }
    /// One pass over the rows: `translatable`, the 4.7 eligibility test on the
    /// CONTENT, and the 4.8 universe test on the ROW — NOTHING ELSE (4.6). Two rows
    /// are not sent — a row with no language at all, which has no work to express and
    /// would expand to an empty batch, and a row whose content holds no English
    /// character (4.7): a leaked `%d - %d`, a bare number, a bullet, an em dash has no
    /// prose to translate, and no column of it needs adapting. No version test, no
    /// per-language filter, no "the row has no source" case either — a row with nothing
    /// authored sends its KEY as the content (4.3). A row with a settled column and
    /// columns that need work is sent exactly like any other.
    ///
    /// A row that is not a row of the OPEN CATALOG is not work here (4.8), even if it
    /// reached `project.data` by another path — a hand-built data set, a preview, a
    /// caller the redesign has not met yet. That answer comes from the row's OWN flag,
    /// set where the row was built: this scan asks the row, never the store and never
    /// the file.
    ///
    /// Nothing here decides what may be written, and nothing here writes: the
    /// settled columns travel because their values are the reference this request
    /// exists for, and what a reply may touch is decided per slot when it is
    /// applied. Split by characters like every other stage: `Operations.split()`.
    private func scan() {
      var operations = Operations()
      for index in 0..<project.data.count {
        let item = project.data[index]
        guard item.isCatalogRow, item.translatable, item.hasEnglishCharacters else { continue }
        // A row with NO language at all is SKIPPED (reader, 2026-09-14): it has
        // nothing to carry and nothing to write, and it would expand to a batch with
        // zero items — a request whose item list is empty.
        guard !item.targets.isEmpty else { continue }
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
        let maxSize = Limits.batch / 4
        for item in self.items {
          let chars = item.characters
          // A batch always takes at least one item, so a source that is over the budget
          // by itself gets a request of its own and NO row is ever skipped (4.4).
          if chars >= maxSize {
            if !current.items.isEmpty {
              operations.append(current)
              current = Operations()
              size = 0
            }
            operations.append(Operations(items: [item]))
          } else if size + chars > maxSize {
            // The item that did not fit STARTS the next batch: `size` is only ever
            // non-zero with a non-empty `current`, so the batch closed here has at least
            // one item, and the item that overflowed is carried over rather than dropped.
            operations.append(current)
            current = Operations(items: [item])
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
      /// Where THIS ROW is in the run's life, filled by `RunBinding` from the row's OWN items
      /// (8.1, "stage pages"): the row page's item is a row, so this is the narrowest reading the
      /// page needs — failed when any column of it failed, written when any was written, and
      /// otherwise the batch's own phase, because a row whose every column is context has
      /// nothing of its own to report. A page marks a row from the ROW's state and never from the
      /// batch's, because a batch that wrote some of its rows IS applied.
      var phase: Translation.Run.Phase = .pending
      var stage: Stage { .horizontal }
      /// The write-back, as a value the design preview can watch — the app's own
      /// write-back is `Runner.apply`, which is the only writer of a slot (5.5).
      ///
      /// The set it may touch is the slot's OWN status and nothing else, so a
      /// `.verified` or `.imported` column is left exactly as it was found,
      /// whatever the reply said about it (4.6). `.translated` IS in that set:
      /// adapting machine output this run produced earlier to what the row's
      /// settled columns say is the pass's whole purpose, and a `.translated`
      /// column is exactly that output — a work predicate that excludes it would
      /// leave the one column the pass exists to adjust untouched.
      consuming func resolve(_ value: StringBody) -> Self {
        for index in targets.indices where Run.writable(targets[index].status) {
          targets[index].target = value
          targets[index].status = .translated
        }
        return self
      }
    }
  }
}
