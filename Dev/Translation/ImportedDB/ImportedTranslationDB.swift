//
//  ImportedTranslationDB.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import AppKit
import Foundation
import Observation
import SQLite
import UniformTypeIdentifiers

// MARK: - ImportedDBStats

/// Aggregate facts about an imported translation DB, computed once per
/// import (a full scan of the file — a 3.6 GB database takes a while, so
/// the work runs off the main thread and the UI shows the spinner until it
/// lands). `nonisolated`: built by the background scan.
nonisolated struct ImportedDBStats: Equatable, Sendable {
  /// Total translation rows.
  var totalRows: Int64
  /// Rows per raw db language code (code as stored, e.g. "pt_PT").
  var languages: [String: Int64]
  /// Rows per owning app.
  var apps: [String: Int64]
  /// When the scan finished.
  var scannedAt: Date

  /// Rows for a catalog language across every matching spelling.
  func rows(forCatalogLanguage code: String) -> Int64 {
    ImportedDBLanguage.candidates(for: code).reduce(0) { sum, spelling in
      sum + (languages[spelling] ?? 0)
    }
  }

  /// The apps carrying the most translations, best first.
  var topApps: [(app: String, rows: Int64)] {
    apps.map { (app: $0.key, rows: $0.value) }
      .sorted { $0.rows > $1.rows || ($0.rows == $1.rows && $0.app < $1.app) }
  }
}

// MARK: - ImportedTranslationDB

/// The app's ONE imported translation database (Phase D decision: global, not
/// per-project; importing replaces the previous). Wraps a read-only SQLite
/// connection to the remembered file and answers exact source-text lookups
/// for the pipeline's imported-DB resolve stage.
///
/// - Import: NSOpenPanel -> schema probe (must carry a `translations`
///   language/source/target/app table) -> path persisted (app sandbox off:
///   a plain path survives launches; the 3.6 GB file is NEVER copied).
/// - Stats: computed in the background once per import/open; cached. The UI
///   reads `stats`/`isScanning`; the pipeline reads rows via `rows(forSource:)`.
/// - The connection is opened lazily and kept for the process lifetime;
///   lookups are bound-parameter exact text matches (never interpolated).
@MainActor
@Observable
final class ImportedTranslationDB {
  /// Process-lifetime singleton (mirrors TranslationStore/run patterns).
  static let shared = ImportedTranslationDB()

  /// UserDefaults key for the remembered import path.
  private static let pathKey = "importedTranslationDBPath"

  // MARK: - state

  /// The imported file, nil when none is active.
  private(set) var fileURL: URL?
  /// When the current file was imported (restored imports keep the first
  /// session's date — it is not refreshed on launch).
  private(set) var importedAt: Date?
  /// Parsed catalog languages -> matching raw row count, once scanned.
  private(set) var stats: ImportedDBStats?
  /// True while the background stats scan is running.
  private(set) var isScanning = false
  /// Last operation error (import probe / open / scan), UI-readable.
  private(set) var errorMessage: String?
  /// True when the remembered file exists on disk (false = stale path).
  private(set) var fileExists = false

  private var connection: SQLiteConnection?
  private var scanGeneration = 0

  // MARK: - derived state

  var isImported: Bool { fileURL != nil }
  var isConnected: Bool { connection?.isConnected == true }
  var fileSize: Int64? {
    guard let fileURL,
          let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    else { return nil }
    return (attrs[.size] as? NSNumber)?.int64Value
  }

  private init() {}

  // MARK: - lifecycle (remembered path)

  /// Restores the remembered import path, if any, WITHOUT opening or scanning
  /// (cheap — call from the UI on first appearance so the toolbar control
  /// knows a DB is active).
  func restoreIfNeeded() {
    guard fileURL == nil, let path = UserDefaults.standard.string(forKey: Self.pathKey) else {
      return
    }
    let url = URL(fileURLWithPath: path)
    fileURL = url
    importedAt = nil
    fileExists = FileManager.default.fileExists(atPath: url.path)
  }

  /// Ensures the active file is open for lookups (idempotent). Called by the
  /// pipeline before the resolve stage and by the UI before info reads.
  func ensureOpen() async throws {
    guard let fileURL else { return }
    if connection?.isConnected == true { return }
    let config = SQLiteConnectionConfig(
      name: fileURL.lastPathComponent,
      filePath: fileURL.path)
    let opened = SQLiteConnection(config: config)
    do {
      try await opened.connect()
      try await Self.validateSchema(opened)
      connection = opened
    } catch {
      await opened.disconnect()
      throw error
    }
  }

  /// Validates the file carries the expected translations table. Throws a
  /// UI-readable error otherwise.
  private static func validateSchema(_ connection: SQLiteConnection) async throws {
    let rows = try await connection.select(
      sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'translations'",
      limit: 1)
    guard !rows.isEmpty else {
      throw SQLiteError.notADatabase(
        "Not a translation database — missing the 'translations' table")
    }
    // Read the `name` column BY KEY. SQLiteRowData keeps cells in an
    // UNORDERED dictionary, so scanning `.values` for the first string could
    // return the column's TYPE ("TEXT") instead of its name depending on the
    // process's hash seed — the check then rejected a valid file on roughly
    // half of all launches (and on restore after relaunch), so the remembered
    // import looked lost. Key lookup is deterministic.
    let columns = try await connection.select(sql: "PRAGMA table_info(translations)")
    let names = Set(columns.compactMap { row -> String? in
      guard case .string(let name)? = row["name"] else { return nil }
      return name
    })
    guard names.isSuperset(of: ["language", "source", "target", "app"]) else {
      throw SQLiteError.notADatabase(
        "Not a translation database — the 'translations' table must have language, source, target and app columns")
    }
  }

