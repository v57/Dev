//
//  Localization view.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row filter

enum RowFilter: String, CaseIterable, Identifiable {
  case all
  case needsReview
  case missing
  case translated
  case new

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .needsReview: return "Needs review"
    case .missing: return "Missing"
    case .translated: return "Translated"
    case .new: return "New"
    }
  }

  var icon: String {
    switch self {
    case .all: return "tray.full"
    case .needsReview: return "exclamationmark.magnifyingglass"
    case .missing: return "questionmark.circle"
    case .translated: return "checkmark.circle"
    case .new: return "sparkles"
    }
  }
}

// MARK: - Row model

/// One table row = one catalog key, with override-aware display values.
struct CatalogRow: Identifiable {
  let key: String
  /// shouldTranslate == false keys get a glyph and no editable cells.
  let isTranslatable: Bool
  /// Source-language display text (explicit source value, else the key text).
  let sourceText: String
  /// Longest value across all languages (override-aware, source included).
  let longestText: String
  let longestLanguage: String
  let longestLength: Int
  let commentText: String
  /// Display state of every selected non-source language column.
  let cells: [String: LangCell]
  /// Pre-folded haystack for search (empty when search is inactive).
  let searchBlob: String

  var id: String { key }
}

/// Display state of one language cell (missing, edited, variation…).
struct LangCell {
  let text: String
  /// Parsed file state — display only, never flipped by edits.
  let state: String?
  let hasParsed: Bool
  let hasOverride: Bool
  let hasVariations: Bool
  let isEditable: Bool
  /// Live SwiftData record of the (key, language) slot — the cell's dot,
  /// spinner, provenance tooltip and mid-run text read it directly. Nil for
  /// variation holders and non-translatable keys, which reconcile does not
  /// model.
  let record: TranslationRecord?

  /// No value at all: no parsed unit, no override, and no variations to show.
  var isMissing: Bool { !hasParsed && !hasOverride && !hasVariations }
}

// MARK: - Sort comparator

/// Custom comparator so language columns (chosen at runtime) can sort, and so
/// missing/absent values always sort last, in either direction.
struct CatalogSort: SortComparator, Hashable {
  enum Column: Hashable {
    case comment
    case source
    case longest
    case language(String)
  }

  var column: Column
  var order: SortOrder = .forward

  typealias Compared = CatalogRow

  init(_ column: Column, order: SortOrder = .forward) {
    self.column = column
    self.order = order
  }

  /// Column identity only — ascending/descending of the same column is one
  /// sort key for the header state machine.
  static func == (lhs: CatalogSort, rhs: CatalogSort) -> Bool {
    lhs.column == rhs.column
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(column)
  }

  func compare(_ lhs: CatalogRow, _ rhs: CatalogRow) -> ComparisonResult {
    if column == .longest {
      return Self.compareLongest(lhs, rhs, order: order)
    }
    let a = text(of: lhs)
    let b = text(of: rhs)
    var result = Self.compareText(a, b)
    // Deterministic tie-break: rows are identical on the sort key only when
    // they are the same key, so rows stay stable while other cells edit.
    if result == .orderedSame, lhs.key != rhs.key {
      result = Self.compareText(lhs.key, rhs.key)
    }
    // Flip direction, but keep empty/missing values last in both directions.
    if order == .reverse, !a.isEmpty, !b.isEmpty {
      result = result.reversed
    }
    return result
  }

  private func text(of row: CatalogRow) -> String {
    switch column {
    case .comment: return row.commentText
    case .source: return row.sourceText
    case .longest: return row.longestText
    case .language(let language): return row.cells[language]?.text ?? ""
    }
  }

  /// Longest-column comparison: by character count, then text, then key.
  /// Zero-length values sort last in both directions.
  private static func compareLongest(_ lhs: CatalogRow, _ rhs: CatalogRow, order: SortOrder) -> ComparisonResult {
    if lhs.longestLength == 0 && rhs.longestLength == 0 {
      return compareText(lhs.key, rhs.key)
    }
    if lhs.longestLength == 0 { return .orderedDescending }
    if rhs.longestLength == 0 { return .orderedAscending }
    var result: ComparisonResult =
      lhs.longestLength < rhs.longestLength ? .orderedAscending
      : lhs.longestLength > rhs.longestLength ? .orderedDescending
      : compareText(lhs.longestText, rhs.longestText)
    if result == .orderedSame, lhs.key != rhs.key {
      result = compareText(lhs.key, rhs.key)
    }
    if order == .reverse {
      result = result.reversed
    }
    return result
  }

