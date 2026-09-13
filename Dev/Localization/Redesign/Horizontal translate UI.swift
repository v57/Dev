//
//  Horizontal translate UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//

import SwiftUI

extension Translation.HorizontalTranslate {
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
  /// A page per ROW, not per language: one request carries every column of the row,
  /// and the settled columns travel with it as context. So the page is a row — the
  /// source on top, then one line per language, showing what each column holds and
  /// what this pass is allowed to touch.
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
        "tablecells"
      }
    }
    func marker(_ slot: Translation.LocalizationString) -> String {
      switch slot.status {
      case .verified: "checkmark.seal.fill"
      case .imported: "shippingbox.fill"
      case .translated: "sparkles"
      case .stale: "clock.arrow.circlepath"
      case .needsTranslate: "circle.dashed"
      case .ignore: "minus.circle"
      }
    }
    func markerColor(_ slot: Translation.LocalizationString) -> Color {
      switch slot.status {
      case .verified: .green
      case .imported: .blue
      case .translated: .orange
      case .stale: .yellow
      case .needsTranslate: .secondary
      case .ignore: .secondary
      }
    }
    var body: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).font(.title.bold()).frame(width: 32, height: 32)
              .opacity(operation.isCompleted || operation.isFailed ? 1 : 0.1)
            Text("Translating \(operation.items.count) rows")
              .font(.largeTitle.bold())
              .frame(maxWidth: .infinity)
          }.foregroundStyle(color)
          Text("A row travels whole: its settled columns are context for the request, and are never written.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
          ForEach(operation.items.enumerated(), id: \.offset) { (rowIndex, item) in
            VStack(alignment: .leading, spacing: 4) {
              Text(item.key).font(.headline.monospaced())
              Translation.VerticalTranslate.StringView(value: item.source)
                .font(.callout)
                .foregroundStyle(.secondary)
              ForEach(item.targets.enumerated(), id: \.offset) { (index, slot) in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(slot.language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                  Image(systemName: marker(slot)).foregroundStyle(markerColor(slot))
                  if slot.target.isEmpty {
                    Text("…").foregroundStyle(.tertiary)
                  } else {
                    Translation.VerticalTranslate.StringView(value: slot.target)
                  }
                  if slot.status == .verified || slot.status == .imported {
                    Text("context").font(.caption2).foregroundStyle(.tertiary)
                  }
                }.animation(.smooth.delay(Double(index) / 10), value: slot)
              }
            }
            .foregroundStyle(color)
            .padding(.vertical, 4)
            if rowIndex < operation.items.count - 1 {
              Divider().opacity(0.4)
            }
          }
        }.padding(32)
      }.contentTransition(.symbolEffect)
    }
  }
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample

    /// Sample batches for the design preview: ten ROWS each, in the three states a
    /// batch can be in.
    ///
    /// The row travels whole (that is the shape's point), so every row below carries
    /// its settled column as context plus the columns this pass may write:
    ///   `.verified`  the human's own value — never written, always context
    ///   `.imported`  a shipped translation — same deal, shown in its own colour
    ///   `.translated` what this pass already wrote (machine output, unreviewed)
    ///   `.needsTranslate` / `.stale`  the work; `.ignore` is out of scope entirely
    static let sample: [Operations] = [
      // Done: every writable column of every row has been written, the settled
      // columns are untouched.
      Operations(items: [
        row("settings.title", 0, "Settings window title", .value("Settings"),
            [verified("ru", "Настройки"), written("de", "Einstellungen"), written("ja", "設定")]),
        row("button.save", 1, "Primary action in the editor toolbar", .value("Save"),
            [verified("ru", "Сохранить"), written("de", "Sichern"), written("ja", "保存")], maxWidth: 12),
        row("button.cancel", 2, "Dismisses the sheet without saving", .value("Cancel"),
            [verified("ru", "Отмена"), written("de", "Abbrechen"), written("ja", "キャンセル")], maxWidth: 12),
        row("button.delete", 3, "Destructive action; keep it short", .value("Delete"),
            [verified("ru", "Удалить"), written("de", "Entfernen"), written("ja", "削除")], maxWidth: 8),
        row("sidebar.projects", 4, "Sidebar section header", .value("Projects"),
            [verified("ru", "Проекты"), written("de", "Projekte"), written("ja", "プロジェクト")]),
        row("sidebar.sessions", 5, "Sidebar section header", .value("Sessions"),
            [verified("ru", "Сеансы"), written("de", "Sitzungen"), written("ja", "セッション")]),
        row("items.count", 6, "Sidebar footer; how many strings are visible",
            .plural(Plurals(array: [Plural(rule: .one, value: "%d string"),
                                    Plural(rule: .other, value: "%d strings")])),
            [verified("ru", plurals: [.one: "%d строка", .few: "%d строки", .many: "%d строк", .other: "%d строки"]),
             written("de", plurals: [.one: "%d Eintrag", .other: "%d Einträge"]),
             written("ja", plurals: [.other: "%d件"])]),
        row("files.selected", 7, "Toolbar; how many files the export will include",
            .plural(Plurals(array: [Plural(rule: .one, value: "%d file selected"),
                                    Plural(rule: .other, value: "%d files selected")])),
            [verified("ru", plurals: [.one: "%d файл выбран", .few: "%d файла выбрано", .many: "%d файлов выбрано", .other: "%d файла выбрано"]),
             written("de", plurals: [.one: "%d Datei ausgewählt", .other: "%d Dateien ausgewählt"]),
             written("ja", plurals: [.other: "%d件のファイル"])]),
        row("selection.summary", 8, "Status bar; how many strings are selected",
            .plural(Plurals(array: [Plural(rule: .one, value: "%d string selected"),
                                    Plural(rule: .other, value: "%d strings selected")])),
            [verified("ru", plurals: [.one: "%d строка выбрана", .few: "%d строки выбрано", .many: "%d строк выбрано", .other: "%d строки выбрано"]),
             written("de", plurals: [.one: "%d Eintrag ausgewählt", .other: "%d Einträge ausgewählt"]),
             written("ja", plurals: [.other: "%d件を選択中"])]),
        row("export.progress", 9, "Progress line while an export runs", .value("Exporting %d of %d…"),
            [verified("ru", "Экспорт %d из %d…"), written("de", "Exportiere %d von %d…"), written("ja", "%d / %d を書き出し中…")]),
      ], isCompleted: true),

      // Failed partway: the last three rows were never reached, so their columns are
      // still empty — a run keeps what it already wrote.
      Operations(items: [
        row("alert.title", 10, "Modal alert title", .value("Something went wrong"),
            [verified("ru", "Произошла ошибка"), written("de", "Ein Fehler ist aufgetreten"), waiting("ja")]),
        row("alert.retry", 11, "Alert button", .value("Try Again"),
            [verified("ru", "Повторить"), written("de", "Wiederholen"), waiting("ja")], maxWidth: 8),
        row("onboarding.body", 12, "Second paragraph; wraps freely, no width limit",
            .value("Hermes keeps your projects, sessions and translations in one place."),
            [verified("ru", "Hermes хранит проекты, сеансы и переводы в одном месте."),
             written("de", "Projekte, Sitzungen und Übersetzungen — alles an einem Ort."), waiting("ja")]),
        row("empty.state.hint", 13, "Shown when a project has no catalog yet",
            .value("No projects yet. Add one to get started."),
            [verified("ru", "Проектов пока нет. Добавьте проект, чтобы начать."),
             written("de", "Noch keine Projekte. Füge eines hinzu."), waiting("ja")]),
        row("tabs.general", 14, "First tab of the settings window", .value("General"),
            [verified("ru", "Основные"), written("de", "Allgemein"), waiting("ja")]),
        row("tabs.appearance", 15, "Settings tab; theme and fonts", .value("Appearance"),
            [verified("ru", "Оформление"), written("de", "Darstellung"), waiting("ja")]),
        row("tabs.advanced", 16, "Settings tab; provider and routing options", .value("Advanced"),
            [verified("ru", "Дополнительно"), written("de", "Erweitert"), waiting("ja")]),
        row("toggle.autoSave", 17, "Settings switch", .value("Save changes automatically"),
            [verified("ru", "Автосохранение изменений"), waiting("de"), waiting("ja")]),
        row("field.searchPlaceholder", 18, "Search field in the browser toolbar", .value("Search strings"),
            [verified("ru", "Поиск строк"), waiting("de"), waiting("ja")], maxWidth: 16),
        row("label.widthLimit", 19, "Field label; characters, as in the row menu", .value("Width limit (characters)"),
            [verified("ru", "Ограничение ширины"), waiting("de"), waiting("ja")]),
      ], isFailed: true),

      // Untouched: nothing written anywhere, and the vocabulary of the row's statuses
      // is all visible — including a stale column and an ignored one.
      Operations(items: [
        row("error.fileMissing", 20, "Alert body; %@ is the catalog file name",
            .value("The catalog %@ could not be found."), [verified("ru", "Каталог %@ не найден."), waiting("de"), waiting("ja")]),
        row("status.needsReview", 21, "Row state badge", .value("Needs Review"),
            [verified("ru", "Требует проверки"), waiting("de"), waiting("ja")]),
        row("status.reviewed", 22, "Row state badge", .value("Reviewed"),
            [verified("ru", "Проверено"), waiting("de"), waiting("ja")]),
        row("button.retry", 23, "Recovery action under a failed operation", .value("Retry"),
            [verified("ru", "Повторить"), waiting("de"), waiting("ja")], maxWidth: 8),
        row("help.shortcutHint", 24, "Tooltip under the search field", .value("Press ⌘F to search"),
            [verified("ru", "Нажмите ⌘F для поиска"), waiting("de"), waiting("ja")]),
        row("project.rename", 25, "Project context menu", .value("Rename…"),
            [verified("ru", "Переименовать…"), waiting("de"), waiting("ja")]),
        row("project.remove", 26, "Project context menu; removes it from the sidebar only",
            .value("Remove from Sidebar"),
            [verified("ru", "Убрать из бокового меню"), shipped("de", "Aus Seitenleiste entfernen"), waiting("ja")]),
        row("session.new", 27, "Sidebar action", .value("New Session"),
            [verified("ru", "Новый сеанс"), waiting("de"), waiting("ja")]),
        row("session.close", 28, "Session toolbar", .value("Close Session"),
            [verified("ru", "Закрыть сеанс"), stale("de", "Sitzung schliessen"), waiting("ja")]),
        row("export.format", 29, "Export sheet; file format picker", .value("Format"),
            [verified("ru", "Формат"), waiting("de"), ignored("ja")]),
      ]),
    ]

    // MARK: - sample helpers

    /// `.verified`: the human's own value. Context that travels with the row and is
    /// never written by this pass.
    static func verified(_ language: String, _ text: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .value(text), status: .verified)
    }
    static func verified(_ language: String, plurals: [Plural.Rule: String]) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .plural(Plurals(array: plurals.map { Plural(rule: $0.key, value: $0.value) })), status: .verified)
    }
    /// `.imported`: a shipped translation from the database the app ships. Usable and
    /// unreviewed, and equally not writable.
    static func shipped(_ language: String, _ text: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .value(text), status: .imported)
    }
    /// `.translated`: what this pass wrote — machine output, waiting for review.
    static func written(_ language: String, _ text: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .value(text), status: .translated)
    }
    static func written(_ language: String, plurals: [Plural.Rule: String]) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .plural(Plurals(array: plurals.map { Plural(rule: $0.key, value: $0.value) })), status: .translated)
    }
    /// `.needsTranslate`: nothing there yet — the work.
    static func waiting(_ language: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, status: .needsTranslate)
    }
    /// `.stale`: it has a value that predates the documents governing it.
    static func stale(_ language: String, _ text: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, target: .value(text), status: .stale)
    }
    /// `.ignore`: the key is marked do-not-translate for this language. Out of scope
    /// for every stage, and the value it has is kept.
    static func ignored(_ language: String) -> Translation.LocalizationString {
      Translation.LocalizationString(language: language, status: .ignore)
    }
    static func row(_ key: String, _ index: Int, _ comment: String, _ source: Translation.StringBody,
                    _ targets: [Translation.LocalizationString], maxWidth: Int = 0) -> Operation {
      Operation(key: key, index: index, comment: comment, maxWidth: maxWidth, source: source, targets: targets)
    }

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

#Preview("Translate by row") {
  Translation.HorizontalTranslate.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
