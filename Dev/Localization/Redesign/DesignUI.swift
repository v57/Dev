//
//  DesignUI.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation.VerticalTranslate {
  struct Content: View {
    let index: Int
    let operations: [Operations]
    @State var scrollPosition: Int?
    var body: some View {
      GeometryReader { view in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 0) {
            ForEach(operations.enumerated(), id: \.offset) { (offset, element) in
              OperationContent(operation: element).frame(width: view.size.width, height: view.size.height)
            }
          }.scrollTargetLayout()
        }.scrollTargetBehavior(.paging).scrollPosition(id: $scrollPosition, anchor: .center)
      }.task(id: index) {
        withAnimation(.smooth) {
          scrollPosition = index
        }
      }
    }
  }
  struct OperationContent: View {
    let operation: Operations
    var color: Color {
      if operation.isFailed {
        .red
      } else if operation.isCompleted {
        .green
      } else {
        .primary
      }
    }
    var icon: String {
      if operation.isFailed {
        "xmark.circle.fill"
      } else if operation.isCompleted {
        "checkmark.circle.fill"
      } else {
        "translate"
      }
    }
    var body: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          Text("Translating to \(operation.language)")
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity)
          ForEach(operation.items.enumerated(), id: \.offset) { (index, item) in
            HStack {
              Image(systemName: icon).font(.title.bold()).frame(width: 32, height: 32)
                .opacity(operation.isCompleted || operation.isFailed ? 1 : 0.1)
              StringView(value: operation.isCompleted ? item.target : item.source)
                .fontWeight(operation.isCompleted ? .semibold : .regular)
                .contentTransition(.numericText())
            }.foregroundStyle(color).animation(.smooth.delay(Double(index) / 10), value: item)
          }
        }.padding(32)
      }.contentTransition(.symbolEffect)
    }
  }
  struct StringView: View {
    let value: Translation.StringBody
    var body: some View {
      switch value {
      case .value(let value):
        Text(value)
      case .plural(let value):
        VStack(alignment: .leading) {
          ForEach(value.values, id: \.rule) { plural in
            Text(plural.rule.rawValue).foregroundStyle(.secondary).font(.caption)
            Text(plural.value)
          }
        }
      }
    }
  }
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample

    /// Sample batches for the design preview: ten items each, one batch of every
    /// shape the view has to lay out — a settled column, a character-budget split
    /// (same language twice), a six-form language, a failure, and an untouched one.
    ///
    /// A catalog key keeps the SAME `index` in every language batch it appears in,
    /// because the index is the row's position in `project.data` and the batches of
    /// the other languages cover the same rows.
    ///
    /// The preview's fake run reverses each source (`reversed()`) and marks the batch
    /// completed, so a seeded `target` is the BEFORE value — the settled and failed
    /// batches carry one, the pending ones do not. Everything else starts `.empty`,
    /// which is also what `VerticalTranslate.scan()` produces for work to do.
    static let sample: [Operations] = [
      // Settled: every slot filled, nothing to watch. Russian carries FOUR plural
      // forms where the source has two.
      Operations(language: "ru", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title", maxWidth: 0,
                  source: .value("Settings"), target: .value("Настройки")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar", maxWidth: 12,
                  source: .value("Save"), target: .value("Сохранить")),
        Operation(key: "button.cancel", index: 2, comment: "Dismisses the sheet without saving", maxWidth: 12,
                  source: .value("Cancel"), target: .value("Отмена")),
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short", maxWidth: 8,
                  source: .value("Delete"), target: .value("Удалить")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка"),
                                                  Plural(rule: .few, value: "%d строки"),
                                                  Plural(rule: .many, value: "%d строк"),
                                                  Plural(rule: .other, value: "%d строки")]))),
        Operation(key: "files.selected", index: 7, comment: "Toolbar; how many files the export will include", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                                  Plural(rule: .other, value: "%d files selected")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d файл выбран"),
                                                  Plural(rule: .few, value: "%d файла выбрано"),
                                                  Plural(rule: .many, value: "%d файлов выбрано"),
                                                  Plural(rule: .other, value: "%d файла выбрано")]))),
        Operation(key: "selection.summary", index: 8, comment: "Status bar; how many strings are selected", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string selected"),
                                                  Plural(rule: .other, value: "%d strings selected")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка выбрана"),
                                                  Plural(rule: .few, value: "%d строки выбрано"),
                                                  Plural(rule: .many, value: "%d строк выбрано"),
                                                  Plural(rule: .other, value: "%d строки выбрано")]))),
        Operation(key: "export.progress", index: 9, comment: "Progress line while an export runs", maxWidth: 0,
                  source: .value("Exporting %d of %d…"), target: .value("Экспорт %d из %d…")),
        Operation(key: "alert.title", index: 10, comment: "Modal alert title", maxWidth: 0,
                  source: .value("Something went wrong"), target: .value("Что-то пошло не так")),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit", maxWidth: 0,
                  source: .value("Hermes keeps your projects, sessions and translations in one place."),
                  target: .value("Hermes хранит проекты, сеансы и переводы в одном месте.")),
      ]),

      // The same language again: this is what a character-budget split looks like —
      // the second batch of a column. One slot is stale rather than empty (it has a
      // value and is being re-translated), the rest are new.
      Operations(language: "ru", items: [
        Operation(key: "empty.state.hint", index: 13, comment: "Shown when a project has no catalog yet", maxWidth: 0,
                  source: .value("No projects yet. Add one to get started."), target: .empty),
        Operation(key: "tabs.general", index: 14, comment: "First tab of the settings window", maxWidth: 0,
                  source: .value("General"), target: .empty),
        Operation(key: "tabs.appearance", index: 15, comment: "Settings tab; theme and fonts", maxWidth: 0,
                  source: .value("Appearance"), target: .empty),
        Operation(key: "tabs.advanced", index: 16, comment: "Settings tab; provider and routing options", maxWidth: 0,
                  source: .value("Advanced"), target: .empty),
        Operation(key: "toggle.autoSave", index: 17, comment: "Settings switch", maxWidth: 0,
                  source: .value("Save changes automatically"), target: .empty),
        Operation(key: "field.searchPlaceholder", index: 18, comment: "Search field in the browser toolbar", maxWidth: 16,
                  source: .value("Search strings"), target: .empty),
        Operation(key: "label.widthLimit", index: 19, comment: "Field label; characters, as in the row menu", maxWidth: 0,
                  source: .value("Width limit (characters)"), target: .empty),
        Operation(key: "error.fileMissing", index: 20, comment: "Alert body; %@ is the catalog file name", maxWidth: 0,
                  source: .value("The catalog %@ could not be found."), target: .empty),
        // Stale: the value predates the project rules, so it is work again.
        Operation(key: "status.needsReview", index: 21, comment: "Row state badge", maxWidth: 0,
                  source: .value("Needs Review"), target: .value("Требует проверки")),
        Operation(key: "status.reviewed", index: 22, comment: "Row state badge", maxWidth: 0,
                  source: .value("Reviewed"), target: .value("Проверено")),
      ]),

      // Arabic: six plural forms. One slot is a bare skeleton built by
      // `Plurals(language:)`, the other is PARTIALLY filled — the shape the view has
      // to render while a wide form set is still being worked through.
      Operations(language: "ar", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title", maxWidth: 0,
                  source: .value("Settings"), target: .value("الإعدادات")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar", maxWidth: 12,
                  source: .value("Save"), target: .value("حفظ")),
        // Stale rather than empty: it has a value and is being re-translated.
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short", maxWidth: 8,
                  source: .value("Delete"), target: .value("حذف")),
        Operation(key: "files.selected", index: 7, comment: "Toolbar; how many files the export will include", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                                  Plural(rule: .other, value: "%d files selected")])),
                  target: .plural(Plurals(array: [Plural(rule: .zero, value: "لا ملفات محددة"),
                                                  Plural(rule: .one, value: "ملف واحد محدد"),
                                                  Plural(rule: .two, value: "ملفان محددان"),
                                                  Plural(rule: .few, value: ""),
                                                  Plural(rule: .many, value: ""),
                                                  Plural(rule: .other, value: "%d ملف محدد")]))),
        Operation(key: "selection.summary", index: 8, comment: "Status bar; how many strings are selected", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string selected"),
                                                  Plural(rule: .other, value: "%d strings selected")])),
                  target: .plural(Plurals(language: "ar"))),
        Operation(key: "export.progress", index: 9, comment: "Progress line while an export runs", maxWidth: 0,
                  source: .value("Exporting %d of %d…"), target: .empty),
        Operation(key: "alert.title", index: 10, comment: "Modal alert title", maxWidth: 0,
                  source: .value("Something went wrong"), target: .value("حدث خطأ ما")),
        Operation(key: "alert.retry", index: 11, comment: "Alert button", maxWidth: 8,
                  source: .value("Try Again"), target: .empty),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit", maxWidth: 0,
                  source: .value("Hermes keeps your projects, sessions and translations in one place."), target: .empty),
        Operation(key: "empty.state.hint", index: 13, comment: "Shown when a project has no catalog yet", maxWidth: 0,
                  source: .value("No projects yet. Add one to get started."), target: .empty),
      ]),

      // A failed batch: a run keeps its other results, so the view needs a failure
      // it can render — and that means PARTIAL output, some slots written, some
      // never reached. Japanese has a single plural form where the source has two.
      Operations(language: "ja", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title", maxWidth: 0,
                  source: .value("Settings"), target: .value("設定")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar", maxWidth: 12,
                  source: .value("Save"), target: .value("保存")),
        Operation(key: "button.cancel", index: 2, comment: "Dismisses the sheet without saving", maxWidth: 12,
                  source: .value("Cancel"), target: .value("キャンセル")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")])),
                  target: .plural(Plurals(array: [Plural(rule: .other, value: "%d件")]))),
        Operation(key: "files.selected", index: 7, comment: "Toolbar; how many files the export will include", maxWidth: 0,
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                                  Plural(rule: .other, value: "%d files selected")])),
                  target: .plural(Plurals(language: "ja"))),
        Operation(key: "export.progress", index: 9, comment: "Progress line while an export runs", maxWidth: 0,
                  source: .value("Exporting %d of %d…"), target: .empty),
        Operation(key: "alert.title", index: 10, comment: "Modal alert title", maxWidth: 0,
                  source: .value("Something went wrong"), target: .value("問題が発生しました")),
        Operation(key: "alert.retry", index: 11, comment: "Alert button", maxWidth: 8,
                  source: .value("Try Again"), target: .value("再試行")),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit", maxWidth: 0,
                  source: .value("Hermes keeps your projects, sessions and translations in one place."), target: .empty),
        Operation(key: "tabs.general", index: 14, comment: "First tab of the settings window", maxWidth: 0,
                  source: .value("General"), target: .value("一般")),
      ]),

      // The ordinary case: a column nobody has touched. Two slots are stale rather
      // than empty, and the plural slot arrived as a skeleton.
      Operations(language: "de", items: [
        Operation(key: "tabs.general", index: 14, comment: "First tab of the settings window", maxWidth: 0,
                  source: .value("General"), target: .empty),
        Operation(key: "tabs.appearance", index: 15, comment: "Settings tab; theme and fonts", maxWidth: 0,
                  source: .value("Appearance"), target: .empty),
        Operation(key: "tabs.advanced", index: 16, comment: "Settings tab; provider and routing options", maxWidth: 0,
                  source: .value("Advanced"), target: .empty),
        Operation(key: "toggle.autoSave", index: 17, comment: "Settings switch", maxWidth: 0,
                  source: .value("Save changes automatically"), target: .empty),
        Operation(key: "field.searchPlaceholder", index: 18, comment: "Search field in the browser toolbar", maxWidth: 16,
                  source: .value("Search strings"), target: .empty),
        Operation(key: "label.widthLimit", index: 19, comment: "Field label; characters, as in the row menu", maxWidth: 0,
                  source: .value("Width limit (characters)"), target: .empty),
        Operation(key: "error.fileMissing", index: 20, comment: "Alert body; %@ is the catalog file name", maxWidth: 0,
                  source: .value("The catalog %@ could not be found."), target: .empty),
        Operation(key: "status.needsReview", index: 21, comment: "Row state badge", maxWidth: 0,
                  source: .value("Needs Review"), target: .value("Prüfung nötig")),
        Operation(key: "status.reviewed", index: 22, comment: "Row state badge", maxWidth: 0,
                  source: .value("Reviewed"), target: .value("Geprüft")),
        Operation(key: "help.shortcutHint", index: 24, comment: "Tooltip under the search field", maxWidth: 0,
                  source: .value("Press ⌘F to search"), target: .empty),
      ]),
    ]

    var body: some View {
      Content(index: index, operations: operations)
        .task {
          do {
            for i in 0..<operations.count {
              withAnimation {
                index = i
              }
              try await Task.sleep(for: .seconds(2))
              withAnimation {
                operations[i].items = operations[i].items.map { $0.resolve($0.source.reversed()) }
                operations[i].isCompleted = true
              }
              try await Task.sleep(for: .seconds(1))
            }
          } catch { }
        }
    }
  }
  struct OperationsView: View {
    @Environment(Translation.HorizontalTranslate.self) var translate
    let operations: Translation.HorizontalTranslate.Operations
    var body: some View {
      
    }
  }
}

extension Translation.StringBody {
  func reversed() -> Self {
    switch self {
    case .value(let value): .value(String(value.reversed()))
    case .plural(let value): .plural(value.reversed())
    }
  }
}
extension Plurals {
  consuming func reversed() -> Self {
    values = values.map { Plural(rule: $0.rule, value: String($0.value.reversed())) }
    return self
  }
}

#Preview {
  Translation.VerticalTranslate.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