  /// Text comparison with empty/missing sorting last, after any text.
  private static func compareText(_ a: String, _ b: String) -> ComparisonResult {
    if a.isEmpty && b.isEmpty { return .orderedSame }
    if a.isEmpty { return .orderedDescending }
    if b.isEmpty { return .orderedAscending }
    return a.localizedStandardCompare(b)
  }
}

private extension ComparisonResult {
  var reversed: ComparisonResult {
    switch self {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }
}

// MARK: - Store

/// Owns the parsed catalog, load state, view state and the in-memory edit
/// overrides. Since Phase C the catalog is reconciled into SwiftData
/// (Reconcile): every (re)load upserts TranslationRecords from the file —
/// DB-owned provenance (provider, context-versions, state) survives the
/// reload — and every committed cell edit is written through to the DB
/// record AND back into the .xcstrings stringUnit, so edits survive Reload.
/// The file stays the artifact; the DB is the working/provenance store.
@Observable
final class LocalizationStore {
  // MARK: load state

  private(set) var catalog: StringCatalog?
  private(set) var catalogURL: URL?
  private(set) var loadError: String?

  // MARK: SwiftData reconcile

  /// The project this catalog reconciles into (nil until the first load).
  private(set) var project: Project?
  /// Non-nil when the last durable save of an edit failed.
  private(set) var saveError: String?

  // MARK: in-memory edits

  private(set) var valueOverrides: [String: [String: String]] = [:]  // key -> language -> text
  /// Bumped on every (re)load so editing cells can resync their drafts.
  private(set) var revision = 0

  // MARK: view state

  var searchText = ""
  var filter: RowFilter = .all
  var includeNonTranslatable = false
  /// Comments hidden unless the user opts in (off by default).
  var showComments = false
  /// Longest column hidden unless the user opts in (off by default).
  var showLongest = false
  /// Non-source languages with a visible column (source column is permanent).
  private(set) var selectedLanguages: [String] = []
  var sortOrder: [CatalogSort] = [CatalogSort(.source)]

  /// Default language columns on open: none selected (user picks via buttons).
  /// Kept for reference; `open` resets to an empty selection.
  static let defaultColumns: [String] = []

  var isLoaded: Bool { catalog != nil }

  var pickerLanguages: [String] {
    guard let catalog else { return [] }
    return catalog.languages.filter { $0 != catalog.sourceLanguage }
  }

  var sourceLanguageTitle: String {
    guard let catalog else { return "" }
    return "\(catalog.sourceLanguage) (source)"
  }

  var totalKeyCount: Int { catalog?.strings.count ?? 0 }

  /// Keys explicitly marked shouldTranslate = false.
  var nonTranslatableCount: Int {
    catalog?.strings.values.filter { $0.shouldTranslate == false }.count ?? 0
  }

  // MARK: - SwiftData working store (records + run)

  /// Live SwiftData records of the open project, indexed (key, language).
  /// Rebuilt on every reconcile (open/reload); record objects are mutated
  /// in place by edits and pipeline runs, so the refs stay valid.
  private var recordIndex: [String: [String: TranslationRecord]] = [:]

  /// Drives the Translate run lifecycle — progress, cancel, per-cell
  /// in-flight state and the last-run summary. One instance per store.
  let run = TranslateRunController()

  /// True when the Translate button may start a run.
  var canTranslate: Bool { isLoaded && project != nil && !run.isRunning }

  /// Kicks the pipeline off from the Translate button (async Task; re-entry
  /// is guarded by `begin`). When the run returns, the DB is flushed back
  /// into the .xcstrings artifact and the updated catalog is adopted so the
  /// table shows the machine output without a reload.
  func startTranslate() {
    guard let project, run.begin(project: project) else { return }
    Task { await performTranslate(project: project) }
  }

