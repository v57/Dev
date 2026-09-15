//
//  DesignUI.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//

import SwiftUI

extension Translation {
  /// The mark ONE ROW carries on a stage page (8.1, "stage pages"): a reading of the ROW's own
  /// state, never of its batch's.
  ///
  /// It exists because the batch's flags cannot answer the question a page is read for: a batch
  /// is a REQUEST of many rows, and one that wrote 31 of 33 IS applied (`Runner.settle`), so a
  /// page that marks its rows from the batch turns every row into an xmark the moment a single
  /// one goes wrong (reader, 2026-09-14). The batch's own mark stays for the page's chrome,
  /// where it reads as the page's summary, and it never reaches a row.
  ///
  /// ONE shape for all four pages: what differs between them is the symbol a row carries while
  /// nothing has answered it, and that is what the caller passes in.
  struct RowMark {
    /// Where the ROW itself is in the run's life.
    let phase: Translation.Run.Phase
    /// The stage's own in-flight symbol: `wand.and.stars` on prelearn, `graduationcap` on learn,
    /// `translate` on the column pass, `tablecells` on the row pass.
    let inFlight: String

    /// True while nothing has answered this row: it reads as the stage's own symbol, dimmed,
    /// rather than as a tick or a cross.
    var isWaiting: Bool {
      switch phase {
      case .failed, .applied: false
      case .pending, .sent, .validated: true
      }
    }

    var icon: String {
      switch phase {
      case .failed: "xmark.circle.fill"
      case .applied: "checkmark.circle.fill"
      case .pending, .sent, .validated: inFlight
      }
    }

    var color: Color {
      switch phase {
      case .failed: .red
      case .applied: .green
      case .pending, .sent, .validated: .primary
      }
    }
  }

  /// How long a row's mark waits before settling, by its position in the list — the wave that
  /// makes a page's marks land in READING order rather than all at once.
  ///
  /// BOUNDED, and that bound is the whole point (reader, 2026-09-15: "still uses 100% cpu while
  /// translation is working", with the sample showing 87,6 % of the core inside SwiftUI's own view
  /// graph updates). The stagger used to be `Double(index) / 10` with NO ceiling, and the modifier
  /// it hangs off animated on ANY change to the row's value: a row 300 rows down scheduled its
  /// animation THIRTY SECONDS out, and since rows land continuously during a run, transactions kept
  /// arriving — a permanently busy animation pipeline, which is exactly the shape the sample showed.
  /// Twelve rows is the longest wave a reader notices; past it a landing row marks at once.
  static func stagger(_ index: Int) -> Double { min(Double(index), 12) / 10 }

  /// The LAST row of a page's list the run has ANSWERED — written or failed (8.1: the mark
  /// belongs to the row, never to its batch).
  ///
  /// What a page's list follows, and it follows the ROW rather than the batch (reader,
  /// 2026-09-15): a row is written the moment the model finishes writing it (5.12), so a list
  /// that followed only its batch would sit still through every row of a 33-row request and then
  /// jump at the end. The list keeps the last landed row CENTRED — the row the model has just
  /// finished is the one being read — and a page opened mid-batch lands on it at once, because a
  /// row that has landed is already written and saved.
  static func lastLanded<T: Operation>(in items: [T]) -> Int? {
    items.lastIndex { $0.phase == .applied || $0.phase == .failed }
  }

  /// How long a stage page waits before it follows the run to a NEWER batch (8.1, "PACING").
  ///
  /// The pause belongs to the SCROLL, never to the run: the pipeline never waits for a view. It
  /// is the budget the page keeps between two scrolls — measured from the last one, so a batch
  /// arriving half a second after the previous scroll waits the remaining second and a half,
  /// while a page that has been quiet scrolls at once. ONE value for all four pages.
  static let pagePacing: TimeInterval = 2
}

