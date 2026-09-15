//
//  Horizontal translate UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//

import SwiftUI

extension Translation.HorizontalTranslate {
  /// One row of the journal, narrowed to what this page reads: what a write to one
  /// COLUMN said before (`from`) and what it says now (`to`).
  ///
  /// The page cannot tell a column the pass FILLED from one it REWROTE by looking at
  /// the slot: both end the pass `.translated` (4.6), and the row pass's real output
  /// is the second kind — a column that already held machine output, rewritten to
  /// agree with the row's settled sibling. What separates them is the value the
  /// column held BEFORE the write, and that is the journal's own pair
  /// (`TranslationEdit.fromValue` -> `toValue`). So the distinction is a READ: it is
  /// not a field on the operation, and not a field on the slot — nothing on the
  /// stage's side of the wire records it.
  struct Write: Equatable {
    /// The catalog key of the column's row. App-side, like everything the journal
    /// addresses by (4.3).
    let key: String
    let language: String
    /// The value before the write — EMPTY when the column had nothing, which is
    /// exactly what makes a filled column read as newly written rather than adjusted.
    let from: String
    /// The value the write left.
    let to: String
  }

  /// One project's journal, oldest first, as this page reads it.
  ///
  /// A synchronous main-actor fetch (7.1), and the ONE thing the page reads that the
  /// run's batches do not carry — which is why the live page is handed it rather
  /// than fetching per column: a page per batch is one read. Machine writes only
  /// (`editor == .provider`): what the page reports is what this PASS did, and a
  /// human's edit is not its work.
  static func journal(of project: Translation.Project) -> [Write] {
    let edits = (try? project.global.store.edits(project: project.id, confirmedOnly: false)) ?? []
    return edits.compactMap { edit in
      guard edit.editor == .provider,
        let key = edit.record?.key,
        let language = edit.record?.language
      else { return nil }
      return Write(key: key, language: language, from: edit.fromValue ?? "", to: edit.toValue)
    }
  }

