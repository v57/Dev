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
  /// A lesson is a DIFFERENCE: what the model produced against what the human
  /// settled on. There is no value to watch being written here — the output of this
  /// stage is a line in the language document, so each row shows the lesson and the
  /// line it becomes.
  ///
  /// SPLIT IN HALF (8.1, "stage pages"): those lessons on the left as they always were,
  /// and the batch's EXCHANGE on the right — here a DOCUMENT, not a set of candidates, which is
  /// exactly why the raw text is worth seeing.
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
    func mark(_ item: Translation.VerticalLearn.Operation) -> Translation.RowMark {
      Translation.RowMark(phase: item.phase, inFlight: "graduationcap")
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
                Image(systemName: mark(item).icon).font(.title.bold()).frame(width: 32, height: 32)
                  .opacity(mark(item).isWaiting ? 0.1 : 1)
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
              }.foregroundStyle(mark(item).color)
              // The mark settles when the MARK changes — never on a change to the row's value or
              // the phase, which a run moves on every row it lands (8.1) — and it does so at once:
              // rows land in realtime, so there is no wave to pace.
              .animation(.smooth, value: mark(item).color)
                .id(index)
            }
          }.padding(32)
            .scrollTargetLayout()
        }.contentTransition(.symbolEffect)
          .scrollPosition(id: $rowPosition, anchor: .center)
          .task(id: Translation.lastLanded(in: operation.items)) {
            // The list follows the row that just landed, centred (reader, 2026-09-15): rows are
            // written one at a time (5.12), so the page follows the ROW rather than the batch.
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
  struct Test: View {
    @State var index = 0
    @State var operations: [Operations] = Test.sample
    /// Both sides of the exchange each of this sample's batches has with the model, PARALLEL to
    /// `operations` — the right half of every page (8.1). It starts as `Test.exchanges` and the
    /// preview's own fake run fills a page in as it lands, exactly as `Runner` sets the batch's
    /// input when it goes out and its reply when the call returns.
    @State var exchanges: [Translation.Run.Exchange] = Test.exchanges

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

    /// The INPUT of every page, aligned with `sample` (8.1): the request the fold sends — its
    /// lessons, then the document it is folding into (`Prompt.learnFold`), which is why this page
    /// carries NO L0/L1 blocks and no cacheable boundary to mark.
    static var requests: [Translation.Prompt.Request] {
      sample.map { batch in
        Translation.SampleRequest.learnFold(
          language: batch.language,
          lessons: batch.items.map { item in
            Translation.SampleRequest.Lesson(
              key: item.key, source: item.source.catalogValue, comment: item.comment,
              machine: item.machine.catalogValue, value: item.target.catalogValue)
          },
          document: Translation.SampleRequest.documents[batch.language] ?? [])
      }
    }

    /// What each page's right half starts with, aligned with `sample`: the batches that were SENT
    /// carry their input, the folded batch carries the lines it folded, the failed one carries the
    /// prose that made it fail, and the batch nobody has reached has not been sent — so its pane
    /// says so on BOTH halves instead of showing two unexplained empty boxes.
    static var exchanges: [Translation.Run.Exchange] {
      [
        Translation.Run.Exchange(
          request: requests[0], reply: Translation.Run.Reply(raw: answers[0], phase: .applied)),
        Translation.Run.Exchange(
          request: requests[1], reply: Translation.Run.Reply(raw: answers[1], phase: .failed)),
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
              // Nothing to resolve: what this stage writes is the document, not a
              // value. Folding the batch is the whole visible effect.
              withAnimation {
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
                // The fold went out and was answered: its page's right half fills in the same
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
}

#Preview("Learn") {
  Translation.VerticalLearn.Test()
    .frame(minWidth: .infinity, maxHeight: .infinity)
}
