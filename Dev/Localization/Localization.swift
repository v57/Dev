//
//  Localization.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row filter

enum RowFilter: String, CaseIterable, Identifiable {
  case all
  case needsReview
  case missing
  case translated
  case new
  /// Rows that carry a max-width guideline with at least one filled value
  /// over it — the reviewer's shortening worklist.
  case tooWide

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .needsReview: return "Needs review"
    case .missing: return "Missing"
    case .translated: return "Translated"
    case .new: return "New"
    case .tooWide: return "Too wide"
    }
  }

  var icon: String {
    switch self {
    case .all: return "tray.full"
    case .needsReview: return "exclamationmark.magnifyingglass"
    case .missing: return "questionmark.circle"
    case .translated: return "checkmark.circle"
    case .new: return "sparkles"
    case .tooWide: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
    }
  }
}

// MARK: - Row model

/// One table row = one catalog key, with override-aware display values.
struct CatalogRow: Identifiable {
  let key: String
  /// shouldTranslate == false keys get a glyph and no editable cells.
  let isTranslatable: Bool
  /// True when any language slot of this key carries a plural variation.
  let hasPlurals: Bool
  /// Source-language display text (explicit source value, else the key text).
  let sourceText: String
  /// Source plural summary ("one: … / other: …"), empty for flat keys.
  let sourcePluralSummary: String
  /// Longest value across all languages (override-aware, source included).
  let longestText: String
  let longestLanguage: String
  let longestLength: Int
  let commentText: String
  /// Display state of every non-source language — always fully filled at
  /// row materialization, not just the visible columns, so language column
  /// toggles only re-project `visibleRows`. Views and filters pick the
  /// languages they care about from this map.
  let cells: [String: LangCell]
  /// True when at least one slot is filled and every filled slot (all
  /// languages, flat + plural forms) is reviewed.
  let isFullyReviewed: Bool
  /// True when at least one slot is filled and every filled slot is
  /// needs_review. Mixed and empty rows report false for both.
  let isFullyNeedsReview: Bool
  /// Folded haystack for search, built once at row materialization.
  let searchBlob: String
  /// The row's max-width guideline (nil = none), read from its live records.
  let maxWidth: Int?

  var id: String { key }
}

/// Display state of one language cell (missing, edited, variation…).
struct LangCell {
  let text: String
  /// Parsed file state — display only, never flipped by edits. For plural
  /// cells the aggregate across forms (needs_review wins, then new).
  let state: String?
  let hasParsed: Bool
  let hasOverride: Bool
  let hasVariations: Bool
  /// This slot carries a plural variation: `text` is the form summary,
  /// `pluralRecords` holds the per-form live records, and the cell opens
  /// the plural editor instead of the flat TextEditor.
  let hasPlurals: Bool
  let isEditable: Bool
  /// Live SwiftData record of the (key, language) slot — the cell's dot,
  /// provenance tooltip and mid-run text read it directly. Nil for
  /// plural holders (see pluralRecords), device holders and
  /// non-translatable keys, which reconcile does not model flat.
  let record: TranslationRecord?
  /// Live per-form records (category -> record) for plural slots; empty for
  /// flat cells. Each form is a full translation slot with its own value,
  /// state and provenance.
  let pluralRecords: [String: TranslationRecord]

  /// No value at all: no parsed unit, no override, and no variations to show.
  /// Plural slots are missing only when no form carries anything.
  var isMissing: Bool {
    if hasPlurals {
      if hasParsed || hasOverride { return false }
      return pluralRecords.values.allSatisfy { $0.value?.isBlankOrEmpty != false }
    }
    return !hasParsed && !hasOverride && !hasVariations
  }

  /// Length of the longest FILLED value in this slot, in grapheme clusters
  /// (0 when the slot holds nothing) — the same counting rule the batch budget
  /// and the guideline use, so the submenu and the warning cannot disagree.
  /// Plural slots weigh their FORMS; the cell's summary text is not a value.
  var longestValueCharacters: Int {
    var longest = 0
    func weigh(_ value: String?) {
      guard let value, !value.isBlankOrEmpty else { return }
      longest = max(longest, value.count)
    }
    weigh(record?.value)
    if pluralRecords.isEmpty {
      weigh(hasPlurals ? nil : text)
    } else {
      for form in pluralRecords.values { weigh(form.value) }
    }
    return longest
  }

  /// True when this slot holds a value longer than the row's guideline.
  func isOverWidth(_ limit: Int) -> Bool {
    let longest = longestValueCharacters
    return longest > 0 && longest > limit
  }
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

/// What a leave-the-catalog request is standing in front of while the
/// unsaved-changes prompt is up.
enum LeaveIntent: Equatable {
  /// Toolbar Reload.
  case reload
  /// Opening a known file (sidebar project switch, Open… choice).
  case open(URL)
  /// Toolbar Open… — the file panel has not run yet.
  case openPanel
}

/// The user's answer to the unsaved-changes prompt.
enum LeaveChoice {
  case save
  case discard
  case cancel
}

/// Which half of a load a finished parse belongs to (`LocalizationStore.land`).
/// An OPEN resets the pane's view state (search, filter, columns, sort), a RELOAD
/// deliberately leaves it alone — that is the whole difference between them, and
/// the held parse has to remember which one it was while the user answers.
private enum LoadPurpose {
  case open
  case reload
}

/// The user's answer to the versions prompt: the file and the app's records carry
/// different values for the slots the load asked about.
enum DifferenceChoice {
  /// Load the FILE's values for the differing slots.
  case file
  /// Keep the app's records; the file's values for those slots are left out (and
  /// the next Save writes the app's values back over them).
  case app
  /// Open nothing — the request is dropped and the pane stays as it was.
  case cancel
}

/// Owns the parsed catalog, load state, view state and the in-memory edit
/// overrides. Since Phase C the catalog is reconciled into SwiftData
/// (Reconcile): every (re)load upserts TranslationRecords from the file —
/// DB-owned provenance (provider, context-versions, state) survives the
/// reload — and every committed cell edit is written through to the DB
/// record.
///
/// The FILE is the artifact and `save()` is its ONLY writer: no edit, no
/// Translate run and no plural skeleton writes the .xcstrings on its own, so
/// the UI keeps a dirty flag and asks before leaving a catalog with unsaved
/// edits. The DB is the working/provenance store and stays immediate.
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

  // MARK: unsaved changes

  /// True when the in-memory catalog carries edits the file does not have
  /// yet. Save is the ONLY writer of the .xcstrings artifact: no cell edit,
  /// no Translate run and no plural skeleton writes on its own, so an edit is
  /// durable in the DB (records) and pending on disk until the user saves.
  private(set) var isDirty = false

  /// The leave-the-catalog request waiting on the unsaved-changes prompt.
  /// Reload…/Open… hold the open catalog in place until it is answered.
  private(set) var pendingLeave: LeaveIntent?

  /// True while the alert is on screen. Kept SEPARATE from `pendingLeave` so
  /// the dismissal SwiftUI reports when a button is tapped cannot drop the
  /// request before that button's action runs.
  private(set) var isUnsavedPromptPresented = false

  // MARK: file-vs-records prompt

  /// The parsed catalog held on the versions prompt, or nil.
  ///
  /// The load does not pick a side when the file and the app's records carry different
  /// values for the same slot: the mirror pass writes NOTHING (see
  /// `Reconcile.mirrorOffMainActor`), the parse waits here, and the answer decides which
  /// version the re-run mirrors. Nil while no question is up.
  private var heldLoad: HeldLoad?

  /// The differing slots the versions prompt is asking about, in the order the mirror
  /// found them — a SAMPLE, not the whole set (the count below is exact). The prompt
  /// names a few of them.
  private(set) var pendingDifferences: [Reconcile.SlotDifference] = []

  /// How many slots the file and the app's records disagree about. The exact count, for
  /// the prompt's text.
  private(set) var pendingDifferenceCount = 0

  /// True while the versions alert is on screen. Separate from the pending state for the
  /// same reason as `isUnsavedPromptPresented`: the dismissal SwiftUI reports must not
  /// drop the question before its button's action runs.
  private(set) var isVersionsPromptPresented = false

  /// A parse held on the versions prompt: the document, the file it came from, which half
  /// of a load it is, and the generation it belongs to — so a newer open/reload, a close
  /// or a store clear (each bumps `loadGeneration`) supersedes it instead of having the
  /// answer land over whatever came next.
  private struct HeldLoad {
    let catalog: StringCatalog
    let url: URL
    let purpose: LoadPurpose
    let generation: Int
    /// The shape conflicts the load found, to hand to the mirror once the question is answered
    /// (they are not part of the question: the reviewed value's shape wins either way).
    let shapeConflicts: [Reconcile.ShapeConflict]
    /// True when the load already converted the FILE's side of them, which makes the parsed
    /// document differ from the file on disk — i.e. the pane has something to Save.
    let reshaped: Bool
  }

  /// The store app-level code (the quit prompt) asks; STRONG, so a closed
  /// window's unsaved edits still reach their prompt instead of vanishing
  /// with the scene. Latest store created wins (one window in practice).
  private static var retained: LocalizationStore?

  /// The store a window-independent prompt (quit) should ask, or nil.
  static var active: LocalizationStore? { retained }

  init() {
    Self.retained = self
  }

  // MARK: in-memory edits

  private(set) var valueOverrides: [String: [String: String]] = [:]  // key -> language -> text
  /// Bumped on every (re)load so editing cells can resync their drafts.
  private(set) var revision = 0

  // MARK: view state

  // Filter/search/sort inputs are computed so every change re-projects
  // `rows` into `visibleRows`; the backing stores keep @Observable tracking.
  private var _searchText = ""
  var searchText: String {
    get { _searchText }
    set { _searchText = newValue; recomputeVisibleRows() }
  }

  private var _filter: RowFilter = .all
  var filter: RowFilter {
    get { _filter }
    set { _filter = newValue; recomputeVisibleRows() }
  }

  private var _includeNonTranslatable = false
  var includeNonTranslatable: Bool {
    get { _includeNonTranslatable }
    set { _includeNonTranslatable = newValue; recomputeVisibleRows() }
  }

