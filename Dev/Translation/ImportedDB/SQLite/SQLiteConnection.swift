import Darwin
import Foundation
import SQLite3

/// Async facade over one SQLite database file via the OFFICIAL driver: the
/// system libsqlite3 C API (the macOS SDK ships the SQLite3 module; no remote
/// dependency needed, unlike the network engines). NOT Sendable-declared on
/// purpose — it owns a raw sqlite3 handle and is driven from the MainActor UI
/// or from tests, mirroring PostgresConnection.
///
/// MIRRORED from ../Database/Sources/SQLite/SQLiteConnection.swift (same
/// author). The Dev copy adds `selectBound(sql:binds:)` — parameterized reads
/// the original lacks (raw-SQL interpolation is unsafe for translation text
/// carrying quotes/apostrophes). Re-sync the rest carefully if the source
/// moves.
///
/// Queries are synchronous C calls inside async methods: local files read in
/// milliseconds for the app's limited document loads. Unbounded user SQL (a
/// future SQL editor) should hop to a background queue first.
/// `nonisolated` (Dev compiles with MainActor default isolation): the facade
/// must stay isolation-free so a background stats scan can construct and
/// drive it off the main thread.
nonisolated public final class SQLiteConnection {
  public let config: SQLiteConnectionConfig
  private var db: OpaquePointer?
  /// Always "main" for a file database (see use(database:)).
  public private(set) var currentDatabase: String?
  /// True when the file could only be opened read-only (permision fallback).
  public private(set) var isReadOnly = false

  public init(config: SQLiteConnectionConfig) { self.config = config }

  public var isConnected: Bool { db != nil }

  /// Opens the file read-write, falling back to read-only when the file is
  /// not writable. Never creates a missing file — connect() requires an
  /// existing path (Open With / drag-drop semantics). A probe of
  /// sqlite_master rejects files that are not SQLite databases.
  public func connect() async throws {
    guard config.isValid else {
      throw SQLiteError.invalidConfig("name and filePath must not be empty")
    }
    await disconnect()

    let path = (config.filePath as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      throw SQLiteError.fileNotFound(config.filePath)
    }
    guard !isDirectory.boolValue else { throw SQLiteError.notAFile(config.filePath) }

    var handle: OpaquePointer?
    var rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
    if rc != SQLITE_OK {
      if handle != nil {
        sqlite3_close(handle)
        handle = nil
      }
      rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
      if rc == SQLITE_OK { isReadOnly = true }
    }
    guard rc == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      throw SQLiteError.server(errorMessage(handle) ?? "unable to open database file (\(rc))")
    }

    // The file opened, but it may not be a SQLite database (any file can be
    // dropped onto the app). Probe sqlite_master before reporting connected.
    var stmt: OpaquePointer?
    let probe = sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
    let probeOK = probe == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW
    sqlite3_finalize(stmt)
    guard probeOK else {
      sqlite3_close(handle)
      throw SQLiteError.notADatabase(config.filePath)
    }

    // Avoid spurious "database is locked" when another client holds the file.
    sqlite3_exec(handle, "PRAGMA busy_timeout = 5000", nil, nil, nil)

    // sqlite silently re-opens an unwritable file read-only even when asked
    // for READWRITE, so the handle cannot tell us — ask the file system.
    // (BEGIN IMMEDIATE is NOT a valid probe: POSIX locks work on read-only
    // descriptors, so it succeeds even on a read-only database.)
    isReadOnly = access(path, W_OK) != 0

    db = handle
    currentDatabase = "main"
  }

  public func disconnect() async {
    if let db { sqlite3_close(db) }
    db = nil
    currentDatabase = nil
    isReadOnly = false
  }

  /// A file database is a single database: "main".
  public func listDatabases() async throws -> [String] {
    guard db != nil else { throw SQLiteError.notConnected }
    return ["main"]
  }

  /// SQLite files expose exactly one database ("main"); ATTACH is out of
  /// scope. Kept for facade symmetry with the server engines.
  public func use(database: String) async throws {
    guard db != nil else { throw SQLiteError.notConnected }
    guard database == "main" else {
      throw SQLiteError.unsupported(
        "SQLite files expose a single 'main' database — cannot switch to '\(database)'")
    }
    currentDatabase = "main"
  }

  /// User tables and views, optionally filtered by case-insensitive substring
  /// (client-side; table counts are small in local files).
  public func listTables(matching search: String = "") async throws -> [String] {
    guard db != nil else { throw SQLiteError.notConnected }
    let sql =
      "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') "
      + "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    let names = try await select(sql: sql).compactMap { row in
      for value in row.values.values { if case .string(let s) = value { return s } }
      return nil
    }
    guard !search.isEmpty else { return names }
    return names.filter { $0.localizedCaseInsensitiveContains(search) }
  }

  /// Runs a SELECT and returns every row as key/value pairs. `limit` stops
  /// stepping the statement early; `offset` skips the first N rows (for
  /// cursor-free pagination with a stable ORDER BY).
  public func select(sql: String, limit: Int? = nil, offset: Int? = nil) async throws
    -> [SQLiteRowData]
  {
    guard let db else { throw SQLiteError.notConnected }
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SQLiteError.invalidQuery("Empty SQL statement") }
    let applied = try Self.applyLimitOffset(sql: trimmed, limit: limit, offset: offset)

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, applied, -1, &stmt, nil) == SQLITE_OK else {
      throw SQLiteError.invalidQuery(errorMessage(db) ?? "unknown SQLite error")
    }
    defer { sqlite3_finalize(stmt) }

    var rows: [SQLiteRowData] = []
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW {
      rows.append(Self.rowData(index: rows.count, stmt: stmt))
      if let limit, rows.count >= limit { break }
      rc = sqlite3_step(stmt)
    }
    guard rc == SQLITE_DONE || (limit != nil && rows.count >= limit!) else {
      throw SQLiteError.server(errorMessage(db) ?? "unknown SQLite error")
    }
    return rows
  }

  /// Parameterized SELECT — the Dev-copy addition over the ../Database
  /// original. Text values are bound, never interpolated, so arbitrary
  /// translation source strings (quotes, apostrophes, percent signs) are
  /// safe. `binds` fill `?1, ?2, …` in order. `limit`/`offset` are appended
  /// like select(sql:)'s.
  public func selectBound(sql: String, binds: [String], limit: Int? = nil, offset: Int? = nil)
    async throws -> [SQLiteRowData]
  {
    guard let db else { throw SQLiteError.notConnected }
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SQLiteError.invalidQuery("Empty SQL statement") }
    let applied = try Self.applyLimitOffset(sql: trimmed, limit: limit, offset: offset)

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, applied, -1, &stmt, nil) == SQLITE_OK else {
      throw SQLiteError.invalidQuery(errorMessage(db) ?? "unknown SQLite error")
    }
    defer { sqlite3_finalize(stmt) }

    for (index, bind) in binds.enumerated() {
      let rc = bind.withCString { cString in
        sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, Self.transientDestructor)
      }
      guard rc == SQLITE_OK else {
        throw SQLiteError.invalidQuery(errorMessage(db) ?? "failed to bind parameter \(index + 1)")
      }
    }

    var rows: [SQLiteRowData] = []
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW {
      rows.append(Self.rowData(index: rows.count, stmt: stmt))
      if let limit, rows.count >= limit { break }
      rc = sqlite3_step(stmt)
    }
    guard rc == SQLITE_DONE || (limit != nil && rows.count >= limit!) else {
      throw SQLiteError.server(errorMessage(db) ?? "unknown SQLite error")
    }
    return rows
  }

  /// Appends LIMIT/OFFSET to a read query when asked. SQLite parses both
  /// natively, so the stepping loop's early-break still caps the row count.
  private static func applyLimitOffset(sql: String, limit: Int?, offset: Int?) throws -> String {
    guard limit != nil || offset != nil else { return sql }
    var clauses: [String] = []
    if let limit { clauses.append("LIMIT \(limit)") }
    if let offset { clauses.append("OFFSET \(offset)") }
    return sql + " " + clauses.joined(separator: " ")
  }

  /// Runs any DML/DDL to completion — literally: sqlite3_exec executes every
  /// statement in the string. Affected-row counts are not exposed (matching
  /// the PostgreSQL facade's honesty rule); use `count(sql:)` with an
  /// explicit predicate when a real number matters.
  public func execute(sql: String) async throws {
    guard let db else { throw SQLiteError.notConnected }
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SQLiteError.invalidQuery("Empty SQL statement") }

    var errMsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, trimmed, nil, nil, &errMsg)
    if rc != SQLITE_OK {
      let message = errMsg.map { String(cString: $0) } ?? "unknown SQLite error"
      if let errMsg { sqlite3_free(errMsg) }
      throw SQLiteError.invalidQuery(message)
    }
    if let errMsg { sqlite3_free(errMsg) }
  }

  /// Scalar count via SELECT count(*)-style queries (tests, delete previews).
  public func count(sql: String) async throws -> Int64 {
    let rows = try await select(sql: sql, limit: 1)
    guard let first = rows.first else { return 0 }
    for value in first.values.values { if case .int(let n) = value { return n } }
    return 0
  }

  // MARK: - Internals

  /// SQLITE_TRANSIENT is a C macro (not exported to Swift); the canonical
  /// shim tells sqlite to copy the bound text before the C string dies.
  private static let transientDestructor =
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private static func rowData(index: Int, stmt: OpaquePointer?) -> SQLiteRowData {
    let count = Int(sqlite3_column_count(stmt))
    var columns: [String] = []
    var cells: [SQLiteValue] = []
    for i in 0..<count {
      let idx = Int32(i)
      if let name = sqlite3_column_name(stmt, idx) {
        columns.append(String(cString: name))
      } else {
        columns.append("column\(i)")
      }
      cells.append(value(of: stmt, at: idx))
    }
    return SQLiteRowData(id: index, columns: columns, cells: cells)
  }

  /// Decodes a cell according to its declared storage class; NULL and
  /// untyped cells map to .null so nothing crashes the document list.
  private static func value(of stmt: OpaquePointer?, at index: Int32) -> SQLiteValue {
    switch sqlite3_column_type(stmt, index) {
    case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, index))
    case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, index))
    case SQLITE_TEXT: return text(stmt: stmt, at: index).map { .string($0) } ?? .null
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(stmt, index))
      guard count > 0, let raw = sqlite3_column_blob(stmt, index) else { return .bytes([]) }
      let buffer = UnsafeRawBufferPointer(start: raw, count: count)
      return .bytes(Array(buffer))
    default: return .null
    }
  }

  /// sqlite3_column_text may be typed UnsafePointer<UInt8> — go through
  /// UnsafeRawPointer so either importer spelling compiles.
  private static func text(stmt: OpaquePointer?, at index: Int32) -> String? {
    guard let raw = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
  }

  private func errorMessage(_ handle: OpaquePointer?) -> String? {
    guard let c = sqlite3_errmsg(handle) else { return nil }
    return String(cString: c)
  }
}
