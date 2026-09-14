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
  /// The page, SPLIT IN HALF (8.1, "stage pages"): the batch's own items on the left,
  /// exactly as this page always showed them, and the model's RAW reply for that batch on
  /// the right.
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
        "translate"
      }
    }
    var body: some View {
      HStack(spacing: 0) {
        // The batch's own items — what this page always showed, now at half the width.
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
          .frame(maxWidth: .infinity)

        Divider()

        // The model's RAW reply for this batch, printed as it came back.
        Translation.RawReplyPane(reply: reply)
          .frame(maxWidth: .infinity)
      }
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
    /// The raw replies this sample's batches answered with, PARALLEL to `operations` — the
    /// right half of every page (8.1). It starts as `Test.replies` and the preview's own
    /// fake run fills each page in as it lands, exactly as `Runner` sets the batch's reply
    /// when a call returns.
    @State var replies: [Translation.Run.Reply] = Test.replies

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

    /// The raw text each batch answered with, aligned with `sample` — the fixture's honest
    /// replies, not lorem ipsum. A language batch's reply is the JSON array
    /// `Prompt.languageBatch` asks for (4.3): `{"id": <position>, "text": …}`, one element
    /// per item in order, and a PLURAL slot answering an object of its language's
    /// categories. Every text is the value the fixture's own left half shows for that slot,
    /// so the two halves can be read against each other.
    static let answers: [String] = [
      // The settled ru column.
      """
      [{"id": 0, "text": "Настройки"},
       {"id": 1, "text": "Сохранить"},
       {"id": 2, "text": "Отмена"},
       {"id": 3, "text": "Удалить"},
       {"id": 4, "text": {"one": "%d строка", "few": "%d строки", "many": "%d строк", "other": "%d строки"}},
       {"id": 5, "text": {"one": "%d файл выбран", "few": "%d файла выбрано", "many": "%d файлов выбрано", "other": "%d файла выбрано"}},
       {"id": 6, "text": {"one": "%d строка выбрана", "few": "%d строки выбрано", "many": "%d строк выбрано", "other": "%d строки выбрано"}},
       {"id": 7, "text": "Экспорт %d из %d…"},
       {"id": 8, "text": "Что-то пошло не так"},
       {"id": 9, "text": "Hermes хранит проекты, сеансы и переводы в одном месте."}]
      """,
      // The column's second batch — what a character-budget split looks like.
      """
      [{"id": 0, "text": "Проектов пока нет. Добавьте проект, чтобы начать."},
       {"id": 1, "text": "Основные"},
       {"id": 2, "text": "Оформление"},
       {"id": 3, "text": "Дополнительно"},
       {"id": 4, "text": "Автоматически сохранять изменения"},
       {"id": 5, "text": "Поиск строк"},
       {"id": 6, "text": "Ограничение ширины (символы)"},
       {"id": 7, "text": "Каталог %@ не найден."},
       {"id": 8, "text": "Требует проверки"},
       {"id": 9, "text": "Проверено"}]
      """,
      // Arabic, whose plural slots answer SIX categories (zero / one / two / few / many /
      // other) — the plural shape arrives here as an object, and the raw pane is where you
      // see that it did.
      """
      [{"id": 0, "text": "الإعدادات"},
       {"id": 1, "text": "حفظ"},
       {"id": 2, "text": "حذف"},
       {"id": 3, "text": {"zero": "لا ملفات محددة", "one": "ملف واحد محدد", "two": "ملفان محددان", "few": "%d ملفات محددة", "many": "%d ملفاً محدداً", "other": "%d ملف محدد"}},
       {"id": 4, "text": {"zero": "لا نصوص محددة", "one": "نص واحد محدد", "two": "نصان محددان", "few": "%d نصوص محددة", "many": "%d نصاً محدداً", "other": "%d نص محدد"}},
       {"id": 5, "text": "جارٍ تصدير %d من %d…"},
       {"id": 6, "text": "حدث خطأ ما"},
       {"id": 7, "text": "إعادة المحاولة"},
       {"id": 8, "text": "يحفظ Hermes مشاريعك وجلساتك وترجماتك في مكان واحد."},
       {"id": 9, "text": "لا توجد مشاريع بعد. أضف مشروعاً للبدء."}]
      """,
      // The failed batch: this is ALL that came back — whitespace. An empty answer is a
      // defect (5.3), which is exactly why this batch is the failed one, and the pane has
      // to say "the model answered nothing" rather than show a blank box.
      "\n   \n",
      // The last batch, which the fixture leaves UNSENT: the reply the preview's own fake run
      // answers it with when it lands it.
      """
      [{"id": 0, "text": "Allgemein"},
       {"id": 1, "text": "Darstellung"},
       {"id": 2, "text": "Erweitert"},
       {"id": 3, "text": "Änderungen automatisch sichern"},
       {"id": 4, "text": "Strings durchsuchen"},
       {"id": 5, "text": "Breitenbegrenzung (Zeichen)"},
       {"id": 6, "text": "Der Katalog %@ wurde nicht gefunden."},
       {"id": 7, "text": "Prüfung erforderlich"},
       {"id": 8, "text": "Überprüft"},
       {"id": 9, "text": "Drücken Sie ⌘F, um zu suchen"}]
      """,
    ]

    /// What each page's right half starts with, aligned with `sample`: the batches that landed
    /// carry their raw reply, the failed one carries what actually came back (nothing), and the
    /// last has not been sent yet — so its pane says "no reply yet" instead of showing an
    /// unexplained empty box.
    static var replies: [Translation.Run.Reply] {
      [
        Translation.Run.Reply(raw: answers[0], phase: .applied),
        Translation.Run.Reply(raw: answers[1], phase: .applied),
        Translation.Run.Reply(raw: answers[2], phase: .applied),
        Translation.Run.Reply(raw: answers[3], phase: .failed),
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
              withAnimation {
                operations[i].items = operations[i].items.map { $0.resolve($0.source.reversed()) }
                operations[i].isCompleted = true
                // The batch answered: its page's right half fills in the same way a live
                // run fills it in (`Run.Batch.rawReply`), so the fixture covers both the
                // open batch and the answered one.
                replies[i] = Translation.Run.Reply(raw: Test.answers[i], phase: .applied)
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

extension Translation {
  /// The RIGHT half of a stage page: the model's raw reply for the batch the page is
  /// showing, printed as it came back (8.1, "stage pages").
  ///
  /// RAW means raw. Nothing here parses, validates, summarises or reformats the text: the
  /// pane exists so that what the validator accepted, what the repair step fixed and what
  /// the paid gate was asked about is VISIBLE instead of inferred. It is monospaced (a
  /// reply is JSON, and JSON is easier to check in a fixed pitch), it scrolls, and it is
  /// selectable — the reason a human reads it is usually to copy a piece of it out. It is
  /// a `Text`: read-only by construction.
  ///
  /// It lives beside `VerticalTranslate.StringView`, the other component every page
  /// prints, and it is the ONE pane the four stage pages share, so the split reads the same
  /// on all of them.
  ///
  /// The states are a diagnostic surface's, not a blank box's: a batch with no reply yet
  /// says so, a batch no request was spent on says THAT (`Runner.resolveMemory` answers a
  /// slot before a request is built), a request that failed says so, a reply that is empty
  /// or whitespace is reported as the model answering nothing, and everything else is the
  /// reply itself. `state(of:)` decides which, so the pane and a probe ask the same
  /// question.
  struct RawReplyPane: View {
    let reply: Run.Reply

    /// What the right half shows.
    enum State: Equatable {
      /// Nothing has answered this batch yet: it is scanned and in flight.
      case pending
      /// No request was ever sent: translation memory answered every item of the batch
      /// (`Run.resolveMemory`), so there is no reply to show — and no call to regret.
      case noRequest
      /// The request failed before any reply arrived.
      case failed
      /// The model answered nothing: the reply is empty or whitespace, which the validator
      /// rejects as an empty answer (5.3).
      case empty
      /// The reply, verbatim.
      case reply(String)
    }

    /// The state a batch's reply is in. The phase is what separates a batch nobody has sent
    /// yet from one no model will ever answer, and it comes off the batch rather than off
    /// the text: an absent reply means four different things.
    static func state(of reply: Run.Reply) -> State {
      guard let raw = reply.raw else {
        switch reply.phase {
        case .applied: return .noRequest
        case .failed: return .failed
        case .pending, .sent, .validated, .repaired: return .pending
        }
      }
      return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .reply(raw)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        content
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.thinMaterial)
    }

    private var header: some View {
      HStack(spacing: 8) {
        Image(systemName: "curlybraces").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Model reply").font(.headline)
          Text("Raw, as it came back for this batch — nothing parsed, nothing summarised.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
    }

    @ViewBuilder
    private var content: some View {
      switch Self.state(of: reply) {
      case .pending:
        note(
          icon: "clock.arrow.circlepath", title: "No reply yet",
          detail: "This batch is in flight — the model's answer appears here when it comes back.")
      case .noRequest:
        note(
          icon: "memorychip", title: "No request was spent",
          detail: "Translation memory answered every item of this batch, so there is no reply to show (6.2).")
      case .failed:
        note(
          icon: "exclamationmark.triangle", title: "No reply",
          detail: "The request failed before the model answered. The run's failure report carries the reason.")
      case .empty:
        note(
          icon: "text.badge.xmark", title: "The model answered nothing",
          detail: "The reply came back empty — whitespace only, which is an empty answer and a defect (5.3).")
      case .reply(let raw):
        ScrollView {
          Text(raw)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
      }
    }

    private func note(icon: String, title: String, detail: String) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Label(title, systemImage: icon).font(.callout.weight(.semibold))
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview {
  Translation.VerticalTranslate.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