  /// Comments hidden unless the user opts in (off by default).
  var showComments = false
  /// Longest column hidden unless the user opts in (off by default).
  var showLongest = false
  /// Non-source languages with a visible column (source column is permanent).
  private(set) var selectedLanguages: [String] = []
  private var _sortOrder: [CatalogSort] = [CatalogSort(.source)]
  var sortOrder: [CatalogSort] {
    get { _sortOrder }
    set { _sortOrder = newValue; recomputeVisibleRows() }
  }

  /// Default language columns on open: none selected (user picks via buttons).
  /// Kept for reference; `open` resets to an empty selection.
  static let defaultColumns: [String] = []

  var isLoaded: Bool { catalog != nil }

  /// Language codes the "Add Language" menu offers — every language Apple's own
  /// platforms carry as a keyboard OR a UI language, alphabetical. The menu
  /// marks the ones the open catalog already carries.
  ///
  /// Verified locally against the installed iOS 27 runtime: the
  /// `System/Library/TextInput/TextInput_<code>.bundle` set (keyboard/device
  /// languages, 98 codes) union the `.lproj` sets of its first-party apps
  /// (UI languages, 66 codes), so nothing here is offered that the OS cannot
  /// render. Not separate entries: regional variants (pt-BR, en-GB, es-419,
  /// de-CH, fr-CA…), Apple's generic `no` (Norwegian is offered as nb + nn)
  /// and `tl` (Filipino carries Tagalog). A catalog may of course still carry
  /// any code it likes — that is the catalog's business, not this menu's.
  static let offeredLanguages: [String] = [
    "ar", "ars", "as", "az", "be", "bg",
    "bn", "bo", "brx", "ca", "chr", "ckb",
    "cs", "cy", "da", "de", "doi", "dv",
    "el", "en", "es", "et", "fa", "fi",
    "fil", "fo", "fr", "ga", "gu", "haw",
    "he", "hi", "hr", "hu", "hy", "id",
    "is", "it", "ja", "ka", "kk", "km",
    "kn", "ko", "kok", "ks", "ku", "ky",
    "lo", "lt", "lv", "mai", "mi", "mk",
    "ml", "mn", "mni", "mr", "ms", "mt",
    "my", "nb", "ne", "nl", "nn", "or",
    "pa", "pl", "ps", "pt_PT", "ro", "ru",
    "sa", "sat", "sd", "si", "sk", "sl",
    "sq", "sr", "sv", "sw", "ta", "te",
    "tg", "th", "tk", "to", "tr", "ug",
    "uk", "ur", "vi", "yue", "zh-Hans",
  ]

  /// Languages added during THIS window, before any of their records exist.
  /// Kept only so an add is visible immediately on a catalog with no keys (a
  /// freshly generated one, where there is nothing to seed and nothing to
  /// persist). Once the catalog has keys, the seeded records carry the
  /// language — see `browserLanguages`.
  private(set) var addedLanguages: [String] = []

  /// Every language the browser projects a cell/column for: the open
  /// catalog's own codes, the ones added in this window, and the ones this
  /// project's records carry.
  ///
  /// The records are what make an ADDED language survive a reopen: the
  /// catalog's nodes for it are empty, and an empty localization node is a
  /// file error, so the save path prunes them (see `normalizeForWrite`) — the
  /// file only ever gains the language where a translation exists to write.
  private(set) var browserLanguages: [String] = []

  /// True while an add-language pass is seeding its records.
  private(set) var isAddingLanguage = false

  /// Language columns the strip offers: every language of the browser except
  /// the source (whose column is permanent).
  var pickerLanguages: [String] { browserLanguages }

  /// True when the open catalog — or this project's records — already carries
  /// `language`. The source language counts as present: it is not a target.
  func isLanguagePresent(_ language: String) -> Bool {
    browserLanguages.contains(language) || catalog?.sourceLanguage == language
  }

  /// The Add Languages overlay is open. Drives the sheet in the localization
  /// pane; the strip's button only raises it.
  var languagePickerOpen = false

  func openLanguagePicker() { languagePickerOpen = true }
  func closeLanguagePicker() { languagePickerOpen = false }

  /// Adds every selected language in ONE pass: the document half here (on the
  /// CURRENT document, never on a snapshot the seeding pass was given — an
  /// edit, a Translate run or a reload can land while the pass runs), then the
  /// records the Translate pipeline fills, off the main actor
  /// (`Reconcile.addLanguages`).
  ///
  /// Nothing is written to the artifact: adding a language is a DB-side
  /// operation until a translation exists for it, and Save stays the only
  /// writer. One added language selects its column (the missing cells are the
  /// point); a batch leaves the selection alone — opening forty columns at once
  /// is not a view anyone asked for.
  func addLanguages(_ languages: [String]) {
    guard let catalog, let project else { return }
    let codes = languages.filter { !isLanguagePresent($0) }
    guard !codes.isEmpty else { return }
    // The languages' nodes (empty — pruned on the way to disk, so the file
    // only gains a language where a translation exists to write) plus the CLDR
    // form skeleton for every key whose SOURCE is plural-varied, which is what
    // makes those keys read as plural targets instead of flat slots.
    var updated = catalog
    for code in codes {
      updated.addLanguage(code)
    }
    for key in Array(updated.strings.keys)
    where updated.hasPlurals(for: key, language: updated.sourceLanguage) {
      updated.varyByPlural(key: key, languages: codes)
    }
    self.catalog = updated
    addedLanguages.append(contentsOf: codes)
    if codes.count == 1, !selectedLanguages.contains(codes[0]) {
      selectedLanguages.append(codes[0])
    }
    buildRows()
    let projectID = project.persistentModelID
    isAddingLanguage = true
    // The seeding is bulk store work (one insert per slot per language), so it goes through
    // the app's ONE queue: it must not race a whole-catalog mirror for the same slots, and
    // the load path may well have one in flight behind the pane.
    Task {
      let result = await StoreWork.shared.enqueue {
        await Reconcile.addLanguages(
          codes, catalog: catalog, projectID: projectID,
          in: TranslationStore.container)
      }
      isAddingLanguage = false
      switch result {
      case .success(let outcome):
        note("Added \(codes.count) language(s): \(outcome.inserted) slot(s) ready to translate")
        // Another catalog may have been opened while the pass ran: its rows are
        // not this project's. The records it seeded are durable either way, and
        // the next open/adopt picks them up.
        guard self.project?.persistentModelID == projectID else { return }
        rebuildRecordIndex()
        buildRows()
      case .failure(let error):
        saveError = "Couldn't add \(codes.count) language(s): \(error.localizedDescription)"
      }
    }
  }

  /// A short line for the footer, so an add that changes nothing visible (a
  /// catalog with no keys yet) still reports what happened.
  private(set) var statusNote: String?
  private var noteTask: Task<Void, Never>?

