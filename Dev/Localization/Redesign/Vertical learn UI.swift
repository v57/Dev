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
    /// The model's RAW reply for each page, PARALLEL to `operations` (8.1, "stage pages").
    /// The page shows one batch, so its reply is the entry at the page's own offset; a
    /// caller that supplies none gets the "no reply yet" reading rather than a crash.
    var replies: [Translation.Run.Reply] = []
    @State var scrollPosition: Int?
    var body: some View {
      GeometryReader { view in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 0) {
            ForEach(operations.enumerated(), id: \.offset) { (offset, element) in
              OperationContent(operation: element, reply: reply(at: offset)).frame(width: view.size.width, height: view.size.height)
            }
          }.scrollTargetLayout()
        }.scrollTargetBehavior(.paging).scrollPosition(id: $scrollPosition, anchor: .center)
      }.task(id: index) {
        withAnimation(.smooth) {
          scrollPosition = index
        }
      }
    }

    /// The reply of the batch this page is showing.
    private func reply(at offset: Int) -> Translation.Run.Reply {
      replies.indices.contains(offset) ? replies[offset] : Translation.Run.Reply(raw: nil, phase: .pending)
    }
  }
  /// A lesson is a DIFFERENCE: what the model produced against what the human
  /// settled on. There is no value to watch being written here — the output of this
  /// stage is a line in the language document, so each row shows the lesson and the
  /// line it becomes.
  ///
  /// SPLIT IN HALF (8.1, "stage pages"): those lessons on the left as they always were,
  /// and the model's RAW reply for the batch on the right — here a DOCUMENT, not a set of
  /// candidates, which is exactly why the raw text is worth seeing.
  struct OperationContent: View {
    let operation: Operations
    /// The batch's raw reply — what the right half prints, unread.
    let reply: Translation.Run.Reply
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
      HStack(spacing: 0) {
        // The batch's own lessons — what this page always showed, now at half the width.
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
          .frame(maxWidth: .infinity)

        Divider()

        // The model's RAW reply for this batch, printed as it came back.
        Translation.RawReplyPane(reply: reply)
          .frame(maxWidth: .infinity)
      }
    }
  }
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample
    /// The raw replies this sample's batches answered with, PARALLEL to `operations` — the
    /// right half of every page (8.1). It starts as `Test.replies` and the preview's own
    /// fake run fills a page in as its batch lands, exactly as `Runner` sets the batch's
    /// reply when a fold returns.
    @State var replies: [Translation.Run.Reply] = Test.replies

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

    /// The raw text each fold answered with, aligned with `sample` — the fixture's honest
    /// replies, not lorem ipsum.
    ///
    /// Learn's reply is NOT a set of candidates: it is DOCUMENT TEXT, the canonical line(s)
    /// to append to the language document — `KEY<TAB>SOURCE<TAB>VALUE`, three fields — or
    /// the single word `NO_CHANGE` (3.7, 5.3). So the fixture answers with exactly those
    /// lines, one per lesson folded, and with prose where the fold failed: the runner
    /// reports a reply whose lines are not lesson lines rather than folding it (5.5).
    static let answers: [String] = [
      // The folded ru batch: one line per lesson, tab separated.
      """
      settings.title\tSettings\tНастройки
      button.save\tSave\tСохранить
      button.cancel\tCancel\tОтмена
      button.delete\tDelete\tУдалить
      sidebar.projects\tProjects\tПроекты
      sidebar.sessions\tSessions\tСеансы
      items.count\t%d strings\tНайдено: %d строк
      files.selected\t%d files selected\t%d файлов выбрано
      export.progress\tExporting %d of %d…\tЭкспортировано %d из %d…
      alert.title\tSomething went wrong\tПроизошла ошибка
      """,
      // The failed fold: the model answered prose. It cannot be folded — a language
      // document's line is three tab-separated fields — so the run reports the lines that
      // are not lesson lines and leaves the document alone. This is the reply a reader
      // wants to see, and it is the reason the raw pane exists.
      "Your settled values are shorter and less formal than the machine's: I kept the "
        + "terminology and dropped the honorifics, and I would rather not guess the "
        + "gender agreement of each verb form.",
      // The batch nobody has folded yet: the reply it answers with when the preview's fake
      // run lands it.
      """
      settings.title\tSettings\tEinstellungen
      button.save\tSave\tSichern
      button.delete\tDelete\tEntfernen
      items.count\t%d strings\t%d Einträge
      onboarding.body\tHermes keeps your projects, sessions and translations in one place.\tProjekte, Sitzungen und Übersetzungen — alles an einem Ort.
      error.fileMissing\tThe catalog %@ could not be found.\tKatalog %@ konnte nicht gefunden werden.
      status.needsReview\tNeeds Review\tPrüfung nötig
      status.reviewed\tReviewed\tGeprüft
      button.retry\tRetry\tWiederholen
      help.shortcutHint\tPress ⌘F to search\tZum Suchen ⌘F drücken
      """,
    ]

    /// What each page's right half starts with, aligned with `sample`: the folded batch
    /// carries the lines it folded, the failed one carries the prose that made it fail, and
    /// the batch nobody has reached has not been sent — so its pane says "no reply yet"
    /// instead of showing an unexplained empty box.
    static var replies: [Translation.Run.Reply] {
      [
        Translation.Run.Reply(raw: answers[0], phase: .applied),
        Translation.Run.Reply(raw: answers[1], phase: .failed),
        Translation.Run.Reply(raw: nil, phase: .pending),
      ]
    }

    var body: some View {
      Content(index: index, operations: operations, replies: replies)
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
                // The fold answered: its page's right half fills in the same way a live
                // run fills it in (`Run.Batch.rawReply`).
                replies[i] = Translation.Run.Reply(raw: Test.answers[i], phase: .applied)
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
