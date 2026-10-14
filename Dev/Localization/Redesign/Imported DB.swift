//
//  Imported DB.swift
//  Dev
//
//  The blocking, read-only reader the imported-database resolve needs (6.3).
//
//  The design fixes the resolve as SYNCHRONOUS (7.1: `Memory.resolve`/`upsert`/
//  `clearHints`, the `Imported` lookup and the whole `Store` are synchronous —
//  state that lives in SwiftData or in one local file), and `Workspace.open()`
//  applies it with a plain `try`. The app's own facade (`ImportedTranslationDB`)
//  is async (the deleted first pipeline awaited it); this file reads the same
//  file through a small blocking handle instead, so prepare never has to be async
//  for a local index seek.
//
//  Read-only, and nothing else: the database is a source of truth the app ships
//  from, never something it writes (6.3).
//

import Foundation
import SQLite3

extension Translation {
  /// The reader behind `Imported.resolve`.
  ///
  /// It answers one question — the raw rows of one exact source text — and hands
  /// them to `ImportedDBLanguage.hit`, the same spelling-normalizing picker the
  /// facade uses, so both readers agree on what a hit is (DB
  /// language codes are not clean BCP-47; see `ImportedDBLanguage`).
  enum ImportedDB {
    /// The handle for the database the app has imported, or nil when there is
    /// none to read.
    ///
    /// Three cases, deliberately different:
    ///
    /// - **nothing imported, or the remembered file has gone away** -> nil, and
    ///   the resolve answers with nothing, exactly as it does with no import at
    ///   all. `fileExists == false` is the app's own word for "this import is
    ///   stale" (`ImportedTranslationDB` says the same), and a remembered path is
    ///   no reason for a project to fail to open.
    /// - **a file that reads** -> the handle, opened once per process and
    ///   re-opened when the file itself has changed: the database is rebuilt by a
    ///   scanner, so the same path is a different database afterwards.
    /// - **a file that is there and does NOT read** (not a database, unreadable)
    ///   -> the error. An unreadable source of truth must not look like an empty
    ///   one.
    static func handle() throws -> Connection? {
      guard let url = ImportedTranslationDB.shared.fileURL,
        FileManager.default.fileExists(atPath: url.path)
      else { return nil }
      if let handle = processHandle, handle.reads(path: url.path) { return handle }
      processHandle?.close()
      processHandle = nil
      let opened = try Connection(path: url.path)
      processHandle = opened
      return opened
    }

    /// The one handle this process keeps, next to the unopened path it was not
    /// worth opening for.
    private static var processHandle: Connection?

    /// One blocking, read-only handle on the imported database file.
    ///
    /// Bound parameters only: a source text is arbitrary UI copy (quotes,
    /// apostrophes, `%`), so it is never interpolated into SQL — the same rule
    /// the app's facade learned the hard way.
    ///
    /// `rows(forSource:)` memoizes per source text, empty answers included. A
    /// project's languages share their sources, and `Imported.resolve` is called
    /// once per language over the SAME rows, so the first column pays the index
    /// seeks and every later column is a memory read.
    final class Connection {
      /// The file this handle reads.
      let path: String
      /// What the file looked like when it was opened, so a rewritten database is
      /// detected rather than served from a stale handle.
      private let stamp: Stamp
      private var handle: OpaquePointer?
      /// The one lookup statement, prepared once and re-bound per source.
      private var lookup: OpaquePointer?
      /// source text -> that source's rows; a miss is memoized as an empty array,
      /// because "the database does not know this string" is an answer too.
      private var memo: [String: [ImportedDBRow]] = [:]

      /// The memo's bound. One project's sources are bounded by its catalog, but a
      /// session can open several projects against one database, so the cache is
      /// dropped wholesale rather than growing without limit. The re-read it costs
      /// is one index seek per source.
      private static let memoLimit = 50_000
      /// A sanity cap on one source's rows, mirroring the app's facade: a string
      /// this common is not evidence, it is noise. Even "OK"-class sources stay far
      /// below it.
      private static let rowLimit = 20_000