  private func note(_ text: String) {
    statusNote = text
    noteTask?.cancel()
    noteTask = Task {
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      statusNote = nil
    }
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

  // MARK: - SwiftData working store (records)

  /// Live SwiftData records of the open project, indexed (key, language,
  /// form-or-flat). Rebuilt on every reconcile (open/reload); record objects
  /// are mutated in place by edits and pipeline runs, so the refs stay
  /// valid. The "" form key is the flat slot; named keys are plural forms.
  private var recordIndex: [String: [String: [String: TranslationRecord]]] = [:]

  /// Drives Scan Strings — live progress, cancel, the finished report and
  /// the merge it proposes. One instance per store, so the toolbar button
  /// and the report sheet share it.
  let scan = ScanController()

  /// True when the Scan Strings button may start a scan: a project-bound
  /// catalog is open, its project has a root to scan and no scan is in
  /// flight.
  var canScan: Bool {
    isLoaded && project != nil && scanRoot != nil && !scan.isRunning
  }

  /// The folder Scan Strings scans: the project's own root when the project
  /// was imported as a directory; otherwise the catalog's parent, climbing
  /// toward the repo root while no folder looks like a repo (a catalog can
  /// live deep inside the tree, e.g. Resources/Localization).
  var scanRoot: URL? {
    let start = project?.rootURL ?? catalogURL?.deletingLastPathComponent()
    guard let start else { return nil }
    if ScanEngine.looksLikeRepoRoot(start) { return start }
    var candidate: URL? = start
    for _ in 0..<4 {
      guard let current = candidate, current.pathComponents.count > 1 else { break }
      if ScanEngine.looksLikeRepoRoot(current) { return current }
      candidate = current.deletingLastPathComponent()
    }
    return start
  }

  /// Toolbar "Scan Strings": scans the project's Swift packages AND its
  /// Xcode targets, then previews the merge into this catalog.
  func startScan() {
    scan.begin(store: self, root: scanRoot)
  }

  /// Report sheet "Merge": applies the preview to the catalog (additive
  /// only), writes the file and re-reconciles so the new keys become rows.
  func applyScan() {
    scan.apply()
  }

  /// Adopts a scan merge as a durable catalog change: the merged document
  /// replaces the open one, is written to the same file and reconciled — the
  /// scan adds keys only, so no existing translation can be touched.
  func adoptScanMerge(_ catalog: StringCatalog, url: URL) {
    self.catalog = catalog
    saveError = nil
    markDirty()
    mirrorOpenCatalog(catalog, url: url)
  }

  // MARK: - the redesign's publish step

  /// Publishes the redesign's session onto the OPEN in-memory catalog (5.8).
  ///
  /// The redesign's run never writes the `.xcstrings` itself: its results reach
  /// the file only through THIS catalog and a user Save — so the session's owner
  /// hands over an edit of the catalog struct, this store owns the instance the
  /// browser displays, and `markDirty` is what makes ⌘S, the Save button and the
  /// unsaved-changes prompt see the edit at all. Before this entry point existed
  /// a run's results were app-side only, and could be lost with no prompt.
  ///
  /// Refused — touching nothing — when a DIFFERENT catalog is open (a stale caller:
  /// the same rule `mirrorOpenCatalog` states) and when the edit changes nothing
  /// (a re-publish of what the catalog already carries must not raise the flag).
  /// Returns whether the open catalog really changed.
  ///
  /// The RECORDS are the redesign's own to write (a run's write-back, `saveData`),
  /// so nothing here re-mirrors the file. What this owes the browser is the derived
  /// half of a catalog change — the record index and the rows. `keys` names the rows
  /// the edit touched when the caller knows them (one row a human edited): only those
  /// are re-read and rebuilt, the way a row-scoped edit is (`saveRow`). Nil — a whole
  /// run's results — rebuilds everything.
  @discardableResult
  func publish(
    from url: URL, keys: Set<String>? = nil, _ edit: (inout StringCatalog) -> Bool
  ) -> Bool {
    guard let open = catalog, catalogURL == url else { return false }
    var updated = open
    guard edit(&updated) else { return false }
    catalog = updated
    saveError = nil
    if let keys {
      refreshKeys(keys)
    } else {
      rebuildRecordIndex()
      buildRows()
    }
    markDirty()
    return true
  }

  /// True when the Save button may write the artifact.
  var canSave: Bool { isDirty && isLoaded && project != nil }

  /// True when the open catalog carries edits the file does not have yet.
  var hasUnsavedChanges: Bool { isDirty && isLoaded }

  /// Row-menu "Vary by plural": builds the CLDR plural skeleton for the
  /// source language + every selected non-source column, seeds one record
  /// per form, then writes the artifact. The flat stringUnit value moves
  /// into "other" (file state preserved); missing forms stay empty for the
  /// pipeline to fill.
  func varyByPlural(key: String) {
    guard var catalog, let project else { return }
    let languages = ([catalog.sourceLanguage] + selectedLanguages).uniqued()
    catalog.varyByPlural(key: key, languages: languages)
    self.catalog = catalog
    saveError = nil
    markDirty()
    mirrorOpenCatalog(catalog, url: project.catalogURL, keys: [key])
  }

  /// Row-menu "Remove plural variations": collapses every plural slot of the
  /// key back to a flat stringUnit ("other" wins), drops the per-form
  /// records, then writes the artifact.
  func removePlurals(key: String) {
    guard var catalog, let project else { return }
    catalog.removePlurals(key: key)
    let context = TranslationStore.shared.context
    for record in Reconcile.records(ofKey: key, in: project) where record.category != nil {
      context.delete(record)
    }
    try? context.save()
    self.catalog = catalog
    saveError = nil
    markDirty()
    mirrorOpenCatalog(catalog, url: project.catalogURL, keys: [key])
  }

  /// Row-menu "Don't translate" / "Needs translate": flips the catalog's
  /// `shouldTranslate` flag for the key, writes the artifact, then syncs
  /// the DB. Opting OUT deletes the key's records (the pipeline never looks
  /// at them again — reconcile skips non-translatable keys); opting back IN
  /// re-seeds records from the file via the normal reconcile, so Translate
  /// picks the key up on the next run. Non-translatable rows stay visible
  /// with the nosign glyph (respecting the eye toggle); their AI/plural
  /// actions stay hidden since they hold no records.
  func setTranslatable(key: String, _ translatable: Bool) {
    guard var catalog, let project else { return }
    guard var entry = catalog.strings[key] else { return }
    entry.shouldTranslate = translatable ? nil : false
    catalog.strings[key] = entry
    if !translatable {
      let context = TranslationStore.shared.context
      for record in Reconcile.records(ofKey: key, in: project) {
        context.delete(record)
      }
      try? context.save()
    }
    self.catalog = catalog
    saveError = nil
    markDirty()
    mirrorOpenCatalog(catalog, url: project.catalogURL, keys: [key])
  }

  /// Marks a whole row (key) `reviewed` / `needs_review` across every filled
  /// language slot AND every filled plural form, then writes the state back
  /// to the artifact. Empty slots are left untouched.
  func setRowState(_ key: String, _ state: TranslationState) {
    guard let project else { return }
    let context = TranslationStore.shared.context
    Reconcile.applyReviewState(key: key, state: state, project: project, context: context)
    saveRow(key)
  }

  // MARK: - reviewer note

  /// The key whose note editor is open, or nil. Drives the note sheet.
  var noteKey: String?
  /// True while the project-context editor sheet is open.
  var contextDocsOpen = false

  func editNote(_ key: String) { noteKey = key }
  func closeNote() { noteKey = nil }
  func openContextDocs() { contextDocsOpen = true }
  func closeContextDocs() { contextDocsOpen = false }

  /// The row's note + scope, read from the live records (the note is set
  /// across every record of the key, so the first one that carries one is
  /// authoritative). Empty text + `.project` when the row has no note.
  func note(for key: String) -> (text: String, scope: Reconcile.NoteScope) {
    let all = recordIndex[key]?.values.flatMap { $0.values } ?? []
    guard let record = all.first(where: { $0.note?.isBlankOrEmpty == false }) else {
      return ("", .project)
    }
    return (record.note ?? "", Reconcile.NoteScope(rawValue: record.noteScope ?? "") ?? .project)
  }

  /// Saves the row's note. A `project`-scoped note is folded into the project's
  /// ContextDoc as a rule (audited, version bumped); a memo never leaves the
  /// DB. No catalog write: the note is app-local metadata.
  func setNote(key: String, note: String, scope: Reconcile.NoteScope) {
    guard let project else { return }
    let context = TranslationStore.shared.context
    Reconcile.applyNote(
      key: key, note: note, scope: scope, project: project, context: context)
    refreshKeys([key])
  }

  /// The project context body — the human-authored rule set the translator
  /// follows (prompt rule 4: context sections are authoritative).
  var projectContextText: String { project?.contextDoc?.content ?? "" }

  /// Saves the hand-edited project context (audit + one version bump; a no-op
  /// when unchanged).
  func setProjectContext(_ text: String) {
    guard let project else { return }
    let context = TranslationStore.shared.context
    Reconcile.applyProjectDoc(content: text, project: project, context: context)
  }

  /// The row's max-width guideline (nil = none), read from the live records.
  func maxWidth(for key: String) -> Int? {
    let all = recordIndex[key]?.values.flatMap { $0.values } ?? []
    return all.compactMap(\.maxWidth).first
  }

  /// Sets (nil clears) the row's max-width guideline across every record of
  /// the key. Nothing is written to the catalog file: the guideline is
  /// app-local metadata, and Save stays the only catalog writer.
  func setMaxWidth(key: String, width: Int?) {
    guard let project else { return }
    Reconcile.applyMaxWidth(
      key: key, width: width, project: project,
      context: TranslationStore.shared.context)
    refreshKeys([key])
  }

  // MARK: - imported-DB human confirm

  /// One-click human confirm of an auto-reviewed slot (the "auto" badge):
  /// the value is already .reviewed — this clears the auto marker so the
  /// record counts as human-reviewed (reviewedAt stamped, producer stamp
  /// kept) and upserts the TM gold entry, so any future catalog resolves
  /// the same (sourceText, language, target) as gold immediately — no need
  /// to wait for the next run's Stage 0. No-op unless the record really is
  /// auto-reviewed with a value.
  ///
  /// Clearing the marker is HALF the confirm: the file carries an imported
  /// value as `needs_review` (that is the state a value nobody vouched for
  /// writes), so the owning row must be merged before a Save promotes it to
  /// `translated`. The callers do that — `confirmAutoReviewedRow` for the row
  /// action, `confirmAutoReviewed(key:language:category:)` for a cell.
  @discardableResult
  func confirmAutoReviewed(_ record: TranslationRecord) -> Bool {
    guard let project, let catalog,
          record.autoReviewed,
          let value = record.value,
          !value.isBlankOrEmpty
    else { return false }
    let context = TranslationStore.shared.context
    record.autoReviewed = false
    record.reviewedAt = .now
    record.updatedAt = .now
    // Gold is gold: the human vouched for this (sourceText, target) triple.
    Reconcile.upsertGoldMemory(
      in: context,
      sourceText: record.sourceText,
      sourceLanguage: catalog.sourceLanguage,
      targetLanguage: record.language,
      value: value,
      contextVersions: Reconcile.persistableVersions(record.contextVersions),
      projectTag: project.name)
    try? context.save()
    return true
  }

  /// Cell-scoped confirm (flat slot, or one plural form when `category` is
  /// set). The value does not move, but the row still has to be re-merged:
  /// the slot just became human-confirmed, and the file only learns that from
  /// the merge (`needs_review` -> `translated` — the auto marker is DB-only
  /// provenance the artifact cannot carry).
  func confirmAutoReviewed(key: String, language: String, category: String? = nil) {
    guard let project,
          let record = Reconcile.record(
            key: key, language: language, category: category, in: project)
    else { return }
    confirmAutoReviewed(record)
    saveRow(key)
  }

  /// Row-scoped confirm: every auto-reviewed slot (flat + plural forms) of
  /// one key becomes human-reviewed in one click.
  func confirmAutoReviewedRow(_ key: String) {
    guard let project else { return }
    for record in Reconcile.records(ofKey: key, in: project) where record.autoReviewed {
      confirmAutoReviewed(record)
    }
    saveRow(key)
  }

  /// Row-driven save: commit exactly ONE edited row's records — its cells'
  /// live records, flat + plural forms across every language — back into
  /// the artifact, scoped to that key instead of walking the whole project,
  /// then adopts the updated catalog. Per-slot semantics match
  /// `Reconcile.merge` (owned records write value+state; empty slots stay
  /// absent; plural and flat slots never cross).
  private func saveRow(_ key: String) {
    guard let catalog, let project else { return }
    // Pure key-scoped merge on this thread (no file I/O), then the write
    // is handed to the coalescing background worker.
    let merged = Reconcile.merge(catalog, project: project, keys: [key])
    self.catalog = merged.catalog
    saveError = nil
    // The edit may have created the slot's record (a first value), so the key is re-read,
    // and only its row is rebuilt.
    refreshKeys([key])
    if merged.changed {
      markDirty()
    }
  }

  /// Translates the open catalog; nil record slots fall back to the file.
  /// Plural form records win over the file mid-run; plural slots are read
  /// via pluralValue(for:language:category:).
  func value(for key: String, language: String) -> String {
    if let override = valueOverrides[key]?[language] { return override }
    // Working-store value first: pipeline fills land in the DB record
    // mid-run and only reach the .xcstrings file at the end-of-run commit,
    // so cells must read the record (not the parsed file) to update as the
    // run writes them.
    if let record = recordIndex[key]?[language]?[""],
       let recordValue = record.value,
       !recordValue.isBlankOrEmpty {
      return recordValue
    }
    return catalog?.rawValue(for: key, language: language) ?? ""
  }

  /// Live value of one plural form: per-form record first (mid-run fills),
  /// else the parsed file, else the source form (AI/reference context).
  func pluralValue(for key: String, language: String, category: String) -> String {
    if let record = recordIndex[key]?[language]?[category],
       let recordValue = record.value,
       !recordValue.isBlankOrEmpty {
      return recordValue
    }
    return catalog?.pluralValue(for: key, language: language, category: category) ?? ""
  }

  /// Live per-form records for a plural slot (category -> record).
  func pluralRecords(for key: String, language: String) -> [String: TranslationRecord] {
    recordIndex[key]?[language]?.filter { $0.key != "" } ?? [:]
  }

  /// Parsed aggregate state across a plural slot's forms (needs_review wins,
  /// then new, then translated) — display only, never flipped by edits.
  func pluralAggregateState(for key: String, language: String) -> String? {
    guard let catalog else { return nil }
    let categories = PluralRules.categories(for: language)
    var seen: [String] = []
    for category in categories {
      if let state = catalog.pluralState(for: key, language: language, category: category),
         !seen.contains(state) {
        seen.append(state)
      }
      if let record = recordIndex[key]?[language]?[category],
         record.value != nil {
        // A DB-owned form carries a live state even when the file has no
        // unit yet — map it back to the file vocabulary for the dot.
        let mapped = record.state == .reviewed ? "translated"
          : record.state == .empty ? nil : "needs_review"
        if let mapped, !seen.contains(mapped) {
          seen.append(mapped)
        }
      }
    }
    if seen.contains("needs_review") { return "needs_review" }
    if seen.contains("new") { return "new" }
    return seen.first
  }

  /// One-line plural summary for a cell ("one: 1 file / other: %d files").
  func pluralSummary(for key: String, language: String) -> String {
    let categories = PluralRules.categories(for: language)
    let parts = categories.map { category in
      "\(category): \(pluralValue(for: key, language: language, category: category))"
    }
    return parts.joined(separator: " / ")
  }

  /// Source plural summary ("one: … / other: …"), empty for flat keys.
  /// Live: human source-form edits write straight to the file, so the parsed
  /// source forms ARE the current values.
  func sourcePluralSummary(for key: String) -> String {
    guard let catalog, catalog.hasPlurals(for: key, language: catalog.sourceLanguage) else { return "" }
    let categories = PluralRules.categories(for: catalog.sourceLanguage)
    let parts = categories.map { category in
      "\(category): \(catalog.sourcePluralDisplay(for: key, category: category))"
    }
    return parts.joined(separator: " / ")
  }

  /// Source reference text for one target form ("Source one: 1 file"):
  /// the matching source form, else source "other", else the key text.
  func sourcePluralReference(for key: String, category: String) -> String {
    guard let catalog else { return key }
    let text = catalog.sourcePluralDisplay(for: key, category: category)
    if languageHasMatchingSourceForm(category: category) {
      return "Source \(category): \(text)"
    }
    return "Source (other): \(text)"
  }

  /// True when the source language carries the same plural category (so the
  /// reference is a true match, not an "other" fallback).
  private func languageHasMatchingSourceForm(category: String) -> Bool {
    guard let catalog else { return false }
    return PluralRules.categories(for: catalog.sourceLanguage).contains(category)
  }

  func comment(for key: String) -> String {
    catalog?.strings[key]?.comment ?? ""
  }

  /// Writes one on-device generated comment onto a catalog entry (notes 2.8).
  ///
  /// A comment is the artifact's own field and has no home in the store (7.2),
  /// so the open catalog is where the pass puts it — exactly like any other
  /// app-side edit: rows are rebuilt for the UI, the store goes dirty, and the
  /// FILE still waits for Save, which stays the only writer of the .xcstrings
  /// (5.8). Nothing here writes a source path anywhere durable either: the
  /// pass reads its call sites from the scan's in-memory result.
  ///
  /// Refused when the entry is gone, when the comment is empty, or when the
  /// entry has GAINED a comment since the pass chose its targets — a human's
  /// comment is never rewritten, not even by that race.
  @discardableResult
  func setGeneratedComment(_ comment: String, for key: String) -> Bool {
    guard var catalog, let entry = catalog.strings[key] else { return false }
    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard (entry.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    catalog.strings[key]?.comment = trimmed
    self.catalog = catalog
    saveError = nil
    rebuildRows([key])
    // A COMMENT is not record state: the count cannot have moved, and the comment pass calls this
    // once per key (ScanController's on-device pass), so it must not pay a whole-project fetch.
    markDirty()
    return true
  }

  /// Commits one plural form: human edit -> .manual/.reviewed + a
  /// user-confirmed edit row on the per-form record, then writes the form
  /// back into the variation. Clearing a form to empty removes its file unit
  /// (absence IS empty) while the record goes .empty.
  func setPluralValue(_ text: String, for key: String, language: String, category: String) {
    guard var catalog, let project else { return }
    if language == catalog.sourceLanguage {
      // Source forms are authored text: straight to the file, no records.
      catalog.setSourcePluralValue(text, key: key, category: category)
      self.catalog = catalog
      saveError = nil
      rebuildRows([key])
      markDirty()
      return
    }
    let context = TranslationStore.shared.context
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      // Clear: drop the file unit, mark the form record empty (keeps its
      // provenance history for Stage 0 to ignore — empty forms learn nothing).
      catalog.setPluralValue("", state: nil, key: key, language: language, category: category)
      if let record = Reconcile.record(key: key, language: language, category: category, in: project) {
        record.value = nil
        record.state = .empty
        record.provider = nil
        record.confidence = nil
        record.reviewedAt = nil
        record.updatedAt = .now
        try? context.save()
      }
      self.catalog = catalog
      saveError = nil
      rebuildRows([key])
      markDirty()
      return
    }
    let sourceText = catalog.sourcePluralDisplay(for: key, category: category)
    Reconcile.applyHumanEdit(
      key: key, language: language, value: trimmed,
      sourceText: sourceText, project: project, context: context,
      category: category)
    saveRow(key)
  }

  func setValue(_ text: String, for key: String, language: String) {
    guard catalog != nil else { return }
    let parsed = catalog?.rawValue(for: key, language: language) ?? ""
    if text == parsed {
      removeOverride(key: key, language: language)
      rebuildRows([key])
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
    let sourceText = catalog.sourceDisplay(for: key)
    Reconcile.applyHumanEdit(
      key: key, language: language, value: text,
      sourceText: sourceText, project: project, context: context)
    saveRow(key)
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
    // Cells are pre-built for every language — a column toggle only
    // re-projects the visible set, no row re-derivation.
    recomputeVisibleRows()
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

  /// True when the catalog failed to load or a save failed.
  var hasError: Bool {
    loadError != nil || saveError != nil
  }

  /// Alert title for the current error.
  var errorTitle: String {
    saveError != nil ? "Couldn't save catalog" : "Couldn't open catalog"
  }

  /// Alert message for the current error (save error wins, then the load error).
  var errorMessage: String? {
    saveError ?? loadError
  }

  // MARK: - save (the only writer)

  /// Writes the open catalog back to its .xcstrings artifact. Save is the
  /// ONLY write path in the app: nothing saves implicitly — not a cell edit,
  /// not a Translate run, not the plural skeletons a run creates.
  func save() async {
    guard let catalog, let url = project?.catalogURL ?? catalogURL else { return }
    // The write is awaited, and edits keep landing while it runs: only an edit
    // made BEFORE the snapshot is on disk now, so the flag clears only when
    // nothing marked the catalog dirty in between.
    let snapshot = dirtyGeneration
    do {
      try await CatalogFileIO.write(catalog, to: url)
      saveError = nil
      if dirtyGeneration == snapshot { isDirty = false }
    } catch {
      saveError = error.localizedDescription
    }
  }

  /// Synchronous save for the quit prompt, where no runloop remains to await
  /// on. Returns false — with `saveError` set — when the write failed, so the
  /// caller can refuse to terminate instead of losing the edits.
  func saveBeforeTerminating() -> Bool {
    guard let catalog, let url = project?.catalogURL ?? catalogURL else { return true }
    do {
      try CatalogFileIO.writeSync(catalog, to: url)
      saveError = nil
      isDirty = false
      return true
    } catch {
      saveError = error.localizedDescription
      return false
    }
  }

  // MARK: - unsaved-changes prompt

  /// Alert title while a leave request waits on the prompt.
  var unsavedChangesTitle: String {
    "Save changes to \(unsavedCatalogName)?"
  }

  /// Alert body: what the pending leave would do with the unsaved edits.
  var unsavedChangesMessage: String {
    switch pendingLeave {
    case .reload:
      return "Reloading discards the edits this window has not written to the catalog yet."
    case .open, .openPanel:
      return "Opening another catalog discards the edits this window has not written to the catalog yet."
    case nil:
      return ""
    }
  }

  /// The file the unsaved edits belong to, for prompt text.
  var unsavedCatalogName: String {
    (project?.catalogURL ?? catalogURL)?.lastPathComponent ?? "the catalog"
  }

  /// Raises the unsaved-changes alert for a leave request.
  private func presentUnsavedPrompt(_ intent: LeaveIntent) {
    pendingLeave = intent
    isUnsavedPromptPresented = true
  }

  /// Closes the alert UI. The request itself stays pending until a button
  /// answers it, so an order-of-events difference between dismissal and the
  /// button action can never lose the user's choice.
  func dismissUnsavedPrompt() {
    isUnsavedPromptPresented = false
  }

  /// Answers the unsaved-changes prompt: write the catalog first, drop the
  /// in-memory edits, or stay where we are.
  func resolvePendingLeave(_ choice: LeaveChoice) async {
    guard let intent = pendingLeave else { return }
    pendingLeave = nil
    isUnsavedPromptPresented = false
    switch choice {
    case .cancel:
      return
    case .discard:
      await performLeave(intent)
    case .save:
      await save()
      // A failed write keeps us in place: saveError is showing.
      guard !isDirty else { return }
      await performLeave(intent)
    }
  }

  /// Runs the request the prompt was standing in front of.
  private func performLeave(_ intent: LeaveIntent) async {
    switch intent {
    case .reload: await performReload()
    case .open(let url): await performOpen(url)
    case .openPanel: presentOpenPanel()
    }
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
  func openDefaultIfPresent() async {
    guard catalog == nil else { return }
    let url = Self.defaultFixtureURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    await open(url)
  }

  // MARK: - generating a catalog

  /// Creates a catalog for a project that has none, then hands straight over
  /// to the SAME scan the "Scan Strings" toolbar button runs: the new file is
  /// empty, so the merge the scan proposes is every key the project's Swift
  /// packages and Xcode targets hold.
  ///
  /// The file is a real artifact the moment it is created (an empty, valid
  /// `.xcstrings` with the project's own source language — Xcode opens it
  /// like any other), so a user who generates and then closes the report
  /// without merging is left with an empty catalog rather than a store that
  /// believes in a file that does not exist. Keys reach the file by the
  /// normal path: merge into the open catalog (in memory), then Save.
  ///
  /// Refused — never overwritten — when the file already exists, or while the
  /// open catalog carries unsaved edits: a generated catalog replaces the open
  /// one, and nothing in this app discards edits implicitly.
  @discardableResult
  func generateCatalog(at url: URL, root: URL?) async -> Bool {
    guard !FileManager.default.fileExists(atPath: url.path) else { return false }
    guard !hasUnsavedChanges else {
      saveError = "The open catalog has edits its file does not have yet. Save or discard them, then generate this catalog."
      return false
    }
    let folder = (root ?? url.deletingLastPathComponent()).standardizedFileURL
    // The project's own development region, so a generated catalog is authored
    // in the language the project's sources are written in (its own String
    // Catalog would use the same), not an assumed "en".
    let sourceLanguage = ScanXcodeProject.developmentRegion(under: folder) ?? "en"
    let blank = StringCatalog(sourceLanguage: sourceLanguage, version: "1.1", strings: [:])
    do {
      try await CatalogFileIO.write(blank, to: url)
    } catch {
      saveError = error.localizedDescription
      return false
    }
    // A brand-new catalog: reset the view state exactly like an open, so a
    // previous catalog's search/filter/columns cannot carry over.
    searchText = ""
    filter = .all
    includeNonTranslatable = false
    showComments = false
    showLongest = false
    sortOrder = [CatalogSort(.source)]
    selectedLanguages = []
    addedLanguages = []
    // A blank catalog has no values to disagree about, so it never asks: it is opened at
    // once and its (empty) mirror goes to the queue behind the pane like any other load.
    let project = Reconcile.ensureProject(catalogURL: url, in: TranslationStore.shared.context)
    adopt(blank, project: project, url: url)
    submitMirror(blank, url: url, generation: loadGeneration, policy: .appWins)
    scan.begin(store: self, root: scanRoot)
    return true
  }

  /// The projectless counterpart of `generateCatalog(at:root:)`: the repo-root
  /// test catalog. The pane offers this only when the fixture is absent, so a
  /// deleted test catalog can be rebuilt from the repo's own sources.
  @discardableResult
  func generateDefaultFixture() async -> Bool {
    let url = Self.defaultFixtureURL
    return await generateCatalog(at: url, root: url.deletingLastPathComponent())
  }

  /// Toolbar Open…: held on the unsaved-changes prompt first, so the file
  /// panel only appears once leaving has been answered.
  func openPanelAndLoad() {
    guard !hasUnsavedChanges else {
      presentUnsavedPrompt(.openPanel)
      return
    }
    presentOpenPanel()
  }

  /// Unguarded half: shows the .xcstrings file panel and opens the choice.
  private func presentOpenPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose an .xcstrings catalog"
    if let type = UTType(filenameExtension: "xcstrings") {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // Unguarded: the prompt (if any) was answered before the panel appeared,
    // so this must not ask again — re-entering the guarded `open` here would
    // loop the prompt forever on a discarded-edit leave.
    Task { await self.performOpen(url) }
  }

  /// Opens `url` only when it is NOT the catalog already open — the
  /// Localization tab's lazy open (see `ProjectDetailView`). Catalog loading is
  /// expensive (parse + the whole-catalog mirror + row build), so it happens
  /// when the user first opens the tool for a project, never merely because the
  /// project was selected; a tab revisit that still holds this catalog is a
  /// no-op, so per-catalog view state survives.
  func openIfNeeded(_ url: URL) async {
    guard catalogURL != url else { return }
    await open(url)
  }

  /// Opens `url`. When the open catalog has unsaved edits the request is held
  /// on the unsaved-changes prompt instead — nothing is written implicitly, so
  /// leaving has to be answered first.
  func open(_ url: URL) async {
    guard !hasUnsavedChanges else {
      presentUnsavedPrompt(.open(url))
      return
    }
    await performOpen(url)
  }

  /// Full (re)load: parse + reset everything. Used by Open….
  /// No language is selected by default; the user picks via the buttons.
  /// The decode runs off the main actor and the pane is opened in ONE main-actor
  /// step afterwards, so it never shows a half-opened catalog; the mirror into
  /// SwiftData is submitted behind it (`openCatalog`) and lands later.
  private func performOpen(_ url: URL) async {
    loadGeneration += 1
    let generation = loadGeneration
    pendingLoad = generation
    CatalogFileIO.flush()
    // Off the main actor: a real detached decode, not the no-op
    // `MainActor.run` hop this used to be (see `loadOffMainActor`).
    let result = await StringCatalog.loadOffMainActor(url)
    // A newer open/reload supersedes this one — never adopt a stale parse.
    guard generation == loadGeneration else { return }
    await land(result, url: url, generation: generation, purpose: .open)
  }

  /// The main-actor side of a finished parse — the one landing path both halves of a
  /// load go through (an open and a reload differ only in what they reset, see
  /// `finishLoad`).
  ///
  /// Two things stand between the parse and the table, and both are cheap: the DIFFERENCE
  /// scan (one scoped fetch plus a walk, no writes), and — only when it finds something to
  /// ask about — the versions prompt, which holds the parse with `pendingLoad` still set so
  /// a newer open/reload, a close or a store clear takes the question down with the load it
  /// belongs to. The MIRROR is not one of them: it is submitted behind the pane
  /// (`openCatalog`), because it is seconds of inserts on a big catalog and the table does
  /// not need a single one of them to be usable.
  private func land(
    _ result: Result<StringCatalog, Error>,
    url: URL,
    generation: Int,
    purpose: LoadPurpose
  ) async {
    switch result {
    case .success(let catalog):
      let differences = await Reconcile.detectDifferences(
        catalog, catalogURL: url, in: TranslationStore.container)
      // The scan is a fetch: a newer open/reload may have started and finished in the
      // meantime, so re-check before this one takes over the pane.
      guard generation == loadGeneration else { return }
      // THE SHAPE PASS, file half: where the file and the records disagree about the SHAPE of a
      // slot (one plural, one flat) and a person stands behind one of them, the REVIEWED side's
      // shape wins — converted here on the parsed document, and handed to the mirror for the
      // records. Shape is not part of the versions question: the answer decides VALUES, while the
      // reviewed value decides the shape, either way (a plural slot translated flat, or a flat slot
      // that a person filled form by form, is a slot the two halves of the app would otherwise
      // never agree about).
      let shapeConflicts = await Reconcile.detectShapeConflicts(
        catalog, catalogURL: url, in: TranslationStore.container)
      guard generation == loadGeneration else { return }
      var parsed = catalog
      var reshaped = false
      for conflict in shapeConflicts where conflict.fileShape != conflict.reviewedShape {
        switch conflict.reviewedShape {
        case .plural:
          parsed.varyByPlural(key: conflict.key, languages: [conflict.language])
        case .flat:
          parsed.flatten(key: conflict.key, language: conflict.language)
        }
        reshaped = true
      }
      if reshaped {
        NSLog(
          "[Localization] %d slot shape(s) followed the reviewed value in %@",
          shapeConflicts.count, url.lastPathComponent)
      }
      guard differences.isEmpty else {
        heldLoad = HeldLoad(
          catalog: parsed, url: url, purpose: purpose, generation: generation,
          shapeConflicts: shapeConflicts, reshaped: reshaped)
        pendingDifferences = differences.sample
        pendingDifferenceCount = differences.count
        isVersionsPromptPresented = true
        return
      }
      await openCatalog(
        parsed, url: url, generation: generation, purpose: purpose, policy: .appWins,
        shapeConflicts: shapeConflicts, reshaped: reshaped)
    case .failure(let error):
      finishLoadFailure(error, purpose: purpose)
      if pendingLoad == generation { pendingLoad = nil }
    }
  }

  /// Opens a parsed catalog: the pane gets the document and the rows the file already
  /// describes, and the store catches up behind it.
  ///
  /// The project row is find-or-create on the main context (one fetch of the registry), and
  /// it must NOT wait for the mirror: the pane's rows, the redesign's workspace and a run's
  /// first read all hang off it. The mirror is then SUBMITTED to the app's one store queue
  /// (`StoreWork.shared`) instead of awaited — that is the whole point of the split: an open
  /// that waits for 48,420 inserts is a window that reads "Opening catalog…" while the user
  /// is looking at a table the artifact could already have filled.
  private func openCatalog(
    _ catalog: StringCatalog,
    url: URL,
    generation: Int,
    purpose: LoadPurpose,
    policy: Reconcile.DifferencePolicy,
    shapeConflicts: [Reconcile.ShapeConflict] = [],
    reshaped: Bool = false
  ) async {
    let context = TranslationStore.shared.context
    let project = Reconcile.ensureProject(catalogURL: url, in: context)
    // SAVED before the mirror is submitted, and that is load-bearing: the project row is what
    // the mirror's own background context finds-or-creates by URL, and a row this context has
    // only INSERTED is invisible to it — the pass would make a SECOND row for the same file and
    // write the catalog into that one (found by the probe: 6001 rows and two projects for one
    // URL). One save of the registry here is cheaper than a reconciliation later.
    try? context.save()
    finishLoad(catalog, project: project, url: url, purpose: purpose)
    // A reshaped document is NOT a fresh parse any more: the pane holds an edit the file does not
    // have (the load changed a slot's shape), so Save is live and the unsaved-changes prompt will
    // say so — `finishLoad`/`adopt` clear the flag for a freshly parsed catalog, and this is the
    // one case where that would be a lie.
    if reshaped { markDirty() }
    submitMirror(
      catalog, url: url, generation: generation, policy: policy,
      shapeConflicts: shapeConflicts)
    if pendingLoad == generation { pendingLoad = nil }
  }

  /// Hands the whole-catalog mirror to the store queue, to run after whatever bulk work is
  /// already ahead of it (another catalog's mirror, a plural skeleton, a language seeding —
  /// they all write the same slots, so they are serial BY the queue).
  ///
  /// Nothing waits for this. What it lands with is the store's own rows, and
  /// `mirrorLanded` is where they become the table's: the badges, the needs-review counts
  /// and the provenance are the store's readings, so they arrive late rather than keeping
  /// the pane shut.
  private func submitMirror(
    _ catalog: StringCatalog,
    url: URL,
    generation: Int,
    policy: Reconcile.DifferencePolicy,
    shapeConflicts: [Reconcile.ShapeConflict] = []
  ) {
    StoreWork.shared.submit { [weak self] in
      let result = await Reconcile.mirrorOffMainActor(
        catalog, catalogURL: url, in: TranslationStore.container, policy: policy,
        shapeConflicts: shapeConflicts)
      self?.mirrorLanded(result, url: url, generation: generation)
    }
  }

  /// Applies a mirror that landed behind the pane.
  ///
  /// The generation guard is the load's own: a mirror submitted for a catalog that is no
  /// longer the open one (another project, a closed pane) must not rebuild this pane's
  /// rows. The records are durable either way — they belong to the project row, and the
  /// next open adopts them with everything else.
  private func mirrorLanded(
    _ result: Result<Reconcile.MirrorResult, Error>,
    url: URL,
    generation: Int
  ) {
    switch result {
    case .success(let mirror):
      NSLog(
        "[Localization] mirrored %@ behind the pane: %d created, %d refreshed, %d kept, "
          + "%d differing, %d given back, %d re-linked, %d dropped by shape",
        url.lastPathComponent, mirror.stats.created, mirror.stats.refreshed,
        mirror.stats.kept, mirror.stats.differing, mirror.reverted, mirror.repaired,
        mirror.stats.dropped)
      guard generation == loadGeneration, catalogURL == url else { return }
      // The mirror wrote on its OWN context, so this one's copies of those rows are stale
      // — fetch by identity, then re-read the records it wrote (see `rebuildRecordIndex`).
      let context = TranslationStore.shared.context
      if let landed = Reconcile.project(id: mirror.projectID, in: context) {
        project = landed
      }
      guard let project else { return }
      rebuildRecordIndex(from: Reconcile.records(of: project, in: context))
      buildRows()
      // The scan's merge preview is a diff against the catalog — keep it current while its
      // sheet is open.
      if scan.isPresented { scan.refreshPlan() }
    case .failure(let error):
      saveError = "Couldn't save the catalog's records: \(error.localizedDescription)"
    }
  }

  /// Opens a finished, mirrored parse: the view state and the document.
  ///
  /// An OPEN resets the view state to its defaults (a different file's search, columns
  /// and sort must not carry over); a RELOAD deliberately touches none of it — the
  /// reload's whole point is that the user keeps the view they were working in.
  private func finishLoad(
    _ catalog: StringCatalog,
    project: Project?,
    url: URL,
    purpose: LoadPurpose
  ) {
    if purpose == .open {
      searchText = ""
      filter = .all
      includeNonTranslatable = false
      showComments = false
      showLongest = false
      sortOrder = [CatalogSort(.source)]
      selectedLanguages = []
      addedLanguages = []
    }
    adopt(catalog, project: project, url: url)
  }

  /// Applies a failed parse. An OPEN that failed leaves nothing open — a pane showing
  /// half a catalog is worse than an empty one — while a RELOAD that failed leaves the
  /// open catalog exactly as it was and only reports the error: the document on screen
  /// is still the one the user is working in.
  private func finishLoadFailure(_ error: Error, purpose: LoadPurpose) {
    loadError = error.localizedDescription
    guard purpose == .open else { return }
    catalog = nil
    catalogURL = nil
    recordIndex = [:]
    rows = []
    visibleRows = []
    isDirty = false
    pendingLeave = nil
    isUnsavedPromptPresented = false
  }

  /// Closes the open catalog without opening another: the parsed document,
  /// the edits that never reached the file and every derived list are
  /// dropped, and the reconciled records are left to their owner — the
  /// project row (nothing is deleted here).
  ///
  /// Used when the project BEHIND the open catalog is removed from the
  /// sidebar: a store still pointing at that project would keep rendering its
  /// (now deleted) records and its next reconcile would silently re-create
  /// the project it just removed. Callers ask about unsaved edits and
  /// in-flight runs first — this is the unguarded half.
  func closeCatalog() {
    catalog = nil
    catalogURL = nil
    project = nil
    loadError = nil
    saveError = nil
    recordIndex = [:]
    rows = []
    visibleRows = []
    valueOverrides = [:]
    addedLanguages = []
    browserLanguages = []
    isDirty = false
    pendingLeave = nil
    isUnsavedPromptPresented = false
    // A parse held on the versions prompt belongs to THIS catalog: it goes with it.
    heldLoad = nil
    pendingDifferences = []
    pendingDifferenceCount = 0
    isVersionsPromptPresented = false
    // Supersede any parse still in flight, so it cannot adopt state over a
    // closed store.
    loadGeneration += 1
    pendingLoad = nil
    revision += 1
  }

  // MARK: - clearing the store (Design notes 7.5)

  /// Drops everything this window holds OVER the translation store, BEFORE a
  /// single row of it is deleted.
  ///
  /// The ORDER is the point: a `CatalogRow`'s cells carry the very
  /// `TranslationRecord` objects the mirror read (`LangCell.record`,
  /// `pluralRecords`), and an override is the display half of an edit whose
  /// record is about to be deleted, so a store emptied under a live mirror would
  /// leave this window reading objects that no longer exist. Everything the store
  /// supplied goes; the parsed DOCUMENT stays, because it is the artifact's
  /// in-memory form and Save is its only writer — `rebuildAfterStoreClear`
  /// re-derives the rows from it in the same turn.
  func dropStoreMirror() {
    recordIndex = [:]
    rows = []
    visibleRows = []
    valueOverrides = [:]
    saveError = nil
    // A parse held on the versions prompt would write the whole-catalog mirror this clear
    // just emptied: it is dropped with the store it was read against, and the generation
    // bump below is what makes its answer land nowhere.
    heldLoad = nil
    pendingDifferences = []
    pendingDifferenceCount = 0
    isVersionsPromptPresented = false
    // A parse still in flight must not land its whole-catalog MIRROR over a store
    // that was just emptied.
    loadGeneration += 1
    pendingLoad = nil
    revision += 1
  }

  /// Re-derives the table from the artifact, once the store has been emptied.
  ///
  /// What can be reloaded is reloaded and what cannot is dropped: the ROWS come
  /// from the open catalog again (with no record index behind them, so every slot
  /// reads as the file has it), while the record-derived readings — the state
  /// badges' provenance, the Update Translations counts, the widths and notes the
  /// records carried — are simply gone.
  ///
  /// The document itself is RE-READ from its file rather than kept: the store's
  /// values reach this window's document too (a run publishes its results into it
  /// — 5.8), and those are exactly the values the clear deleted, so keeping the
  /// document would leave the table showing them. What the table shows afterwards
  /// is what the artifact holds and nothing else, which is also what makes the
  /// loss the confirmation names true: edits this window had not written to the
  /// file go with the session.
  ///
  /// The parse deliberately does NOT go through the mirror: `submitMirror` is
  /// what writes a catalog's records into the store, and re-mirroring on the way
  /// in would put back the rows the clear just deleted.
  func reloadAfterStoreClear() async {
    guard let url = catalogURL else { return }
    loadGeneration += 1
    let generation = loadGeneration
    pendingLoad = generation
    CatalogFileIO.flush()
    let result = await StringCatalog.loadOffMainActor(url)
    guard generation == loadGeneration else { return }
    switch result {
    case .success(let catalog):
      // No mirror, and no unsaved-changes prompt: the clear's own confirmation
      // already answered for the edits this drops (7.5).
      adopt(catalog, project: project, url: url)
    case .failure(let error):
      loadError = error.localizedDescription
    }
    if pendingLoad == generation { pendingLoad = nil }
  }

  /// Re-read the current file and drop overrides; view state is untouched.
  /// Decodes off the main thread like `open`. Held on the unsaved-changes
  /// prompt when there are edits the file does not have yet.
  func reload() async {
    guard !hasUnsavedChanges else {
      presentUnsavedPrompt(.reload)
      return
    }
    await performReload()
  }

  /// Unguarded half of `reload`: re-reads the file and drops the overrides.
  private func performReload() async {
    guard let url = catalogURL else { return }
    loadGeneration += 1
    let generation = loadGeneration
    pendingLoad = generation
    CatalogFileIO.flush()
    let result = await StringCatalog.loadOffMainActor(url)
    guard generation == loadGeneration else { return }
    await land(result, url: url, generation: generation, purpose: .reload)
  }

  // MARK: - versions prompt (file vs the app's records)

  /// Title of the versions alert: the load found slots the file and the app's records
  /// fill with different values.
  var versionsPromptTitle: String {
    "Which version should load?"
  }

  /// Body of the versions alert: how many slots are in play, a few of them by name, what a person
  /// confirmed about them, and what each answer does — including the part that is invisible from
  /// the pane, that keeping the app's records leaves the file's values to be overwritten by the
  /// next row save.
  ///
  /// The alert only ever asks about slots with a REVIEWED value on one side (see
  /// `Reconcile.differences`): machine output, imported text and empty slots never raise it, which
  /// is why the question can say what it is about.
  var versionsPromptMessage: String {
    let count = pendingDifferenceCount
    let named = pendingDifferences.prefix(3)
    var text = "One side is a value a person confirmed and the two disagree, for "
      + "\(count) \(count == 1 ? "slot" : "slots") — "
      + named.map(\.label).joined(separator: ", ")
    if count > named.count { text += " (and \(count - named.count) more)" }
    text += "."
    text += "\n\nLoading the file's values replaces what the app holds for those slots; "
      + "the replaced values stay in the row's edit history."
    text += "\n\nKeeping the app's records leaves the file's values out of the app — the row "
      + "still holds the app's value, and saving that row writes it back over the file's."
    // The shape work is NOT part of the question — the reviewed value's shape wins either way (see
    // `LocalizationStore.land`) — so the alert only reports it.
    let shapes = heldLoad?.shapeConflicts.count ?? 0
    if shapes > 0 {
      text += "\n\n\(shapes) of them also changed shape (plural vs single): the shape follows "
        + "the value a person confirmed."
    }
    if heldLoad?.purpose == .open { text += " Cancelling leaves the catalog closed." }
    return text
  }

  /// Raises the versions alert. The parse is already held (`heldLoad`); nothing else
  /// happens until a button answers it.
  func dismissVersionsPrompt() {
    isVersionsPromptPresented = false
  }

  /// Answers the versions prompt: load the file's values for the differing slots, keep
  /// the app's records, or open nothing.
  ///
  /// The answer is what the mirror is then submitted with — the scan that asked wrote
  /// nothing at all (`Reconcile.detectDifferences`), so this is the pass that makes the
  /// choice durable — and the parse is opened exactly as an unanswered load would have been
  /// (the pane up at once, the mirror behind it). A generation mismatch means a newer
  /// open/reload, a close or a store clear happened while the alert was up: the answer is
  /// dropped rather than applied over it, and the load it belonged to is gone with the
  /// parse.
  func resolveDifferences(_ choice: DifferenceChoice) async {
    guard let held = heldLoad else { return }
    heldLoad = nil
    isVersionsPromptPresented = false
    pendingDifferences = []
    pendingDifferenceCount = 0
    guard choice != .cancel else {
      // No parse is adopted and the generation is NOT bumped: the pane stays exactly as
      // it was — the catalog already open, for a reload that was cancelled.
      if pendingLoad == held.generation { pendingLoad = nil }
      return
    }
    guard held.generation == loadGeneration else { return }
    let policy: Reconcile.DifferencePolicy = choice == .file ? .fileWins : .appWins
    await openCatalog(
      held.catalog, url: held.url, generation: held.generation, purpose: held.purpose,
      policy: policy, shapeConflicts: held.shapeConflicts, reshaped: held.reshaped)
  }

  /// Opens a catalog that has already been mirrored into the DB: the document,
  /// the project row the mirror wrote and the rows derived from both. The ONE
  /// place the store's open state changes, so `catalog`, `catalogURL` and
  /// `project` are never published half-set.
  private func adopt(_ catalog: StringCatalog, project: Project?, url: URL) {
    self.catalog = catalog
    catalogURL = url
    valueOverrides = [:]
    revision += 1
    // A freshly parsed catalog carries no edits of ours.
    isDirty = false
    pendingLeave = nil
    isUnsavedPromptPresented = false
    loadError = nil
    self.project = project
    if let project {
      // ONE query for the records the mirror just wrote: this context is cold,
      // so the relationship would fault per row (4.2 s for 48k) and this fetch
      // is what makes the table's cells live (0.6 s).
      rebuildRecordIndex(from: Reconcile.records(of: project, in: TranslationStore.shared.context))
    } else {
      rebuildRecordIndex(from: [])
    }
    // The document must name every language the records carry before the rows
    // are derived from it (see `topUpCatalogLanguages`).
    topUpCatalogLanguages()
    buildRows()
    // The scan's merge preview is a diff against the catalog — keep it
    // current while its sheet is open.
    if scan.isPresented {
      scan.refreshPlan()
    }
  }

  /// True while the STORE is still catching up with the pane: the app's one work queue has
  /// bulk writes to run (a whole-catalog mirror, a plural skeleton, a language seeding).
  ///
  /// Nothing the user does with the table waits for this — that is the point of the queue
  /// — but the operations that need a SETTLED store say so: the clear (7.5) refuses while
  /// one is running, and a run's own reads are the run's own business (`adoptForeignWrites`
  /// is how a session picks up what landed behind it).
  var isSyncing: Bool { StoreWork.shared.isBusy }

  /// Re-mirrors the OPEN catalog into the DB on the main actor and refreshes
  /// the derived rows — the per-key mutations' path (plural vary/remove,
  /// don't-translate: `keys` names the one key, so only its slots are upserted
  /// and only its row is rebuilt) and the scan merge's (new keys anywhere, so
  /// the whole catalog).
  private func mirrorOpenCatalog(_ catalog: StringCatalog, url: URL, keys: Set<String>? = nil) {
    let context = TranslationStore.shared.context
    // The open project owns this catalog; a URL that does not match it (a
    // stale caller) falls back to the find-or-create the mirror path uses.
    let project = (self.project?.catalogURL == url ? self.project : nil)
      ?? Reconcile.ensureProject(catalogURL: url, in: context)
    if let keys {
      _ = Reconcile.upsertFromCatalog(
        catalog, project: project,
        existing: keys.flatMap { Reconcile.records(ofKey: $0, in: project) },
        context: context, keys: keys)
      try? context.save()
      self.project = project
      refreshKeys(keys)
    } else {
      // One scoped fetch for the existing rows and for the membership write
      // (`liveWriters`): the relationship is not kept warm by anything, and a cold
      // walk of it is seconds — see `rebuildRecordIndex`.
      _ = Reconcile.upsertFromCatalog(
        catalog, project: project, existing: Reconcile.records(of: project, in: context),
        context: context, liveWriters: true)
      try? context.save()
      self.project = project
      rebuildRecordIndex()
      buildRows()
    }
    // The scan's merge preview is a diff against the catalog — keep it
    // current while its sheet is open.
    if scan.isPresented {
      scan.refreshPlan()
    }
  }

  /// Re-indexes the project's live records by (key, language, form) for O(1)
  /// per-cell lookups — the WHOLE-project rebuild, for the events that touch the
  /// whole project (a run's results, a language seeding, a scan merge). Row edits
  /// re-read only their own key (`refreshKeys`).
  ///
  /// ONE scoped fetch (`Reconcile.records(of:in:)`), never `project.records`: no
  /// per-edit path walks the relationship any more, so nothing keeps it warm, and
  /// a cold walk faults every row one at a time — 4.2 s ON THE MAIN ACTOR for a
  /// 48,420-record catalog, against ~0.6 s for the fetch.
  private func rebuildRecordIndex() {
    guard let project else {
      recordIndex = [:]
      return
    }
    rebuildRecordIndex(from: Reconcile.records(of: project, in: TranslationStore.shared.context))
  }

  /// Same, from records the caller already holds.
  private func rebuildRecordIndex(from records: [TranslationRecord]) {
    var index: [String: [String: [String: TranslationRecord]]] = [:]
    index.reserveCapacity(records.count)
    for record in records {
      index[record.key, default: [:]][record.language, default: [:]][record.category ?? ""] = record
    }
    recordIndex = index
  }

  // MARK: - background file I/O

  /// Bumped by every open/reload; a finished parse whose generation no
  /// longer matches the latest request is discarded, so rapid open/reload
  /// never stacks or applies stale state over newer work.
  private var loadGeneration = 0

  /// The generation whose parse has not landed yet — a catalog open or reload in
  /// flight. Keyed by generation rather than held as a bool so a superseded parse
  /// cannot clear a newer one's flag, and so closing the catalog (which bumps the
  /// generation) takes it down with the parse it belongs to.
  private var pendingLoad: Int?

  /// True while a load request is still being made ready: the parse, the difference scan
  /// and the adopt. The MIRROR is not part of it (`isSyncing` is that half), because the
  /// pane does not wait for it — this flag is what the "Opening catalog…" state reads.
  var isLoading: Bool { pendingLoad != nil }

  /// Marks the open catalog as carrying edits the file does not have yet.
  /// Every catalog mutation funnels here instead of writing: the artifact is
  /// only written by `save()`, so an edit is durable in the DB (records) and
  /// pending on disk until the user saves.
  private func markDirty() {
    isDirty = true
    dirtyGeneration += 1
  }

  /// Bumped by every `markDirty`, so a Save that was in flight while an edit
  /// landed can tell that its snapshot is not the latest catalog.
  private var dirtyGeneration = 0

  // MARK: - rows

  /// Materialized rows — one CatalogRow per catalog key. Converted from
  /// `catalog.strings` on load (reconcile) and re-converted after every
  /// commit/save, so the table never derives rows on render. Cells hold
  /// live TranslationRecord refs, so mid-run values and spinners still
  /// update without a rebuild.
  private(set) var rows: [CatalogRow] = []

  /// What the table shows: `rows` after the include toggle, filter, search
  /// and sort. Recomputed whenever those inputs change and whenever `rows`
  /// is rebuilt — never derived per render.
  private(set) var visibleRows: [CatalogRow] = []

  /// Re-projects `rows` through the current include toggle, filter, search
  /// and sort. Pure predicates over what the rows already carry — no
  /// per-row catalog derivation, so per-keystroke search stays cheap.
  private func recomputeVisibleRows() {
    guard !rows.isEmpty else {
      visibleRows = []
      return
    }
    let query = folded(searchText)
    var shown: [CatalogRow] = []
    shown.reserveCapacity(rows.count)
    for row in rows {
      if !includeNonTranslatable && !row.isTranslatable { continue }
      guard matchesFilter(row) else { continue }
      if !query.isEmpty && !row.searchBlob.contains(query) { continue }
      shown.append(row)
    }
    let sort = sortOrder.isEmpty ? [CatalogSort(.source)] : sortOrder
    visibleRows = shown.sorted(using: sort)
  }

  /// (Re)builds `rows` from the open catalog — the strings -> rows
  /// conversion — then re-applies the current filters. Called from
  /// reconcile (every load) and after every commit/save, so `rows` always
  /// mirrors the artifact that was just written.
  private func buildRows() {
    browserLanguages = computeBrowserLanguages()
    guard let catalog else {
      rows = []
      visibleRows = []
      return
    }
    var built: [CatalogRow] = []
    var positions: [String: Int] = [:]
    built.reserveCapacity(catalog.strings.count)
    positions.reserveCapacity(catalog.strings.count)
    for (key, entry) in catalog.strings {
      positions[key] = built.count
      built.append(makeRow(catalog: catalog, key: key, entry: entry))
    }
    rows = built
    rowPositions = positions
    recomputeVisibleRows()
  }

  /// key -> its position in `rows`, kept by `buildRows` for the row-scoped rebuild.
  private var rowPositions: [String: Int] = [:]

  /// Rebuilds ONLY the rows of `keys` — an edit touches one row, and rebuilding every row
  /// of the catalog for it (every language cell, every search haystack folded again) was
  /// most of what an edit cost on a big catalog. Falls back to `buildRows` whenever the
  /// shape around the rows moved: the browser's language set (a cell per language), or a
  /// key the rows do not have yet or that the catalog no longer has.
  private func rebuildRows(_ keys: Set<String>) {
    guard let catalog, !rows.isEmpty else { return buildRows() }
    let languages = computeBrowserLanguages()
    guard languages == browserLanguages else { return buildRows() }
    for key in keys {
      guard let entry = catalog.strings[key], let position = rowPositions[key],
        rows.indices.contains(position), rows[position].key == key
      else { return buildRows() }
      rows[position] = makeRow(catalog: catalog, key: key, entry: entry)
    }
    recomputeVisibleRows()
  }

  /// Re-reads `keys`' records into the index (one scoped fetch per key — an edit may have
  /// created a record, and a run may have written one meanwhile), then rebuilds their rows.
  private func refreshKeys(_ keys: Set<String>) {
    guard let project else { return rebuildRows(keys) }
    for key in keys {
      var byLanguage: [String: [String: TranslationRecord]] = [:]
      for record in Reconcile.records(ofKey: key, in: project) {
        byLanguage[record.language, default: [:]][record.category ?? ""] = record
      }
      recordIndex[key] = byLanguage.isEmpty ? nil : byLanguage
    }
    rebuildRows(keys)
  }

  /// Recomputes `browserLanguages`: the open catalog's codes, the languages
  /// added in this window, and the ones this project's records carry (an
  /// added language lives in the DB before the file knows it — see
  /// `addLanguage`). Sorted, source excluded.
  private func computeBrowserLanguages() -> [String] {
    var seen = Set(catalog?.languages ?? [])
    seen.formUnion(addedLanguages)
    for byLanguage in recordIndex.values {
      seen.formUnion(byLanguage.keys)
    }
    if let source = catalog?.sourceLanguage {
      seen.remove(source)
    }
    return seen.sorted()
  }

  /// Gives the open document every language this project's records carry.
  ///
  /// A language added in an earlier session is in the RECORDS only (its empty
  /// file nodes are pruned on save), while the engine's own language list —
  /// `catalog.languages`, read by the plural-skeleton passes — is the
  /// document's. Topping the document up here is what keeps the two halves
  /// from disagreeing: a whole-catalog run varies plural keys for every
  /// language the catalog names, so an added language missing from the
  /// document would silently get no plural forms at all.
  private func topUpCatalogLanguages() {
    guard let catalog else { return }
    let known = Set(catalog.languages)
    var missing = Set<String>()
    for byLanguage in recordIndex.values {
      for language in byLanguage.keys where !known.contains(language) {
        missing.insert(language)
      }
    }
    guard !missing.isEmpty else { return }
    var updated = catalog
    for language in missing.sorted() {
      updated.addLanguage(language)
    }
    self.catalog = updated
  }

  private func makeRow(
    catalog: StringCatalog,
    key: String,
    entry: StringCatalog.Entry
  ) -> CatalogRow {
    let translatable = entry.shouldTranslate != false
    let rowHasPlurals = catalog.hasPlurals(for: key)
    // Cells for EVERY language the browser shows, selected or not — a
    // language column toggle only re-projects `visibleRows`, never re-derives
    // rows. `browserLanguages` (catalog codes + added/record-carried ones,
    // see `computeBrowserLanguages`) is what the strip lists, so a language
    // the file does not know yet still gets its missing cells.
    // The same per-language pass feeds each LangCell AND the row review
    // flags (all languages, flat + plural forms).
    var cells: [String: LangCell] = [:]
    var filled = 0
    var reviewed = 0
    var needsReview = 0
    func tally(record: TranslationRecord?, fileValue: String?, fileState: String?) {
      // A filled slot counts reviewed when its live record is .reviewed (or
      // the file says "translated"); needs_review when live .needs_review
      // (or the file says so). Draft overrides don't count.
      if let record,
         let value = record.value,
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        filled += 1
        if record.state == .reviewed { reviewed += 1 }
        else if record.state == .needs_review { needsReview += 1 }
      } else if let fileValue,
                !fileValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        filled += 1
        if fileState == "translated" { reviewed += 1 }
        else if fileState == "needs_review" { needsReview += 1 }
      }
    }
    for language in browserLanguages {
      let loc = entry.localizations?[language]
      let plural = catalog.hasPlurals(for: key, language: language)
      let device = !plural && (loc?.variations?.isEmpty == false)
      if plural {
        // Plural slot: tally every form, then one LangCell carrying the form
        // summary + per-form live records (it opens the plural editor).
        let units = catalog.pluralUnits(for: key, language: language)
        for category in PluralRules.categories(for: language) {
          tally(
            record: recordIndex[key]?[language]?[category],
            fileValue: units?[category]?.value,
            fileState: units?[category]?.state)
        }
        let forms = pluralRecords(for: key, language: language)
        cells[language] = LangCell(
          text: pluralSummary(for: key, language: language),
          state: pluralAggregateState(for: key, language: language),
          hasParsed: units != nil,
          hasOverride: false,
          hasVariations: true,
          hasPlurals: true,
          isEditable: translatable,
          record: nil,
          pluralRecords: forms)
        continue
      }
      // Flat slot: tally + one cell in the same pass.
      let unit = loc?.stringUnit
      let flatRecord = recordIndex[key]?[language]?[""]
      tally(
        record: flatRecord,
        fileValue: unit?.value,
        fileState: unit?.state)
      cells[language] = LangCell(
        text: valueOverrides[key]?[language] ?? unit?.value ?? "",
        state: unit?.state,
        hasParsed: unit != nil,
        hasOverride: valueOverrides[key]?[language] != nil,
        hasVariations: device,
        hasPlurals: false,
        isEditable: translatable && !device,
        record: flatRecord,
        pluralRecords: [:])
    }
    let sourceText = catalog.sourceDisplay(for: key)
    // The guideline is key-scoped metadata on the records; the first one that
    // carries it is authoritative (same rule as the reviewer note).
    let width = cells.values.compactMap { cell -> Int? in
      cell.record?.maxWidth ?? cell.pluralRecords.values.compactMap(\.maxWidth).first
    }.first
    let (longestText, longestLanguage) = Self.longestValue(
      catalog: catalog, key: key, sourceText: sourceText,
      overrides: valueOverrides[key])
    return CatalogRow(
      key: key,
      isTranslatable: translatable,
      hasPlurals: rowHasPlurals,
      sourceText: sourceText,
      sourcePluralSummary: sourcePluralSummary(for: key),
      longestText: longestText,
      longestLanguage: longestLanguage,
      longestLength: longestText.count,
      commentText: entry.comment ?? "",
      cells: cells,
      isFullyReviewed: filled > 0 && reviewed == filled,
      isFullyNeedsReview: filled > 0 && needsReview == filled,
      searchBlob: folded(searchBlobText(key: key, entry: entry)),
      maxWidth: width)
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
        if let variations = language.variations {
          for forms in variations.values {
            for form in forms.values {
              if let value = form.stringUnit?.value {
                parts.append(value)
              }
            }
          }
        }
      }
    }
    return parts.joined(separator: "\n")
  }

