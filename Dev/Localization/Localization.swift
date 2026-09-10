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
  /// spinner, provenance tooltip and mid-run text read it directly. Nil for
  /// plural holders (see pluralRecords), device holders and
  /// non-translatable keys, which reconcile does not model flat.
  let record: TranslationRecord?
  /// Live per-form records (category -> record) for plural slots; empty for
  /// flat cells. Each form is a full translation slot with its own value,
  /// state and provenance.
  let pluralRecords: [String: TranslationRecord]

  /// True while the run is active AND any of this cell's records is a
  /// not-yet-written run target.
  func isInFlight(run: TranslateRunController) -> Bool {
    if let record, run.isInFlight(record) { return true }
    return pluralRecords.values.contains { run.isInFlight($0) }
  }

  /// No value at all: no parsed unit, no override, and no variations to show.
  /// Plural slots are missing only when no form carries anything.
  var isMissing: Bool {
    if hasPlurals {
      if hasParsed || hasOverride { return false }
      return pluralRecords.values.allSatisfy { $0.value?.isBlankOrEmpty != false }
    }
    return !hasParsed && !hasOverride && !hasVariations
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

  var pickerLanguages: [String] {
    guard let catalog else { return [] }
    return catalog.languages.filter { $0 != catalog.sourceLanguage }
  }

  var sourceLanguageTitle: String {
    guard let catalog else { return "" }
    return "\(catalog.sourceLanguage) (source)"
  }

  var totalKeyCount: Int { catalog?.strings.count ?? 0 }

  /// Distinct keys with at least one FILLED needs_review record — same
  /// key-level semantics as the sidebar project badge (a key counts when
  /// ANY of its language/plural slots needs review). Reads the open
  /// catalog's reconciled records; 0 when no catalog is open.
  var needsReviewKeyCount: Int {
    guard let project else { return 0 }
    var reviewKeys = Set<String>()
    for record in project.records {
      if let value = record.value,
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         record.state == .needs_review {
        reviewKeys.insert(record.key)
      }
    }
    return reviewKeys.count
  }

  /// Keys explicitly marked shouldTranslate = false.
  var nonTranslatableCount: Int {
    catalog?.strings.values.filter { $0.shouldTranslate == false }.count ?? 0
  }

  // MARK: - SwiftData working store (records + run)

  /// Live SwiftData records of the open project, indexed (key, language,
  /// form-or-flat). Rebuilt on every reconcile (open/reload); record objects
  /// are mutated in place by edits and pipeline runs, so the refs stay
  /// valid. The "" form key is the flat slot; named keys are plural forms.
  private var recordIndex: [String: [String: [String: TranslationRecord]]] = [:]

  /// Drives the Translate run lifecycle — progress, cancel, per-cell
  /// in-flight state and the last-run summary. One instance per store.
  let run = TranslateRunController()

  /// Drives Scan Strings — live progress, cancel, the finished report and
  /// the merge it proposes. One instance per store, so the toolbar button
  /// and the report sheet share it.
  let scan = ScanController()

  /// True when the Scan Strings button may start a scan: a project-bound
  /// catalog is open, its project has a root to scan and no other run is in
  /// flight.
  var canScan: Bool {
    isLoaded && project != nil && scanRoot != nil && !run.isRunning && !scan.isRunning
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

  /// True when the Translate button may start a run.
  var canTranslate: Bool { isLoaded && project != nil && !run.isRunning && !scan.isRunning }

  /// True when the Save button may write the artifact.
  var canSave: Bool { isDirty && isLoaded && project != nil }

  /// True when the open catalog carries edits the file does not have yet.
  var hasUnsavedChanges: Bool { isDirty && isLoaded }

  /// Kicks the pipeline off from the Translate button (async Task; re-entry
  /// is guarded by `begin`). When the run returns, its DB output is merged
  /// into the OPEN in-memory catalog — never written: the artifact changes
  /// only on Save, so a run cannot touch a file behind the user's back.
  func startTranslate() {
    guard let project, beginRun(project: project, key: nil, languages: nil, force: false) else { return }
    Task { await performTranslate(project: project, key: nil) }
  }

  /// Prepares a run's scope, then starts its lifecycle. Plural forms the
  /// catalog does not have yet are varied FIRST (in memory — the artifact is
  /// written only by Save), so the controller's spinner candidates include
  /// them. False when a run is already active.
  private func beginRun(project: Project, key: String?, languages: Set<String>?, force: Bool) -> Bool {
    guard !run.isRunning else { return false }
    if let varied = run.ensurePluralForms(
      project: project, catalog: catalog, key: key, languages: languages) {
      catalog = varied
      markDirty()
    }
    return run.begin(project: project, key: key, languages: languages, force: force)
  }

  /// Row-menu "Translate": runs the pipeline scoped to a single key AND only
  /// the currently-selected language columns (the visible sections), with the
  /// freshness gate lifted so even a fresh `needs_review` machine value is
  /// re-translated/reviewed. Reuses the shared run controller so the footer
  /// shows progress and re-entry is guarded. No columns selected => no
  /// targets (nothing is translated).
  func translateKey(_ key: String) {
    let languages = Set(selectedLanguages)
    guard let project, beginRun(project: project, key: key, languages: languages, force: true) else { return }
    Task { await performTranslate(project: project, key: key, languages: languages, force: true) }
  }

  // MARK: - row inspection (diagnostics)

  /// The key whose inspector overlay is open, or nil.
  var inspectedKey: String?
  /// Trace of the current (or last) inspection.
  let trace = TranslationTrace()
  /// True while an inspection is running.
  private(set) var isInspecting = false

  /// Opens the inspector for `key` and runs the appropriate test: a full
  /// pipeline run for a row with no reviewed slot, or just the learning fold
  /// for a reviewed one.
  func inspect(_ key: String) {
    guard !run.isRunning, !isInspecting else { return }
    inspectedKey = key
    Task { await runInspection(key) }
  }

  func closeInspector() {
    inspectedKey = nil
  }

  private func runInspection(_ key: String) async {
    guard let project else { return }
    let records = project.records.filter { $0.key == key }
    // Reviewed slots are tested for what the pipeline LEARNS from them;
    // everything still open is tested by translating it. A row can be both.
    let reviewed = records
      .filter { $0.state == .reviewed }
      .sorted { ($0.language, $0.category ?? "") < ($1.language, $1.category ?? "") }
    let runnable = records
      .filter { $0.state != .reviewed && $0.provider != .manual }
      .sorted { ($0.language, $0.category ?? "") < ($1.language, $1.category ?? "") }

    let mode: TranslationTrace.Mode
    switch (reviewed.isEmpty, runnable.isEmpty) {
    case (false, false): mode = .mixed
    case (false, true): mode = .learning
    case (true, _): mode = .fullRun
    }

    trace.begin(key: key, mode: mode)
    isInspecting = true
    defer {
      isInspecting = false
      trace.finish()
    }

    switch mode {
    case .fullRun:
      trace.note("No reviewed slot on this row — running the full pipeline for the key.")
      await inspectFullRun(key: key, project: project, languages: languages(of: runnable))
    case .learning:
      trace.note("\(reviewed.count) reviewed slot(s) — folding the human edits into the context docs instead of translating.")
      await inspectLearning(project: project, records: reviewed)
    case .mixed:
      trace.note("\(reviewed.count) reviewed slot(s) to learn, \(runnable.count) slot(s) to translate — doing both.")
      await inspectLearning(project: project, records: reviewed)
      await inspectFullRun(key: key, project: project, languages: languages(of: runnable))
    }
  }

  /// Languages of the slots a full run should touch, or nil when unknown.
  private func languages(of records: [TranslationRecord]) -> Set<String>? {
    let languages = Set(records.map(\.language))
    return languages.isEmpty ? nil : languages
  }

  /// Untranslated / needs-review row: run the whole pipeline for this one key.
  private func inspectFullRun(key: String, project: Project, languages: Set<String>?) async {
    // `languages` nil means "every target language of the key". The run gets
    // the OPEN catalog (never the file): unsaved edits are its prompt context,
    // and a run writes nothing to the artifact.
    let summary = await TranslationPipeline.run(
      project: project,
      key: key,
      languages: languages,
      force: true,
      catalog: catalog,
      trace: trace)
    trace.note("Run finished: \(summary.recordsTouched) record(s) touched, \(summary.failures.count) failure(s)")

    // Fold the writes back into the catalog/table — in memory, exactly like a
    // normal run.
    if let catalog {
      let merged = Reconcile.merge(catalog, project: project, keys: [key])
      self.catalog = merged.catalog
      rebuildRecordIndex()
      buildRows()
      if merged.changed {
        markDirty()
      }
    }
  }

  /// Reviewed row: fold each reviewed slot's confirmed edit and show the
  /// ContextDoc before/after. Writes context docs only — never catalog values.
  private func inspectLearning(project: Project, records: [TranslationRecord]) async {
    let env = PipelineRunContext(
      context: TranslationStore.shared.context,
      project: project,
      targetKey: nil,
      targetLanguages: nil,
      force: false)
    for record in records {
      _ = await Stage0Learner.learnOne(env: env, record: record, trace: trace)
    }
    rebuildRecordIndex()
    buildRows()
  }

  private func performTranslate(project: Project, key: String? = nil, languages: Set<String>? = nil, force: Bool = false) async {
    let summary = await run.execute(
      project: project, key: key, languages: languages, force: force, catalog: catalog)
    defer { run.finish(summary) }
    // The run writes the DB only — its output reaches the artifact by merging
    // into the OPEN in-memory catalog, never by re-reading the file (which
    // predates every unsaved edit in this window, and is not written by
    // anything but Save).
    guard let catalog else { return }
    let merged = Reconcile.merge(catalog, project: project, keys: key.map { [$0] })
    self.catalog = merged.catalog
    rebuildRecordIndex()
    saveError = nil
    buildRows()
    if merged.changed {
      markDirty()
    }
  }

  /// Row-menu "Generate plural": AI-authors the SOURCE forms for a flat key,
  /// varies the source + selected columns, then runs the normal single-key
  /// Translate to fill the targets. Steps:
  ///   1. Vary by plural (skeleton; flat value -> "other", empty forms).
  ///   2. Ask the model for the missing source forms (existing ones are sent
  ///      for consistency and never overwritten); write them to the file.
  ///   3. Kick the forced single-key run over the selected columns.
  /// A no-key backend surfaces saveError and stops (the skeleton stays, so a
  /// retry costs nothing). Guarded by the shared run controller.
  func generatePlural(key: String) {
    guard catalog != nil, project != nil else { return }
    varyByPlural(key: key)
    guard let project else { return }
    let languages = Set(selectedLanguages)
    guard beginRun(project: project, key: key, languages: languages, force: true) else { return }
    Task { await performGeneratePlural(project: project, key: key, languages: languages) }
  }

  /// Async half of Generate plural: author source forms, then fill targets.
  /// Runs off-main (the model call is async); every store mutation hops back
  /// to the main actor, matching the rest of the store.
  private func performGeneratePlural(project: Project, key: String, languages: Set<String>) async {
    // Step 2: author the missing source forms before the stages run.
    if let catalog = self.catalog {
      let source = catalog.sourceLanguage
      let categories = PluralRules.categories(for: source)
      let flat = catalog.sourceDisplay(for: key)
      var existing: [String: String] = [:]
      var missing: [String] = []
      for category in categories {
        if let value = catalog.pluralValue(for: key, language: source, category: category),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          existing[category] = value
        } else {
          missing.append(category)
        }
      }
      if !missing.isEmpty {
        do {
          let forms = try await PluralGenerator.sourceForms(
            key: key,
            comment: catalog.strings[key]?.comment,
            text: missing.count == categories.count ? flat : (existing["other"] ?? flat),
            language: source,
            categories: categories,
            existing: existing)
          var mutated = catalog
          for category in missing {
            if let text = forms[category] {
              mutated.setSourcePluralValue(text, key: key, category: category)
            }
          }
          markDirty()
          await MainActor.run {
            self.catalog = mutated
            buildRows()
          }
        } catch {
          let message = error.localizedDescription
          await MainActor.run {
            self.saveError = message
            self.run.finish(PipelineRunSummary())
          }
          return
        }
      }
    }
    // Step 3: the forced single-key run fills the target forms.
    await performTranslate(project: project, key: key, languages: languages, force: true)
  }

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
    mirrorOpenCatalog(catalog, url: project.catalogURL)
  }

  /// Row-menu "Remove plural variations": collapses every plural slot of the
  /// key back to a flat stringUnit ("other" wins), drops the per-form
  /// records, then writes the artifact.
  func removePlurals(key: String) {
    guard var catalog, let project else { return }
    catalog.removePlurals(key: key)
    let context = TranslationStore.shared.context
    for record in project.records where record.key == key && record.category != nil {
      context.delete(record)
    }
    try? context.save()
    self.catalog = catalog
    saveError = nil
    markDirty()
    mirrorOpenCatalog(catalog, url: project.catalogURL)
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
      for record in project.records where record.key == key {
        context.delete(record)
      }
      try? context.save()
    }
    self.catalog = catalog
    saveError = nil
    markDirty()
    rebuildRecordIndex()
    mirrorOpenCatalog(catalog, url: project.catalogURL)
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

  // MARK: - imported-DB human confirm

  /// One-click human confirm of an auto-reviewed slot (the "auto" badge):
  /// the value is already .reviewed — this clears the auto marker so the
  /// record counts as human-reviewed (reviewedAt stamped, producer stamp
  /// kept) and upserts the TM gold entry, so any future catalog resolves
  /// the same (sourceText, language, target) as gold immediately — no need
  /// to wait for the next run's Stage 0. No-op unless the record really is
  /// auto-reviewed with a value.
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
    TranslationMemory.upsertReviewed(
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
  /// set). Value unchanged; no file write needed (the file already carries
  /// "translated" — the auto marker is DB-only provenance).
  func confirmAutoReviewed(key: String, language: String, category: String? = nil) {
    guard let project,
          let record = Reconcile.record(
            key: key, language: language, category: category, in: project)
    else { return }
    confirmAutoReviewed(record)
  }

  /// Row-scoped confirm: every auto-reviewed slot (flat + plural forms) of
  /// one key becomes human-reviewed in one click.
  func confirmAutoReviewedRow(_ key: String) {
    guard let project else { return }
    for record in project.records where record.key == key && record.autoReviewed {
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
    buildRows()
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
      buildRows()
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
      buildRows()
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
      buildRows()
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

  // MARK: - save (the only writer)

  /// Writes the open catalog back to its .xcstrings artifact. Save is the
  /// ONLY write path in the app: nothing saves implicitly — not a cell edit,
  /// not a Translate run, not the plural skeletons a run creates.
  func save() async {
    guard let catalog, let url = project?.catalogURL ?? catalogURL else { return }
    do {
      try await CatalogFileIO.write(catalog, to: url)
      saveError = nil
      isDirty = false
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
  /// Both halves run off the main actor — the decode, then the catalog's
  /// mirror into SwiftData — and the store is opened in ONE main-actor step
  /// afterwards, so the pane never shows a half-opened catalog (see
  /// `mirrorCatalog`).
  private func performOpen(_ url: URL) async {
    loadGeneration += 1
    let generation = loadGeneration
    CatalogFileIO.flush()
    // Off the main actor: a real detached decode, not the no-op
    // `MainActor.run` hop this used to be (see `loadOffMainActor`).
    let result = await StringCatalog.loadOffMainActor(url)
    // A newer open/reload supersedes this one — never adopt a stale parse.
    guard generation == loadGeneration else { return }
    await finishOpen(result, url: url, generation: generation)
  }

  /// Applies a still-current finished parse: success resets view state and
  /// reconciles; failure clears the open catalog. Main-actor side of `open`.
  private func finishOpen(
    _ result: Result<StringCatalog, Error>, url: URL, generation: Int
  ) async {
    switch result {
    case .success(let catalog):
      let project = await mirrorCatalog(catalog, url: url)
      // The mirror is seconds long on a large catalog: a newer open/reload may
      // have started and finished in the meantime, so re-check before this one
      // takes over the store.
      guard generation == loadGeneration else { return }
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
      adopt(catalog, project: project, url: url)
    case .failure(let error):
      catalog = nil
      catalogURL = nil
      recordIndex = [:]
      rows = []
      visibleRows = []
      isDirty = false
      pendingLeave = nil
      isUnsavedPromptPresented = false
      loadError = error.localizedDescription
    }
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
    isDirty = false
    pendingLeave = nil
    isUnsavedPromptPresented = false
    // Supersede any parse still in flight, so it cannot adopt state over a
    // closed store.
    loadGeneration += 1
    revision += 1
    run.reset()
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
    CatalogFileIO.flush()
    let result = await StringCatalog.loadOffMainActor(url)
    guard generation == loadGeneration else { return }
    switch result {
    case .success(let catalog):
      let project = await mirrorCatalog(catalog, url: url)
      guard generation == loadGeneration else { return }
      // View state is deliberately untouched by a reload.
      adopt(catalog, project: project, url: url)
    case .failure(let error):
      loadError = error.localizedDescription
    }
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
    buildRows()
    // The scan's merge preview is a diff against the catalog — keep it
    // current while its sheet is open.
    if scan.isPresented {
      scan.refreshPlan()
    }
  }

  /// True while a parsed catalog is being mirrored into the DB — the open /
  /// reload window, which for a large catalog is seconds long. Drives the
  /// panes' "Opening catalog…" state.
  private(set) var isReconciling = false

  /// Tail of the mirror chain. An open/reload that lands while an earlier
  /// mirror is still writing must not race it for the same records (the mirror
  /// used to be synchronous on the main actor, which made this ordering
  /// implicit) — each mirror awaits the previous one first.
  private var mirrorChain: Task<Void, Never> = Task {}

  /// Re-mirrors the OPEN catalog into the DB on the main actor and refreshes
  /// the derived rows — the per-key mutations' path (scan merge, plural
  /// vary/remove, don't-translate): one key's slots, cheap enough to run
  /// inline, unlike the whole-catalog `mirrorCatalog`.
  private func mirrorOpenCatalog(_ catalog: StringCatalog, url: URL) {
    let context = TranslationStore.shared.context
    // The open project owns this catalog; a URL that does not match it (a
    // stale caller) falls back to the find-or-create the mirror path uses.
    let project = (self.project?.catalogURL == url ? self.project : nil)
      ?? Reconcile.ensureProject(catalogURL: url, in: context)
    // The relationship is already materialized here (the open path faulted it
    // in), so passing it beats a fresh 0.6 s fetch — see upsertFromCatalog.
    _ = Reconcile.upsertFromCatalog(
      catalog, project: project, existing: project.records, context: context)
    try? context.save()
    self.project = project
    rebuildRecordIndex()
    buildRows()
    // The scan's merge preview is a diff against the catalog — keep it
    // current while its sheet is open.
    if scan.isPresented {
      scan.refreshPlan()
    }
  }

  /// Mirrors `catalog` into the project's records OFF the main actor and
  /// returns the project to hold in the MAIN context, or nil when the write
  /// failed.
  ///
  /// The upsert is the expensive half of opening a catalog (48,420 slots
  /// measured at ~6 s in Debug — see `Reconcile.mirrorOffMainActor`), so it
  /// runs in its own background `ModelContext`. Browsing never depends on the
  /// DB: a failed mirror still returns the project row so the pane opens with
  /// file-derived cells, and reports through `saveError`.
  private func mirrorCatalog(_ catalog: StringCatalog, url: URL) async -> Project? {
    isReconciling = true
    defer { isReconciling = false }
    let previous = mirrorChain
    let work = Task { () -> Result<Reconcile.MirrorResult, Error> in
      await previous.value
      return await Reconcile.mirrorOffMainActor(
        catalog, catalogURL: url, in: TranslationStore.container)
    }
    mirrorChain = Task { _ = await work.value }
    switch await work.value {
    case .success(let mirror):
      // The BACKGROUND context did the writing, so this context's copies of
      // those rows are stale — a fetch by identity refreshes them and hands
      // back the instance this store should hold.
      let context = TranslationStore.shared.context
      let project = Reconcile.project(id: mirror.projectID, in: context)
        ?? Reconcile.ensureProject(catalogURL: url, in: context)
      NSLog(
        "[Localization] reconciled %@: %d created, %d refreshed, %d kept",
        url.lastPathComponent, mirror.stats.created, mirror.stats.refreshed, mirror.stats.kept)
      return project
    case .failure(let error):
      saveError = "Couldn't save the catalog's records: \(error.localizedDescription)"
      return Reconcile.ensureProject(catalogURL: url, in: TranslationStore.shared.context)
    }
  }

  /// Re-indexes the project's live records by (key, language, form) for O(1)
  /// per-cell lookups. Runs after every upsert, so newly seeded slots
  /// (open/reload) are visible to the table immediately.
  private func rebuildRecordIndex() {
    guard let project else {
      recordIndex = [:]
      return
    }
    rebuildRecordIndex(from: project.records)
  }

  /// Same, from records the caller already holds. The OPEN path passes ONE
  /// scoped fetch (`Reconcile.records(of:in:)`) because its context is cold —
  /// iterating `project.records` there faults every row one at a time, which
  /// cost 4.2 s ON THE MAIN ACTOR for a 48,420-record catalog. Everything else
  /// (row-level mutations, a mirror that just wrote) passes the relationship,
  /// which is materialized by then and ~200x cheaper than a fresh fetch.
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

  /// Marks the open catalog as carrying edits the file does not have yet.
  /// Every catalog mutation funnels here instead of writing: the artifact is
  /// only written by `save()`, so an edit is durable in the DB (records) and
  /// pending on disk until the user saves.
  private func markDirty() {
    isDirty = true
  }

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
    guard let catalog else {
      rows = []
      visibleRows = []
      return
    }
    var built: [CatalogRow] = []
    built.reserveCapacity(catalog.strings.count)
    for (key, entry) in catalog.strings {
      built.append(makeRow(catalog: catalog, key: key, entry: entry))
    }
    rows = built
    recomputeVisibleRows()
  }

  private func makeRow(
    catalog: StringCatalog,
    key: String,
    entry: StringCatalog.Entry
  ) -> CatalogRow {
    let translatable = entry.shouldTranslate != false
    let rowHasPlurals = catalog.hasPlurals(for: key)
    // Cells for EVERY non-source language, selected or not — a language
    // column toggle only re-projects `visibleRows`, never re-derives rows.
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
    for language in catalog.languages where language != catalog.sourceLanguage {
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
      searchBlob: folded(searchBlobText(key: key, entry: entry)))
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