  private func performTranslate(project: Project) async {
    let summary = await run.execute(project: project)
    defer { run.finish(summary) }
    guard let catalog else { return }
    do {
      self.catalog = try Reconcile.commit(catalog, project: project)
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
  }

  /// Translates the open catalog; nil record slots fall back to the file.
  func value(for key: String, language: String) -> String {
    if let override = valueOverrides[key]?[language] { return override }
    // Working-store value first: pipeline fills land in the DB record
    // mid-run and only reach the .xcstrings file at the end-of-run commit,
    // so cells must read the record (not the parsed file) to update as the
    // run writes them.
    if let record = recordIndex[key]?[language],
       let recordValue = record.value,
       !recordValue.isBlankOrEmpty {
      return recordValue
    }
    return catalog?.rawValue(for: key, language: language) ?? ""
  }

  func comment(for key: String) -> String {
    catalog?.strings[key]?.comment ?? ""
  }

  func setValue(_ text: String, for key: String, language: String) {
    guard catalog != nil else { return }
    let parsed = catalog?.rawValue(for: key, language: language) ?? ""
    if text == parsed {
      removeOverride(key: key, language: language)
      return
    }
    valueOverrides[key, default: [:]][language] = text
    // Only a real value is durable. Clearing a cell to empty is a display
    // affordance in this phase (shows "missing" until Reload) — it never
    // deletes the file's translation, so it has nothing to write through.
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      writeThrough(text: text, key: key, language: language)
    }
  }

