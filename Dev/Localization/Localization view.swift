//
//  Localization view.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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

/// Detail tool over the shared LocalizationStore (owned + injected by
/// ContentView, so the sidebar's projectless bottom-bar row and this tool
/// read the SAME open catalog).
///
/// Two modes:
///  - PROJECTLESS (projectCatalogURL == nil): arbitrary open — the app's
///    original behavior; auto-opens the dev fixture when nothing is loaded.
///  - PROJECT-BOUND (P40, projectCatalogURL set): the pane belongs to a
///    selected sidebar project. It renders content ONLY while the store
///    holds THAT project's catalog — a different open catalog is never
///    shown under the project's name, and no arbitrary Open… is offered
///    (opening another file would re-target reconcile away from the
///    selected project). ProjectDetailView opens the catalog on selection;
///    when the file is absent this view shows the 'no catalog' state.
struct LocalizationView: View {
  @Environment(LocalizationStore.self) private var store

  /// The catalog of the selected project this instance is bound to, or nil
  /// for the projectless tool. Read from the shared sidebar view-model's
  /// row snapshot by the caller — never tracked here.
  var projectCatalogURL: URL?

  var body: some View {
    Group {
      if store.isReconciling {
        // A catalog is being parsed/mirrored into the DB. For a large one that
        // is seconds of work, so it gets a state of its own rather than
        // flashing the empty state or a half-opened table.
        ProgressView("Opening catalog…")
      } else if let url = projectCatalogURL {
        boundContent(url: url)
      } else if store.isLoaded {
        loadedContent(allowsOpenCatalog: true)
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The projectless auto-open (dev fixture) must never fire while bound —
    // a bound pane only ever opens its project's catalog, which
    // ProjectDetailView drives on selection. The id makes the bound/
    // projectless flip re-evaluate the guard.
    .task(id: projectCatalogURL) {
      guard projectCatalogURL == nil else { return }
      await store.openDefaultIfPresent()
    }
    .alert(store.errorTitle, isPresented: errorBinding) {
      Button("OK") { store.dismissError() }
    } message: {
      Text(store.errorMessage ?? "")
    }
    // Single-row diagnostic overlay (row menu "Inspect Row…").
    .sheet(isPresented: Binding(
      get: { store.inspectedKey != nil },
      set: { if !$0 { store.closeInspector() } }
    )) {
      RowInspectorView(store: store)
    }
    // Scan Strings report (toolbar "Scan Strings").
    .sheet(isPresented: Binding(
      get: { store.scan.isPresented },
      set: { if !$0 { store.scan.dismiss() } }
    )) {
      ScanStringsView(store: store)
    }
    // Reviewer note editor (row menu "Note…").
    .sheet(isPresented: Binding(
      get: { store.noteKey != nil },
      set: { if !$0 { store.closeNote() } }
    )) {
      NoteEditorView(store: store)
    }
    // Project context rules (toolbar "Context Rules…").
    .sheet(isPresented: Binding(
      get: { store.contextDocsOpen },
      set: { if !$0 { store.closeContextDocs() } }
    )) {
      ContextDocsView(store: store)
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.hasError },
      set: { if !$0 { store.dismissError() } })
  }

  /// Bound pane: full table while the store holds the project's catalog;
  /// a brief opening state (the binding open lands right after this frame)
  /// or a permanent 'no catalog' state when the file is absent.
  @ViewBuilder
  private func boundContent(url: URL) -> some View {
    if store.isLoaded, store.catalogURL == url {
      loadedContent(allowsOpenCatalog: false)
    } else if FileManager.default.fileExists(atPath: url.path) {
      if store.hasError {
        ContentUnavailableView(
          "Couldn't open catalog",
          systemImage: "exclamationmark.triangle",
          description: Text("The project catalog failed to open."))
      } else {
        ProgressView("Opening catalog…")
      }
    } else {
      noCatalogState(url: url)
    }
  }

  /// 'No catalog' for a bound project without a Localizable.xcstrings yet:
  /// nothing to open, so the pane explains instead of offering an arbitrary
  /// file (which would reconcile into a DIFFERENT project).
  private func noCatalogState(url: URL) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 44))
        .foregroundStyle(.tertiary)
      Text("No catalog")
        .font(.title3)
      VStack(spacing: 4) {
        Text("This project has no Localizable.xcstrings yet.")
          .foregroundStyle(.secondary)
        Text(url.path)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(20)
  }

  private func loadedContent(allowsOpenCatalog: Bool) -> some View {
    @Bindable var store = store
    return VStack(spacing: 0) {
      CatalogTable(store: store)
        .searchable(text: $store.searchText,
                    prompt: "Search keys, comments, translations")
        .safeAreaBar(edge: .top) {
          LanguageButtonsRow(store: store)
        }
        .safeAreaBar(edge: .bottom) {
          FooterBar(store: store)
        }
    }
    .toolbar {
      ControlsBar(store: store, allowsOpenCatalog: allowsOpenCatalog)
    }
    // Update Translations: the paid sweep always asks first, with the pre-run
    // count in the message. Attached here (not on the outer Group) so it
    // cannot collide with the load/save error alert.
    .alert("Update Translations", isPresented: Binding(
      get: { store.updateConfirmationPresented },
      set: { if !$0 { store.cancelUpdateTranslations() } }
    )) {
      Button("Cancel", role: .cancel) { store.cancelUpdateTranslations() }
      Button("Run Update") { store.confirmUpdateTranslations() }
    } message: {
      Text(store.updateConfirmationMessage)
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
        SourceCell(store: store, row: row)
      }
      .width(min: 160, ideal: 300, max: 300)

      if store.showLongest {
        TableColumn("Longest", sortUsing: CatalogSort(.longest)) { row in
          LongestCell(store: store, row: row)
        }
        .width(min: 140, ideal: 300, max: 300)
      }

      TableColumnForEach(store.selectedLanguages, id: \.self) { language in
        TableColumn(language, sortUsing: CatalogSort(.language(language))) { row in
          LanguageCell(store: store, row: row, language: language)
        }
        .width(min: 120, ideal: 240, max: 300)
      }
    }
  }

}

