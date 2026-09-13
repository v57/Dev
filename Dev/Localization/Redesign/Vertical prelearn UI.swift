//
//  Vertical prelearn UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//

import SwiftUI

extension Translation.VerticalPrelearn {
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
  /// The stage exists so that lessons become possible: a slot the human already
  /// settled has no machine output on record, and nothing can be learned from a
  /// value the model never produced. So this page shows a source and the machine
  /// version being produced for it — never a translation anybody will read.
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
        "wand.and.stars"
      }
    }
    var body: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          Text("Prelearning \(operation.language)")
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity)
          Text("Machine versions of slots you already settled. They never replace your value — learn reads the difference.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
          ForEach(operation.items.enumerated(), id: \.offset) { (index, item) in
            HStack(alignment: .firstTextBaseline) {
              Image(systemName: icon).font(.title.bold()).frame(width: 32, height: 32)
                .opacity(operation.isCompleted || operation.isFailed ? 1 : 0.1)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.key).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Translation.VerticalTranslate.StringView(value: item.source)
                  .foregroundStyle(.secondary)
                  .font(.callout)
                if item.machine.isEmpty {
                  Text("…").foregroundStyle(.tertiary)
                } else {
                  Translation.VerticalTranslate.StringView(value: item.machine)
                    .fontWeight(.semibold)
                }
              }
            }.foregroundStyle(color).animation(.smooth.delay(Double(index) / 10), value: item)
          }
        }.padding(32)
      }.contentTransition(.symbolEffect)
    }
  }
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample

    /// Sample batches for the design preview: ten items each, in the three states a
    /// batch can be in.
    ///
    /// Every item is a slot a human already settled — that is the stage's whole
    /// predicate (`needsPrelearn`), so the only value here is the machine version the
    /// model produces for it. `resolve` writes that, and nothing else: no target, no
    /// status.
    static let sample: [Operations] = [
      // Done: the model has produced a version for every slot. These are the
      // "evidence" values learn will diff against the human's own.
      Operations(language: "ru", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title",
                  source: .value("Settings"), machine: .value("Параметры")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar",
                  source: .value("Save"), machine: .value("Сохранить изменения")),
        Operation(key: "button.cancel", index: 2, comment: "Dismisses the sheet without saving",
                  source: .value("Cancel"), machine: .value("Отменить")),
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short",
                  source: .value("Delete"), machine: .value("Удалить")),
        Operation(key: "sidebar.projects", index: 4, comment: "Sidebar section header",
                  source: .value("Projects"), machine: .value("Проекты")),
        Operation(key: "sidebar.sessions", index: 5, comment: "Sidebar section header",
                  source: .value("Sessions"), machine: .value("Сеансы")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка"),
                                                   Plural(rule: .few, value: "%d строки"),
                                                   Plural(rule: .many, value: "%d строк"),
                                                   Plural(rule: .other, value: "%d строки")]))),
        Operation(key: "files.selected", index: 7, comment: "Toolbar; how many files the export will include",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                                  Plural(rule: .other, value: "%d files selected")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d файл выбран"),
                                                   Plural(rule: .few, value: "%d файла выбрано"),
                                                   Plural(rule: .many, value: "%d файлов выбрано"),
                                                   Plural(rule: .other, value: "%d файла выбрано")]))),
        Operation(key: "selection.summary", index: 8, comment: "Status bar; how many strings are selected",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string selected"),
                                                  Plural(rule: .other, value: "%d strings selected")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка выбрана"),
                                                   Plural(rule: .few, value: "%d строки выбрано"),
                                                   Plural(rule: .many, value: "%d строк выбрано"),
                                                   Plural(rule: .other, value: "%d строки выбрано")]))),
        Operation(key: "export.progress", index: 9, comment: "Progress line while an export runs",
                  source: .value("Exporting %d of %d…"), machine: .value("Экспорт %d из %d…")),
      ], isCompleted: true),

      // Failed halfway: the first slots have a machine version, the rest were never
      // reached. That mixed state is what the view has to make obvious.
      Operations(language: "ja", items: [
        Operation(key: "alert.title", index: 10, comment: "Modal alert title",
                  source: .value("Something went wrong"), machine: .value("問題が発生しました")),
        Operation(key: "alert.retry", index: 11, comment: "Alert button",
                  source: .value("Try Again"), machine: .value("再試行")),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit",
                  source: .value("Hermes keeps your projects, sessions and translations in one place."),
                  machine: .value("Hermes はプロジェクト、セッション、翻訳を一か所にまとめます。")),
        Operation(key: "empty.state.hint", index: 13, comment: "Shown when a project has no catalog yet",
                  source: .value("No projects yet. Add one to get started."),
                  machine: .value("プロジェクトがまだありません。追加して始めましょう。")),
        Operation(key: "tabs.general", index: 14, comment: "First tab of the settings window",
                  source: .value("General"), machine: .value("一般")),
        Operation(key: "tabs.appearance", index: 15, comment: "Settings tab; theme and fonts",
                  source: .value("Appearance"), machine: .value("外観")),
        Operation(key: "tabs.advanced", index: 16, comment: "Settings tab; provider and routing options",
                  source: .value("Advanced")),
        Operation(key: "toggle.autoSave", index: 17, comment: "Settings switch",
                  source: .value("Save changes automatically")),
        Operation(key: "field.searchPlaceholder", index: 18, comment: "Search field in the browser toolbar",
                  source: .value("Search strings")),
        Operation(key: "label.widthLimit", index: 19, comment: "Field label; characters, as in the row menu",
                  source: .value("Width limit (characters)")),
      ], isFailed: true),

      // Untouched: nothing has a machine version yet, so every row shows the source
      // and the placeholder the reply will fill.
      Operations(language: "de", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title",
                  source: .value("Settings")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar",
                  source: .value("Save")),
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short",
                  source: .value("Delete")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")]))),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit",
                  source: .value("Hermes keeps your projects, sessions and translations in one place.")),
        Operation(key: "error.fileMissing", index: 20, comment: "Alert body; %@ is the catalog file name",
                  source: .value("The catalog %@ could not be found.")),
        Operation(key: "status.needsReview", index: 21, comment: "Row state badge",
                  source: .value("Needs Review")),
        Operation(key: "status.reviewed", index: 22, comment: "Row state badge",
                  source: .value("Reviewed")),
        Operation(key: "button.retry", index: 23, comment: "Recovery action under a failed operation",
                  source: .value("Retry")),
        Operation(key: "help.shortcutHint", index: 24, comment: "Tooltip under the search field",
                  source: .value("Press ⌘F to search")),
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
}

#Preview("Prelearn") {
  Translation.VerticalPrelearn.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