  struct Content: View {
    let index: Int
    let operations: [Operations]
    /// BOTH SIDES of each page's exchange, PARALLEL to `operations` (8.1, "stage pages"): the
    /// input the batch sent and the reply it got back, one value per batch. The page shows one
    /// batch, so its exchange is the entry at the page's own offset; a caller that supplies none
    /// gets the "nothing sent yet" reading on both halves rather than a crash.
    var exchanges: [Translation.Run.Exchange] = []
    /// The journal this page reads (`Write`): the live page is handed its project's
    /// (`journal(of:)`), the design preview its sample's. Empty is legal and shows
    /// the pre-pass reading only — no write is claimed without evidence.
    var journal: [Write] = []
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
              OperationContent(operation: element, exchange: exchange(at: offset), journal: journal).frame(width: view.size.width, height: view.size.height)
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
  /// A page per ROW, not per language: one request carries every column of the row,
  /// and the settled columns travel with it as context. So the page is a row — the
  /// source on top, then one line per language, showing what each column holds and
  /// what this pass did to it.
  ///
  /// SPLIT IN HALF (8.1, "stage pages"): those rows on the left as they always were and
  /// the batch's EXCHANGE on the right — what was sent, and what came back.
  struct OperationContent: View {
    let operation: Operations
    /// Both sides of this batch's exchange — what the right half prints, unread.
    let exchange: Translation.Run.Exchange
    /// The row the list is showing, bound to the list's own scroll position exactly as the batch
    /// pager above is bound to the batch (8.1, "PACING"): the page follows the last row the run
    /// ANSWERED rather than the batch it belongs to (reader, 2026-09-15), because rows are written
    /// one at a time now (5.12).
    @State var rowPosition: Int?
    /// The journal, so the page can tell a column this pass FILLED from one it
    /// REWROTE (`outcome(_:)`). Empty claims nothing.
    var journal: [Write] = []
    /// The mark THIS row carries (8.1, "stage pages"): the row's own state, never the
    /// batch's. The page's item is a ROW, so this is the reading the page draws — and the
    /// batch's own mark, which the heading carries, never reaches a row.
    func mark(_ row: Operation) -> Translation.RowMark {
      Translation.RowMark(phase: row.phase, inFlight: "tablecells")
    }
    /// The batch's own mark, for the heading only: it reads as the page's summary of the
    /// request. A batch that wrote anything is applied, so an xmark here appears exactly
    /// when the batch wrote NOTHING (`Runner.settle`).
    var color: Color {
      if operation.isFailed {
        .red
      } else if operation.isCompleted {
        .green
      } else {
        .primary
      }
    }
    /// The same batch mark, as the heading's icon. A row never draws this: every row carries
    /// its own (`mark(_:)`).
    var icon: String {
      if operation.isFailed {
        "xmark.circle.fill"
      } else if operation.isCompleted {
        "checkmark.circle.fill"
      } else {
        "tablecells"
      }
    }
    /// What this pass did to ONE column of the row.
    ///
    /// The column's STATUS says what the pass is allowed to touch — `.verified` and
    /// `.imported` are the reference the request carries and are never written (4.6)
    /// — and the journal says what it DID. Both a column the pass filled from nothing
    /// and a column it rewrote over machine output end the pass `.translated`, so the
    /// two are told apart by the value the column held BEFORE the write, which only
    /// the journal has (`Write`).
    enum Outcome: Equatable {
      /// Nothing this pass wrote is on record for the column: it has not been reached,
      /// or the value on screen is not this write's. No tag.
      case waiting
      /// It had NOTHING and now holds machine output.
      case written
      /// It HAD machine output and the pass rewrote it — the row pass's whole point
      /// (4.6): a column adapted to agree with what the row's settled sibling says.
      /// `previous` is what it said before, and nil when the rewrite landed the same
      /// text, because "had a value, NOW DIFFERENT" is what this page reports.
      case adjusted(previous: Translation.StringBody?)
      /// `.verified` / `.imported`: left alone. It travels as the request's reference.
      case context
      /// `.ignore`: out of scope for every stage, and the value it has is kept.
      case outOfScope
      /// THIS ROW failed before the column was reached — the row's own state, never the
      /// batch's: a batch that wrote some of its rows is applied, and the rows it did not
      /// answer are the ones that carry the failure.
      case failed
    }
    func outcome(_ slot: Translation.LocalizationString, of row: Operation) -> Outcome {
      switch slot.status {
      case .verified, .imported: return .context
      case .ignore: return .outOfScope
      // Work, and nothing landed in it: the pass has not got here yet, or the row
      // failed before it did.
      case .needsTranslate, .stale: return row.phase == .failed ? .failed : .waiting
      case .translated:
        // Machine output. Read what it said before the write that left it: an empty
        // `from` is a column this pass FILLED, anything else one it REWROTE.
        guard let from = previousValue(of: slot, in: row) else {
          return row.phase == .failed ? .failed : .waiting
        }
        return from.isEmpty
          ? .written
          : .adjusted(previous: from == slot.target.catalogValue ? nil : .value(from))
      }
    }
    /// The value the column held before the write now on screen — the journal's
    /// `fromValue`, and nil when no write of this pass put what the page shows there.
    ///
    /// The journal is append-only, one row per value change, so the row that matters
    /// is the LATEST one for this column whose `to` is a value the column holds NOW: a
    /// write that ended on another value belongs to an earlier pass and says nothing
    /// about this one. (A plural slot journals one row per form, so the form the write
    /// named is the one compared.)
    func previousValue(of slot: Translation.LocalizationString, in row: Operation) -> String? {
      journal
        .filter { $0.key == row.key && $0.language == slot.language }
        .last { holds(slot, $0.to) }?
        .from
    }
    /// Whether the column holds `value` now: a flat body is its text, a plural body is
    /// any of its forms.
    private func holds(_ slot: Translation.LocalizationString, _ value: String) -> Bool {
      guard !value.isEmpty else { return false }
      switch slot.target {
      case .value(let text): return text == value
      case .plural(let plurals): return plurals.values.contains { $0.value == value }
      }
    }
    /// The word the column's outcome earns, in the page's one tag style (next to the
    /// value, caption2, tertiary — the "context" tag was already there, unchanged).
    func tag(_ outcome: Outcome) -> String? {
      switch outcome {
      case .written: "written"
      case .adjusted: "adjusted"
      case .context: "context"
      case .failed: "failed"
      case .waiting, .outOfScope: nil
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
      HStack(spacing: 0) {
        // The batch's own rows — what this page always showed, now at half the width.
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  // The ROW's own mark (8.1, "stage pages"): this row's state, never the
                  // batch's — the heading above carries the batch's own.
                  Image(systemName: mark(item).icon)
                    .opacity(mark(item).isWaiting ? 0.4 : 1)
                    .foregroundStyle(mark(item).color)
                  Text(item.key).font(.headline.monospaced())
                }
                Translation.VerticalTranslate.StringView(value: item.source)
                  .font(.callout)
                  .foregroundStyle(.secondary)
                ForEach(item.targets.enumerated(), id: \.offset) { (index, slot) in
                  let outcome = outcome(slot, of: item)
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
                    // What the column said BEFORE the write, when this pass rewrote it:
                    // the adjusted column is the change the row pass exists to make, so
                    // the page shows the change.
                    if case .adjusted(let previous) = outcome, let previous {
                      Text("was").font(.caption2).foregroundStyle(.tertiary)
                      Translation.VerticalTranslate.StringView(value: previous)
                        .font(.caption2).foregroundStyle(.tertiary).strikethrough()
                    }
                    if let tag = tag(outcome) {
                      Text(tag).font(.caption2).foregroundStyle(.tertiary)
                    }
                  }
                }
              }
              // The row's own colour, taken from the row's own mark: the batch's colour is
              // the heading's, and a row reads red or green for its OWN state.
              .foregroundStyle(mark(item).color)
              .padding(.vertical, 4)
              .id(rowIndex)
              if rowIndex < operation.items.count - 1 {
                Divider().opacity(0.4)
              }
            }
          }.padding(32)
            .scrollTargetLayout()
        }
          // The ONE transition left on a page's rows (the reader turned animations off, 2026-09-15):
          // a mark's SF Symbol still swaps with its effect, which is a per-CHANGE animation on the
          // mark itself rather than the standing wave 8.1 profiled.
          .contentTransition(.symbolEffect)
          .scrollPosition(id: $rowPosition, anchor: .center)
          .task(id: Translation.lastLanded(in: operation.items)) {
            // The list follows the ROW that just landed, centred (reader, 2026-09-15): a row is
            // written the moment its columns are decided (5.12), so the page follows the row the
            // model has finished rather than the batch.
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
    /// input when it goes out and its reply when a call returns.
    @State var exchanges: [Translation.Run.Exchange] = Test.exchanges
    /// The journal this page reads, and the preview's second half: it starts as the
    /// sample's own values imply and GROWS as the preview's write-back lands, exactly
    /// as the runner's write-back appends one journal row per slot it applies (5.5).
    /// That is what makes the preview show a column being ADJUSTED rather than merely
    /// filled — the pass's real output.
    @State var journal: [Write] = Test.journal

    /// Sample batches for the design preview: ten ROWS each, in the three states a
    /// batch can be in.
    ///
    /// The row travels whole (that is the shape's point), so every row below carries
    /// its settled column as context plus the columns this pass may write:
    ///   `.verified`  the human's own value — never written, always context
    ///   `.imported`  a shipped translation — same deal, shown in its own colour
    ///   `.translated` machine output this pass wrote, or REWROTE over earlier
    ///                machine output; which one is the journal's to say, and the two
    ///                rows built from `Test.journal` below are the rewritten kind
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

    // MARK: - sample journal

    /// The journal the sample's own values imply, plus the two rows that make the
    /// page's point visible in the preview.
    ///
    /// Every `.translated` column of the sample was written by this pass — the
    /// fixture's own comments say so — and a column the pass FILLED from nothing
    /// journals an EMPTY `from`. Two columns were ADJUSTED instead: they already held
    /// machine output when the row pass ran, and it rewrote them to agree with the
    /// column the human verified (4.6). Those two are the pass's real output, and they
    /// are the columns the page tags "adjusted" and shows a previous value for. They
    /// are APPENDED, so they are the latest row for their column and win the read.
    static let journal: [Write] = {
      var writes = sample.flatMap { batch in
        batch.items.flatMap { row in
          row.targets
            .filter { $0.status == .translated && !$0.target.isEmpty }
            .map { Write(key: row.key, language: $0.language, from: "", to: $0.target.catalogValue) }
        }
      }
      writes.append(
        Write(key: "settings.title", language: "de",
              from: "Einstellungen (Fenster)", to: "Einstellungen"))
      writes.append(
        Write(key: "sidebar.projects", language: "ja",
              from: "プロジェクト一覧", to: "プロジェクト"))
      return writes
    }()

    /// One row per column a write-back just rewrote: the preview's stand-in for the
    /// journal append in `Runner.persist` (5.5). `from` is what the column said before
    /// the write — EMPTY when it had nothing, which is what keeps a filled column
    /// reading as newly written, and what makes a column that already had machine
    /// output read as adjusted.
    static func writes(from before: [Operation], to after: [Operation]) -> [Write] {
      zip(before, after).flatMap { (previous, row) in
        zip(previous.targets, row.targets).compactMap { (was, now) in
          guard was.target != now.target else { return nil }
          return Write(
            key: row.key, language: now.language,
            from: was.target.catalogValue, to: now.target.catalogValue)
        }
      }
    }

    // MARK: - sample replies

    /// The raw text each batch answered with, aligned with `sample` — the fixture's honest
    /// replies, not lorem ipsum. A ROW batch is the same shape as a language batch (4.3):
    /// `{"id": <position>, "text": …}`, one element per item in row order — a row is one
    /// item per language, settled columns included — and a plural column answers an OBJECT
    /// of its language's categories. Every text is the value the fixture's own left half
    /// shows for that column, so the two halves can be read against each other.
    static let answers: [String] = [
      // The finished batch: ten rows, three columns each, thirty items — the id order the
      // request asked for. The ru column is the human's and travels as context; its answer
      // is discarded (4.6), which is why it repeats the value the row already holds.
      """
      [{"id": 0, "text": "Настройки"},
       {"id": 1, "text": "Einstellungen"},
       {"id": 2, "text": "設定"},
       {"id": 3, "text": "Сохранить"},
       {"id": 4, "text": "Sichern"},
       {"id": 5, "text": "保存"},
       {"id": 6, "text": "Отмена"},
       {"id": 7, "text": "Abbrechen"},
       {"id": 8, "text": "キャンセル"},
       {"id": 9, "text": "Удалить"},
       {"id": 10, "text": "Entfernen"},
       {"id": 11, "text": "削除"},
       {"id": 12, "text": "Проекты"},
       {"id": 13, "text": "Projekte"},
       {"id": 14, "text": "プロジェクト"},
       {"id": 15, "text": "Сеансы"},
       {"id": 16, "text": "Sitzungen"},
       {"id": 17, "text": "セッション"},
       {"id": 18, "text": {"one": "%d строка", "few": "%d строки", "many": "%d строк", "other": "%d строки"}},
       {"id": 19, "text": {"one": "%d Eintrag", "other": "%d Einträge"}},
       {"id": 20, "text": {"other": "%d件"}},
       {"id": 21, "text": {"one": "%d файл выбран", "few": "%d файла выбрано", "many": "%d файлов выбрано", "other": "%d файла выбрано"}},
       {"id": 22, "text": {"one": "%d Datei ausgewählt", "other": "%d Dateien ausgewählt"}},
       {"id": 23, "text": {"other": "%d件のファイル"}},
       {"id": 24, "text": {"one": "%d строка выбрана", "few": "%d строки выбрано", "many": "%d строк выбрано", "other": "%d строки выбрано"}},
       {"id": 25, "text": {"one": "%d Eintrag ausgewählt", "other": "%d Einträge ausgewählt"}},
       {"id": 26, "text": {"other": "%d件を選択中"}},
       {"id": 27, "text": "Экспорт %d из %d…"},
       {"id": 28, "text": "Exportiere %d von %d…"},
       {"id": 29, "text": "%d / %d を書き出し中…"}]
      """,
      // The failed batch, and the reason the pane is worth having: the model stopped
      // mid-array after three of the ten rows, so this is ALL that came back. A cut reply is
      // reported as truncation and re-asked in halves (5.3) — the answers it did complete
      // are the ones a reader can check against the rows.
      """
      [{"id": 0, "text": "Произошла ошибка"},
       {"id": 1, "text": "Ein Fehler ist aufgetreten"},
       {"id": 2, "text": "エラーが発生しました"},
       {"id": 3, "text": "Повторить"},
       {"id": 4, "text": "Wiederholen"},
       {"id": 5, "text": "再試行"},
       {"id": 6, "text": "Hermes хранит проекты, сеансы и переводы в одном месте."},
       {"id": 7, "text": "Projekte, Sitzungen und Übersetzungen — alles an einem Ort."
      """,
      // The batch nobody has sent yet: the reply it answers with when the preview's fake run
      // lands it — built from the sample's OWN text (`lateAnswer`).
      lateAnswer,
    ]

    /// The reply the untouched batch answers with, built from the sample's own values rather
    /// than written out again: a row batch is thirty items of text the left half already
    /// shows, so the honest fixture is that text, one element per (row, language) in the
    /// request's id order. A plural column answers the form the artifact reads
    /// (`StringBody.catalogValue`).
    static var lateAnswer: String {
      var id = 0
      var elements: [String] = []
      for row in sample[2].items {
        for slot in row.targets {
          elements.append("{\"id\": \(id), \"text\": \"\(slot.target.catalogValue)\"}")
          id += 1
        }
      }
      return "[" + elements.joined(separator: ",\n ") + "]"
    }

    /// The INPUT of every page, aligned with `sample` (8.1): the request the row pass sends — L0,
    /// then ONE item per (row, language) with each item naming its OWN language and the settled
    /// columns travelling with it (4.6). There is no L1 block at all, which is why the row page's
    /// input reads shorter than the column pages' — and why its items carry the language instead.
    /// It is assembled from the sample's own rows, so a page's input and its reply describe the
    /// same batch.
    static var requests: [Translation.Prompt.Request] {
      sample.map { batch in
        Translation.SampleRequest.rowBatch(
          items: batch.items.flatMap { row in
            row.targets.map { slot in
              Translation.SampleRequest.Item(
                source: Translation.SampleRequest.body(row.source),
                target: Translation.SampleRequest.body(slot.target),
                comment: row.comment, maxWidth: row.maxWidth, language: slot.language)
            }
          })
      }
    }

    /// What each page's right half starts with, aligned with `sample`: the batches that were SENT
    /// carry their input, the finished batch carries its reply, the failed one carries the
    /// cut-off text that made it fail, and the untouched batch has not been sent — so its pane
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
      Content(index: index, operations: operations, exchanges: exchanges, journal: journal)
        .task {
          do {
            for i in 0..<operations.count {
              index = i
              try await Task.sleep(for: .seconds(2))
              let rewritten = operations[i].items.map { $0.resolve($0.source.reversed()) }
              journal += Test.writes(from: operations[i].items, to: rewritten)
              // The ROWS' own state, the way the runner leaves it (`Runner.settle`): a batch
              // that wrote its rows applied them one by one, and the batch this fixture marks
              // failed wrote nothing, so its rows carry the failure themselves — which is what
              // the page marks, and never the batch's own flag.
              let failed = operations[i].isFailed
              operations[i].items = rewritten.map { item in
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
