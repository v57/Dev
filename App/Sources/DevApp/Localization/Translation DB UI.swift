//
//  Translation DB UI.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import ComponentKit
import SwiftUI

// MARK: - TranslationDBControl

/// Toolbar control for the app's imported translation database (Phase D): a
/// database glyph tinted green when a DB is imported; the popover shows the
/// file's basic info (row count, languages, top apps), per-catalog-language
/// coverage once the background scan lands, and the Import-replacement /
/// Remove actions. The DB itself is global (not per-project).
struct TranslationDBControl: View {
  let store: LocalizationStore

  @State private var showingInfo = false

  var body: some View {
    let db = ImportedTranslationDB.shared
    Button {
      showingInfo = true
    } label: {
      Label("Translation DB", systemImage: "cylinder.split.1x2")
        .foregroundStyle(db.isImported ? AnyShapeStyle(Hue.green.text) : AnyShapeStyle(.kitLabel))
        .symbolVariant(db.isImported ? .fill : .none)
    }
    .kitHelp(
      "Translation DB",
      meta: db.isImported
        ? "Imported translation DB: \(db.fileURL?.lastPathComponent ?? "—"). Click for info, import or remove."
        : "No translation DB imported — translations come from the AI pipeline. Click to import one.",
      systemImage: "cylinder.split.1x2", hue: db.isImported ? .green : .accent)
    .kitPopover(isPresented: $showingInfo) {
      ImportedDBInfoView(store: store)
    }
  }
}

// MARK: - ImportedDBInfoView

/// The imported-DB popover: file identity, aggregate stats (background
/// scan), coverage of the CURRENT catalog's languages, and import/remove.
private struct ImportedDBInfoView: View {
  let store: LocalizationStore
  /// A run resolves slots from the imported DB, so it is not swapped out mid-run.
  @Environment(Translation.Shell.self) private var shell

  var body: some View {
    let db = ImportedTranslationDB.shared
    VStack(alignment: .leading, spacing: 12) {
      header(db: db)
      if db.isImported {
        Divider()
        statsSection(db: db)
        Divider()
        actionsRow(db: db)
      } else {
        emptyPrompt
      }
      if let error = db.errorMessage {
        Text(error)
          .kitFont(.caption)
          .foregroundStyle(Hue.red.text)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 340)
    .task {
      // Restore the remembered path (first launch after import) and kick the
      // background stats scan when no stats are cached yet.
      db.restoreIfNeeded()
      db.ensureStats()
    }
  }

  // MARK: header

  @ViewBuilder
  private func header(db: ImportedTranslationDB) -> some View {
    RichHeader(
      db.isImported ? (db.fileURL?.lastPathComponent ?? String(localized: "Translation DB")) : String(localized: "Translation DB"),
      meta: db.isImported ? [metaLine(db: db)] : [],
      systemImage: "cylinder.split.1x2", hue: db.isImported ? .green : .gray,
      status: db.isScanning ? .working : .idle)
  }

  private func metaLine(db: ImportedTranslationDB) -> String {
    var parts: [String] = []
    if let size = db.fileSize {
      parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }
    if !db.fileExists {
      parts.append(String(localized: "file missing"))
    }
    if parts.isEmpty {
      parts.append(db.fileURL?.path ?? "")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: empty state

  private var emptyPrompt: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No translation database imported.")
        .kitFont(.callout)
      Text("Import a sqlite file with a translations (language, source, target, app) table — e.g. the Localization scanner output. The pipeline then checks it BEFORE the AI backends; matching translations are applied as automatically-reviewed and stay one click away from human confirmation.")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Import Database…", systemImage: "cylinder.split.1x2") {
        Task { await ImportedTranslationDB.shared.importViaPanel() }
      }
      .buttonStyle(.kitPrimary)
      .controlSize(.small)
    }
  }

  // MARK: stats

  @ViewBuilder
  private func statsSection(db: ImportedTranslationDB) -> some View {
    if let stats = db.stats {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: [
          String(localized: "\(stats.totalRows) translations"), String(localized: "\(stats.languages.count) language codes"),
          String(localized: "\(stats.apps.count) apps"),
        ].joined(separator: " · "))
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
        if store.isLoaded {
          coverageGrid(db: db, stats: stats)
        }
        topApps(stats: stats)
      }
    } else if db.isScanning {
      HStack(spacing: 6) {
        LiveIcon(systemImage: "magnifyingglass", hue: .gray, status: .working, size: 16)
        Text("Scanning translations…")
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
      }
    } else if let scanError = db.scanError {
      Text("Stats unavailable: \(scanError)")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text("Stats not computed yet.")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
    }
  }

  /// Per-language row counts for the CURRENT catalog's languages (only
  /// languages with rows are shown) — the "can this DB help this catalog"
  /// answer at a glance.
  @ViewBuilder
  private func coverageGrid(db: ImportedTranslationDB, stats: ImportedDBStats) -> some View {
    let covered = store.pickerLanguages.compactMap { language -> (String, Int64)? in
      let rows = stats.rows(forCatalogLanguage: language)
      return rows > 0 ? (language, rows) : nil
    }
    if !covered.isEmpty {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], spacing: 2) {
        ForEach(covered, id: \.0) { language, rows in
          Text("\(language): \(rows.formatted(.number.notation(.compactName)))")
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
            .lineLimit(1)
            .help("\(language): \(rows) translations in the imported DB")
        }
      }
    }
  }

  private func topApps(stats: ImportedDBStats) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Top sources")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
      ForEach(stats.topApps.prefix(5), id: \.app) { app, rows in
        HStack(spacing: 6) {
          Text(app)
            .kitFont(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Text(rows.formatted(.number.notation(.compactName)))
            .kitFont(.caption)
            .foregroundStyle(.kitTertiary)
        }
      }
    }
  }

  // MARK: actions

  @ViewBuilder
  private func actionsRow(db: ImportedTranslationDB) -> some View {
    HStack {
      Button("Replace…") {
        Task { await db.importViaPanel() }
      }
      .disabled(shell.isRunning)
      Button("Remove", role: .destructive) {
        db.remove()
      }
      .disabled(shell.isRunning)
      Spacer()
    }
    .buttonStyle(.kit)
    .controlSize(.small)
  }
}
