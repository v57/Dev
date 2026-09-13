//
//  Vertical learn UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//

import SwiftUI

extension Translation.VerticalLearn {
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
  /// A lesson is a DIFFERENCE: what the model produced against what the human
  /// settled on. There is no value to watch being written here — the output of this
  /// stage is a line in the language document, so each row shows the lesson and the
  /// line it becomes.
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
        "graduationcap"
      }
    }
    var body: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          Text("Learning \(operation.language)")
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity)
          Text("Your corrections against the model's own output. They fold into the language document and memory — never into a value.")
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Translation.VerticalTranslate.StringView(value: item.machine)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                  Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                  Translation.VerticalTranslate.StringView(value: item.target)
                    .fontWeight(.semibold)
                }
                // The line this lesson becomes in the language document:
                // KEY, SOURCE, VALUE, tab separated.
                if operation.isCompleted {
                  Text("\(item.key)\t\(item.source.catalogValue)\t\(item.target.catalogValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
                }
              }
            }.foregroundStyle(color).animation(.smooth.delay(Double(index) / 10), value: operation.isCompleted)
          }
        }.padding(32)
      }.contentTransition(.symbolEffect)
    }
  }
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample

    /// Sample batches for the design preview: ten lessons each, in the three states a
    /// fold can be in.
    ///
    /// Every item is a REAL lesson predicate (`toLearn`): the slot is verified, has
    /// machine output on record, and the machine value DIFFERS from the human's —
    /// a slot the model already got right teaches nothing, so none of these agree.
    /// The differences are the kinds this app actually produces: terminology,
    /// length against a width limit, form for a button, register, plural wording.
    static let sample: [Operations] = [
      // Folded: every lesson has landed in the document.
      Operations(language: "ru", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title",
                  source: .value("Settings"), machine: .value("Параметры"), target: .value("Настройки")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar",
                  source: .value("Save"), machine: .value("Сохранить изменения"), target: .value("Сохранить")),
        Operation(key: "button.cancel", index: 2, comment: "Dismisses the sheet without saving",
                  source: .value("Cancel"), machine: .value("Отменить"), target: .value("Отмена")),
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short",
                  source: .value("Delete"), machine: .value("Удалить безвозвратно"), target: .value("Удалить")),
        Operation(key: "sidebar.projects", index: 4, comment: "Sidebar section header",
                  source: .value("Projects"), machine: .value("проекты"), target: .value("Проекты")),
        Operation(key: "sidebar.sessions", index: 5, comment: "Sidebar section header",
                  source: .value("Sessions"), machine: .value("Заседания"), target: .value("Сеансы")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка"),
                                                   Plural(rule: .few, value: "%d строки"),
                                                   Plural(rule: .many, value: "%d строк"),
                                                   Plural(rule: .other, value: "%d строки")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d строка"),
                                                  Plural(rule: .few, value: "%d строки"),
                                                  Plural(rule: .many, value: "Найдено: %d строк"),
                                                  Plural(rule: .other, value: "%d строки")]))),
        Operation(key: "files.selected", index: 7, comment: "Toolbar; how many files the export will include",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                                  Plural(rule: .other, value: "%d files selected")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d файл выбран"),
                                                   Plural(rule: .other, value: "%d файла выбрано")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d файл выбран"),
                                                  Plural(rule: .other, value: "%d файлов выбрано")]))),
        Operation(key: "export.progress", index: 9, comment: "Progress line while an export runs",
                  source: .value("Exporting %d of %d…"), machine: .value("Экспорт %d из %d…"),
                  target: .value("Экспортировано %d из %d…")),
        Operation(key: "alert.title", index: 10, comment: "Modal alert title",
                  source: .value("Something went wrong"), machine: .value("Что-то пошло не так"),
                  target: .value("Произошла ошибка")),
      ], isCompleted: true),

      // The fold call failed: the lessons are all here, nothing landed in the
      // document. A run keeps its other results.
      Operations(language: "ar", items: [
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit",
                  source: .value("Hermes keeps your projects, sessions and translations in one place."),
                  machine: .value("Hermes يحفظ مشاريعك وجلساتك وترجماتك في مكان واحد."),
                  target: .value("يحفظ Hermes مشاريعك وجلساتك وترجماتك في مكان واحد.")),
        Operation(key: "alert.retry", index: 11, comment: "Alert button",
                  source: .value("Try Again"), machine: .value("حاول مرة أخرى"),
                  target: .value("إعادة المحاولة")),
        Operation(key: "empty.state.hint", index: 13, comment: "Shown when a project has no catalog yet",
                  source: .value("No projects yet. Add one to get started."),
                  machine: .value("لا توجد مشاريع. أضف واحداً للبدء."),
                  target: .value("لا توجد مشاريع بعد. أضف مشروعاً للبدء.")),
        Operation(key: "tabs.general", index: 14, comment: "First tab of the settings window",
                  source: .value("General"), machine: .value("الإعدادات العامة"), target: .value("عام")),
        Operation(key: "tabs.appearance", index: 15, comment: "Settings tab; theme and fonts",
                  source: .value("Appearance"), machine: .value("الشكل"), target: .value("المظهر")),
        Operation(key: "tabs.advanced", index: 16, comment: "Settings tab; provider and routing options",
                  source: .value("Advanced"), machine: .value("خيارات متقدمة"), target: .value("متقدّم")),
        Operation(key: "toggle.autoSave", index: 17, comment: "Settings switch",
                  source: .value("Save changes automatically"), machine: .value("حفظ التغييرات تلقائياً"),
                  target: .value("الحفظ التلقائي للتغييرات")),
        Operation(key: "field.searchPlaceholder", index: 18, comment: "Search field in the browser toolbar",
                  source: .value("Search strings"), machine: .value("ابحث عن النصوص"),
                  target: .value("بحث في النصوص")),
        Operation(key: "label.widthLimit", index: 19, comment: "Field label; characters, as in the row menu",
                  source: .value("Width limit (characters)"), machine: .value("حد العرض (بالأحرف)"),
                  target: .value("الحد الأقصى للعرض")),
        Operation(key: "error.fileMissing", index: 20, comment: "Alert body; %@ is the catalog file name",
                  source: .value("The catalog %@ could not be found."),
                  machine: .value("تعذّر العثور على الملف %@."),
                  target: .value("لم يتم العثور على الكتالوج %@.")),
      ], isFailed: true),

      // Not folded yet: the lessons are collected, the document has not moved.
      Operations(language: "de", items: [
        Operation(key: "settings.title", index: 0, comment: "Settings window title",
                  source: .value("Settings"), machine: .value("Konfiguration"),
                  target: .value("Einstellungen")),
        Operation(key: "button.save", index: 1, comment: "Primary action in the editor toolbar",
                  source: .value("Save"), machine: .value("Speichern"), target: .value("Sichern")),
        Operation(key: "button.delete", index: 3, comment: "Destructive action; keep it short",
                  source: .value("Delete"), machine: .value("Löschen"), target: .value("Entfernen")),
        Operation(key: "items.count", index: 6, comment: "Sidebar footer; how many strings are visible",
                  source: .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                                  Plural(rule: .other, value: "%d strings")])),
                  machine: .plural(Plurals(array: [Plural(rule: .one, value: "%d Zeichenkette"),
                                                   Plural(rule: .other, value: "%d Zeichenketten")])),
                  target: .plural(Plurals(array: [Plural(rule: .one, value: "%d Eintrag"),
                                                  Plural(rule: .other, value: "%d Einträge")]))),
        Operation(key: "onboarding.body", index: 12, comment: "Second paragraph; wraps freely, no width limit",
                  source: .value("Hermes keeps your projects, sessions and translations in one place."),
                  machine: .value("Hermes bewahrt Ihre Projekte, Sitzungen und Übersetzungen an einem Ort auf."),
                  target: .value("Projekte, Sitzungen und Übersetzungen — alles an einem Ort.")),
        Operation(key: "error.fileMissing", index: 20, comment: "Alert body; %@ is the catalog file name",
                  source: .value("The catalog %@ could not be found."),
                  machine: .value("Der Katalog %@ wurde nicht gefunden."),
                  target: .value("Katalog %@ konnte nicht gefunden werden.")),
        Operation(key: "status.needsReview", index: 21, comment: "Row state badge",
                  source: .value("Needs Review"), machine: .value("Prüfung erforderlich"),
                  target: .value("Prüfung nötig")),
        Operation(key: "status.reviewed", index: 22, comment: "Row state badge",
                  source: .value("Reviewed"), machine: .value("Überprüft"), target: .value("Geprüft")),
        Operation(key: "button.retry", index: 23, comment: "Recovery action under a failed operation",
                  source: .value("Retry"), machine: .value("Erneut versuchen"),
                  target: .value("Wiederholen")),
        Operation(key: "help.shortcutHint", index: 24, comment: "Tooltip under the search field",
                  source: .value("Press ⌘F to search"), machine: .value("Drücken Sie ⌘F, um zu suchen"),
                  target: .value("Zum Suchen ⌘F drücken")),
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
              // Nothing to resolve: what this stage writes is the document, not a
              // value. Folding the batch is the whole visible effect.
              withAnimation {
                operations[i].isCompleted = true
              }
              try await Task.sleep(for: .seconds(1))
            }
          } catch { }
        }
    }
  }
}

#Preview("Learn") {
  Translation.VerticalLearn.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