// MARK: - Row cells

/// Source column cell: the source text with its plural-form summary and,
/// when opted in, the comment line under it. The row context menu applies
/// to the whole column area.
private struct SourceCell: View {
  let store: LocalizationStore
  let row: CatalogRow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.sourceText)
        .lineLimit(3)
        .help(row.sourceText)
      if row.hasPlurals, !row.sourcePluralSummary.isEmpty {
        Text(row.sourcePluralSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .help("Plural forms — \(row.sourcePluralSummary)")
      }
      if store.showComments, !row.commentText.isEmpty {
        Text(row.commentText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .help(row.commentText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu { RowContextMenu(row: row, store: store) }
  }
}

/// Longest column cell: the length-leading text (plus the not-translatable
/// glyph), with a tooltip naming the language and length.
private struct LongestCell: View {
  let store: LocalizationStore
  let row: CatalogRow

  var body: some View {
    HStack(spacing: 5) {
      if !row.isTranslatable {
        Image(systemName: "nosign")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .help("Not translatable")
      }
      Text(row.longestText)
        .lineLimit(3)
        .help(tooltip)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu { RowContextMenu(row: row, store: store) }
  }

  private var tooltip: String {
    if row.longestLanguage.isEmpty {
      return row.longestText
    }
    return "\(row.longestLanguage) · \(row.longestLength) chars\n\(row.longestText)"
  }
}

/// One non-source language column cell: status accessory + editor, or the
/// read-only device-variations placeholder. Missing rows fall back to an
/// empty editable cell.
private struct LanguageCell: View {
  let store: LocalizationStore
  let row: CatalogRow
  let language: String

  var body: some View {
    let cell = row.cells[language] ?? LangCell(
      text: "", state: nil, hasParsed: false, hasOverride: false,
      hasVariations: false, hasPlurals: false,
      isEditable: row.isTranslatable, record: nil, pluralRecords: [:])
    return HStack(spacing: 5) {
      if cell.hasPlurals {
        PluralCellStatusAccessory(cell: cell, run: store.run)
        if cell.pluralRecords.values.contains(where: { $0.lastEditor == ProvenanceMarkers.translationMemory }) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .help("A form was resolved from translation memory")
        }
        PluralEditCell(store: store, rowKey: row.key, language: language, cell: cell)
      } else if cell.hasVariations {
        Text(cell.text)
          .lineLimit(3)
        Image(systemName: "ellipsis.curlybraces")
          .foregroundStyle(.tertiary)
          .help("Device variations present — read-only in this phase")
      } else {
        CellStatusAccessory(
          record: cell.record,
          isInFlight: store.run.isInFlight(cell.record))
        if let record = cell.record,
           record.lastEditor == ProvenanceMarkers.translationMemory {
          TranslationMemoryBadge(record: record)
        }
        if let record = cell.record, record.autoReviewed {
          AutoReviewedBadge {
            store.confirmAutoReviewed(key: row.key, language: language)
          }
        }
        if let limit = row.maxWidth, cell.isOverWidth(limit) {
          WidthBadge(
            chars: cell.longestValueCharacters, limit: limit,
            sourceChars: row.sourceText.count)
        }
        LanguageEditCell(
          store: store, rowKey: row.key, language: language,
          cell: cell, record: cell.record)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu { RowContextMenu(row: row, store: store) }
  }
}

// MARK: - Row context menu

/// Right-click menu for a row: Translate (single item) / Vary by plural /
/// Reviewed / Needs Review. Translate is disabled while a run is active
/// and for non-translatable keys; the review/plural actions are hidden for
/// them (they hold no records).
private struct RowContextMenu: View {
  let row: CatalogRow
  let store: LocalizationStore

  var body: some View {
    Button {
      store.inspect(row.key)
    } label: {
      Label("Inspect Row…", systemImage: "magnifyingglass.circle")
    }
    .disabled(store.run.isActive || store.isInspecting)
    .help("Run one row end to end and show which model was used and what was learned")

    Button {
      store.editNote(row.key)
    } label: {
      Label("Note…", systemImage: "text.bubble")
    }
    .disabled(store.run.isActive)
    .help("Attach a reviewer note to this row — a project rule guides the translator, a plain note stays in the app")

    Menu {
      ForEach([nil, 6, 8, 12, 16, 32] as [Int?], id: \.self) { option in
        Button {
          store.setMaxWidth(key: row.key, width: option)
        } label: {
          if row.maxWidth == option {
            Label(option.map { "\($0) chars" } ?? "None", systemImage: "checkmark")
          } else {
            Text(option.map { "\($0) chars" } ?? "None")
          }
        }
      }
    } label: {
      Label("Max Width", systemImage: "arrow.left.and.right")
    }
    .help("Guideline for the rendered width of this row's text. It is never sent to the translator — over-width values are flagged here for you, and the reviewer may shorten one")

    Divider()

    Button {
      store.translateKey(row.key)
    } label: {
      Label("Translate", systemImage: "translate")
    }
    .disabled(!row.isTranslatable || store.run.isActive)

    if row.isTranslatable {
      if row.hasPlurals {
        Button {
          store.generatePlural(key: row.key)
        } label: {
          Label("Generate plural", systemImage: "sparkles")
        }
        .disabled(store.run.isActive)
        Button {
          store.removePlurals(key: row.key)
        } label: {
          Label("Remove plural variations", systemImage: "ellipsis.curlybraces")
        }
        .disabled(store.run.isActive)
      } else {
        Button {
          store.varyByPlural(key: row.key)
        } label: {
          Label("Vary by plural", systemImage: "ellipsis.curlybraces")
        }
        .disabled(store.run.isActive)
        Button {
          store.generatePlural(key: row.key)
        } label: {
          Label("Generate plural", systemImage: "sparkles")
        }
        .disabled(store.run.isActive)
      }
      // One-click human confirm for every imported-DB auto-reviewed slot of
      // the row (badge click does the same per cell).
      if rowHasAutoReviewed {
        Button {
          store.confirmAutoReviewedRow(row.key)
        } label: {
          Label("Confirm Auto-Reviewed", systemImage: "checkmark.seal")
        }
      }
      Divider()
      // Reviewed shows only when the row is NOT fully reviewed; Needs Review
      // only when it is NOT fully needs_review. Mixed/half rows offer both,
      // empty rows offer neither (setRowState skips empty slots anyway).
      if !row.isFullyReviewed {
        Button {
          store.setRowState(row.key, .reviewed)
        } label: {
          Label("Reviewed", systemImage: "checkmark.circle")
        }
      }
      if !row.isFullyNeedsReview {
        Button {
          store.setRowState(row.key, .needs_review)
        } label: {
          Label("Needs Review", systemImage: "exclamationmark.circle")
        }
      }
      Divider()
      if row.isTranslatable {
        Button {
          store.setTranslatable(key: row.key, false)
        } label: {
          Label("Don't translate", systemImage: "nosign")
        }
      } else {
        Button {
          store.setTranslatable(key: row.key, true)
        } label: {
          Label("Needs translate", systemImage: "translate")
        }
      }
    } else {
      Divider()
      Button {
        store.setTranslatable(key: row.key, true)
      } label: {
        Label("Needs translate", systemImage: "translate")
      }
    }
  }

  /// True when any slot of the row (flat cells or plural forms) carries an
  /// imported-DB auto-reviewed value — offers the Confirm action.
  private var rowHasAutoReviewed: Bool {
    row.cells.values.contains { cell in
      if cell.record?.autoReviewed == true { return true }
      return cell.pluralRecords.values.contains { $0.autoReviewed }
    }
  }
}
/// Advisory marker: this value is longer than the row's max-width guideline.
/// It never changes state and never blocks "Reviewed" — the reviewer decides
/// whether to rephrase, abbreviate, or accept it as it is.
private struct WidthBadge: View {
  let chars: Int
  let limit: Int
  /// Length of the source text, when the caller knows it (0 = unknown).
  var sourceChars: Int = 0

  var body: some View {
    Image(systemName: "arrow.left.and.right")
      .font(.system(size: 9))
      .foregroundStyle(.orange)
      .help(sourceChars > 0
        ? "\(chars) chars — over the \(limit)-char limit (source \(sourceChars))"
        : "\(chars) chars — over the \(limit)-char limit")
  }
}

/// Row note editor (row menu "Note…"): the note text plus what it should do.
/// A project-scoped note becomes a rule in the project ContextDoc, which the
/// translator follows; a memo stays in the app. Nothing here writes a catalog
/// file — a note is app-local metadata, and Save is still the only catalog
/// writer.
private struct NoteEditorView: View {
  let store: LocalizationStore
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""
  @State private var scope: Reconcile.NoteScope = .project
  @State private var initialized = false

  private var key: String { store.noteKey ?? "" }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "text.bubble")
        Text(key)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      Text("A project rule is sent to the translator with every request for this project. A plain note is for you only.")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextEditor(text: $text)
        .font(.body)
        .frame(minHeight: 110)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

      Picker("", selection: $scope) {
        ForEach(Reconcile.NoteScope.allCases, id: \.self) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()

      if !store.projectContextText.isEmpty {
        DisclosureGroup("Project context now (\(store.projectContextText.count) chars)") {
          ScrollView {
            Text(store.projectContextText)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: 110)
        }
        .font(.caption)
      }

      HStack {
        Button("Remove Note", role: .destructive) {
          store.setNote(key: key, note: "", scope: scope)
          dismiss()
        }
        .disabled(text.isEmpty && store.note(for: key).text.isEmpty)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          store.setNote(key: key, note: text, scope: scope)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 540)
    .onAppear {
      guard !initialized else { return }
      let existing = store.note(for: key)
      text = existing.text
      scope = existing.scope
      initialized = true
    }
  }
}

/// Human editor for the project's context document — the rule set the
/// translator follows, and the place a rule is retracted by hand (delete its
/// line). Saving writes a ContextEdit audit and exactly one version bump; the
/// project version does not auto-enqueue re-runs, so nothing re-translates
/// until "Update Translations" (or the next whole-catalog run) is asked to.
private struct ContextDocsView: View {
  let store: LocalizationStore
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""
  @State private var initialized = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "text.book.closed")
        Text("Project Context")
          .font(.headline)
        Spacer(minLength: 0)
        Text("\(text.count) chars")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text("One rule per line. Sent with every translation request for this project, and followed over the model's own defaults (prompt rule 4).")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(minHeight: 320)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          store.setProjectContext(text)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 640)
    .onAppear {
      guard !initialized else { return }
      text = store.projectContextText
      initialized = true
    }
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

/// Plural slot status: spinner while ANY form is in flight, else the worst
/// form dot (needs_review orange wins, then reviewed green, else none).
private struct PluralCellStatusAccessory: View {
  let cell: LangCell
  let run: TranslateRunController

  var body: some View {
    if cell.isInFlight(run: run) {
      ProgressView()
        .controlSize(.small)
        .help("Translating…")
    } else {
      let dot: TranslationState? = cell.pluralRecords.values
        .map(\.state)
        .sorted { rank($0) < rank($1) }
        .first { $0 != .empty }
      if let dot, dot != .empty {
        Circle()
          .fill(dot.dotColor)
          .frame(width: 6, height: 6)
          .help(pluralHelp)
      }
    }
  }

  private func rank(_ state: TranslationState) -> Int {
    switch state {
    case .needs_review: return 0
    case .reviewed: return 1
    case .empty: return 2
    }
  }

  private var pluralHelp: String {
    let lines = cell.pluralRecords
      .sorted { $0.key < $1.key }
      .map { category, record in
        let state = record.state == .empty ? "empty" : record.state.displayName
        let editor = record.lastEditor.map { " — \($0)" } ?? ""
        return "\(category): \(state)\(editor)"
      }
    return (["Plural forms"] + lines).joined(separator: "\n")
  }
}

/// Plural forms editor: one row per CLDR category (source form as reference,
/// per-form value + state dot + provenance tooltip). The target forms edit
/// inline (commit on focus loss, Escape cancels); the source language column
/// is skipped (source edits live in the source column's own cell). Shown as a
/// popover from the plural cell.
private struct PluralFormsEditor: View {
  let store: LocalizationStore
  let rowKey: String
  let language: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(rowKey) — \(language)")
        .font(.headline)
        .lineLimit(1)
      ForEach(PluralRules.categories(for: language), id: \.self) { category in
        PluralFormRow(store: store, rowKey: rowKey, language: language, category: category)
      }
    }
    .padding(12)
    .frame(minWidth: 320, maxWidth: 480)
  }
}