      /// Opens the file read-only and checks it carries the table the resolve
      /// reads: the importable format is a `translations` table with `language`,
      /// `source`, `target` and `app`.
      init(path: String) throws {
        guard let stamp = Stamp.read(path) else { throw ImportedDBError.fileNotFound(path) }
        self.path = path
        self.stamp = stamp

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened = handle else {
          let message = handle.map { String(cString: sqlite3_errmsg($0)) }
          if let handle { sqlite3_close(handle) }
          throw ImportedDBError.server(message ?? "unable to open database file (\(rc))")
        }
        // A scanner rebuilding the file must not turn a read into "database is
        // locked" (the facade sets the same timeout).
        sqlite3_exec(opened, "PRAGMA busy_timeout = 5000", nil, nil, nil)
        guard Self.hasTranslationsTable(opened) else {
          sqlite3_close(opened)
          throw ImportedDBError.notADatabase(path)
        }
        self.handle = opened
      }

      deinit { close() }

      var isOpen: Bool { handle != nil }

      /// True when this handle still reads the file it was opened on: the same
      /// path, holding the same bytes (size and modification date). A rebuilt
      /// database is a different database.
      func reads(path: String) -> Bool {
        guard isOpen, path == self.path else { return false }
        return Stamp.read(path) == stamp
      }

      func close() {
        if let lookup { sqlite3_finalize(lookup) }
        lookup = nil
        if let handle { sqlite3_close(handle) }
        handle = nil
      }

      /// Every row of one exact source text, in database order.
      func rows(forSource source: String) throws -> [ImportedDBRow] {
        if let memoized = memo[source] { return memoized }
        let statement = try lookupStatement()
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let bound = source.withCString { sqlite3_bind_text(statement, 1, $0, -1, Self.transient) }
        guard bound == SQLITE_OK else {
          throw ImportedDBError.invalidQuery(self.message ?? "failed to bind the source text")
        }
        var rows: [ImportedDBRow] = []
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW, rows.count < Self.rowLimit {
          let language = Self.text(statement, 0) ?? ""
          // A row without a language cannot be matched to a catalog language, and
          // the reader's own hit picker requires one.
          if !language.isEmpty {
            rows.append(
              ImportedDBRow(
                language: language,
                target: Self.text(statement, 1) ?? "",
                app: Self.text(statement, 2) ?? ""))
          }
          rc = sqlite3_step(statement)
        }
        // A capped run stops on SQLITE_ROW, which is a complete answer here: the
        // cap IS the answer. Anything else is an error worth reporting.
        guard rc == SQLITE_DONE || rows.count >= Self.rowLimit else {
          throw ImportedDBError.server(self.message ?? "unknown SQLite error")
        }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: false) }
        memo[source] = rows
        return rows
      }

      // MARK: - statement

      private func lookupStatement() throws -> OpaquePointer {
        if let lookup { return lookup }
        guard let handle else { throw ImportedDBError.notConnected }
        var statement: OpaquePointer?
        let sql = "SELECT language, target, app FROM translations WHERE source = ?1 LIMIT \(Self.rowLimit)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
        else {
          throw ImportedDBError.invalidQuery(self.message ?? "unknown SQLite error")
        }
        lookup = statement
        return statement
      }

      // MARK: - internals

      /// What identifies the bytes a handle was opened on.
      struct Stamp: Equatable {
        var size: Int64
        var modified: Date?

        static func read(_ path: String) -> Stamp? {
          guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
          else { return nil }
          return Stamp(size: size.int64Value, modified: attributes[.modificationDate] as? Date)
        }
      }

      /// True when the file carries a `translations` table with all four columns the
      /// resolve and the import format agree on. One probe for both halves of what
      /// the app's facade checks separately (the table exists, and its columns are
      /// the expected four).
      private static func hasTranslationsTable(_ handle: OpaquePointer?) -> Bool {
        let sql =
          "SELECT count(*) FROM pragma_table_info('translations') "
          + "WHERE name IN ('language', 'source', 'target', 'app')"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW
        else { return false }
        return sqlite3_column_int(statement, 0) >= 4
      }

      /// SQLITE_TRANSIENT is a C macro (not exported to Swift); the canonical shim
      /// tells sqlite to copy the bound text before the C string dies.
      private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

      /// A cell as text. `nil` for NULL and for any non-text storage class.
      private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
          let raw = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
      }

      private var message: String? {
        guard let handle else { return nil }
        return String(cString: sqlite3_errmsg(handle))
      }
    }
  }
}