  // MARK: - import / remove

  /// Runs the import picker (main-actor NSOpenPanel, like the catalog Open).
  /// Replaces the previous import on success; errors surface through
  /// `errorMessage` (shown by the calling view).
  func importViaPanel() async {
    let panel = NSOpenPanel()
    panel.title = "Import Translation Database"
    panel.message = "Choose a sqlite file with a translations (language, source, target, app) table"
    panel.prompt = "Import"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.data]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try await setImported(url)
    } catch {
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  /// Adopts a file as the active imported DB: remembers the path, opens the
  /// connection, starts the background stats scan.
  func setImported(_ url: URL) async throws {
    let standardized = url.standardizedFileURL
    // Probe BEFORE adopting anything: a bad file must leave the current
    // import untouched.
    let probe = SQLiteConnection(
      config: SQLiteConnectionConfig(name: standardized.lastPathComponent, filePath: standardized.path))
    try await probe.connect()
    try await Self.validateSchema(probe)
    await probe.disconnect()

    errorMessage = nil
    fileURL = standardized
    importedAt = .now
    fileExists = true
    UserDefaults.standard.set(standardized.path, forKey: Self.pathKey)
    scanGeneration += 1
    stats = nil
    isScanning = false
    connection = nil
    try await ensureOpen()
    startStatsScan()
  }

  /// Forgets the imported DB: closes the connection, drops stats + path.
  func remove() {
    scanGeneration += 1
    if let connection {
      Task { await connection.disconnect() }
    }
    connection = nil
    stats = nil
    isScanning = false
    fileURL = nil
    importedAt = nil
    fileExists = false
    UserDefaults.standard.removeObject(forKey: Self.pathKey)
  }

  // MARK: - stats scan

  /// Starts the background aggregate scan when no stats are cached (the info
  /// popover calls this on open). Idempotent while a scan runs.
  func ensureStats() {
    guard fileURL != nil, stats == nil, !isScanning else { return }
    startStatsScan()
  }

  private func startStatsScan() {
    guard let fileURL, !isScanning else { return }
    isScanning = true
    scanError = nil
    let generation = scanGeneration
    let path = fileURL.path

    Task.detached(priority: .utility) {
      do {
        let scanned = try await Self.scanStats(path: path)
        await MainActor.run {
          guard generation == self.scanGeneration, self.fileURL?.path == path else { return }
          self.stats = scanned
          self.isScanning = false
        }
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        await MainActor.run {
          guard generation == self.scanGeneration, self.fileURL?.path == path else { return }
          self.scanError = message
          self.isScanning = false
        }
      }
    }
  }

  /// Runs the aggregate scan on a background thread with its OWN connection
  /// (the facade is not Sendable; the main-actor connection must never be
  /// driven off-main — two read-only handles to one file are fine).
  /// One full pass, aggregated server-side: (language, app) groups are far
  /// fewer than the 11M rows they summarize. `nonisolated` so the work runs
  /// on the detached executor, not the main actor.
  private nonisolated static func scanStats(path: String) async throws -> ImportedDBStats {
    let connection = SQLiteConnection(
      config: SQLiteConnectionConfig(name: "scan", filePath: path))
    do {
      try await connection.connect()
      let rows = try await connection.select(
        sql: "SELECT language, app, COUNT(*) AS n FROM translations GROUP BY language, app")
      await connection.disconnect()

      var languages: [String: Int64] = [:]
      var apps: [String: Int64] = [:]
      var total: Int64 = 0
      for row in rows {
        var language = ""
        var app = ""
        var count: Int64 = 0
        for (key, value) in row.values {
          switch (key, value) {
          case ("language", .string(let s)): language = s
          case ("app", .string(let s)): app = s
          case ("n", .int(let n)): count = n
          default: break
          }
        }
        languages[language, default: 0] += count
        apps[app, default: 0] += count
        total += count
      }
      return ImportedDBStats(
        totalRows: total,
        languages: languages,
        apps: apps,
        scannedAt: .now)
    } catch {
      await connection.disconnect()
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      throw SQLiteError.server(message)
    }
  }

  /// Background-scan failure text (distinct from import/open errors so the
  /// popover can show "stats unavailable" without failing the import).
  private(set) var scanError: String?

  // MARK: - lookups

  /// Every row of one exact source text (any language). One index seek on
  /// `source`; the caller (pipeline stage) caches per unique source of a run
  /// and picks winners per language via ImportedDBLanguage.hit. The LIMIT is
  /// a sanity cap — a translation string is carried by a handful of apps per
  /// language, so even "OK"-class sources stay far below it.
  func rows(forSource source: String) async throws -> [ImportedDBRow] {
    try await ensureOpen()
    guard let connection else { return [] }
    let rows = try await connection.select(
      sql: "SELECT language, target, app FROM translations WHERE source = ?1 LIMIT 20000",
      binds: [source])
    return rows.compactMap { row -> ImportedDBRow? in
      var language = ""
      var target = ""
      var app = ""
      for (key, value) in row.values {
        switch (key, value) {
        case ("language", .string(let s)): language = s
        case ("target", .string(let s)): target = s
        case ("app", .string(let s)): app = s
        default: break
        }
      }
      guard !language.isEmpty else { return nil }
      return ImportedDBRow(language: language, target: target, app: app)
    }
  }

  /// Convenience: full winner for one (source, catalog language) — the stage
  /// prefers fetch-all-rows + per-language hits for run-wide caching.
  func hit(source: String, language: String) async throws -> ImportedDBHit? {
    let rows = try await rows(forSource: source)
    return ImportedDBLanguage.hit(
      in: rows,
      forCatalogLanguage: language,
      appRowCounts: stats?.apps ?? [:])
  }
}