private struct PluralFormRow: View {
  let store: LocalizationStore
  let rowKey: String
  let language: String
  let category: String

  @State private var draft: String = ""
  @State private var isEditing = false
  @State private var initializedRevision = -1
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        if let record = formRecord, record.state != .empty {
          Circle()
            .fill(record.state.dotColor)
            .frame(width: 6, height: 6)
        }
        if let record = formRecord, record.autoReviewed {
          AutoReviewedBadge {
            store.confirmAutoReviewed(
              key: rowKey, language: language, category: category)
          }
        }
        if let limit = store.maxWidth(for: rowKey),
           let value = formRecord?.value, !value.isBlankOrEmpty,
           value.count > limit {
          WidthBadge(chars: value.count, limit: limit)
        }
        Text(PluralRules.displayName(for: category))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let record = formRecord,
           let provenance = record.provenanceSummary {
          Text(provenance.components(separatedBy: "\n").first ?? "")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      Text(sourceReference)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
      if isEditing {
        TextEditor(text: $draft)
          .font(.body)
          .focused($focused)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 44)
          .onAppear { focused = true }
          .onExitCommand { cancel() }
          .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
          }
      } else {
        Group {
          if liveText.isEmpty {
            Text("missing — click to add")
              .foregroundStyle(.tertiary)
          } else {
            Text(liveText)
              .lineLimit(3)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(fullHelp)
        .onTapGesture {
          draft = liveText
          isEditing = true
        }
      }
    }
    .onAppear {
      draft = liveText
      initializedRevision = store.revision
    }
    .onChange(of: store.revision) { _, revision in
      if revision != initializedRevision {
        draft = liveText
        initializedRevision = revision
        isEditing = false
      }
    }
    .onChange(of: liveText) { _, newText in
      if !isEditing && !focused {
        draft = newText
      }
    }
  }

  private var liveText: String {
    store.pluralValue(for: rowKey, language: language, category: category)
  }

  private var formRecord: TranslationRecord? {
    store.pluralRecords(for: rowKey, language: language)[category]
  }

  private var sourceReference: String {
    store.sourcePluralReference(for: rowKey, category: category)
  }

  private var fullHelp: String {
    if let record = formRecord, let provenance = record.provenanceSummary {
      return "\(sourceReference)\n---\n\(provenance)"
    }
    return liveText.isEmpty ? "Missing — click to add" : "\(sourceReference)\n---\n\(liveText)"
  }

  private func commit() {
    store.setPluralValue(draft, for: rowKey, language: language, category: category)
    draft = liveText
    isEditing = false
  }

  private func cancel() {
    draft = liveText
    isEditing = false
  }
}