  /// Filter across the VISIBLE non-source language columns only: a key
  /// matches when the chosen state occurs in at least one SELECTED column.
  /// `cells` now holds every language, so the match is scoped to
  /// `selectedLanguages` — a hidden language never drives the filters.
  private func matchesFilter(_ row: CatalogRow) -> Bool {
    switch filter {
    case .all:
      return true
    case .needsReview:
      return selectedLanguages.contains { row.cells[$0]?.state == "needs_review" }
    case .missing:
      return selectedLanguages.contains { row.cells[$0]?.isMissing == true }
    case .translated:
      return selectedLanguages.contains { row.cells[$0]?.state == "translated" }
    case .new:
      return selectedLanguages.contains { row.cells[$0]?.state == "new" }
    case .tooWide:
      guard let limit = row.maxWidth else { return false }
      return selectedLanguages.contains { row.cells[$0]?.isOverWidth(limit) == true }
    }
  }

  /// Missing count for one language over the base key set (respects the
  /// non-translatable toggle, ignores search/filter). Reads the same
  /// `LangCell.isMissing` the Missing filter does, so a plural slot counts by
  /// its forms and the footer and the filter cannot disagree.
  func missingCount(for language: String) -> Int {
    rows.reduce(0) { count, row in
      guard includeNonTranslatable || row.isTranslatable else { return count }
      return row.cells[language]?.isMissing ?? true ? count + 1 : count
    }
  }
}