extension Translation.VerticalTranslate {
  struct Content: View {
    let index: Int
    let operations: [Operations]
    /// BOTH SIDES of each page's exchange, PARALLEL to `operations` (8.1, "stage pages"): the
    /// input the batch sent and the reply it got back, one value per batch. The page shows one
    /// batch, so its exchange is the entry at the page's own offset; a caller that supplies none
    /// gets the "nothing sent yet" reading on both halves rather than a crash.
    var exchanges: [Translation.Run.Exchange] = []
    @State var scrollPosition: Int?
    /// When this page last followed the run to a batch. Seeded `.distantPast`, so the FIRST
    /// appearance never waits: a page opened mid-run goes straight to the batch the run is on,
    /// and only later CHANGES pause (8.1, "PACING").
    @State var lastScroll: Date = .distantPast
    var body: some View {
      GeometryReader { view in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 0) {
            ForEach(operations.enumerated(), id: \.offset) { (offset, element) in
              OperationContent(operation: element, exchange: exchange(at: offset)).frame(width: view.size.width, height: view.size.height)
            }
          }.scrollTargetLayout()
        }.scrollTargetBehavior(.paging).scrollPosition(id: $scrollPosition, anchor: .center)
      }.task(id: index) {
        // The pause is a BUDGET since the last scroll, not a fresh timer per change: SwiftUI
        // cancels this task whenever `index` changes, so a sleep counted from here would share
        // nothing and a run producing batches faster than the pause would postpone the scroll
        // forever. Measuring from `lastScroll` keeps the page advancing — and it always lands on
        // the NEWEST index, because a cancelled task never reaches the scroll below.
        let target = index
        let wait = max(0, Translation.pagePacing - Date.now.timeIntervalSince(lastScroll))
        try? await Task.sleep(for: .seconds(wait))
        lastScroll = .now
        withAnimation(.smooth) {
          scrollPosition = target
        }
      }
    }

    /// The exchange of the batch this page is showing: batch N's input beside batch N's reply,
    /// because the two are one value (`Run.Exchange`) taken from the batch at this offset.
    private func exchange(at offset: Int) -> Translation.Run.Exchange {
      exchanges.indices.contains(offset) ? exchanges[offset] : .unsent
    }
  }
  /// The page, SPLIT IN HALF (8.1, "stage pages"): the batch's own items on the left,
  /// exactly as this page always showed them, and the batch's EXCHANGE on the right — what
  /// was sent to the model, and what it answered.
  struct OperationContent: View {
    let operation: Operations
    /// Both sides of this batch's exchange — what the right half prints, unread.
    let exchange: Translation.Run.Exchange
    /// The row the list is showing, bound to the list's own scroll position exactly as the batch
    /// pager above is bound to the batch (8.1, "PACING"): the page follows the last row the run
    /// ANSWERED rather than the batch it belongs to (reader, 2026-09-15), because rows are written
    /// one at a time now (5.12).
    @State var rowPosition: Int?
    /// The mark THIS row carries (8.1, "stage pages"): the row's own state, never the batch's.
    /// The batch's flags are not read here at all — a batch that wrote some of its rows is
    /// applied, and the row that went wrong is the only thing that carries the failure.
    func mark(_ item: Translation.VerticalTranslate.Operation) -> Translation.RowMark {
      Translation.RowMark(phase: item.phase, inFlight: "translate")
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
                Image(systemName: mark(item).icon).font(.title.bold()).frame(width: 32, height: 32)
                  .opacity(mark(item).isWaiting ? 0.1 : 1)
                StringView(value: operation.isCompleted ? item.target : item.source)
                  .fontWeight(operation.isCompleted ? .semibold : .regular)
                  .contentTransition(.numericText())
              }.foregroundStyle(mark(item).color).animation(.smooth.delay(Double(index) / 10), value: item)
                .id(index)
            }
          }.padding(32)
            .scrollTargetLayout()
        }.contentTransition(.symbolEffect)
          .scrollPosition(id: $rowPosition, anchor: .center)
          .task(id: Translation.lastLanded(in: operation.items)) {
            // The list follows the row that just landed, centred: it is the row the model has
            // finished and the one being read. A page opened mid-batch lands on it at once — no
            // pacing, unlike the batch pager, because a row that has landed is already written.
            rowPosition = Translation.lastLanded(in: operation.items)
          }
          .frame(maxWidth: .infinity)

        Divider()

        // BOTH sides of this batch's exchange: the input that was sent, then the reply.
        Translation.RawExchangePane(exchange: exchange)
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
    /// Both sides of the exchange each of this sample's batches has with the model, PARALLEL to
    /// `operations` — the right half of every page (8.1). It starts as `Test.exchanges` and the
    /// preview's own fake run fills a page in as it lands, exactly as `Runner` sets the batch's
    /// input when it goes out and its reply when a call returns.
    @State var exchanges: [Translation.Run.Exchange] = Test.exchanges

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

    /// The INPUT of every page, aligned with `sample` (8.1): the request the batch sends — a
    /// system message, the L0 and L1 blocks, and the ITEMS payload last — assembled from the
    /// batch's OWN items in the order the wire carries them, so a page's input and its reply
    /// describe the same batch (4.3).
    static var requests: [Translation.Prompt.Request] {
      sample.map { batch in
        Translation.SampleRequest.languageBatch(
          language: batch.language,
          items: batch.items.map { item in
            Translation.SampleRequest.Item(
              source: Translation.SampleRequest.body(item.source),
              target: Translation.SampleRequest.body(item.target),
              comment: item.comment, maxWidth: item.maxWidth)
          })
      }
    }

    /// What each page's right half starts with, aligned with `sample`: the batches that were
    /// SENT carry their input, the ones that landed carry the reply they got, the failed one
    /// carries what actually came back (nothing — an empty answer is a defect, 5.3), and the
    /// last has not been sent yet — so its pane says so on BOTH halves instead of showing two
    /// unexplained empty boxes.
    static var exchanges: [Translation.Run.Exchange] {
      [
        Translation.Run.Exchange(
          request: requests[0], reply: Translation.Run.Reply(raw: answers[0], phase: .applied)),
        Translation.Run.Exchange(
          request: requests[1], reply: Translation.Run.Reply(raw: answers[1], phase: .applied)),
        Translation.Run.Exchange(
          request: requests[2], reply: Translation.Run.Reply(raw: answers[2], phase: .applied)),
        Translation.Run.Exchange(
          request: requests[3], reply: Translation.Run.Reply(raw: answers[3], phase: .failed)),
        Translation.Run.Exchange(
          request: nil, reply: Translation.Run.Reply(raw: nil, phase: .pending)),
      ]
    }

    var body: some View {
      Content(index: index, operations: operations, exchanges: exchanges)
        .task {
          do {
            for i in 0..<operations.count {
              withAnimation {
                index = i
              }
              try await Task.sleep(for: .seconds(2))
              withAnimation {
                operations[i].items = operations[i].items.map { $0.resolve($0.source.reversed()) }
                // The ROWS' own state, the way the runner leaves it (`Runner.settle`): a batch
                // that wrote its rows applied them one by one, and the batch this fixture marks
                // failed wrote nothing, so its rows carry the failure themselves — which is what
                // the page marks, and never the batch's own flag.
                let failed = operations[i].isFailed
                operations[i].items = operations[i].items.map { item in
                  var item = item
                  item.phase = failed ? .failed : .applied
                  return item
                }
                operations[i].isCompleted = true
                // The batch went out and was answered: its page's right half fills in the same
                // way a live run fills it in — the input when the request is built
                // (`Run.Batch.request`), then the reply when the call returns
                // (`Run.Batch.rawReply`).
                exchanges[i] = Translation.Run.Exchange(
                  request: Test.requests[i],
                  reply: Translation.Run.Reply(raw: Test.answers[i], phase: .applied))
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
  /// The RIGHT half of a stage page: BOTH SIDES of the batch's exchange — the model INPUT that
  /// went out and the model's RAW reply that came back (8.1, "stage pages").
  ///
  /// RAW means raw, on both sides. Nothing here parses, validates, summarises or reformats: the
  /// pane exists so that what the model was ASKED and what it ANSWERED is visible instead of
  /// inferred, and one request is one batch, so a page shows exactly one exchange. Both halves
  /// are monospaced (a request and a reply are structured text, and structure is easier to check
  /// in a fixed pitch), they scroll together, and they are selectable — the reason a human reads
  /// them is usually to copy a piece of one out. They are `Text`: read-only by construction.
  ///
  /// The INPUT marks where the provider's CACHEABLE PREFIX ends (4.3): that byte-prefix is what
  /// the tally's cached share is about (5.7), and a flat zero there means the prefix moved
  /// rather than the provider being unlucky. The boundary is drawn from the request's OWN
  /// `cacheablePrefix` and asserted against what is sent — never eyeballed.
  ///
  /// The states are a diagnostic surface's, not a blank box's, and each half carries its OWN
  /// reading: a batch nobody has sent has no input AND no reply, and says so on BOTH halves
  /// rather than showing two empty boxes; a batch translation memory answered has no request
  /// behind it and no reply either; a request that failed still shows what it was about to ask;
  /// and a reply that came back empty reads as the model answering nothing — never as a missing
  /// input.
  ///
  /// It lives beside `VerticalTranslate.StringView`, the other component every page prints, and
  /// it is the ONE pane the four stage pages share, so the split reads the same on all of them.
  struct RawExchangePane: View {
    let exchange: Run.Exchange

    /// The string `Prompt.request` joins a request's blocks with, repeated here because the pane
    /// prints the two messages as one text and has to know where the first stops. The copy is
    /// SAFE: the boundary assertion below compares the request's own `cacheablePrefix` against
    /// what this separator produces, so a change in `Prompt` fires the assertion instead of
    /// sliding the marker.
    static let messageSeparator = "\n\n"

    // MARK: - the input

    /// What the INPUT half shows.
    enum InputState: Equatable {
      /// No request has gone out for this batch yet: it is scanned and waiting.
      case notSent
      /// No request was ever built: translation memory answered every item of the batch
      /// (`Run.resolveMemory`), so nothing was asked and there is no call to regret.
      case noRequest
      /// The batch failed before a request was built.
      case failed
      /// The request, verbatim.
      case input(Prompt.Request)
    }

    /// The state a batch's INPUT is in. A request is kept the moment it is BUILT
    /// (`Run.Batch.request`), so a request that is there is the one that went out — a batch
    /// whose call then failed included; when it is not there, the phase says which of the three
    /// reasons it is, because an absent request means three different things.
    static func inputState(of exchange: Run.Exchange) -> InputState {
      if let request = exchange.request { return .input(request) }
      switch exchange.reply.phase {
      case .applied: return .noRequest
      case .failed: return .failed
      case .pending, .sent, .validated: return .notSent
      }
    }

    /// Where a request's cacheable prefix ends, in the terms the pane draws it: how many
    /// characters of what is sent the provider may cache, and where that run stops inside the
    /// USER message (the second of the two messages the pane prints).
    ///
    /// `userOffset` may sit at either EDGE — the prefix is the system message alone when the
    /// project has no context documents to send, and it covers the whole user message when
    /// nothing but L0 went out — which is why the pane draws a boundary at an edge as readily as
    /// at an offset.
    struct Cacheable: Equatable {
      /// `cacheablePrefix.count`: what the telemetry counts as the cacheable share (5.7).
      let characters: Int
      /// The offset into the user message where the prefix ends. Negative and past-the-end are
      /// legal and mean an EDGE.
      let userOffset: Int
      /// The user message's own length, so an edge can be told from a cut.
      let userCharacters: Int

      /// Whether the boundary falls strictly inside the user message — the ordinary case, since
      /// L0 is non-empty for a real batch.
      var isInsideUserMessage: Bool { userOffset > 0 && userOffset < userCharacters }
    }

    /// A request's cacheable prefix, mapped onto the text this pane prints — or nil when the
    /// request carries none to mark.
    ///
    /// The two assertions are the point of the function: the prefix must be a REAL prefix of
    /// what is sent, and the offset the pane draws must be exactly where that prefix ends. A
    /// marker placed by eye would be a claim about the provider cache the pane cannot back up,
    /// and 5.7 reads that share as evidence.
    static func cacheable(of request: Prompt.Request) -> Cacheable? {
      let prefix = request.cacheablePrefix
      guard !prefix.isEmpty else { return nil }
      let sent = request.system + messageSeparator + request.user
      assert(
        sent.hasPrefix(prefix),
        "Prompt's cacheable prefix is not a prefix of what this request sends")
      let offset = prefix.count - request.system.count - messageSeparator.count
      assert(
        !(offset > 0 && offset < request.user.count)
          || prefix == request.system + messageSeparator + request.user.prefix(offset),
        "the cacheable boundary the pane draws is not where the prefix ends")
      return Cacheable(
        characters: prefix.count, userOffset: offset, userCharacters: request.user.count)
    }

    // MARK: - the reply

    /// What the REPLY half shows.
    enum ReplyState: Equatable {
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
    static func replyState(of reply: Run.Reply) -> ReplyState {
      guard let raw = reply.raw else {
        switch reply.phase {
        case .applied: return .noRequest
        case .failed: return .failed
        case .pending, .sent, .validated: return .pending
        }
      }
      return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .reply(raw)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            // The input FIRST: it is the question the reply answers, and a reader checking a
            // failure needs to see what was asked before what came back.
            inputHalf
            Divider()
            replyHalf
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.thinMaterial)
    }

    private var header: some View {
      HStack(spacing: 8) {
        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Model exchange").font(.headline)
          Text("Both sides of one batch: what was sent, and what came back.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
    }

    // MARK: - the two halves

    /// The INPUT: the system message, then the user message with the prefix's end marked in it.
    @ViewBuilder
    private var inputHalf: some View {
      VStack(alignment: .leading, spacing: 0) {
        halfHeader(
          icon: "arrow.up.circle", title: "Model input",
          detail: "Exactly what went out for this batch: the system message, then the user message — L0, L1, the items last (4.3).")
        switch Self.inputState(of: exchange) {
        case .notSent:
          note(
            icon: "clock.arrow.circlepath", title: "Not sent yet",
            detail: "This batch has no request on the wire yet, so there is no input to show — it appears here the moment it goes out.")
        case .noRequest:
          note(
            icon: "memorychip", title: "No request was spent",
            detail: "Translation memory answered every item of this batch, so nothing was asked of the model (6.2).")
        case .failed:
          note(
            icon: "exclamationmark.triangle", title: "No input",
            detail: "The batch failed before a request was built. The run's failure report carries the reason.")
        case .input(let request):
          blocks(request)
        }
      }
    }

    /// The REPLY: what came back, printed as it came — or why nothing did.
    @ViewBuilder
    private var replyHalf: some View {
      VStack(alignment: .leading, spacing: 0) {
        halfHeader(
          icon: "arrow.down.circle", title: "Model reply",
          detail: "Raw and unparsed: this is the batch's answer exactly as it arrived.")
        switch Self.replyState(of: exchange.reply) {
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
          text(raw).padding(.bottom, 12)
        }
      }
    }

    // MARK: - one request, printed

    /// A request as the wire carried it: the system message, then the user message with the
    /// cacheable prefix's end marked inside it.
    private func blocks(_ request: Prompt.Request) -> some View {
      VStack(alignment: .leading, spacing: 0) {
        blockLabel("System message")
        text(request.system)
        blockLabel("User message")
        userMessage(request, Self.cacheable(of: request))
      }
    }

    /// The user message, SPLIT AT THE PREFIX: what stands above the rule is what the provider may
    /// cache, and the rule says how much of what was sent that is. The prefix always covers the
    /// system message, so its end is drawn inside the user message or at one of its edges.
    @ViewBuilder
    private func userMessage(_ request: Prompt.Request, _ cacheable: Cacheable?) -> some View {
      if let cacheable, cacheable.isInsideUserMessage {
        text(String(request.user.prefix(cacheable.userOffset)))
        boundary(cacheable, at: .cut)
        text(String(request.user.dropFirst(cacheable.userOffset)))
      } else if let cacheable, cacheable.userOffset >= cacheable.userCharacters {
        text(request.user)
        boundary(cacheable, at: .end)
      } else if let cacheable {
        boundary(cacheable, at: .start)
        text(request.user)
      } else {
        text(request.user)
      }
    }

    /// Where the boundary sits, which decides what the caption can say about it.
    private enum Edge {
      /// The prefix is the system message alone: the user message is entirely uncached.
      case start
      /// The prefix ends part-way through the user message — the ordinary case.
      case cut
      /// Everything sent is cacheable.
      case end
    }

    /// The prefix's end, drawn as a rule across the input. It is what makes the tally's cached
    /// share checkable: a prefix that moved is visible here before the share reads zero (5.7).
    private func boundary(_ cacheable: Cacheable, at edge: Edge) -> some View {
      HStack(spacing: 8) {
        Rectangle().fill(.tertiary).frame(height: 1)
        Text(caption(cacheable, at: edge))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Rectangle().fill(.tertiary).frame(height: 1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }

    private func caption(_ cacheable: Cacheable, at edge: Edge) -> String {
      switch edge {
      case .start:
        "cacheable prefix ends here, with the system message: \(cacheable.characters) characters of what was sent are cacheable, the user message is not"
      case .cut:
        "cacheable prefix ends here: \(cacheable.characters) characters of what was sent, system message included"
      case .end:
        "cacheable prefix ends here: everything this request sent is cacheable (\(cacheable.characters) characters)"
      }
    }

    private func halfHeader(icon: String, title: String, detail: String) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: icon).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline.weight(.semibold))
          Text(detail).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .padding(.bottom, 4)
    }

    /// What a body on the wire IS — a label, not a title: raw text needs no decoration.
    private func blockLabel(_ label: String) -> some View {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    /// One message or reply body, verbatim and selectable.
    private func text(_ body: String) -> some View {
      Text(body)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
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

  /// The four previews' stand-in for the request `Prompt` assembles.
  ///
  /// A preview has no project to build a real request from, and the pane draws where the
  /// provider's CACHEABLE PREFIX ends — an offset that only means something if the blocks are in
  /// the order the wire carries them (4.3: L0, then L1, then L2, the payload last, each block one
  /// function). So a fixture assembles its input here, in that order, from the page's OWN items
  /// and from the CLOSED SET of item fields (`comment`, `maxWidth`, `source`, `target` — plus
  /// `language` on a row batch, and never the key).
  ///
  /// It is a FIXTURE, not a second builder: nothing in the run reads it, nothing here writes
  /// anything, and it lives beside the pane it feeds rather than beside `Prompt`.
  enum SampleRequest {
    /// A body on the wire: a flat value, or an object of plural category -> text (4.3).
    enum Body: Equatable {
      case text(String)
      case forms([String: String])
    }

    /// One item as the payload carries it.
    struct Item {
      let source: Body
      let target: Body
      let comment: String
      var maxWidth: Int = 0
      /// A row batch names each item's language; a language batch names its own instead.
      var language: String? = nil
    }

    /// A `StringBody` as the payload carries it.
    static func body(_ body: Translation.StringBody) -> Body {
      switch body {
      case .value(let text):
        return .text(text)
      case .plural(let plural):
        return .forms(
          Dictionary(
            plural.values.map { ($0.rule.rawValue, $0.value) },
            uniquingKeysWith: { first, _ in first }))
      }
    }

    /// A lesson, as the fold's own request carries it (`Prompt.Lesson`).
    struct Lesson {
      let key: String
      let source: String
      let comment: String
      let machine: String
      let value: String
    }

    /// The system message. The real one is per shape and long, so the fixture carries the shape
    /// — job, direction, the JSON array asked for — abridged rather than invented, because the
    /// system text is the outermost part of the cacheable prefix and a fixture that changed the
    /// shape would mark the boundary in the wrong place.
    static let system = """
      You are a careful software-localization translator. The items to translate are in the \
      "ITEMS" section of the user message; the target language is named in the \
      "TARGET LANGUAGE" section.

      Rules:
      1. Output ONLY a JSON array — no prose, no markdown fences. Each element is \
      {"id": <the item's id>, "text": <the translation>}, one element per input item, in the \
      same order.
      2. An item's "id" is its position in this batch: echo it back unchanged.
      3. Preserve placeholders (%@, %11$@, %lld, {name}), format specifiers and code tokens \
      exactly as written.
      4. Context sections in the user message are authoritative.
      5. When an item's "source" and "target" are OBJECTS of plural categories, answer with the \
      same object shape, one entry per category.
      6. A filled "target" is the current value of that slot: produce the better translation for \
      the same slot, or answer with the same value when it is already right.
      7. When an item carries "maxWidth", keep the translation within that many characters if \
      you can do it without losing meaning.
      """

    /// L0: the same for every target language of a project, which is the whole reason it is the
    /// cacheable part (4.3). One project, so the fixtures share one L0.
    static let shared = [
      """
      CONTEXT — GLOBAL
      Hermes is the product name: never translated, never declined.
      Use the formal register throughout the UI.
      """,
      """
      CONTEXT — PROJECT
      Buttons read as an imperative ("Save", "Cancel"), never as a noun.
      Settings tab names are one word.
      """,
    ]

    /// The lesson lines the fixtures' language documents carry, by language, in the redesign's own
    /// format (3.7: KEY<TAB>SOURCE<TAB>VALUE, real tabs) — the L1 block a batch of that language
    /// travels with.
    static let documents: [String: [String]] = [
      "ru": [
        "button.save\tSave\tСохранить",
        "sidebar.projects\tProjects\tПроекты",
        "alert.title\tSomething went wrong\tПроизошла ошибка",
      ],
      "de": [
        "button.save\tSave\tSichern",
        "tabs.general\tGeneral\tAllgemein",
        "status.reviewed\tReviewed\tGeprüft",
      ],
      "ja": [
        "button.save\tSave\t保存",
        "items.count\t%d strings\t%d件",
        "settings.title\tSettings\t設定",
      ],
      "ar": [
        "settings.title\tSettings\tالإعدادات",
        "button.delete\tDelete\tحذف",
        "tabs.advanced\tAdvanced\tمتقدّم",
      ],
    ]

    /// The register sample (`EXISTING TRANSLATIONS`): what this project already says in the
    /// language, as the source = value pairs the block is made of (4.3).
    static let register: [String: [String]] = [
      "ru": ["Settings = Настройки", "Cancel = Отмена", "Delete = Удалить"],
      "de": ["Cancel = Abbrechen", "Delete = Löschen", "Settings = Einstellungen"],
      "ja": ["Cancel = キャンセル", "Delete = 削除", "General = 一般"],
      "ar": ["Save = حفظ", "Cancel = إلغاء", "Delete = حذف"],
    ]

    /// A language batch: L0 (global, project), L1 (target language, its lesson document, the
    /// register sample), then L2 — the ITEMS payload last (`Prompt.languageBatch`).
    static func languageBatch(language: String, items: [Item]) -> Prompt.Request {
      var rest = ["TARGET LANGUAGE\n" + language]
      if let lines = documents[language], !lines.isEmpty {
        rest.append("CONTEXT — LANGUAGE (\(language))\n" + lines.joined(separator: "\n"))
      }
      if let lines = register[language], !lines.isEmpty {
        rest.append("EXISTING TRANSLATIONS (\(language))\n" + lines.joined(separator: "\n"))
      }
      rest.append("ITEMS\n" + json(items))
      return request(system: system, l0: shared, rest: rest, ids: positions(count: items.count))
    }

    /// A row batch: L0 then ITEMS, each item naming its own language — no L1 block at all
    /// (`Prompt.rowBatch`), because the row's settled columns ARE its reference.
    static func rowBatch(items: [Item]) -> Prompt.Request {
      request(
        system: system, l0: shared, rest: ["ITEMS\n" + json(items)],
        ids: positions(count: items.count))
    }

    /// The learn fold: a request of its own shape, with NO L0/L1 blocks and no ids — its reply is
    /// document TEXT rather than a per-id map (`Prompt.learnFold`), which is exactly why the pane
    /// marks no cacheable boundary on it.
    static func learnFold(language: String, lessons: [Lesson], document: [String]) -> Prompt.Request {
      let lines: [[String: Any]] = lessons.map { lesson in
        [
          "key": lesson.key, "source": lesson.source, "comment": lesson.comment,
          "machine": lesson.machine, "value": lesson.value,
        ]
      }
      let body = document.joined(separator: "\n")
      let user = """
        LESSONS — what the machine produced vs what the human settled on
        \(jsonRows(lines))

        CURRENT \(language.uppercased()) DOCUMENT — \(body.count) characters, budget \(Limits.languageContext)
        \(body.isEmpty ? "(the document is empty)" : body)
        """
      return Prompt.Request(
        system: """
          You are the learning engine of a software-localization pipeline. You maintain ONE \
          plain-text document of accumulated lessons for the target language "\(language)". Your \
          job is the line (or lines) this fold APPENDS to the document — the fields are KEY, \
          SOURCE and VALUE, separated by real tab characters, one line per lesson, and nothing \
          else. Reply with exactly the single line NO_CHANGE when the document already covers \
          every lesson.
          """,
        user: user)
    }

    // MARK: - assembly

    /// The order `Prompt.request` uses, and the same prefix rule: the system message plus the L0
    /// blocks, laid out exactly as the two messages are laid out, which is what makes the
    /// boundary the pane draws a real one.
    private static func request(
      system: String, l0: [String], rest: [String], ids: [String]
    ) -> Prompt.Request {
      Prompt.Request(
        system: system,
        user: (l0 + rest).joined(separator: RawExchangePane.messageSeparator),
        ids: ids,
        cacheablePrefix: ([system] + l0).joined(separator: RawExchangePane.messageSeparator))
    }

    private static func positions(count: Int) -> [String] {
      (0..<count).map { String($0) }
    }

    /// The ITEMS payload, deterministic the way `Prompt.json` is (sorted keys, no escaped
    /// slashes) so a fixture's request reads like the one the wire carries.
    private static func json(_ items: [Item]) -> String {
      let rows: [[String: Any]] = items.enumerated().map { index, item in
        var row: [String: Any] = [
          "id": index, "source": jsonBody(item.source), "target": jsonBody(item.target),
        ]
        if !item.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          row["comment"] = item.comment
        }
        if item.maxWidth > 0 {
          row["maxWidth"] = item.maxWidth
        }
        if let language = item.language {
          row["language"] = language
        }
        return row
      }
      return jsonRows(rows)
    }

    /// A body as JSON: a string for a flat value, an object of category -> text for a plural
    /// one. An empty skeleton therefore travels as the same categories with empty strings, which
    /// is the "fill these" signal the model is given (4.3).
    private static func jsonBody(_ body: Body) -> Any {
      switch body {
      case .text(let text): return text
      case .forms(let forms): return forms
      }
    }

    private static func jsonRows(_ rows: [[String: Any]]) -> String {
      guard !rows.isEmpty,
        let data = try? JSONSerialization.data(
          withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]),
        let text = String(data: data, encoding: .utf8)
      else { return "[]" }
      return text
    }
  }
}

#Preview {
  Translation.VerticalTranslate.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