/// Plural language cell: read-only form summary until clicked, then the
/// per-form popover editor. Live record values flow in mid-run like the flat
/// cell; the popover commits per form on focus loss.
private struct PluralEditCell: View {
  let store: LocalizationStore
  let rowKey: String
  let language: String
  let cell: LangCell

  @State private var showingEditor = false

  var body: some View {
    Group {
      if liveSummary.isEmpty {
        Text("missing")
          .foregroundStyle(.tertiary)
      } else {
        Text(liveSummary)
          .lineLimit(3)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(helpText)
    .onTapGesture {
      guard cell.isEditable else { return }
      showingEditor = true
    }
    .popover(isPresented: $showingEditor) {
      PluralFormsEditor(store: store, rowKey: rowKey, language: language)
    }
  }

  /// Live summary: per-form record values win mid-run, else the parsed file.
  private var liveSummary: String {
    store.pluralSummary(for: rowKey, language: language)
  }

  private var helpText: String {
    let lines = PluralRules.categories(for: language).map { category in
      let value = store.pluralValue(for: rowKey, language: language, category: category)
      let record = store.pluralRecords(for: rowKey, language: language)[category]
      let marker: String
      if let record, record.state != .empty {
        marker = record.state == .reviewed ? "✓" : "!"
      } else {
        marker = value.isEmpty ? "·" : "?"
      }
      return "\(marker) \(category): \(value.isEmpty ? "missing" : value)"
    }
    return (["Plural forms — click to edit"] + lines).joined(separator: "\n")
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
    .environment(LocalizationStore())
    .frame(width: 1100, height: 600)
}