// MARK: - Folding helper

/// Case- and diacritic-insensitive folding used by search.
func folded(_ string: String) -> String {
  string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

// MARK: - Catalog file I/O

/// Serial worker for .xcstrings writes. It has exactly ONE caller — the
/// store's `save()` — because nothing in this app writes the artifact
/// implicitly: no edit, no run, no skeleton. The queue keeps a save off the
/// main thread and `flush()` lets a reader block until an in-flight write has
/// landed (open/reload, and a run that reads the file when no catalog is
/// open).
enum CatalogFileIO {
  private static let queue = DispatchQueue(
    label: "dev.v57.dev.catalog-fileio", qos: .userInitiated)

  /// Writes `catalog` to `url` off the main thread. Throws the encode/write
  /// failure to the caller, which turns it into the save alert.
  static func write(_ catalog: StringCatalog, to url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          try catalog.save(to: url)
          continuation.resume(returning: ())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Synchronous variant for the quit prompt, where no runloop is left to
  /// await on. Throws so the caller can refuse to terminate.
  static func writeSync(_ catalog: StringCatalog, to url: URL) throws {
    try queue.sync { try catalog.save(to: url) }
  }

  /// Blocks the caller until every previously requested write has landed.
  /// Never call from `queue` itself.
  static func flush() {
    queue.sync {}
  }
}
