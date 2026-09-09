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
  /// Display state of every selected non-source language column.
  let cells: [String: LangCell]
  /// True when at least one slot is filled and every filled slot (all
  /// languages, flat + plural forms) is reviewed.
  let isFullyReviewed: Bool
  /// True when at least one slot is filled and every filled slot is
  /// needs_review. Mixed and empty rows report false for both.
  let isFullyNeedsReview: Bool
  /// Pre-folded haystack for search (empty when search is inactive).
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

  /// True when the Translate button may start a run.
  var canTranslate: Bool { isLoaded && project != nil && !run.isRunning }

  /// Kicks the pipeline off from the Translate button (async Task; re-entry
  /// is guarded by `begin`). When the run returns, the DB is flushed back
  /// into the .xcstrings artifact and the updated catalog is adopted so the
  /// table shows the machine output without a reload.
  func startTranslate() {
    guard let project, run.begin(project: project) else { return }
    Task { await performTranslate(project: project, key: nil) }
  }

  /// Row-menu "Translate": runs the pipeline scoped to a single key AND only
  /// the currently-selected language columns (the visible sections), with the
  /// freshness gate lifted so even a fresh `needs_review` machine value is
  /// re-translated/reviewed. Reuses the shared run controller so the footer
  /// shows progress and re-entry is guarded. No columns selected => no
  /// targets (nothing is translated).
  func translateKey(_ key: String) {
    let languages = Set(selectedLanguages)
    guard let project, run.begin(project: project, key: key, languages: languages, force: true) else { return }
    Task { await performTranslate(project: project, key: key, languages: languages, force: true) }
  }

  private func performTranslate(project: Project, key: String? = nil, languages: Set<String>? = nil, force: Bool = false) async {
    let summary = await run.execute(project: project, key: key, languages: languages, force: force)
    defer { run.finish(summary) }
    // The pipeline's plural reconcile may have written new variation
    // skeletons straight to the file: re-read it (not the stale in-memory
    // copy) so commit sees the skeletons, then adopt + re-index.
    if let reloaded = try? StringCatalog.load(url: project.catalogURL) {
      catalog = reloaded
    }
    guard let catalog else { return }
    do {
      self.catalog = try Reconcile.commit(catalog, project: project)
      rebuildRecordIndex()
      saveError = nil
    } catch {
      saveError = error.localizedDescription
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
    guard run.begin(project: project, key: key, languages: languages, force: true) else { return }
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
          try mutated.save(to: project.catalogURL)
          await MainActor.run { self.catalog = mutated }
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
    do {
      try catalog.save(to: project.catalogURL)
      self.catalog = catalog
      saveError = nil
    } catch {
      saveError = error.localizedDescription
      return
    }
    reconcile(catalog, url: project.catalogURL)
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
    do {
      try catalog.save(to: project.catalogURL)
      self.catalog = catalog
      saveError = nil
    } catch {
      saveError = error.localizedDescription
      return
    }
    reconcile(catalog, url: project.catalogURL)
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
    do {
      try catalog.save(to: project.catalogURL)
      self.catalog = catalog
      saveError = nil
    } catch {
      saveError = error.localizedDescription
      return
    }
    rebuildRecordIndex()
    reconcile(catalog, url: project.catalogURL)
  }

  /// Marks a whole row (key) `reviewed` / `needs_review` across every filled
  /// language slot AND every filled plural form, then writes the state back
  /// to the artifact. Empty slots are left untouched.
  func setRowState(_ key: String, _ state: TranslationState) {
    guard let catalog, let project else { return }
    let context = TranslationStore.shared.context
    Reconcile.applyReviewState(key: key, state: state, project: project, context: context)
    do {
      self.catalog = try Reconcile.commit(catalog, project: project)
      saveError = nil
    } catch {
      saveError = error.localizedDescription
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
      do {
        try catalog.save(to: project.catalogURL)
        self.catalog = catalog
        saveError = nil
      } catch {
        saveError = error.localizedDescription
      }
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
      do {
        try catalog.save(to: project.catalogURL)
        self.catalog = catalog
        saveError = nil
      } catch {
        saveError = error.localizedDescription
      }
      return
    }
    do {
      let sourceText = catalog.sourcePluralDisplay(for: key, category: category)
      Reconcile.applyHumanEdit(
        key: key, language: language, value: trimmed,
        sourceText: sourceText, project: project, context: context,
        category: category)
      let updated = try Reconcile.commit(catalog, project: project)
      self.catalog = updated
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
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

  /// Re-indexes the project's live records by (key, language, form) for O(1)
  /// per-cell lookups. Runs after every upsert, so newly seeded slots
  /// (open/reload) are visible to the table immediately.
  private func rebuildRecordIndex() {
    guard let project else {
      recordIndex = [:]
      return
    }
    var index: [String: [String: [String: TranslationRecord]]] = [:]
    for record in project.records {
      index[record.key, default: [:]][record.language, default: [:]][record.category ?? ""] = record
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
    let rowHasPlurals = catalog.hasPlurals(for: key)
    var cells: [String: LangCell] = [:]
    for language in selectedLanguages {
      let loc = entry.localizations?[language]
      let plural = catalog.hasPlurals(for: key, language: language)
      let device = !plural && (loc?.variations?.isEmpty == false)
      if plural {
        // Plural cell: the form summary is the display text; per-form live
        // records drive the spinner, provenance and mid-run values.
        let forms = pluralRecords(for: key, language: language)
        let parsed = catalog.pluralUnits(for: key, language: language) != nil
        cells[language] = LangCell(
          text: pluralSummary(for: key, language: language),
          state: pluralAggregateState(for: key, language: language),
          hasParsed: parsed,
          hasOverride: false,
          hasVariations: true,
          hasPlurals: true,
          isEditable: translatable,
          record: nil,
          pluralRecords: forms)
        continue
      }
      let flatRecord = recordIndex[key]?[language]?[""]
      cells[language] = LangCell(
        text: valueOverrides[key]?[language] ?? loc?.stringUnit?.value ?? "",
        state: loc?.stringUnit?.state,
        hasParsed: loc?.stringUnit != nil,
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
    // Row review flags across ALL languages (not just visible columns), flat
    // + plural forms. A filled slot counts reviewed when its live record is
    // .reviewed (or the file says "translated"); needs_review when live
    // .needs_review (or the file says so). Draft overrides don't count.
    var filled = 0
    var reviewed = 0
    var needsReview = 0
    func tally(record: TranslationRecord?, fileValue: String?, fileState: String?) {
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
      if catalog.hasPlurals(for: key, language: language) {
        let units = catalog.pluralUnits(for: key, language: language)
        for category in PluralRules.categories(for: language) {
          tally(
            record: recordIndex[key]?[language]?[category],
            fileValue: units?[category]?.value,
            fileState: units?[category]?.state)
        }
        continue
      }
      let unit = entry.localizations?[language]?.stringUnit
      tally(
        record: recordIndex[key]?[language]?[""],
        fileValue: unit?.value,
        fileState: unit?.state)
    }
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