  /// Durable half of a cell commit: upsert the record (human edit ->
  /// .manual/.reviewed + user-confirmed edit row) and write value + state
  /// back into the .xcstrings stringUnit. The override stays as the
  /// in-memory display value; a failure surfaces as saveError instead of
  /// silently dropping the edit.
  private func writeThrough(text: String, key: String, language: String) {
    guard let catalog, let project else {
      saveError = "No catalog open"
      return
    }
    let context = TranslationStore.shared.context
    do {
      let sourceText = catalog.sourceDisplay(for: key)
      Reconcile.applyHumanEdit(
        key: key, language: language, value: text,
        sourceText: sourceText, project: project, context: context)
      let updated = try Reconcile.commit(catalog, project: project)
      self.catalog = updated
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func removeOverride(key: String, language: String) {
    guard valueOverrides[key] != nil else { return }
    valueOverrides[key]?.removeValue(forKey: language)
    if valueOverrides[key]?.isEmpty == true {
      valueOverrides.removeValue(forKey: key)
    }
  }

  // MARK: language columns

  func isLanguageSelected(_ language: String) -> Bool {
    selectedLanguages.contains(language)
  }

  func toggleLanguage(_ language: String) {
    if let index = selectedLanguages.firstIndex(of: language) {
      selectedLanguages.remove(at: index)
    } else {
      selectedLanguages.append(language)
    }
  }

  /// Show/hide the Longest column; hiding also drops it from the sort so a
  /// hidden column never drives the row order.
  func setShowLongest(_ show: Bool) {
    showLongest = show
    if !show {
      sortOrder.removeAll { $0.column == .longest }
      if sortOrder.isEmpty {
        sortOrder = [CatalogSort(.source)]
      }
    }
  }

  /// Show/hide inline comments; hiding also drops the comment sort so a
  /// hidden field never drives the row order.
  func setShowComments(_ show: Bool) {
    showComments = show
    if !show {
      sortOrder.removeAll { $0.column == .comment }
      if sortOrder.isEmpty {
        sortOrder = [CatalogSort(.source)]
      }
    }
  }

  /// Dismiss the load-error alert (and any save error).
  func dismissError() {
    loadError = nil
    saveError = nil
  }

  /// True when either the catalog failed to load or a save failed.
  var hasError: Bool { loadError != nil || saveError != nil }

  /// Alert title for the current error.
  var errorTitle: String {
    saveError != nil ? "Couldn't save catalog" : "Couldn't open catalog"
  }

  /// Alert message for the current error (save error wins).
  var errorMessage: String? {
    saveError ?? loadError
  }

  // MARK: - loading

  /// <root>/Dev/Localization/<this file> — drop 3 path components to reach
  /// the repo root, then the gitignored fixture sits next to it.
  static var defaultFixtureURL: URL {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return root.appendingPathComponent("Localizable.xcstrings")
  }

  /// Auto-open the repo-root fixture on first appearance, if it exists.
  func openDefaultIfPresent() {
    guard catalog == nil else { return }
    let url = Self.defaultFixtureURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    open(url)
  }

  func openPanelAndLoad() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose an .xcstrings catalog"
    if let type = UTType(filenameExtension: "xcstrings") {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }

  /// Full (re)load: parse + reset everything. Used by Open….
  /// No language is selected by default; the user picks via the buttons.
  func open(_ url: URL) {
    do {
      let catalog = try StringCatalog.load(url: url)
      apply(catalog, url: url)
      loadError = nil
      // Fresh file: reset view state to defaults.
      searchText = ""
      filter = .all
      includeNonTranslatable = false
      showComments = false
      showLongest = false
      sortOrder = [CatalogSort(.source)]
      selectedLanguages = []
      // A different catalog: drop the previous project's run summary.
      run.reset()
    } catch {
      catalog = nil
      catalogURL = nil
      recordIndex = [:]
      loadError = error.localizedDescription
    }
  }

  /// Re-read the current file and drop overrides; view state is untouched.
  func reload() {
    guard let catalogURL else { return }
    do {
      let catalog = try StringCatalog.load(url: catalogURL)
      apply(catalog, url: catalogURL)
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  private func apply(_ catalog: StringCatalog, url: URL) {
    self.catalog = catalog
    catalogURL = url
    valueOverrides = [:]
    revision += 1
    reconcile(catalog, url: url)
  }

  /// Upsert the parsed catalog into SwiftData: find-or-create the project
  /// for this file and mirror every (key, language) slot into
  /// TranslationRecords. DB-owned provenance survives the reload; only
  /// unowned empty slots adopt what the file now says. Browsing never
  /// depends on the DB — if reconcile fails the file stays open and the
  /// next edit surfaces saveError.
  private func reconcile(_ catalog: StringCatalog, url: URL) {
    let context = TranslationStore.shared.context
    let project = Reconcile.ensureProject(catalogURL: url, in: context)
    let stats = Reconcile.upsertFromCatalog(catalog, project: project, context: context)
    self.project = project
    rebuildRecordIndex()
    NSLog(
      "[Localization] reconciled %@: %d created, %d refreshed, %d kept",
      url.lastPathComponent, stats.created, stats.refreshed, stats.kept)
  }

  /// Re-indexes the project's live records by (key, language) for O(1)
  /// per-cell lookups. Runs after every upsert, so newly seeded slots
  /// (open/reload) are visible to the table immediately.
  private func rebuildRecordIndex() {
    guard let project else {
      recordIndex = [:]
      return
    }
    var index: [String: [String: TranslationRecord]] = [:]
    for record in project.records {
      index[record.key, default: [:]][record.language] = record
    }
    recordIndex = index
  }

  // MARK: - rows

  /// Rows after include-toggle, filter, search and sort — rebuilt from store
  /// state, so edits survive any sort/filter toggling.
  var visibleRows: [CatalogRow] {
    guard let catalog else { return [] }
    let query = folded(searchText)
    let searching = !query.isEmpty
    var rows: [CatalogRow] = []
    rows.reserveCapacity(catalog.strings.count)
    for (key, entry) in catalog.strings {
      if !includeNonTranslatable && entry.shouldTranslate == false { continue }
      let row = makeRow(catalog: catalog, key: key, entry: entry, query: query, searching: searching)
      if matchesFilter(row) && (!searching || row.searchBlob.contains(query)) {
        rows.append(row)
      }
    }
    let sort = sortOrder.isEmpty ? [CatalogSort(.source)] : sortOrder
    return rows.sorted(using: sort)
  }

  private func makeRow(
    catalog: StringCatalog,
    key: String,
    entry: StringCatalog.Entry,
    query: String,
    searching: Bool
  ) -> CatalogRow {
    let translatable = entry.shouldTranslate != false
    var cells: [String: LangCell] = [:]
    for language in selectedLanguages {
      let loc = entry.localizations?[language]
      let variations = loc?.variations?.isEmpty == false
      cells[language] = LangCell(
        text: valueOverrides[key]?[language] ?? loc?.stringUnit?.value ?? "",
        state: loc?.stringUnit?.state,
        hasParsed: loc?.stringUnit != nil,
        hasOverride: valueOverrides[key]?[language] != nil,
        hasVariations: variations,
        isEditable: translatable && !variations,
        record: recordIndex[key]?[language])
    }
    let sourceText = catalog.sourceDisplay(for: key)
    let (longestText, longestLanguage) = Self.longestValue(
      catalog: catalog, key: key, sourceText: sourceText,
      overrides: valueOverrides[key])
    return CatalogRow(
      key: key,
      isTranslatable: translatable,
      sourceText: sourceText,
      longestText: longestText,
      longestLanguage: longestLanguage,
      longestLength: longestText.count,
      commentText: entry.comment ?? "",
      cells: cells,
      searchBlob: searching ? folded(searchBlobText(key: key, entry: entry)) : "")
  }

  /// Longest value across the source display text and every language
  /// (parsed + overrides), with variations contributing their parsed values.
  /// Returns (text, languageCode) — the source code appears as-is.
  private static func longestValue(
    catalog: StringCatalog,
    key: String,
    sourceText: String,
    overrides: [String: String]?
  ) -> (String, String) {
    var best = (text: sourceText, language: catalog.sourceLanguage)
    guard let localizations = catalog.strings[key]?.localizations else {
      return best
    }
    for (language, loc) in localizations {
      let candidates: [String]
      if let override = overrides?[language] {
        candidates = [override]
      } else if let value = loc.stringUnit?.value {
        candidates = [value]
      } else if let variations = loc.variations {
        candidates = variations.values.compactMap { $0.values.compactMap(\.stringUnit?.value) }.flatMap { $0 }
      } else {
        candidates = []
      }
      for text in candidates where text.count > best.text.count {
        best = (text, language)
      }
    }
    // Overrides for languages with no parsed entry at all.
    if let overrides {
      for (language, text) in overrides where localizations[language] == nil
        && text.count > best.text.count {
        best = (text, language)
      }
    }
    return best
  }

  private func searchBlobText(key: String, entry: StringCatalog.Entry) -> String {
    var parts = [key, entry.comment ?? ""]
    if let localizations = entry.localizations {
      for language in localizations.values {
        if let value = language.stringUnit?.value {
          parts.append(value)
        }
      }
    }
    return parts.joined(separator: "\n")
  }

  /// Filter across the visible non-source language columns only: a key
  /// matches when the chosen state occurs in at least one of them.
  private func matchesFilter(_ row: CatalogRow) -> Bool {
    switch filter {
    case .all:
      return true
    case .needsReview:
      return row.cells.values.contains { $0.state == "needs_review" }
    case .missing:
      return row.cells.values.contains { $0.isMissing }
    case .translated:
      return row.cells.values.contains { $0.state == "translated" }
    case .new:
      return row.cells.values.contains { $0.state == "new" }
    }
  }

  /// Missing count for one language over the base key set (respects the
  /// non-translatable toggle, ignores search/filter).
  func missingCount(for language: String) -> Int {
    guard let catalog else { return 0 }
    var count = 0
    for (key, entry) in catalog.strings {
      if !includeNonTranslatable && entry.shouldTranslate == false { continue }
      let hasOverride = valueOverrides[key]?[language] != nil
      if !catalog.hasValue(for: key, language: language) && !hasOverride {
        count += 1
      }
    }
    return count
  }
}

// MARK: - Folding helper

/// Case- and diacritic-insensitive folding used by search.
func folded(_ string: String) -> String {
  string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

// MARK: - Conditional modifier helper

extension View {
  @ViewBuilder
  func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

// MARK: - View

struct LocalizationView: View {
  @State private var store = LocalizationStore()

  var body: some View {
    Group {
      if store.isLoaded {
        loadedContent
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { store.openDefaultIfPresent() }
    .alert(store.errorTitle, isPresented: errorBinding) {
      Button("OK") { store.dismissError() }
    } message: {
      Text(store.errorMessage ?? "")
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.hasError },
      set: { if !$0 { store.dismissError() } })
  }

  private var loadedContent: some View {
    VStack(spacing: 0) {
      CatalogTable(store: store)
        .searchable(text: $store.searchText,
                    prompt: "Search keys, comments, translations")
        .safeAreaBar(edge: .top) {
        VStack {
          ControlsBar(store: store)
          Divider()
          LanguageButtonsRow(store: store)
        }
      }.safeAreaBar(edge: .bottom) {
        FooterBar(store: store)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "globe")
        .font(.system(size: 44))
        .foregroundStyle(.tertiary)
      Text("No string catalog open")
        .font(.title3)
      Text("Open a .xcstrings file to browse its keys and translations.")
        .foregroundStyle(.secondary)
      Button("Open Catalog…") { store.openPanelAndLoad() }
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Controls

private struct ControlsBar: View {
  let store: LocalizationStore

  var body: some View {
    @Bindable var store = store
    HStack(spacing: 12) {
      Button("Open…") { store.openPanelAndLoad() }
        .disabled(store.run.isRunning)
      Button {
        store.reload()
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(!store.isLoaded || store.run.isRunning)

      Picker(selection: $store.filter, label: EmptyView()) {
        ForEach(RowFilter.allCases) { rowFilter in
          Label(rowFilter.title, systemImage: rowFilter.icon).tag(rowFilter)
        }
      }.pickerStyle(.segmented).fixedSize()

      Spacer()

      Toggle(isOn: $store.includeNonTranslatable) {
        Image(systemName: "eye")
      }.help("Include the \(store.nonTranslatableCount) keys marked shouldTranslate = false (hidden by default)")

      Toggle(isOn: Binding(
        get: { store.showComments },
        set: { store.setShowComments($0) })) {
          Image(systemName: "text.bubble")
        }
        .help("Show comment text under each source value")

      Toggle(isOn: Binding(
        get: { store.showLongest },
        set: { store.setShowLongest($0) })) {
          Image(systemName: "ruler")
        }
        .help("Show the Longest column (longest value across all languages)")

      Button {
        store.startTranslate()
      } label: {
        Label("Translate", systemImage: "translate")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!store.canTranslate)
      .help(store.run.isRunning
        ? "A translation run is in progress — cancel it from the footer"
        : "Run the translation pipeline: learn from confirmed edits, resolve translation memory, then Apple, Ollama and review")
    }.toggleStyle(ToggleButtonStyle())
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
  struct ToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
      Button {
        withAnimation {
          configuration.isOn.toggle()
        }
      } label: {
        configuration.label
          .foregroundStyle(configuration.isOn ? .blue : .secondary)
          .symbolVariant(configuration.isOn ? .fill : .none.slash)
          .contentTransition(.symbolEffect)
      }.buttonStyle(.plain)
    }
  }
}

// MARK: - Language buttons

/// Horizontal strip of language buttons on the second row; selected ones are
/// highlighted. Tapping toggles the language column.
private struct LanguageButtonsRow: View {
  let store: LocalizationStore

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(store.pickerLanguages, id: \.self) { language in
          let selected = store.isLanguageSelected(language)
          Button {
            store.toggleLanguage(language)
          } label: {
            Text(language)
              .font(.callout)
              .foregroundStyle(selected ? .white : .primary)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
          }
          .buttonStyle(.plain)
          .help(selected ? "Hide \(language) column" : "Show \(language) column")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Table

private struct CatalogTable: View {
  let store: LocalizationStore

  var body: some View {
    @Bindable var store = store
    Table(store.visibleRows, sortOrder: $store.sortOrder) {
      TableColumn(store.sourceLanguageTitle, sortUsing: CatalogSort(.source)) { row in
        sourceCell(row)
      }
      .width(min: 160, ideal: 300, max: 300)

      if store.showLongest {
        TableColumn("Longest", sortUsing: CatalogSort(.longest)) { row in
          longestCell(row)
        }
        .width(min: 140, ideal: 300, max: 300)
      }

      TableColumnForEach(store.selectedLanguages, id: \.self) { language in
        TableColumn(language, sortUsing: CatalogSort(.language(language))) { row in
          languageCell(row, language: language)
        }
        .width(min: 120, ideal: 240, max: 300)
      }
    }
  }

  // MARK: cells

  private func longestCell(_ row: CatalogRow) -> some View {
    HStack(spacing: 5) {
      if !row.isTranslatable {
        Image(systemName: "nosign")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .help("Not translatable")
      }
      Text(row.longestText)
        .lineLimit(3)
        .help(longestTooltip(row))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func longestTooltip(_ row: CatalogRow) -> String {
    if row.longestLanguage.isEmpty {
      return row.longestText
    }
    return "\(row.longestLanguage) · \(row.longestLength) chars\n\(row.longestText)"
  }

  private func sourceCell(_ row: CatalogRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.sourceText)
        .lineLimit(3)
        .help(row.sourceText)
      if store.showComments, !row.commentText.isEmpty {
        Text(row.commentText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .help(row.commentText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func languageCell(_ row: CatalogRow, language: String) -> some View {
    let cell = row.cells[language] ?? LangCell(
      text: "", state: nil, hasParsed: false, hasOverride: false,
      hasVariations: false, isEditable: row.isTranslatable, record: nil)
    return HStack(spacing: 5) {
      if cell.hasVariations {
        Text(cell.text)
          .lineLimit(3)
        Image(systemName: "ellipsis.curlybraces")
          .foregroundStyle(.tertiary)
          .help("Variations present — read-only in this phase")
      } else {
        CellStatusAccessory(
          record: cell.record,
          isInFlight: store.run.isInFlight(cell.record))
        if let record = cell.record,
           record.lastEditor == ProvenanceMarkers.translationMemory {
          TranslationMemoryBadge(record: record)
        }
        LanguageEditCell(
          store: store, rowKey: row.key, language: language,
          cell: cell, record: cell.record)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var editedTint: Color {
    Color.accentColor.opacity(0.08)
  }

  // MARK: bindings (store-backed, survive sort/filter)

  private func valueBinding(for key: String, language: String) -> Binding<String> {
    Binding(
      get: { store.value(for: key, language: language) },
      set: { store.setValue($0, for: key, language: language) })
  }
}

/// Editable language cell: read-only Text until clicked, then a focused
/// TextEditor for multiline editing. Keystrokes mutate @State draft only, so
/// the field is never rebuilt while typing; the store override commits on
/// focus loss (Escape cancels). `revision` resyncs the draft on reload.
private struct LanguageEditCell: View {
  let store: LocalizationStore
  let rowKey: String
  let language: String
  let cell: LangCell
  /// Live record of the slot (nil for variation/non-translatable cells);
  /// its value feeds the read-only display and its provenance the tooltip.
  let record: TranslationRecord?

  @State private var draft: String = ""
  @State private var isEditing = false
  @State private var initializedRevision = -1
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextEditor(text: $draft)
          .font(.body)
          .focused($focused)
          .scrollContentBackground(.hidden)
          .background(hasOverride ? editedTint : Color.clear)
          .onAppear { focused = true }
          .onExitCommand { cancel() }
          .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
          }
      } else {
        Group {
          if liveText.isEmpty {
            Text("missing")
              .foregroundStyle(.tertiary)
          } else {
            Text(liveText)
              .lineLimit(3)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
        .background(hasOverride ? editedTint : Color.clear)
        .onTapGesture {
          guard cell.isEditable else { return }
          draft = store.value(for: rowKey, language: language)
          isEditing = true
        }
      }
    }
    .onAppear {
      draft = store.value(for: rowKey, language: language)
      initializedRevision = store.revision
    }
    .onChange(of: store.revision) { _, revision in
      if revision != initializedRevision {
        draft = store.value(for: rowKey, language: language)
        initializedRevision = revision
        isEditing = false
      }
    }
    .onChange(of: cell.text) { _, newText in
      // Adopt external changes (sort/reload/commit) unless mid-edit.
      if !isEditing && !focused {
        draft = newText
      }
    }
  }

  /// Override-aware, record-aware display value. Reads the live SwiftData
  /// record so mid-run machine fills appear the moment the pipeline writes
  /// them — before the end-of-run commit reaches the .xcstrings file.
  private var liveText: String {
    store.value(for: rowKey, language: language)
  }

  /// Cell tooltip: full provenance when the record carries a value
  /// (producer + context versions + state), else the plain prompt.
  private var helpText: String {
    if let record, let provenance = record.provenanceSummary {
      return provenance
    }
    return liveText.isEmpty ? "Missing — click to add" : liveText
  }

  private var hasOverride: Bool {
    store.valueOverrides[rowKey]?[language] != nil
  }

  private func commit() {
    store.setValue(draft, for: rowKey, language: language)
    // Adopt the canonical value (commit may drop the override when the
    // draft equals the parsed text).
    draft = store.value(for: rowKey, language: language)
    isEditing = false
  }

  private func cancel() {
    draft = store.value(for: rowKey, language: language)
    isEditing = false
  }

  private var editedTint: Color {
    Color.accentColor.opacity(0.08)
  }
}

// MARK: - Footer

private struct FooterBar: View {
  let store: LocalizationStore

  var body: some View {
    HStack(spacing: 6) {
      Text("\(store.totalKeyCount) keys, showing \(store.visibleRows.count)")
        .foregroundStyle(.secondary)
      if !store.selectedLanguages.isEmpty {
        Text("·").foregroundStyle(.tertiary)
        ForEach(store.selectedLanguages, id: \.self) { language in
          Text("\(language): \(store.missingCount(for: language)) missing")
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      TranslateRunStatus(controller: store.run)
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
  }
}

#Preview {
  LocalizationView()
    .frame(width: 1100, height: 600)
}
